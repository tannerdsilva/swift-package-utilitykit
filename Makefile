# swift-package-utilitykit — build, install, and remove
#
# The primary delivery model is standalone binaries installed on the host or
# container where the agentic harness runs.  The SPM command plugin is a
# secondary interface for interactive `swift package` use.
#
# Usage:
#   make                    build debug binaries
#   make release            build release binaries
#   make install            install debug binaries to PREFIX/bin
#   make install-release    build release + install binaries
#   make install-plugin     build release + install binaries + install Hermes plugin
#   make remove             remove installed binaries and Hermes plugin
#   make test               run all tests
#   make clean              remove build artifacts
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

PREFIX              ?= /usr/local
SWIFT               ?= swift
VERSION             ?= 0.1.0
HERMES_PLUGINS      ?= $(HOME)/.hermes/plugins
INSTALL_INTERACTIVE ?= 1

BINARIES    = swift-code-query normalizer-tool
PLUGIN_NAME = swift-package-utilitykit
PLUGIN_SRC  = $(CURDIR)/hermes-plugin
PLUGIN_DST  = $(HERMES_PLUGINS)/$(PLUGIN_NAME)

# Detect if we need sudo for PREFIX/bin
ifneq ($(shell test -w $(PREFIX)/bin 2>/dev/null && echo writable),writable)
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
	@echo "  Target:  $(PREFIX)/bin/{$(BINARIES)}"
	@echo "  Sudo:    $(if $(SUDO),yes (not writable),no)"
	@_confirm="y"; \
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ]; then \
		printf "  Install binaries? [Y/n] "; \
		read -r _confirm; \
		_confirm=$${_confirm:-y}; \
	fi; \
	case "$$_confirm" in y|Y|yes|YES) ;; *) echo "  Cancelled."; exit 0;; esac
	$(SUDO) install -d "$(PREFIX)/bin"
	$(foreach bin,$(BINARIES),$(SUDO) install .build/debug/$(bin) "$(PREFIX)/bin/$(bin)";)
	@echo "  Done."

install-release: release
	@echo ""
	@echo "=== Installing binaries (release) ==="
	@echo "  Target:  $(PREFIX)/bin/{$(BINARIES)}"
	@echo "  Sudo:    $(if $(SUDO),yes (not writable),no)"
	@_confirm="y"; \
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ]; then \
		printf "  Install binaries? [Y/n] "; \
		read -r _confirm; \
		_confirm=$${_confirm:-y}; \
	fi; \
	case "$$_confirm" in y|Y|yes|YES) ;; *) echo "  Cancelled."; exit 0;; esac
	$(SUDO) install -d "$(PREFIX)/bin"
	$(foreach bin,$(BINARIES),$(SUDO) install .build/release/$(bin) "$(PREFIX)/bin/$(bin)";)
	@echo "  Done."

# --- install plugin ----------------------------------------------------------

define plugin_symlink
	@echo "  Symlinking plugin: $(PLUGIN_DST) -> $(PLUGIN_SRC)"
	@ln -sf "$(PLUGIN_SRC)" "$(PLUGIN_DST)"
	@echo "  Plugin symlinked."
endef

define plugin_copy
	@echo "  Copying plugin: $(PLUGIN_SRC) -> $(PLUGIN_DST)"
	@rm -rf "$(PLUGIN_DST)"
	@cp -R "$(PLUGIN_SRC)" "$(PLUGIN_DST)"
	@echo "  Plugin copied."
endef

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
		$(plugin_symlink) \
	else \
		$(plugin_copy) \
	fi
	@echo ""
	@echo "=== Installation complete ==="
	@echo "  Binaries:  $(PREFIX)/bin/{$(BINARIES)}"
	@echo "  Plugin:    $(PLUGIN_DST)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Verify binaries are in PATH:  swift-code-query --version"
	@echo "  2. Restart Hermes or run:        hermes plugin reload"
	@echo "  3. Test the plugin:              hermes tool list | grep pkg_"

# --- remove ------------------------------------------------------------------

remove:
	@echo ""
	@echo "=== Removing swift-package-utilitykit ==="
	@_binaries=""; \
	for bin in $(BINARIES); do \
		if [ -f "$(PREFIX)/bin/$$bin" ]; then \
			_binaries="$$_binaries $$bin"; \
		fi; \
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
	if [ "$(INSTALL_INTERACTIVE)" = "1" ] && [ -t 0 ] && [ "$(FORCE)" != "1" ]; then \
		printf "  Remove all? [y/N] "; \
		read -r _confirm; \
		case "$$_confirm" in \
			y|Y|yes|YES) :;; \
			*) echo "  Cancelled."; exit 0;; \
		esac; \
	fi; \
	for bin in $(BINARIES); do \
		if [ -f "$(PREFIX)/bin/$$bin" ]; then \
			$(SUDO) rm -f "$(PREFIX)/bin/$$bin"; \
			echo "  Removed: $(PREFIX)/bin/$$bin"; \
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
