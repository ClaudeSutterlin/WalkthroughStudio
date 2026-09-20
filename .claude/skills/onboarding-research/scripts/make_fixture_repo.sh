#!/usr/bin/env bash
# Builds the deterministic fixture repository used by the onboarding selftest
# (`--selftest-onboarding <fixtureRepo> <outDir>`) and by the Research Packet
# producer skill's own test. Every author, email and date is fixed, so the head
# SHA is stable across machines; `fixtureRepoProbe` asserts the facts below.
#
#   scripts/make-fixture-repo.sh /tmp/fixture-repo
#
# Shape (see docs/onboarding/ARCHITECTURE.md section 9):
#   two authors: Ada Lovelace (8 commits), Grace Hopper (4 commits)
#   src/api/orders_handler.py   entry point, calls authz, TODO about idempotency
#   src/auth/authz.py           authorization check
#   src/service/orders.py       business logic
#   src/repo/orders_repo.py     touched in 6 commits (the hotspot), one hotfix, one revert
#   db/schema.sql               users (email = PII), orders; TODO referencing migration 002
#   db/migrations/001_orders.sql, 002_split_addresses.sql (002 not applied to schema.sql)
#   .github/workflows/ci.yml    runs tests/test_orders.sh
#   deploy/deploy.sh            untouched since commit 1
#   requirements.txt            requests==2.19.0 (old, known-vulnerable pin)
#   tests/test_orders.sh        prints PASS
#   config/settings.example     FAKE_SECRET=sk-test-fixture-0001 (secret-leak probe string)
#   templates/email.tmpl        contains {{ user.name }} (placeholder-escaping probe)
#   vendor/                     generated code the packet must list as unread
set -euo pipefail

dest="${1:?usage: make-fixture-repo.sh <dir>}"
rm -rf "$dest"
mkdir -p "$dest"
cd "$dest"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q -b main .
git config commit.gpgsign false
git config core.autocrlf false

ADA_NAME="Ada Lovelace";  ADA_EMAIL="ada@example.com"
GRACE_NAME="Grace Hopper"; GRACE_EMAIL="grace@example.com"
day=0
commit() { # commit <author> <message>
  local who="$1"; shift
  local name email
  if [ "$who" = ada ]; then name="$ADA_NAME"; email="$ADA_EMAIL"; else name="$GRACE_NAME"; email="$GRACE_EMAIL"; fi
  day=$((day + 3))
  local date
  date="$((1735725600 + day * 86400)) +0000"   # 2025-01-01T10:00Z plus N days, git raw format
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_DATE="$date" \
  GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_DATE="$date" \
    git commit -q --allow-empty -m "$*"
}

# ---- commit 1 (Ada): skeleton ------------------------------------------------
mkdir -p src/api src/service src/repo db deploy config
cat > README.md <<'R'
# Fixture Orders Service

A tiny order service used as a test fixture. Run tests with `tests/test_orders.sh`.
Deploy with `deploy/deploy.sh <env>`.
R
cat > requirements.txt <<'R'
requests==2.19.0
psycopg2==2.8.6
R
cat > src/api/orders_handler.py <<'P'
"""HTTP entry point for orders."""
from src.service.orders import OrderService


def handle_create_order(request):
    service = OrderService()
    return service.create(request.json["user_id"], request.json["items"])


def handle_get_order(request, order_id):
    service = OrderService()
    return service.get(order_id)
P
cat > src/service/orders.py <<'P'
"""Order business logic."""
from src.repo.orders_repo import OrdersRepo


class OrderService:
    def __init__(self):
        self.repo = OrdersRepo()

    def create(self, user_id, items):
        total = sum(item["price"] * item["qty"] for item in items)
        return self.repo.insert(user_id, items, total)

    def get(self, order_id):
        return self.repo.fetch(order_id)
P
cat > src/repo/orders_repo.py <<'P'
"""Persistence for orders (raw SQL)."""
import psycopg2


