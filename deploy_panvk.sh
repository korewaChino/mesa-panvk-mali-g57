#!/bin/bash
# Deploy a build from build_panvk_container.sh to the device.
#
#   ./deploy_panvk.sh [user@host]
#
# 1. Copies _build/install/usr to ~/panvk/usr on the device, plus an ICD
#    (~/panvk/panfrost_icd.json) with an absolute library_path, for root-less
#    testing:  VK_DRIVER_FILES=~/panvk/panfrost_icd.json vulkaninfo --summary
# 2. Builds _build/panvk.raw (erofs systemd-sysext) and copies it to ~/panvk.raw.
#    Activate as root on the device:
#      install -m644 ~/panvk.raw /var/lib/extensions/panvk.raw && systemd-sysext refresh
set -euo pipefail

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
eval "$(ssh "$HOST" 'grep -E "^(ID|VERSION_ID)=" /etc/os-release')"
printf 'ID=%s\nVERSION_ID=%s\n' "$ID" "$VERSION_ID" \
   > "$stage/usr/lib/extension-release.d/extension-release.panvk"
podman exec panvk-build mkfs.erofs /src/_build/panvk.raw /src/_build/sysext >/dev/null
scp -q "$repo/_build/panvk.raw" "$HOST:panvk.raw"

echo "Deployed to $HOST:"
echo "  test:     VK_DRIVER_FILES=$home/panvk/panfrost_icd.json vulkaninfo --summary"
echo "  sysext:   sudo install -m644 ~/panvk.raw /var/lib/extensions/panvk.raw && sudo systemd-sysext refresh"
