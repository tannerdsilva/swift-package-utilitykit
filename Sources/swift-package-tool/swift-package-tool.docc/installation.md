# Installation

## Prerequisites

- Swift 6.0+ toolchain (macOS 13+)
- Xcode 16+ (recommended) or standalone Swift toolchain

## From source

```bash
git clone git@github.com:tannerdsilva/swift-package-utilitykit.git
cd swift-package-utilitykit
swift build -c release
cp .build/release/swift-package-tool ~/.local/bin/
```

## Via Makefile

```bash
make install-plugin
```

This builds the release binary, installs it to ``~/.local/bin``, and
symlinks the Hermes plugin.  (``~/.local/bin`` is the canonical install
location — the Hermes plugin resolver falls back to it, so the installer
and the plugin agree.  Override with ``PREFIX=``/``BIN_DIR=``.)

## Via install subcommand

The ``swift-package-tool`` binary owns install/remove logic natively
(``install``, ``uninstall``, ``path-wire``):

```bash
swift-package-tool install                   # interactive (prompts: symlink/copy)
swift-package-tool install --copy            # noninteractive copy plugin
swift-package-tool install --symlink         # noninteractive symlink plugin
swift-package-tool uninstall                 # remove binaries, plugin, PATH wiring
```

``PLUGIN_MODE`` (``symlink`` or ``copy``) and ``PATH_UPDATE``/``NO_INTERACTIVE``
are honored as environment overrides.  ``install --no-plugin --no-build``
installs just the binaries from a prebuilt ``.build``.
