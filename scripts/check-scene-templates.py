#!/usr/bin/env python3
"""Hold the scene templates and SceneRenderer to the same {{SLOT}} contract.

    scripts/check-scene-templates.py

A slot a template declares but the renderer never fills reaches a shipped frame as the
literal text `{{CELL_PX}}`. A slot the renderer fills that no template declares is dead
code that looks like it is doing something. Neither shows up in a build, and both show
up in a video, so this runs in the verify loop — it needs no Swift and no network.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "Sources/WalkthroughStudio/Resources"
RENDERER = ROOT / "Sources/WalkthroughStudio/Onboarding/Video/SceneRenderer.swift"

# Filled for every scene by `fill`, not by the per-kind builders.
UNIVERSAL = {"WIDTH", "HEIGHT", "THEME_CSS", "WORDMARK"}

# template stem -> the function in SceneRenderer that fills it
BUILDERS = {
    "scene-code": "codeHTML",
    "scene-title": "titleHTML",
    "scene-card": "cardHTML",
    "scene-terminal": "terminalHTML",
    "scene-table": "tableHTML",
    "scene-diagram": "diagramHTML",
}

SLOT = re.compile(r"\{\{([A-Z0-9_]+)\}\}")


def builder_slots(source, name):
    """The slot names a builder passes to `fill`, read from its `"KEY":` pairs."""
    start = source.index(f"static func {name}(")
    end = source.index("\n    static func ", start + 1) if "\n    static func " in source[start + 1:] \
        else len(source)
    end = source.find("\n    static func ", start + 1)
    body = source[start:end if end != -1 else len(source)]
    return set(re.findall(r'"([A-Z0-9_]+)":', body))


def main():
    source = RENDERER.read_text()
    problems = []
    for stem, builder in sorted(BUILDERS.items()):
        path = TEMPLATES / f"{stem}.html"
        if not path.exists():
            problems.append(f"{stem}.html is missing")
            continue
        declared = set(SLOT.findall(path.read_text()))
        filled = builder_slots(source, builder) | UNIVERSAL
        for slot in sorted(declared - filled):
            problems.append(f"{stem}.html declares {{{{{slot}}}}}, which {builder} never fills")
        for slot in sorted(filled - declared - UNIVERSAL):
            problems.append(f"{builder} fills {{{{{slot}}}}}, which {stem}.html does not declare")
        print(f"  {stem:16s} {len(declared):2d} slots, all filled by {builder}"
              if not problems else f"  {stem:16s} checked")

    # The renderer's own list of template names has to match the files on disk.
    theme = (ROOT / "Sources/WalkthroughStudio/Services/BrandTheme.swift").read_text()
    registered = set(re.findall(r'"(scene-[a-z]+)"', theme))
    on_disk = {p.stem for p in TEMPLATES.glob("scene-*.html")}
    for name in sorted(on_disk - registered):
        problems.append(f"{name}.html is not in TemplateStore.templateNames, so editing it is impossible")
    for name in sorted(registered - on_disk):
        problems.append(f"TemplateStore.templateNames lists {name}, which has no file")

    if problems:
        print("\nSCENE TEMPLATE CONTRACT BROKEN:")
        for p in problems:
            print(f"  {p}")
        return 1
    print(f"\nscene templates OK: {len(BUILDERS)} templates, every slot filled, all registered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
