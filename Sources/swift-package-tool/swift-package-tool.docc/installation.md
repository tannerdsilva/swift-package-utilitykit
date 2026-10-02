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

This builds the release binary, installs it to ``~/.local/bin``, and installs
the Hermes adapter plugin into ``~/.hermes/plugins``.  (``~/.local/bin`` is
the canonical install location — the Hermes plugin resolver falls back to it,
so the installer and the plugin agree.  Override with
``PREFIX=``/``BIN_DIR=``/``PLUGINS_DIR=``.)

## Via install subcommand

The ``swift-package-tool`` binary owns install/remove logic natively
(``install``, ``uninstall``, ``path-wire``) and is harness-agnostic:

```bash
swift-package-tool install --no-build                    # binaries only (no plugin)
swift-package-tool install --plugins-dir ~/.hermes/plugins --copy    # + adapter plugin (copy)
swift-package-tool install --plugins-dir ~/.hermes/plugins --symlink # + adapter plugin (symlink)
swift-package-tool uninstall --plugins-dir ~/.hermes/plugins         # remove binaries + plugin
```

``PLUGIN_MODE`` (``symlink`` or ``copy``) and ``PATH_UPDATE``/``NO_INTERACTIVE``
are honored as environment overrides.  the adapter plugin step runs only when
a plugins dir is given (``--plugins-dir`` or ``PLUGINS_DIR``); with none, the
installer manages the binaries and PATH wiring alone.
