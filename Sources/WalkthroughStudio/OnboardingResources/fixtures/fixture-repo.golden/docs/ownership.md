---
id: ownership
title: Ownership and bus factor
minutes: 3
evidence: [map-ci, map-db, map-ops, map-src]
order: 4
---

# Ownership and bus factor

## Per directory

| Directory | Commits | Top author | Share | Bus factor |
|---|---|---|---|---|
| `.` | 2 | Grace Hopper | 50% | 1 |
| `.github/` | 1 | Grace Hopper | 100% | 1 |
| `config/` | 1 | Ada Lovelace | 100% | 1 |
| `db/` | 3 | Grace Hopper | 67% | 1 |
| `deploy/` | 1 | Ada Lovelace | 100% | 1 |
| `src/` | 7 | Ada Lovelace | 100% | 1 |
| `templates/` | 1 | Ada Lovelace | 100% | 1 |
| `tests/` | 1 | Grace Hopper | 100% | 1 |
| `vendor/` | 1 | Grace Hopper | 100% | 1 |

## What the history says

- The .github/ directory has a single author, Grace Hopper (1 commit, 100% share), giving it a bus factor of 1. [[fact:F-map-ci-016]] [[code:.github/workflows/ci.yml@fb63e78#L1-L8]]
- The tests/ directory has a single author, Grace Hopper (1 commit, 100% share), giving it a bus factor of 1. [[fact:F-map-ci-017]] [[code:tests/test_orders.sh@fb63e78#L1-L8]]
- db/ has a bus factor of 1: Grace Hopper authored 2 of its 3 commits (both migrations) and Ada Lovelace the initial schema, so schema evolution knowledge sits with one person who has not touched the code in src/. [[fact:F-map-db-022]] [[code:db/@fb63e78]]
- deploy/ has a single author, Ada Lovelace, from one commit in the initial import on 2025-01-04, giving it a bus factor of 1 and no changes since. [[fact:F-map-ops-010]] [[code:deploy/deploy.sh@fb63e78]]
- config/ has a single author, Ada Lovelace, from the initial import commit on 2025-01-04, and has not been touched since (bus factor 1). [[fact:F-map-ops-016]] [[code:config/settings.example@fb63e78]]
- templates/ was added in a single commit by Ada Lovelace on 2025-01-31 and has one author (bus factor 1). [[fact:F-map-ops-022]] [[code:templates/email.tmpl@fb63e78]]
- The root files (README.md, requirements.txt) are split evenly between Ada Lovelace and Grace Hopper at one commit each, but with only two commits total the effective bus factor is 1. [[fact:F-map-ops-028]] [[code:requirements.txt@fb63e78#L1-L2]]
- All 7 commits touching src/ are by Ada Lovelace, so the directory has a bus factor of 1 and no second person has ever changed the api, auth, service or repo layers. [[fact:F-map-src-009]] [[code:src/@fb63e78]]
- ci.yml and tests/test_orders.sh were created together in one commit on 2025-01-10 and never touched again, while src/ received seven commits including a hotfix and a revert, so the test suite has not kept pace with the code it is meant to guard. [[fact:F-map-ci-018]] [[code:.github/workflows/ci.yml@fb63e78#L8]]
- db/schema.sql is the third most-changed file (3 of 12 commits) and one of only two files edited by both authors, last touched 2025-01-25 when migration 002 was drafted. [[fact:F-map-db-021]] [[code:db/schema.sql@fb63e78#L1-L16]]
- README.md is the only file in the ops scope with more than one commit or author: created by Ada Lovelace in the initial import and rewritten by Grace Hopper on 2025-02-03 when the Operations section and the vendored client were added. [[fact:F-map-ops-027]] [[code:README.md@fb63e78#L6-L9]]
- src/api/orders_handler.py has 3 commits from a single author (Ada Lovelace), last touched 2025-02-06 at HEAD, which added the idempotency TODO. [[fact:F-map-src-008]] [[code:src/api/orders_handler.py@fb63e78#L1-L16]]
- Authorization was not part of the initial service and was added three days later in a single commit (2025-01-07) that has never been revised since. [[fact:F-map-src-016]] [[code:src/auth/authz.py@fb63e78#L1-L10]]
- src/repo/orders_repo.py is the repository's top hotspot: 6 of 12 commits touch it, all by one author (Ada Lovelace), including one hotfix and one production revert, last touched 2025-02-06. [[fact:F-map-src-034]] [[code:src/repo/orders_repo.py@fb63e78#L1-L37]]
