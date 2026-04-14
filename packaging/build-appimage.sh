#!/usr/bin/env bash
set -euo pipefail

# Assemble a Trace AppImage using sharun + uruntime (aligned with KiCad's pipeline).
#
# Usage:
#   ./packaging/build-appimage.sh [options]
#
# Options:
#   --build-dir DIR    Where build.sh wrote its output (default: ./build)
#   --install-dir DIR  DESTDIR root (default: BUILD_DIR/install-root)
#   --output-dir DIR   Where to place the final AppImage (default: ./output)
#   --trace-src DIR    Trace source tree (for icon fallback; default: ../Trace)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────
BUILD_DIR="${BUILD_DIR:-${BUILDER_DIR}/build}"
INSTALL_DIR=""
OUTPUT_DIR="${OUTPUT_DIR:-${BUILDER_DIR}/output}"
TRACE_SRC="${TRACE_SRC:-${BUILDER_DIR}/../Trace}"
ARCH="${ARCH:-x86_64}"

# Pinned tool versions (match KiCad's CI)
SHARUN_VERSION="${SHARUN_VERSION:-v0.8.1}"
URUNTIME_VERSION="${URUNTIME_VERSION:-v0.5.6}"
DWARFS_VERSION="${DWARFS_VERSION:-v0.14.1}"

SHARUN_SHA256="${SHARUN_SHA256:-18d970f56eca2c527ffd3993b161b6bc340055129db14b394a77cb67d8bbfff9}"
URUNTIME_SHA256="${URUNTIME_SHA256:-6416a112fac1e9983b1c0738cd140f17dc1205f515b9bdb36b4607ef98ee2a70}"
DWARFS_SHA256="${DWARFS_SHA256:-f3a117fd6d5b7304944b199af7fdb8086a48c509ea2e9832255d8f9a54c98587}"

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --build-dir)    BUILD_DIR="$2"; shift 2 ;;
        --build-dir=*)  BUILD_DIR="${1#*=}"; shift ;;
        --install-dir)  INSTALL_DIR="$2"; shift 2 ;;
        --install-dir=*)INSTALL_DIR="${1#*=}"; shift ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}"; shift ;;
        --trace-src)    TRACE_SRC="$2"; shift 2 ;;
        --trace-src=*)  TRACE_SRC="${1#*=}"; shift ;;
        *)              echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "${INSTALL_DIR}" ]; then
    INSTALL_DIR="${BUILD_DIR}/install-root"
fi

APPDIR="${BUILD_DIR}/Trace.AppDir"

echo "============================================"
echo "  Trace AppImage Builder (sharun pipeline)"
echo "============================================"
echo "  Install root: ${INSTALL_DIR}"
echo "  Output dir:   ${OUTPUT_DIR}"
echo "============================================"

# ── Validate ─────────────────────────────────────────────────────────
if [ ! -d "${INSTALL_DIR}/usr/bin" ]; then
    echo "ERROR: No install tree found at ${INSTALL_DIR}/usr/bin" >&2
    echo "       Run build.sh first." >&2
    exit 1
fi

# ── Determine version for output filename ────────────────────────────
TRACE_VERSION="unknown"
VERSION_CMAKE="${BUILD_DIR}/trace-src/cmake/TraceVersion.cmake"
if [ ! -f "${VERSION_CMAKE}" ]; then
    VERSION_CMAKE="${TRACE_SRC}/cmake/TraceVersion.cmake"
fi
if [ -f "${VERSION_CMAKE}" ]; then
    TRACE_VERSION=$(grep -oP 'TRACE_SEMANTIC_VERSION\s+"?\K[0-9.]+' "${VERSION_CMAKE}" || echo "unknown")
fi

# =====================================================================
# HELPER FUNCTIONS
# =====================================================================

