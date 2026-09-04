# swift-package-utilitykit — build, test, and install.
#
# All install/remove/path-wiring logic lives in the swift-package-tool binary
# (`install`, `uninstall`, `path-wire` subcommands).  The make targets below
# are thin, flag-mapped delegates so the install logic exists in exactly one
# place — Swift, not shell.
#
# Usage:
#   make                         build debug binaries
#   make release                 build release binaries
#   make install                 install debug binaries only (no plugin)
#   make install-release         install release binaries only (no plugin)
#   make install-plugin          install release binaries + Hermes plugin
#   make remove                  remove binaries, plugin, and PATH wiring
#   make test                    run all Swift tests
#   make clean                   remove build artifacts
#   make path-wire DIR=<dir>     wire <dir> into the harness PATH
#   make path-wire-remove        strip the swift-package-utilitykit PATH block
#
# Target -> swift-package-tool delegation:
#   install          .build/debug/swift-package-tool install --debug --no-plugin
#   install-release  .build/release/swift-package-tool install --no-plugin
#   install-plugin   .build/release/swift-package-tool install
#   remove           .build/release/swift-package-tool uninstall
#   path-wire        swift-package-tool path-wire <dir>
#
# Install knobs (env or command line, passed through to swift-package-tool):
#   PREFIX=~/.local            parent dir; binaries go to PREFIX/bin
#   BIN_DIR=/opt/bin           exact binary dir (overrides PREFIX/bin)
#   HERMES_PLUGINS=...         Hermes plugins dir (default ~/.hermes/plugins)
#   PLUGIN_MODE=symlink|copy   plugin mode for install-plugin (required
#                              noninteractive; defaults to copy)
#   PATH_UPDATE=0              skip harness PATH wiring
#   INSTALL_INTERACTIVE=0      never prompt
#   FORCE=1                    skip remove confirmation
#
# Examples:
#   make install-plugin                                  # full install (copy)
#   make install-plugin PLUGIN_MODE=symlink
#   make install-release PREFIX=/usr/local               # system-wide (uses sudo)

PREFIX              ?= $(HOME)/.local
BIN_DIR             ?=
SWIFT               ?= swift
HERMES_PLUGINS      ?= $(HOME)/.hermes/plugins
PLUGIN_MODE         ?=
INSTALL_INTERACTIVE ?= 1
PATH_UPDATE         ?= 1
FORCE               ?= 0
DIR                 ?=

DEBUG_TOOL   = $(CURDIR)/.build/debug/swift-package-tool
RELEASE_TOOL = $(CURDIR)/.build/release/swift-package-tool

# Map make knobs onto the swift-package-tool flag interface.
# make already builds via the target dependencies, so --no-build is passed.
BUILD_FLAG = --no-build

INSTALL_FLAGS = \
	$(BUILD_FLAG) \
	$(if $(filter-out 1,$(INSTALL_INTERACTIVE)),--no-interactive) \
	$(if $(filter-out 1,$(PATH_UPDATE)),--no-path-update) \
	$(if $(PLUGIN_MODE),$(if $(filter symlink copy,$(PLUGIN_MODE)),--$(PLUGIN_MODE),$(error PLUGIN_MODE must be symlink or copy (got '$(PLUGIN_MODE)')))) \
	$(if $(BIN_DIR),--bin-dir $(BIN_DIR)) \
	--prefix $(PREFIX) \
	--hermes-plugins $(HERMES_PLUGINS)

UNINSTALL_FLAGS = \
	$(if $(filter-out 1,$(INSTALL_INTERACTIVE)),--no-interactive) \
	$(if $(filter-out 1,$(PATH_UPDATE)),--no-path-update) \
	$(if $(filter 1,$(FORCE)),--force) \
	$(if $(BIN_DIR),--bin-dir $(BIN_DIR)) \
	--prefix $(PREFIX) \
	--hermes-plugins $(HERMES_PLUGINS)

.PHONY: all build release install install-release install-plugin remove test clean path-wire path-wire-remove

all: build

# --- build -------------------------------------------------------------------

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

# --- install / maintenance (delegated to swift-package-tool) -----------------

install: build
	$(DEBUG_TOOL) install --debug --no-plugin $(INSTALL_FLAGS)

install-release: release
	$(RELEASE_TOOL) install --no-plugin $(INSTALL_FLAGS)

install-plugin: release
	$(RELEASE_TOOL) install $(INSTALL_FLAGS)

remove: release
	$(RELEASE_TOOL) uninstall $(UNINSTALL_FLAGS)

# --- harness PATH wiring ------------------------------------------------------

path-wire: release
	$(RELEASE_TOOL) path-wire $(DIR)

path-wire-remove: release
	$(RELEASE_TOOL) path-wire --remove

# --- test --------------------------------------------------------------------

test:
	$(SWIFT) test

# --- clean -------------------------------------------------------------------

clean:
	$(SWIFT) package clean
