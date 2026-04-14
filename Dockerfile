FROM debian:bookworm

ARG DEBIAN_FRONTEND=noninteractive

# Version pins (aligned with KiCad's CI pipeline)
ARG WX_VERSION=3.2.8.1
ARG WXPYTHON_VERSION=4.2.3

# ── System build dependencies ────────────────────────────────────────
# Aligned with KiCad's kicad-appimage Dockerfile.base (Debian Bookworm).
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake bison build-essential \
    ca-certificates cmake curl \
    desktop-file-utils dpkg-dev \
    file flex \
    gcc-12 g++-12 gettext git \
    libboost-all-dev \
    libbz2-dev \
    libcairo2-dev \
    libcurl4-gnutls-dev \
    libfreeimage-dev \
    libfreetype-dev \
    libfontconfig-dev \
    libgcrypt20-dev \
    libgit2-dev \
    libgl1-mesa-dev \
    libglew-dev \
    libglm-dev \
    libglu1-mesa-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgtk-3-dev \
    libharfbuzz-dev \
    libjpeg-dev \
    liblzma-dev \
    libnng-dev \
    libngspice0-dev \
    libnotify-dev \
    libocct-modeling-algorithms-dev libocct-modeling-data-dev \
    libocct-data-exchange-dev libocct-visualization-dev \
    libocct-foundation-dev libocct-ocaf-dev \
    libpixman-1-dev \
    libpng-dev \
    libpoppler-dev libpoppler-glib-dev \
    libprotobuf-dev \
    libsecret-1-dev \
    libsm-dev \
    libsodium-dev \
    libspnav-dev \
    libsqlite3-dev \
    libtbb-dev \
    libtiff-dev \
    libwebkit2gtk-4.1-dev \
    libx11-dev libxext-dev libxi-dev libxmu-dev \
    libxtst-dev \
    libzint-dev \
    libzstd-dev \
    lld \
    mesa-common-dev \
    ninja-build \
    patchelf pkg-config \
    protobuf-compiler \
    python-is-python3 python3-dev python3-pip python3-setuptools python3-venv python3-wheel \
    rapidjson-dev rsync \
    shared-mime-info squashfs-tools strace \
    swig \
    tcl-dev tk-dev \
    unixodbc-dev \
    wget \
    zlib1g-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Node.js 20 LTS (needed to build the React chat UI) ──────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Use GCC 12 as default ────────────────────────────────────────────
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 120 \
        --slave /usr/bin/g++ g++ /usr/bin/g++-12 && \
    update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-12 120 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-12 120

# ── Python packaging tools ────────────────────────────────────────────
RUN python3 -m pip install --break-system-packages --upgrade pip setuptools wheel build packaging

# ── Build wxWidgets from source ───────────────────────────────────────
# Bookworm ships wxWidgets 3.2.2, but wxPython 4.2.3 needs >= 3.2.8.
# KiCad's pipeline builds wxWidgets from source for version consistency.
RUN cd /tmp && \
    wget -q "https://github.com/wxWidgets/wxWidgets/releases/download/v${WX_VERSION}/wxWidgets-${WX_VERSION}.tar.bz2" -O wxWidgets.tar.bz2 && \
    mkdir wxWidgets && tar xjf wxWidgets.tar.bz2 -C wxWidgets --strip-components=1 && \
    cd wxWidgets && \
    cmake -G Ninja -B builddir -DCMAKE_INSTALL_PREFIX=/usr \
        -DwxBUILD_SHARED=ON \
        -DwxBUILD_TOOLKIT=gtk3 \
        -DwxUSE_OPENGL=ON \
        -DwxUSE_GLCANVAS_EGL=OFF \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
    ninja -C builddir -j$(nproc) && \
    cmake --install builddir && \
    wx_config=$(find /usr -path '*/wx/config/gtk3-unicode-*' -type f | head -1) && \
    rm -f /usr/bin/wx-config && \
    cp "$wx_config" /usr/bin/wx-config && \
    ldconfig && \
    cd /tmp && rm -rf wxWidgets wxWidgets.tar.bz2

# ── Build wxPython from source ────────────────────────────────────────
# Must be built against the same wxWidgets we just installed.
RUN cd /tmp && \
    wget -q "https://github.com/wxWidgets/Phoenix/releases/download/wxPython-${WXPYTHON_VERSION}/wxPython-${WXPYTHON_VERSION}.tar.gz" -O wxPython.tar.gz && \
    mkdir wxPython && tar xzf wxPython.tar.gz -C wxPython --strip-components=1 && \
    cd wxPython && \
    python3 -m pip install --break-system-packages "setuptools<75" cython requests && \
    mkdir -p /usr/docs && \
    touch /usr/docs/preamble.txt /usr/docs/licence.txt /usr/docs/license.txt /usr/docs/lgpl.txt /usr/docs/gpl.txt && \
    export WXWIN=/usr && \
    python3 build.py --use_syswx --nodoc build_py --jobs=$(nproc) && \
    python3 build.py install_py --destdir=/ && \
    cd /tmp && rm -rf wxPython wxPython.tar.gz

# ── Working directories ───────────────────────────────────────────────
RUN mkdir -p /src /build /output

WORKDIR /build

ENTRYPOINT ["/bin/bash"]
