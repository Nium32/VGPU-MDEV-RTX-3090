# Setup

Read [HARDWARE-SCOPE.md](HARDWARE-SCOPE.md) and [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md)
first. If your kernel is not 6.1.71 or 5.15.95, stop and deal with that before anything else —
everything below will appear to work and then not work.

This repository contains the scripts and the findings. It does not contain the NVIDIA driver, the
installers, or any guest image; you supply those.

## What you need in place

A merged vgpu-kvm driver build for your kernel, producing at minimum `nvidia.ko` and
`nvidia-vgpu-vfio.ko`, plus `nvidia-uvm.ko` if you also want host CUDA. The build used here is
535.309.01 from the `general-merge` target of the vGPU-Unlock-Patcher, which keeps the vgpu-kvm RM
core and adds the consumer userland.

`vgpu_unlock-rs` built and `LD_PRELOAD`ed into `nvidia-vgpud` and `nvidia-vgpu-mgr` only. Do not
try to preload it into the kernel module path; the spoof is userspace-only by design.

QEMU with KVM, a 4 MB OVMF image, and `uuidgen`.

The expected on-disk layout, which `vgpu.conf` points at:

```
$VGPU_ROOT/driver/modules-<uname -r>/    nvidia.ko, nvidia-vgpu-vfio.ko, nvidia-uvm.ko
$VGPU_ROOT/kmod/zfmulti/                 zfmulti-<uname -r>.ko   (required)
$VGPU_ROOT/kmod/mdguest/                 mdguest-<uname -r>.ko
$VM_BASE/<vm name>/                      the guest's qcow2 and its own OVMF_VARS.fd
```

A module built for one kernel cannot load on another — `insmod` rejects the version magic — so the
module tree is per-kernel and there is deliberately no generic fallback.

## Build the helper modules

```bash
make -C kmod/zfmulti
make -C kmod/mdguest
```

Then put the results where `vgpu.conf` expects them, named `zfmulti-$(uname -r).ko` and
`mdguest-$(uname -r).ko`. The scripts accept the unsuffixed name too, but they check vermagic and
will refuse a mismatch rather than letting `insmod` fail obscurely.

`zfmulti` is the required one. Before you can use it you need the right symbol and offset for
*your* driver build — `_nv042311rm+0x28` is correct for 535.309.01 and is very unlikely to be
correct for anything else. See the note at the end of KERNEL-REQUIREMENTS.md.

## Configure

```bash
cp vgpu.conf.example vgpu.conf
```

You can start by editing nothing. Every value is either defaulted or discovered. The ones most
likely to need setting are `VGPU_ROOT`, `VM_BASE`, `VM_NAME` and `VM_DISK`.

Set `VGPU_PROFILE_NAME` to a profile *name* such as `RTXA5000-8Q`, not to an `nvidia-NNN` id. The
numeric ids are assigned per driver version and per board and will not match yours.

## Check the machine

```bash
sudo ./scripts/preflight.sh
```

It changes nothing. It reports the GPU it found and its real PCI id, the IOMMU group, the module
set for your kernel with each module's version and vermagic, whether the required helpers exist and
match, where your OVMF image is, every vGPU profile the card offers with framebuffer sizes and
availability, and how many DRM connectors exist (expect zero).

It warns about an untested kernel, a missing IOMMU, and `nvidia_modeset` being loaded. Fix what it
flags before continuing.

## Bring the stack up

```bash
sudo ./scripts/bringup.sh
```

The order is load-bearing and the script enforces it:

1. `nvidia.ko` with `NVreg_RegistryDwords=RMSetSriovMode=0` and `NVreg_EnableGpuFirmware=0`
2. `nvidia-vgpud` — this is where the device-ID spoof applies
3. `nvidia-vgpu-vfio.ko`
4. `nvidia-uvm.ko`, only if you want host CUDA; the device nodes are created by hand because
   nothing does it for a hand-`insmod`ed module
5. the kprobe helpers
6. `nvidia-vgpu-mgr` — this is what actually registers the mdev types

Two things that are not obvious. `nvidia-vgpu-vfio.ko` links against `mdev`, `vfio`,
`vfio_pci_core` and `irqbypass`; without them `insmod` fails with "Unknown symbol in module" and
does not say which symbol. And a PCI function-level reset is mandatory after any by-hand reload —
skip it and the first guest fails at `init_device_instance` with error 7.

Output goes to `$LOG_DIR/bringup.log`. A healthy run ends with the profile count, the selected
profile's available instances, `xid in dmesg: 0` and `plugin errors: 0`.

## Boot a guest

```bash
sudo ./scripts/startguest.sh
```

Creates a fresh mdev on the configured profile, writes `vgpu_params` to it, and boots QEMU. If
QEMU fails to start, the script removes the mdev it created rather than leaking it.

The guest needs its registry keys set before any of this helps:

```
RMSetClientRMAllocatedCtxBuffer = 0
RmRcWatchdog                    = 0
```

Both as DWORDs under
`SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001`. Subkey
`0001`, not `0000` — it must be the class subkey the live device instance points at.

## Check it is working

Three counters, scoped to the current run using the mark the start script writes:

```bash
MARK=$(cat /var/log/vgpu/winguest.mark)   # $LOG_DIR/$VM_NAME.mark
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -ci 'Immediate pteblit'
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -c  'error:'
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -cE 'XID [0-9]+ detected'
```

All three must be zero. A non-zero pteblit count means the kernel is wrong, not the configuration.

Confirm the kprobes are live with `lsmod | grep -E 'zfmulti|mdguest'`. Do not use
`/sys/kernel/debug/kprobes/list` as the check — it only works when debugfs happens to be mounted,
so a zero reading there means nothing.

Do not use `nvidia-smi` to confirm vGPU is working. With a guest running and holding 8 GB it still
reports `Virtualization Mode : None`.

## Tear down

```bash
sudo ./scripts/hardreset.sh
```

Needed more often than you would expect. If a QEMU holding an mdev is killed with `SIGKILL`, the
IOMMU group stays wedged and every later QEMU fails with `error getting device from group <N>`
even though nothing holds the device. Unloading the nvidia modules and resetting the GPU is not
enough; `vfio_iommu_type1`, `vfio_pci_core`, `vfio` and `mdev` keep the group object alive, and
unloading those is what destroys it. The script discovers the group number rather than assuming it.

One failure mode has no software exit: if `nvidia_modeset` has spun up, its refcount never drops,
it pins `nvidia.ko`, and you have to reboot.
