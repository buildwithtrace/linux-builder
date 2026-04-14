#!/bin/bash
# Build Trace inside a Docker container and produce an AppImage.
#
# This is the main entrypoint for building distributable Linux packages.
# It builds a Docker image with all dependencies, then runs the build
# and packaging steps inside the container.
#
# Usage:
#   ./docker-build.sh [options]
#
# Options:
#   --trace-src DIR    Path to Trace source tree (default: ../Trace)
#   --rebuild-image    Force rebuild of the Docker image
#   --no-appimage      Build only, skip AppImage creation
#   --debug            Debug build + localhost backend
#   --staging          Staging build + staging backend
#   --jobs N           Parallel build jobs (default: nproc)
#
# Directory layout expected:
#   parent/
#   ├── trace-linux-builder/   (this repo)
#   └── Trace/                 (Trace source)

set -euo pipefail
trap 'echo "ERROR: Command failed at line $LINENO (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────
TRACE_SRC="${SCRIPT_DIR}/../Trace"
REBUILD_IMAGE=false
BUILD_APPIMAGE=true
BUILD_ARGS=()
DOCKER_IMAGE="trace-linux-builder"
JOBS="$(nproc 2>/dev/null || echo 2)"
DOCKER_CMD="docker"

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --trace-src)    TRACE_SRC="$2"; shift 2 ;;
        --trace-src=*)  TRACE_SRC="${1#*=}"; shift ;;
        --rebuild-image) REBUILD_IMAGE=true; shift ;;
        --no-appimage)  BUILD_APPIMAGE=false; shift ;;
        --debug)        BUILD_ARGS+=(--debug); shift ;;
        --staging)      BUILD_ARGS+=(--staging); shift ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --jobs=*)       JOBS="${1#*=}"; shift ;;
        *)              echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

TRACE_SRC="$(cd "${TRACE_SRC}" && pwd)"

echo "============================================"
echo "  Trace Linux Builder (Docker)"
echo "============================================"
echo "  Trace source: ${TRACE_SRC}"
echo "  Docker image: ${DOCKER_IMAGE}"
echo "  AppImage:     ${BUILD_APPIMAGE}"
echo "  Jobs:         ${JOBS}"
echo "============================================"

# ── Validate ─────────────────────────────────────────────────────────
if [ ! -f "${TRACE_SRC}/CMakeLists.txt" ]; then
    echo "ERROR: Cannot find Trace source at ${TRACE_SRC}" >&2
    echo "       Use --trace-src to specify the path." >&2
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed or not in PATH." >&2
    exit 1
fi

# Check Docker daemon connectivity; fall back to sudo if needed
if ! docker info >/dev/null 2>&1; then
    echo "Cannot connect to Docker daemon. Trying with sudo..."
    if sudo docker info >/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
        echo "Using: sudo docker"
    else
        echo "ERROR: Cannot connect to Docker daemon, even with sudo." >&2
        echo "       Make sure Docker is running:" >&2
        echo "         sudo systemctl start docker" >&2
        echo "       Or add your user to the docker group:" >&2
        echo "         sudo usermod -aG docker \$USER" >&2
        echo "         (then log out and back in)" >&2
        exit 1
    fi
fi

# ── Build Docker image ───────────────────────────────────────────────
IMAGE_EXISTS=$(${DOCKER_CMD} images -q "${DOCKER_IMAGE}" 2>/dev/null || true)

if [ -z "${IMAGE_EXISTS}" ] || [ "${REBUILD_IMAGE}" = true ]; then
    echo ""
    echo "--- Building Docker image (this may take several minutes the first time) ---"
    ${DOCKER_CMD} build \
        --network=host \
        -t "${DOCKER_IMAGE}" \
        "${SCRIPT_DIR}"
else
    echo "Docker image '${DOCKER_IMAGE}' already exists. Use --rebuild-image to force rebuild."
fi

# ── Prepare output directory ─────────────────────────────────────────
OUTPUT_DIR="${SCRIPT_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

# ── Run build inside container ───────────────────────────────────────
echo ""
echo "--- Running build inside Docker ---"

APPIMAGE_CMD=""
if [ "${BUILD_APPIMAGE}" = true ]; then
    APPIMAGE_CMD="bash /builder/packaging/build-appimage.sh --build-dir /build --output-dir /output --trace-src /build/trace-src"
fi

${DOCKER_CMD} run --rm \
    --network=host \
    -v "${TRACE_SRC}:/src:ro" \
    -v "${SCRIPT_DIR}:/builder:ro" \
    -v "${OUTPUT_DIR}:/output" \
    -e JOBS="${JOBS}" \
    "${DOCKER_IMAGE}" \
    -c "
        set -e

        echo '--- Copying source tree ---'
        cp -a /src /build/trace-src

        bash /builder/build.sh \
            --trace-src /build/trace-src \
            --build-dir /build \
            --install-dir /build/install-root \
            --jobs ${JOBS} \
            ${BUILD_ARGS[*]:-}

        ${APPIMAGE_CMD}

        echo ''
        echo 'Build inside container finished successfully.'
    "

echo ""
echo "============================================"
if [ "${BUILD_APPIMAGE}" = true ]; then
    echo "  Build complete! Output:"
    ls -lh "${OUTPUT_DIR}"/*.AppImage 2>/dev/null || echo "  (no AppImage found — check build logs)"
else
    echo "  Build complete (no AppImage — use without --no-appimage to package)."
fi
echo "============================================"
