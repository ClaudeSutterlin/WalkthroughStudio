#!/usr/bin/env python3
"""Assemble unit outputs into a Research Packet and compute coverage and counts.

    assemble_packet.py --packet <dir> --units <dir> [--repo <checkout>] [--model <name>] [--finished-at <iso>]

<dir> is the packet written by survey_repo.py (inventory, history, dependencies,
coverage and packet skeletons). <units> holds the research units' outputs:

    mappers/*.json    {"unit","facts":[...],"readPaths":[...],"skipped":[...]}
    lenses/*.json     {"unit","facts":[...],"readPaths":[...],"dependencies":[...]?,"glossary":[...]?}
    verdicts/*.json   {"verifier","verdicts":[{"id","verdict","reason","evidence":[...]}]}
    paths.json        {"candidates","paths":[...],"untraced":[...]}
    traces/*.json     trace objects (pathId, title, entry, scenario, hops, concerns, scaresMe, factIds)
    decisions.json    {"decisions":[...],"summary":"...","topFindings":[...]}
    checks.json       optional [{"check","status","reason","anchor"}]

Status rule per fact: two refuting verdicts with evidence -> refuted; at least one
confirming and no refuting -> verified; verdicts but no clear outcome -> unknown;
no verdicts -> proposed. Coverage levels: traced > verified > mapped > inventoried,
unread when nothing was read and no fact cites the directory. Runs the validator
at the end and exits with its status.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

CODE_RE = re.compile(r"^code:(?P<path>.+)@(?P<sha>[0-9a-f]{7,40})(?:#L(?P<a>\d+)(?:-L(?P<b>\d+))?)?$")
CONCERNS = ["entry", "authorization", "validation", "businessLogic", "persistence",
            "sideEffects", "failureHandling", "idempotency", "timeoutsRetries", "logging"]


def load_dir(d):
    out = []
    if d.is_dir():
        for p in sorted(d.glob("*.json")):
            out.append(json.loads(p.read_text()))
    return out


def top_of(path):
    return path.split("/", 1)[0] + "/" if "/" in path else "."


def code_path(anchor):
    m = CODE_RE.match(anchor or "")
    return m.group("path") if m else None


ANCHOR_PREFIXES = ("code:", "video:", "doc:", "diagram:", "trace:", "fact:", "commit:", "cmd:", "issue:", "url:")
BARE_CODE_RE = re.compile(r"^[^\s:]+@[0-9a-f]{7,40}(#L\d+(-L\d+)?)?$")
BARE_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def repair_anchor(raw, where, warnings):
    """Producers occasionally drop the scheme prefix. Repair the unambiguous
    cases (path@sha7#Lx -> code:..., a bare 40-hex sha -> commit:...) and drop
    anything else with a warning, so one sloppy agent cannot invalidate a packet."""
    if not isinstance(raw, str) or not raw.strip():
        warnings.append(f"{where}: dropped a non-string anchor")
        return None
    raw = raw.strip()
    if raw.startswith(ANCHOR_PREFIXES):
        return raw
    if BARE_CODE_RE.match(raw):
        warnings.append(f"{where}: added the missing 'code:' prefix to {raw}")
        return "code:" + raw
    if BARE_SHA_RE.match(raw):
        warnings.append(f"{where}: added the missing 'commit:' prefix to {raw}")
        return "commit:" + raw
    if raw.startswith("http://") or raw.startswith("https://"):
        warnings.append(f"{where}: added the missing 'url:' prefix to {raw}")
        return "url:" + raw
    warnings.append(f"{where}: dropped an unparseable anchor {raw!r}")
    return None


def repair_anchors(raws, where, warnings):
    out = []
    for i, a in enumerate(raws or []):
        fixed = repair_anchor(a, f"{where}[{i}]", warnings)
        if fixed:
            out.append(fixed)
    return out


def dump(path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--packet", required=True)
    ap.add_argument("--units", required=True)
    ap.add_argument("--repo")
    ap.add_argument("--model")
    ap.add_argument("--finished-at")
    a = ap.parse_args()
    pk, un = Path(a.packet), Path(a.units)
    warnings = []
    packet = json.loads((pk / "packet.json").read_text())
    head = packet["repo"]["headSHA"]
    inventory = json.loads((pk / "inventory.json").read_text())
    coverage = json.loads((pk / "coverage.json").read_text())
    dependencies = json.loads((pk / "dependencies.json").read_text())

    # ---- facts ---------------------------------------------------------------
    units = load_dir(un / "mappers") + load_dir(un / "lenses")
    facts, seen, read_paths = [], set(), set()
    for u in units:
        unit = u.get("unit", "unit")
        for p in u.get("readPaths", []):
            read_paths.add(p.strip("./") if p.startswith("./") else p)
        for i, f in enumerate(u.get("facts", []), 1):
            f = dict(f)
            fid = f.get("id") or f"F-{unit}-{i:03d}"
            while fid in seen:
                fid += "-dup"
                warnings.append(f"duplicate fact id renamed to {fid}")
            seen.add(fid)
            f["id"] = fid
            f.setdefault("producedBy", unit)
            f.setdefault("attributes", {})
            f.setdefault("verdicts", [])
            f.setdefault("status", "proposed")
            f.setdefault("confidence", 0.5)
            if f.get("kind") == "dataEntity":
                for k in ("pii", "rows", "retention"):
                    f["attributes"].setdefault(k, "unknown")
            ev = []
            for j, e in enumerate(f.get("evidence", [])):
                if isinstance(e, str):
                    e = {"anchor": e}
                e = {k: v for k, v in e.items() if k in ("anchor", "excerpt", "note") and v is not None}
                anchor = repair_anchor(e.get("anchor"), f"{fid}:evidence[{j}]", warnings)
                if not anchor:
                    continue
                e["anchor"] = anchor
                if "excerpt" in e and len(e["excerpt"]) > 6000:
                    e["excerpt"] = e["excerpt"][:5990] + "\n[truncated]"
                ev.append(e)
            f["evidence"] = ev
            if not ev:
                warnings.append(f"{fid}: every evidence anchor was unusable; fact dropped")
                seen.discard(fid)
                continue
            f["claim"] = str(f.get("claim", "")).strip()
            facts.append(f)
    fact_ids = {f["id"] for f in facts}

    # ---- verdicts ------------------------------------------------------------
    by_id = defaultdict(list)
    for vs in load_dir(un / "verdicts"):
        for v in vs.get("verdicts", []):
            if v.get("id") in fact_ids:
                by_id[v["id"]].append({"verifier": vs.get("verifier", "verifier"), "verdict": v.get("verdict", "unknown"),
                                       "reason": v.get("reason", ""),
                                       "evidence": repair_anchors(v.get("evidence"), f"{v['id']}:verdict[{vs.get('verifier','verifier')}].evidence", warnings)})
            else:
                warnings.append(f"verdict for unknown fact {v.get('id')} dropped")
    for f in facts:
        vs = by_id.get(f["id"], [])
        f["verdicts"] = vs
        if not vs:
            f["status"] = "proposed"
            continue
        confirmed = sum(1 for v in vs if v["verdict"] == "confirmed")
        refuted = sum(1 for v in vs if v["verdict"] == "refuted" and v["evidence"])
        if refuted >= 2:
            f["status"] = "refuted"
        elif confirmed >= 1 and refuted == 0:
            f["status"] = "verified"
        else:
            f["status"] = "unknown"
    with (pk / "facts.jsonl").open("w") as fh:
        for f in facts:
            fh.write(json.dumps(f, ensure_ascii=False) + "\n")
    usable = {f["id"] for f in facts if f["status"] != "refuted"}

    # ---- dependencies and glossary from lenses -------------------------------
    glossary = []
    for u in load_dir(un / "lenses"):
        for d in u.get("dependencies") or []:
            for existing in dependencies["dependencies"]:
                if existing["name"] == d.get("name"):
                    for k in ("license", "eol", "cves", "note", "evidence", "version", "direct"):
                        if k in d and d[k] not in (None, ""):
                            existing[k] = d[k]
                    if isinstance(existing.get("cves"), list):
                        for c in existing["cves"]:
                            c.setdefault("severity", "unknown")
                    break
            else:
                d.setdefault("manifest", dependencies["dependencies"][0]["manifest"] if dependencies["dependencies"] else f"code:requirements.txt@{head[:7]}")
                d.setdefault("license", "unknown"); d.setdefault("eol", "unknown"); d.setdefault("cves", "unknown")
                dependencies["dependencies"].append(d)
        for g in u.get("glossary") or []:
            entry = {"term": g["term"], "definition": g["definition"],
                     "definedAt": repair_anchor(g["definedAt"], f"glossary {g['term']}:definedAt", warnings) if g.get("definedAt") else None,
                     "factIds": [x for x in g.get("factIds", []) if x in usable]}
            glossary.append(entry)
    dump(pk / "dependencies.json", dependencies)
    if glossary:
        dump(pk / "glossary.json", {"version": 1, "headSHA": head, "terms": glossary})

    # ---- paths and traces ----------------------------------------------------
    paths_in = json.loads((un / "paths.json").read_text()) if (un / "paths.json").exists() else {"candidates": 0, "paths": [], "untraced": []}
    traces = {}
    (pk / "traces").mkdir(exist_ok=True)
    for t in load_dir(un / "traces"):
        t = dict(t)
        t["version"] = 1
        t["factIds"] = [x for x in t.get("factIds", []) if x in usable]
        hops = []
        for i, h in enumerate(t.get("hops", []), 1):
            h = dict(h)
            h["n"] = i
            h["factIds"] = [x for x in h.get("factIds", []) if x in usable]
            h["anchor"] = repair_anchor(h.get("anchor"), f"trace {t.get('pathId')}:hop{i}", warnings) or h.get("anchor")
            if h.get("callSite"):
                h["callSite"] = repair_anchor(h["callSite"], f"trace {t.get('pathId')}:hop{i}.callSite", warnings)
            if not h.get("callSite"):
                h["callSite"] = None
            hops.append(h)
        t["hops"] = hops
        concerns = {}
        for c in CONCERNS:
            cc = dict((t.get("concerns") or {}).get(c) or {"status": "unknown", "evidence": []})
            cc["evidence"] = repair_anchors(cc.get("evidence"), f"trace {t.get('pathId')}:concern {c}", warnings)
            if cc.get("status") in ("present", "absent") and not cc["evidence"]:
                cc["status"] = "unknown"
                cc["note"] = (cc.get("note") or "") + " [status downgraded: no evidence]"
                warnings.append(f"trace {t.get('pathId')} concern {c} downgraded to unknown (no evidence)")
            if cc.get("note") is None:
                cc.pop("note", None)
            concerns[c] = cc
        t["concerns"] = concerns
        t["entry"] = repair_anchor(t.get("entry"), f"trace {t.get('pathId')}:entry", warnings) or t.get("entry")
        if not t.get("scaresMe"):
            t["scaresMe"] = ["The tracer did not state a risk; treat this path as unreviewed."]
        traces[t["pathId"]] = t
        dump(pk / "traces" / f"{t['pathId']}.json", t)
    paths = []
    for p in paths_in.get("paths", []):
        p = dict(p)
        p["factIds"] = [x for x in p.get("factIds", []) if x in usable]
        p["entry"] = repair_anchor(p.get("entry"), f"path {p.get('id')}:entry", warnings) or p.get("entry")
        p["traced"] = p["id"] in traces
        if not p["traced"]:
            warnings.append(f"path {p['id']} has no trace; marked untraced")
        paths.append(p)
    untraced = list(paths_in.get("untraced", [])) + [{"id": p["id"], "title": p.get("title"), "reason": "tracer produced no trace"} for p in paths if not p["traced"]]
    dump(pk / "paths.json", {"version": 1, "headSHA": head, "candidates": paths_in.get("candidates", len(paths) + len(untraced)),
                             "paths": [p for p in paths if p["traced"]], "untraced": untraced})

    # ---- decisions and summary ------------------------------------------------
    decided = json.loads((un / "decisions.json").read_text()) if (un / "decisions.json").exists() else {}
    decisions = []
    for d in decided.get("decisions", []):
        d = dict(d)
        d["factIds"] = [x for x in d.get("factIds", []) if x in usable]
        d["evidence"] = repair_anchors(d.get("evidence"), f"decision {d.get('id')}:evidence", warnings)
        if not d.get("evidence"):
            warnings.append(f"decision {d.get('id')} dropped: no evidence")
            continue
        decisions.append(d)
    if decisions:
        dump(pk / "decisions.json", {"version": 1, "headSHA": head, "decisions": decisions})
    if decided.get("topFindings"):
        (pk / "drafts" / "docs").mkdir(parents=True, exist_ok=True)
        body = "# Top findings\n\nWritten by the producer at hand-off. Claims cite code anchors in double brackets.\n\n" + "\n".join(f"{i}. {x}" for i, x in enumerate(decided["topFindings"], 1)) + "\n"
        (pk / "drafts" / "docs" / "top-findings.md").write_text(body)

    # ---- coverage --------------------------------------------------------------
    files_by_dir = defaultdict(set)
    if a.repo:
        out = subprocess.run(["git", "-C", a.repo, "ls-tree", "-r", "--name-only", head], capture_output=True, text=True, check=True).stdout
        for p in out.splitlines():
            files_by_dir[top_of(p)].add(p)
    facts_by_dir = defaultdict(lambda: {"facts": 0, "verified": 0})
    for f in facts:
        dirs = {top_of(cp) for cp in (code_path(e["anchor"]) for e in f["evidence"]) if cp}
        for d in dirs:
            facts_by_dir[d]["facts"] += 1
            if f["status"] == "verified":
                facts_by_dir[d]["verified"] += 1
    traced_dirs = set()
    for t in traces.values():
        for h in t["hops"]:
            cp = code_path(h["anchor"])
            if cp:
                traced_dirs.add(top_of(cp))
    directories = []
    for d in inventory["topLevel"]:
        path = d["path"]
        if files_by_dir:
            read = len({p for p in read_paths if p in files_by_dir[path]})
        else:
            read = min(d["files"], len({p for p in read_paths if top_of(p) == path}))
        fd = facts_by_dir.get(path, {"facts": 0, "verified": 0})
        if d.get("generated") and read == 0:
            # nobody opened a generated directory: it stays unread even if a fact
            # mentions it from the inventory (honest coverage beats a higher level)
            directories.append({"path": path, "files": d["files"], "filesRead": 0, "level": "unread",
                                "facts": fd["facts"], "verified": fd["verified"],
                                "reason": d.get("reason") or "generated or vendored code, not read"})
            continue
        if path in traced_dirs and fd["facts"] > 0:
            level = "traced"
        elif fd["verified"] > 0:
            level = "verified"
        elif fd["facts"] > 0:
            level = "mapped"
        elif read == 0:
            level = "unread"
        else:
            level = "inventoried"
        reason = d.get("reason") if level == "unread" else None
        if level == "unread" and not reason:
            reason = "no unit read this directory"
        directories.append({"path": path, "files": d["files"], "filesRead": read, "level": level,
                            "facts": fd["facts"], "verified": fd["verified"], "reason": reason})
    checks = json.loads((un / "checks.json").read_text()) if (un / "checks.json").exists() else coverage.get("checks", [])
    coverage.update({"directories": directories,
                     "paths": {"candidates": paths_in.get("candidates", len(paths) + len(untraced)), "traced": len(traces),
                               "untraced": [{"id": u_["id"], "reason": u_["reason"]} for u_ in untraced]},
                     "checks": checks})
    dump(pk / "coverage.json", coverage)

    # ---- packet manifest -----------------------------------------------------
    counts = {"facts": len(facts), "verified": sum(f["status"] == "verified" for f in facts),
              "refuted": sum(f["status"] == "refuted" for f in facts), "unknown": sum(f["status"] == "unknown" for f in facts),
              "traces": len(traces), "unreadDirs": sum(d["level"] == "unread" for d in directories)}
    packet["counts"] = counts
    if decided.get("summary"):
        packet["summary"] = decided["summary"]
    if a.model:
        packet["producer"]["model"] = a.model
    packet["producer"]["finishedAt"] = a.finished_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    packet["producer"]["notes"] = "assembled by assemble_packet.py"
    dump(pk / "packet.json", packet)
    for w in warnings:
        print(f"assemble warning: {w}")
    print(f"assembled {len(facts)} facts ({counts}), {len(traces)} traces, {len(decisions)} decisions, {len(glossary)} terms")

    # ---- validate ------------------------------------------------------------
    cmd = [sys.executable, str(Path(__file__).with_name("validate_packet.py")), str(pk)]
    if a.repo:
        cmd += ["--repo", a.repo]
    cmd += ["--json", str(pk / "validation.json")]
    return subprocess.run(cmd).returncode


if __name__ == "__main__":
    sys.exit(main())
