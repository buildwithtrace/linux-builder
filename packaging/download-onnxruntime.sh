#!/bin/bash
# Download pre-built ONNX Runtime for Linux x64 and place it where
# Trace's thirdparty/onnxruntime/CMakeLists.txt expects it.
#
# Usage:
#   ./packaging/download-onnxruntime.sh /path/to/Trace

set -euo pipefail

ORT_VERSION="1.20.1"
ORT_ARCHIVE="onnxruntime-linux-x64-${ORT_VERSION}.tgz"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ORT_ARCHIVE}"

TRACE_SRC="${1:?Usage: $0 /path/to/Trace}"
ORT_DEST="${TRACE_SRC}/thirdparty/onnxruntime"

if [ -d "${ORT_DEST}/lib" ] && ls "${ORT_DEST}/lib"/libonnxruntime.so* &>/dev/null; then
    echo "ONNX Runtime ${ORT_VERSION} already present at ${ORT_DEST}/lib — skipping download."
    exit 0
fi

echo "Downloading ONNX Runtime ${ORT_VERSION}..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

wget -q --show-progress -O "${TMPDIR}/${ORT_ARCHIVE}" "${ORT_URL}"

echo "Extracting to ${ORT_DEST}/lib ..."
mkdir -p "${ORT_DEST}/lib"

tar -xzf "${TMPDIR}/${ORT_ARCHIVE}" -C "${TMPDIR}"

EXTRACTED_DIR="${TMPDIR}/onnxruntime-linux-x64-${ORT_VERSION}"

cp -a "${EXTRACTED_DIR}"/lib/libonnxruntime.so* "${ORT_DEST}/lib/"

if [ ! -d "${ORT_DEST}/include" ] || [ -z "$(ls -A "${ORT_DEST}/include" 2>/dev/null)" ]; then
    echo "Copying headers to ${ORT_DEST}/include ..."
    mkdir -p "${ORT_DEST}/include"
    cp -a "${EXTRACTED_DIR}"/include/* "${ORT_DEST}/include/"
fi

echo "ONNX Runtime ${ORT_VERSION} installed to ${ORT_DEST}"