class OrdersRepo:
    def __init__(self):
        self.conn = psycopg2.connect("dbname=orders")

    def insert(self, user_id, items, total):
        cur = self.conn.cursor()
        cur.execute("INSERT INTO orders (user_id, total) VALUES (%s, %s) RETURNING id", (user_id, total))
        order_id = cur.fetchone()[0]
        self.conn.commit()
        return {"id": order_id, "total": total}

    def fetch(self, order_id):
        cur = self.conn.cursor()
        cur.execute("SELECT id, user_id, total FROM orders WHERE id = %s", (order_id,))
        row = cur.fetchone()
        return {"id": row[0], "user_id": row[1], "total": row[2]}
P
cat > db/schema.sql <<'S'
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  email TEXT NOT NULL,          -- PII
  address TEXT
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  total NUMERIC(10, 2) NOT NULL
);
S
cat > deploy/deploy.sh <<'D'
#!/usr/bin/env bash
# Deploys by copying files to the host. No rollback.
set -e
env="${1:?env}"
scp -r src "deploy@${env}.example.com:/srv/orders/"
ssh "deploy@${env}.example.com" "sudo systemctl restart orders"
D
chmod +x deploy/deploy.sh
cat > config/settings.example <<'C'
DATABASE_URL=postgres://orders:orders@localhost/orders
FAKE_SECRET=sk-test-fixture-0001
C
git add -A
commit ada "Initial orders service: handler, service, repo, schema, deploy script"

# ---- commit 2 (Ada): authz --------------------------------------------------
mkdir -p src/auth
cat > src/auth/authz.py <<'P'
"""Authorization checks."""


class Forbidden(Exception):
    pass


def require_user(request, user_id):
    if request.headers.get("X-User") != str(user_id):
        raise Forbidden("user mismatch")
P
cat > src/api/orders_handler.py <<'P'
"""HTTP entry point for orders."""
from src.auth.authz import require_user
from src.service.orders import OrderService


def handle_create_order(request):
    user_id = request.json["user_id"]
    require_user(request, user_id)
    service = OrderService()
    return service.create(user_id, request.json["items"])


def handle_get_order(request, order_id):
    service = OrderService()
    return service.get(order_id)
P
git add -A
commit ada "Add authorization check to order creation"

# ---- commit 3 (Grace): CI + tests -------------------------------------------
mkdir -p .github/workflows tests
cat > .github/workflows/ci.yml <<'Y'
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: tests/test_orders.sh
Y
cat > tests/test_orders.sh <<'T'
#!/usr/bin/env bash
# Smoke test: the modules import and the total math is right.
set -e
python3 - <<'PY'
items = [{"price": 2.5, "qty": 2}, {"price": 1.0, "qty": 1}]
assert sum(i["price"] * i["qty"] for i in items) == 6.0
PY
echo PASS
T
chmod +x tests/test_orders.sh
git add -A
commit grace "Add CI workflow and smoke test"

# ---- commit 4 (Ada): repo list ----------------------------------------------
cat >> src/repo/orders_repo.py <<'P'

    def list_for_user(self, user_id):
        cur = self.conn.cursor()
        cur.execute("SELECT id FROM orders WHERE user_id = %s", (user_id,))
        ids = [row[0] for row in cur.fetchall()]
        return [self.fetch(order_id) for order_id in ids]
P
git add -A
commit ada "Add list_for_user to the orders repo"

# ---- commit 5 (Ada): hotfix -------------------------------------------------
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("src/repo/orders_repo.py")
s = p.read_text()
s = s.replace('''        cur.execute("SELECT id FROM orders WHERE user_id = %s", (user_id,))
        ids = [row[0] for row in cur.fetchall()]
        return [self.fetch(order_id) for order_id in ids]''',
'''        # hotfix: one query instead of N+1 fetches
        cur.execute("SELECT id, user_id, total FROM orders WHERE user_id = %s", (user_id,))
        return [{"id": r[0], "user_id": r[1], "total": r[2]} for r in cur.fetchall()]''')
p.write_text(s)
PY
git add -A
commit ada "hotfix: list_for_user issued N+1 queries under load"

