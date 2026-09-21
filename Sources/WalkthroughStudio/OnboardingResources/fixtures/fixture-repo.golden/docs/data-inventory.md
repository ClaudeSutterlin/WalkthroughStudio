---
id: data-inventory
title: Data inventory
minutes: 4
evidence: [map-db, map-src]
order: 9
---

# Data inventory

## Entities

- The users table has three columns (id SERIAL PK, email TEXT NOT NULL, address TEXT) and stores personal data in plaintext. [[fact:F-map-db-002]] [[code:db/schema.sql@fb63e78#L1-L5]]
- The orders table stores one row per order with id, user_id (FK to users), total NUMERIC(10,2), and created_at added by migration 001; there is no line-item table. [[fact:F-map-db-005]] [[code:db/schema.sql@fb63e78#L7-L14]]
- The planned addresses table (id, user_id FK, line1, city, country) would hold one or more postal addresses per user; it does not exist in any applied schema yet. [[fact:F-map-db-012]] [[code:db/migrations/002_split_addresses.sql@fb63e78#L2-L6]]
- The orders table is the only entity src/ reads or writes; the repo writes user_id and total and reads id, user_id, total, never touching created_at or the users table. [[fact:F-map-src-035]] [[code:src/repo/orders_repo.py@fb63e78#L22]]

## Fields

- users.email is the only column explicitly annotated as PII in the schema; it is NOT NULL but has no UNIQUE constraint, so duplicate accounts per email are possible. [[fact:F-map-db-003]] [[code:db/schema.sql@fb63e78#L3]]
- users.address is a nullable free-text column that migration 002 is written to drop in favor of a separate addresses table, but the drop has not been applied. [[fact:F-map-db-004]] [[code:db/schema.sql@fb63e78#L4]]
- orders.total is NUMERIC(10,2) NOT NULL, capping any order at 99,999,999.99, while the service computes it as a Python float sum of price*qty that is inserted without rounding. [[fact:F-map-db-006]] [[code:db/schema.sql@fb63e78#L10]]
- orders.created_at (TIMESTAMP without time zone, DEFAULT now()) was added by migration 001 but no code in src/ ever reads it: the repo's SELECTs return only id, user_id, total. [[fact:F-map-db-007]] [[code:db/schema.sql@fb63e78#L13-L14]]
- order.total is interpolated raw into the email with no currency symbol or formatting; the backing column is NUMERIC(10,2) and the repo returns it unformatted. [[fact:F-map-ops-021]] [[code:templates/email.tmpl@fb63e78#L3]]
- orders.created_at (added by migration 001 with DEFAULT now()) is populated by the database but never selected or returned by any repo method, so callers cannot see when an order was placed. [[fact:F-map-src-036]] [[code:src/repo/orders_repo.py@fb63e78#L29]]
- orders.created_at was added on 2025-01-19 by ALTER TABLE ... ADD COLUMN ... DEFAULT now(), which in PostgreSQL stamps every pre-existing row with the value of now() at migration time, so any order placed between the 2025-01-04 initial schema and the migration carries the time 001 was run, not the time it was placed. [[fact:F-lens-data-migrations-005]] [[code:db/migrations/001_orders.sql@fb63e78#L1-L2]]
- orders.created_at is TIMESTAMP without time zone and nullable: now() is stored in the connection's session TimeZone with the zone discarded, so values written from servers or environments with different TimeZone settings are not comparable, and an explicit NULL is accepted because the ALTER added no NOT NULL. [[fact:F-lens-data-migrations-006]] [[code:db/schema.sql@fb63e78#L13-L14]]
- PII is wider than the single '-- PII' annotation on users.email: users.address is a postal address, the planned addresses.line1/city/country are postal-address fields with no annotation in the migration, and orders.user_id plus total and created_at link purchase history to a person, so every table in the store carries personal data. [[fact:F-lens-data-migrations-012]] [[code:db/schema.sql@fb63e78#L3-L4]]
- Every column of the planned addresses table except id is nullable (user_id, line1, city, country) and there is no UNIQUE or 'is_primary' marker, so once 002 is applied a user may have zero, one or many addresses including entirely empty rows with no owner, and no code exists to choose among them. [[fact:F-lens-data-migrations-013]] [[code:db/migrations/002_split_addresses.sql@fb63e78#L2-L6]]

## Migrations

- Migration 001 adds orders.created_at and is marked applied; its exact ALTER is also copied verbatim into schema.sql under a '-- 001_orders.sql' comment. [[fact:F-map-db-009]] [[code:db/migrations/001_orders.sql@fb63e78#L1-L2]]
- Migration 002 (create addresses table, drop users.address) is written but not applied: its own header and the TODO in schema.sql both say so, and schema.sql still defines users.address with no addresses table. [[fact:F-map-db-011]] [[code:db/migrations/002_split_addresses.sql@fb63e78#L1-L7]]
- The README's statement that migrations are applied by hand matches the code: db/migrations/002_split_addresses.sql exists but schema.sql carries a TODO saying it has not been applied and src still reads users.address. [[fact:F-map-ops-024]] [[code:README.md@fb63e78#L9]]
- Migration ledger at HEAD: 001 (orders.created_at, 2025-01-19, Grace Hopper) is written, marked applied and folded into schema.sql; 002 (addresses split, 2025-01-25, Grace Hopper) is written, marked not applied and absent from schema.sql, and no commit in the remaining 12 days of history (to 2025-02-06) touched it or referred to it again. [[fact:F-lens-data-migrations-014]] [[code:db/migrations/001_orders.sql@fb63e78#L1]]
- Three schema changes are implied by code or TODOs but have no migration file: an order_items table (the service accepts items that the INSERT discards), a users.name column (required by templates/email.tmpl), and an idempotency key with a unique index on orders (named in both TODOs), so 002 is not the only half-finished data work and the migration folder understates the schema debt. [[fact:F-lens-data-migrations-019]] [[code:src/service/orders.py@fb63e78#L9-L11]]
- The repository has exactly two TODO markers plus one 'NOT yet applied' header, and all three point at unfinished data-layer work (idempotency key, address split) with no issue number, owner or date, so the only tracking of unfinished work is comments in three files. [[fact:F-lens-data-migrations-020]] [[code:src/api/orders_handler.py@fb63e78#L7]]
- There are no feature flags, environment toggles or v1/v2 code paths anywhere in src/; the only dual state in the system is at the schema level (schema.sql versus the unapplied 002), and the one behavioural reversal in history (retry count 3 to 2) was done by editing a literal in a hotfix commit rather than via a flag. [[fact:F-lens-data-migrations-021]] [[code:src/repo/orders_repo.py@fb63e78#L13]]
