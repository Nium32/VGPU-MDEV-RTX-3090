# Full tutorial: vGPU on a GeForce RTX 3090, start to finish

This walks the whole thing from a bare machine to a Windows guest running CUDA on a slice of a
consumer RTX 3090, with the Linux host keeping the card at the same time.

It is long because the short version does not work. Nearly every step has one detail that, if you
skip it, produces a setup that *looks* fine and does nothing.

Read [HARDWARE-SCOPE.md](HARDWARE-SCOPE.md) first if you have not. Short version: this is proven
on one GA102 RTX 3090 on kernel 6.1.71 with driver 535.309.01. On any other combination, step 5
becomes reverse engineering rather than configuration.

---

## Part 0: what you are actually building, and what you are not

### The picture

```
            ┌─────────────────── Linux host ───────────────────┐
            │                                                  │
            │   nvidia.ko (vgpu-kvm, RMSetSriovMode=0)         │
            │        │                                          │
            │   nvidia-vgpud ──┐  LD_PRELOAD vgpu_unlock-rs    │
            │   nvidia-vgpu-mgr┘  (tells them the card is an    │
            │        │             A5000, not a 3090)          │
            │        │                                          │
            │   mdev devices ─── one per guest, 8 GB each       │
            │        │                                          │
            │   nvidia-uvm.ko ── optional: host CUDA            │
            └────────┼─────────────────────────────────────────┘
                     │ vfio-pci
            ┌────────┴──────┐   ┌───────────────┐
            │  Windows VM   │   │  second VM    │
            │  8 GB vGPU    │   │  8 GB vGPU    │
            │  CUDA, OpenGL │   │               │
            └───────────────┘   └───────────────┘
```

The GPU is **not** passed through. It stays bound to the host driver, which carves it into
mediated devices (mdevs). Each guest gets one mdev, which looks to it like a real GPU with its own
8 GB of framebuffer. The host can still use the card.

### What makes this possible on a consumer card

NVIDIA's vGPU driver refuses to run unless the PCI device id belongs to a card they sell for it.
`vgpu_unlock-rs` is `LD_PRELOAD`ed into the two NVIDIA userspace daemons and rewrites the id they
see, so a 3090 (`10de:2204`) presents as an RTX A5000 (`10de:2231`). The kernel module is never
patched and always sees the real id.

That gets you a device the stack will talk to. It does **not** get you a working one — that is
what the rest of this document is about.

### What you are not building

**You are not getting a monitor.** The vgpu-kvm RM core publishes zero KMS connectors. Neither the
host nor any guest can drive a display from this card. Verified: `/sys/class/drm` holds nothing but
`version` and `/dev/dri` does not exist. If you want a screen on your desk, you need a second GPU.
Guests are reached over RDP or a streaming client.

**You are not overcommitting VRAM.** 24 GB splits into fixed slices. 8 GB each, three at most.

**You are not avoiding licensing.** Unlocking the device gate is unrelated to vGPU licensing.
Guests still want a license server or they throttle after a grace period.

**You are not on a supported path.** Expect to redo work after driver and kernel updates.

### Time and difficulty

If your hardware matches exactly: a few hours. If it does not, step 5 is disassembly work and
there is no estimate — that step is what this whole project was.

---

## Part 1: hardware and BIOS

### What you need

- An NVIDIA GPU the unlock covers. Proven: GA102 RTX 3090. Anything else, see
  [HARDWARE-SCOPE.md](HARDWARE-SCOPE.md).
- A CPU and board with IOMMU. Nothing exotic: this was developed on a Ryzen 7 2700 on an X370
  board from 2017.
- A **second GPU** if you want a monitor on the host. Any cheap AMD card on `amdgpu` is the
  low-risk choice. Note a Kepler card like a GTX 650 will not work with driver 535 — Kepler
  support ended at 470 — so it would have to run `nouveau`.
- Enough RAM for host plus guests. 12 GB per Windows guest is comfortable.
- Disk space: the driver trees and a Windows image come to roughly 60 GB.

### BIOS

