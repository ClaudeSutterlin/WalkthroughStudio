#!/usr/bin/env python3
"""Project a validated Research Packet into the onboarding package's deliverables.

    project_packet.py --packet <packet-dir> --out <package-dir> [--repo <checkout>]

Reference implementation of the projectors in ARCHITECTURE.md section 1 (the Swift
DiagramProjector, RegisterProjector and HubProjector mirror it, as PacketValidator
mirrors validate_packet.py). Deterministic: no model runs here. Facts in, files out.

Writes into <package-dir>:
    diagrams/<id>.mmd, <id>.links.json      Mermaid source plus the node/edge anchor sidecar
    docs/<docId>.md                         registers with front matter and heading anchors
    traces/<pathId>.mmd, .md                sequence diagram and prose per critical path
    hub/index.json                          recommended order, minutes, coverage summary
    index/anchors.json                      backlinks: anchor -> the deliverables citing it

Every claim printed into a register cites the fact it came from, and a refuted fact
never reaches any output.
"""
import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

WORDS_PER_MINUTE = 220
CODE_RE = re.compile(r"^code:(?P<path>.+)@(?P<sha>[0-9a-f]{7,40})(?:#L(?P<a>\d+)(?:-L(?P<b>\d+))?)?$")


def slugify(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "section"


def mermaid_id(text):
    """A Mermaid-safe node id that is stable across runs."""
    s = re.sub(r"[^A-Za-z0-9]+", "_", text).strip("_")
    return s[:48] or "n"


def mermaid_label(text):
    """Mermaid parses a label as markdown, so a backtick raises "Unsupported markdown:
    codespan" and renders that text instead of the label. Quotes and brackets end the
    label early. Producers write all three, so strip them here rather than asking every
    agent to remember."""
    text = str(text).replace("`", "").replace("\n", " ")
    text = text.replace('"', "'").replace("[", "(").replace("]", ")")
    return " ".join(text.split())


def clip(text, limit):
    """Truncate on a word boundary. Cutting mid-word ('deploy/de') reads as a bug."""
    text = " ".join(str(text).split())
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return (cut or text[:limit]).rstrip(" ,;:.") + "..."


# The .mmd files carry no theme directive on purpose: they stay portable, so a user can
# paste one into any Mermaid tool, and the brand tokens come from BrandTheme at render
# time (the renderer calls mermaid.initialize with them, exactly as BrandedRenderer
# injects {{THEME_CSS}} into the HTML templates).
THEME_INIT = ""


def trace_edges(pk):
    """File-to-file edges taken from consecutive hops of every trace. Hop sequences are
    recorded call evidence, unlike the optional `imports` attribute that most producers
    leave empty.

    A trace walks down into callees and back out again, so consecutive pairs contain
    return hops too; drawing those gives arrows that point backwards (repo -> handler).
    A caller is always seen before its callee, so an edge is kept only when it runs from
    an earlier first appearance to a later one."""
    edges = defaultdict(set)
    for pid, t in pk.traces.items():
        hops = t.get("hops", [])
        first = {}
        for h in hops:
            cp = code_path(h["anchor"])
            if cp and cp not in first:
                first[cp] = h.get("n", len(first) + 1)
        for a, b in zip(hops, hops[1:]):
            pa, pb = code_path(a["anchor"]), code_path(b["anchor"])
            if not pa or not pb or pa == pb:
                continue
            if first.get(pa, 0) < first.get(pb, 0):
                edges[(pa, pb)].add(pid)
    return edges


def code_path(anchor):
    m = CODE_RE.match(anchor or "")
    return m.group("path") if m else None


def top_dir(path):
    return path.split("/", 1)[0] + "/" if "/" in path else "."


class Packet:
    def __init__(self, root):
        self.root = Path(root)
        self.manifest = self._json("packet.json")
        self.inventory = self._json("inventory.json")
        self.history = self._json("history.json")
        self.coverage = self._json("coverage.json")
        self.paths = self._json("paths.json")
        self.dependencies = self._json("dependencies.json", optional=True) or {"dependencies": []}
        self.decisions = self._json("decisions.json", optional=True) or {"decisions": []}
        self.glossary = self._json("glossary.json", optional=True) or {"terms": []}
        self.facts = []
        with (self.root / "facts.jsonl").open() as fh:
            for line in fh:
                if line.strip():
                    self.facts.append(json.loads(line))
        self.by_id = {f["id"]: f for f in self.facts}
        self.traces = {}
        for p in sorted((self.root / "traces").glob("*.json")):
            t = json.loads(p.read_text())
            self.traces[t["pathId"]] = t
        self.sha7 = self.manifest["repo"]["headSHA"][:7]

    def _json(self, name, optional=False):
        p = self.root / name
        if not p.exists():
            if optional:
                return None
            raise SystemExit(f"packet is missing {name}")
        return json.loads(p.read_text())

    def usable(self, kind=None):
        """Refuted facts never reach a deliverable."""
        out = [f for f in self.facts if f.get("status") != "refuted"]
        if kind:
            out = [f for f in out if f.get("kind") == kind]
        return out

    def anchors_of(self, fact):
        return [e["anchor"] for e in fact.get("evidence", []) if e.get("anchor")]

    def primary_anchor(self, fact):
        for a in self.anchors_of(fact):
            if a.startswith("code:"):
                return a
        return (self.anchors_of(fact) or [None])[0]


# --------------------------------------------------------------------------- diagrams

def diagram_c4_context(pk):
    """One box for the system, one per external thing it talks to."""
    name = pk.manifest["repo"].get("name") or "system"
    lines = ["graph LR", f'  system["{mermaid_label(name)}"]']
    links = {"version": 1, "diagramId": "c4-context", "nodes": {}, "edges": {}}
    links["nodes"]["system"] = {"anchor": f"code:./@{pk.sha7}", "owner": None,
                                "factIds": [f["id"] for f in pk.usable("component")][:8]}
    seen = {}
    for f in pk.usable("integration"):
        label = f["attributes"].get("target") or f["subject"]
        nid = mermaid_id("ext_" + str(label))
        if nid in seen:
            continue
        seen[nid] = True
        proto = f["attributes"].get("protocol") or f["attributes"].get("transport") or "calls"
        lines.append(f'  {nid}["{mermaid_label(str(label))}"]')
        lines.append(f'  system -->|"{mermaid_label(str(proto))}"| {nid}')
        anchor = pk.primary_anchor(f)
        links["nodes"][nid] = {"anchor": anchor, "owner": None, "factIds": [f["id"]]}
        links["edges"][f"system->{nid}"] = {"protocol": str(proto), "contract": anchor, "factIds": [f["id"]]}
    lines.append("  classDef sys fill:#DA4F45,stroke:#1A1612,color:#FFFBF5;")
    lines.append("  class system sys;")
    return "\n".join(lines) + "\n", links


def diagram_c4_container(pk):
    """One box per source directory, edges from recorded trace hops."""
    lines = ["graph TD"]
    links = {"version": 1, "diagramId": "c4-container", "nodes": {}, "edges": {}}
    owners = {o["dir"]: o for o in pk.history.get("ownership", [])}
    dirs = [d for d in pk.inventory["topLevel"] if not d.get("generated")]
    dir_paths = {d["path"] for d in dirs}
    facts_by_dir = defaultdict(list)
    for f in pk.usable():
        for a in pk.anchors_of(f):
            cp = code_path(a)
            if cp:
                facts_by_dir[top_dir(cp)].append(f["id"])

    def container_of(path):
        """src/api/orders_handler.py -> src/api/ ; db/schema.sql -> db/ ; README.md -> ."""
        parts = path.split("/")
        if len(parts) >= 3 and parts[0] + "/" in dir_paths:
            return "/".join(parts[:2]) + "/"
        return top_dir(path)

    # which containers actually exist, from the inventory plus anything a trace touches
    containers = {}
    for d in dirs:
        containers[d["path"]] = {"files": d["files"], "parent": None}
    edges = trace_edges(pk)
    for (pa, pb) in edges:
        for path in (pa, pb):
            c = container_of(path)
            if c not in containers:
                containers[c] = {"files": None, "parent": top_dir(path)}

    # Which containers an edge actually touches. A parent that is itself an endpoint
    # (db/ holds schema.sql) cannot become a bare subgraph, or the edge points at a
    # group id and Mermaid invents a phantom node.
    endpoints = set()
    for (pa, pb) in edges:
        endpoints.add(container_of(pa))
        endpoints.add(container_of(pb))

    children = defaultdict(list)
    for c, meta in containers.items():
        parent = meta["parent"]
        if parent and parent in dir_paths and parent != c and parent not in endpoints:
            children[parent].append(c)
    # one child in a box of its own is noise, not grouping
    children = {p: k for p, k in children.items() if len(k) > 1}

    def node_line(path, indent="  "):
        nid = mermaid_id("d_" + path)
        own = owners.get(path) or owners.get(top_dir(path))
        bits = [mermaid_label(path)]
        meta = containers.get(path, {})
        if meta.get("files"):
            bits.append(f"{meta['files']} files")
        if own and own.get("authors"):
            a = own["authors"][0]
            bits.append(f"{mermaid_label(a['name'])} {round(a['share'] * 100)}%")
        links["nodes"][nid] = {
            "anchor": f"code:{path}@{pk.sha7}" if path != "." else f"code:./@{pk.sha7}",
            "owner": own["authors"][0]["name"] if own and own.get("authors") else None,
            "factIds": facts_by_dir.get(path, facts_by_dir.get(top_dir(path), []))[:8],
        }
        return f'{indent}{nid}["{"<br/>".join(bits)}"]'

    emitted = set()
    for parent in sorted(children):
        kids = sorted(children[parent])
        gid = mermaid_id("g_" + parent)
        # a subgraph label must stay one short line; multi-line labels collide with children
        lines.append(f'  subgraph {gid}["{mermaid_label(parent)}"]')
        for c in kids:
            lines.append(node_line(c, "    "))
            emitted.add(c)
        lines.append("  end")
        emitted.add(parent)
    for path in sorted(containers):
        if path in emitted or path in children:
            continue
        lines.append(node_line(path))
        emitted.add(path)

    drawn = set()
    for (pa, pb), traces in sorted(edges.items()):
        ca, cb = container_of(pa), container_of(pb)
        if ca == cb:
            continue
        src, dst = mermaid_id("d_" + ca), mermaid_id("d_" + cb)
        if (src, dst) in drawn or src not in links["nodes"] or dst not in links["nodes"]:
            continue
        drawn.add((src, dst))
        label = sorted(traces)[0] if len(traces) == 1 else f"{len(traces)} paths"
        lines.append(f'  {src} -->|"{mermaid_label(label)}"| {dst}')
        links["edges"][f"{src}->{dst}"] = {
            "protocol": "call", "contract": f"code:{pb}@{pk.sha7}",
            "factIds": [], "traces": sorted(traces)}
    if not drawn:
        lines.append("  %% no trace crossed a container boundary, so no call edges are drawn")

    hot = {h["path"] for h in pk.history.get("hotspots", [])[:3]}
    hotnodes = sorted({mermaid_id("d_" + container_of(p)) for p in hot} & set(links["nodes"]))
    lines.append("  classDef hot stroke:#DA4F45,stroke-width:3px;")
    if hotnodes:
        lines.append("  class " + ",".join(hotnodes) + " hot;")
    return "\n".join(lines) + "\n", links


def diagram_erd(pk):
    """Entity relationship diagram; PII columns are marked and the node carries the flag."""
    lines = ["erDiagram"]
    links = {"version": 1, "diagramId": "erd", "nodes": {}, "edges": {}}
    entities = [f for f in pk.usable("dataEntity") if f["attributes"].get("columns")]
    fields = defaultdict(list)
    for f in pk.usable("dataField"):
        table = f["subject"].split()[-1]
        if "." in table:
            fields[table.split(".")[0]].append(f)
    for f in entities:
        table = f["subject"].split()[-1].split(".")[-1]
        nid = mermaid_id(table).upper()
        cols = f["attributes"].get("columns") or []
        lines.append(f"  {nid} {{")
        for c in cols:
            cname = str(c)
            field = next((x for x in pk.usable("dataField")
                          if str(x["subject"]).endswith(f"{table}.{cname}")), None)
            # Mermaid ERD rows are `<type> <name> "<comment>"`; a real type beats the
            # word "column" repeated down the table.
            raw_type = str((field or {}).get("attributes", {}).get("type") or "").strip()
            # Mermaid ERD types cannot carry parentheses: NUMERIC(10,2) would render as
            # NUMERIC_10_2_. Keep the base type and move the precision into the comment.
            base = re.sub(r"[^A-Za-z0-9_]", "", raw_type.split("(")[0]) or "unknown"
            detail = raw_type[len(raw_type.split("(")[0]):].strip() if "(" in raw_type else ""
            pii = bool(field and field["attributes"].get("pii") is True)
            comment = " ".join(x for x in ("PII" if pii else "", detail) if x)
            lines.append(f'    {base} {cname} "{comment}"')
        lines.append("  }")
        links["nodes"][nid] = {
            "anchor": pk.primary_anchor(f),
            "owner": None,
            "factIds": [f["id"]] + [x["id"] for x in fields.get(table, [])],
            "attributes": {"rows": f["attributes"].get("rows", "unknown"),
                           "retention": f["attributes"].get("retention", "unknown"),
                           "pii": f["attributes"].get("pii", "unknown"),
                           "piiNote": f["attributes"].get("piiNote")},
        }
    # relationships from foreignKeys attributes
    for f in entities:
        table = f["subject"].split()[-1].split(".")[-1]
        nid = mermaid_id(table).upper()
        for fk in f["attributes"].get("foreignKeys", []) or []:
            target = re.split(r"[ .(]", str(fk).replace("->", " ").replace("references", " ").strip())
            target = [t for t in target if t]
            for cand in target:
                other = mermaid_id(cand).upper()
                if other in links["nodes"] and other != nid:
                    lines.append(f"  {other} ||--o{{ {nid} : has")
                    links["edges"][f"{other}->{nid}"] = {"protocol": "foreign key", "contract": pk.primary_anchor(f),
                                                         "factIds": [f["id"]]}
                    break
    return "\n".join(lines) + "\n", links


def diagram_deployment(pk):
    """How code reaches production. Built from the deploy trace's ordered hops when one
    exists; deployStep findings are never chained with arrows, because most of them are
    observations ("CI is not a gate") and an arrow between them would assert a sequence
    the evidence does not support."""
    lines = ["graph LR"]
    links = {"version": 1, "diagramId": "deployment", "nodes": {}, "edges": {}}
    deploy_trace = next((t for pid, t in sorted(pk.traces.items())
                         if "deploy" in pid or "deploy" in t["title"].lower()), None)
    if deploy_trace:
        prev = None
        for h in deploy_trace["hops"]:
            nid = f"h{h['n']}"
            path = code_path(h["anchor"]) or "?"
            label = f"{mermaid_label(Path(path).name)}<br/>{mermaid_label(clip(h['summary'], 64))}"
            lines.append(f'  {nid}["{label}"]')
            links["nodes"][nid] = {"anchor": h["anchor"], "owner": None, "factIds": h.get("factIds", [])}
            if prev:
                lines.append(f"  {prev} --> {nid}")
                links["edges"][f"{prev}->{nid}"] = {"protocol": "then", "contract": h["anchor"],
                                                    "factIds": h.get("factIds", [])}
            prev = nid
        # things the deploy path does NOT touch are the finding worth drawing
        for f in pk.usable("deployStep"):
            claim = f["claim"].lower()
            if "ci" in claim and ("not" in claim or "never" in claim):
                nid = mermaid_id("ci_" + f["id"])
                lines.append(f'  {nid}["CI<br/>{mermaid_label(clip(f["claim"], 60))}"]')
                lines.append(f"  {nid} -.->|\"does not deploy\"| h1")
                links["nodes"][nid] = {"anchor": pk.primary_anchor(f), "owner": None, "factIds": [f["id"]]}
                links["edges"][f"{nid}->h1"] = {"protocol": "no link", "contract": pk.primary_anchor(f),
                                                "factIds": [f["id"]]}
                break
        lines.append("  classDef gap stroke:#DA4F45,stroke-width:3px,stroke-dasharray:4 3;")
        gaps = [k for k, v in links["edges"].items() if v["protocol"] == "no link"]
        if gaps:
            lines.append("  class " + gaps[0].split("->")[0] + " gap;")
    else:
        steps = pk.usable("deployStep")
        if not steps:
            lines.append('  none["No deploy steps were found"]')
            links["nodes"]["none"] = {"anchor": None, "owner": None, "factIds": []}
        for i, f in enumerate(steps[:10], 1):
            nid = f"s{i}"
            lines.append(f'  {nid}["{mermaid_label(clip(f["claim"], 70))}"]')
            links["nodes"][nid] = {"anchor": pk.primary_anchor(f), "owner": None, "factIds": [f["id"]]}
    return "\n".join(lines) + "\n", links


def trace_diagram(pk, trace):
    """A sequence diagram whose participants are the files the hops touch."""
    lines = ["sequenceDiagram", "  autonumber"]
    parts, order = {}, []
    for h in trace["hops"]:
        cp = code_path(h["anchor"]) or "?"
        name = Path(cp).name
        pid = mermaid_id(name)
        if pid not in parts:
            parts[pid] = cp
            order.append(pid)
            lines.append(f'  participant {pid} as {mermaid_label(name)}')
    prev = None
    for h in trace["hops"]:
        cp = code_path(h["anchor"]) or "?"
        pid = mermaid_id(Path(cp).name)
        summary = mermaid_label(clip(h["summary"], 70))
        if prev and prev != pid:
            lines.append(f"  {prev}->>{pid}: {summary}")
        else:
            lines.append(f"  Note over {pid}: {summary}")
        prev = pid
    for name, c in trace["concerns"].items():
        if c["status"] == "absent":
            target = order[0] if order else "x"
            lines.append(f"  Note over {target}: MISSING {mermaid_label(name)}")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- registers

def cite(fact):
    return f"[[fact:{fact['id']}]]"


def anchor_chip(pk, fact):
    a = pk.primary_anchor(fact)
    return f" {{code: {a}}}" if a else ""


def register_lines(pk, facts, limit=None, show_kind=False):
    out = []
    for f in facts[:limit]:
        prefix = f"**{f['kind']}** " if show_kind else ""
        hedge = "Possibly: " if f.get("status") == "unknown" else ""
        out.append(f"- {prefix}{hedge}{f['claim']} {cite(f)}")
        a = pk.primary_anchor(f)
        if a:
            out[-1] += f" [[{a}]]"
    return out


def front_matter(doc_id, title, order, evidence_units, minutes):
    return ("---\n"
            f"id: {doc_id}\n"
            f"title: {title}\n"
            f"minutes: {minutes}\n"
            f"evidence: [{', '.join(sorted(evidence_units)[:12])}]\n"
            f"order: {order}\n"
            "---\n\n")


def build_registers(pk):
    """Every register is a projection of facts; the composer pass (M8, LLM) rewrites
    the prose later, but these are already true, cited and complete."""
    docs = {}
    units = lambda facts: {f.get("producedBy", "?") for f in facts}

    def doc(doc_id, title, order, body_facts, body):
        minutes = max(1, round(len(body.split()) / WORDS_PER_MINUTE))
        docs[doc_id] = front_matter(doc_id, title, order, units(body_facts), minutes) + body

    # architecture narrative
    comps = pk.usable("component")
    ifaces = pk.usable("interface")
    eps = pk.usable("endpoint")
    body = f"# Architecture\n\n{pk.manifest['summary']}\n\n"
    body += "## Containers {code: code:./@%s}\n\n" % pk.sha7 + "\n".join(register_lines(pk, comps)) + "\n\n"
    body += "## Entry points\n\n" + ("\n".join(register_lines(pk, eps)) or "- None found.") + "\n\n"
    body += "## Interfaces\n\n" + "\n".join(register_lines(pk, ifaces, limit=20)) + "\n"
    doc("architecture", "Architecture narrative", 2, comps + ifaces + eps, body)

    # ownership and bus factor
    rows = ["| Directory | Commits | Top author | Share | Bus factor |", "|---|---|---|---|---|"]
    for o in pk.history.get("ownership", []):
        a = (o.get("authors") or [{}])[0]
        rows.append(f"| `{o['dir']}` | {o.get('commits','?')} | {a.get('name','?')} | "
                    f"{round(a.get('share',0)*100)}% | {o['busFactor']} |")
    body = "# Ownership and bus factor\n\n## Per directory\n\n" + "\n".join(rows) + "\n\n"
    body += "## What the history says\n\n" + "\n".join(register_lines(pk, pk.usable("owner") + pk.usable("hotspot"))) + "\n"
    doc("ownership", "Ownership and bus factor", 4, pk.usable("owner"), body)

    # dependencies
    rows = ["| Package | Version | License | End of life | Known CVEs |", "|---|---|---|---|---|"]
    for d in pk.dependencies["dependencies"]:
        cves = d["cves"]
        cve_text = "unknown" if not isinstance(cves, list) else (", ".join(c["id"] for c in cves) or "none found")
        rows.append(f"| `{d['name']}` | {d['version']} | {d['license']} | {d['eol']} | {cve_text} |")
    body = "# Dependency register\n\n## Declared dependencies\n\n" + "\n".join(rows) + "\n\n"
    body += "## Findings\n\n" + "\n".join(register_lines(pk, pk.usable("dependency"))) + "\n"
    doc("dependencies", "Dependency register", 6, pk.usable("dependency"), body)

    # technical debt, ranked by severity then kind
    sev = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    debt = sorted(pk.usable("risk") + pk.usable("landmine"),
                  key=lambda f: (sev.get(str(f["attributes"].get("severity", "")).lower(), 4), f["id"]))
    body = "# Technical debt register\n\n## Ranked by severity\n\n" + "\n".join(register_lines(pk, debt, show_kind=True)) + "\n"
    doc("tech-debt", "Technical debt register", 7, debt, body)

    # test truth
    body = "# Test truth\n\n## What the tests actually cover\n\n" + "\n".join(register_lines(pk, pk.usable("testCoverage"))) + "\n\n"
    checks = pk.coverage.get("checks", [])
    if checks:
        body += "## Checks run during research\n\n" + "\n".join(
            f"- `{c['check']}`: {c['status']}" + (f" ({c['reason']})" if c.get("reason") else "") for c in checks) + "\n"
    else:
        body += "## Checks run during research\n\nNo build or test command was executed; the producer reported none.\n"
    doc("test-truth", "Test truth", 8, pk.usable("testCoverage"), body)

    # data inventory
    body = "# Data inventory\n\n## Entities\n\n" + "\n".join(register_lines(pk, pk.usable("dataEntity"))) + "\n\n"
    body += "## Fields\n\n" + "\n".join(register_lines(pk, pk.usable("dataField"))) + "\n\n"
    body += "## Migrations\n\n" + "\n".join(register_lines(pk, pk.usable("migration"))) + "\n"
    doc("data-inventory", "Data inventory", 9, pk.usable("dataEntity"), body)

    # security posture
    body = "# Security posture\n\n## Findings\n\n" + "\n".join(register_lines(pk, pk.usable("security"))) + "\n\n"
    body += "## Configuration\n\n" + "\n".join(register_lines(pk, pk.usable("config"))) + "\n"
    doc("security-posture", "Security posture", 10, pk.usable("security"), body)

    # observability
    body = "# Observability\n\n## What is visible in production\n\n" + \
           ("\n".join(register_lines(pk, pk.usable("observability"))) or "- Nothing was found.") + "\n"
    doc("observability", "Observability", 11, pk.usable("observability"), body)

    # incidents
    body = "# Incident patterns\n\n## From commit history and markers\n\n" + \
           ("\n".join(register_lines(pk, pk.usable("incidentPattern"))) or "- Nothing was found.") + "\n\n"
    notable = pk.history.get("notableCommits", [])
    if notable:
        body += "## Notable commits\n\n" + "\n".join(
            f"- {n.get('subject','')} ({n.get('author','?')}, {n.get('date','?')}) [[{n['anchor']}]]" for n in notable) + "\n"
    doc("incident-patterns", "Incident patterns", 12, pk.usable("incidentPattern"), body)

    # decisions
    parts = ["# Architecture decisions\n"]
    for d in pk.decisions["decisions"]:
        parts.append(f"## {d['title']}\n")
        parts.append(f"**Decision.** {d['decision']}\n")
        if d.get("alternatives"):
            parts.append("**Alternatives.** " + "; ".join(d["alternatives"]) + "\n")
        parts.append(f"**Consequences.** {d['consequences']}\n")
        if d.get("wouldRepeat") is not None:
            parts.append(f"**Would repeat.** {'yes' if d['wouldRepeat'] else 'no'}\n")
        parts.append("**Evidence.** " + " ".join(f"[[{a}]]" for a in d["evidence"]) + "\n")
    doc("adrs", "Architecture decisions", 5, pk.usable("decision"), "\n".join(parts))

    # glossary
    body = "# Glossary\n\n" + "\n".join(
        f"- **{t['term']}**: {t['definition']}" + (f" [[{t['definedAt']}]]" if t.get("definedAt") else "")
        for t in pk.glossary["terms"]) + "\n"
    doc("glossary", "Glossary", 13, [], body)

    # landmines, in the style of this repository's CLAUDE.md: verify loop first
    lm = [f for f in pk.usable("landmine")]
    body = "# Landmines\n\n## Verify loop\n\n"
    checks = [c for c in pk.coverage.get("checks", []) if c["status"] == "ran"]
    if checks:
        body += "The producer ran: " + ", ".join(f"`{c['check']}`" for c in checks) + ".\n\n"
    else:
        body += "The producer ran no build or test command, so nothing below was confirmed by execution.\n\n"
    body += "## Numbered gotchas\n\n"
    for i, f in enumerate(lm, 1):
        a = pk.primary_anchor(f)
        body += f"{i}. {f['claim']} {cite(f)}" + (f" [[{a}]]" if a else "") + "\n"
    doc("landmines", "Landmines", 14, lm, body)

    # operational scorecard
    cov = pk.coverage
    rows = ["| Measure | Value |", "|---|---|",
            f"| Facts | {len(pk.facts)} |",
            f"| Verified | {sum(1 for f in pk.facts if f['status']=='verified')} |",
            f"| Refuted (excluded from every register) | {sum(1 for f in pk.facts if f['status']=='refuted')} |",
            f"| Critical paths traced | {len(pk.traces)} of {cov['paths']['candidates']} candidates |",
            f"| Directories at level traced or verified | {sum(1 for d in cov['directories'] if d['level'] in ('traced','verified'))} of {len(cov['directories'])} |",
            f"| Commits mined | {pk.history['commits']} |"]
    body = "# Operational scorecard\n\n## Coverage of this research\n\n" + "\n".join(rows) + "\n\n"
    body += "## What was not read\n\n"
    unread = [d for d in cov["directories"] if d["level"] in ("unread", "inventoried")]
    body += ("\n".join(f"- `{d['path']}`: {d['level']}" + (f", {d['reason']}" if d.get("reason") else "") for d in unread)
             or "- Every directory was read.") + "\n\n"
    if cov["paths"]["untraced"]:
        body += "## Candidate paths not traced\n\n" + "\n".join(
            f"- `{u['id']}`: {u['reason']}" for u in cov["paths"]["untraced"]) + "\n"
    doc("operational-scorecard", "Operational scorecard", 15, [], body)

    # coverage report is written whatever the run status
    doc("coverage-report", "Coverage report", 16, [], body)
    return docs


def build_trace_docs(pk):
    out = {}
    for pid, t in pk.traces.items():
        parts = [f"# {t['title']}\n", f"**Scenario.** {t['scenario']}\n", "## Hops\n"]
        for h in t["hops"]:
            parts.append(f"{h['n']}. {h['summary']} [[{h['anchor']}]]")
        parts.append("\n## The ten concerns\n")
        parts.append("| Concern | Status | Evidence |")
        parts.append("|---|---|---|")
        for name, c in t["concerns"].items():
            ev = " ".join(f"[[{a}]]" for a in c.get("evidence", [])[:3]) or "none"
            parts.append(f"| {name} | **{c['status']}** | {ev} |")
        parts.append("\n## What scares me\n")
        for s in t["scaresMe"]:
            parts.append(f"- {s}")
        out[pid] = "\n".join(parts) + "\n"
    return out


# --------------------------------------------------------------------------- hub

def build_hub(pk, docs, diagrams, trace_docs):
    items = []
    order = 1
    items.append({"id": "doc:architecture", "kind": "doc", "title": "Start here: architecture narrative",
                  "path": "docs/architecture.md", "minutes": 4, "order": order})
    for did in ["c4-context", "c4-container", "erd", "deployment"]:
        if did in diagrams:
            order += 1
            items.append({"id": f"diagram:{did}", "kind": "diagram", "title": did.replace("-", " "),
                          "path": f"diagrams/{did}.mmd", "minutes": 2, "order": order})
    for pid in sorted(pk.traces):
        order += 1
        items.append({"id": f"trace:{pid}", "kind": "trace", "title": pk.traces[pid]["title"],
                      "path": f"traces/{pid}.md", "minutes": 5, "order": order})
    for did in ["ownership", "adrs", "dependencies", "tech-debt", "test-truth", "data-inventory",
                "security-posture", "observability", "incident-patterns", "glossary", "landmines",
                "operational-scorecard"]:
        if did in docs:
            order += 1
            minutes = max(1, round(len(docs[did].split()) / WORDS_PER_MINUTE))
            title = re.search(r"^title: (.+)$", docs[did], re.M).group(1)
            items.append({"id": f"doc:{did}", "kind": "doc", "title": title,
                          "path": f"docs/{did}.md", "minutes": minutes, "order": order})
    cov = pk.coverage
    return {
        "version": 1,
        "repo": pk.manifest["repo"],
        "producer": pk.manifest["producer"],
        "summary": pk.manifest["summary"],
        "totalMinutes": sum(i["minutes"] for i in items),
        "items": items,
        "coverage": {
            "directories": cov["directories"],
            "paths": cov["paths"],
            "checks": cov["checks"],
            "counts": pk.manifest["counts"],
        },
    }


def build_backlinks(pk, docs, diagram_links, trace_docs):
    """anchor -> every deliverable that cites it, so the code view can say where a file is covered."""
    index = defaultdict(list)
    for did, links in diagram_links.items():
        for nid, n in links["nodes"].items():
            if n.get("anchor"):
                index[n["anchor"]].append({"kind": "diagram", "ref": f"diagram:{did}#{nid}", "label": did})
    for doc_id, text in docs.items():
        for m in re.finditer(r"\[\[(code:[^\]|]+)\]\]", text):
            index[m.group(1)].append({"kind": "doc", "ref": f"doc:{doc_id}", "label": doc_id})
    for pid, text in trace_docs.items():
        for m in re.finditer(r"\[\[(code:[^\]|]+)\]\]", text):
            index[m.group(1)].append({"kind": "trace", "ref": f"trace:{pid}", "label": pid})
    # de-duplicate while keeping order
    out = {}
    for anchor, refs in index.items():
        seen, keep = set(), []
        for r in refs:
            if r["ref"] not in seen:
                seen.add(r["ref"])
                keep.append(r)
        out[anchor] = keep
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--packet", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo")
    a = ap.parse_args()
    pk = Packet(a.packet)
    out = Path(a.out)
    for d in ("diagrams", "docs", "traces", "hub", "index"):
        (out / d).mkdir(parents=True, exist_ok=True)

    diagrams, diagram_links = {}, {}
    for did, fn in [("c4-context", diagram_c4_context), ("c4-container", diagram_c4_container),
                    ("erd", diagram_erd), ("deployment", diagram_deployment)]:
        mmd, links = fn(pk)
        diagrams[did] = mmd
        diagram_links[did] = links
        (out / "diagrams" / f"{did}.mmd").write_text(mmd)
        (out / "diagrams" / f"{did}.links.json").write_text(json.dumps(links, indent=2) + "\n")

    docs = build_registers(pk)
    for doc_id, text in docs.items():
        (out / "docs" / f"{doc_id}.md").write_text(text)

    trace_docs = build_trace_docs(pk)
    for pid, text in trace_docs.items():
        (out / "traces" / f"{pid}.md").write_text(text)
        (out / "traces" / f"{pid}.mmd").write_text(trace_diagram(pk, pk.traces[pid]))

    hub = build_hub(pk, docs, diagrams, trace_docs)
    (out / "hub" / "index.json").write_text(json.dumps(hub, indent=2) + "\n")
    backlinks = build_backlinks(pk, docs, diagram_links, trace_docs)
    (out / "index" / "anchors.json").write_text(json.dumps(backlinks, indent=2) + "\n")

    print(f"projected into {out}")
    print(f"  diagrams {len(diagrams)}: " + ", ".join(sorted(diagrams)))
    print(f"  registers {len(docs)}, traces {len(trace_docs)}")
    print(f"  hub items {len(hub['items'])}, {hub['totalMinutes']} minutes; backlinked anchors {len(backlinks)}")
    refuted = [f["id"] for f in pk.facts if f["status"] == "refuted"]
    leaked = [r for r in refuted if any(r in t for t in list(docs.values()) + list(trace_docs.values()))]
    print(f"  refuted facts {len(refuted)}, leaked into a deliverable: {len(leaked)}")
    return 1 if leaked else 0


if __name__ == "__main__":
    raise SystemExit(main())
