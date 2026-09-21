---
id: adrs
title: Architecture decisions
minutes: 13
evidence: [lens-data-migrations]
order: 5
---

# Architecture decisions

## Persist orders with hand-written SQL over psycopg2 instead of an ORM

**Decision.** All persistence is three literal SQL strings executed through a psycopg2 cursor in OrdersRepo, with rows unpacked by positional index into dicts; no ORM, query builder or data-access framework is declared or used anywhere, and requirements.txt names psycopg2 as the only database dependency.

**Alternatives.** SQLAlchemy Core or ORM with declarative models; Django ORM with its migration framework; A thin query builder such as PyPika, or asyncpg with generated row types; psycopg2 with RealDictCursor and named columns instead of positional indexes

**Consequences.** The code is small, dependency-light and free of SQL injection because every statement is parameterized, but the schema exists in the code only as column names inside strings and as the integer offsets row[0], row[1], row[2]: adding or reordering a column in db/schema.sql breaks fetch and list_for_user silently at runtime rather than at import or test time. It also means no unit of work, no connection pooling and no type mapping layer, which is where the connection leak and the float-in/Decimal-out mismatch come from. Nothing outside the repo file knows the schema, so the same choice keeps the blast radius of a schema change to one 37-line file.

**Would repeat.** yes

