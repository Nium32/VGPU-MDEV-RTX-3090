# Kernel and version requirements

This is the part that decides whether anything works. Get it wrong and the stack still loads,
the guest still boots, and nothing useful happens.

## The matrix

Identical driver, identical host configuration, identical hardware. Only the kernel differs.

| kernel | BAR1 with a guest attached | pteblit timeouts | plugin errors | verdict |
|---|---|---|---|---|
| 5.15.95-051595-generic | real | 0 | 0 | works |
| **6.1.71-1-lts** | **real** | **0** | **0** | **works — this is the one** |
| **6.1.0-53-amd64** (Debian 12) | **real** | **0** | **0** | **works** — stack comes up identically, 18 RTXA5000 profiles, `avail=3`, Xid 0 |
| 6.8.9-arch1-2 | poison | 50 | 100 | fails |
| 6.18.52-1-cachyos-lts | poison | ~76 | ~152 | fails |

The 6.18 figures are approximate; the project's notes record them with tildes and the only
precise related datapoint is 86 timeouts at t=230 s against a control of 76. Do not treat them as
exact. The 6.8 numbers are exact.

Rows 1, 3 and 4 were not re-run when this repository was written. Row 2 is the running system and
was measured directly: over a 35-minute window with a guest active, `nvidia-vgpu-mgr` logged 78
lines, every one `status=0x0`, with zero `error:` lines, zero `Immediate pteblit`, and
`dmesg | grep -ci xid` = 0 across the whole boot.

### The gap nobody has measured

Working: 6.1.71. Broken: 6.8.9. **Nothing in between was tested.** The boundary could be
anywhere in 6.2 through 6.7. If you test one, that is genuinely new information.

An earlier guess blamed the vfio pin-page API rework at 6.0. That guess was wrong — 6.1 works —
and reading the 550 driver's handling of that API did not show a defect. The mechanism behind the
6.1-to-6.8 regression is **not identified**. All that is established is the boundary's existence.

### Why 5.15 is not a usable fallback here

It worked on a separate Ubuntu install on this same machine, so the row is real. But on this host
it cannot be used, for a filesystem reason rather than a GPU one:

- the btrfs root has `compat_ro_flags 0xb`, which includes `BLOCK_GROUP_TREE`, requiring kernel
  **≥ 6.1** to mount
- the old vfio pin API that 5.15 provides requires kernel **≤ 5.19**

The intersection is empty. 6.1.71 is therefore both the oldest kernel that can mount the root and
a kernel on which vGPU works, which is the only reason this configuration exists at all.

## Exact versions of everything

Measured on the running host unless marked otherwise.

### Host

```
kernel            6.1.71-1-lts  (#1 SMP PREEMPT_DYNAMIC Fri, 05 Jan 2024 15:35:19 +0000)
kernel package    linux-lts 6.1.71-1, linux-lts-headers 6.1.71-1  (from the Arch archive)
distribution      CachyOS (ID_LIKE=arch), rolling
driver            535.309.01, merged vgpu-kvm build
NVRM banner       NVIDIA UNIX x86_64 Kernel Module  535.309.01  Wed Mar 25 15:26:15 UTC 2026
nvidia.ko         vermagic 6.1.71-1-lts SMP preempt mod_unload
                  srcversion 6C34B1F19B8B598FD83E964
qemu              11.1.1
build toolchain   gcc 16.2.1 20260810
```

Do not identify the build toolchain from `/proc/driver/nvidia/version`. On this build that file
claims `gcc version 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)`, which is baked into the vendor blob
and has nothing to do with the compiler that built the running module.

Also note `/sys/module/nvidia/parameters/` **does not exist** on this driver build, even as root.
The only readable source of live RM settings is `/proc/driver/nvidia/params`.

### Guest

Read from the project's notes and setup scripts; the running guest was not logged into.

```
driver            539.72 (GRID, DCH)
installer         539.72_grid_win10_win11_server2019_server2022_dch_64bit_international.exe
CUDA              12.2, driverVersion 12020, compute capability 8.6
nvidia-smi        NVIDIA-SMI 539.72 / CUDA Version 12.2
handshake         vGPU version 0x120001
```

### Profile

```
nvidia-664  =  NVIDIA RTXA5000-8Q
framebuffer    8192 MB
num_heads      4
frl_config     60
max_resolution 7680x4320
max_instance   3
```

`available_instances` drops by one per running guest, so a live reading of 2 means one guest holds
a slice. Use `max_instance` as the profile fact.

**Do not hard-code `nvidia-664`.** The numeric id is assigned per driver version and per board.
Resolve the profile by its name, `RTXA5000-8Q`, which is what `lib/common.sh` does.

For Debian and Ubuntu hosts there are two extra traps - split kernel headers and the
`vgpu_unlock` board mapping. See [BUILDING-ON-DEBIAN.md](BUILDING-ON-DEBIAN.md).

## Host module parameters

Both of these are set, and earlier documentation in this project claimed only the first:

```
NVreg_RegistryDwords=RMSetSriovMode=0
NVreg_EnableGpuFirmware=0
```

