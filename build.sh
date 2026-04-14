#!/bin/bash
# Build Trace from source for Linux packaging.
#
# Can run inside the Docker container or natively on a system with all
# dependencies installed (see ci/deps.sh).
#
# Usage:
#   ./build.sh [options]
#
# Options:
#   --trace-src DIR    Path to Trace source (default: ../Trace)
#   --build-dir DIR    Build output directory (default: ./build)
#   --install-dir DIR  DESTDIR for staged install (default: ./build/install-root)
#   --jobs N           Parallel jobs (default: nproc or 2)
#   --debug            Debug build + localhost backend
#   --staging          Staging build + staging backend
#   --skip-install     Build only, skip install step
#   --skip-ort         Skip ONNX Runtime download

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────
TRACE_SRC="${TRACE_SRC:-${SCRIPT_DIR}/../Trace}"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/build}"
INSTALL_DIR="${INSTALL_DIR:-${BUILD_DIR}/install-root}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
BUILD_TYPE="Release"
BACKEND_URL="https://api.buildwithtrace.com/api/v3"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
fi
if [ -z "${AMPLITUDE_KEY:-}" ]; then
    echo "ERROR: AMPLITUDE_KEY not set. Add it to .env or export it." >&2
    exit 1
fi
SKIP_INSTALL=false
SKIP_ORT=false

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --trace-src)    TRACE_SRC="$2"; shift 2 ;;
        --trace-src=*)  TRACE_SRC="${1#*=}"; shift ;;
        --build-dir)    BUILD_DIR="$2"; shift 2 ;;
        --build-dir=*)  BUILD_DIR="${1#*=}"; shift ;;
        --install-dir)  INSTALL_DIR="$2"; shift 2 ;;
        --install-dir=*)INSTALL_DIR="${1#*=}"; shift ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --jobs=*)       JOBS="${1#*=}"; shift ;;
        --debug)
            BUILD_TYPE="Debug"
            BACKEND_URL="http://localhost:8000/api/v3"
            shift ;;
        --staging)
            BUILD_TYPE="Staging"
            # Set TRACE_STAGING_URL in your .env or environment, e.g.:
            #   export TRACE_STAGING_URL="http://your-staging-server/api/v3"
            BACKEND_URL="${TRACE_STAGING_URL:?ERROR: TRACE_STAGING_URL not set. Add it to .env or export it.}"
            shift ;;
        --skip-install) SKIP_INSTALL=true; shift ;;
        --skip-ort)     SKIP_ORT=true; shift ;;
        *)              shift ;;
    esac
done

# Resolve to absolute paths
TRACE_SRC="$(cd "${TRACE_SRC}" && pwd)"
mkdir -p "${BUILD_DIR}"
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"

echo "============================================"
echo "  Trace Linux Builder"
echo "============================================"
echo "  Source:     ${TRACE_SRC}"
echo "  Build dir:  ${BUILD_DIR}"
echo "  Install to: ${INSTALL_DIR}"
echo "  Build type: ${BUILD_TYPE}"
echo "  Backend:    ${BACKEND_URL}"
echo "  Jobs:       ${JOBS}"
echo "============================================"

# ── Validate source tree ─────────────────────────────────────────────
if [ ! -f "${TRACE_SRC}/CMakeLists.txt" ]; then
    echo "ERROR: Cannot find CMakeLists.txt at ${TRACE_SRC}" >&2
    echo "       Make sure --trace-src points to the Trace repository root." >&2
    exit 1
fi

# ── Download ONNX Runtime if needed ──────────────────────────────────
if [ "${SKIP_ORT}" = false ]; then
    echo ""
    echo "--- Checking ONNX Runtime ---"
    bash "${SCRIPT_DIR}/packaging/download-onnxruntime.sh" "${TRACE_SRC}"
fi

# ── Detect beta version ──────────────────────────────────────────────
TRACE_VERSION=$(grep -oP 'TRACE_SEMANTIC_VERSION\s+"?\K[^"]+' "${TRACE_SRC}/cmake/TraceVersion.cmake" || echo "")
if [[ "${TRACE_VERSION}" == *-beta ]]; then
    echo "Beta version detected (${TRACE_VERSION}): enabling KICAD_BACKEND_URL_OVERRIDE"
    BACKEND_URL_OVERRIDE=ON
else
    BACKEND_URL_OVERRIDE=OFF
fi

# ── Configure ────────────────────────────────────────────────────────
echo ""
echo "--- CMake Configure ---"
mkdir -p "${BUILD_DIR}/release"
cd "${BUILD_DIR}/release"

CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
    -DCMAKE_INSTALL_PREFIX=/usr
    -DTRACE_BACKEND_URL="${BACKEND_URL}"
    -DAMPLITUDE_API_KEY="${AMPLITUDE_KEY}"
    -DKICAD_USE_OCC=ON
    -DKICAD_SPICE=ON
    -DKICAD_BUILD_I18N=ON
    -DKICAD_USE_CMAKE_FINDPROTOBUF=ON
    -DKICAD_BUILD_QA_TESTS=OFF
    -DKICAD_BACKEND_URL_OVERRIDE="${BACKEND_URL_OVERRIDE}"
)

# Use lld if available
if command -v ld.lld &>/dev/null; then
    CMAKE_ARGS+=(-DCMAKE_CXX_FLAGS="-fuse-ld=lld")
    CMAKE_ARGS+=(-DCMAKE_C_FLAGS="-fuse-ld=lld")
fi

cmake "${CMAKE_ARGS[@]}" "${TRACE_SRC}"

# ── Build ────────────────────────────────────────────────────────────
echo ""
echo "--- Build (${JOBS} jobs) ---"
ninja -j"${JOBS}"

# ── Install to staging directory ─────────────────────────────────────
if [ "${SKIP_INSTALL}" = false ]; then
    echo ""
    echo "--- Install to ${INSTALL_DIR} ---"
    rm -rf "${INSTALL_DIR}"
    DESTDIR="${INSTALL_DIR}" ninja install

    echo ""
    echo "Staged install tree:"
    echo "  Binaries:  ${INSTALL_DIR}/usr/bin/"
    echo "  Libraries: ${INSTALL_DIR}/usr/lib/"
    echo "  Data:      ${INSTALL_DIR}/usr/share/trace/"
fi

echo ""
echo "Build complete!"
