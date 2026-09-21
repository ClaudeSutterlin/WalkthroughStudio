#!/usr/bin/env python3
"""Regenerate the adversarial corpus for MarkdownLite.

    scripts/make-markdown-cases.py

Writes Sources/WalkthroughStudio/OnboardingResources/fixtures/markdown-lite-cases.json:
inputs chosen by fuzzing the converter, with the expected output computed by the
reference implementation in .claude/skills/onboarding-research/scripts/project_packet.py.
`markdownLiteProbe` asserts the Swift produces the same.

The golden projection only covers the fixture packet's friendly prose. These are the
shapes that actually broke the converter: a `#` inside a path, a `.` component pathlib
drops, an unclosed emphasis run, a heading chip whose value is only whitespace. Keep the
REGRESSIONS list append-only — every entry is there because something was once wrong.

Deterministic: the random sample is seeded, so regenerating without changing this file
changes nothing. After an intentional converter change the expectations move; say in the
build log why.
"""
import importlib.util
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFERENCE = ROOT / ".claude/skills/onboarding-research/scripts/project_packet.py"
OUT = ROOT / "Sources/WalkthroughStudio/OnboardingResources/fixtures/markdown-lite-cases.json"
SEED = 20260921

REGRESSIONS = [
    "code:12.code:]]doc:##| a | b | ## h {code: x@abcdef1",      # a '#' inside the path
    "code:notes/c#-samples/x.cs@abcdef1",
    "code:notes/c#-samples/x.cs@abcdef1#L4-L9",
    "code:src/.@abcdef1",                                         # pathlib drops '.' components
    "code:a/..@abcdef1",                                          # ...and keeps '..'
    "code:./@fb63e78",
    "code:src/@fb63e78",
    "code:src/api/orders_handler.py@fb63e78#L12-L18",
    "code:src/api/orders_handler.py@fb63e78#L12-L12",
    "code:src/api/orders_handler.py@fb63e78#L12",
    "code:a@b@abcdef1",                                           # more than one '@'
    "code:a@abcdef1#Lfoo",                                        # a fragment that is not a span
    "code:a@ABCDEF1",                                             # uppercase sha: not a code anchor
    "code:a@abcdef",                                              # six hex digits: too short
    "video:ONB-intro#t=90", "doc:tech-debt#ranked", "fact:F-001", "trace:order-creation",
    "commit:fb63e78", "url:https://example.test/x#frag", "nocolonhere",
]
INLINE_REGRESSIONS = [
    "**bold** and `code`", "**a**b**", "***", "``", "`a`b`c`",
    "[[code:a@abcdef1]]", "[[code:a@abcdef1|the handler]]", "[[code:a@abcdef1|]]",
    "[[[a]]", "[[a]x]]", "[[|x]]", "[[a|b|c]]", "a < b && c > d", 'quote " here',
    "**[[code:a@abcdef1]]**", "`[[code:a@abcdef1]]`", "[[code:c#x/y@abcdef1#L2-L7]]",
]
MD_REGRESSIONS = [
    "---\nid: x\ntitle: T\n---\n\n# Heading\n\nbody\n",
    "---\nno closing fence\n\n# H\n",
    "## h {code: x@abcdef1}\n", "## h {code:\t}\n", "## h {code:   }\n",
    "## h {bogus: x}\n", "## h {code: x@abcdef1} {doc: tech-debt}\n",
    "| Concern | Status |\n|---|---|\n| auth | **absent** |\n",
    "| a | b |\n| c | d |\n",
    "| one |\n|:-:|\n| two |\n",
    "- one\n- two\n\n1. first\n2. second\n",
    "-\n- x\n",
    "```\nraw <b> & stuff\n```\n",
    "```python\nx = 1\n",
    "para one\ncontinued\n\npara two\n",
    "# A\n## B\n### C\n#### D\n##### E\n###### F\n",
    "#\n",
    "text with a | pipe mid-line\n",
]

ALPHA = list("ab*`[]|{}#-. \t<>&\"\\/@:") + [
    "**", "[[", "]]", "code:", "{code:", "doc:", "video:", "12.", "```", "|", "---",
    "@abcdef1", "#L3", "#L3-L9", "x.py", "src/", "/.", "/..", "..",
]
MD_ALPHA = ALPHA + [
    "\n", "\n\n", "| a | b |", "|---|---|", "# h", "## h {code: x@abcdef1}",
    "- item", "1. item", "{code:\t}", "{doc: a}",
]


def sample(alpha, count, maxlen):
    out = []
    while len(out) < count:
        s = "".join(random.choice(alpha) for _ in range(random.randint(1, maxlen)))
        if s not in out:
            out.append(s)
    return out


def main():
    spec = importlib.util.spec_from_file_location("ref", REFERENCE)
    ref = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ref)

    random.seed(SEED)
    labels = REGRESSIONS + sample(ALPHA, 120, 16) + ["code:" + s for s in sample(ALPHA, 120, 16)]
    inline = INLINE_REGRESSIONS + sample(ALPHA, 140, 20)
    blocks = MD_REGRESSIONS + sample(MD_ALPHA, 140, 12)

    payload = {
        "version": 1,
        "note": ("Adversarial inputs for MarkdownLite, with the expected output computed by "
                 ".claude/skills/onboarding-research/scripts/project_packet.py. The golden "
                 "projection only covers friendly prose; these are the shapes that broke the "
                 "converter. Regenerate with scripts/make-markdown-cases.py after an "
                 "intentional change, and say in the build log why the output moved."),
        "labels": [{"anchor": a, "label": ref.anchor_label(a)} for a in dict.fromkeys(labels)],
        "inline": [{"text": t, "html": ref.inline_html(t)} for t in dict.fromkeys(inline)],
        "blocks": [{"markdown": m, "html": ref.markdown_to_html(m)} for m in dict.fromkeys(blocks)],
    }
    OUT.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(f"{OUT.relative_to(ROOT)}: {len(payload['labels'])} labels, "
          f"{len(payload['inline'])} inline, {len(payload['blocks'])} blocks")


if __name__ == "__main__":
    main()