`RMSetSriovMode=0` selects the legacy mdev path. Consumer Ampere has no SR-IOV, so this is not a
preference.

`NVreg_EnableGpuFirmware=0` is passed twice over: once on the `insmod` line and again
independently on the kernel command line as `nvidia.NVreg_EnableGpuFirmware=0`.
`/proc/driver/nvidia/params` confirms `EnableGpuFirmware: 0`. GSP cannot boot on this card —
attempts produce `Xid 119 GSP_INIT_DONE` timeout, wedge the GPU and destroy the mdev types — so
the monolithic path is the only working one.

## Guest registry

The script that writes these sets **two** dwords into every NVIDIA class subkey, not one:

```
RMSetClientRMAllocatedCtxBuffer = 0
RmRcWatchdog                    = 0
```

Which of the two the running guest actually has could not be confirmed: the disk image is held
read-write by the running QEMU and the hive cannot be read. Treat "only one key is needed" as
unverified. The key lives under
`SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001` — subkey
`0001`, not `0000`.

## The one required intervention

```
insmod zfmulti.ko spec=_nv042311rm+0x28:1
```

A kprobe that forces the zero flag at one branch inside the RM interrupt handler. That handler
otherwise disables the graphics runlist and never re-enables it — measured at 572 disables against
zero re-enables, while the comparable balanced path showed 15 against 15. With the kprobe the leak
goes to zero, `SCHED_DISABLE` stays 0, and the guest's graphics channel runs all its work natively.

A control test with no kprobe at all: everything hangs. This is the single necessary intervention.

### This is not a claim that NVIDIA's driver is buggy

Worth stating plainly, because it would be easy to read it that way and the evidence does not
support it.

The branch at `+0x28` tests a flag (`pGpu+0x44ec & 0x10`) and parks the runlist when it is not set.
That is the handler doing exactly what it was written to do. On hardware NVIDIA actually supports
for vGPU, that condition presumably resolves the other way and the disable is either never taken or
properly paired — this card is not such hardware, and nothing here establishes otherwise.

So what was measured is an **unpaired disable in a configuration the vendor does not support**, not
a defect. The kprobe does not repair anything. It forces one branch so an unsupported card takes
the path a supported one would, which is a different and much smaller claim.

The honest limit of the finding: `_nv042311rm+0x77` issued 572 disables and zero re-enables over
roughly 70 seconds with a hung guest, while `_nv023182rm` was balanced 15/15, and forcing the gate
makes the guest work. Everything beyond that — why the flag is clear, what it means on a supported
card, whether NVIDIA intended this path for unsupported devices — is not known from here.

**The symbol and the offset are specific to one driver build.** NVIDIA anonymises these names, and
both the name and the offset move between versions. Within 535.309.01 alone the same symbol sat at
two different addresses across two kernel builds. There is no evidence either way about whether
`_nv042311rm+0x28` means anything on 550 or 580 — the trees for those on this machine contain no
`nvidia.ko` to check against.

### mdguest is loaded but does nothing

The working setup loads `mdguest apply=1`, and earlier project notes describe it as the PCI-ID
spoofer. Both the description and the necessity look wrong on this build. Live parameters:

```
apply=1  seen=805  matched=0  patched=0  wantsize=1662976
```

It has patched zero memory descriptors this boot. It is probably vestigial here. Removing it was
**not** tested, so the scripts still load it and this document records the measurement rather than
a recommendation.

## Tried and rejected

Do not spend time on these.

| knob | result |
|---|---|
| `RMInstLoc=65536` (USERD→COH) | loads, leaves the mdev unusable |
| `RMInstLoc=131072` (USERD→NCOH) | **untested.** Earlier docs claim it fails; the notes list it as a thing to try. Unverified either way. |
| `pte_blit_enabled=0` | removes the pteblit timeouts, replaces them with `Guest FB pfn out-of-range`, Xid 43 and a TDR |
| `vgpu_device_caps` bit 5 clear | harmful, Xid 31 |
| Resizable BAR | never a factor. The capability exists and BAR1 could be 32 GB; it ran at the stock 256 MB throughout and no part of this project touched it. |
| GSP firmware on the host | cannot boot on this card, wedges the GPU |
| driver 580 | hits the SR-IOV wall on consumer Ampere |
| driver 550 | builds on 6.18, never bring-up tested. Status unknown; not a working configuration. |
| the 8A profile | `cuCtxCreate` returns 801 NOT_SUPPORTED, no TSG ever scheduled. Stay on 8Q. |

## A trap in the module directory

The build command excludes the display modules with
`NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem"`. Despite that,
`nvidia-drm.ko` and `nvidia-modeset.ko` are both present in the 6.1.71 module directory, built an
hour later by a different script.

Loading either one on a vGPU host wedges the display engine. `nvidia_modeset`'s refcount never
drops, which pins `nvidia.ko` and makes the whole stack un-unloadable; the only way out is a
reboot. Three reboots were spent learning this. `lib/common.sh` refuses to continue if either
module is loaded.
