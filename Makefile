SHELL := /usr/bin/env bash

.PHONY: all html pdf epub decks diagrams validate test source-validate manifest-validate pages clean clean-diagrams clean-pages

all:
	bash scripts/build.sh all
	python3 scripts/validate_manifest.py build

html:
	bash scripts/build.sh html
	python3 scripts/validate_manifest.py build

pdf:
	bash scripts/build.sh pdf
	python3 scripts/validate_manifest.py build

epub:
	bash scripts/build.sh epub
	python3 scripts/validate_manifest.py build

decks:
	bash scripts/build-decks.sh

diagrams:
	bash scripts/build.sh diagrams

validate: test
	bash scripts/build.sh validate
	python3 scripts/validate_manifest.py build

test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

source-validate:
	python3 scripts/validate_sources.py

manifest-validate:
	python3 scripts/validate_manifest.py build

# Local preview of exactly what CI publishes to GitHub Pages. Publishing
# itself happens in .github/workflows/publish-book.yml on every push to
# main -- there is no manual publish step.
pages: all decks
	bash scripts/build-pages.sh build site

clean-diagrams:
	rm -rf build/figures/mermaid

clean-pages:
	rm -rf site

clean:
	rm -rf build .build-src site
