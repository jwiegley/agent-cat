MANUAL := agent-cat
SOURCE := $(MANUAL).texi
INCLUDES := haskell-api-index.texi haskell-member-coverage.texi runner-index.texi examples/Hello.hs examples/Registry.hs
BUILD_DIR := build
MAKEINFO ?= makeinfo
PYTHON ?= python3

.PHONY: all info html check check-haskell update-haskell-inventory clean

all: info html

info: $(BUILD_DIR)/$(MANUAL).info

html: $(BUILD_DIR)/$(MANUAL).html

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/$(MANUAL).info: $(SOURCE) $(INCLUDES) | $(BUILD_DIR)
	$(MAKEINFO) --no-split --output=$@ $<

$(BUILD_DIR)/$(MANUAL).html: $(SOURCE) $(INCLUDES) | $(BUILD_DIR)
	$(MAKEINFO) --html --no-split --output=$@ $<

check:
	@set -eu; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	$(MAKEINFO) --no-split --output="$$tmp/$(MANUAL).info" "$(SOURCE)" 2>"$$tmp/info.err"; \
	test ! -s "$$tmp/info.err" || { cat "$$tmp/info.err" >&2; exit 1; }; \
	$(MAKEINFO) --html --no-split --output="$$tmp/$(MANUAL).html" "$(SOURCE)" 2>"$$tmp/html.err"; \
	test ! -s "$$tmp/html.err" || { cat "$$tmp/html.err" >&2; exit 1; }
	$(PYTHON) check-manual-sources.py
	$(PYTHON) check-manual-coverage.py
	$(PYTHON) check-prose.py
	$(PYTHON) check-workflow-smoke.py

check-haskell:
	cd .. && nix develop path:. -c bash -c 'set -eu; cabal build all; tmp=$$(mktemp -d); mkdir -p "$$tmp/ghc"; cabal exec -- ghc -outputdir "$$tmp/ghc" -idoc/examples -package agentic-cli -package agentic-dsl doc/examples/Registry.hs -o "$$tmp/manual-run"; "$$tmp/manual-run" list >/dev/null; "$$tmp/manual-run" run hello --scripted >/dev/null; runner=$$(cabal list-bin agentic-run); python3 doc/check-manual-cli.py "$$runner"; python3 doc/check-manual-members.py; rm -rf "$$tmp"'

update-haskell-inventory:
	cd .. && nix develop path:. -c bash -c 'set -eu; cabal build all; python3 doc/check-manual-members.py --write'

clean:
	rm -rf $(BUILD_DIR)
