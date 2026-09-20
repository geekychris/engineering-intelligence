#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-all}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
WORK_DIR="$ROOT/.build-src"
RENDER_OUTPUT_DIR="$WORK_DIR/output"
EDITION_STAGING_DIR="$BUILD_DIR/.edition-staging"
DIAGRAM_STAGING_DIR="$BUILD_DIR/figures/.mermaid-staging"
DIAGRAM_FINAL_DIR="$BUILD_DIR/figures/mermaid"
BOOK="$ROOT/book.adoc"
PDF_THEME="$ROOT/themes/engineering-intelligence-theme.yml"
HTML_STYLESHEET="$ROOT/styles/engineering-intelligence.css"
MERMAID_CONFIG="$ROOT/figures/mermaid.config.json"
MATH_RENDERER="$ROOT/scripts/render-math.js"
PLOT_RENDERER="$ROOT/scripts/render-plots.py"
PLATE_RENDERER="$ROOT/scripts/render-chapter-plates.py"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$2"
}

case "$MODE" in
  all|html|pdf|epub|validate|diagrams)
    ;;
  *)
    fail "Unknown build mode: $MODE"
    ;;
esac

require_command python3 "Python 3 is required"
require_command node "Node.js is required"
require_command npx "npx is required"

if [[ "$MODE" != "diagrams" ]]; then
  require_command ruby "Ruby is required"
  require_command bundle "Bundler is required"
fi

[[ -f "$BOOK" ]] || fail "book.adoc was not found"
[[ -f "$ROOT/scripts/validate_sources.py" ]] || fail "source validator was not found"
[[ -f "$MERMAID_CONFIG" ]] || fail "Mermaid config was not found"

if [[ "$MODE" != "diagrams" ]]; then
  [[ -f "$MATH_RENDERER" ]] || fail "math renderer was not found"
  [[ -f "$PLOT_RENDERER" ]] || fail "plot renderer was not found"
  [[ -f "$PLATE_RENDERER" ]] || fail "chapter plate renderer was not found"
fi

if [[ "$MODE" == "html" || "$MODE" == "all" || "$MODE" == "validate" ]]; then
  [[ -f "$HTML_STYLESHEET" ]] || fail "HTML stylesheet was not found"
fi

if [[ "$MODE" == "pdf" || "$MODE" == "all" || "$MODE" == "validate" ]]; then
  [[ -f "$PDF_THEME" ]] || fail "PDF theme was not found"
fi

initialize_publication_identity() {
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || \
      fail "SOURCE_DATE_EPOCH must be a non-negative integer"
  elif command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct)"
  else
    SOURCE_DATE_EPOCH="0"
  fi

  if [[ -n "${SOURCE_COMMIT:-}" ]]; then
    :
  elif command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
  elif [[ -n "${GITHUB_SHA:-}" ]]; then
    SOURCE_COMMIT="$GITHUB_SHA"
  else
    SOURCE_COMMIT="0000000000000000000000000000000000000000"
  fi

  [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || \
    fail "SOURCE_COMMIT must be a full 40-character lowercase Git SHA"

  # `date -r EPOCH` is BSD-only; GNU date reads -r as a reference *file*.
  # python3 is already a hard requirement, so format the stamp with it.
  BUILD_DATE="$(python3 -c '
import datetime, sys
stamp = datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc)
print(stamp.strftime("%Y-%m-%d"))
' "$SOURCE_DATE_EPOCH")"
  BUILD_COMMIT_SHORT="${SOURCE_COMMIT:0:8}"

  export SOURCE_DATE_EPOCH SOURCE_COMMIT BUILD_DATE BUILD_COMMIT_SHORT
}

initialize_publication_identity

mkdir -p "$BUILD_DIR/figures"
rm -rf "$WORK_DIR" "$EDITION_STAGING_DIR" "$DIAGRAM_STAGING_DIR"
mkdir -p "$WORK_DIR" "$RENDER_OUTPUT_DIR"
if [[ "$MODE" != "diagrams" ]]; then
  mkdir -p "$EDITION_STAGING_DIR"
fi

validate_sources() {
  python3 "$ROOT/scripts/validate_sources.py" "$ROOT"
}

