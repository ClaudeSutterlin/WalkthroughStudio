---
id: architecture
title: Architecture narrative
minutes: 4
evidence: [lens-data-migrations, map-ci, map-db, map-ops, map-src]
order: 2
---

# Architecture

This repository is a fifteen-file Python order service kept as a test fixture: two HTTP handler functions (create an order, get an order), a ten-line authorization module, a service that sums line items into a total, and a thirty-seven-line repository that reaches a single PostgreSQL database named orders through hand-written SQL. Twelve commits by two authors between 2025-01-04 and 2025-02-06 built it, every directory has a bus factor of one, and all seven commits touching src/ are by the same person. There is no web framework, no route binding, no configuration layer and no logging, so the service cannot actually be run from this checkout alone. What it does carry is unusually legible risk: reading an order needs no credential at all, order creation retries its INSERT without an idempotency key (duplicate orders already reached production and the fix lowered the retry count rather than closing the hole), every request leaks a database connection, migration 002 is written to drop users.address without copying the data, and the only test never imports any of this code, so CI is green by construction.

## Containers {code: code:./@fb63e78}

- The repository has exactly one GitHub Actions workflow, named ci, with a single job test that checks out the repo and runs tests/test_orders.sh. [[fact:F-map-ci-001]] [[code:.github/workflows/ci.yml@fb63e78#L1-L8]]
- tests/test_orders.sh is the repository's entire test suite: an 8-line bash script that runs an inline Python heredoc and prints PASS. [[fact:F-map-ci-008]] [[code:tests/test_orders.sh@fb63e78#L1-L8]]
- db/ holds the Postgres schema as three hand-applied raw SQL files (schema.sql plus two numbered migrations) with no migration runner, tracking table, or ORM. [[fact:F-map-db-001]] [[code:db/schema.sql@fb63e78#L1-L16]]
- deploy/deploy.sh is a six-line bash script that deploys the service by copying the src/ tree to a per-environment host over scp and restarting a systemd unit over ssh. [[fact:F-map-ops-001]] [[code:deploy/deploy.sh@fb63e78#L1-L6]]
- templates/email.tmpl is a three-line plain-text order-confirmation email body using Jinja/Mustache-style {{ }} placeholders. [[fact:F-map-ops-017]] [[code:templates/email.tmpl@fb63e78#L1-L3]]
- README.md is a nine-line document describing the repository as a tiny fixture order service and pointing at the test script, the deploy script and the operations caveats (no rollback, hand-applied migrations). [[fact:F-map-ops-023]] [[code:README.md@fb63e78#L1-L9]]
- src/auth/authz.py is the entire authorization layer: one Forbidden exception class and one require_user function that compares a header to the requested user id. [[fact:F-map-src-010]] [[code:src/auth/authz.py@fb63e78#L1-L10]]
- src/service/orders.py holds OrderService, the business-logic layer: it computes the order total from items and delegates persistence to OrdersRepo. [[fact:F-map-src-017]] [[code:src/service/orders.py@fb63e78#L1-L14]]
- src/repo/orders_repo.py is the persistence layer: OrdersRepo issues raw parameterized SQL over a psycopg2 connection opened in __init__ and never closed, with insert, fetch and list_for_user operations. [[fact:F-map-src-024]] [[code:src/repo/orders_repo.py@fb63e78#L1-L9]]
- The entire data plane is one PostgreSQL database literally named 'orders' holding two tables (users, orders) at HEAD; there is no cache, queue, file store, search index or second database anywhere in the repository. [[fact:F-lens-data-migrations-001]] [[code:src/repo/orders_repo.py@fb63e78#L9]]

## Entry points

- handle_create_order(request) creates an order from request.json['user_id'] and request.json['items'] after require_user passes, returning whatever OrderService.create returns. [[fact:F-map-src-002]] [[code:src/api/orders_handler.py@fb63e78#L6-L11]]
- handle_get_order(request, order_id) returns OrderService.get(order_id) with no authorization step. [[fact:F-map-src-003]] [[code:src/api/orders_handler.py@fb63e78#L14-L16]]

## Interfaces

- The test script's contract is exit code only: set -e makes any failing command abort non-zero, a passing run prints PASS and exits 0, and it takes no arguments or environment variables. [[fact:F-map-ci-014]] [[code:tests/test_orders.sh@fb63e78#L3-L8]]
- The only code that touches the schema is src/repo/orders_repo.py, which depends on exactly three orders columns: INSERT (user_id, total) RETURNING id, and SELECT id, user_id, total by id or by user_id; users is never queried by application code. [[fact:F-map-db-019]] [[code:db/schema.sql@fb63e78#L7-L11]]
- The script takes exactly one required positional argument, the environment name, and aborts with the message 'env' if it is missing; the target host is derived as deploy@<env>.example.com. [[fact:F-map-ops-002]] [[code:deploy/deploy.sh@fb63e78#L4-L5]]
- The template's rendering contract requires a context with user.name, order.id and order.total; no other variables are referenced. [[fact:F-map-ops-018]] [[code:templates/email.tmpl@fb63e78#L1-L3]]
- require_user(request, user_id) raises Forbidden('user mismatch') unless the X-User request header string-equals str(user_id); it returns None on success. [[fact:F-map-src-011]] [[code:src/auth/authz.py@fb63e78#L8-L10]]
- Forbidden is a bare Exception subclass with no HTTP status or serialization, so the hosting framework must translate it or a failed authz check surfaces as a 500. [[fact:F-map-src-012]] [[code:src/auth/authz.py@fb63e78#L4-L5]]
- OrderService.create(user_id, items) computes total = sum(price * qty) over items and returns repo.insert(user_id, items, total). [[fact:F-map-src-018]] [[code:src/service/orders.py@fb63e78#L9-L11]]
- OrderService.get(order_id) is a pass-through to OrdersRepo.fetch(order_id). [[fact:F-map-src-019]] [[code:src/service/orders.py@fb63e78#L13-L14]]
- OrdersRepo.insert(user_id, items, total) tries _insert_once up to 2 times, sleeping 0.1s then 0.2s after a psycopg2.OperationalError, and raises RuntimeError('insert failed after retries') if both attempts fail; it returns {'id', 'total'}. [[fact:F-map-src-027]] [[code:src/repo/orders_repo.py@fb63e78#L11-L25]]
- OrdersRepo.fetch(order_id) runs SELECT id, user_id, total FROM orders WHERE id = %s and returns a dict; for an unknown id fetchone() returns None and row[0] raises TypeError, so there is no not-found path. [[fact:F-map-src-031]] [[code:src/repo/orders_repo.py@fb63e78#L27-L31]]
- OrdersRepo.list_for_user(user_id) returns all orders for a user in one query, but no handler or service in src/ calls it, so it is unreachable from the HTTP surface at HEAD. [[fact:F-map-src-032]] [[code:src/repo/orders_repo.py@fb63e78#L33-L37]]
