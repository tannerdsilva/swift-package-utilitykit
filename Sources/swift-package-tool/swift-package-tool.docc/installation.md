# Installation

## Prerequisites

- Swift 6.0+ toolchain (macOS 13+)
- Xcode 16+ (recommended) or standalone Swift toolchain

## From source

```bash
git clone https://github.com/your-org/swift-package-utilitykit.git
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

## Via install script

```bash
./scripts/install.sh
```

Supports interactive and noninteractive modes. Pass ``PLUGIN_MODE=1``
in noninteractive mode to also install the Hermes plugin.