# ---- commit 6 (Grace): migration 001 ---------------------------------------
mkdir -p db/migrations
cat > db/migrations/001_orders.sql <<'S'
-- applied
ALTER TABLE orders ADD COLUMN created_at TIMESTAMP DEFAULT now();
S
cat >> db/schema.sql <<'S'

-- 001_orders.sql
ALTER TABLE orders ADD COLUMN created_at TIMESTAMP DEFAULT now();
S
git add -A
commit grace "Add created_at to orders (migration 001)"

# ---- commit 7 (Ada): retries in repo, service passes context ----------------
python3 - <<'PY'
import pathlib
p = pathlib.Path("src/repo/orders_repo.py")
s = p.read_text()
s = s.replace('import psycopg2\n', 'import time\n\nimport psycopg2\n')
s = s.replace('''    def insert(self, user_id, items, total):
        cur = self.conn.cursor()''', '''    def insert(self, user_id, items, total):
        # retried without idempotency key: a timeout after commit double-inserts
        for attempt in range(3):
            try:
                return self._insert_once(user_id, total)
            except psycopg2.OperationalError:
                time.sleep(0.1 * (attempt + 1))
        raise RuntimeError("insert failed after retries")

    def _insert_once(self, user_id, total):
        cur = self.conn.cursor()''')
p.write_text(s)
PY
git add -A
commit ada "Retry order inserts on transient database errors"

# ---- commit 8 (Grace): migration 002 written, not applied -------------------
cat > db/migrations/002_split_addresses.sql <<'S'
-- NOT yet applied to schema.sql (see TODO there)
CREATE TABLE addresses (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  line1 TEXT, city TEXT, country TEXT
);
ALTER TABLE users DROP COLUMN address;
S
cat >> db/schema.sql <<'S'

-- TODO: apply 002_split_addresses.sql; users.address is still read by src/service
S
git add -A
commit grace "Draft migration 002: split addresses into their own table"

# ---- commit 9 (Ada): revert part of the retry -------------------------------
python3 - <<'PY'
import pathlib
p = pathlib.Path("src/repo/orders_repo.py")
s = p.read_text()
s = s.replace('for attempt in range(3):', 'for attempt in range(2):  # reverted from 3: too many double inserts')
p.write_text(s)
PY
git add -A
commit ada "Revert retry count to 2 after duplicate orders in production"

# ---- commit 10 (Ada): email template ---------------------------------------
mkdir -p templates
cat > templates/email.tmpl <<'T'
Hello {{ user.name }},

Your order {{ order.id }} for {{ order.total }} was received.
T
git add -A
commit ada "Add order confirmation email template"

# ---- commit 11 (Grace): docs ----------------------------------------------
cat >> README.md <<'R'

## Operations

There is no rollback in `deploy/deploy.sh`; redeploy the previous commit instead.
Migrations are applied by hand; see `db/migrations/`.
R
mkdir -p vendor/generated
cat > vendor/generated/client_pb2.py <<'P'
# Generated by protoc. DO NOT EDIT.
DESCRIPTOR = b"\x0a\x06orders"
P
git add -A
commit grace "Document operations and vendor the generated client"

# ---- commit 12 (Ada): idempotency TODO + repo touch -------------------------
python3 - <<'PY'
import pathlib
p = pathlib.Path("src/api/orders_handler.py")
s = p.read_text()
s = s.replace('def handle_create_order(request):', 'def handle_create_order(request):\n    # TODO: idempotency key; retries in the repo can double-insert')
p.write_text(s)
p = pathlib.Path("src/repo/orders_repo.py")
s = p.read_text()
s = s.replace('"""Persistence for orders (raw SQL)."""', '"""Persistence for orders (raw SQL). Connection is opened per instance and never closed."""')
p.write_text(s)
PY
git add -A
commit ada "Note idempotency gap in the handler; clarify repo connection lifetime"

echo "fixture repo at $dest"
echo "head: $(git rev-parse HEAD)"
echo "commits: $(git rev-list --count HEAD)"
git shortlog -sn --no-merges HEAD | sed 's/^/  /'
