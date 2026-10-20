#!/bin/bash
# Deploy a build from build_panvk_container.sh to the device.
#
#   ./deploy_panvk.sh [--install] [user@host]
#
# 1. Copies _build/install/usr to ~/panvk/usr on the device, plus an ICD
#    (~/panvk/panfrost_icd.json) with an absolute library_path, for root-less
#    Vulkan testing:  VK_DRIVER_FILES=~/panvk/panfrost_icd.json vulkaninfo --summary
# 2. Builds _build/panvk.raw (stripped erofs systemd-sysext carrying the whole
#    Mesa stack: GL/GLES/EGL/GLX/GBM + PanVK) and copies it to ~/panvk.raw.
# 3. With --install, installs it over root@<host> (key auth) and refreshes
#    systemd-sysext. Otherwise, as root on the device:
#      install -m644 ~/panvk.raw /var/lib/extensions/panvk.raw && systemd-sysext refresh
#
# The sysext replaces the distro Mesa, including the EGL/GBM the compositor
# uses. Roll back with:  rm /var/lib/extensions/panvk.raw && systemd-sysext refresh
set -euo pipefail

install=0
if [ "${1:-}" = "--install" ]; then
   install=1
   shift
fi
HOST=${1:-ultramarine@192.168.1.19}
repo=$(cd "$(dirname "$0")" && pwd)
inst="$repo/_build/install"
[ -d "$inst/usr" ] || { echo "no build at $inst, run build_panvk_container.sh" >&2; exit 1; }

# --- root-less test install -------------------------------------------------
home=$(ssh "$HOST" 'echo $HOME')
ssh "$HOST" 'mkdir -p ~/panvk'
rsync -a --delete "$inst/usr/" "$HOST:panvk/usr/"
icd=$(ls "$inst"/usr/share/vulkan/icd.d/panfrost_icd.*.json)
sed "s|\"library_path\": *\"[^\"]*\"|\"library_path\": \"$home/panvk/usr/lib64/libvulkan_panfrost.so\"|" \
   "$icd" | ssh "$HOST" 'cat > ~/panvk/panfrost_icd.json'

# --- sysext image ------------------------------------------------------------
stage="$repo/_build/sysext"
rm -rf "$stage" "$repo/_build/panvk.raw"
mkdir -p "$stage/usr/lib/extension-release.d"
cp -a "$inst/usr/." "$stage/usr/"
# Headers/pkgconfig are not needed on the device.
rm -rf "$stage/usr/include" "$stage/usr/lib64/pkgconfig"
# Debug info would make the full stack several hundred MiB; keep it only in
# the unstripped ~/panvk copy.
podman exec panvk-build find /src/_build/sysext/usr/lib64 -name '*.so*' -type f \
   -exec strip --strip-debug {} +
eval "$(ssh "$HOST" 'grep -E "^(ID|VERSION_ID)=" /etc/os-release')"
printf 'ID=%s\nVERSION_ID=%s\n' "$ID" "$VERSION_ID" \
   > "$stage/usr/lib/extension-release.d/extension-release.panvk"
# The device's 5.15 erofs can't read symlinks whose inline data crosses a
# block boundary ("erofs_fill_symlink: inline data cross block boundary"),
# which mkfs.erofs 1.9 produces; keep file data out of the inode.
podman exec panvk-build mkfs.erofs -Enoinline_data /src/_build/panvk.raw /src/_build/sysext >/dev/null
scp -q "$repo/_build/panvk.raw" "$HOST:panvk.raw"

if [ "$install" = 1 ]; then
   host_only=${HOST#*@}
   ssh -o BatchMode=yes "root@$host_only" \
      "install -m644 $home/panvk.raw /var/lib/extensions/panvk.raw && systemd-sysext refresh"
fi

echo "Deployed to $HOST ($(du -h "$repo/_build/panvk.raw" | cut -f1) sysext):"
echo "  test:     VK_DRIVER_FILES=$home/panvk/panfrost_icd.json vulkaninfo --summary"
if [ "$install" = 1 ]; then
   echo "  sysext:   installed and merged"
else
   echo "  sysext:   sudo install -m644 ~/panvk.raw /var/lib/extensions/panvk.raw && sudo systemd-sysext refresh"
fi
echo "  rollback: rm /var/lib/extensions/panvk.raw && systemd-sysext refresh"
