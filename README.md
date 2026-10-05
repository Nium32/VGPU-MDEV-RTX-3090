# vGPU on a GeForce RTX 3090

NVIDIA's vGPU stack, running on a consumer RTX 3090 through the legacy mdev path, with guests
that do real work: CUDA, compiled PTX kernels, OpenGL, NVENC. The host keeps the card at the
same time and can run its own CUDA.

**Start here: [docs/TUTORIAL.md](docs/TUTORIAL.md)** - the full walkthrough, bare machine to a
working guest, with the reasoning and the failure mode at each step. It opens with five questions
that tell you in two minutes whether this can work for you at all.

**Read [docs/HARDWARE-SCOPE.md](docs/HARDWARE-SCOPE.md) before you start.** This is proven on
exactly one GPU — a GA102 RTX 3090 — and on exactly two kernels. It is not a general recipe and
it will not work unmodified on your card.

## Status

**If you cannot find something internet archive is a very good place to search for drivers.**

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
kmod/isrfind/          finds the one-way call site on a driver build you do not have
                       an offset for yet - this is what makes other versions tractable
kmod/*                 read-only diagnostic probes used during the investigation
notes/                 what was tried and what failed
COMPATIBILITY.md       what works, what fails, what nobody has tried - please add rows
CONTRIBUTING.md        what is most wanted, and the traps this codebase hit
Makefile               make modules / make check / make install
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

**Finding the drivers.** Both the host and guest drivers come from NVIDIA's licensing portal and
are not public downloads. If a version has been withdrawn or you cannot reach the portal, the
Internet Archive is a genuinely good place to look - older vGPU and GRID installers are often
mirrored there. Check the version matches what you need exactly, because the kprobe offset is tied
to one driver build.

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

## What has and has not been tested

Be clear about this before trusting the code, because the documentation is better verified than the
scripts are.

**Verified by running it on the hardware:**

- `scripts/preflight.sh` - run against the live host. It correctly discovers the GPU, its real PCI
  id, the IOMMU group, the module set and vermagic, the OVMF path, all 18 profiles and the zero DRM
  connectors, and reports OK.
- The backing-file guard in `lib/common.sh` - run against the real 4-deep qcow2 chain. It permits
  the leaf and refuses all three parents, each naming the overlay that blocks it.
- `kmod/zfmulti`, `kmod/mdguest`, `kmod/isrfind` - all build warning-free against kernel 6.1.71.
- `make modules` and `make check` - run end to end on the host.
- Everything in `scripts/as-run/` - that is the exact text that produced every measurement quoted
  in the documentation.

**Generalised from working scripts but NOT re-tested as a full cycle:**

`scripts/bringup.sh`, `scripts/startguest.sh` and `scripts/hardreset.sh`. They are rewrites of the
as-run versions with the machine-specific values replaced by runtime discovery. The logic and the
ordering match, the discovery layer is tested, and they pass `shellcheck -S warning` - but a full
tear-down-and-bring-up cycle has not been run with them, because doing that means taking down a
working guest.

That matters. Until recently `bringup.sh` carried a two-character escape where a line continuation
was meant, so `systemctl is-active` received an extra argument and the script died on every single
run. `bash -n` accepted it happily; `shellcheck` caught it. CI now rejects that pattern, but assume
there may be another like it and read the script before you run it as root.

If you want the proven-exact path, use `scripts/as-run/` and edit the paths by hand.

## If you got here searching for an error

These are the exact failures this repository explains, with the symptom first. If you are staring
at one of them right now, the linked section is where the answer is.

| what you are seeing | what it means |
|---|---|
| `Immediate pteblit ... timed out`, hundreds of them, from `nvidia-vgpu-mgr` | your kernel. 6.8 and 6.18 fail this way, 6.1.71 does not. [KERNEL-REQUIREMENTS.md](docs/KERNEL-REQUIREMENTS.md) |
| guest shows **Code 43** in Device Manager with a vGPU attached | the two guest registry keys are missing, or are in the wrong class subkey. [Tutorial Part 9](docs/TUTORIAL.md) |
| `Xid 44 ... Ch 00000008, intr 00000000` every run | `RMSetClientRMAllocatedCtxBuffer` is unset, so the guest promotes its own context buffers. [Tutorial Part 9](docs/TUTORIAL.md) |
| guest boots, GPU present, no errors anywhere, and nothing renders | an interrupt handler disabled the graphics runlist and nothing re-enabled it. This is the core finding. [Tutorial Part 5](docs/TUTORIAL.md) |
| `init_device_instance` fails with **error 7** | no PCI function-level reset after a by-hand driver reload |
| `insmod: Unknown symbol in module` on `nvidia-vgpu-vfio.ko` | `mdev`, `vfio`, `vfio_pci_core` or `irqbypass` is not loaded |
| `error getting device from group N ... not already in use` | a `SIGKILL`ed QEMU wedged the IOMMU group; the vfio core modules must come out |
| `cuCtxCreate` returns **801** NOT_SUPPORTED | you are on an `A` profile. Use a `Q` profile. |
| `Xid 119 GSP_INIT_DONE` timeout, mdev types vanish | GSP cannot boot on this card. `NVreg_EnableGpuFirmware=0` |
| `nvidia-smi` says `Virtualization Mode : None` while a guest is running | expected here, and not a useful signal. Check `/sys/bus/mdev/devices/` |
| `krcWatchdogInit_IMPL` returns `NV_ERR_INVALID_STATE` | `RmRcWatchdog=0` is missing in the guest |
| no KMS connectors, `/dev/dri` absent, no monitor output | structural. The vgpu-kvm RM core has no display engine. [HARDWARE-SCOPE.md](docs/HARDWARE-SCOPE.md) |

For the symbol `_nv042311rm` and the offset `+0x28`: that is the interrupt handler branch this
project suppresses, and [FINDING-THE-ISR-OFFSET.md](docs/FINDING-THE-ISR-OFFSET.md) explains how to
locate the equivalent on a driver build other than 535.309.01.

This is a **GeForce RTX 3090** running NVIDIA **vGPU** through the **legacy mdev** path - the same
territory as `vgpu_unlock`, but the problem solved here is scheduling, not device-ID gating. It is
not Proxmox-specific, though Proxmox is the obvious host for it and the kernel caveat above applies
there too.

## No support

I am not answering questions about this. Not in issues, not by email, not in DMs.

That is not hostility, it is capacity. Everything I know is already written down here, in more detail
than I could reproduce in a reply:

- **"How do I set it up?"** - [docs/TUTORIAL.md](docs/TUTORIAL.md), thirteen parts, start to finish.
- **"Will it work on my card / kernel / driver?"** - [docs/HARDWARE-SCOPE.md](docs/HARDWARE-SCOPE.md)
  and [COMPATIBILITY.md](COMPATIBILITY.md). If your combination is not listed, the honest answer is
  that nobody knows.
- **"Where do I get the driver?"** - NVIDIA's licensing portal. I cannot give you a copy and will
  not respond to requests for one.
- **"It does not work / I get error X."** - [the troubleshooting table](docs/TUTORIAL.md) covers the
  failures that were actually hit here. Beyond that, read
  [notes/WHAT-DIDNT-WORK.md](notes/WHAT-DIDNT-WORK.md) before asking anyone anything, because
  roughly 80 approaches were already measured and most of them failed.
- **"Can you add support for ...?"** - no. Use the method, see
  [docs/FINDING-THE-ISR-OFFSET.md](docs/FINDING-THE-ISR-OFFSET.md).
- **"Is this legal / allowed?"** - ask a lawyer, not me.

Issues are open for exactly two things: **a row for [COMPATIBILITY.md](COMPATIBILITY.md)** (including
a failure - those are just as useful) and **a concrete bug with a reproduction**. Pull requests are
welcome and will be read. Questions will be closed unanswered.

If the documentation is wrong or unclear, that is worth a pull request fixing it, which helps more
than an answer to one person would.

## Use it

Free to use, all of it. Scripts, kernel modules, documentation, the measurements, the dead ends.
Your project, your article, your product, commercial or not. Modify it, redistribute it, no
permission needed.

**Credit "Nium"**, with a link back here where that is reasonable. That is the only condition.

Formally: `kmod/` is GPL-2.0-only because Linux kernel modules calling GPL-only exports cannot be
anything else; `scripts/`, `lib/` and `host-config/` are MIT; the documentation is CC-BY-4.0. All
three require attribution, so crediting Nium satisfies all of them. Full text and the reasoning:
[LICENSE](LICENSE).

No warranty, and read that part seriously - this loads kernel modules, resets PCI devices and
places kprobes at hard-coded offsets in a proprietary driver. It wedged a GPU and oopsed the host
more than once during development. See [Part 11 of the tutorial](docs/TUTORIAL.md) first.

## Donations

This took a long time and the result is given away. If it saved you some of that time and you feel
like it, Monero:

```
47BzeT42HzDArmPkUTrCQ2D1VidW4LiwA9L4E3k5ENrZVN7WPTx8yw2NHLcmQY7b9JBEgvvNSWUmqPmmGXdpLe6Y8QKniEs
```

Entirely optional. Nothing here is gated behind it.