Enable IOMMU: `AMD-Vi`/`SVM` on AMD, `VT-d` on Intel.

That is the whole list. Nothing else mattered here. Specifically:

- **Resizable BAR**: leave it alone. The capability exists and BAR1 could be 32 GB; it ran at the
  stock 256 MB throughout and no part of this works because of it.
- **Above 4G Decoding**: default.
- **ACS override patches**: not needed. The GPU's IOMMU group contained only the GPU and its own
  audio function.

### Check IOMMU came up

```bash
ls /sys/class/iommu/
dmesg | grep -iE 'AMD-Vi|DMAR'
```

You should see at least one entry. On this host it worked with **no** `amd_iommu=` or `iommu=`
kernel parameter at all. If `/sys/class/iommu` is empty, add `amd_iommu=on` or `intel_iommu=on` to
your kernel command line and reboot.

Find your GPU and its group:

```bash
lspci -D -d 10de::0300
readlink -f /sys/bus/pci/devices/0000:0a:00.0/iommu_group
ls /sys/bus/pci/devices/0000:0a:00.0/iommu_group/devices/
```

Substitute your own address. The group should contain only the GPU and its audio function. **The
group number is not stable** — it was 15 and earlier 22 on the same machine across reboots. Never
hard-code it; the scripts here discover it.

---

## Part 2: the host OS and the kernel

### This is the step people get wrong

Install a Linux distribution, then make sure you are on a kernel that works:

| kernel | result |
|---|---|
| 5.15.95 | works |
| **6.1.71** | works — use this |
| 6.8.9 | **fails** |
| 6.18.52 | **fails** |

Nothing between 6.1 and 6.8 has been tested, so anything in that range is a coin flip and genuinely
unknown.

The failure is nasty because it is quiet. On 6.8 the modules load, the mdev appears, the guest boots
all the way to a Windows desktop — and then the framebuffer blit times out, over and over:

```
Immediate pteblit ... timed out
```

50 timeouts and 100 plugin errors on 6.8.9. Roughly 76 and 152 on 6.18. You do not get a clear
error, you get something that almost works. If you are debugging a setup that behaves this way,
check your kernel before anything else.

The mechanism was never identified. An early guess blamed the vfio pin-page rework at 6.0; that
guess was wrong, because 6.1 works.

### Getting 6.1.71 on an Arch-family host

```bash
sudo pacman -U --needed \
  https://archive.archlinux.org/packages/l/linux-lts/linux-lts-6.1.71-1-x86_64.pkg.tar.zst \
  https://archive.archlinux.org/packages/l/linux-lts-headers/linux-lts-headers-6.1.71-1-x86_64.pkg.tar.zst
```

Then **pin it**, or the next routine upgrade silently destroys your setup. In `/etc/pacman.conf`:

```
IgnorePkg = linux-lts linux-lts-headers
```

On Debian-family hosts, install the matching kernel and headers and hold them with
`apt-mark hold`.

Keep the headers package. You cannot build the driver without it.

### Stop the distribution driver loading

You do not want nouveau or a distro NVIDIA package touching the card.

```bash
sudo tee /etc/modprobe.d/blacklist-nvidia-distro.conf <<'EOF'
blacklist nouveau
blacklist nvidia_drm
blacklist nvidia_modeset
EOF
sudo mkinitcpio -P      # or update-initramfs -u on Debian
```

`nvidia_drm` and `nvidia_modeset` are on that list for a specific reason. See the warning in
Part 11 — loading `nvidia_modeset` costs you a reboot, every time.

Reboot and confirm:

```bash
uname -r                  # must be your chosen kernel
lsmod | grep -E 'nouveau|nvidia'   # must be empty
```

---

## Part 3: get and build the driver

### What you need to obtain

Two things, neither of which this repository redistributes:

1. The **vgpu-kvm host driver**, `NVIDIA-Linux-x86_64-535.309.01-vgpu-kvm.run`. This comes from
   NVIDIA's licensing portal. It is not a public download.
