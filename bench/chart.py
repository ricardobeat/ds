#!/usr/bin/env python3
"""Regenerate website/benchmarks.html from bench/results.json.

Run from the repository root:
    python3 bench/chart.py
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "bench" / "results.json"
HTML = ROOT / "website" / "benchmarks.html"


def main() -> None:
    data = json.loads(RESULTS.read_text())
    html = HTML.read_text()

    replacement = "const data = " + json.dumps(data, indent=2) + ";"
    new_html, count = re.subn(
        r"const data = \{.*?\};\n",
        replacement + "\n",
        html,
        count=1,
        flags=re.DOTALL,
    )

    if count != 1:
        raise RuntimeError("Could not find the data block in website/benchmarks.html")

    HTML.write_text(new_html)
    print(f"Updated {HTML.relative_to(ROOT)} from {RESULTS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