fetch_sharun_tools(){
    echo ""
    echo "--- Downloading sharun toolchain ---"

    local sharun_url="https://github.com/VHSgunzo/sharun/releases/download/${SHARUN_VERSION}/sharun-${ARCH}"
    local uruntime_url="https://github.com/VHSgunzo/uruntime/releases/download/${URUNTIME_VERSION}/uruntime-appimage-dwarfs-${ARCH}"
    local dwarfs_url="https://github.com/mhx/dwarfs/releases/download/${DWARFS_VERSION}/dwarfs-universal-${DWARFS_VERSION#v}-Linux-${ARCH}"

    wget -q "${sharun_url}" -O /tmp/sharun
    echo "${SHARUN_SHA256}  /tmp/sharun" | sha256sum -c -
    install -m 0755 /tmp/sharun /usr/local/bin/sharun

    wget -q "${uruntime_url}" -O /tmp/uruntime
    echo "${URUNTIME_SHA256}  /tmp/uruntime" | sha256sum -c -
    install -m 0755 /tmp/uruntime /usr/local/bin/uruntime

    wget -q "${dwarfs_url}" -O /tmp/dwarfs-universal
    echo "${DWARFS_SHA256}  /tmp/dwarfs-universal" | sha256sum -c -
    install -m 0755 /tmp/dwarfs-universal /usr/local/bin/dwarfs-universal
    ln -sf dwarfs-universal /usr/local/bin/mkdwarfs

    echo "Installed sharun ${SHARUN_VERSION}, uruntime ${URUNTIME_VERSION}, dwarfs ${DWARFS_VERSION}"
}

bundle_pixbuf_loaders(){
    local appdir="$1"
    local src_dir
    src_dir=$(find /usr/lib -type d -name "loaders" -path "*/gdk-pixbuf-2.0/*" 2>/dev/null | head -1)

    if [[ -z "${src_dir}" ]]; then
        echo "WARNING: gdk-pixbuf loaders not found, SVG icons may not render" >&2
        return 0
    fi

    local abi_ver
    abi_ver=$(basename "$(dirname "${src_dir}")")
    local dest_dir="${appdir}/shared/lib/gdk-pixbuf-2.0/${abi_ver}/loaders"
    mkdir -p "${dest_dir}"

    cp -a "${src_dir}/"*.so "${dest_dir}/" 2>/dev/null || true
    local loader_count
    loader_count=$(find "${dest_dir}" -name '*.so' | wc -l)

    for loader in "${dest_dir}/"*.so; do
        [[ -f "${loader}" ]] || continue
        ldd "${loader}" 2>/dev/null | awk '/=> \//{print $3}' | while read -r dep; do
            local name
            name=$(basename "${dep}")
            if [[ ! -f "${appdir}/shared/lib/${name}" ]]; then
                cp -L "${dep}" "${appdir}/shared/lib/"
            fi
        done
    done

    local cache_dir="${appdir}/shared/lib/gdk-pixbuf-2.0/${abi_ver}"
    local query_loaders=""
    query_loaders=$(command -v gdk-pixbuf-query-loaders 2>/dev/null || true)

    if [[ -z "${query_loaders}" ]]; then
        query_loaders=$(find /usr/lib -name "gdk-pixbuf-query-loaders" -type f -executable 2>/dev/null | head -1)
    fi

    if [[ -n "${query_loaders}" ]]; then
        GDK_PIXBUF_MODULEDIR="${dest_dir}" "${query_loaders}" > "${cache_dir}/loaders.cache"
        sed -i 's|"/.*/loaders/|"|' "${cache_dir}/loaders.cache"
    else
        local sys_cache
        sys_cache=$(find /usr/lib -name "loaders.cache" -path "*/gdk-pixbuf-2.0/*" 2>/dev/null | head -1)
        if [[ -n "${sys_cache}" ]]; then
            cp "${sys_cache}" "${cache_dir}/loaders.cache"
            sed -i 's|"/.*/loaders/|"|' "${cache_dir}/loaders.cache"
        fi
    fi

    if ! grep -qF "+/gdk-pixbuf-2.0/${abi_ver}/loaders" "${appdir}/shared/lib/lib.path" 2>/dev/null; then
        echo "+/gdk-pixbuf-2.0/${abi_ver}/loaders" >> "${appdir}/shared/lib/lib.path"
    fi

    echo "Bundled ${loader_count} gdk-pixbuf loaders"
}

