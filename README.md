# Trace Linux Builder

This repository contains the build system for creating distributable Linux packages for **Trace**, a fork of KiCad focused on AI-powered PCB design.

Currently produces **AppImage** packages using a pipeline aligned with [KiCad's official AppImage builder](https://gitlab.com/kicad/packaging/kicad-appimage). A `debian/` skeleton is included for future `.deb` packaging.

## Requirements

- **Docker** (recommended) or a native Debian Bookworm system
- At least **30GB** of free disk space
- At least **8GB** of RAM (16GB recommended)

## Directory Structure

The build system expects the following layout:

```
parent-directory/
├── trace-linux-builder/     # This repository
└── Trace/                   # The Trace source code repository
```

**Important:** Both repositories must be in the same parent directory. The build scripts reference the Trace source using a relative path (`../Trace`).

## Setup

### 1. Clone both repositories

```bash
cd /path/to/parent-directory

# Clone this repository
git clone https://github.com/buildwithtrace/trace-linux-builder.git

# Clone the Trace source code
git clone https://github.com/buildwithtrace/trace.git Trace
```

### 2. Install Docker (if not already installed)

```bash
# Ubuntu
sudo apt-get update
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
# Log out and back in for group membership to take effect
```

## Building Trace

### Quick Start (Docker)

Build an AppImage with a single command:

```bash
cd trace-linux-builder
./docker-build.sh
```

The AppImage will be written to `./output/Trace-<version>-x86_64.AppImage`.

### Build Options

```bash
# Force rebuild of the Docker image (e.g., after changing Dockerfile)
./docker-build.sh --rebuild-image

# Build only, skip AppImage creation
./docker-build.sh --no-appimage

# Use a different Trace source location
./docker-build.sh --trace-src /path/to/Trace

# Control parallel jobs
./docker-build.sh --jobs 4

# Debug build (localhost backend)
./docker-build.sh --debug

# Staging build (staging backend)
./docker-build.sh --staging
```

### Native Build (Without Docker)

If you prefer to build directly on your system (Debian Bookworm):

#### Install dependencies

```bash
# Source the dependency list
source ci/deps.sh

sudo apt-get update
sudo apt-get install -y "${BUILD_DEPS[@]}"
```

#### Build

```bash
./build.sh
```

#### Create AppImage

```bash
./packaging/build-appimage.sh
```

The packaging script downloads the required tools (sharun, uruntime, dwarfs) automatically.

### build.sh Options

The core build script accepts these flags:

| Flag | Description |
|------|-------------|
| `--trace-src DIR` | Path to Trace source (default: `../Trace`) |
| `--build-dir DIR` | Build output directory (default: `./build`) |
| `--install-dir DIR` | DESTDIR for staged install (default: `./build/install-root`) |
| `--jobs N` | Parallel build jobs (default: `nproc`) |
| `--debug` | Debug build + localhost backend |
| `--staging` | Staging build + staging backend |
| `--skip-install` | Build only, skip install step |
| `--skip-ort` | Skip ONNX Runtime download |

## Output

The built AppImage will be located at:

```
trace-linux-builder/output/Trace-<version>-x86_64.AppImage
```

The AppImage includes:
- Trace main application and all sub-applications
- All required shared libraries (bundled via sharun lib4bin for complete portability)
- WebKit2GTK with binary-patched helper process paths
- Mesa OpenGL stack (DRI drivers, GLVND)
- ONNX Runtime for AI features
- Python standard library and packages
- GTK3 theme integration

### Running the AppImage

```bash
chmod +x Trace-*-x86_64.AppImage
./Trace-*-x86_64.AppImage
```

To access internal binaries, provide the executable name as the first argument:

```bash
./Trace-*-x86_64.AppImage eeschema
./Trace-*-x86_64.AppImage pcbnew
./Trace-*-x86_64.AppImage trace-cli
```

## How It Works

### Docker Build Flow

1. **`docker-build.sh`** builds a Docker image from `Dockerfile` (Debian Bookworm with all build dependencies)
2. The Trace source is copied into the container (read-only mount, then copied for write access)
3. **`build.sh`** runs inside the container:
   - Downloads ONNX Runtime 1.20.1 pre-built binaries
   - Configures with CMake (Ninja generator, `-DCMAKE_INSTALL_PREFIX=/usr`)
   - Builds with Ninja
   - Installs to a staging directory via `DESTDIR`
4. **`packaging/build-appimage.sh`** assembles the AppImage using KiCad's proven pipeline:
   - Downloads **sharun** (library bundler + runtime loader), **uruntime** (AppImage runtime), and **DwarFS** (compressed filesystem)
   - Runs `sharun lib4bin` to discover and bundle ALL transitive shared library dependencies
   - Restructures the AppDir from FHS layout to sharun layout (`shared/bin/`, `shared/lib/`, `share/`)
   - Binary-patches `libwebkit2gtk` so WebKit helper processes (WebKitNetworkProcess, WebKitWebProcess) resolve to bundled copies via a runtime symlink
   - Builds a JSC stack sanitizer fix for Boost.Context coroutine compatibility
   - Bundles Mesa OpenGL drivers and gdk-pixbuf loaders (dlopen'd at runtime, invisible to ldd)
   - Generates a `.env` file for runtime environment variables (read automatically by sharun)
   - Strips debug symbols from all ELF binaries
   - Creates the final AppImage using `mkdwarfs` with `uruntime` header (DwarFS + zstd compression)

### Toolchain

| Tool | Version | Purpose |
|------|---------|---------|
| [sharun](https://github.com/VHSgunzo/sharun) | v0.8.1 | Library bundler (`lib4bin`) + runtime loader |
| [uruntime](https://github.com/VHSgunzo/uruntime) | v0.5.6 | AppImage runtime (replaces appimagetool) |
| [DwarFS](https://github.com/mhx/dwarfs) | v0.14.1 | Compressed filesystem (replaces squashfs) |

### Why Debian Bookworm?

The Docker image uses Debian Bookworm as its base, aligned with KiCad's official AppImage builder. Bookworm ships glibc 2.36, webkit2gtk-4.1, and wxWidgets 3.2 natively (no PPA required). The resulting AppImage runs on any system with glibc >= 2.36 (Ubuntu 22.04.1+, Debian 12+, Fedora 37+, and newer).

### ONNX Runtime

Trace uses ONNX Runtime for its AI vector search features. The pre-built binaries are downloaded automatically during the build from [GitHub releases](https://github.com/microsoft/onnxruntime/releases/tag/v1.20.1). The headers are already included in the Trace source tree at `thirdparty/onnxruntime/include/`.

## Future: .deb Packaging

A `debian/` directory is included with a valid packaging skeleton. To build a `.deb` package (not yet fully tested):

```bash
# Symlink debian/ into the Trace source
ln -s /path/to/trace-linux-builder/debian /path/to/Trace/debian

# Install build tools
sudo apt-get install -y devscripts debhelper lintian

# Build
cd /path/to/Trace
debuild -us -uc -b

# Result: ../trace_1.3.0-1_amd64.deb
```

## Troubleshooting

### Docker build fails with permission errors

Make sure your user is in the `docker` group:

```bash
sudo usermod -aG docker $USER
# Log out and back in
```

### Build runs out of memory

Reduce parallel jobs:

```bash
./docker-build.sh --jobs 2
```

### AppImage won't start

The AppImage uses uruntime (DwarFS-based) which does not require FUSE. If you still encounter issues, try extracting and running directly:

```bash
URUNTIME_EXTRACT=1 ./Trace-*-x86_64.AppImage --appimage-extract
./squashfs-root/AppRun
```

### ONNX Runtime not found at runtime

The AppImage should bundle the ONNX Runtime `.so` files automatically. If AI features don't work, check that `libonnxruntime.so` is inside the AppImage:

```bash
URUNTIME_EXTRACT=1 ./Trace-*-x86_64.AppImage --appimage-extract
ls squashfs-root/shared/lib/libonnxruntime*
```

### WebKit / WebView errors

The build pipeline binary-patches `libwebkit2gtk` and bundles all helper processes. If you see WebKit errors:

1. Check that `/tmp/.trace-wk-helpers` symlink exists at runtime (created by AppRun)
2. Verify helpers are present: `ls squashfs-root/shared/lib/webkit2gtk-4.1/`
3. Check for JSC stack errors (the `jsc-stack-fix.so` LD_PRELOAD should handle Boost.Context crashes)

### Clean build

Remove all build artifacts:

```bash
rm -rf build/ output/
```

To also remove the Docker image:

```bash
docker rmi trace-linux-builder
```

## Architecture

This builder is aligned with KiCad's official AppImage packaging pipeline:

- **Debian Bookworm** base (same as KiCad's CI)
- **sharun + uruntime + DwarFS** toolchain (same as KiCad's pipeline)
- **Binary-patched WebKit** helper paths (same technique as KiCad)
- **Bundled Mesa OpenGL** stack for portability
- Trace-specific additions: ONNX Runtime, AI models, Trace branding and backend configuration

## Contributing

Contributions are welcome for:

- Build system improvements
- Packaging for additional formats (Flatpak, Snap)
- Testing on additional distributions
- Documentation updates

## License

This build system is licensed under the GNU General Public License v3 (GPLv3), consistent with Trace and KiCad.

## Credits

Aligned with [KiCad AppImage](https://gitlab.com/kicad/packaging/kicad-appimage) packaging pipeline. Inspired by [trace-mac-builder](https://github.com/buildwithtrace/trace-mac-builder).