# mmdc drives Chrome through puppeteer. Ubuntu 24 CI runners block
# unprivileged user namespaces via AppArmor, so Chrome cannot sandbox and
# mmdc dies. Setting MERMAID_PUPPETEER_CONFIG to a puppeteer JSON config
# (typically {"args": ["--no-sandbox"]}) makes every render use it. Unset
# on a developer machine, where the sandbox works and should stay on.
MMDC_PUPPETEER_ARGS=()
if [[ -n "${MERMAID_PUPPETEER_CONFIG:-}" ]]; then
  [[ -f "$MERMAID_PUPPETEER_CONFIG" ]] \
    || fail "MERMAID_PUPPETEER_CONFIG points at a missing file: $MERMAID_PUPPETEER_CONFIG"
  MMDC_PUPPETEER_ARGS=(--puppeteerConfigFile "$MERMAID_PUPPETEER_CONFIG")
fi

render_diagrams() {
  local source output

  rm -rf "$DIAGRAM_STAGING_DIR"
  mkdir -p "$DIAGRAM_STAGING_DIR"

  # Render Mermaid to high-DPI PNG rather than SVG. Mermaid v11 emits node
  # labels inside <foreignObject> (HTML in SVG), which prawn-svg cannot
  # render, so text disappears from PDF SVGs. Rasterising through mmdc
  # preserves every label at print quality without a bespoke SVG rewriter.
  while IFS= read -r -d '' source; do
    output="$DIAGRAM_STAGING_DIR/$(basename "${source%.mmd}.png")"
    npx --no-install mmdc \
      --input "$source" \
      --output "$output" \
      --backgroundColor transparent \
      --configFile "$MERMAID_CONFIG" \
      ${MMDC_PUPPETEER_ARGS[@]+"${MMDC_PUPPETEER_ARGS[@]}"} \
      --width 2400 \
      --height 1800 \
      --scale 2 \
      --quiet
  done < <(
    python3 - "$ROOT/figures/mermaid" <<'PY'
from pathlib import Path
import os
import sys

source_dir = Path(sys.argv[1])
for path in sorted(source_dir.glob("*.mmd")):
    sys.stdout.buffer.write(os.fsencode(path))
    sys.stdout.buffer.write(b"\0")
PY
  )
}

publish_diagrams() {
  rm -rf "$DIAGRAM_FINAL_DIR"
  mv "$DIAGRAM_STAGING_DIR" "$DIAGRAM_FINAL_DIR"
}

