#!/usr/bin/env python3
"""Deterministic survey of a git checkout into the survey files of a Research Packet.

    survey_repo.py --repo <checkout> --out <packet-dir> [--producer <name>] [--stale-days 365]

Writes inventory.json, history.json, dependencies.json (license/eol/cves as
"unknown" for the lens agent to fill), a coverage.json skeleton (every top-level
directory at level inventoried, generated ones unread) and a packet.json skeleton
with counts zeroed. Everything is computed from `git ls-tree` and `git log`, so
two runs on the same commit produce identical files (generatedAt is the commit
date of HEAD, not the wall clock).
"""
import argparse
import json
import re
import subprocess
from collections import Counter, defaultdict
from pathlib import Path

GENERATED_DIRS = {"vendor", "node_modules", "third_party", "thirdparty", "generated", "dist", "build",
                  ".build", "Pods", "DerivedData", "target", "__pycache__", ".yarn", "bower_components"}
GENERATED_FILE_RE = re.compile(r"(\.min\.(js|css)$|_pb2\.py$|\.pb\.go$|\.generated\.|\.g\.dart$|\.designer\.cs$)")
MANIFESTS = {"package.json": "npm", "requirements.txt": "pypi", "pyproject.toml": "pypi", "Pipfile": "pypi",
             "go.mod": "go", "Package.swift": "swiftpm", "Gemfile": "rubygems", "pom.xml": "maven",
             "build.gradle": "maven", "build.gradle.kts": "maven", "Cargo.toml": "cargo", "composer.json": "composer",
             "Podfile": "other", "setup.py": "pypi"}
ENTRY_HINTS = [
    (re.compile(r"(^|/)(main|app|server|index|cli|manage|wsgi|asgi)\.(py|js|ts|go|rs|rb|swift|java|kt|cs)$"), "main"),
    (re.compile(r"(^|/)cmd/[^/]+/main\.go$"), "main"),
    (re.compile(r"(^|/)(routes?|urls|handlers?|controllers?|api)(/|\.)"), "httpRoute"),
    (re.compile(r"(^|/)(jobs?|cron|workers?|tasks?|queue)(/|\.)"), "job"),
    (re.compile(r"(^|/)tests?/"), "test"),
    (re.compile(r"(^|/)(Makefile|Dockerfile|docker-compose\.ya?ml|build\.sh|build-app\.sh)$"), "build"),
]
CI_RE = re.compile(r"^(\.github/workflows/.*\.ya?ml|\.gitlab-ci\.yml|\.circleci/config\.yml|Jenkinsfile|azure-pipelines\.yml|bitbucket-pipelines\.yml|\.travis\.yml)$")
INFRA_RE = re.compile(r"(\.tf$|(^|/)(deploy|infra|k8s|kubernetes|helm|terraform|ansible|charts)/|(^|/)Dockerfile|docker-compose\.ya?ml$|(^|/)Procfile$|serverless\.ya?ml$|fly\.toml$|render\.yaml$|vercel\.json$)")
DOCS_RE = re.compile(r"(^|/)(README|CONTRIBUTING|CHANGELOG|ARCHITECTURE|CLAUDE|AGENTS|SECURITY|LICENSE)[^/]*$|(^|/)docs?/.*\.(md|rst|txt)$|(^|/)adrs?/", re.I)
KEYWORDS = {"revert": re.compile(r"\brevert", re.I), "hotfix": re.compile(r"\bhot ?fix", re.I),
            "fix": re.compile(r"\bfix(es|ed)?\b", re.I), "todo": re.compile(r"\bTODO\b"), "fixme": re.compile(r"\bFIXME\b"),
            "wip": re.compile(r"\bWIP\b", re.I), "hack": re.compile(r"\bhack\b", re.I)}


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def top_of(path):
    return path.split("/", 1)[0] + "/" if "/" in path else "."


