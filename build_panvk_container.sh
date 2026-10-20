#!/bin/bash
# Build the full Mesa userspace for panfrost.ko (no kbase) in an emulated arm64
# Fedora 44 container: Gallium panfrost GL/GLES + PanVK, with EGL/GLX (glvnd
# vendor libs), GBM and the DRI loader laid out like Fedora's mesa packages,
# so the sysext replaces the distro Mesa stack wholesale.
#
# Host:      ./build_panvk_container.sh          (starts the container if needed)
# Output:    _build/install/usr                  (prefix /usr, ready for a sysext)
set -euo pipefail

IMAGE=${PANVK_BUILD_IMAGE:-localhost/panvk-build:f44}
NAME=panvk-build

if [ ! -f /run/.containerenv ]; then
   repo=$(cd "$(dirname "$0")" && pwd)
   if ! podman container exists "$NAME"; then
      if ! podman image exists "$IMAGE"; then
         podman run -d --name "$NAME" --arch arm64 -v "$repo":/src:z \
            registry.fedoraproject.org/fedora:44 sleep infinity
         podman exec "$NAME" bash -c \
            'dnf -y install dnf-plugins-core && dnf -y builddep mesa && dnf -y install ccache erofs-utils'
      else
         podman run -d --name "$NAME" --arch arm64 -v "$repo":/src:z "$IMAGE" sleep infinity
      fi
   fi
   podman start "$NAME" >/dev/null
   exec podman exec -e PANVK_JOBS="${PANVK_JOBS:-}" "$NAME" /src/build_panvk_container.sh "$@"
fi

SRC=/src
BUILD=/src/_build/mesa

# Two ninja runs in one build dir corrupt each other (e.g. a host-side
# `podman exec` that was killed leaves its build running in the container).
mkdir -p /src/_build
exec 9>/src/_build/.build.lock
if ! flock -n 9; then
   echo "another build is already running in $BUILD" >&2
   exit 1
fi
export CCACHE_DIR=/src/_build/ccache
export CC="ccache gcc" CXX="ccache g++"

if [ ! -f "$BUILD/build.ninja" ]; then
   # llvmpipe/softpipe and zink keep Fedora's swrast, kms_swrast and zink
   # entry points working, since they all go through our libdril/libgallium.
   meson setup "$BUILD" "$SRC" \
      --prefix=/usr \
      --libdir=lib64 \
      --sysconfdir=/etc \
      -Dbuildtype=debugoptimized \
      -Dplatforms=x11,wayland \
      -Dgallium-drivers=panfrost,llvmpipe,softpipe,zink \
      -Dvulkan-drivers=panfrost \
      -Dpanfrost-kmds=panfrost,panthor \
      -Dllvm=enabled -Dshared-llvm=enabled \
      -Dglvnd=enabled -Dglx=dri -Degl=enabled -Dgbm=enabled \
      -Dopengl=true -Dgles1=disabled -Dgles2=enabled \
      -Dgallium-va=disabled \
      -Dvideo-codecs= \
      -Dvulkan-layers= -Dtools= \
      -Dbuild-tests=false
fi

# Emulated C++ compiles (llvmpipe, zink) are memory-hungry: ninja's default
# of nproc+2 jobs ran a 23 GiB host out of RAM.
ninja -C "$BUILD" -j "${PANVK_JOBS:-6}"
rm -rf /src/_build/install
DESTDIR=/src/_build/install ninja -C "$BUILD" install >/dev/null
echo "Installed to _build/install/usr"
