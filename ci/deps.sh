#!/bin/bash
# System dependencies for building Trace on Debian Bookworm.
# Sourced by Dockerfile and build.sh.
#
# Aligned with KiCad's kicad-appimage Dockerfile.base (Debian Bookworm).

export BUILD_DEPS=(
    # Core build tools
    autoconf
    automake
    bison
    build-essential
    cmake
    dpkg-dev
    flex
    gcc-12
    g++-12
    gettext
    git
    lld
    ninja-build
    pkg-config

    # Python
    python-is-python3
    python3-dev
    python3-pip
    python3-setuptools
    python3-venv
    python3-wheel
    swig

    # wxWidgets / GTK / WebKit (Bookworm ships these natively)
    libwxgtk3.2-dev
    libwxgtk-webview3.2-dev
    libgtk-3-dev
    libwebkit2gtk-4.1-dev

    # Boost
    libboost-all-dev

    # OpenGL / Graphics
    libglew-dev
    libglm-dev
    libglu1-mesa-dev
    libgl1-mesa-dev
    mesa-common-dev

    # Cairo / Pixman
    libcairo2-dev
    libpixman-1-dev

    # Networking / TLS
    libcurl4-gnutls-dev

    # Simulation
    libngspice0-dev

    # OpenCASCADE (STEP/3D model support)
    libocct-modeling-algorithms-dev
    libocct-modeling-data-dev
    libocct-data-exchange-dev
    libocct-visualization-dev
    libocct-foundation-dev
    libocct-ocaf-dev

    # Git integration
    libgit2-dev
    libsecret-1-dev

    # Database / compression
    libsqlite3-dev
    libzstd-dev
    zlib1g-dev
    libbz2-dev

    # Protobuf / IPC
    libprotobuf-dev
    protobuf-compiler
    libnng-dev

    # Fonts
    libfreetype-dev
    libharfbuzz-dev
    libfontconfig-dev

    # GStreamer (multimedia)
    libgstreamer1.0-dev
    libgstreamer-plugins-base1.0-dev

    # Crypto
    libgcrypt20-dev
    libsodium-dev

    # Input devices
    libspnav-dev

    # ODBC
    unixodbc-dev

    # Image processing
    libfreeimage-dev
    libpoppler-dev
    libpoppler-glib-dev

    # Threading
    libtbb-dev

    # Barcode
    libzint-dev

    # X11
    libx11-dev
    libxext-dev
    libxi-dev
    libxmu-dev

    # Misc build
    rapidjson-dev
    shared-mime-info
    tcl-dev
    tk-dev

    # AppImage / packaging tools
    ca-certificates
    curl
    desktop-file-utils
    file
    patchelf
    rsync
    squashfs-tools
    strace
    wget
)