2. The matching **GRID guest driver** for Windows, `539.72`. Same source.

You also want the matching consumer driver `.run` for the same version, because the merge step
takes the userspace from it.

### The merge

Use [vGPU-Unlock-Patcher](https://github.com/VGPU-Community-Drivers/vGPU-Unlock-Patcher) with the
`general-merge` target:

```bash
git clone https://github.com/VGPU-Community-Drivers/vGPU-Unlock-Patcher.git
cd vGPU-Unlock-Patcher
cp /path/to/NVIDIA-Linux-x86_64-535.309.01-vgpu-kvm.run .
cp /path/to/NVIDIA-Linux-x86_64-535.309.01.run .
./patch.sh general-merge
```

What this produces is a driver with the **vgpu-kvm RM core** and the consumer userland. That
distinction matters: `general-merge` deliberately restores the vgpu-kvm `nv-kernel.o_binary`, which
is why the display limitation in Part 0 cannot be worked around by merging differently. The RM core
is what has no display engine, and `general-merge` keeps it by design.

To be clear about what the patcher does and does not do: it patches device-id gating, profile
tables, licensing and branding. It does not touch scheduling or display. On this build the string
`vup_` appears zero times in `nv-kernel.o_binary`, and `vgpuConfig.xml` is byte-identical to its
backup.

### Build it

```bash
cd NVIDIA-Linux-x86_64-535.309.01-vgpu-kvm-merged
sudo ./nvidia-installer --dkms=no --no-systemd --silent \
     --no-install-compat32-libs --no-nvidia-modprobe
```

Or build just the modules and keep them out of `/usr`, which is what this project does — it leaves
the system libraries alone and keeps each kernel's modules in their own directory:

```bash
make -C kernel modules \
     SYSSRC=/usr/lib/modules/$(uname -r)/build \
     SYSOUT=/usr/lib/modules/$(uname -r)/build \
     NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem"
mkdir -p /srv/vgpu/VMs/driver/modules-$(uname -r)
cp kernel/*.ko /srv/vgpu/VMs/driver/modules-$(uname -r)/
```

### The conftest trap

NVIDIA's build system probes your kernel with small test compilations and writes the answers into
`conftest/`. If that directory is stale — generated against a *different* kernel's headers — every
`#if defined(NV_...)` in the driver silently picks the wrong branch. The build succeeds. The module
loads. It misbehaves in ways that look like hardware problems.

This cost a lot of time here. Before any rebuild:

```bash
rm -rf kernel/conftest
# then build, and verify:
cat kernel/conftest/uts_release    # must equal `uname -r`
```

Also be aware the conftest logic is inverted from what you would expect: for `functions` tests, a
test that *compiles successfully* means the feature is **absent**.

### Two build notes

If you build out-of-tree against a kernel whose `include/generated/autoconf.h` is missing, do
**not** `touch` the file to make the check pass. Kbuild only tests that the file exists, so an empty
one satisfies it and the entire driver then compiles with no `CONFIG_*` defined — wrong struct
layouts, wrong conftest answers, a module that loads and then oopses. Reinstall the headers instead.

And check whether your build produced `nvidia-drm.ko` and `nvidia-modeset.ko` despite the exclude
list. On this host they appeared anyway, built by a later step. Their presence in the module
directory is a trap; see Part 11.

### Verify what you built

```bash
modinfo -F version  /srv/vgpu/VMs/driver/modules-$(uname -r)/nvidia.ko
modinfo -F vermagic /srv/vgpu/VMs/driver/modules-$(uname -r)/nvidia.ko
```

Version should be `535.309.01` and vermagic must match `uname -r` exactly. A module built for
another kernel cannot load — `insmod` rejects it on version magic — which is why the module tree
here is per-kernel with no generic fallback.

---

## Part 4: vgpu_unlock-rs

This is the device-id spoof. It goes into the two NVIDIA daemons and nowhere else.

```bash
git clone https://github.com/mbilker/vgpu_unlock-rs.git
cd vgpu_unlock-rs
cargo build --release
sudo mkdir -p /opt/vgpu_unlock-rs
sudo cp target/release/libvgpu_unlock_rs.so /opt/vgpu_unlock-rs/
```

Hook it into both units:

```bash
sudo mkdir -p /etc/systemd/system/nvidia-vgpud.service.d \
              /etc/systemd/system/nvidia-vgpu-mgr.service.d

sudo tee /etc/systemd/system/nvidia-vgpud.service.d/vgpu_unlock.conf <<'EOF'
[Service]
Environment=LD_PRELOAD=/opt/vgpu_unlock-rs/libvgpu_unlock_rs.so
EOF

sudo cp /etc/systemd/system/nvidia-vgpud.service.d/vgpu_unlock.conf \
        /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf

sudo systemctl daemon-reload
```

Do not try to preload it anywhere else. The spoof is userspace-only on purpose; `nvidia.ko` always
sees `10de:2204` and that is correct.

If `nvidia-vgpud` publishes no profiles later, this is the first thing to check:

```bash
sudo journalctl -u nvidia-vgpud -b | grep -i 'devid'
```

You want to see the spoofed id in there.

---

## Part 5: the kprobe — the one thing that actually makes it work

### What the problem is

Without this, everything else succeeds and the guest still does nothing useful. The guest's
graphics channel gets scheduled exactly once and then never again. No error is logged. Nothing
reports a fault. It simply stops.

The cause: a function in the RM interrupt handler disables the graphics runlist and never
re-enables it. Measured by counting calls per call site over about 70 seconds with the guest hung:

```
site _nv042311rm+0x77    disables=572   enables=0      <-- one-way
site _nv023182rm+0xad    disables=15    enables=15     <-- correctly paired
total                    disables=587   enables=15     LEAK=572
```

The fix is to force one branch in that handler so the disable never happens. That is all `zfmulti`
does: it registers a kprobe at an offset and sets the zero flag so one conditional goes the other
way.

With it: leak 0, `SCHED_DISABLE` stays 0, and the guest's channel runs all 80 of its queued work
items natively with no poking. A control test with no kprobe at all: everything hangs.

### Building it

```bash
make -C kmod/zfmulti
make -C kmod/mdguest
cp kmod/zfmulti/zfmulti.ko /srv/vgpu/VMs/kmod/zfmulti/zfmulti-$(uname -r).ko
cp kmod/mdguest/mdguest.ko /srv/vgpu/VMs/kmod/mdguest/mdguest-$(uname -r).ko
```

The per-kernel naming matters — the scripts check vermagic and refuse a mismatch rather than
letting `insmod` fail with something cryptic.

### If you are on driver 535.309.01

The offset is known:

```
spec=_nv042311rm+0x28:1
```

That is the default in `vgpu.conf.example` and you can move on.

### If you are not, you have to find it yourself

This is the genuinely hard part and there is no shortcut. The symbol names are anonymised by
NVIDIA, and both the name and the offset move between driver versions. Even within 535.309.01, the
same symbol sat at two different addresses across two kernel builds.

The approach that found it:

1. Find the function that writes the runlist scheduling-disable register. On GA102 that is a
   `KernelFifo` HAL entry; the write target is the `NV_RUNLIST_SCHED_DISABLE` field.
2. Put a kprobe on it that records the return address, so you learn which call sites invoke it.
3. Run a guest until it hangs, then count disables and enables **per call site**.
4. One site will be wildly unbalanced. On 535.309.01 that was `_nv042311rm+0x77`, an interrupt
   handler for event type 0xe, at `.text` offset `0x7eeb10`, size `0xcd`.
5. Disassemble that function and find the branch that decides whether to disable. Here it was a
   single `test`/`jne` pair testing a flag at `pGpu+0x44ec & 0x10`, at `+0x28`.
6. The kprobe goes at the *test*, forcing the flag so the branch is not taken. Never patch the
   predicate itself.

Tools that help: `nvko.py`-style relocation mapping to give the anonymised functions stable names,
plus Ghidra or objdump on `nv-kernel.o_binary`. The guest driver is more helpful than the host one
because it keeps `NV_PRINTF` strings you can cross-reference to recover function names.

There is **no evidence either way** about whether `_nv042311rm` even exists on 550 or 580.

### A note on mdguest

The working setup loads `mdguest apply=1` and older notes describe it as the PCI-id spoofer. Both
claims look wrong on this build. Live parameters measured with a guest running:

```
apply=1  seen=805  matched=0  patched=0
```

It has patched nothing. It is probably vestigial. Removing it was never tested, so the scripts
still load it and you should too until someone checks.

---

## Part 6: configure and preflight

```bash
git clone <this repo>
cd VGPU-MDEV-RTX-3090
cp vgpu.conf.example vgpu.conf
```

Set the paths and the profile **by name**:

```bash
VGPU_ROOT=/srv/vgpu/VMs
VM_BASE=/var/lib/vgpu-vm
VM_NAME=winguest
VM_DISK=win.qcow2
VGPU_PROFILE_NAME=RTXA5000-8Q
```

Use the name, not an `nvidia-NNN` id. The numeric ids are assigned per driver version and per
board and will not match yours.

Then:

```bash
sudo ./scripts/preflight.sh
```

This changes nothing. It reports the GPU it found and its real PCI id, the IOMMU group, the module
set for your kernel with versions and vermagic, whether the helpers exist and match, your OVMF
path, every profile the card offers with framebuffer sizes, and the DRM connector count (expect
zero).

Fix everything it flags before continuing. In particular it refuses to bless a kernel outside the
known-good list, a missing IOMMU, or a loaded `nvidia_modeset`.

---

## Part 7: bring the stack up

```bash
sudo ./scripts/bringup.sh
```

### The order is load-bearing

1. `nvidia.ko` with `NVreg_RegistryDwords=RMSetSriovMode=0` and `NVreg_EnableGpuFirmware=0`
2. `nvidia-vgpud` — the spoof applies here
3. `nvidia-vgpu-vfio.ko`
4. `nvidia-uvm.ko` — only if you want host CUDA
5. the kprobe helpers
6. `nvidia-vgpu-mgr` — **this** is what registers the mdev types

Why each parameter:

- `RMSetSriovMode=0` picks the legacy mediated-device path. Consumer Ampere has no SR-IOV, so this
  is not a preference.
- `NVreg_EnableGpuFirmware=0` disables GSP. GSP cannot boot on this card: you get
  `Xid 119 GSP_INIT_DONE` timeout, the GPU wedges, and the mdev types vanish. This project sets it
  twice over — on the insmod line and on the kernel command line as
  `nvidia.NVreg_EnableGpuFirmware=0`.

### Two things that will bite you

`nvidia-vgpu-vfio.ko` links against `mdev`, `vfio`, `vfio_pci_core` and `irqbypass`. Without them
`insmod` fails with "Unknown symbol in module" and does not tell you which symbol. The script
modprobes them first.

A **PCI function-level reset is mandatory** after any by-hand reload. Skip it and the first guest
fails at `init_device_instance` with error 7 (init frame copy engine).

### Healthy output

```
profiles      : 18
selected      : nvidia-664 (NVIDIA RTXA5000-8Q)
available     : 3
xid in dmesg  : 0
plugin errors : 0
================ ready ================
```

If `profiles` is 0, `nvidia-vgpu-mgr` is not running or the spoof is not working. If it prints
anything other than `ready`, read the log and stop.

Check the kprobe took:

```bash
lsmod | grep -E 'zfmulti|mdguest'
```

Both must be listed. Do **not** use `/sys/kernel/debug/kprobes/list` as your check — it only works
when debugfs happens to be mounted, so a zero reading there means nothing at all.

---

## Part 8: build the guest

### Create the VM directory and disk

```bash
sudo mkdir -p /var/lib/vgpu-vm/winguest
cd /var/lib/vgpu-vm/winguest
sudo qemu-img create -f qcow2 win.qcow2 80G
sudo cp /usr/share/edk2/x64/OVMF_VARS.4m.fd OVMF_VARS.fd
```

The `OVMF_VARS.fd` must be the **4 MB** variant and must match your `OVMF_CODE`. A 2 MB code image
with a 4 MB vars file does not boot. One `OVMF_VARS.fd` **per VM** — two guests sharing one file
clobber each other's boot entries.

### Install Windows first, without the vGPU

Install with plain emulated graphics. Do not attach the mdev yet; you want a working Windows before
adding the complicated part.

```bash
sudo qemu-system-x86_64 -name winguest \
  -machine q35,accel=kvm -smp 8 -m 12288 \
  -cpu host,kvm=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,unit=1,file=OVMF_VARS.fd \
  -device ich9-ahci,id=ahci \
  -drive file=win.qcow2,if=none,id=disk0,format=qcow2 \
  -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
  -cdrom /path/to/windows.iso \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
  -vga std -vnc 127.0.0.1:2
```

Connect with a VNC client to `127.0.0.1:5902`. **Bind to loopback**, not `0.0.0.0` — an
unauthenticated VNC console on a public interface hands anyone the guest's keyboard and screen.
Tunnel over SSH if you need it remotely:

```bash
ssh -L 5902:127.0.0.1:5902 user@host
```

Inside Windows, before you go further:

1. Enable **Remote Desktop**. This becomes your main way in, since the vGPU has no display output.
2. Set the account to auto-logon if you want the guest usable without a console.
3. Note that `usb-tablet` needs xHCI to work properly; without it the pointer misbehaves.

Shut the guest down cleanly when you are done.

### Now attach the vGPU

```bash
sudo ./scripts/startguest.sh
```

This creates a fresh mdev on your profile, writes `vgpu_params` to it, and boots the guest with the
mdev attached as `vfio-pci`. If QEMU fails to start, the script removes the mdev rather than
leaking it — important, because the profile only has three instances and leaked mdevs exhaust them.

---

## Part 9: the guest driver and the registry keys

### Install the GRID driver

Copy `539.72` into the guest and install it. It will appear in Device Manager and, at this stage,
almost certainly show **Code 43**.

That is expected. Code 43 here is not a generic "driver failed" — it is the specific failure this
whole project was about, and the next step fixes it.

### The two registry keys

Both as **DWORD** values:

```
RMSetClientRMAllocatedCtxBuffer = 0
RmRcWatchdog                    = 0
```

Under:

```
HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001
```

**Subkey `0001`, not `0000`.** It must be the class subkey the live device instance actually points
at. Getting this wrong is a silent no-op — the keys exist, nothing changes, and you conclude they
do not work.

Why each one:

- `RMSetClientRMAllocatedCtxBuffer=0` stops the guest owning and promoting its own graphics context
  buffers. With it unset, the guest promotes its buffers while the host keeps and initialises its
  own, the context switcher lands on an all-zero context, and every run raises
  `Xid 44 ... Ch 00000008, intr 00000000`. With it at 0 the guest sends no promote request, the
  host's initialised context is used, and Xid 44 disappears completely.
- `RmRcWatchdog=0` disables RM's own recovery watchdog. That watchdog is a channel RM creates for
  itself and it was the first thing to demand graphics context buffers, so it took the whole
  adapter down with it — `krcWatchdogInit_IMPL` returned `NV_ERR_INVALID_STATE` on every call.
  Measured: with the key, 0 failures and the device enumerates. Without it, 4 failures and "No
  devices were found".

Reboot the guest. Device Manager should now show the GPU working, and in the guest:

```
nvidia-smi
```

should report `NVIDIA RTXA5000-8Q`, 8192 MiB.

---

## Part 10: prove it actually works

Do not trust the absence of errors. On this stack it is entirely possible to have a guest that
reports success and computes nothing — fences can be forged, and at one point a test returned
`rc=0` while `memset32` silently did nothing and a readback showed the original pattern. **Verify
by reading data back.**

### Host-side counters first

```bash
MARK=$(cat /tmp/vgpu-mark.txt)
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -ci 'Immediate pteblit'
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -c  'error:'
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -cE 'XID [0-9]+ detected'
```

All three must be **0**. A non-zero pteblit count means your kernel is wrong — go back to Part 2.

### In the guest: copy, then compute

A copy test proves the copy engine. It does **not** prove compute — the copy engine worked for a
long time on this project while graphics never executed. Run both:

```c
// 1. allocate, fill with a known pattern, copy host->device->host, compare every byte
// 2. launch a kernel that writes a computed value per element, copy back, check every element
```

A real pass looks like:

```
cuInit rc=0   device='NVIDIA RTXA5000-8Q'   computeCapability=8.6
COPY-PASS    (4 MiB roundtrip verified)
cuLaunchKernel rc=0 ; readback verified 1052 sampled elements
COMPUTE-PASS
```

If you write PTX by hand, note `.version 7.0` with `.target sm_86` fails to load — `sm_86` needs
PTX ISA 7.1 or later. Use `cuModuleLoadDataEx` with `CU_JIT_ERROR_LOG_BUFFER` so you actually see
why a load failed instead of a bare error code.

### Do not use nvidia-smi on the host to confirm vGPU

With a guest running and holding 8 GB, host `nvidia-smi` still reported:

```
Virtualization Mode : None
Host VGPU Mode      : N/A
```

It is not a reliable indicator here. Check `/sys/bus/mdev/devices/` and ask the guest.

---

## Part 11: things that will cost you a reboot, or worse

Read this section before experimenting.

| do not | what happens |
|---|---|
| load `nvidia_modeset` | wedges the display engine with `Error while waiting for GPU progress`. Its refcount never drops, which pins `nvidia.ko` and makes the whole stack un-unloadable. **Only a reboot clears it.** Three were spent learning this. |
| set `nvidia_drm modeset=1` | creates a `card0` with zero connectors, and wedges as above |
| write to `/dev/fb0` | the EFI framebuffer is mapped inside BAR1, the same aperture the vGPU stack uses. A 3 MB write there silently corrupted a running guest. |
| `kill -9` a QEMU holding an mdev | leaves the IOMMU group wedged. Every later QEMU fails with `error getting device from group N` even though nothing holds the device. Needs `hardreset.sh`. |
| loop the BAR0 PRAMIN window while RM is live | wedged the host hard enough to need a physical power cycle. Set the window once per 64 KB, never per entry. |
| `pacman -Syu` without pinning the kernel | moves you off a working kernel onto a broken one |
| use any `RMInstLoc` value | `65536` loads and leaves the mdev unusable. `131072` is **untested** despite older notes claiming otherwise. |
| set `pte_blit_enabled=0` | trades the blit timeouts for `Guest FB pfn out-of-range`, Xid 43 and a TDR |
| clear bit 5 of `vgpu_device_caps` | Xid 31 |
| use the `8A` profile | `cuCtxCreate` returns 801 NOT_SUPPORTED and no channel is ever scheduled. Stay on `8Q`. |

On the module directory trap: if your build left `nvidia-drm.ko` and `nvidia-modeset.ko` in there
despite the exclude list, they are one `modprobe` away from the first row of that table. The
scripts here refuse to continue if either is loaded.

---

## Part 12: daily operation

```bash
# start
sudo ./scripts/bringup.sh
sudo ./scripts/startguest.sh

# get in
ssh -L 3390:127.0.0.1:3390 user@host     # then RDP to 127.0.0.1:3390

# stop the guest cleanly - do NOT kill -9
printf "system_powerdown\n" | sudo socat - UNIX-CONNECT:/var/lib/vgpu-vm/winguest/monitor.sock

# recover from a wedged group
sudo ./scripts/hardreset.sh
sudo ./scripts/bringup.sh
```

### Why hardreset exists

If a QEMU holding an mdev dies by `SIGKILL`, the IOMMU group stays wedged. Unloading the nvidia
modules and resetting the GPU is **not** enough: `vfio_iommu_type1`, `vfio_pci_core`, `vfio` and
`mdev` keep the group object alive. Unloading those is what destroys it, and that is what
`hardreset.sh` does.

### A second guest

The 8Q profile allows three instances. Make a second VM directory with its own disk and its own
`OVMF_VARS.fd`, set `VM_NAME`, and run `startguest.sh` again. Two guests were measured running a 9B
parameter model concurrently at roughly 83 tok/s aggregate — the card time-slices between them, so
aggregate throughput holds up while per-guest latency does not.

### Host CUDA alongside the guests

`bringup.sh` loads `nvidia-uvm.ko` and creates `/dev/nvidia-uvm` by hand, because nothing does that
for a module you `insmod` yourself. You then need a `libcuda` matching the 535 module, kept isolated
so it does not overwrite your system libraries:

```bash
sudo LD_LIBRARY_PATH=/opt/nv535-x python3 your-cuda-test.py
```

Never install the 535 userland over the distribution's libraries.

### Host graphics (Vulkan, NVENC)

```bash
bash scripts/stage-gfx.sh
```

Builds `/opt/nv535-gfx` out of the merged tree: the 535 libraries with SONAME symlinks generated
from each library's own `DT_SONAME`, plus EGL and Vulkan ICD files. Select it per-process with
`LD_LIBRARY_PATH`, `__EGL_VENDOR_LIBRARY_FILENAMES` and `VK_DRIVER_FILES`.

---

## Part 13: troubleshooting

| symptom | likely cause | what to do |
|---|---|---|
| `profiles: 0` after bringup | `nvidia-vgpu-mgr` not running, or the spoof is not loaded | `systemctl status nvidia-vgpu-mgr`; check `journalctl -u nvidia-vgpud -b \| grep -i devid` for the spoofed id |
| `insmod: Unknown symbol in module` | `mdev`/`vfio`/`vfio_pci_core`/`irqbypass` not loaded | `modprobe -a mdev vfio vfio_pci_core irqbypass` |
| `init_device_instance ... error 7` | no PCI reset after a by-hand reload | run `hardreset.sh`, then `bringup.sh` |
| `error getting device from group N` | a QEMU was SIGKILLed; the group is wedged | `hardreset.sh` — unloading the vfio core is what fixes it |
| `Immediate pteblit ... timed out`, hundreds of them | **wrong kernel** | go back to Part 2 |
| guest shows Code 43 | the registry keys are missing or in the wrong subkey | Part 9; check it is subkey `0001` |
| guest boots, GPU present, nothing renders, no errors | the kprobe is not active | `lsmod \| grep zfmulti`; if a module reload happened, the probe may be `[GONE]` and needs reloading |
| `cuCtxCreate` returns 801 | wrong profile type | use a `Q` profile, not `A` |
| PTX fails to load with error 218 | `.version` too low for `sm_86` | use PTX ISA 7.1 or later |
| `rmmod nvidia` says "in use" | `nvidia_uvm` or an open `/dev/nvidia*` fd, or `nvidia_modeset` | unload `nvidia_uvm` first; if it is `nvidia_modeset`, reboot |
| host `nvidia-smi` says `Virtualization Mode: None` | expected, it is unreliable here | ignore it; check `/sys/bus/mdev/devices/` |
| guest works, then stops after an upgrade | kernel moved | pin the kernel, Part 2 |

### When you are genuinely stuck

The read-only diagnostic modules in `kmod/` are what was used to debug this: `fifopeek` dumps the
FIFO runlist and channel RAM through BAR0 using PRI reads only, `barscan` probes whether BARs are
backed or returning poison, `bar1walk` walks the GP100-style page tables, `userdpeek` resolves
virtual to physical and shows PTE cache bits. They all deliberately return `-EINVAL` from init so
they never stay loaded.

Read [../notes/WHAT-DIDNT-WORK.md](../notes/WHAT-DIDNT-WORK.md) before starting any deep
investigation. Roughly 80 approaches were measured and most failed; several confident "root cause"
conclusions in that list were wrong and had to be retracted. It will save you from repeating them.
