# vGPU on a GeForce RTX 3090

NVIDIA's vGPU stack, running on a consumer RTX 3090 through the legacy mdev path, with guests
that do real work: CUDA, compiled PTX kernels, OpenGL, NVENC. The host keeps the card at the
same time and can run its own CUDA.

**Start here: [docs/TUTORIAL.md](docs/TUTORIAL.md)** - the full walkthrough, bare machine to a
working guest, with the reasoning and the failure mode at each step.

**Read [docs/HARDWARE-SCOPE.md](docs/HARDWARE-SCOPE.md) before you start.** This is proven on
exactly one GPU — a GA102 RTX 3090 — and on exactly two kernels. It is not a general recipe and
it will not work unmodified on your card.

## Status

What has been verified by reading data back, not by the absence of errors:

| | result |
|---|---|
| Guest CUDA | `cuInit` 0, device reports `NVIDIA RTXA5000-8Q`, compute capability 8.6, CUDA 12.2 |
| Guest compute | compiled PTX kernels run; a 4M-element fill verified element by element |
| Guest copy | 4 MiB round trip verified; ~11.1 GiB/s host-to-device, ~10.0 GiB/s back |
| Guest graphics | headless EGL/GLES renders and reads back correct pixels, all 6 FBO formats complete |
| Host CUDA | runs concurrently with a guest on the same card |
| Two guests | both held a slice and ran a 9B-parameter model, ~83 tok/s aggregate, time-sliced |
| Stability | 34609 iterations over 300 s with 0 failures; 200-iteration soak clean; no Xid |

The throughput and endurance figures above come from the project's own logs and were not re-run
when this repository was assembled. The configuration facts in
[docs/KERNEL-REQUIREMENTS.md](docs/KERNEL-REQUIREMENTS.md) were measured directly off the
running machine and are marked where they were not.

## The short version

- Driver **535.309.01**, a merged vgpu-kvm build. The RM core is unpatched.
- Kernel **6.1.71**. Not 6.8, not 6.18. This is the part people get wrong; see below.
- `RMSetSriovMode=0`, because consumer Ampere has no SR-IOV and legacy mdev is the only path.
- The device-ID spoof is userspace only. `nvidia.ko` always sees the real `10de:2204`.
- One kprobe is mandatory. Without it the guest's graphics channel is scheduled once and then
  never again, with no error logged anywhere.

## The kernel is not negotiable

Same driver, same configuration, same machine. Only the kernel changed:

| kernel | outcome |
|---|---|
| 5.15.95 | works (recorded on a separate install; not re-measured, and see the note below) |
| **6.1.71** | works — this is what runs |
| 6.8.9 | fails: `Immediate pteblit ... timed out`, 50 timeouts, 100 plugin errors |
| 6.18.52 | fails the same way, worse: roughly 76 timeouts and 152 errors |

Nothing between 6.1 and 6.8 was tested, so the real boundary is somewhere in that gap and this
project does not know where. The failure is quiet and slow: the stack loads, the mdev appears,
the guest boots to a desktop, and then the framebuffer blit times out thousands of times. If you
are on an untested kernel you will not get an obvious error, you will get something that looks
almost right.

`scripts/preflight.sh` warns when the running kernel is not on the known-good list. Full detail,
including what was ruled out as the cause, is in [docs/KERNEL-REQUIREMENTS.md](docs/KERNEL-REQUIREMENTS.md).

## Layout

```
docs/TUTORIAL.md        the full walkthrough - read this first
vgpu.conf.example      every tunable, with defaults and auto-detection
lib/common.sh          config loading, hardware discovery, sanity checks
scripts/preflight.sh   report what this machine looks like; changes nothing
scripts/bringup.sh     load the stack in the order that works
scripts/startguest.sh  create an mdev and boot a guest on it
scripts/hardreset.sh   full teardown, including the vfio core
scripts/as-run/        the original machine-specific versions, kept for provenance
kmod/zfmulti/          required: suppresses the leaked runlist disable
kmod/mdguest/          loaded by the working setup; measurably inert on this build
kmod/*                 read-only diagnostic probes used during the investigation
notes/                 what was tried and what failed
```

Start with `preflight.sh`. It discovers the GPU, its IOMMU group, the module set for your
kernel, your OVMF path and the profiles your card offers, then tells you what is missing. It
touches nothing.

## What this does not do

**No monitor output.** The vgpu-kvm RM core registers zero KMS connectors, so neither the host
nor a guest can drive a display from this card. Measured: `/sys/class/drm` contains nothing but
`version`, and `/dev/dri` does not exist. If you want a screen, put a second GPU in the machine.
Guests are reached over RDP, or by streaming.

**No VRAM overcommit.** Profiles carve the 24 GB into fixed slices. The 8Q profile used here is
8192 MB with a maximum of 3 concurrent instances.

**No licensing bypass.** Unlocking the device gating is a separate thing from vGPU licensing.
Guests still want a license or they degrade after a grace period.

**Not a supported configuration.** Every driver and kernel update can break it, and the kprobe
is tied to one driver build. Expect to re-derive things.

## Credit

This builds directly on prior work: the unlock technique from **vgpu_unlock** (DualCoder), the
**vgpu_unlock-rs** library (mbilker) that actually runs here, and the **vGPU-Unlock-Patcher**
(VGPU-Community-Drivers) `general-merge` target that produced the driver. NVIDIA's **open GPU
kernel modules** source was the reference that made the closed host blob readable.

Full list, including the tooling and what was consulted and rejected:
[REFERENCES.md](REFERENCES.md).

No NVIDIA code, driver installer or license is redistributed in this repository.
