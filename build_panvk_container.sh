#!/bin/bash
# Build PanVK for panfrost.ko (no kbase) in an emulated arm64 Fedora 44 container.
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
   exec podman exec "$NAME" /src/build_panvk_container.sh "$@"
fi

SRC=/src
BUILD=/src/_build/g57

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
   meson setup "$BUILD" "$SRC" \
      --prefix=/usr \
      --libdir=lib64 \
      -Dbuildtype=debugoptimized \
      -Dplatforms=x11,wayland \
      -Dvulkan-drivers=panfrost \
      -Dgallium-drivers= \
      -Dpanfrost-kmds=panfrost,panthor \
      -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
      -Dopengl=false -Dgbm=disabled \
      -Dvideo-codecs= \
      -Dvulkan-layers= -Dtools= \
      -Dbuild-tests=false
fi

ninja -C "$BUILD"
rm -rf /src/_build/install
DESTDIR=/src/_build/install ninja -C "$BUILD" install >/dev/null
echo "Installed to _build/install/usr"
