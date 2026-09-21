---
id: coverage-report
title: Coverage report
minutes: 2
evidence: []
order: 16
---

# Operational scorecard

## Coverage of this research

| Measure | Value |
|---|---|
| Facts | 213 |
| Verified | 206 |
| Refuted (excluded from every register) | 5 |
| Critical paths traced | 4 of 10 candidates |
| Directories at level traced or verified | 9 of 9 |
| Commits mined | 12 |

## What was not read

- Every directory was read.

## Candidate paths not traced

- `ci-smoke-test`: Not a flow the business depends on: the workflow runs a hermetic arithmetic assert that imports no project module, protects no branch, produces no artifact and is never consumed by deploy.sh, so it gates nothing. Its facts (F-map-ci-*, F-lens-security-tests-010) are cited from the production-deploy and order-creation paths instead of traced separately.
- `order-confirmation-email`: No entry point exists at HEAD: nothing renders or sends the template, no template engine or mail client is declared, and the context it needs (user.name) has no backing column. It is an unwired asset (F-map-ops-019, F-lens-deploy-ops-019, F-lens-landmines-glossary-006), so there is no code path to follow hop by hop.
- `list-orders-for-user`: Unreachable from the HTTP surface: no handler or service calls list_for_user (F-map-src-032), so despite its N+1 hotfix history and missing index (F-map-db-008) there is no entry point to trace. Anyone exposing it must add require_user themselves (F-lens-landmines-glossary-011).
- `user-identity`: No such flow exists in the repository: nothing inserts into users, there is no authentication, and identity is a plain X-User header (F-map-src-013, F-lens-data-migrations-003). The only identity-related code, require_user, is traced as the authorization hop of order-creation.
- `grpc-client-stub`: Generated code imported by nothing, with no .proto source, protoc step or protobuf runtime in the repository (F-lens-deploy-ops-020, F-lens-landmines-glossary-007). vendor/ is inventoried only and must not be mapped or traced.
- `database-bootstrap`: A developer setup procedure rather than a business flow, and entirely unscripted: the README omits it, schema.sql plus the migrations folder conflict on 001, and no users seed exists so the first order fails on the FK (F-map-db-010, F-map-db-017, F-map-ops-026, F-lens-landmines-glossary-010). Its landmines are cited from the schema-migration and order-creation paths.