**Evidence.** [[code:src/repo/orders_repo.py@fb63e78#L20-L31]] [[code:src/repo/orders_repo.py@fb63e78#L33-L37]] [[code:db/schema.sql@fb63e78#L1-L11]] [[code:requirements.txt@fb63e78#L1-L2]]

## Authorize inside each handler by comparing an X-User header to the request body

**Decision.** Authorization is a single ten-line module: require_user(request, user_id) raises Forbidden unless request.headers.get('X-User') equals str(user_id). It is called explicitly by handle_create_order and by nothing else; there is no middleware, no session, no token verification and no framework integration. It was not in the initial import; it was added three days later in one commit scoped to order creation and never revised.

**Alternatives.** Framework middleware or a decorator that authorizes every route by default and requires an explicit opt-out; A signed session cookie or bearer token verified against a secret, giving an identity the client cannot choose; Scoping the data access itself: pass the caller's user_id into the SQL so a row the caller does not own cannot be returned; Delegating authentication to a gateway and asserting in code that the trusted header was set by it

**Consequences.** Because the X-User header and the body's user_id both come from the same client, the check enforces self-consistency of a request rather than authorization: a caller who sets both to 7 acts as user 7. Because the check is opt-in per handler, every new handler is unprotected by default, which handle_get_order already demonstrates: reading an order needs no header at all, and order ids are a SERIAL sequence that fetch selects on without a user predicate. Forbidden is a bare Exception with no status code, so even the denial path depends on a hosting framework that is not in this repository. Retrofitting real authorization means changing the SQL as well as the handlers.

**Would repeat.** no

**Evidence.** [[code:src/auth/authz.py@fb63e78#L1-L10]] [[code:src/api/orders_handler.py@fb63e78#L6-L16]] [[code:src/repo/orders_repo.py@fb63e78#L27-L31]] [[commit:d7b0850aadb5334dca15c14081de583791b705fc]]

## Make order inserts durable by retrying twice, without an idempotency key

**Decision.** OrdersRepo.insert wraps _insert_once in for attempt in range(2), catching psycopg2.OperationalError, sleeping 0.1s then 0.2s, and raising RuntimeError('insert failed after retries') if both attempts fail. Transient database errors are handled by repeating the INSERT rather than by making the INSERT repeatable: there is no client token, no unique constraint on orders and no dedup check anywhere.

**Alternatives.** A client-supplied idempotency key stored with a unique index on orders, so a replayed INSERT is recognised and not re-applied; A natural uniqueness constraint (user_id plus a request id, or a hash of the cart) enforced by the database; No retry at all: return the error and let the caller decide, which at least never duplicates; Retrying only errors raised before the commit round-trip, and treating a commit-time failure as indeterminate rather than failed

**Consequences.** An OperationalError that arrives after conn.commit() has already succeeded, such as a timeout on the commit round-trip, re-runs the INSERT and creates a second fully valid order for the same customer with no marker distinguishing it. This is not theoretical: the count was raised to 3 on 2025-01-22 and reverted to 2 six days later after duplicate orders in production, so the chosen remedy made the failure rarer rather than impossible, and the inline comment on line 13 is the only thing stopping the next person from raising it again. The loop also catches only OperationalError, so an IntegrityError from the user_id foreign key or a DataError from NUMERIC(10,2) escapes on the first occurrence, it reuses the same connection without rollback or reconnect, it discards the original exception instead of chaining it, and it sleeps 0.2s after the final failed attempt before giving up.

**Would repeat.** no

**Evidence.** [[code:src/repo/orders_repo.py@fb63e78#L11-L18]] [[code:src/api/orders_handler.py@fb63e78#L6-L11]] [[code:db/schema.sql@fb63e78#L7-L11]] [[commit:27caac59e7c6dec5425b6e2bb60f0f23e7cac3bc]] [[commit:ef34fe2bd7f9fb17c4e85309d4131cc6812d101b]]

## Deploy by copying src/ over scp and restarting a systemd unit, with redeploy as the only rollback

**Decision.** deploy/deploy.sh is six lines: set -e, a required <env> argument used only as the subdomain of deploy@<env>.example.com, scp -r src to /srv/orders/, and ssh sudo systemctl restart orders. There is no build, no artifact, no versioning, no health check and no rollback; the README states the rollback procedure is to redeploy the previous commit. CI never calls the script.

**Alternatives.** Build a versioned artifact (wheel, tarball or container image) in CI and deploy that by tag, so the running version is identifiable and re-deployable; Symlink-switched release directories (the Capistrano pattern), where rollback is repointing a symlink; A second instance plus a health check and a load-balancer switch, so a deploy is not an outage; Letting CI deploy on a green build of the default branch, making the pipeline the only path to production

**Consequences.** The script copies the operator's local working tree, so uncommitted edits ship and nothing on the host or in git records which revision is running; code can reach production having never passed CI or even been pushed. scp never deletes, so a module removed from the repository stays importable on the host forever. Only src/ ships, so requirements.txt, config/, templates/ and db/ drift from the repository by construction, which is exactly why migrations have to be an out-of-band manual step. The restart is a hard restart of a single instance with no drain and no readiness check, so every deploy drops in-flight requests, and a deploy that fails on import leaves the environment down until a human notices. Because set -e only aborts, a failure between the scp and the ssh leaves new code on disk under the old process, to be activated silently by the next restart for any reason.

**Would repeat.** no

**Evidence.** [[code:deploy/deploy.sh@fb63e78#L1-L6]] [[code:README.md@fb63e78#L6-L9]] [[code:.github/workflows/ci.yml@fb63e78#L1-L8]]

## Apply migrations by hand and track them with a comment in the file

**Decision.** Schema changes are numbered raw SQL files run manually against each environment's database. There is no migration runner, no schema_migrations table and no migration step in CI or in deploy.sh. State is recorded by editing a header comment in the migration file ('-- applied' on 001, '-- NOT yet applied' on 002) and by pasting the applied statements into db/schema.sql under a '-- <file>' comment, a three-step convention that is written down nowhere and can only be inferred from commit 8facb98.

**Alternatives.** Alembic, Flyway, sqitch or any runner with a versions table in the database itself, so each environment reports its own state; A migrate step inside deploy.sh or the CI pipeline, giving code and schema a defined order; Keeping schema.sql generated from the migrations (dump after apply) instead of hand-edited, so the two cannot disagree; Expand-and-contract migrations with a separate backfill, so a destructive drop is never in the same script as the create

**Consequences.** The '-- applied' marker is one flag in git while deploy.sh targets any number of <env>.example.com hosts, each with its own database, so the repository cannot tell you whether staging or production has 001 or 002; the only reliable check is inspecting each live database. Because 001's ALTER was also copied into schema.sql, bootstrapping from schema.sql and then running the migrations folder fails with 'column created_at already exists'. Migration 002 has been written but unapplied since 2025-01-25, justified by a TODO in schema.sql claiming users.address is still read by src/service, which a pickaxe search over the whole history shows was never true. Neither migration is wrapped in a transaction and neither has a down script, so a failure part way through 002 leaves a half-migrated database with no recorded state, and 002 as written drops users.address in the same script that creates addresses with no INSERT ... SELECT between them.

**Would repeat.** no

**Evidence.** [[code:db/migrations/001_orders.sql@fb63e78#L1-L2]] [[code:db/migrations/002_split_addresses.sql@fb63e78#L1-L7]] [[code:db/schema.sql@fb63e78#L13-L16]] [[code:README.md@fb63e78#L8-L9]] [[commit:8facb9866f89e89a602948e15b155bcdef226a2d]]

## Test with one hermetic shell smoke test that never imports the code

**Decision.** The entire test suite is tests/test_orders.sh: an eight-line bash script that runs a Python heredoc, asserts that a hard-coded list of two items sums to 6.0 using arithmetic written inside the test itself, and echoes PASS. CI runs that script and nothing else: no pip install, no setup-python, no database, no test framework, no coverage. Neither production-incident commit added a test.

**Alternatives.** pytest with psycopg2.connect monkeypatched or a fake repo, covering the total computation, the retry loop and require_user without any infrastructure; A PostgreSQL service container in CI plus schema.sql, covering the SQL and the foreign key for real; Contract tests over the two handlers with a stub request object, which the duck-typed .json/.headers interface already allows; Keeping the smoke test but making its comment true: import src.service.orders and assert on OrderService.create

**Consequences.** CI is green by construction and proves nothing about src/: the handlers, require_user, the retry loop and every SQL statement have zero coverage, so a repeat of the duplicate-order incident, a deleted require_user call or a handler that raises on every request would all ship green. The script's own comment claims it checks that 'the modules import', which is false and could not be made true under CI's conditions, because importing the handler pulls in psycopg2 and CI never installs requirements.txt. The absence of tests is partly structural: OrderService constructs an OrdersRepo whose __init__ connects to a hard-coded database, so there is no seam to test against, which is why the test re-implements the formula instead of calling it. Adding the first real test therefore means choosing a runner, adding a pip install to CI and introducing a seam, not just writing an assert.

**Would repeat.** no

**Evidence.** [[code:tests/test_orders.sh@fb63e78#L1-L8]] [[code:.github/workflows/ci.yml@fb63e78#L1-L8]] [[code:src/service/orders.py@fb63e78#L5-L11]] [[code:src/repo/orders_repo.py@fb63e78#L7-L9]]

## Store an order as a single total and discard its line items

**Decision.** OrderService.create accepts a list of items, folds them into total = sum(price * qty) in Python float arithmetic, and passes items to OrdersRepo.insert, whose INSERT persists only (user_id, total). The schema has no order_items table and orders has exactly id, user_id, total and created_at.

**Alternatives.** An order_items table written in the same transaction as the order, with the total derived or checked against it; Storing the submitted items as a JSONB column on orders, keeping the evidence without modelling it; Computing the total in SQL (or in Decimal) from stored items rather than in Python floats; Recording at least a currency and a computed-at timestamp alongside the amount

**Consequences.** After a disputed order the system can say what was charged but not what was bought, and no backfill can recover it because the items were never written anywhere. The money path has no validation to compensate: negative or non-numeric prices, an empty items list (total 0) and float artefacts all pass straight into a NUMERIC(10,2) column without rounding, and a total above 99,999,999.99 raises a DataError the retry loop does not catch. The same value also has two types depending on the path, the Python float returned by create versus the decimal.Decimal returned by fetch, which standard json.dumps cannot even serialize. templates/email.tmpl already promises the customer a confirmation naming order.total, so the gap is visible to the business, not only internally.

**Would repeat.** no

**Evidence.** [[code:src/service/orders.py@fb63e78#L9-L11]] [[code:src/repo/orders_repo.py@fb63e78#L20-L25]] [[code:db/schema.sql@fb63e78#L7-L11]] [[code:templates/email.tmpl@fb63e78#L1-L3]]

## Hard-code the database DSN and open a new connection per request

**Decision.** OrdersRepo.__init__ calls psycopg2.connect("dbname=orders") and never closes the connection; OrderService.__init__ constructs an OrdersRepo, and each handler constructs an OrderService. There is no configuration layer: config/settings.example declares a DATABASE_URL key and a FAKE_SECRET key, but no code in src/ reads that file or any environment variable, and deploy.sh never ships it.

**Alternatives.** Reading a DSN from an environment variable or settings file, which is what config/settings.example implies was intended; A module-level connection pool (psycopg2.pool) or a pooler such as pgbouncer, with connections returned after each request; Injecting the connection or repo into OrderService, which would also create the test seam the suite lacks; Per-environment configuration keyed off the <env> argument deploy.sh already takes

**Consequences.** Every HTTP request leaks one PostgreSQL connection, and because psycopg2 runs with autocommit off and the SELECT paths never commit or roll back, each read also leaves a session idle in transaction, pinning snapshots, blocking VACUUM and walking toward the default max_connections of 100 under read traffic as much as write traffic. Host, port, user, password and sslmode come from libpq defaults and PG* environment variables on each host, not from anything in this repository, so the production credential exists only on the machine with no rotation path, and a remote PGHOST falls back to plaintext under sslmode=prefer. The connect call sits in the constructor outside the retry loop and has no connect_timeout, so a database that is down fails every request without retry while a black-holed host blocks until the OS TCP timeout. Editing config/settings.example changes nothing, which is a trap for the first newcomer who tries it.

**Would repeat.** no

**Evidence.** [[code:src/repo/orders_repo.py@fb63e78#L7-L9]] [[code:src/service/orders.py@fb63e78#L5-L7]] [[code:src/api/orders_handler.py@fb63e78#L10-L16]] [[code:config/settings.example@fb63e78#L1-L2]]

## Ship no logging, metrics or tracing

**Decision.** There is no logging call, counter, span or audit record anywhere in src/. Retries are swallowed silently, authorization denials raise Forbidden without a record, and the deploy script writes no marker. The README's two-sentence Operations section is the entire runbook; the systemd journal is the only implicit sink and the code never writes to it.

**Alternatives.** Standard-library logging with a handler configured at the entry point, logging at minimum each retry, each Forbidden and each failed insert; Counters or metrics for retry rate, authz denials and connection count, which is what would have surfaced the duplicate-order incident while it was happening; An audit table recording who placed each order, separate from the body-supplied user_id; A deploy marker (commit sha and timestamp) written on the host by deploy.sh, so incidents can be correlated with releases

**Consequences.** The retry rate, the one signal that would have revealed duplicate orders in production, is unobservable, so the incident could only be found from the data itself or from customers, and the retry count sat wrong for six days before anyone noticed. Header-spoofing attempts against X-User leave no trace anywhere the service controls, and because orders records only the client-supplied user_id, a fraudulent order is indistinguishable from a legitimate one after the fact. With no deploy record and no version endpoint, an incident cannot be tied to what was deployed when except from memory; the durable account of the one incident this repository has had is a commit subject line.

**Would repeat.** no

**Evidence.** [[code:src/repo/orders_repo.py@fb63e78#L11-L18]] [[code:src/auth/authz.py@fb63e78#L8-L10]] [[code:README.md@fb63e78#L6-L9]] [[commit:27caac59e7c6dec5425b6e2bb60f0f23e7cac3bc]]

## Pin two dependencies exactly in requirements.txt and install them nowhere

**Decision.** requirements.txt pins requests==2.19.0 and psycopg2==2.8.6 with exact versions, no hashes, no lock file and no transitive pins. Nothing installs it: CI runs the smoke test with the runner's system python3 and no pip install, and deploy.sh copies only src/, so the versions actually present on a host are undefined.

**Alternatives.** A lock file (pip-tools, Poetry or uv) pinning the full transitive set with hashes; A pip install -r requirements.txt step in CI, so the pins are at least exercised once per push; Shipping requirements.txt with the deploy and installing it before the restart, or building a container image; Dropping requests, which no module imports, and moving psycopg2 to a maintained 2.9.x

**Consequences.** requests 2.19.0 (June 2018) is end-of-life and OSV lists five advisories against it, including the high-severity CVE-2018-18074 Authorization-header leak, and it drags urllib3 1.23 in transitively, which a scanner reading only the manifest never sees; nothing in src/ imports requests, so the right remediation is deleting the line rather than upgrading. psycopg2 2.8.6 has no package-level advisories but is the last of an end-of-life series whose classifiers stop at Python 3.8, and it is the source distribution, so pip install needs libpq headers and may not build on a current interpreter. Because no pipeline ever installs the file, the first person to run pip install -r requirements.txt on a modern machine is the first to discover that, and the host's actual versions are unverified by anything.

**Would repeat.** no

**Evidence.** [[code:requirements.txt@fb63e78#L1-L2]] [[code:.github/workflows/ci.yml@fb63e78#L6-L8]] [[code:deploy/deploy.sh@fb63e78#L5-L6]] [[code:src/repo/orders_repo.py@fb63e78#L1-L4]]
