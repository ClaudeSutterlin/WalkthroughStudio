#!/usr/bin/env python3
"""Reference validator for Research Packets (docs/onboarding/PACKET.md).

    validate_packet.py <packet-dir> [--repo <checkout>] [--json <report.json>] [--quiet]

Exit code 0 only when there are zero errors. With --repo, every code: and
commit: anchor is resolved against that checkout at the packet's headSHA; without
it, anchors are parsed but reported as unchecked.

The JSON Schemas next to this script (../schema/*.json) are the normative
contract. This file adds the cross-file rules the schemas cannot express.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

SCHEMA_DIR = Path(__file__).resolve().parent.parent / "schema"
CONCERNS = ["entry", "authorization", "validation", "businessLogic", "persistence",
            "sideEffects", "failureHandling", "idempotency", "timeoutsRetries", "logging"]
LEVEL_ORDER = ["unread", "inventoried", "mapped", "verified", "traced"]

CODE_RE = re.compile(r"^code:(?P<path>.+)@(?P<sha>[0-9a-f]{7,40})(?:#L(?P<a>\d+)(?:-L(?P<b>\d+))?)?$")
CODE_NOSHA_RE = re.compile(r"^code:(?P<path>[^#]+)(?:#L(?P<a>\d+)(?:-L(?P<b>\d+))?)?$")
ANCHOR_RES = {
    "video": re.compile(r"^video:(?P<id>[A-Za-z0-9_.-]+)#(?:t=(?P<t>\d+(?:\.\d+)?)|c=(?P<c>[A-Za-z0-9_.-]+))$"),
    "doc": re.compile(r"^doc:(?P<id>[A-Za-z0-9_.-]+)#(?P<slug>[A-Za-z0-9_.-]+)$"),
    "diagram": re.compile(r"^diagram:(?P<id>[A-Za-z0-9_.-]+)#(?P<node>[A-Za-z0-9_.-]+)$"),
    "trace": re.compile(r"^trace:(?P<id>[A-Za-z0-9_.-]+)#hop(?P<n>\d+)$"),
    "fact": re.compile(r"^fact:(?P<id>[A-Za-z0-9][A-Za-z0-9_.:-]*)$"),
    "commit": re.compile(r"^commit:(?P<sha>[0-9a-f]{7,40})$"),
    "cmd": re.compile(r"^cmd:(?P<unit>[A-Za-z0-9_.-]+)/(?P<n>\d+)$"),
    "issue": re.compile(r"^issue:(?P<n>\d+)$"),
    "url": re.compile(r"^url:(?P<url>https?://\S+)$"),
}


class Report:
    def __init__(self):
        self.errors, self.warnings, self.stats = [], [], {}

    def error(self, where, msg):
        self.errors.append({"where": where, "message": msg})

    def warn(self, where, msg):
        self.warnings.append({"where": where, "message": msg})


class Anchor:
    """Parsed anchor. kind in code|video|doc|diagram|trace|fact|commit|cmd|issue|url."""

    def __init__(self, raw):
        self.raw = raw
        self.kind = None
        self.path = self.sha = None
        self.a = self.b = None
        self.fields = {}
        self.directory = False
        if raw.startswith("code:"):
            m = CODE_RE.match(raw)
            if m:
                self.kind = "code"
                self.path, self.sha = m.group("path"), m.group("sha")
                self.a = int(m.group("a")) if m.group("a") else None
                self.b = int(m.group("b")) if m.group("b") else self.a
                self.directory = self.path.endswith("/")
                if self.directory and self.a is not None:
                    self.kind = None
                    self.problem = "directory anchor cannot carry a line fragment"
                elif self.a is not None and self.b < self.a:
                    self.kind = None
                    self.problem = "line range end before start"
                elif self.path.startswith("/") or ".." in self.path.split("/"):
                    self.kind = None
                    self.problem = "path must be repository-relative"
            elif CODE_NOSHA_RE.match(raw):
                self.problem = "code anchor without @sha7 (packets must pin every code anchor)"
            else:
                self.problem = "malformed code anchor"
            return
        prefix = raw.split(":", 1)[0]
        rx = ANCHOR_RES.get(prefix)
        if rx is None:
            self.problem = f"unknown anchor kind '{prefix}'"
            return
        m = rx.match(raw)
        if not m:
            self.problem = f"malformed {prefix} anchor"
            return
        self.kind = prefix
        self.fields = m.groupdict()


class Repo:
    """git access at a pinned sha, with caching."""

    def __init__(self, path, sha):
        self.path, self.sha = path, sha
        self.line_counts = {}
        self.exists = {}

    def _git(self, *args):
        return subprocess.run(["git", "-C", self.path, *args], capture_output=True, text=True)

    def has_commit(self, sha):
        return self._git("cat-file", "-e", f"{sha}^{{commit}}").returncode == 0

    def file_lines(self, path):
        if path in self.line_counts:
            return self.line_counts[path]
        r = self._git("show", f"{self.sha}:{path}")
        n = None if r.returncode != 0 else r.stdout.count("\n") + (0 if r.stdout.endswith("\n") or r.stdout == "" else 1)
        self.line_counts[path] = n
        return n

    def dir_exists(self, path):
        if path in self.exists:
            return self.exists[path]
        r = self._git("ls-tree", "-d", self.sha, path.rstrip("/"))
        ok = r.returncode == 0 and r.stdout.strip() != ""
        self.exists[path] = ok
        return ok


def load_schemas():
    try:
        import jsonschema  # noqa: F401
    except ImportError:
        return None
    schemas = {}
    for f in SCHEMA_DIR.glob("*.schema.json"):
        schemas[f.name.split(".")[0]] = json.loads(f.read_text())
    return schemas


def validate_schema(schemas, name, obj, where, rep):
    if schemas is None:
        return
    import jsonschema
    v = jsonschema.Draft202012Validator(schemas[name], format_checker=jsonschema.FormatChecker())
    for err in sorted(v.iter_errors(obj), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in err.path) or "(root)"
        rep.error(f"{where}:{loc}", err.message[:300])


def read_json(path, rep, where):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        rep.error(where, "file missing")
    except json.JSONDecodeError as e:
        rep.error(where, f"invalid JSON: {e}")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("packet")
    ap.add_argument("--repo")
    ap.add_argument("--json")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    pk = Path(args.packet)
    rep = Report()
    schemas = load_schemas()
    if schemas is None:
        rep.warn("validator", "python package 'jsonschema' not installed; schema checks skipped (pip install jsonschema)")

    # ---- load files -------------------------------------------------------
    manifest = read_json(pk / "packet.json", rep, "packet.json")
    if manifest is None:
        return finish(rep, args)
    validate_schema(schemas, "packet", manifest, "packet.json", rep)
    head = (manifest.get("repo") or {}).get("headSHA", "")
    repo = None
    if args.repo:
        repo = Repo(args.repo, head)
        if not re.fullmatch(r"[0-9a-f]{40}", head or ""):
            rep.error("packet.json:repo/headSHA", "not a 40-hex sha")
        elif not repo.has_commit(head):
            rep.error("packet.json:repo/headSHA", f"commit {head} not found in {args.repo}")
            repo = None
    else:
        rep.warn("validator", "no --repo given: code: and commit: anchors are parsed but not resolved")

    files = {}
    for name in ["inventory", "history", "paths", "coverage"]:
        obj = read_json(pk / f"{name}.json", rep, f"{name}.json")
        if obj is not None:
            validate_schema(schemas, name, obj, f"{name}.json", rep)
            if obj.get("headSHA") and obj.get("headSHA") != head:
                rep.error(f"{name}.json:headSHA", "does not match packet.json repo.headSHA")
        files[name] = obj
    for name in ["dependencies", "decisions", "glossary"]:
        p = pk / f"{name}.json"
        if p.exists():
            obj = read_json(p, rep, f"{name}.json")
            if obj is not None:
                validate_schema(schemas, name, obj, f"{name}.json", rep)
                if obj.get("headSHA") and obj.get("headSHA") != head:
                    rep.error(f"{name}.json:headSHA", "does not match packet.json repo.headSHA")
            files[name] = obj
        else:
            rep.warn(f"{name}.json", "optional file absent")

    facts, fact_ids = [], {}
    fpath = pk / "facts.jsonl"
    if not fpath.exists():
        rep.error("facts.jsonl", "file missing")
    else:
        for i, line in enumerate(fpath.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                f = json.loads(line)
            except json.JSONDecodeError as e:
                rep.error(f"facts.jsonl:{i}", f"invalid JSON: {e}")
                continue
            validate_schema(schemas, "fact", f, f"facts.jsonl:{i}", rep)
            fid = f.get("id")
            if fid in fact_ids:
                rep.error(f"facts.jsonl:{i}", f"duplicate fact id {fid}")
            elif fid:
                fact_ids[fid] = i
            facts.append((i, f))

    traces = {}
    tdir = pk / "traces"
    if tdir.is_dir():
        for tp in sorted(tdir.glob("*.json")):
            obj = read_json(tp, rep, f"traces/{tp.name}")
            if obj is not None:
                validate_schema(schemas, "trace", obj, f"traces/{tp.name}", rep)
                if obj.get("pathId") and obj.get("pathId") != tp.stem:
                    rep.error(f"traces/{tp.name}", f"pathId {obj.get('pathId')} does not match file name")
                traces[tp.stem] = obj

    # ---- anchor checks -------------------------------------------------
    anchor_counter = Counter()
    unresolved = 0

    def check_anchor(raw, where, allow_kinds=None):
        nonlocal unresolved
        if not isinstance(raw, str):
            rep.error(where, "anchor is not a string")
            return None
        an = Anchor(raw)
        if an.kind is None:
            rep.error(where, f"{getattr(an, 'problem', 'malformed anchor')}: {raw}")
            return None
        if allow_kinds and an.kind not in allow_kinds:
            rep.error(where, f"anchor kind {an.kind} not allowed here: {raw}")
            return None
        anchor_counter[an.kind] += 1
        if an.kind == "code":
            if head and not head.startswith(an.sha):
                rep.error(where, f"sha7 {an.sha} is not a prefix of headSHA: {raw}")
                return an
            if repo is None:
                unresolved += 1
                return an
            if an.directory:
                if not repo.dir_exists(an.path):
                    rep.error(where, f"directory not found at headSHA: {raw}")
            else:
                n = repo.file_lines(an.path)
                if n is None:
                    rep.error(where, f"file not found at headSHA: {raw}")
                elif an.a is not None and (an.a < 1 or an.b > n):
                    rep.error(where, f"line range L{an.a}-L{an.b} outside file of {n} lines: {raw}")
        elif an.kind == "commit":
            if repo is None:
                unresolved += 1
            elif not repo.has_commit(an.fields["sha"]):
                rep.error(where, f"commit not found: {raw}")
        elif an.kind == "fact":
            if an.fields["id"] not in fact_ids:
                rep.error(where, f"unknown fact id: {raw}")
        elif an.kind == "trace":
            t = traces.get(an.fields["id"])
            if t is None:
                rep.error(where, f"unknown trace: {raw}")
            elif int(an.fields["n"]) > len(t.get("hops", [])):
                rep.error(where, f"hop beyond trace length: {raw}")
        elif an.kind == "cmd":
            if not (pk / "commands" / an.fields["unit"] / f"{an.fields['n']}.txt").exists():
                rep.error(where, f"command output file missing for {raw} (expected commands/<unit>/<n>.txt)")
        elif an.kind in ("video", "doc", "diagram"):
            rep.warn(where, f"{an.kind} anchor in a packet is only meaningful inside drafts/: {raw}")
        return an

    # facts
    kind_counter, status_counter = Counter(), Counter()
    facts_by_dir = defaultdict(lambda: {"facts": 0, "verified": 0})
    verifiers = Counter()
    for i, f in facts:
        where = f"facts.jsonl:{i}({f.get('id')})"
        kind_counter[f.get("kind")] += 1
        status_counter[f.get("status")] += 1
        ev = f.get("evidence") or []
        if not ev:
            rep.error(where, "fact has no evidence")
        for j, e in enumerate(ev):
            an = check_anchor((e or {}).get("anchor"), f"{where}:evidence[{j}]")
            if an is not None and an.kind == "code":
                top = an.path.split("/")[0] + "/" if "/" in an.path else "."
                facts_by_dir[top]["facts"] += 1
                if f.get("status") == "verified":
                    facts_by_dir[top]["verified"] += 1
        verdicts = f.get("verdicts") or []
        for v in verdicts:
            verifiers[v.get("verifier")] += 1
            for j, a in enumerate(v.get("evidence") or []):
                check_anchor(a, f"{where}:verdict[{v.get('verifier')}].evidence[{j}]")
        status = f.get("status")
        if status == "refuted":
            if not any(v.get("verdict") == "refuted" and (v.get("evidence") or []) for v in verdicts):
                rep.error(where, "refuted fact needs a refuting verdict that cites counter-evidence")
        elif status == "verified":
            if not any(v.get("verdict") == "confirmed" for v in verdicts):
                rep.warn(where, "verified fact has no confirming verdict")
        elif status == "proposed" and verdicts:
            rep.warn(where, "fact has verdicts but status is still proposed")
        if f.get("kind") == "dataEntity":
            attrs = f.get("attributes") or {}
            for k in ("pii", "rows", "retention"):
                if k not in attrs:
                    rep.warn(where, f"dataEntity fact lacks attributes.{k} (use \"unknown\" rather than omitting)")

    # inventory + coverage + history anchors
    inv = files.get("inventory") or {}
    inv_dirs = {d.get("path") for d in inv.get("topLevel", [])}
    for k in ("manifests", "ci", "infra", "docs"):
        for j, a in enumerate(inv.get(k, [])):
            check_anchor(a, f"inventory.json:{k}[{j}]", {"code"})
    for j, e in enumerate(inv.get("entryPoints", [])):
        check_anchor(e.get("anchor"), f"inventory.json:entryPoints[{j}]", {"code"})
    hist = files.get("history") or {}
    for j, p in enumerate(hist.get("parallel", [])):
        check_anchor(p.get("a"), f"history.json:parallel[{j}].a", {"code"})
        check_anchor(p.get("b"), f"history.json:parallel[{j}].b", {"code"})
    for j, c in enumerate(hist.get("notableCommits", [])):
        check_anchor(c.get("anchor"), f"history.json:notableCommits[{j}]", {"commit"})
    deps = files.get("dependencies") or {}
    for j, d in enumerate(deps.get("dependencies", [])):
        check_anchor(d.get("manifest"), f"dependencies.json:[{j}].manifest", {"code"})
        for k, a in enumerate(d.get("evidence") or []):
            check_anchor(a, f"dependencies.json:[{j}].evidence[{k}]")
    for j, d in enumerate((files.get("decisions") or {}).get("decisions", [])):
        for k, a in enumerate(d.get("evidence") or []):
            check_anchor(a, f"decisions.json:[{j}].evidence[{k}]")
        for fid in d.get("factIds") or []:
            if fid not in fact_ids:
                rep.error(f"decisions.json:[{j}]", f"unknown factId {fid}")
    for j, t in enumerate((files.get("glossary") or {}).get("terms", [])):
        if t.get("definedAt"):
            check_anchor(t["definedAt"], f"glossary.json:[{j}].definedAt", {"code"})
        for fid in t.get("factIds") or []:
            if fid not in fact_ids:
                rep.error(f"glossary.json:[{j}]", f"unknown factId {fid}")

    # paths + traces
    paths = files.get("paths") or {}
    path_ids = set()
    for j, p in enumerate(paths.get("paths", [])):
        pid = p.get("id")
        path_ids.add(pid)
        check_anchor(p.get("entry"), f"paths.json:[{j}].entry", {"code"})
        for fid in p.get("factIds") or []:
            if fid not in fact_ids:
                rep.error(f"paths.json:[{j}]", f"unknown factId {fid}")
        if p.get("traced", True) and pid not in traces:
            rep.error(f"paths.json:[{j}]", f"path {pid} has no traces/{pid}.json")
    for tid, t in traces.items():
        where = f"traces/{tid}.json"
        if tid not in path_ids:
            rep.warn(where, "trace has no entry in paths.json")
        check_anchor(t.get("entry"), f"{where}:entry", {"code"})
        hops = t.get("hops", [])
        for j, h in enumerate(hops):
            if h.get("n") != j + 1:
                rep.error(f"{where}:hops[{j}]", f"hop numbers must be 1..n in order (got {h.get('n')})")
            check_anchor(h.get("anchor"), f"{where}:hops[{j}].anchor", {"code"})
            if h.get("callSite"):
                check_anchor(h["callSite"], f"{where}:hops[{j}].callSite", {"code"})
            for fid in h.get("factIds") or []:
                if fid not in fact_ids:
                    rep.error(f"{where}:hops[{j}]", f"unknown factId {fid}")
        concerns = t.get("concerns") or {}
        for c in CONCERNS:
            cc = concerns.get(c)
            if cc is None:
                rep.error(f"{where}:concerns", f"missing concern {c}")
                continue
            if cc.get("status") in ("present", "absent") and not cc.get("evidence"):
                rep.error(f"{where}:concerns.{c}", f"status {cc.get('status')} requires evidence anchors")
            for k, a in enumerate(cc.get("evidence") or []):
                check_anchor(a, f"{where}:concerns.{c}.evidence[{k}]")
        for fid in t.get("factIds") or []:
            if fid not in fact_ids:
                rep.error(where, f"unknown factId {fid}")

    # coverage
    cov = files.get("coverage") or {}
    cov_dirs = {}
    for j, d in enumerate(cov.get("directories", [])):
        where = f"coverage.json:directories[{j}]({d.get('path')})"
        cov_dirs[d.get("path")] = d
        if inv_dirs and d.get("path") not in inv_dirs:
            rep.error(where, "directory is not in inventory.topLevel")
        lvl = d.get("level")
        if lvl in ("mapped", "verified", "traced") and d.get("facts", 0) == 0:
            rep.error(where, f"level {lvl} but facts == 0")
        if lvl == "unread" and d.get("filesRead", 0) > 0:
            rep.error(where, "level unread but filesRead > 0")
        if lvl == "unread" and not d.get("reason"):
            rep.warn(where, "unread directory without a reason")
        if d.get("filesRead", 0) > d.get("files", 0):
            rep.error(where, "filesRead exceeds files")
        actual = facts_by_dir.get(d.get("path"), {"facts": 0})["facts"]
        if lvl in ("mapped", "verified", "traced") and actual == 0 and d.get("facts", 0) > 0:
            rep.warn(where, "coverage claims facts but no fact cites code under this directory")
    for d in inv_dirs - set(cov_dirs):
        rep.error("coverage.json:directories", f"inventory directory {d} missing from coverage")
    cp = cov.get("paths") or {}
    if paths:
        if cp.get("traced") != len(traces):
            rep.warn("coverage.json:paths.traced", f"says {cp.get('traced')} but {len(traces)} trace files exist")
    # counts
    counts = manifest.get("counts") or {}
    computed = {"facts": len(facts), "verified": status_counter.get("verified", 0),
                "refuted": status_counter.get("refuted", 0), "traces": len(traces),
                "unreadDirs": sum(1 for d in cov_dirs.values() if d.get("level") == "unread")}
    for k, v in computed.items():
        if k in counts and counts[k] != v:
            rep.warn(f"packet.json:counts.{k}", f"says {counts[k]} but computed {v}")

    # drafts
    ddir = pk / "drafts"
    if ddir.is_dir():
        n = sum(1 for _ in ddir.rglob("*") if _.is_file())
        rep.stats["drafts"] = n
        for md in ddir.rglob("*.md"):
            for m in re.finditer(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", md.read_text()):
                check_anchor(m.group(1), f"drafts/{md.relative_to(ddir)}")

    # completeness gates: a survey skeleton is not a packet
    if not facts:
        rep.error("facts.jsonl", "packet has no facts; a packet must carry the research, not only the survey")
    if str(manifest.get("summary", "")).startswith("SUMMARY PENDING"):
        rep.error("packet.json:summary", "placeholder summary left by survey_repo.py")
    if cov_dirs and all(d.get("level") in ("unread", "inventoried") for d in cov_dirs.values()):
        rep.error("coverage.json", "no directory reached level mapped; nothing was researched")
    if paths and not paths.get("paths") and manifest.get("scope") != "smoke":
        rep.warn("paths.json", "no critical paths ranked")
    for dname in ("decisions", "glossary"):
        if files.get(dname) is None and manifest.get("scope") == "complete":
            rep.warn(f"{dname}.json", "complete scope without this file")

    rep.stats.update({
        "facts": len(facts), "factsByKind": dict(kind_counter), "factsByStatus": dict(status_counter),
        "traces": len(traces), "paths": len(path_ids), "verifiers": len(verifiers),
        "anchorsByKind": dict(anchor_counter), "anchorsUnresolved": unresolved,
        "coverageByLevel": dict(Counter(d.get("level") for d in cov_dirs.values())),
        "directories": len(inv_dirs),
    })
    return finish(rep, args)


def finish(rep, args):
    out = {"errors": rep.errors, "warnings": rep.warnings, "stats": rep.stats, "ok": not rep.errors}
    if args.json:
        Path(args.json).write_text(json.dumps(out, indent=2))
    if not args.quiet:
        for e in rep.errors:
            print(f"ERROR   {e['where']}: {e['message']}")
        for w in rep.warnings:
            print(f"warning {w['where']}: {w['message']}")
        print(f"stats   {json.dumps(rep.stats, sort_keys=True)}")
        print(f"{'PACKET OK' if not rep.errors else 'PACKET INVALID'}: {len(rep.errors)} errors, {len(rep.warnings)} warnings")
    return 0 if not rep.errors else 1


if __name__ == "__main__":
    sys.exit(main())
