# Create an order (POST create-order → OrderService.create → OrdersRepo.insert)

**Scenario.** A client POSTs an order for user 42: headers {"X-User": "42"}, body {"user_id": 42, "items": [{"price": 2.5, "qty": 2}, {"price": 1.0, "qty": 1}]}. handle_create_order reads user_id 42, require_user compares the X-User header "42" to str(42) and passes, OrderService.create folds the two items into total = 6.0, and OrdersRepo.insert writes one row into orders and returns {"id": 1001, "total": 6.0}. The interesting variant, followed at hop 6, is the same request when psycopg2 raises OperationalError on the commit round-trip after the row is already durable: the loop retries and a second order row for user 42 is created.

## Hops

1. handle_create_order pulls user_id straight out of request.json, calls require_user, constructs a fresh OrderService per request, and returns whatever the service returns — its own TODO on L7 admits the repo's retries can double-insert. [[code:src/api/orders_handler.py@fb63e78#L6-L11]]
2. require_user raises Forbidden unless the X-User header string-equals str(user_id), which compares two values the same caller supplied and so proves only that the header and the body agree, never who the caller is. [[code:src/auth/authz.py@fb63e78#L8-L10]]
3. OrderService.__init__ hard-constructs an OrdersRepo, so there is no injection seam between business logic and the database on this request. [[code:src/service/orders.py@fb63e78#L5-L7]]
4. OrdersRepo.__init__ opens a new psycopg2 connection to the hard-coded DSN "dbname=orders" with no connect_timeout, outside any retry, and the module docstring on L1 states the connection is never closed. [[code:src/repo/orders_repo.py@fb63e78#L7-L9]]
5. OrderService.create is the entire business logic: it folds items into total = sum(price * qty) in Python float arithmetic (2.5*2 + 1.0*1 = 6.0) and passes user_id, items and total to the repo. [[code:src/service/orders.py@fb63e78#L9-L11]]
6. OrdersRepo.insert calls _insert_once up to twice, catching only psycopg2.OperationalError and sleeping 0.1s then 0.2s between attempts, with no idempotency key — the literal 2 on L13 is an incident-tuned constant reverted from 3 after duplicate orders in production. [[code:src/repo/orders_repo.py@fb63e78#L11-L18]]
7. _insert_once executes a parameterized INSERT INTO orders (user_id, total) ... RETURNING id, reads the new id, commits, and returns {"id": order_id, "total": total} — the items list never reaches SQL. [[code:src/repo/orders_repo.py@fb63e78#L20-L25]]
8. The write lands in orders (id SERIAL, user_id INTEGER REFERENCES users(id), total NUMERIC(10,2) NOT NULL): no unique or idempotency constraint exists to stop a duplicate, no line-item table exists to hold the items, and the nullable FK points at a users table nothing in this repository ever writes. [[code:db/schema.sql@fb63e78#L7-L11]]
9. The repo's raw dict is returned unchanged through OrderService.create and out of the handler — no serialization, status code or error mapping, so the response shape is whatever psycopg2 and Python produced. [[code:src/api/orders_handler.py@fb63e78#L11]]

## The ten concerns

| Concern | Status | Evidence |
|---|---|---|
| entry | **present** | [[code:src/api/orders_handler.py@fb63e78#L6-L11]] [[code:src/api/orders_handler.py@fb63e78#L1-L3]] |
| authorization | **present** | [[code:src/auth/authz.py@fb63e78#L8-L10]] [[code:src/api/orders_handler.py@fb63e78#L9]] |
| validation | **absent** | [[code:src/api/orders_handler.py@fb63e78#L6-L11]] [[code:src/service/orders.py@fb63e78#L9-L11]] [[code:db/schema.sql@fb63e78#L7-L11]] |
| businessLogic | **present** | [[code:src/service/orders.py@fb63e78#L9-L11]] |
| persistence | **present** | [[code:src/repo/orders_repo.py@fb63e78#L20-L25]] [[code:db/schema.sql@fb63e78#L7-L11]] |
| sideEffects | **absent** | [[code:src/service/orders.py@fb63e78#L9-L11]] [[code:src/repo/orders_repo.py@fb63e78#L11-L25]] [[code:templates/email.tmpl@fb63e78#L1-L3]] |
| failureHandling | **absent** | [[code:src/api/orders_handler.py@fb63e78#L6-L11]] [[code:src/repo/orders_repo.py@fb63e78#L14-L18]] [[code:src/auth/authz.py@fb63e78#L4-L5]] |
| idempotency | **absent** | [[code:src/api/orders_handler.py@fb63e78#L7]] [[code:src/api/orders_handler.py@fb63e78#L6-L11]] [[code:src/repo/orders_repo.py@fb63e78#L11-L18]] |
| timeoutsRetries | **present** | [[code:src/repo/orders_repo.py@fb63e78#L11-L18]] [[code:src/repo/orders_repo.py@fb63e78#L13]] [[code:src/repo/orders_repo.py@fb63e78#L9]] |
| logging | **absent** | [[code:src/api/orders_handler.py@fb63e78#L6-L11]] [[code:src/service/orders.py@fb63e78#L9-L11]] [[code:src/repo/orders_repo.py@fb63e78#L11-L25]] |

## What scares me

- A retry that fires after the commit already succeeded creates a second, fully valid order for the same customer, and nothing anywhere would tell you: there is no idempotency key, no unique constraint on orders, and no log line on the retry. You would find out from a customer complaining about a double charge, or from a SELECT user_id, total, created_at ... GROUP BY HAVING count(*) > 1 run by hand. This already happened in production; the fix changed the retry count from 3 to 2, which makes it rarer, not impossible.
- The single authorization check compares the X-User header with the user_id in the same request body. Anyone who can send a header can set both to 7 and create orders as user 7. If a proxy or gateway upstream is supposed to set or strip X-User, that assumption lives outside this repository and is not asserted anywhere in it, so a routing change that stops stripping the header opens the service silently.
- Every request opens a new psycopg2 connection in OrdersRepo.__init__ and never closes it. Under any real traffic you exhaust Postgres connections rather than degrade, and the symptom is connect failures on the healthy path — which is also the one call not wrapped in the retry loop and the one with no connect_timeout, so requests hang instead of erroring.
- The handler validates nothing. A body missing 'items' raises KeyError, a user_id that does not exist raises IntegrityError from the foreign key, a total above 99,999,999.99 raises DataError, and none of them are caught or mapped to a response — they escape as whatever the (absent) hosting framework does with an unhandled exception, most likely a 500 and a stack trace.
- The items a customer ordered are summed into a total and thrown away. There is no order_items table and insert forwards only user_id and total, so after a disputed order you can say what was charged but not what was bought, and no backfill can recover it.
- No test touches any of this. tests/test_orders.sh re-implements sum(price * qty) in a heredoc and asserts 6.0; it imports nothing from src/, so CI stays green through a repeat of the duplicate-order incident, a broken authorization check, or a handler that raises on every request.
- src/ has exactly one author across all seven of its commits and orders_repo.py is the top hotspot with six of the repository's twelve commits, including the hotfix and the revert. The reasoning behind the constant 2 on L13 exists only in a commit message; anyone who reads that line as an arbitrary default and raises it re-opens the production incident.
- templates/email.tmpl promises the customer a confirmation email that no code sends. Someone will eventually notice confirmations are missing and wire the template in — most likely inside the retry loop or right after commit, which is exactly where a retry would send the second email too.
