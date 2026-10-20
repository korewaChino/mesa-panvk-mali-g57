# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this tree is

A Mesa snapshot (26.3-devel) carrying experimental PanVK (Vulkan) support for **Valhall v9 JM**
GPUs (Mali-G57). It is imported from `apexspan-svg/mesa-panvk-mali-g57` (release v1.3.0), which
targeted Arm's `kbase` driver on Android/Termux. There is no upstream git ancestry. The snapshot
corresponds most closely to upstream Mesa `84f090168c` (2026-07-27). Diff against that commit to
isolate fork changes. An upstream Mesa checkout lives in `mesa-upstream/` inside this repo (git-ignored via `.git/info/exclude`; blobless clone of main since
2026-05, with this repo added as remote `g57`).

**Current goal (branch `g57-panfrost-kmd`):** run PanVK on the **mainline `panfrost.ko` DRM
driver**, not kbase. Target device: TrimUI Smart Pro S (Allwinner A523, Mali-G57 **MC1**).
It runs Ultramarine Linux 44 (Fedora-based, immutable `/usr`) on a vendor 5.15 kernel with a
backported panfrost.

Upstream Mesa only builds PanVK JM for v6/v7 and CSF for v10+. The fork adds v9 to `jm_archs`
in `src/panfrost/vulkan/meson.build` and accepts arch 9 in `panvk_physical_device.c`.

## Build

The device has ~1 GB RAM, so build in an emulated arm64 Fedora 44 container on the host. That
container matches the device's libraries.

```sh
./build_panvk_container.sh   # -> _build/install/usr
```

The script creates or starts the `panvk-build` podman container, with the repo mounted at
`/src`. It uses the `localhost/panvk-build:f44` image with deps preinstalled if that exists,
and otherwise runs `dnf builddep mesa`. Inside the container it builds the **full Mesa
userspace** into `_build/mesa` with `--prefix=/usr`: Gallium `panfrost,llvmpipe,softpipe,zink`
(GL, GLES2+, glvnd EGL/GLX vendor libs, GBM, DRI loader) plus PanVK, with
`-Dpanfrost-kmds=panfrost,panthor` (panthor is needed to link the v10+ CSF arches). llvmpipe and
zink are there so Fedora's `swrast`/`kms_swrast`/`zink` symlinks into our `libdril_dri.so` keep
working. Keep LLVM enabled, because panfrost's precompiled CL kernels need `mesa_clc`.

- Run it with the Bash tool's `run_in_background` and no log redirect.
- `ninja` runs with `-j ${PANVK_JOBS:-6}`. The default (nproc+2) ran the 23 GiB host out of RAM on
  emulated C++ compiles.
- A lock file stops a second build from sharing the build dir. A killed host-side `podman exec`
  leaves its build running in the container, so check for one before retrying.
- Rerunning the script rebuilds incrementally. Build tree, ccache and install output all live in
  `_build/`, which is git-ignored through `.git/info/exclude`. The older `build_panvk.sh` /
  `BUILDING.md` describe the fork's Termux/kbase build.

KMD selection:
- `-Dpanfrost-kmds` takes any of `panfrost,panthor,kbase`. Each one defines `HAVE_PAN_KMOD_<NAME>`.
- `-Dpanvk-use-kbase` adds the raw-kbase JM submit TU. Both are off for panfrost.ko work.
- Every kbase-only code path must stay behind `#if defined(HAVE_PAN_KMOD_KBASE)`, so that a
  panfrost-only build compiles.

## Deploy / test on the device

- Device: `ssh ultramarine@192.168.1.19`. `sudo` needs a password, but `ssh root@192.168.1.19`
  works with key auth for root steps (sysext install, `dmesg`).
- `./deploy_panvk.sh [--install]` copies `_build/install/usr` to `~/panvk/usr` for root-less Vulkan
  tests (`VK_DRIVER_FILES=~/panvk/panfrost_icd.json`). It also builds a stripped erofs
  **systemd-sysext**, `_build/panvk.raw`, with `extension-release.panvk` matching the device's
  `ID`/`VERSION_ID`. `--install` puts it in `/var/lib/extensions/panvk.raw` over root SSH and runs
  `systemd-sysext refresh`. An existing `marina` sysext is also merged; don't touch it.
