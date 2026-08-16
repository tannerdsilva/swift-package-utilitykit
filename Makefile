# swift-package-utilitykit — build, install, and remove
#
# The primary delivery model is standalone binaries installed on the host or
# container where the agentic harness runs.  The SPM command plugin is a
# secondary interface for interactive `swift package` use.
#
# Usage:
#   make                    build debug binaries
#   make release            build release binaries
#   make install            install debug binaries to BIN_DIR
#   make install-release    build release + install binaries
#   make install-plugin     build release + install binaries + install Hermes plugin
#   make remove             remove installed binaries and Hermes plugin
#   make test               run all tests
#   make clean              remove build artifacts
#
# Default install path (user-local, no sudo):
#   $(HOME)/.local/bin
#
# Override with PREFIX (sets parent directory, binaries go to PREFIX/bin):
#   make install PREFIX=/usr/local          # system-wide (requires sudo)
#   make install PREFIX=$(HOME)/.local      # user-local (default)
#
# Override with BIN_DIR (full path, takes precedence over PREFIX/bin):
#   make install BIN_DIR=/opt/my-tools/bin  # custom location
#
# Interactive / noninteractive (applies to all install/remove targets):
#   INSTALL_INTERACTIVE=1   (default) prompt before actions when stdin is a tty
#   INSTALL_INTERACTIVE=0   skip prompts, use PLUGIN_MODE value directly
#
# Plugin install mode (REQUIRED in noninteractive mode):
#   PLUGIN_MODE=symlink     symlink hermes-plugin/ into ~/.hermes/plugins/
#   PLUGIN_MODE=copy        copy hermes-plugin/ into ~/.hermes/plugins/
#
# Removal:
#   FORCE=1                 skip confirmation prompt during removal

PREFIX              ?= $(HOME)/.local
SWIFT               ?= swift
VERSION             ?= 0.1.0
HERMES_PLUGINS      ?= $(HOME)/.hermes/plugins
INSTALL_INTERACTIVE ?= 1

BINARIES    = swift-package-tool normalizer-tool
PLUGIN_NAME = swift-package-utilitykit
PLUGIN_SRC  = $(CURDIR)/hermes-plugin
PLUGIN_DST  = $(HERMES_PLUGINS)/$(PLUGIN_NAME)

# Resolve the actual install directory for binaries.
# BIN_DIR takes precedence; otherwise PREFIX/bin.
ifneq ($(BIN_DIR),)
    INSTALL_DIR := $(BIN_DIR)
else
    INSTALL_DIR := $(PREFIX)/bin
endif

# Detect if we need sudo for INSTALL_DIR
ifneq ($(shell test -w $(INSTALL_DIR) 2>/dev/null && echo writable),writable)
    SUDO := sudo
else
    SUDO :=
endif

.PHONY: all build release install install-release install-plugin remove test clean

all: build

# --- build -------------------------------------------------------------------

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

# --- install binaries --------------------------------------------------------

install: build
	@echo ""
	@echo "=== Installing binaries ==="
	@echo "  Target:  $(INSTALL_DIR)/{$(BINARIES)}"
	@echo "  Sudo:    $(if $(SUDO),yes (not writable),no)"
	@_confirm="y"; \
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ]; then \
		printf "  Install binaries? [Y/n] "; \
		read -r _confirm; \
		_confirm=$${_confirm:-y}; \
	fi; \
	case "$$_confirm" in y|Y|yes|YES) ;; *) echo "  Cancelled."; exit 0;; esac
	$(SUDO) install -d "$(INSTALL_DIR)"
	$(foreach bin,$(BINARIES),$(SUDO) install .build/debug/$(bin) "$(INSTALL_DIR)/$(bin)";)
	@echo "  Done."

install-release: release
	@echo ""
	@echo "=== Installing binaries (release) ==="
	@echo "  Target:  $(INSTALL_DIR)/{$(BINARIES)}"
	@echo "  Sudo:    $(if $(SUDO),yes (not writable),no)"
	@_confirm="y"; \
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ]; then \
		printf "  Install binaries? [Y/n] "; \
		read -r _confirm; \
		_confirm=$${_confirm:-y}; \
	fi; \
	case "$$_confirm" in y|Y|yes|YES) ;; *) echo "  Cancelled."; exit 0;; esac
	$(SUDO) install -d "$(INSTALL_DIR)"
	$(foreach bin,$(BINARIES),$(SUDO) install .build/release/$(bin) "$(INSTALL_DIR)/$(bin)";)
	@echo "  Done."

# --- install plugin ----------------------------------------------------------

