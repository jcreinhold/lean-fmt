#!/usr/bin/env python3
"""Inject search metadata into the rendered Verso manual and write a sitemap.

Verso emits no meta description, no canonical link, and no sitemap, and its RenderConfig has no
head-injection hook, so the Pages workflow runs this between `lake exe docs` and the artifact
upload. The canonical host is jcreinhold.github.io: the apex domain 301s there permanently and
serves nothing itself. A canonical link cannot be relative, so this host is hardcoded here —
a host change means editing this file. No robots.txt is generated: crawlers read it only from the
host root, which belongs to the user-site repository, not this one.
"""

import pathlib
import sys

BASE = "https://jcreinhold.github.io/lean-fmt/"
DESCRIPTION = (
    "lean-fmt is a code formatter and linter for Lean 4: one canonical style, "
    "validated against the original token stream, with editor and CI integration."
)
# Verso's own UI pages, not content: the cross-reference lookup and the search page. They stay
# untagged and out of the sitemap.
NON_CONTENT = {"find", "search"}


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    pages = [root / "index.html"]
    pages += sorted(
        page
        for page in root.glob("*/index.html")
        if page.parent.name not in NON_CONTENT and not page.parent.name.startswith("-")
    )
    urls = []
    for page in pages:
        url = BASE if page.parent == root else f"{BASE}{page.parent.name}/"
        urls.append(url)
        html = page.read_text(encoding="utf-8")
        if 'name="description"' in html:
            continue
        anchor = '<meta charset="utf-8">'
        if anchor not in html:
            raise SystemExit(f"{page}: no {anchor} anchor to inject after")
        tags = (
            f'<meta name="description" content="{DESCRIPTION}">\n'
            f'    <link rel="canonical" href="{url}">'
        )
        page.write_text(html.replace(anchor, f"{anchor}\n    {tags}", 1), encoding="utf-8")
    sitemap = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"  <url><loc>{url}</loc></url>\n" for url in urls)
        + "</urlset>\n"
    )
    (root / "sitemap.xml").write_text(sitemap, encoding="utf-8")
    print(f"tagged {len(pages)} pages; sitemap lists {len(urls)} URLs")


if __name__ == "__main__":
    main()
