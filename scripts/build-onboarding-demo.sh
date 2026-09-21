#!/usr/bin/env bash
# Build a browsable onboarding package from the checked-in fixture Research Packet
# and serve it, so the whole research-to-viewer pipeline can be seen without Swift.
#
#   scripts/build-onboarding-demo.sh [outDir] [port]
#
# Steps: generate the deterministic fixture repository, validate the packet against
# it, project the packet into diagrams, registers, traces, a hub index and the cited
# source files, drop the hub viewer beside them, then serve.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${1:-/tmp/onboarding-demo}"
PORT="${2:-8731}"
FIXTURE="$OUT/fixture-repo"
PKG="$OUT/package"
PACKET="$ROOT/Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet"
HUB="$ROOT/Sources/WalkthroughStudio/OnboardingResources/hub"

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> fixture repository"
scripts/make-fixture-repo.sh "$FIXTURE" </dev/null | sed 's/^/    /'

echo "==> validate the packet against it"
python3 scripts/validate-packet.py "$PACKET" --repo "$FIXTURE" | tail -2 | sed 's/^/    /'

echo "==> project the packet into deliverables"
python3 .claude/skills/onboarding-research/scripts/project_packet.py \
  --packet "$PACKET" --out "$PKG" --repo "$FIXTURE" | sed 's/^/    /'

echo "==> assemble the viewer"
cp "$HUB/hub.html" "$HUB/hub.css" "$HUB/hub.js" "$PKG/"
mkdir -p "$PKG/vendor"
cp "$HUB/vendor/mermaid.min.js" "$PKG/vendor/"
cp -R "$PACKET" "$PKG/packet"          # the hub links facts back to the packet
echo "    hub, stylesheet, script, mermaid and packet copied"

echo
echo "Package: $PKG"
echo "Open:    http://127.0.0.1:$PORT/hub.html"
echo "Serving (control-C to stop)..."
cd "$PKG" && exec python3 -m http.server "$PORT"
