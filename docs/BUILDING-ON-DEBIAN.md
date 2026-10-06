# Building on Debian and Ubuntu

Two things differ from an Arch-family host. Both cost real time to diagnose because neither
symptom points at its cause.

## 1. The kernel headers are split, and conftest cannot cope

Debian splits headers into two trees:

```
/usr/src/linux-headers-6.1.0-53-common    has include/linux/   (the sources)
/usr/src/linux-headers-6.1.0-53-amd64     has include/config/  (the build/config)
/lib/modules/$(uname -r)/build   ->       the -amd64 one
```

The obvious invocation points `SYSSRC` and `SYSOUT` at `/lib/modules/$(uname -r)/build`. That
tree has no `include/linux`, so NVIDIA's conftest concludes that dozens of kernel features are
missing and the build collapses:

```
conftest/functions.h:76:2: error: #error dma_buf_export() conftest failed!
conftest/functions.h:90:2: error: #error wait_on_bit_lock() conftest failed!
common/inc/nv_stdarg.h:33:14: fatal error: stdarg.h: No such file or directory
```

That last line is the tell, and it is misleading. `linux/stdarg.h` is present — conftest just
could not see it, so it emitted `#undef NV_LINUX_STDARG_H_PRESENT` and the driver fell back to
the libc header, which is not available in a kernel build.

A trivial out-of-tree module builds fine with the default path, so "my headers are broken" is the
wrong conclusion. Only NVIDIA's conftest is affected.

**The fix — give it both trees:**

```bash
make -C <merged>/kernel modules -j$(nproc) \
     SYSSRC=/usr/src/linux-headers-$(uname -r | sed 's/-amd64//')-common \
     SYSOUT=/usr/src/linux-headers-$(uname -r) \
     NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem"
```

Confirm it worked before trusting the build:

```bash
cat <merged>/kernel/conftest/uts_release     # must name your running kernel
grep NV_LINUX_STDARG_H_PRESENT <merged>/kernel/conftest/headers.h   # must be #define, not #undef
```

Always `rm -rf conftest` first. A conftest left from another kernel is the original trap this
project lost weeks to, and it is silent — the build succeeds and the module misbehaves.

## 2. vgpu_unlock-rs picks the wrong board without a config

With no `/etc/vgpu_unlock/config.toml`, the library uses its upstream Ampere default `0x2230`,
which is an **RTX A6000** — a 48 GB card. On a 24 GB RTX 3090 you then get 22 profiles scaling up
to `48Q`, with `available_instances` counts computed against memory that does not exist:

```
nvidia-533   NVIDIA RTXA6000-48Q   fb=49152M   avail=1
nvidia-529   NVIDIA RTXA6000-8Q    fb=8192M    avail=6
```

Nothing errors. It simply advertises a card twice the size of the real one.

**The fix:**

```toml
unlock = true
unlock_migration = false

[pci_info_map."0x2204"]
device_id = 8753        # 0x2231  RTX A5000
sub_system_id = 5474    # 0x1562
```

The A5000 is the only GA102 professional board in `vgpuConfig.xml` with the same 24 GB
framebuffer as a 3090, which is why it is the right spoof target rather than the A6000. With the
file in place you get 18 `RTXA5000-*` profiles and `nvidia-664 = RTXA5000-8Q` with `avail=3`.

**Changing this config needs a full stack reload, not a daemon restart.** The mdev types are
registered when RM is configured at module load, so restarting `nvidia-vgpud` leaves the old
table in place and nothing tells you:

```bash
systemctl stop nvidia-vgpu-mgr nvidia-vgpud
rmmod zfmulti mdguest nvidia_vgpu_vfio nvidia_uvm nvidia
echo 1 > /sys/bus/pci/devices/<bdf>/reset
# then bring the stack back up in the usual order
```

## Smaller Debian differences

- **nouveau** binds the card at boot and is in use, so it cannot be `rmmod`ed. Blacklist it and
  reboot. Write the blacklist *before* anything triggers `update-initramfs`, so it lands in the
  initramfs on the first regeneration.
- **`modinfo` is in `/usr/sbin`**, which is not on a normal user's PATH. Scripts that call it
  unqualified will fail with `command not found` rather than anything informative.
- **OVMF** is at `/usr/share/OVMF/OVMF_CODE_4M.fd` from the `ovmf` package. `detect_ovmf` in
  `lib/common.sh` finds it.
- **`nvidia-vgpud.service` is `Type=oneshot`.** `systemctl is-active` reporting `inactive` after
  a successful run is correct. Check the journal for `Finished`, not the active state.
- The vGPU userland does not need installing over system libraries. Point the loader at the tree
  instead, which leaves the distribution's own libraries untouched:
  ```bash
  echo /path/to/535.309.01/usr/lib/x86_64-linux-gnu > /etc/ld.so.conf.d/nvidia-vgpu-535.conf
  ldconfig
  ```

## Why Debian at all

Proxmox VE ships kernels that fail: 8.2+ is 6.8, and 9.x is 6.14 / 6.17 / 7.0. Debian 12 ships
the 6.1 series, which works. Installing Proxmox VE on top of Debian 12 and keeping Debian's
kernel is the only route to a Proxmox management layer on a working kernel — `proxmox-ve`
hard-depends on `proxmox-default-kernel`, so that kernel gets installed either way and boot must
be pinned back to 6.1.
