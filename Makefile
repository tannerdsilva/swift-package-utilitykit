# swift-package-utilitykit — build, test, and install.
#
# All install/remove maintenance operations are single-sourced in
# scripts/install.sh; the make targets below are thin, flag-mapped delegates
# so the install logic exists in exactly one place.  See
# `scripts/install.sh --help` for the full interface (flags, env vars, prompts).
#
# Usage:
#   make                         build debug binaries
#   make release                 build release binaries
#   make install                 install debug binaries only (no plugin)
#   make install-release         install release binaries only (no plugin)
#   make install-plugin          install release binaries + Hermes plugin
#   make remove                  remove binaries, plugin, and PATH wiring
#   make test                    run all Swift tests
#   make test-scripts            run the shell-script test suites
#   make clean                   remove build artifacts
#
# Target -> scripts/install.sh delegation:
#   install          --debug --no-plugin <flags>
#   install-release            --no-plugin <flags>
#   install-plugin                        <flags>
#   remove           --remove             <flags>
#
# Install knobs (env or command line, passed through to install.sh):
#   PREFIX=~/.local            parent dir; binaries go to PREFIX/bin
#   BIN_DIR=/opt/bin           exact binary dir (overrides PREFIX/bin)
#   HERMES_PLUGINS=...         Hermes plugins dir (default ~/.hermes/plugins)
#   PLUGIN_MODE=symlink|copy   plugin mode for install-plugin (required
#                              noninteractive; prompted otherwise)
#   PATH_UPDATE=0              skip harness PATH wiring
#   INSTALL_INTERACTIVE=0      never prompt (install.sh also auto-detects non-tty)
#   FORCE=1                    skip remove confirmation
#
# Examples:
#   make install-plugin                                  # interactive, full install
#   make install-plugin INSTALL_INTERACTIVE=0 PLUGIN_MODE=symlink
#   make install-release PREFIX=/usr/local               # system-wide (uses sudo)

PREFIX              ?= $(HOME)/.local
SWIFT               ?= swift
HERMES_PLUGINS      ?= $(HOME)/.hermes/plugins
PLUGIN_MODE         ?=
INSTALL_INTERACTIVE ?= 1
PATH_UPDATE         ?= 1
FORCE               ?= 0

SCRIPT = $(CURDIR)/scripts/install.sh

# Map make knobs onto the install.sh flag interface.
SCRIPT_FLAGS = \
	$(if $(filter-out 1,$(INSTALL_INTERACTIVE)),--no-interactive) \
	$(if $(filter-out 1,$(PATH_UPDATE)),--no-path-update) \
	$(if $(PLUGIN_MODE),$(if $(filter symlink copy,$(PLUGIN_MODE)),--$(PLUGIN_MODE),$(error PLUGIN_MODE must be symlink or copy (got '$(PLUGIN_MODE)')))) \
	$(if $(filter 1,$(FORCE)),--force)

.PHONY: all build release install install-release install-plugin remove test test-scripts clean

all: build

# --- build -------------------------------------------------------------------

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

# --- install / maintenance (delegated to scripts/install.sh) -----------------

install:
	bash $(SCRIPT) --debug --no-plugin $(SCRIPT_FLAGS)

install-release:
	bash $(SCRIPT) --no-plugin $(SCRIPT_FLAGS)

install-plugin:
	bash $(SCRIPT) $(SCRIPT_FLAGS)

remove:
	bash $(SCRIPT) --remove $(SCRIPT_FLAGS)

# --- test --------------------------------------------------------------------

test:
	$(SWIFT) test

test-scripts: scripts/path-wire.sh Tests/path-wire-tests.sh
	bash Tests/path-wire-tests.sh

# --- clean -------------------------------------------------------------------

clean:
	$(SWIFT) package clean
