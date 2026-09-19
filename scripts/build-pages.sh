#!/usr/bin/env bash
set -euo pipefail

# Assembles a GitHub Pages-ready directory from build/ outputs.
#   - Copies engineering-intelligence.{pdf,html,epub} into site/
#   - Copies build/decks/ (if present) and links each deck from the index
#   - Generates the index.html landing page
# Usage: scripts/build-pages.sh [BUILD_DIR] [SITE_DIR]

BUILD_DIR="${1:-build}"
SITE_DIR="${2:-site}"
REPO_SLUG="${REPO_SLUG:-geekychris/engineering-intelligence}"

for artifact in engineering-intelligence.pdf engineering-intelligence.html engineering-intelligence.epub; do
  if [[ ! -f "${BUILD_DIR}/${artifact}" ]]; then
    echo "Missing ${BUILD_DIR}/${artifact}. Run 'make all' first." >&2
    exit 1
  fi
done

rm -rf "${SITE_DIR}"
mkdir -p "${SITE_DIR}"

cp "${BUILD_DIR}/engineering-intelligence.pdf"  "${SITE_DIR}/"
cp "${BUILD_DIR}/engineering-intelligence.html" "${SITE_DIR}/"
cp "${BUILD_DIR}/engineering-intelligence.epub" "${SITE_DIR}/"
[[ -f "${BUILD_DIR}/manifest.json" ]] && cp "${BUILD_DIR}/manifest.json" "${SITE_DIR}/"

# Slide decks are optional: `make pages` builds them, but a book-only build
# should still produce a valid site.
if [[ -d "${BUILD_DIR}/decks" ]]; then
  mkdir -p "${SITE_DIR}/decks"
  cp -R "${BUILD_DIR}/decks"/. "${SITE_DIR}/decks/"
  rm -f "${SITE_DIR}/decks"/.staged-*.adoc
fi

# Tell Jekyll to leave the site alone (files starting with _ etc.)
touch "${SITE_DIR}/.nojekyll"

human_mb() {
  awk "BEGIN { printf \"%.1f\", $(wc -c <"$1" | tr -d ' ')/1048576 }"
}

pdf_mb=$(human_mb "${SITE_DIR}/engineering-intelligence.pdf")
html_mb=$(human_mb "${SITE_DIR}/engineering-intelligence.html")
epub_mb=$(human_mb "${SITE_DIR}/engineering-intelligence.epub")

# Diagram count comes from the manifest the build already wrote and validated.
diagram_count=""
if [[ -f "${SITE_DIR}/manifest.json" ]]; then
  diagram_count="$(python3 -c '
import json, sys
n = json.load(open(sys.argv[1])).get("diagram_count")
print(f"{n} " if isinstance(n, int) and n > 0 else "")
' "${SITE_DIR}/manifest.json")"
fi

build_date=$(date -u +"%Y-%m-%d")
commit_sha="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
short_sha="${commit_sha:0:7}"

# Deck list, rendered from the built HTML files. Chapter decks sort ahead of
# workshops by filename, which is the order we want on the page anyway.
deck_items=""
deck_section=""
if compgen -G "${SITE_DIR}/decks/*.html" >/dev/null; then
  while IFS= read -r deck; do
    base="$(basename "${deck}" .html)"
    # chapter-07-ai-assisted-engineering -> "Chapter 07 · Ai Assisted Engineering"
    label="$(printf '%s' "${base}" | python3 -c '
import sys, re

ACRONYMS = {"Ai": "AI", "Ci": "CI", "Cd": "CD", "Sdlc": "SDLC", "Kpi": "KPI"}


def titled(slug):
    words = [ACRONYMS.get(w, w) for w in slug.replace("-", " ").title().split()]
    return " ".join(words)


stem = sys.stdin.read().strip()
m = re.match(r"chapter-(\d+)-(.*)$", stem)
if m:
    print(f"Chapter {m.group(1)} · " + titled(m.group(2)))
elif stem.startswith("workshop-"):
    print("Workshop · " + titled(stem[len("workshop-"):]))
else:
    print(titled(stem))
