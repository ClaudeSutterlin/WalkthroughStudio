---
id: observability
title: Observability
minutes: 1
evidence: [lens-deploy-ops, map-ci, map-src]
order: 11
---

# Observability

## What is visible in production

- CI produces no artifacts, coverage reports, or test-result uploads; the only signal is the job's pass/fail status and the PASS line in the log. [[fact:F-map-ci-019]] [[code:.github/workflows/ci.yml@fb63e78#L6-L8]]
- src/ contains no logging, metrics or tracing at all: retries, authz failures and insert failures happen silently, so the production duplicate-order incident could only have been detected from the data itself. [[fact:F-map-src-038]] [[code:src/repo/orders_repo.py@fb63e78#L14-L18]]
- A deploy leaves no trace: the script writes no deploy marker, timestamp, commit id or log line on the host or anywhere else, so an incident cannot be correlated with 'what was deployed when' except from people's memory. [[fact:F-lens-deploy-ops-009]] [[code:deploy/deploy.sh@fb63e78#L1-L6]]
- The retry loop swallows every psycopg2.OperationalError without logging, counting or re-raising it, so the retry rate (the one signal that would have revealed the duplicate-order incident while it was happening) is unobservable in production. [[fact:F-lens-deploy-ops-010]] [[code:src/repo/orders_repo.py@fb63e78#L13-L18]]
- Authorization denials are silent: require_user raises Forbidden with no log, counter or audit record, so a credential-stuffing or header-spoofing attempt against X-User leaves no trace anywhere the service controls. [[fact:F-lens-deploy-ops-011]] [[code:src/auth/authz.py@fb63e78#L8-L10]]
- The two-sentence Operations section of the README is the entire runbook: there are no alerts, dashboards, SLOs, on-call notes or incident procedures anywhere in the repository, and the systemd journal (stdout/stderr of the unit) is the only implicit log sink, which the code never writes to. [[fact:F-lens-deploy-ops-013]] [[code:README.md@fb63e78#L6-L9]]
- There is no health, readiness or version endpoint: the service exposes only create-order and get-order, so a load balancer, a post-deploy smoke check or an operator asking 'which build is live' has nothing to call. [[fact:F-lens-deploy-ops-023]] [[code:src/api/orders_handler.py@fb63e78#L6-L16]]
