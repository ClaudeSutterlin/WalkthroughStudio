---
id: test-truth
title: Test truth
minutes: 3
evidence: [lens-security-tests, map-ci, map-db, map-ops, map-src]
order: 8
---

# Test truth

## What the tests actually cover

- The test asserts only that a hard-coded list of two items sums to 6.0 using arithmetic written inside the test itself; it never imports or calls src/service/orders.py, so OrderService.create's total computation is not actually exercised. [[fact:F-map-ci-009]] [[code:tests/test_orders.sh@fb63e78#L4-L7]]
- The script's own comment claims it checks that 'the modules import', but the code contains no import of any project module, so the comment overstates what the test does. [[fact:F-map-ci-010]] [[code:tests/test_orders.sh@fb63e78#L2]]
- No test covers the HTTP handlers, authorization check, or repository layer: handle_create_order, require_user, and OrdersRepo.insert (including its retry loop) have zero test coverage. [[fact:F-map-ci-011]] [[code:tests/test_orders.sh@fb63e78#L4-L7]]
- The test uses floating-point equality (== 6.0) on a sum of floats; it passes for these specific values but the pattern is fragile for other price/qty combinations. [[fact:F-map-ci-013]] [[code:tests/test_orders.sh@fb63e78#L5-L6]]
- No test requires a database or network: the smoke test is fully hermetic, which is why CI can run it without services, but it also means the psycopg2 connection in OrdersRepo is never exercised anywhere. [[fact:F-map-ci-015]] [[code:tests/test_orders.sh@fb63e78#L4-L7]]
- No test or CI step exercises the schema: tests/test_orders.sh only asserts Python arithmetic and the CI workflow runs just that script, so schema.sql and both migrations are never loaded into a database anywhere in the pipeline. [[fact:F-map-db-024]] [[code:tests/test_orders.sh@fb63e78#L1-L8]]
- The README's 'Run tests with tests/test_orders.sh' overstates what exists: the script never imports any src module (despite its own comment) and only asserts arithmetic on a literal list, so no handler, service, repo or authz code is exercised. [[fact:F-map-ops-025]] [[code:README.md@fb63e78#L3]]
- No test imports any src/ module: tests/test_orders.sh re-implements the sum(price*qty) expression in a heredoc and asserts on it, so the handler, authz, service and repo have zero test coverage despite the script's comment claiming 'the modules import'. [[fact:F-map-src-023]] [[code:tests/test_orders.sh@fb63e78#L2-L8]]
- The smoke test is green precisely because it does not do what its comment says: in CI's conditions (checkout, no pip install) importing src.api.orders_handler fails with ModuleNotFoundError for psycopg2, so making the 'modules import' claim true would turn CI red until CI installs requirements.txt. [[fact:F-lens-security-tests-010]] [[code:tests/test_orders.sh@fb63e78#L2-L7]]
- The absence of auth tests is not an infrastructure problem: require_user and both handlers take a duck-typed request (only .headers.get and .json are used) and perform no I/O before the authz decision, so missing-header, mismatched-header and type-coercion cases could be covered with a plain object and no database or framework. [[fact:F-lens-security-tests-012]] [[code:src/auth/authz.py@fb63e78#L8-L10]]
- The service and repo have no test seam: OrderService.__init__ hard-constructs OrdersRepo, whose __init__ connects to a hard-coded 'dbname=orders', so testing create()'s total computation, the retry loop or fetch requires either a live PostgreSQL database named orders or monkeypatching psycopg2.connect, which explains why the smoke test re-implements the formula instead of calling it. [[fact:F-lens-security-tests-013]] [[code:src/service/orders.py@fb63e78#L6-L7]]
- Both production-incident commits (the N+1 hotfix and the retry-count revert) changed only src/repo/orders_repo.py and added no test, so neither the single-query shape of list_for_user nor the attempt count of insert is pinned by anything; a future edit could reintroduce either regression and CI would stay green. [[fact:F-lens-security-tests-014]] [[code:src/repo/orders_repo.py@fb63e78#L13]]
- There are no skipped, quarantined or flaky tests because there is no test framework at all: no pytest or unittest, no test dependencies in requirements.txt, and the entire suite is one assert inside a bash heredoc, so adding the first real test also means choosing and wiring a runner, a fixture strategy for PostgreSQL, and a pip install step in CI. [[fact:F-lens-security-tests-015]] [[code:tests/test_orders.sh@fb63e78#L1-L8]]

## Checks run during research

No build or test command was executed; the producer reported none.