')"
    deck_items+="      <li><a href=\"decks/${base}.html\">${label}</a></li>"$'\n'
  done < <(ls "${SITE_DIR}"/decks/*.html | sort)

  deck_count=$(ls "${SITE_DIR}"/decks/*.html | wc -l | tr -d ' ')
  deck_section=$(cat <<DECKS
  <h2>Slide decks</h2>
  <p class="note">${deck_count} reveal.js decks &mdash; one per chapter, plus the workshops. Press <kbd>S</kbd> for speaker notes, <kbd>Esc</kbd> for the slide overview.</p>
  <ul class="decks">
${deck_items}  </ul>
DECKS
)
fi

cat >"${SITE_DIR}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Engineering Intelligence</title>
  <meta name="description" content="A quantitative framework for measuring, understanding, and optimizing modern software engineering.">
  <style>
    :root {
      color-scheme: light dark;
      --fg: #1a1a1a;
      --muted: #666;
      --bg: #fff;
      --card: #fafafa;
      --line: #ddd;
      --accent: #6C371F;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #e8e8e8;
        --muted: #a0a0a0;
        --bg: #16161a;
        --card: #1e1e24;
        --line: #33333c;
        --accent: #d89a6a;
      }
    }
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      max-width: 46rem;
      margin: 0 auto;
      padding: 3.5rem 1.5rem 5rem;
      line-height: 1.6;
      color: var(--fg);
      background: var(--bg);
    }
    h1 { margin: 0 0 0.25rem; font-size: 2.1rem; letter-spacing: -0.02em; }
    h2 { margin: 2.75rem 0 0.75rem; font-size: 1.15rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); font-weight: 600; }
    .tagline { color: var(--muted); margin: 0 0 2rem; font-size: 1.05rem; }
    .note { color: var(--muted); font-size: 0.9rem; margin: 0 0 1rem; }
    .read {
      display: block;
      padding: 1.25rem 1.5rem;
      border: 2px solid var(--accent);
      border-radius: 10px;
      text-decoration: none;
      color: inherit;
    }
    .read:hover { background: var(--card); }
    .read strong { display: block; font-size: 1.2rem; color: var(--accent); }
    .read span { color: var(--muted); font-size: 0.9rem; }
    ul { list-style: none; padding: 0; margin: 0; }
    ul.editions li {
      margin: 0.6rem 0;
      padding: 0.9rem 1.15rem;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--card);
    }
    ul.editions a { font-weight: 600; text-decoration: none; color: var(--accent); }
    ul.editions a:hover { text-decoration: underline; }
    .meta { color: var(--muted); font-size: 0.85rem; margin-left: 0.5rem; }
    ul.decks { columns: 2; column-gap: 2rem; }
    @media (max-width: 34rem) { ul.decks { columns: 1; } }
    ul.decks li { break-inside: avoid; margin: 0.3rem 0; font-size: 0.92rem; }
    ul.decks a { text-decoration: none; color: var(--accent); }
    ul.decks a:hover { text-decoration: underline; }
    kbd { border: 1px solid var(--line); border-radius: 3px; padding: 0 0.3em; font-size: 0.85em; }
    footer { margin-top: 3.5rem; padding-top: 1.25rem; border-top: 1px solid var(--line); color: var(--muted); font-size: 0.85rem; }
    footer a { color: var(--muted); }
  </style>
</head>
<body>
  <h1>Engineering Intelligence</h1>
  <p class="tagline">A quantitative framework for measuring, understanding, and optimizing modern software engineering.</p>

  <a class="read" href="engineering-intelligence.html">
    <strong>Read the book online &rarr;</strong>
    <span>Full text, all ${diagram_count}diagrams and tables, in one page &middot; ${html_mb} MB</span>
  </a>

  <h2>Download</h2>
  <ul class="editions">
    <li>
      <a href="engineering-intelligence.pdf">PDF</a>
      <span class="meta">${pdf_mb} MB &middot; print edition</span>
    </li>
    <li>
      <a href="engineering-intelligence.epub">EPUB</a>
      <span class="meta">${epub_mb} MB &middot; e-readers</span>
    </li>
    <li>
      <a href="engineering-intelligence.html">HTML</a>
      <span class="meta">${html_mb} MB &middot; single self-contained file</span>
    </li>
  </ul>

${deck_section}

  <footer>
    Built ${build_date} from commit <code>${short_sha}</code>.
    Source: <a href="https://github.com/${REPO_SLUG}">${REPO_SLUG}</a>.
  </footer>
</body>
</html>
HTML

echo "Assembled Pages site at ${SITE_DIR}/"
ls -lh "${SITE_DIR}/"
