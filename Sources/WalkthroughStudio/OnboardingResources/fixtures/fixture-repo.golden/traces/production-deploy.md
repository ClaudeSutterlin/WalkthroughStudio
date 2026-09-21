# Deploy code to an environment (deploy/deploy.sh <env>)

**Scenario.** An on-call engineer sitting at their laptop on commit fb63e78, with one uncommitted edit still in src/repo/orders_repo.py, runs `deploy/deploy.sh prod`: the script takes "prod" as $1, scp's the local src/ tree to deploy@prod.example.com:/srv/orders/, then ssh's to the same host and runs `sudo systemctl restart orders`.

## Hops

1. The script runs under `set -e` and takes its single input from `env="${1:?env}"`, which rejects only an empty argument — there is no allowlist of environments, no confirmation prompt, and no check of what commit or branch the operator has checked out. [[code:deploy/deploy.sh@fb63e78#L1-L4]]
2. `scp -r src "deploy@${env}.example.com:/srv/orders/"` uploads the operator's local working copy of src/ — a directory on disk, not a git ref — over the previous copy, so uncommitted edits ship, files deleted from src/ are never removed on the host, and requirements.txt, config/, templates/ and db/ are never sent at all. [[code:deploy/deploy.sh@fb63e78#L5-L5]]
3. `ssh "deploy@${env}.example.com" "sudo systemctl restart orders"` hard-restarts the one systemd unit and the script ends there, so ssh's exit status is the only success signal and nothing probes the service afterwards. [[code:deploy/deploy.sh@fb63e78#L6-L6]]
4. What comes back up is the freshly copied code: each OrdersRepo opens its own psycopg2 connection in __init__, and insert() retries twice on OperationalError with no idempotency key, so a create request cut off by the restart can be retried into a duplicate order. [[code:src/repo/orders_repo.py@fb63e78#L7-L18]]
5. The restarted process meets a database the deploy never touched — schema.sql has migration 001 folded in and a standing TODO that 002_split_addresses.sql is still unapplied — because db/ is outside what deploy.sh ships and migrations are run by hand. [[code:db/schema.sql@fb63e78#L13-L16]]

## The ten concerns

| Concern | Status | Evidence |
|---|---|---|
| entry | **present** | [[code:deploy/deploy.sh@fb63e78#L1-L6]] [[code:README.md@fb63e78#L4-L4]] |
| authorization | **absent** | [[code:deploy/deploy.sh@fb63e78#L4-L6]] [[code:.github/workflows/ci.yml@fb63e78#L1-L8]] |
| validation | **absent** | [[code:deploy/deploy.sh@fb63e78#L3-L6]] |
| businessLogic | **present** | [[code:deploy/deploy.sh@fb63e78#L5-L6]] |
| persistence | **present** | [[code:deploy/deploy.sh@fb63e78#L5-L5]] [[code:db/schema.sql@fb63e78#L13-L16]] |
| sideEffects | **present** | [[code:deploy/deploy.sh@fb63e78#L6-L6]] [[code:src/repo/orders_repo.py@fb63e78#L11-L18]] |
| failureHandling | **absent** | [[code:deploy/deploy.sh@fb63e78#L3-L6]] [[code:README.md@fb63e78#L6-L9]] |
| idempotency | **absent** | [[code:deploy/deploy.sh@fb63e78#L5-L6]] |
| timeoutsRetries | **absent** | [[code:deploy/deploy.sh@fb63e78#L5-L6]] [[code:src/repo/orders_repo.py@fb63e78#L13-L18]] |
| logging | **absent** | [[code:deploy/deploy.sh@fb63e78#L1-L6]] [[code:.github/workflows/ci.yml@fb63e78#L1-L8]] |

## What scares me

- The script ships whatever happens to be in the operator's local src/ directory rather than a git ref, so an unfinished edit or a stale branch on one laptop becomes production, and the only way to find out what is actually running is to ssh in and diff /srv/orders against the repository by hand.
- `sudo systemctl restart orders` is the entire rollout strategy: one unit, no second instance, no drain and no health check, so every deploy is a short outage and a deploy that crashes on import leaves the environment down until a customer or an external monitor notices.
- Because `set -e` only aborts, an interrupted run leaves the host half-updated — new files copied, old process still serving, or a restart into a partial copy — and the next run papers over it silently.
- The environment name is pasted straight into a hostname with nothing checking it, so `deploy/deploy.sh prod` and a fat-fingered `deploy/deploy.sh prod2` are equally acceptable and there is no confirmation step between typing it and the restart.
- CI only runs tests/test_orders.sh on push and never calls deploy.sh, so code can reach production on a commit that CI never ran — or that was never pushed at all.
- scp -r adds and overwrites but never deletes, so a file you believe you removed keeps sitting on the host and can keep being imported long after it left the repository.
- requirements.txt, config/ and db/ are never shipped, so pinned dependencies and schema on the host drift from the repository; migration 002_split_addresses.sql sitting unapplied is that gap in the open, and you would discover it as a runtime error on a column that is not there.
- Rollback means redeploying the previous commit by hand, which requires someone to know which commit was previously deployed — and nothing anywhere writes that down.
