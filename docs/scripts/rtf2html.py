#!/usr/bin/env python3
"""Convert an RTF file to a scoped HTML partial for mdBook {{#include}}.

Usage:
    python3 docs/scripts/rtf2html.py <file.rtf> [<file.rtf> ...]

Each <file.rtf> produces a <file.gen.html> in the same directory.
The .gen.html is a self-contained fragment (scoped <style> + <pre>) that
can be included via {{#include file.gen.html}} in any mdBook Markdown page.

Requirements: macOS textutil (ships with Xcode CLI tools / macOS).
"""

import os
import re
import subprocess
import sys


def rtf_to_html_partial(rtf_path: str) -> str:
    """Convert one RTF file and return the HTML partial as a string."""
    # Derive a CSS namespace from the filename (e.g. wip-today → wip-today)
    base = os.path.splitext(os.path.basename(rtf_path))[0]
    ns = re.sub(r"[^a-z0-9-]", "-", base.lower()).strip("-")

    result = subprocess.run(
        ["/usr/bin/textutil", "-convert", "html", "-stdout", rtf_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"textutil failed: {result.stderr}")
    html = result.stdout

    # ── Extract style block ──────────────────────────────────────────────
    style_match = re.search(r"<style[^>]*>(.*?)</style>", html, re.DOTALL)
    style_block = style_match.group(1) if style_match else ""

    # Collect generated class names (p1, s1, s2, …)
    raw_classes = sorted(
        set(re.findall(r"(?<=\bspan\.)[a-z][a-z0-9]+|(?<=\bp\.)[a-z][a-z0-9]+", style_block))
    )

    # Drop the paragraph rule (we'll use <pre> for monospace layout)
    style_block = re.sub(r"\bp\.[a-z][a-z0-9]+\s*\{[^}]*\}", "", style_block)

    # Namespace remaining span rules
    for cls in raw_classes:
        style_block = re.sub(
            rf"\bspan\.{re.escape(cls)}\b", f"span.{ns}-{cls}", style_block
        )
    style_block = style_block.strip()

    # ── Extract body content ─────────────────────────────────────────────
    body_match = re.search(r"<body>(.*?)</body>", html, re.DOTALL)
    body = body_match.group(1).strip() if body_match else ""

    # Namespace class attributes in the body
    for cls in raw_classes:
        body = re.sub(rf'class="{re.escape(cls)}"', f'class="{ns}-{cls}"', body)

    # Unwrap Apple-converted-space spans (keep text, drop the span)
    body = re.sub(r'<span class="Apple-converted-space">([^<]*)</span>', r"\1", body)

    # Collapse paragraph/br structure → plain lines suitable for <pre>
    body = re.sub(r"<p [^>]+>", "", body)
    body = re.sub(r"</p>", "", body)
    body = re.sub(r"<br>\n?", "\n", body)
    body = body.strip()

    # ── Assemble partial ─────────────────────────────────────────────────
    partial = (
        f"<style>\n{style_block}\n</style>\n"
        f'<pre class="sb-rtf">\n{body}\n</pre>\n'
    )
    return partial


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <file.rtf> [...]", file=sys.stderr)
        sys.exit(1)

    for rtf_path in sys.argv[1:]:
        out_path = os.path.splitext(rtf_path)[0] + ".gen.html"
        partial = rtf_to_html_partial(rtf_path)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(partial)
        print(f"  {rtf_path} → {out_path}")


if __name__ == "__main__":
    main()