deploy_opengl(){
    local appdir="$1"
    local lib_dir="/usr/lib/x86_64-linux-gnu"
    local shared_lib="${appdir}/shared/lib"
    local deployed=0

    if [[ -d "${lib_dir}/dri" ]]; then
        cp -a "${lib_dir}/dri" "${shared_lib}/"
        local dri_count
        dri_count=$(find "${shared_lib}/dri" -name '*.so' -type f -o -name '*.so' -type l | wc -l)
        deployed=$((deployed + dri_count))

        if ! grep -qF '+/dri' "${shared_lib}/lib.path" 2>/dev/null; then
            echo "+/dri" >> "${shared_lib}/lib.path"
        fi
    fi

    for pattern in libGLX_mesa.so* libEGL_mesa.so* libglapi.so* libgallium*.so*; do
        for f in "${lib_dir}/"${pattern}; do
            [[ -f "${f}" ]] || continue
            local name
            name=$(basename "${f}")
            if [[ ! -f "${shared_lib}/${name}" ]]; then
                cp -L "${f}" "${shared_lib}/"
                deployed=$((deployed + 1))
            fi
        done
    done

    local mesa_deps=()
    for mesa_lib in "${shared_lib}/"libGLX_mesa.so* "${shared_lib}/"libEGL_mesa.so*; do
        [[ -f "${mesa_lib}" ]] && mesa_deps+=("${mesa_lib}")
    done
    for dri_drv in "${shared_lib}/dri/"*.so; do
        [[ -f "${dri_drv}" ]] && mesa_deps+=("${dri_drv}")
    done

    for mesa_lib in "${mesa_deps[@]}"; do
        ldd "${mesa_lib}" 2>/dev/null | awk '/=> \//{print $3}' | while read -r dep; do
            local name
            name=$(basename "${dep}")
            if [[ ! -f "${shared_lib}/${name}" ]]; then
                cp -L "${dep}" "${shared_lib}/"
            fi
        done
    done

    local glvnd_src="/usr/share/glvnd/egl_vendor.d"
    if [[ -d "${glvnd_src}" ]]; then
        mkdir -p "${appdir}/share/glvnd/egl_vendor.d"
        cp -a "${glvnd_src}/"*.json "${appdir}/share/glvnd/egl_vendor.d/" 2>/dev/null || true
    fi

    echo "Deployed ${deployed} Mesa OpenGL files"
}

