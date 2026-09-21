/* Onboarding hub.
   Reads the package the projectors wrote: hub/index.json, docs/*.html,
   diagrams/*.mmd, traces/*.html, code/<path>.json and index/anchors.json.
   Every link in every deliverable is an anchor string in the grammar of
   docs/onboarding/PACKET.md section 3, and route() is the single resolver,
   mirroring LinkRouter in the app. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const CODE_RE = /^code:(.+)@([0-9a-f]{7,40})(?:#L(\d+)(?:-L(\d+))?)?$/;
  const state = { hub: null, backlinks: {}, codeIndex: { paths: [], sha: "" },
                  history: [], current: null, seen: new Set() };

  const j = async (path) => (await fetch(path)).json();
  const t = async (path) => (await fetch(path)).text();
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  /* ---------------------------------------------------------------- anchors */
  function parseAnchor(anchor) {
    const m = CODE_RE.exec(anchor);
    if (m) {
      return { kind: "code", path: m[1], sha: m[2],
               from: m[3] ? +m[3] : null, to: m[4] ? +m[4] : (m[3] ? +m[3] : null) };
    }
    const [kind, ...rest] = anchor.split(":");
    const body = rest.join(":");
    const [id, frag] = body.split("#");
    return { kind, id, frag };
  }

  function anchorLabel(anchor) {
    const a = parseAnchor(anchor);
    if (a.kind === "code") {
      const name = a.path.replace(/\/$/, "").split("/").pop() || a.path;
      return a.from ? `${name} L${a.from}${a.to && a.to !== a.from ? "-" + a.to : ""}` : name;
    }
    return `${a.kind} ${(a.id || "").slice(0, 28)}`;
  }

  /* ----------------------------------------------------------------- render */
  async function showDoc(id, frag) {
    const html = await t(`docs/${id}.html`);
    $("stage").innerHTML = html;
    const item = state.hub.items.find((i) => i.id === `doc:${id}`);
    setCrumb(item ? item.title : id);
    if (frag) document.getElementById(frag)?.scrollIntoView({ block: "start" });
    else $("stage").scrollTop = 0;
  }

  async function showTrace(id, frag) {
    const html = await t(`traces/${id}.html`);
    let mmd = "";
    try { mmd = await t(`traces/${id}.mmd`); } catch (_) {}
    $("stage").innerHTML = `<div id="trace-diagram" class="diagram"></div>${html}`;
    if (mmd) await drawMermaid(mmd, $("trace-diagram"), `t-${id}`, null);
    const item = state.hub.items.find((i) => i.id === `trace:${id}`);
    setCrumb(item ? item.title : id);
    if (frag) document.getElementById(frag)?.scrollIntoView({ block: "start" });
  }

  async function showDiagram(id, focusNode) {
    const [mmd, links] = await Promise.all([t(`diagrams/${id}.mmd`), j(`diagrams/${id}.links.json`)]);
    $("stage").innerHTML = `<h1>${esc(id.replace(/-/g, " "))}</h1><div id="dg" class="diagram"></div>`;
    await drawMermaid(mmd, $("dg"), `d-${id}`, links);
    setCrumb(`diagram ${id}`);
    if (focusNode) {
      const el = document.querySelector(`#dg [data-node="${CSS.escape(focusNode)}"]`);
      el?.scrollIntoView({ block: "center", inline: "center" });
      showContextFor(links.nodes[focusNode]?.anchor);
    }
  }

  async function drawMermaid(src, host, id, links) {
    // mermaid.render() rather than run(): run() races its own startOnLoad pass and can
    // mark an element processed without emitting an svg.
    try {
      window.mermaid.initialize({
        startOnLoad: false, securityLevel: "loose", theme: "base",
        themeVariables: {
          primaryColor: "#FFFBF5", primaryTextColor: "#1A1612", primaryBorderColor: "#1A1612",
          lineColor: "#1A1612", secondaryColor: "#F2E8DC", tertiaryColor: "#FFFBF5",
          fontFamily: "Georgia, serif", fontSize: "15px",
          noteBkgColor: "#F2E8DC", noteTextColor: "#1A1612", noteBorderColor: "#E3D5C3",
          actorBkg: "#FFFBF5", actorBorder: "#1A1612", actorTextColor: "#1A1612",
          signalColor: "#1A1612", signalTextColor: "#1A1612",
        },
      });
      const { svg } = await window.mermaid.render(`m${id}-${Date.now()}`, src);
      host.innerHTML = svg;
    } catch (e) {
      host.innerHTML = `<p class="empty">This diagram did not render: ${esc(e.message || e)}</p>`;
      return;
    }
    if (!links) return;
    // Mermaid keeps our node ids on the group element, so a click can carry the anchor.
    for (const [nodeId, meta] of Object.entries(links.nodes)) {
      const g = host.querySelector(`#${CSS.escape("flowchart-" + nodeId + "-0")}`)
             || host.querySelector(`[id^="flowchart-${nodeId}-"]`)
             || host.querySelector(`[id*="${nodeId}"]`);
      if (!g || !meta.anchor) continue;
      g.setAttribute("data-anchor", meta.anchor);
      g.setAttribute("data-node", nodeId);
      g.style.cursor = "pointer";
      g.addEventListener("click", (ev) => { ev.stopPropagation(); route(meta.anchor); });
      const title = document.createElementNS("http://www.w3.org/2000/svg", "title");
      title.textContent = `${meta.anchor}${meta.owner ? " — " + meta.owner : ""}`;
      g.appendChild(title);
    }
  }

  async function showDirectory(prefix) {
    // Container nodes in a diagram carry a directory anchor. Listing what the package
    // actually shipped beats a dead end, and it is the honest answer: only files a
    // deliverable cites travel with the package.
    const clean = prefix.replace(/\/$/, "");
    const all = (state.codeIndex.paths || []);
    const inside = all.filter((p) => clean === "." ? !p.includes("/") : p.startsWith(clean + "/"));
    const covered = new Set();
    for (const key of Object.keys(state.backlinks)) {
      const p = parseAnchor(key).path;
      if (p) covered.add(p.replace(/\/$/, ""));
    }
    $("stage").innerHTML =
      `<h1>${esc(clean === "." ? "repository root" : clean + "/")}</h1>` +
      `<p class="crumb">${inside.length} file${inside.length === 1 ? "" : "s"} in this package ` +
      `at ${esc(state.codeIndex.sha || "")}. Files nothing cites are not shipped.</p>` +
      (inside.length
        ? `<ul>` + inside.map((p) =>
            `<li><a class="chip" href="#" data-anchor="code:${esc(p)}@${esc(state.codeIndex.sha)}">` +
            `${esc(p.split("/").pop())}</a> <span class="crumb">${esc(p)}</span></li>`).join("") + `</ul>`
        : `<p class="empty">No file under here is cited by any deliverable.</p>`);
    setCrumb(clean === "." ? "root" : clean + "/");
    showContextFor(`code:${clean}/@${state.codeIndex.sha}`);
  }

  async function showCode(path, from, to) {
    // Consult the index before fetching: a directory anchor would otherwise cost a 404
    // on every container click, which is noise in the app's web view console too.
    const clean = path.replace(/\/$/, "");
    const shipped = state.codeIndex.paths || [];
    if (!shipped.includes(clean)) {
      if (clean === "." || shipped.some((p) => p.startsWith(clean + "/"))) return showDirectory(clean);
      $("stage").innerHTML = `<p class="empty"><code>${esc(path)}</code> is not in this package. ` +
        `Only files a deliverable cites are shipped.</p>`;
      setCrumb(path.split("/").pop() || path);
      return;
    }
    let file;
    try {
      file = await j(`code/${path}.json`);
    } catch (e) {
      $("stage").innerHTML = `<p class="empty">Could not read <code>${esc(path)}</code>.</p>`;
      return;
    }
    const rows = file.lines.map((line, i) => {
      const n = i + 1;
      const hl = from && n >= from && n <= (to || from);
      return `<div class="row${hl ? " hl" : ""}" id="L${n}"><span class="ln">${n}</span>` +
             `<span class="src">${esc(line) || "&nbsp;"}</span></div>`;
    }).join("");
    $("stage").innerHTML =
      `<div class="code-file"><header><span>${esc(path)}</span>` +
      `<span>@ ${esc(file.sha)}${from ? ` · lines ${from}${to && to !== from ? "-" + to : ""}` : ""}</span>` +
      `</header><pre>${rows}</pre></div>`;
    setCrumb(path.split("/").pop());
    if (from) document.getElementById(`L${from}`)?.scrollIntoView({ block: "center" });
    showContextFor(`code:${path}@${file.sha}${from ? `#L${from}${to && to !== from ? "-L" + to : ""}` : ""}`);
  }

  /* ------------------------------------------------------------------ route */
  async function route(anchor, push = true) {
    const a = parseAnchor(anchor);
    // A video is the app's to play, not the hub's to render. Standalone, the export
    // has no player yet and says so rather than opening a blank stage.
    if (a.kind === "video") {
      if (embedded()) { notify("open", { anchor }); return; }
      $("stage").innerHTML = `<p class="empty">This export does not include the player. ` +
        `Open <code>${esc(anchor)}</code> in Walkthrough Studio.</p>`;
      setCrumb(`video ${esc(a.id || "")}`);
      return;
    }
    if (push && state.current) state.history.push(state.current);
    state.current = anchor;
    $("back").hidden = state.history.length === 0;
    try {
      if (a.kind === "code") {
        if (a.path.endsWith("/")) await showDirectory(a.path);
        else await showCode(a.path, a.from, a.to);
      }
      else if (a.kind === "doc") await showDoc(a.id, a.frag);
      else if (a.kind === "trace") await showTrace(a.id, a.frag);
      else if (a.kind === "diagram") await showDiagram(a.id, a.frag);
      else if (a.kind === "fact") await showFact(a.id);
      else {
        $("stage").innerHTML = `<p class="empty">Nothing in this package answers to ` +
          `<code>${esc(anchor)}</code>.</p>`;
      }
    } catch (e) {
      $("stage").innerHTML = `<p class="empty">Could not open <code>${esc(anchor)}</code>: ${esc(e.message || e)}</p>`;
    }
    state.seen.add(anchor.split("#")[0]);
    markOrder();
    if (a.kind !== "code") showContextFor(null);
    notify("navigated", { anchor, title: $("crumb").textContent, canGoBack: state.history.length > 0 });
  }

  async function showFact(id) {
    // Facts live in the packet, which the hub ships beside the deliverables.
    const facts = await t("packet/facts.jsonl").catch(() => "");
    const line = facts.split("\n").find((l) => l.includes(`"id": "${id}"`) || l.includes(`"id":"${id}"`));
    if (!line) { $("stage").innerHTML = `<p class="empty">Fact ${esc(id)} is not in this package.</p>`; return; }
    const f = JSON.parse(line);
    $("stage").innerHTML =
      `<h1>${esc(f.kind)}: ${esc(f.subject)}</h1><p>${esc(f.claim)}</p>` +
      `<p class="crumb">status <b>${esc(f.status)}</b> · confidence ${f.confidence} · produced by ${esc(f.producedBy)}</p>` +
      `<h2>Evidence</h2>` +
      f.evidence.map((e) =>
        `<p><a class="chip" href="#" data-anchor="${esc(e.anchor)}">${esc(anchorLabel(e.anchor))}</a>` +
        (e.excerpt ? `<pre>${esc(e.excerpt)}</pre>` : "") + `</p>`).join("") +
      (f.verdicts?.length
        ? `<h2>Verdicts</h2><ul>` + f.verdicts.map((v) =>
            `<li><b>${esc(v.verdict)}</b> by ${esc(v.verifier)}: ${esc(v.reason)}</li>`).join("") + `</ul>`
        : "");
    setCrumb(`fact ${id}`);
  }

  function setCrumb(text) { $("crumb").textContent = text; }

  /* ------------------------------------------------------------- companions */
  function showContextFor(anchor) {
    const host = $("context");
    if (!anchor) { host.className = "empty"; host.textContent = "Open a diagram node or a code chip."; return; }
    const path = parseAnchor(anchor).path;
    const refs = [];
    for (const [key, list] of Object.entries(state.backlinks)) {
      const p = parseAnchor(key).path;
      if (p && path && p.replace(/\/$/, "") === path.replace(/\/$/, "")) refs.push(...list);
    }
    const seen = new Set();
    const unique = refs.filter((r) => !seen.has(r.ref) && seen.add(r.ref));
    if (!unique.length) { host.className = "empty"; host.textContent = `Nothing else cites ${path}.`; return; }
    host.className = "";
    host.innerHTML = unique.map((r) =>
      `<a class="chip" href="#" data-anchor="${esc(r.ref)}">${esc(r.kind)}: ${esc(r.label)}</a>`).join("");
  }

  function renderCoverage() {
    const c = state.hub.coverage;
    $("coverage").innerHTML = c.directories.map((d) => {
      const pct = d.files ? Math.round((d.filesRead / d.files) * 100) : 0;
      return `<div class="cov-row"><span class="p">${esc(d.path)}</span>` +
             `<span class="bar lv-${esc(d.level)}"><i style="width:${pct}%"></i></span>` +
             `<span class="lvl" title="${esc(d.reason || "")}">${esc(d.level)}</span></div>`;
    }).join("") +
    `<div class="cov-row"><span class="p">critical paths</span>` +
    `<span class="lvl">${c.paths.traced}/${c.paths.candidates}</span></div>` +
    (c.paths.untraced.length
      ? `<div class="empty" style="margin-top:6px">Not traced: ` +
        c.paths.untraced.map((u) => esc(u.id)).join(", ") + `</div>`
      : "");
    const n = state.hub.coverage.counts;
    $("stats").innerHTML =
      `<div class="stat"><span>Facts</span><b>${n.facts}</b></div>` +
      `<div class="stat"><span>Verified</span><b>${n.verified}</b></div>` +
      `<div class="stat"><span>Refuted, excluded</span><b>${n.refuted}</b></div>` +
      `<div class="stat"><span>Traces</span><b>${n.traces}</b></div>` +
      `<div class="stat"><span>Produced by</span><b>${esc(state.hub.producer.name)}</b></div>`;
  }

  function markOrder() {
    for (const el of document.querySelectorAll("#order .item")) {
      const id = el.dataset.id;
      el.setAttribute("aria-current", String(state.current && state.current.split("#")[0] === id));
      el.classList.toggle("done", state.seen.has(id));
    }
  }

  function renderOrder() {
    $("order").innerHTML = state.hub.items.map((i) =>
      `<button class="item" data-id="${esc(i.id)}"><span class="n">${i.order}</span>` +
      `<span class="t">${esc(i.title)}</span><span class="m">${i.minutes}m</span></button>`).join("") +
      `<div class="section-label">${state.hub.totalMinutes} minutes total</div>`;
    for (const el of document.querySelectorAll("#order .item")) {
      el.addEventListener("click", () => route(el.dataset.id));
    }
  }

  /* ----------------------------------------------------------------- search */
  function search(q) {
    const host = $("results");
    if (!q || q.length < 2) { host.innerHTML = ""; return; }
    const needle = q.toLowerCase();
    const hits = [];
    for (const i of state.hub.items) {
      if (i.title.toLowerCase().includes(needle)) hits.push({ ref: i.id, label: i.title, where: i.kind });
    }
    for (const key of Object.keys(state.backlinks)) {
      const p = parseAnchor(key).path || "";
      if (p.toLowerCase().includes(needle)) {
        hits.push({ ref: key, label: p, where: `cited by ${state.backlinks[key].length}` });
      }
    }
    host.innerHTML = hits.slice(0, 12).map((h) =>
      `<div class="result" data-anchor="${esc(h.ref)}">${esc(h.label)}` +
      `<div class="where">${esc(h.where)}</div></div>`).join("") ||
      `<div class="empty">Nothing matches.</div>`;
  }

  /* ------------------------------------------------------------ app bridge */
  /* Embedded in the app (D20) the hub renders only the stage: the window, the
     navigator, the player and the companion are native, and the three surfaces the
     static export needs anyway — documents, diagrams and the code view — are rendered
     here rather than a second time in AppKit. The same file serves both, so there is
     one renderer and one anchor router, not two that drift. */
  const embedded = () => Boolean(window.walkthroughEmbedded);
  const notify = (kind, payload) => {
    if (!embedded()) return;
    try {
      window.webkit?.messageHandlers?.walkthrough?.postMessage({ kind, ...payload });
    } catch (_) { /* not hosted: the export is just a web page */ }
  };

  // What the app calls in. Kept small on purpose: everything else the app needs it
  // already has from the package's own files.
  window.walkthroughHub = {
    route: (anchor) => route(anchor),
    back: () => { const prev = state.history.pop(); if (prev) route(prev, false); },
    current: () => state.current,
    ready: () => Boolean(state.hub),
  };

  /* ------------------------------------------------------------------- boot */
  document.addEventListener("click", (ev) => {
    const el = ev.target.closest("[data-anchor]");
    if (!el || el.classList.contains("dangling")) return;
    ev.preventDefault();
    route(el.dataset.anchor);
  });
  $("back").addEventListener("click", () => {
    const prev = state.history.pop();
    if (prev) route(prev, false);
    $("back").hidden = state.history.length === 0;
  });
  $("search").addEventListener("input", (e) => search(e.target.value));
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "k") { e.preventDefault(); $("search").focus(); }
    if (e.key === "Escape" && state.history.length) $("back").click();
  });

  (async () => {
    if (embedded()) document.body.classList.add("embedded");
    state.hub = await j("hub/index.json");
    state.backlinks = await j("index/anchors.json").catch(() => ({}));
    state.codeIndex = await j("code/index.json").catch(() => ({ paths: [], sha: "" }));
    $("repo").textContent = `${state.hub.repo.name || state.hub.repo.url || "repository"} @ ${state.hub.repo.headSHA.slice(0, 7)}`;
    renderOrder();
    renderCoverage();
    notify("loaded", { items: state.hub.items.length, totalMinutes: state.hub.totalMinutes });
    if (state.hub.items.length) route(state.hub.items[0].id, false);
  })();
})();