def anchor(path, sha7, line=None):
    return f"code:{path}@{sha7}" + (f"#L{line}" if line else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--producer", default="claude-code-skill")
    ap.add_argument("--stale-days", type=int, default=365)
    a = ap.parse_args()
    repo, out = a.repo, Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "traces").mkdir(exist_ok=True)
    head = git(repo, "rev-parse", "HEAD").strip()
    sha7 = head[:7]
    head_date = git(repo, "log", "-1", "--format=%cI", "HEAD").strip()
    shallow = git(repo, "rev-parse", "--is-shallow-repository").strip() == "true"
    default_branch = None
    try:
        default_branch = git(repo, "symbolic-ref", "--short", "HEAD").strip()
    except subprocess.CalledProcessError:
        pass
    remote = None
    try:
        remote = git(repo, "remote", "get-url", "origin").strip()
    except subprocess.CalledProcessError:
        pass

    # ---- inventory ---------------------------------------------------------
    files = []
    for line in git(repo, "ls-tree", "-r", "-l", "-z", head).split("\0"):
        if not line:
            continue
        meta, path = line.split("\t", 1)
        parts = meta.split()
        size = int(parts[3]) if parts[3] != "-" else 0
        files.append((path, size))
    by_top = defaultdict(list)
    for path, size in files:
        by_top[top_of(path)].append((path, size))
    ext_counter = Counter()
    top_level = []
    for top in sorted(by_top):
        entries = by_top[top]
        langs = Counter()
        for path, _ in entries:
            ext = Path(path).suffix.lstrip(".").lower() or Path(path).name
            langs[ext] += 1
            ext_counter[ext] += 1
        name = top.rstrip("/")
        gen_files = sum(1 for p, _ in entries if GENERATED_FILE_RE.search(p))
        generated = name in GENERATED_DIRS or (len(entries) > 0 and gen_files == len(entries))
        top_level.append({"path": top, "files": len(entries), "bytes": sum(s for _, s in entries),
                          "languages": dict(sorted(langs.items())), "generated": generated,
                          "reason": ("generated or vendored code" if generated else None)})
    entry_points, manifests, ci, infra, docs = [], [], [], [], []
    for path, _ in files:
        base = Path(path).name
        if base in MANIFESTS:
            manifests.append(anchor(path, sha7))
        if CI_RE.match(path):
            ci.append(anchor(path, sha7))
            entry_points.append({"anchor": anchor(path, sha7), "kind": "ci", "note": None})
        if INFRA_RE.search(path):
            infra.append(anchor(path, sha7))
        if DOCS_RE.search(path):
            docs.append(anchor(path, sha7))
        for rx, kind in ENTRY_HINTS:
            if rx.search(path) and top_of(path) not in {t["path"] for t in top_level if t["generated"]}:
                entry_points.append({"anchor": anchor(path, sha7), "kind": kind, "note": "name heuristic; confirm by reading"})
                break
    inventory = {"version": 1, "headSHA": head, "totalFiles": len(files), "totalBytes": sum(s for _, s in files),
                 "topLevel": top_level, "languages": dict(sorted(ext_counter.items())),
                 "entryPoints": entry_points, "manifests": sorted(set(manifests)), "ci": sorted(set(ci)),
                 "infra": sorted(set(infra)), "docs": sorted(set(docs))}

    # ---- history -----------------------------------------------------------
    log = git(repo, "log", "--numstat", "--no-merges", "--format=%x1e%H%x1f%an%x1f%as%x1f%s", head)
    commits = []
    for block in log.split("\x1e"):
        if not block.strip():
            continue
        header, _, body = block.partition("\n")
        sha, author, date, subject = header.split("\x1f", 3)
        touched = []
        for row in body.splitlines():
            cols = row.split("\t")
            if len(cols) == 3:
                touched.append(cols[2])
        commits.append((sha, author, date, subject, touched))
    per_file_commits, per_file_last, per_file_authors = Counter(), {}, defaultdict(set)
    per_dir_authors, per_dir_commits = defaultdict(Counter), Counter()
    author_counter = Counter()
    keywords = Counter({k: 0 for k in KEYWORDS})
    notable = []
    present = {p for p, _ in files}
    for sha, author, date, subject, touched in commits:
        author_counter[author] += 1
        for k, rx in KEYWORDS.items():
            if rx.search(subject):
                keywords[k] += 1
        if KEYWORDS["revert"].search(subject) or KEYWORDS["hotfix"].search(subject):
            notable.append({"anchor": f"commit:{sha}", "subject": subject, "author": author, "date": date,
                            "why": "revert or hotfix in the subject line"})
        seen_dirs = set()
        for path in touched:
            per_file_commits[path] += 1
            per_file_last[path] = max(per_file_last.get(path, ""), date)
            per_file_authors[path].add(author)
            d = top_of(path)
            if d not in seen_dirs:
                per_dir_authors[d][author] += 1
                per_dir_commits[d] += 1
                seen_dirs.add(d)
    total = sum(author_counter.values()) or 1
    authors = [{"name": n, "commits": c, "share": round(c / total, 4)} for n, c in author_counter.most_common()]
    hotspots = [{"path": p, "commits": c, "lastTouched": per_file_last[p], "authors": len(per_file_authors[p])}
                for p, c in per_file_commits.most_common(40) if p in present]
    ownership = []
    for d in sorted(per_dir_commits):
        ac = per_dir_authors[d]
        n = per_dir_commits[d]
        share_list = [{"name": name, "share": round(c / n, 4), "commits": c} for name, c in ac.most_common()]
        covered, bus = 0, 0
        for entry in share_list:
            covered += entry["commits"]
            bus += 1
            if covered * 2 >= n:
                break
        ownership.append({"dir": d, "commits": n, "authors": share_list, "busFactor": bus})
    last_date = commits[0][2] if commits else head_date[:10]
    from datetime import date as _date
    def days_between(a_, b_):
        y1, m1, d1 = map(int, a_.split("-")); y2, m2, d2 = map(int, b_.split("-"))
        return (_date(y2, m2, d2) - _date(y1, m1, d1)).days
    stale = []
    for p in sorted(present):
        lt = per_file_last.get(p)
        if lt and days_between(lt, last_date) > a.stale_days:
            stale.append({"path": p, "lastTouched": lt, "days": days_between(lt, last_date)})
    stale.sort(key=lambda s: (-s["days"], s["path"]))
    # parallel implementations: same basename in two non-test, non-generated directories
    by_base = defaultdict(list)
    skip_base = {"__init__.py", "index.js", "index.ts", "mod.rs", "main.go", "README.md", "Makefile", "package.json"}
    gen_tops = {t["path"] for t in top_level if t["generated"]}
    for p in present:
        b = Path(p).name
        if b in skip_base or top_of(p) in gen_tops or re.search(r"(^|/)tests?/", p):
            continue
        by_base[b].append(p)
    parallel = []
    for b, ps in sorted(by_base.items()):
        if len(ps) >= 2 and re.search(r"\.(py|js|ts|go|rs|rb|swift|java|kt|cs)$", b):
            ps = sorted(ps)
            parallel.append({"a": anchor(ps[0], sha7), "b": anchor(ps[1], sha7),
                             "reason": f"same file name {b} in two trees; check for a half-finished migration"})
    history = {"version": 1, "headSHA": head, "commits": len(commits),
               "firstCommit": commits[-1][2] if commits else None, "lastCommit": last_date, "shallow": shallow,
               "authors": authors, "hotspots": hotspots, "ownership": ownership, "stale": stale[:100],
               "parallel": parallel[:50], "messageKeywords": dict(keywords), "notableCommits": notable[:50]}

    # ---- dependencies -------------------------------------------------------
    deps = []
    def add(name, version, path, line, eco, direct=True):
        deps.append({"name": name, "version": version or "unknown", "manifest": anchor(path, sha7, line),
                     "ecosystem": eco, "license": "unknown", "eol": "unknown", "cves": "unknown", "direct": direct,
                     "note": "fill license, eol and cves with evidence or leave unknown", "evidence": []})
    for path, _ in files:
        base = Path(path).name
        if base not in MANIFESTS:
            continue
        eco = MANIFESTS[base]
        try:
            text = git(repo, "show", f"{head}:{path}")
        except subprocess.CalledProcessError:
            continue
        lines = text.splitlines()
        if base in ("requirements.txt",):
            for i, l in enumerate(lines, 1):
                m = re.match(r"^\s*([A-Za-z0-9_.\-\[\]]+)\s*([=<>!~]=+\s*[^\s;#]+)?", l)
                if m and not l.strip().startswith(("#", "-")):
                    add(m.group(1), (m.group(2) or "").replace("==", "").strip(), path, i, eco)
        elif base == "package.json":
            try:
                pj = json.loads(text)
            except json.JSONDecodeError:
                pj = {}
            for section, direct in (("dependencies", True), ("devDependencies", False)):
                for name, ver in (pj.get(section) or {}).items():
                    line = next((i for i, l in enumerate(lines, 1) if f'"{name}"' in l), None)
                    add(name, ver, path, line, eco, direct)
        elif base == "go.mod":
            for i, l in enumerate(lines, 1):
                m = re.match(r"^\s*([\w./\-]+)\s+(v[\w.\-+]+)", l)
                if m and not l.strip().startswith(("module", "go ", "//")):
                    add(m.group(1), m.group(2), path, i, eco, "// indirect" not in l)
        elif base == "Package.swift":
            for i, l in enumerate(lines, 1):
                m = re.search(r'\.package\(\s*url:\s*"([^"]+)"[^)]*?(?:from:|exact:|branch:|revision:)\s*"([^"]+)"', l)
                if m:
                    add(m.group(1), m.group(2), path, i, eco)
        elif base == "Cargo.toml":
            section = None
            for i, l in enumerate(lines, 1):
                if l.strip().startswith("["):
                    section = l.strip()
                elif section and "dependencies" in section:
                    m = re.match(r'^\s*([\w\-]+)\s*=\s*(?:"([^"]+)"|\{[^}]*version\s*=\s*"([^"]+)")', l)
                    if m:
                        add(m.group(1), m.group(2) or m.group(3), path, i, eco, "dev" not in section)
        elif base == "Gemfile":
            for i, l in enumerate(lines, 1):
                m = re.match(r"""^\s*gem\s+['"]([^'"]+)['"](?:\s*,\s*['"]([^'"]+)['"])?""", l)
                if m:
                    add(m.group(1), m.group(2), path, i, eco)
        elif base == "pyproject.toml":
            in_deps = False
            for i, l in enumerate(lines, 1):
                if re.match(r"^\s*dependencies\s*=\s*\[", l) or "[tool.poetry.dependencies]" in l:
                    in_deps = True
                    continue
                if in_deps and l.strip().startswith(("]", "[")):
                    in_deps = False
                if in_deps:
                    m = re.match(r"""^\s*['"]?([A-Za-z0-9_.\-]+)\s*([=<>!~]=*\s*[^'",\s]+)?""", l)
                    if m and m.group(1) not in ("python",):
                        add(m.group(1), (m.group(2) or "").lstrip("=<>!~ "), path, i, eco)
    dependencies = {"version": 1, "headSHA": head, "dependencies": deps}

    # ---- coverage + packet skeletons ---------------------------------------
    coverage = {"version": 1, "headSHA": head, "generatedAt": head_date,
                "directories": [{"path": t["path"], "files": t["files"], "filesRead": 0,
                                 "level": "unread" if t["generated"] else "inventoried",
                                 "facts": 0, "verified": 0, "reason": t["reason"]} for t in top_level],
                "paths": {"candidates": 0, "traced": 0, "untraced": []},
                "checks": [], "deliverablesPlanned": 0, "deliverablesProduced": 0}
    packet = {"version": 1,
              "producer": {"name": a.producer, "version": "0.1", "model": None, "startedAt": head_date, "finishedAt": head_date,
                           "notes": "skeleton written by survey_repo.py; the producer fills summary, counts and finishedAt"},
              "repo": {"url": remote, "headSHA": head, "defaultBranch": default_branch, "localPath": str(Path(repo).resolve()),
                       "name": Path(repo).resolve().name},
              "scope": "complete",
              "summary": "SUMMARY PENDING: one paragraph describing what this repository is, in plain words, written by the producer after research.",
              "counts": {"facts": 0, "verified": 0, "refuted": 0, "unknown": 0, "traces": 0,
                         "unreadDirs": sum(1 for t in top_level if t["generated"])},
              "briefing": None}
    for name, obj in (("inventory", inventory), ("history", history), ("dependencies", dependencies),
                      ("coverage", coverage), ("packet", packet)):
        (out / f"{name}.json").write_text(json.dumps(obj, indent=2) + "\n")
    if not (out / "facts.jsonl").exists():
        (out / "facts.jsonl").write_text("")
    if not (out / "paths.json").exists():
        (out / "paths.json").write_text(json.dumps({"version": 1, "headSHA": head, "candidates": 0, "paths": [], "untraced": []}, indent=2) + "\n")
    print(f"survey written to {out}")
    print(f"  head {head} ({'shallow, ' if shallow else ''}{len(commits)} commits, {len(files)} files, {len(top_level)} top-level dirs)")
    print(f"  entry points {len(entry_points)}, manifests {len(manifests)}, dependencies {len(deps)}, hotspots {len(hotspots)}, stale {len(stale)}, parallel {len(parallel)}")


if __name__ == "__main__":
    main()