fix_webkit_exec_path(){
    local appdir="$1"
    local webkit_lib=""
    webkit_lib=$(find "${appdir}/shared/lib" -maxdepth 1 -name 'libwebkit2gtk-4.1.so.0.*' -type f 2>/dev/null | head -1)

    if [[ -z "${webkit_lib}" ]]; then
        echo "No libwebkit2gtk found, skipping exec path fix" >&2
        return 0
    fi

    # lib4bin replaces /usr with ././ in all binaries. This breaks execve() paths
    # because execve() resolves against CWD, not the binary's directory.
    # WebKit's PKGLIBEXECDIR becomes ././/lib/x86_64-linux-gnu/webkit2gtk-4.1.
    # Replace with /tmp/.trace-wk-helpers padded to same byte length.
    # AppRun creates a symlink: /tmp/.trace-wk-helpers -> bundled webkit dir.
    local patched="././/lib/x86_64-linux-gnu/webkit2gtk-4.1"
    local replacement="/tmp/.trace-wk-helpers"
    local pat_len=${#patched}
    local rep_len=${#replacement}
    local padding=""

    for ((i = rep_len; i < pat_len; i++)); do
        padding="${padding}/"
    done

    replacement="${replacement}${padding}"

    python3 -c "
import sys
old = sys.argv[1].encode()
new = sys.argv[2].encode()
data = open(sys.argv[3], 'rb').read()
count = data.count(old)
if count > 0:
    data = data.replace(old, new)
    open(sys.argv[3], 'wb').write(data)
    print(f'Patched {count} WebKit PKGLIBEXECDIR occurrence(s) in {sys.argv[3]}', file=sys.stderr)
else:
    print(f'WARNING: WebKit PKGLIBEXECDIR pattern not found in {sys.argv[3]}', file=sys.stderr)
" "${patched}" "${replacement}" "${webkit_lib}"
}

fix_jsc_stack_sanitize(){
    local appdir="$1"

    if ! find "${appdir}/shared/lib" -maxdepth 1 -name 'libjavascriptcoregtk-4.1.so.0.*' -type f 2>/dev/null | grep -q .; then
        echo "No libjavascriptcoregtk found, skipping JSC fix" >&2
        return 0
    fi

    # Boost.Context coroutines move the stack pointer outside JSC's expected
    # main-thread bounds, triggering SIGABRT in sanitizeStackForVM.
    # Override with a no-op via LD_PRELOAD.
    local fix_so="${appdir}/shared/lib/jsc-stack-fix.so"
    local fix_src
    fix_src=$(mktemp /tmp/jsc-fix.XXXXXX.c)

    cat > "${fix_src}" <<'CEOF'
void _ZN3JSC18sanitizeStackForVMERNS_2VME(void *vm) { (void)vm; }
CEOF

    if gcc -shared -fPIC -o "${fix_so}" "${fix_src}" 2>/dev/null; then
        echo "Built JSC sanitizeStackForVM override"
    else
        echo "WARNING: Failed to compile JSC fix .so" >&2
    fi

    rm -f "${fix_src}"
}

fix_webkit_helpers(){
    local appdir="$1"
    local wk_dir="${appdir}/shared/lib/webkit2gtk-4.1"

    if [[ ! -d "${wk_dir}" ]]; then
        return 0
    fi

    # sharun hardlinks must be in bin/ (one level below AppDir root) so sharun
    # can walk up to find the AppDir root and locate shared/bin/.
    # lib4bin places helpers deeper in shared/lib/webkit2gtk-4.1/ — too deep.
    local count=0

    for helper in WebKitWebProcess WebKitNetworkProcess WebKitGPUProcess; do
        local deep="${wk_dir}/${helper}"
        local real="${appdir}/shared/bin/${helper}"
        local bin_link="${appdir}/bin/${helper}"

        if [[ ! -f "${deep}" ]] || [[ ! -f "${real}" ]]; then
            continue
        fi

        ln -f "${appdir}/sharun" "${bin_link}"
        rm -f "${deep}"
        ln -s "../../../bin/${helper}" "${deep}"
        count=$((count + 1))
    done

    echo "Fixed ${count} WebKit helper hardlinks (moved to bin/, symlinked from webkit dir)"
}

restructure_appdir(){
    echo ""
    echo "--- Restructuring AppDir from FHS to sharun layout ---"
    local new_appdir="/tmp/SharunAppDir"
    rm -rf "${new_appdir}"

    # Collect all Trace ELF binaries for lib4bin
    local binaries=()

    for bin in trace trace-cli eeschema pcbnew gerbview bitmap2component pcb_calculator pl_editor; do
        if [[ -f "${APPDIR}/usr/bin/${bin}" ]]; then
            binaries+=("${APPDIR}/usr/bin/${bin}")
        fi
    done

    for kiface in "${APPDIR}"/usr/bin/*.kiface; do
        [[ -f "${kiface}" ]] && binaries+=("${kiface}")
    done

    # Add Python interpreter if present
    local py_ver=""
    for pybin in "${APPDIR}"/usr/bin/python3.*; do
        if [[ -f "${pybin}" && -x "${pybin}" && ! -L "${pybin}" ]]; then
            binaries+=("${pybin}")
            py_ver=$(basename "${pybin}" | sed 's/python//')
            break
        fi
    done

    echo "Running lib4bin on ${#binaries[@]} binaries"

    # lib4bin uses ldd which only searches standard system paths. Trace's own
    # libraries live under the AppDir, so add them to LD_LIBRARY_PATH.
    local appdir_lib_paths=""
    while IFS= read -r libdir; do
        appdir_lib_paths="${appdir_lib_paths:+${appdir_lib_paths}:}${libdir}"
    done < <(find "${APPDIR}/usr/lib" "${APPDIR}/usr/local/lib" "${APPDIR}/lib" \
        -type d 2>/dev/null | sort -u)

    if [[ -n "${appdir_lib_paths}" ]]; then
        export LD_LIBRARY_PATH="${appdir_lib_paths}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi

    sharun lib4bin \
        --hard-links \
        --with-sharun \
        --with-hooks \
        --gen-lib-path \
        --dst-dir "${new_appdir}" \
        "${binaries[@]}"

    # ── Copy Trace data files ────────────────────────────────────────
    mkdir -p "${new_appdir}/share"

    if [[ -d "${APPDIR}/usr/share/trace" ]]; then
        cp -a "${APPDIR}/usr/share/trace" "${new_appdir}/share/trace"
    fi

    # ── ONNX Runtime ─────────────────────────────────────────────────
    local ort_lib_dir="${BUILD_DIR}/trace-src/thirdparty/onnxruntime/lib"
    if [ ! -d "${ort_lib_dir}" ]; then
        ort_lib_dir="${TRACE_SRC}/thirdparty/onnxruntime/lib"
    fi
    if [ -d "${ort_lib_dir}" ]; then
        echo "Bundling ONNX Runtime libraries"
        cp -a "${ort_lib_dir}"/libonnxruntime.so* "${new_appdir}/shared/lib/" 2>/dev/null || true
    fi

    # ── ONNX models and tokenizer ────────────────────────────────────
    local model_dir="${BUILD_DIR}/trace-src/trace/common/models"
    if [ ! -d "${model_dir}" ]; then
        model_dir="${TRACE_SRC}/trace/common/models"
    fi
    if [ -d "${model_dir}" ]; then
        echo "Bundling ONNX model files"
        mkdir -p "${new_appdir}/share/trace/models"
        cp -a "${model_dir}"/* "${new_appdir}/share/trace/models/" 2>/dev/null || true
    fi

    local tokenizer_dir="${BUILD_DIR}/trace-src/trace/common/tokenizer"
    if [ ! -d "${tokenizer_dir}" ]; then
        tokenizer_dir="${TRACE_SRC}/trace/common/tokenizer"
    fi
    if [ -d "${tokenizer_dir}" ]; then
        echo "Bundling tokenizer files"
        mkdir -p "${new_appdir}/share/trace/tokenizer"
        cp -a "${tokenizer_dir}"/* "${new_appdir}/share/trace/tokenizer/" 2>/dev/null || true
    fi

    # ── Desktop entry + icon at AppDir root ──────────────────────────
    if [[ -d "${APPDIR}/usr/share/applications" ]]; then
        cp -a "${APPDIR}/usr/share/applications" "${new_appdir}/share/applications"
    fi
    if [[ -d "${APPDIR}/usr/share/icons" ]]; then
        cp -a "${APPDIR}/usr/share/icons" "${new_appdir}/share/icons"
    fi

    local desktop="${new_appdir}/share/applications/trace.desktop"
    if [[ ! -f "${desktop}" ]]; then
        desktop="${APPDIR}/trace.desktop"
    fi
    if [[ -f "${desktop}" ]]; then
        cp "${desktop}" "${new_appdir}/trace.desktop"
    fi

    local icon=""
    icon=$(find "${new_appdir}/share/icons" -name "trace.svg" -type f 2>/dev/null | head -1)
    if [[ -z "${icon}" ]] && [[ -f "${APPDIR}/trace.svg" ]]; then
        icon="${APPDIR}/trace.svg"
    fi
    if [[ -n "${icon}" ]]; then
        cp "${icon}" "${new_appdir}/trace.svg"
        ln -sf trace.svg "${new_appdir}/.DirIcon"
    fi

    # ── Compatibility symlinks for code that hard-codes APPDIR/usr/ paths ──
    mkdir -p "${new_appdir}/usr"
    ln -sf ../shared/bin "${new_appdir}/usr/bin"
    ln -sf ../share "${new_appdir}/usr/share"
    ln -sf ../shared/lib "${new_appdir}/usr/lib"

    # 3D plugin compatibility path
    local plugin_dir multiarch
    plugin_dir=$(find "${APPDIR}/usr/lib" -type d -path '*/kicad/plugins' 2>/dev/null | head -n1 || true)

    if [[ -n "${plugin_dir}" ]]; then
        multiarch="${plugin_dir#${APPDIR}/usr/lib/}"
        multiarch="${multiarch%%/*}"
        mkdir -p "${new_appdir}/shared/lib/kicad"
        cp -a "${plugin_dir}" "${new_appdir}/shared/lib/kicad/plugins"
        mkdir -p "${new_appdir}/usr/lib/${multiarch}/kicad"
        ln -sf ../../../../shared/lib/kicad/plugins "${new_appdir}/usr/lib/${multiarch}/kicad/plugins"
    fi

    # ── GLib schemas ─────────────────────────────────────────────────
    if [[ -d "${APPDIR}/usr/share/glib-2.0/schemas" ]]; then
        mkdir -p "${new_appdir}/share/glib-2.0"
        cp -a "${APPDIR}/usr/share/glib-2.0/schemas" "${new_appdir}/share/glib-2.0/schemas"
        glib-compile-schemas "${new_appdir}/share/glib-2.0/schemas" 2>/dev/null || true
    fi

    # ── Bundle Python packages ───────────────────────────────────────
    # Python is placed under shared/python/ (NOT shared/lib/) to prevent
    # sharun from auto-detecting it and setting PYTHONHOME incorrectly.
    # sharun globs shared/$LIB/python* which matches shared/lib/python3.11
    # and sets PYTHONHOME to that directory -- but PYTHONHOME must be a
    # *prefix*, not the python lib dir.  By using shared/python/ we avoid
    # the glob entirely and control PYTHONHOME from AppRun.
    local pyroot="${new_appdir}/shared/python"
    if [[ -n "${py_ver}" ]]; then
        local pylib="${pyroot}/lib/python${py_ver}"
        mkdir -p "${pylib}"

        for pydir in \
            "${APPDIR}/usr/lib/python3/dist-packages" \
            "${APPDIR}/usr/lib/python${py_ver}/dist-packages" \
            "${APPDIR}/usr/lib/python${py_ver}/site-packages" \
            "${APPDIR}/usr/local/lib/python${py_ver}/dist-packages"; do

            if [[ -d "${pydir}" ]]; then
                local dest="${pylib}/$(basename "${pydir}")"
                mkdir -p "${dest}"
                cp -a "${pydir}/." "${dest}/"
            fi
        done

        for stdlib in "${APPDIR}/usr/lib/python${py_ver}"; do
            if [[ -d "${stdlib}" ]]; then
                find "${stdlib}" -maxdepth 1 -mindepth 1 \
                    ! -name "dist-packages" ! -name "site-packages" \
                    -exec cp -a {} "${pylib}/" \;
            fi
        done

        # Also relocate /usr/lib/python3/dist-packages
        if [[ -d "${APPDIR}/usr/lib/python3/dist-packages" ]]; then
            mkdir -p "${pyroot}/lib/python3/dist-packages"
            cp -a "${APPDIR}/usr/lib/python3/dist-packages/." "${pyroot}/lib/python3/dist-packages/"
        fi

        # Create python3 symlinks in bin/ and shared/bin/ so that
        # FindPythonInterpreter() finds the bundled Python instead of the host's.
        ln -sf "python${py_ver}" "${new_appdir}/bin/python3"
        ln -sf "python${py_ver}" "${new_appdir}/shared/bin/python3"
    fi

    # ── Bundle gdk-pixbuf loaders ────────────────────────────────────
    bundle_pixbuf_loaders "${new_appdir}"

    # ── Bundle Mesa OpenGL stack ─────────────────────────────────────
    deploy_opengl "${new_appdir}"

    # ── Generate AppRun ──────────────────────────────────────────────
    cp "${SCRIPT_DIR}/AppRun" "${new_appdir}/AppRun"
    chmod +x "${new_appdir}/AppRun"

    # ── Replace old AppDir ───────────────────────────────────────────
    rm -rf "${APPDIR}"
    mv "${new_appdir}" "${APPDIR}"

    echo "Restructured AppDir: $(du -sm "${APPDIR}" | cut -f1)MB"
    echo "Binaries: $(ls "${APPDIR}/bin/" | wc -l), Libraries: $(find "${APPDIR}/shared/lib" -name '*.so*' | wc -l)"
}

generate_env_file(){
    local env_file="${APPDIR}/.env"

    echo "Generating .env for Trace"

    # Detect Trace major version for versioned env var names (TRACE1_*, TRACE2_*, etc.)
    local trace_major=""
    local ver_cmake="${BUILD_DIR}/trace-src/cmake/TraceVersion.cmake"
    if [[ ! -f "${ver_cmake}" ]]; then
        ver_cmake="${TRACE_SRC}/cmake/TraceVersion.cmake"
    fi
    if [[ -f "${ver_cmake}" ]]; then
        trace_major=$(grep -oP 'TRACE_SEMANTIC_VERSION\s+"?\K[0-9]+' "${ver_cmake}" | head -1)
    fi
    trace_major="${trace_major:-1}"

    cat > "${env_file}" <<ENVEOF
APPDIR=\${SHARUN_DIR}
KICAD_STOCK_DATA_HOME=\${SHARUN_DIR}/share/trace
TRACE${trace_major}_SYMBOL_DIR=\${SHARUN_DIR}/share/trace/symbols
TRACE${trace_major}_FOOTPRINT_DIR=\${SHARUN_DIR}/share/trace/footprints
TRACE${trace_major}_3DMODEL_DIR=\${SHARUN_DIR}/share/trace/3dmodels
TRACE${trace_major}_TEMPLATE_DIR=\${SHARUN_DIR}/share/trace/template
TRACE${trace_major}_DESIGN_BLOCK_DIR=\${SHARUN_DIR}/share/trace/blocks
XDG_DATA_DIRS=\${SHARUN_DIR}/share:\${XDG_DATA_DIRS}
GSETTINGS_SCHEMA_DIR=\${SHARUN_DIR}/share/glib-2.0/schemas
GDK_BACKEND=x11
NO_AT_BRIDGE=1
GTK_A11Y=none
GTK_MODULES=
GTK3_MODULES=
WEBKIT_DISABLE_COMPOSITING_MODE=1
WEBKIT_DISABLE_DMABUF_RENDERER=1
GIO_MODULE_DIR=\${SHARUN_DIR}/shared/lib/gio/modules
GIO_USE_VFS=local
ENVEOF

    if [[ -f "${APPDIR}/shared/lib/jsc-stack-fix.so" ]]; then
        echo 'SHARUN_ALLOW_LD_PRELOAD=1' >> "${env_file}"
        echo 'LD_PRELOAD=${SHARUN_DIR}/shared/lib/jsc-stack-fix.so' >> "${env_file}"
    fi

    # gdk-pixbuf cache path
    local pixbuf_cache
    pixbuf_cache=$(find "${APPDIR}/shared/lib" -name "loaders.cache" -path "*/gdk-pixbuf-2.0/*" 2>/dev/null | head -1)
    if [[ -n "${pixbuf_cache}" ]]; then
        local rel_cache="${pixbuf_cache#"${APPDIR}/"}"
        echo "GDK_PIXBUF_MODULE_FILE=\${SHARUN_DIR}/${rel_cache}" >> "${env_file}"
    fi

    # Mesa DRI drivers
    if [[ -d "${APPDIR}/shared/lib/dri" ]]; then
        echo 'LIBGL_DRIVERS_PATH=${SHARUN_DIR}/shared/lib/dri' >> "${env_file}"
    fi

    # EGL vendor ICDs
    if [[ -d "${APPDIR}/share/glvnd/egl_vendor.d" ]]; then
        echo '__EGL_VENDOR_LIBRARY_DIRS=${SHARUN_DIR}/share/glvnd/egl_vendor.d' >> "${env_file}"
    fi

    # Python environment -- set in .env as well as AppRun.
    # Python stdlib is at shared/python/lib/python3.X/ (NOT shared/lib/) to
    # prevent sharun's auto-detection from overriding PYTHONHOME.
    local py_ver
    py_ver=$(ls -d "${APPDIR}"/shared/python/lib/python3.* 2>/dev/null | head -1 | grep -o '3\.[0-9]*' || true)

    if [[ -n "${py_ver}" ]]; then
        local pylib="\${SHARUN_DIR}/shared/python/lib/python${py_ver}"
        cat >> "${env_file}" <<PYEOF
PYTHONHOME=\${SHARUN_DIR}/shared/python
PYTHONPATH=${pylib}:${pylib}/lib-dynload:${pylib}/dist-packages:${pylib}/site-packages:\${SHARUN_DIR}/shared/python/lib/python3/dist-packages
PYTHONDONTWRITEBYTECODE=1
PYTHONNOUSERSITE=1
PYEOF
    fi

    # Create GIO modules dir (may be empty -- that's intentional to prevent
    # loading host modules that link against a different glibc)
    mkdir -p "${APPDIR}/shared/lib/gio/modules"

    echo "Generated .env ($(wc -l < "${env_file}") entries)"
}

strip_binaries(){
    local before after
    before=$(du -sm "${APPDIR}" | cut -f1)
    echo "Stripping ELF binaries (${before}MB before)"

    local count=0
    while IFS= read -r f; do
        strip --strip-unneeded "$f" 2>/dev/null && count=$((count + 1))
    done < <(find "${APPDIR}" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.kiface' -o -executable \) -print0 \
        | xargs -0 file \
        | awk -F: '/ELF.*not stripped/{print $1}')

    after=$(du -sm "${APPDIR}" | cut -f1)
    echo "Stripped ${count} ELF files (${before}MB -> ${after}MB)"
}

build_image(){
    local appimage="${OUTPUT_DIR}/Trace-${TRACE_VERSION}-${ARCH}.AppImage"
    mkdir -p "${OUTPUT_DIR}"

    echo ""
    echo "--- Creating DwarFS AppImage with uruntime ---"

    mkdwarfs \
        --force \
        --set-owner 0 \
        --set-group 0 \
        --no-history \
        --no-create-timestamp \
        --header "$(command -v uruntime)" \
        --input "${APPDIR}" \
        -C zstd:level=22 \
        -S26 -B6 \
        --output "${appimage}"

    chmod +x "${appimage}"

    local size
    size=$(du -h "${appimage}" | cut -f1)
    echo ""
    echo "============================================"
    echo "  AppImage created: $(basename "${appimage}") (${size})"
    echo "  ${appimage}"
    echo "============================================"
}

# =====================================================================
# MAIN
# =====================================================================

main(){
    # ── Prepare initial FHS AppDir from install tree ─────────────────
    echo ""
    echo "--- Preparing AppDir at ${APPDIR} ---"
    rm -rf "${APPDIR}"
    mkdir -p "${APPDIR}"
    cp -a "${INSTALL_DIR}/usr" "${APPDIR}/usr"

    # Desktop file + icon into AppDir before restructuring
    cp "${SCRIPT_DIR}/trace.desktop" "${APPDIR}/trace.desktop"

    local icon_src=""
    if [ -f "${INSTALL_DIR}/usr/share/icons/hicolor/scalable/apps/trace.svg" ]; then
        icon_src="${INSTALL_DIR}/usr/share/icons/hicolor/scalable/apps/trace.svg"
    elif [ -f "${TRACE_SRC}/resources/linux/icons/hicolor/scalable/apps/trace.svg" ]; then
        icon_src="${TRACE_SRC}/resources/linux/icons/hicolor/scalable/apps/trace.svg"
    fi
    if [ -n "${icon_src}" ]; then
        cp "${icon_src}" "${APPDIR}/trace.svg"
        mkdir -p "${APPDIR}/usr/share/icons/hicolor/scalable/apps"
        cp "${icon_src}" "${APPDIR}/usr/share/icons/hicolor/scalable/apps/trace.svg"
    fi

    # Bundle Python interpreter + standard library into the FHS AppDir
    local python_version
    python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.11")
    local python_stdlib="/usr/lib/python${python_version}"

    # Copy the Python interpreter binary so restructure_appdir detects it
    local system_python
    system_python=$(readlink -f "$(command -v python3)")
    if [ -x "${system_python}" ]; then
        echo "Bundling Python ${python_version} interpreter: ${system_python}"
        cp "${system_python}" "${APPDIR}/usr/bin/python${python_version}"
        chmod +x "${APPDIR}/usr/bin/python${python_version}"
        ln -sf "python${python_version}" "${APPDIR}/usr/bin/python3"
    fi

    if [ -d "${python_stdlib}" ]; then
        echo "Bundling Python ${python_version} standard library"
        mkdir -p "${APPDIR}/usr/lib/python${python_version}"
        rsync -a \
            --exclude='__pycache__' \
            --exclude='test/' \
            --exclude='tests/' \
            --exclude='idle_test/' \
            --exclude='tkinter/' \
            --exclude='turtledemo/' \
            --exclude='ensurepip/' \
            "${python_stdlib}/" "${APPDIR}/usr/lib/python${python_version}/"

        if [ -d "${python_stdlib}/lib-dynload" ]; then
            cp -a "${python_stdlib}/lib-dynload" "${APPDIR}/usr/lib/python${python_version}/"
        fi
    fi

    # Debian dist-packages (system packages installed via apt)
    local python_dynload="/usr/lib/python3/dist-packages"
    if [ -d "${python_dynload}" ]; then
        echo "Bundling /usr/lib/python3/dist-packages"
        mkdir -p "${APPDIR}/usr/lib/python3/dist-packages"
        rsync -a --exclude='__pycache__' \
            "${python_dynload}/" "${APPDIR}/usr/lib/python3/dist-packages/"
    fi

    # pip-installed packages (e.g. wxPython) live under /usr/local/lib/
    local pip_site="/usr/local/lib/python${python_version}/dist-packages"
    if [ -d "${pip_site}" ]; then
        echo "Bundling ${pip_site} (pip packages including wxPython)"
        mkdir -p "${APPDIR}${pip_site}"
        rsync -a --exclude='__pycache__' \
            "${pip_site}/" "${APPDIR}${pip_site}/"
    fi

    # Also check sysconfig platlib as a fallback
    local site_packages
    site_packages=$(python3 -c "import sysconfig; print(sysconfig.get_path('platlib'))" 2>/dev/null || echo "")
    if [ -n "${site_packages}" ] && [ -d "${site_packages}" ] && [ "${site_packages}" != "${pip_site}" ]; then
        echo "Bundling ${site_packages}"
        mkdir -p "${APPDIR}${site_packages}"
        rsync -a --exclude='__pycache__' \
            "${site_packages}/" "${APPDIR}${site_packages}/"
    fi

    # ── sharun pipeline ──────────────────────────────────────────────
    fetch_sharun_tools
    restructure_appdir
    fix_webkit_exec_path "${APPDIR}"
    fix_webkit_helpers "${APPDIR}"
    fix_jsc_stack_sanitize "${APPDIR}"
    generate_env_file
    strip_binaries
    build_image
}

main "$@"