prepare_sources() {
  cp "$ROOT/book.adoc" "$WORK_DIR/book.adoc"
  cp -R "$ROOT/frontmatter" "$WORK_DIR/frontmatter"
  cp -R "$ROOT/chapters" "$WORK_DIR/chapters"
  cp -R "$ROOT/appendices" "$WORK_DIR/appendices"

  if [[ -d "$ROOT/themes" ]]; then
    cp -R "$ROOT/themes" "$WORK_DIR/themes"
  fi

  if [[ -d "$ROOT/styles" ]]; then
    cp -R "$ROOT/styles" "$WORK_DIR/styles"
  fi

  mkdir -p "$WORK_DIR/figures"

  # Copy raster/vector figures that live at the top of figures/ (cover art,
  # photos, etc.) but skip the Mermaid source directory — the rendered PNGs
  # come from the diagram staging area below.
  find "$ROOT/figures" -maxdepth 1 -type f -exec cp {} "$WORK_DIR/figures/" \;

  # Copy chapter illustration plates (chapter-01.jpg … chapter-18.jpg
  # and any .png variants). If present they override the procedural
  # ornament below.
  if [[ -d "$ROOT/figures/plates" ]]; then
    mkdir -p "$WORK_DIR/figures/plates"
    find "$ROOT/figures/plates" -maxdepth 1 -type f \
      \( -name "*.png" -o -name "*.jpg" \) \
      -exec cp {} "$WORK_DIR/figures/plates/" \;
  fi

  mkdir -p "$WORK_DIR/figures/mermaid"

  if compgen -G "$DIAGRAM_STAGING_DIR/*.png" >/dev/null; then
    cp "$DIAGRAM_STAGING_DIR"/*.png "$WORK_DIR/figures/mermaid/"
  fi

  python3 - "$WORK_DIR" <<'PY'
from pathlib import Path
import re
import sys

work = Path(sys.argv[1])
chapters_dir = work / "chapters"
first_section_re = re.compile(r"^== ", re.MULTILINE)

for path in work.rglob("*.adoc"):
    text = path.read_text(encoding="utf-8")
    text = text.replace(".mmd[", ".png[")
    # Chapter files reference figures with '../figures/...' so they render
    # standalone in the source tree. In the staged jail, book.adoc is the
    # top-level document and figures live alongside it, so any '../' in an
    # image target escapes the jail and asciidoctor emits a warning.
    text = text.replace("image::../figures/", "image::figures/")
    path.write_text(text, encoding="utf-8")

# Apply drop caps to the first prose paragraph inside the first section of
# each chapter file. Source-note files and appendices are left untouched.
letter_re = re.compile(r"^([A-Z])(\w*)")
for path in sorted(chapters_dir.glob("*.adoc")):
    if "source-notes" in path.name:
        continue
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    section_idx = None
    for i, line in enumerate(lines):
        if line.startswith("== ") and not line.startswith("== Key ") \
                and not line.startswith("== Open ") \
                and not line.startswith("== Implementation "):
            section_idx = i
            break
    if section_idx is None:
        continue
    # find first non-blank, non-directive line after the section heading
    for j in range(section_idx + 1, len(lines)):
        line = lines[j]
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(("[", "image::", "//", "====", "----", "++++", "|===")):
            continue
        m = letter_re.match(stripped)
        if not m:
            break
        new_line = f"[.dropcap]##{m.group(1)}##{m.group(2)}{stripped[m.end():]}"
        lines[j] = new_line
        break
    path.write_text("\n".join(lines), encoding="utf-8")
PY
}

render_math() {
  # Pre-render every stem:[...] and [stem] block into an SVG under
  # figures/math/ inside the jail and rewrite the source to reference it.
  # asciidoctor-pdf's built-in stem handling is unavailable in safe mode
  # without the mathematical gem, and MathJax is a browser-only runtime,
  # so precomputing SVGs is the portable path for both HTML and PDF.
  node "$MATH_RENDERER" "$WORK_DIR"
}

render_plots() {
  # Emit data-driven SVG figures (cost distributions, queueing curves,
  # power curves, DAGs) directly into the jail so chapter prose can
  # cite them like any other image.
  python3 "$PLOT_RENDERER" "$WORK_DIR/figures/plots"
}

render_chapter_plates() {
  # Render the procedural ornament fallbacks and inject the chapter-opening
  # image directive after each chapter's title. If a bespoke illustration
  # exists at figures/plates/chapter-<NN>.png it wins; otherwise the topic
  # badge (magnifier for measurement, balance for economics, etc.) is used.
  python3 "$PLATE_RENDERER" "$WORK_DIR/figures/plates"
  python3 - "$WORK_DIR" <<'PY'
from pathlib import Path
import re
import sys

work = Path(sys.argv[1])
plates_dir = work / "figures" / "plates"
title_re = re.compile(r"^=\s+(.+)", re.MULTILINE)
chapter_num_re = re.compile(r"^(\d{2})-")

RULES = [
    (re.compile(r"economic|cost|portfolio|executive", re.I), "balance"),
    (re.compile(r"attention|human|governance|learning|ethics", re.I), "profile"),
    (re.compile(r"measur|metric|catalogue|experimentation|causal|playbook|science", re.I), "magnifier"),
    (re.compile(r"platform|instrumentation|architecture|infrastructure", re.I), "gears"),
    (re.compile(r"lifecycle|implementation|rollout|change|future", re.I), "cycle"),
]

def pick_badge(title):
    for pat, badge in RULES:
        if pat.search(title):
            return badge
    return "compass"

def plate_for(path, title):
    m = chapter_num_re.match(path.name)
    if m:
        for ext in ("jpg", "png"):
            illustration = plates_dir / f"chapter-{m.group(1)}.{ext}"
            if illustration.exists():
                return (f'image::figures/plates/chapter-{m.group(1)}.{ext}'
                        f'[Chapter illustration,pdfwidth=6.5in,align=center]')
    badge = pick_badge(title)
    return (f'image::figures/plates/chapter-ornament-{badge}.png'
            '[Chapter ornament,pdfwidth=5.5in,align=center]')

for chapters_dir in (work / "chapters",):
    if not chapters_dir.exists():
        continue
    for path in sorted(chapters_dir.glob("*.adoc")):
        if "source-notes" in path.name:
            continue
        text = path.read_text(encoding="utf-8")
        m = title_re.search(text)
        if not m:
            continue
        insert_at = m.end()
        new_text = text[:insert_at] + "\n\n" + plate_for(path, m.group(1)) + text[insert_at:]
        path.write_text(new_text, encoding="utf-8")
PY
}

build_html() {
  local output="$RENDER_OUTPUT_DIR/engineering-intelligence.html"
  rm -f "$output"
  bundle exec asciidoctor \
    --failure-level WARN \
    --safe-mode safe \
    --attribute reproducible \
    --attribute build-date="$BUILD_DATE" \
    --attribute build-commit="$BUILD_COMMIT_SHORT" \
    --attribute linkcss! \
    --attribute data-uri \
    --attribute stylesdir="$WORK_DIR/styles" \
    --attribute stylesheet=engineering-intelligence.css \
    --destination-dir "$RENDER_OUTPUT_DIR" \
    --out-file engineering-intelligence.html \
    "$WORK_DIR/book.adoc"
  mv "$output" "$EDITION_STAGING_DIR/engineering-intelligence.html"
}

build_pdf() {
  local output="$RENDER_OUTPUT_DIR/engineering-intelligence.pdf"
  rm -f "$output"
  bundle exec asciidoctor-pdf \
    --failure-level WARN \
    --safe-mode safe \
    --attribute reproducible \
    --attribute build-date="$BUILD_DATE" \
    --attribute build-commit="$BUILD_COMMIT_SHORT" \
    --attribute pdf-themesdir="$WORK_DIR/themes" \
    --attribute pdf-theme=engineering-intelligence \
    --destination-dir "$RENDER_OUTPUT_DIR" \
    --out-file engineering-intelligence.pdf \
    "$WORK_DIR/book.adoc"
  mv "$output" "$EDITION_STAGING_DIR/engineering-intelligence.pdf"
}

build_epub() {
  local output="$RENDER_OUTPUT_DIR/engineering-intelligence.epub"
  rm -f "$output"
  bundle exec asciidoctor-epub3 \
    --safe-mode safe \
    --attribute reproducible \
    --attribute build-date="$BUILD_DATE" \
    --attribute build-commit="$BUILD_COMMIT_SHORT" \
    --attribute ebook-format=epub3 \
    --destination-dir "$RENDER_OUTPUT_DIR" \
    --out-file engineering-intelligence.epub \
    "$WORK_DIR/book.adoc"
  mv "$output" "$EDITION_STAGING_DIR/engineering-intelligence.epub"
}

write_manifest() {
  python3 - "$EDITION_STAGING_DIR" "$DIAGRAM_STAGING_DIR" "$MODE" <<'PY'
from datetime import datetime, timezone
from hashlib import sha256
from pathlib import Path
import json
import os
import sys

editions = Path(sys.argv[1])
diagrams = Path(sys.argv[2])
build_mode = sys.argv[3]


def digest(path):
    h = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


commit = os.environ["SOURCE_COMMIT"]
epoch = int(os.environ["SOURCE_DATE_EPOCH"])
publication_time = datetime.fromtimestamp(epoch, timezone.utc).isoformat()

files = []
for name in (
    "engineering-intelligence.html",
    "engineering-intelligence.pdf",
    "engineering-intelligence.epub",
):
    path = editions / name
    if path.exists():
        files.append(
            {
                "name": name,
                "bytes": path.stat().st_size,
                "sha256": digest(path),
            }
        )

manifest = {
    "schema_version": 1,
    "title": "Engineering Intelligence",
    "build_mode": build_mode,
    "publication_time": publication_time,
    "source_date_epoch": epoch,
    "source_commit": commit,
    "files": files,
    "diagram_count": len(list(diagrams.glob("*.png"))),
}
(editions / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
}

publish_publication() {
  local name

  publish_diagrams

  for name in engineering-intelligence.html engineering-intelligence.pdf engineering-intelligence.epub; do
    if [[ -f "$EDITION_STAGING_DIR/$name" ]]; then
      mv -f "$EDITION_STAGING_DIR/$name" "$BUILD_DIR/$name"
    else
      rm -f "$BUILD_DIR/$name"
    fi
  done
  mv -f "$EDITION_STAGING_DIR/manifest.json" "$BUILD_DIR/manifest.json"
  rmdir "$EDITION_STAGING_DIR"
}

validate_sources

case "$MODE" in
  validate)
    render_diagrams
    prepare_sources
    render_math
    render_plots
    render_chapter_plates
    build_html
    build_pdf
    write_manifest
    publish_publication
    ;;
  diagrams)
    render_diagrams
    publish_diagrams
    ;;
  html)
    render_diagrams
    prepare_sources
    render_math
    render_plots
    render_chapter_plates
    build_html
    write_manifest
    publish_publication
    ;;
  pdf)
    render_diagrams
    prepare_sources
    render_math
    render_plots
    render_chapter_plates
    build_pdf
    write_manifest
    publish_publication
    ;;
  epub)
    render_diagrams
    prepare_sources
    render_math
    render_plots
    render_chapter_plates
    build_epub
    write_manifest
    publish_publication
    ;;
  all)
    render_diagrams
    prepare_sources
    render_math
    render_plots
    render_chapter_plates
    build_html
    build_pdf
    build_epub
    write_manifest
    publish_publication
    ;;
esac

printf 'Publication build completed: %s\n' "$MODE"
