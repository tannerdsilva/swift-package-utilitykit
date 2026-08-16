# Installation

## Prerequisites

- Swift 6.0+ toolchain (macOS 13+)
- Xcode 16+ (recommended) or standalone Swift toolchain

## From source

```bash
git clone https://github.com/your-org/swift-package-utilitykit.git
cd swift-package-utilitykit
swift build -c release
cp .build/release/swift-package-tool /usr/local/bin/
```

## Via Makefile

```bash
make install-plugin
```

This builds the release binary, installs it to ``/usr/local/bin``, and
symlinks the Hermes plugin.

## Via install script

```bash
./scripts/install.sh
```

Supports interactive and noninteractive modes. Pass ``PLUGIN_MODE=1``
in noninteractive mode to also install the Hermes plugin.
