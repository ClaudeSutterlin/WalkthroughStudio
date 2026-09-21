---
id: dependencies
title: Dependency register
minutes: 2
evidence: [lens-dependencies, map-ci, map-ops]
order: 6
---

# Dependency register

## Declared dependencies

| Package | Version | License | End of life | Known CVEs |
|---|---|---|---|---|
| `requests` | 2.19.0 | Apache-2.0 | end-of-life | CVE-2018-18074, CVE-2023-32681, CVE-2024-35195, CVE-2024-47081, CVE-2026-25645 |
| `psycopg2` | 2.8.6 | LGPL-3.0-or-later | end-of-life | none found |

## Findings

- The only external action used by CI is actions/checkout pinned to the floating major tag v4, not to a commit SHA. [[fact:F-map-ci-004]] [[code:.github/workflows/ci.yml@fb63e78#L7]]
- requests is pinned to 2.19.0, a mid-2018 release that predates the fixes for CVE-2018-18074 (Authorization header leaked on HTTPS-to-HTTP redirect, fixed in 2.20.0) and CVE-2023-32681 (Proxy-Authorization leak, fixed in 2.31.0). [[fact:F-map-ops-029]] [[code:requirements.txt@fb63e78#L1]]
- requests is declared but never imported anywhere in src/, so the pin is dead weight that still drags a vulnerable version into every install. [[fact:F-map-ops-030]] [[code:requirements.txt@fb63e78#L1]]
- psycopg2 is pinned to 2.8.6 (late 2020) and is the single runtime dependency actually used, by src/repo/orders_repo.py for the Postgres connection and OperationalError handling. [[fact:F-map-ops-031]] [[code:requirements.txt@fb63e78#L2]]
- requests 2.19.0 is licensed Apache-2.0 (PyPI metadata 'Apache 2.0', classifier 'OSI Approved :: Apache Software License'), which imposes no copyleft obligation on this service. [[fact:F-lens-dependencies-001]] [[code:requirements.txt@fb63e78#L1]]
- requests 2.19.0 (uploaded 2018-06-12) was superseded by 2.19.1 two days later and by 2.20.0 on 2018-10-18; the project maintains no LTS branches, so with 2.34.2 current (2026-05-14) the 2.19 line is end-of-life and every fix since requires a minor-version jump. [[fact:F-lens-dependencies-002]] [[code:requirements.txt@fb63e78#L1]]
- psycopg2 2.8.6 is LGPL-licensed (PyPI: 'LGPL with exceptions'; SPDX LGPL-3.0-or-later with a linking exception for OpenSSL), which is fine for an unmodified pip-installed dependency but is the only copyleft component in the manifest. [[fact:F-lens-dependencies-006]] [[code:requirements.txt@fb63e78#L2]]
- psycopg2 2.8.6 (2020-09-06) is the final release of the 2.8 series, whose Python classifiers stop at 3.8; the 2.9 series began 2021-06-16 and is at 2.9.13 (2026-09-09) declaring Python 3.10-3.15, so the pinned line is end-of-life and undeclared on any Python a current runner ships. [[fact:F-lens-dependencies-007]] [[code:requirements.txt@fb63e78#L2]]
- requirements.txt pins only the two direct packages with exact versions and no hashes, lock file or transitive pins, so two installs from the same file can differ in urllib3, idna, chardet and certifi (the last unbounded) and the manifest gives no reproducibility guarantee. [[fact:F-lens-dependencies-010]] [[code:requirements.txt@fb63e78#L1-L2]]
- The code uses only the stable DB-API subset of psycopg2 (connect with a DSN string, cursor, execute with %s params, fetchone, fetchall, commit, and the OperationalError class), all unchanged between 2.8 and 2.9, so moving the pin to a current 2.9.x is a low-risk edit whose main effect is Python-version support and a fresher libpq build. [[fact:F-lens-dependencies-011]] [[code:src/repo/orders_repo.py@fb63e78#L4-L9]]