install-plugin: install-release
	@echo ""
	@echo "=== Installing Hermes plugin ==="
	@mkdir -p "$(HERMES_PLUGINS)"
	@if [ -L "$(PLUGIN_DST)" ] || [ -d "$(PLUGIN_DST)" ]; then \
		echo "  Removing previous plugin at $(PLUGIN_DST)..."; \
		rm -rf "$(PLUGIN_DST)"; \
	fi
	@_mode=""; \
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ]; then \
		while true; do \
			printf "  Install plugin as [s]ymlink or [c]opy? [S/c] "; \
			read -r _choice; \
			_choice=$${_choice:-s}; \
			case "$$_choice" in \
				s|S|symlink) _mode=symlink; break;; \
				c|C|copy)    _mode=copy;   break;; \
			esac; \
		done; \
	else \
		if [ "$(PLUGIN_MODE)" = "" ]; then \
			echo "  ERROR: PLUGIN_MODE is required in noninteractive mode."; \
			echo "  Set PLUGIN_MODE=symlink or PLUGIN_MODE=copy."; \
			exit 1; \
		fi; \
		_mode="$(PLUGIN_MODE)"; \
	fi; \
	if [ "$$_mode" = "symlink" ]; then \
		echo "  Symlinking plugin: $(PLUGIN_DST) -> $(PLUGIN_SRC)"; \
		ln -sf "$(PLUGIN_SRC)" "$(PLUGIN_DST)"; \
		echo "  Plugin symlinked."; \
	else \
		echo "  Copying plugin: $(PLUGIN_SRC) -> $(PLUGIN_DST)"; \
		rm -rf "$(PLUGIN_DST)"; \
		cp -R "$(PLUGIN_SRC)" "$(PLUGIN_DST)"; \
		echo "  Plugin copied."; \
	fi
	@echo ""
	@echo "=== Installation complete ==="
	@echo "  Binaries:  $(INSTALL_DIR)/{$(BINARIES)}"
	@echo "  Plugin:    $(PLUGIN_DST)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Ensure $(INSTALL_DIR) is in your PATH"
	@echo "  2. Restart Hermes or run:        hermes plugin reload"
	@echo "  3. Test the plugin:              hermes tool list | grep pkg_"

# --- remove ------------------------------------------------------------------

remove:
	@echo ""
	@echo "=== Removing swift-package-utilitykit ==="
	@_binaries=""; \
	_checked_dirs=""; \
	_remove_dirs="$(INSTALL_DIR) $(HOME)/.local/bin /usr/local/bin"; \
	if [ -n "$(BIN_DIR)" ]; then \
		_remove_dirs="$(BIN_DIR) $$_remove_dirs"; \
	fi; \
	for d in $$_remove_dirs; do \
		_checked_dirs="$$_checked_dirs $$d"; \
		for bin in $(BINARIES); do \
			if [ -f "$$d/$$bin" ]; then \
				_binaries="$$_binaries $$d/$$bin"; \
			fi; \
		done; \
	done; \
	_plugin=""; \
	if [ -L "$(PLUGIN_DST)" ] || [ -d "$(PLUGIN_DST)" ]; then \
		_plugin="$(PLUGIN_NAME)"; \
	fi; \
	if [ -z "$$_binaries" ] && [ -z "$$_plugin" ]; then \
		echo "  Nothing to remove."; \
		exit 0; \
	fi; \
	echo "  Found: binaries($${_binaries:-none}) plugin($${_plugin:-none})"; \
	echo "  Checked:$$_checked_dirs"; \
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ] && [ "$(FORCE)" != "1" ]; then \
		printf "  Remove all? [y/N] "; \
		read -r _confirm; \
		case "$$_confirm" in \
			y|Y|yes|YES) :;; \
			*) echo "  Cancelled."; exit 0;; \
		esac; \
	fi; \
	for bin_path in $$_binaries; do \
		_dir=$$(dirname "$$bin_path"); \
		if [ ! -w "$$_dir" ] 2>/dev/null; then \
			sudo rm -f "$$bin_path"; \
			echo "  Removed: $$bin_path (sudo)"; \
		else \
			rm -f "$$bin_path"; \
			echo "  Removed: $$bin_path"; \
		fi; \
	done; \
	if [ -L "$(PLUGIN_DST)" ] || [ -d "$(PLUGIN_DST)" ]; then \
		rm -rf "$(PLUGIN_DST)"; \
		echo "  Removed: $(PLUGIN_DST)"; \
	fi; \
	echo "  Done."

# --- test --------------------------------------------------------------------

test:
	$(SWIFT) test

# --- clean -------------------------------------------------------------------

clean:
	$(SWIFT) package clean
