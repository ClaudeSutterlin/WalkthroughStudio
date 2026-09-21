---
id: incident-patterns
title: Incident patterns
minutes: 1
evidence: [lens-deploy-ops, map-src]
order: 12
---

# Incident patterns

## From commit history and markers

- Duplicate orders occurred in production after the retry count was raised to 3; the fix was to revert to 2 attempts rather than add idempotency, so the failure mode remains and merely fires less often. [[fact:F-map-src-029]] [[code:src/repo/orders_repo.py@fb63e78#L13]]
- The retry count sat at 3 in production for six days (introduced 2025-01-22, reverted 2025-01-28) before duplicate orders were noticed, and with no logging, metrics or deploy record the only durable account of the incident is the revert commit's subject line. [[fact:F-lens-deploy-ops-012]] [[code:src/repo/orders_repo.py@fb63e78#L12-L13]]

## Notable commits

- Revert retry count to 2 after duplicate orders in production (Ada Lovelace, 2025-01-28) [[commit:27caac59e7c6dec5425b6e2bb60f0f23e7cac3bc]]
- hotfix: list_for_user issued N+1 queries under load (Ada Lovelace, 2025-01-16) [[commit:30bfa828b4b5a162bbb9c2bf9487ae82f3ace6c6]]