- The sysext **replaces the distro Mesa stack** (Fedora `mesa-dri-drivers`/`libEGL`/`libGL`/`libgbm`
  26.2), including the EGL/GBM that sway uses. Processes started before a refresh keep the old
  libraries mapped. Roll back with `rm /var/lib/extensions/panvk.raw && systemd-sysext refresh`.
- Display is the vendor `sunxi-drm` driver (card0); panfrost is the render node. Mesa has no
  kmsro entry for `sunxi-drm`, so compositors render through `renderD128`.
- On-device processes that must outlive an SSH command (RetroArch, etc.) run via
  `systemd-run --user` and are read with `journalctl --user -u <unit>`. Never use `setsid`/`nohup`
  with a log file, and stop processes by exact PID or unit, never by pattern.
- PanVK refuses v6/v7/v14 unless `PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1` is set. v9 is allowed.

## Architecture notes (JM path)

- Everything kernel-facing goes through the `pan_kmod` vtable (`src/panfrost/lib/kmod/`):
  `panfrost_kmod.c`, `panthor_kmod.c`, plus the fork-added `kbase_kmod.c`. `panfrost_kmod`
  supports only kernel-assigned VAs (`PAN_KMOD_VM_FLAG_AUTO_VA`): no explicit VA `vm_bind`, so
  no sparse binding.
- JM queue: `jm/panvk_vX_gpu_queue.c`. When no kbase node is in use, it builds a BO list per
  batch and calls `DRM_IOCTL_PANFROST_SUBMIT` twice: the vertex/tiler/compute chain, then the
  fragment chain with `PANFROST_JD_REQ_FS`, chained by syncobjs. The kbase branch dispatches to
  `jm/panvk_vX_gpu_queue_kbase.c`.
- Arch gates: upstream code uses `PAN_ARCH < 9` to mean "JM/Bifrost" and `>= 9`/`>= 10` to mean
  "Valhall/CSF". In this tree v9 is both Valhall *and* JM. Check every `PAN_ARCH < 9` gate for
  whether it really means "Bifrost-only" (descriptor and shader layout) or "JM-only"
  (submission, BO tracking). JM-only gates should be `< 10`. Example: framebuffer BO tracking
  in `panvk_cmd_draw.h` / `panvk_vX_cmd_draw.c` / `jm/panvk_vX_cmd_buffer.c`.
- The v9 draw path is a separate block in `jm/panvk_vX_cmd_draw.c` under `#if PAN_ARCH >= 9`. It
  uses Valhall SPD/resource tables and is KMD-agnostic. Dispatch, precomp and cmd_buffer also
  have v9 branches.
- Fork knobs: `PANVK_*` env vars, read with `getenv`/`os_get_option`. Most are kbase-only
  (`PANVK_ASYNC`, `PANVK_MERGE_SUBMIT`, `PANVK_OVERLAP`, `PANVK_KBASE_*`, `PANVK_AHB_WSI`).
  `PANVK_VERBOSE` / `PANVK_DEBUG` are general.
- The CSF kbase backend (Pixel 7 / G710 heritage) is also in tree, in `csf/panvk_vX_gpu_queue.c`.
  `docs/kbase-minecraft-fault-analysis.md` has its tiler-heap notes. It's irrelevant to the
  G57 work.

## Known issues inherited from the fork

See `KNOWN_ISSUES.md` and `STATUS.md`, both written against kbase/Termux:
- X11 output comes out black.
- vkmark batch reuse triggers `DATA_INVALID_FAULT` (JD event 0x58).
- `colorWriteMask` isn't handled for masked MRT preserve.
- Occlusion queries overcount.

Re-verify each one on panfrost.ko before assuming it applies.

## Conventions

- Upstream Mesa style (`.editorconfig`, `.clang-format`, 3-space C indent). Use Mesa commit
  prefixes (`panvk/jm:`, `panvk:`, `pan/kmod:`, `panfrost:`).
- Keep panfrost.ko changes separable from kbase code, so they can be rebased onto upstream Mesa
  main later.
