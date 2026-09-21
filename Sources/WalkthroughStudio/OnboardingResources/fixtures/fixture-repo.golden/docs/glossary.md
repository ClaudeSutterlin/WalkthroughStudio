---
id: glossary
title: Glossary
minutes: 5
evidence: []
order: 13
---

# Glossary

- **applied (migration header)**: A first-line SQL comment ('-- applied' or '-- NOT yet applied') that is the only record of whether a db/migrations/ file has been run; it is one flag for all environments and is flipped by hand. [[code:db/migrations/001_orders.sql@fb63e78#L1]]
- **schema.sql**: The hand-maintained bootstrap schema for a fresh 'orders' database; by convention applied migrations are appended to it verbatim under a '-- NNN_name.sql' comment, so it already contains 001 and running the migrations folder after it fails. [[code:db/schema.sql@fb63e78#L13-L14]]
- **address split**: The planned but unapplied migration 002 that moves users.address into a separate addresses table (line1, city, country) and drops the column, with no data copy step. [[code:db/migrations/002_split_addresses.sql@fb63e78#L2-L7]]
- **pin**: An exact '==' version constraint in requirements.txt; this repository pins its two direct dependencies (requests 2.19.0, psycopg2 2.8.6) but nothing transitive, and no pipeline installs the file. [[code:requirements.txt@fb63e78#L1-L2]]
- **psycopg2 vs psycopg2-binary**: psycopg2 is the source distribution that compiles against the host's libpq headers; psycopg2-binary ships prebuilt wheels. The manifest pins the source form, so installs need Postgres development headers. [[code:requirements.txt@fb63e78#L2]]
- **orders (systemd unit)**: The systemd service named 'orders' that deploy.sh restarts over ssh; its unit file (interpreter, working directory, environment) is not in the repository and is the only thing that decides how the Python code is actually run on a host. [[code:deploy/deploy.sh@fb63e78#L6]]
- **/srv/orders**: The install directory on every host into which deploy.sh scp's the src/ tree; the process must run with this directory on sys.path so that 'from src.auth.authz import ...' resolves. [[code:deploy/deploy.sh@fb63e78#L5]]
- **deploy user**: The 'deploy' Unix account on each <env>.example.com host that receives scp uploads and runs 'sudo systemctl restart orders'; its keys and sudo rules live outside the repository. [[code:deploy/deploy.sh@fb63e78#L5-L6]]
- **order**: One row of the orders table (id, user_id, total, created_at), created by OrderService.create from a user_id and a list of items; returned as {id, total} on creation and {id, user_id, total} on fetch. Line items are not part of an order as stored. [[code:db/schema.sql@fb63e78#L7-L14]]
- **items**: The request-body list of {price, qty} dicts passed to create; summed into total and then discarded, never persisted. There is no line-item table. [[code:src/service/orders.py@fb63e78#L10]]
- **total**: The order amount: sum(price*qty) over items, computed as a Python float, stored in orders.total as NUMERIC(10,2), read back as decimal.Decimal. No currency is recorded. [[code:src/service/orders.py@fb63e78#L10]]
- **user**: A row of the users table (id SERIAL, email TEXT NOT NULL -- PII, address TEXT). Application code never reads or writes users; a user exists to the service only as the integer user_id on orders and in the X-User header. No code path creates users. [[code:db/schema.sql@fb63e78#L1-L5]]
- **address**: Today: the nullable free-text users.address column. Planned (migration 002, not applied): a separate addresses table (id, user_id, line1, city, country) with users.address dropped. Nothing in src/ reads either, despite the schema TODO claiming otherwise. [[code:db/schema.sql@fb63e78#L4]]
- **addresses (table)**: The planned per-user postal address table introduced by migration 002; does not exist in any applied schema at HEAD. [[code:db/migrations/002_split_addresses.sql@fb63e78#L2-L6]]
- **user_id**: Integer identifying a user; arrives in the JSON body, is compared as str() against the X-User header, and is written to orders.user_id (FK to users.id). The only tenant/ownership signal in the system. [[code:src/api/orders_handler.py@fb63e78#L8-L9]]
- **X-User**: Request header carrying the caller's user id as a string; the sole identity signal. require_user passes iff header == str(body user_id). Not authenticated. [[code:src/auth/authz.py@fb63e78#L9]]
- **Forbidden / 'user mismatch'**: The bare Exception raised by require_user when X-User does not equal str(user_id). Carries no HTTP status; the hosting framework must translate it. [[code:src/auth/authz.py@fb63e78#L4-L10]]
- **idempotency key**: A client-supplied token that would let a retried order INSERT be recognised and not re-applied. Referenced as missing in the handler TODO and the repo comment; exists nowhere in the schema or code. Its absence is the root cause of the production duplicate-order incident. [[code:src/api/orders_handler.py@fb63e78#L7]]
- **attempt (retry)**: One iteration of OrdersRepo.insert's `for attempt in range(2)` loop: two attempts total, one retry, sleeping 0.1s then 0.2s after an OperationalError. The count was 3 and was reverted to 2 after duplicate orders in production. [[code:src/repo/orders_repo.py@fb63e78#L13-L17]]
- **double insert / duplicate order**: The failure where an OperationalError after a successful commit causes the retry loop to run the INSERT again, creating two orders rows for one request. Observed in production at 3 attempts (commit 27caac5). [[code:src/repo/orders_repo.py@fb63e78#L12]]
- **orders (database)**: The literal Postgres database name hard-coded in psycopg2.connect("dbname=orders"); host, port, user and password come from libpq PG* environment variables, not from DATABASE_URL. [[code:src/repo/orders_repo.py@fb63e78#L9]]
- **migration**: A numbered raw SQL file in db/migrations/ applied by hand with psql; there is no runner and no tracking table. Migration 001's ALTER is also inlined in schema.sql, so bootstrap-then-migrate fails on 001. [[code:db/migrations/001_orders.sql@fb63e78#L1-L2]]
- **applied / NOT yet applied**: The first-line comment in each migration file recording its status. It is one flag per repository, not per environment database, so it cannot say which env has which migration. [[code:db/migrations/002_split_addresses.sql@fb63e78#L1]]
- **created_at**: orders.created_at TIMESTAMP DEFAULT now(), added by migration 001; populated by the database but never selected or returned by any repo method. [[code:db/schema.sql@fb63e78#L13-L14]]
- **env**: The single positional argument to deploy.sh; used only as the subdomain of the target host (deploy@<env>.example.com). It selects no config file or database. [[code:deploy/deploy.sh@fb63e78#L4-L5]]
- **deploy**: `deploy/deploy.sh <env>`: scp -r of the local src/ working tree to /srv/orders/ on the host, then `sudo systemctl restart orders`. No rollback, no migrations, no requirements install; recovery is redeploying the previous commit. [[code:deploy/deploy.sh@fb63e78#L2-L6]]
- **smoke test**: tests/test_orders.sh: an inline Python heredoc asserting that a hard-coded two-item list sums to 6.0, then `echo PASS`. It imports no project module despite its comment, and is the whole CI test step. [[code:tests/test_orders.sh@fb63e78#L2-L8]]
- **PII**: Personally identifiable information; in this schema only users.email is annotated as such (comment), though users.address is also personal data. Stored in plaintext. [[code:db/schema.sql@fb63e78#L3]]
- **generated client (client_pb2)**: vendor/generated/client_pb2.py, marked 'Generated by protoc. DO NOT EDIT'. No .proto source, no codegen step and no importer exist in the repository; it is vendored, unreferenced and not regenerable from here. [[code:vendor/generated/client_pb2.py@fb63e78#L1-L2]]
- **confirmation email**: templates/email.tmpl, a plain-text body with {{ user.name }}, {{ order.id }} and {{ order.total }} placeholders. No engine is declared and no code renders or sends it; user.name has no backing column. [[code:templates/email.tmpl@fb63e78#L1-L3]]
