#!/usr/bin/env python3
"""Generate website/examples.html from the source files in examples/.

The examples page inlines the full source of each curated example, syntax
highlighted. Rather than keep that HTML in sync by hand, this script reads the
example files directly and regenerates the page. Run it via `just website`.

To add or reorder an example, edit the EXAMPLES list below.
"""

import html
import sys
from pathlib import Path

# Repo root is the parent of website/.
ROOT = Path(__file__).resolve().parent.parent
EXAMPLES_DIR = ROOT / "examples"
OUT = ROOT / "website" / "examples.html"

# (filename, one-line description). Order here is the order on the page.
EXAMPLES = [
    ("counter.ds",     "A simple counter TUI: up and down to change a number."),
    ("spinner.ds",     "An animated braille spinner."),
    ("timer.ds",       "A countdown timer with pause, resume, and reset."),
    ("progress.ds",    "Three animated progress bars at adjustable speed."),
    ("tabs.ds",        "Tab navigation between three panes."),
    ("repl.ds",        "An interactive line-entry box, REPL style."),
    ("todo.ds",        "A todo app built from JSX components."),
    ("snake.ds",       "Terminal snake. Game state lives in reactive $-signals."),
    ("raylib_demo.ds", "A 3D demo driving the raylib plugin from DS, with a signal-backed camera."),
]

HEAD = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Examples</title>
  <link rel="stylesheet" href="style.css">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/atom-one-dark.min.css">
</head>
<body>
  <nav>
    <span class="brand">new-engine</span>
    <a href="index.html">Overview</a>
    <a href="examples.html" aria-current="page">Examples</a>
  </nav>

  <main>
    <h1>Examples</h1>

    <p>
      These are the example programs that ship with the project. Most are small
      milktea TUI apps, each a self-contained model, update, and view triple.
      This page is generated from the files in <code>examples/</code> by
      <code>just website</code>, so it always matches the source.
    </p>
"""

FOOT = """\
  </main>

  <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
  <script>hljs.highlightAll();</script>
</body>
</html>
"""


def build() -> str:
    parts = [HEAD]

    # Table of contents.
    parts.append("\n    <ul>\n")
    for name, _ in EXAMPLES:
        parts.append(f'      <li><a href="#{name}">{name}</a></li>\n')
    parts.append("    </ul>\n")

    # One section per example.
    for name, desc in EXAMPLES:
        path = EXAMPLES_DIR / name
        if not path.exists():
            print(f"warning: {path} not found, skipping", file=sys.stderr)
            continue
        source = path.read_text(encoding="utf-8")
        # Escape so JSX tags and comparison operators render verbatim.
        escaped = html.escape(source, quote=False)
        parts.append(f'\n    <h2 id="{name}">{name}</h2>\n')
        parts.append(f"    <p>{html.escape(desc, quote=False)}</p>\n")
        parts.append(
            f'    <pre><code class="language-javascript ds">{escaped}</code></pre>\n'
        )

    parts.append(FOOT)
    return "".join(parts)


def main() -> int:
    OUT.write_text(build(), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(EXAMPLES)} examples)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
