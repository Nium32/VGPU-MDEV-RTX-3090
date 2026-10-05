# References and credits

No code from any of these projects is vendored in this repository. This is a record of what was
actually used or consulted, so the prior work is credited and so anyone reproducing this knows
what else they need.

## The unlock itself

**vgpu_unlock** — DualCoder
<https://github.com/DualCoder/vgpu_unlock>

The original technique: intercept the NVIDIA vGPU userspace daemons and rewrite the PCI device id
they see, so a consumer card presents as one the driver will serve vGPU profiles for. Everything in
this repository stands on that idea. The approach of leaving the kernel module untouched and
spoofing only in userspace comes from here.

**vgpu_unlock-rs** — mbilker
<https://github.com/mbilker/vgpu_unlock-rs>

The Rust reimplementation, and the one actually used. `libvgpu_unlock_rs.so` is `LD_PRELOAD`ed into
`nvidia-vgpud` and `nvidia-vgpu-mgr` and nowhere else. On this host it lives at
`/opt/nvidia-vgpu-535/vgpu-unlock/`. This is what makes the GA102 present as an RTX A5000
(`10de:2204` → `10de:2231`) to the daemons while `nvidia.ko` continues to see the real id.

**vGPU-Unlock-Patcher** — VGPU-Community-Drivers
<https://github.com/VGPU-Community-Drivers/vGPU-Unlock-Patcher>

Used with the `general-merge` target to build the driver this runs on. The result is
`merged-535.309.01`: the vgpu-kvm RM core with the consumer userland merged in. Worth being precise
about what it does, because it was repeatedly mistaken for more than it is — it patches device-id
gating, profile tables, licensing and branding. It does not touch scheduling, and it does not touch
display. `general-merge` deliberately restores the vgpu-kvm `nv-kernel.o_binary`, which is why the
missing display engine cannot be merged around.

On the build used here, `vup_` appears zero times in `nv-kernel.o_binary` and `vgpuConfig.xml` is
byte-identical to its backup, so the RM core really is unpatched.

## Reverse engineering

**NVIDIA open GPU kernel modules**
<https://github.com/NVIDIA/open-gpu-kernel-modules>

Used as a reference to make sense of the closed host blob. The shipped `nv-kernel.o_binary` has its
function names anonymised to `_nvNNNNNNrm`, but the open RM source has the real names and
structures. Cross-referencing log strings and call patterns against the open source is how symbols
like `channelCommitPdb_GK104`, `kgrobjConstruct`, `dmaMapBuffer_GM107` and `gpuStateLoad_IMPL` were
recovered. The guest Windows driver also retains `NV_PRINTF` format strings, which gave a second
cross-reference path.

Without this, finding the interrupt handler in Part 5 of the tutorial would not have been
practical.

**Ghidra** — NSA / Ghidra contributors
<https://github.com/NationalSecurityAgency/ghidra>

Disassembly and decompilation of `nv-kernel.o_binary` and of the Windows `nvlddmkm.sys`.

**Debugging Tools for Windows (`kd.exe`)** — Microsoft

Kernel debugging inside the Windows guest while chasing the Code 43 failure. One warning worth
passing on, learned the hard way: launching the portable `kd.exe` unattended with console input
active leaked Windows nonpaged pool at hundreds of MB per second under pool tag `Irp `. Always pass
`-noio` for non-interactive use and supply commands with `-c`.

## Build and runtime dependencies

| what | used for |
|---|---|
| **QEMU** / KVM | running the guests; `vfio-pci` with `sysfsdev=` attaches the mdev |
| **EDK2 / OVMF** | UEFI firmware for the guests. Must be the 4 MB variant to match the 4 MB `OVMF_VARS.fd`. |
| **qemu-nbd** + **ntfs-3g** / `ntfsfix` | mounting the guest's qcow2 offline to read results back and edit the registry without booting it |
| **chntpw** / `reged` | offline Windows registry editing, for setting the guest keys before first boot |
| **osslsigncode** 2.8 | test-signing patched `nvlddmkm.sys` builds so Windows would load them |
| **7-Zip** | unpacking the NVIDIA driver installers |
| **socat** | talking to the QEMU monitor socket for clean shutdown and `sendkey` |
| **zstd** | compressing the archived evidence trees |
| **x11vnc**, **Xorg** `dummy` driver, **KDE Plasma** | a host desktop on a machine whose only GPU has no display engine |
| **Arch Linux package archive** | source of the pinned `linux-lts 6.1.71-1`, which is no longer in the live repositories |

## Workload used for validation

**Ollama** and **Gemma 2 (9B)**
<https://ollama.com>

Used as a realistic load rather than a synthetic benchmark. One guest held the model at about
6.26 GB resident and produced roughly 80 tok/s; two guests running it concurrently on the one card
reached about 83 tok/s aggregate, time-sliced, with no Xid. That was the test that showed the
configuration was usable and not merely passing a self-test.

## Consulted and found not to apply

Recorded because checking these took time and the conclusions are useful negatives.

Published consumer-vGPU writeups circulating under the `kkk.rs` name were reviewed. They disclose
license and branding patches only — gates that were already cleared here — and nothing about
scheduling, which was the actual blocker in this project.

A separate Blackwell-focused consumer vGPU effort was reviewed and independently established that
consumer virtual-function PRIV registers are fused off on that generation. Useful for scoping, not
applicable to GA102. The project name was not recorded in the notes, so it is not cited here rather
than cited wrongly.

The conclusion of that survey: **no published implementation of this exists.** The runlist-disable
leak described in the tutorial does not appear in any public write-up found, which is why this
repository documents it in full.

## Not redistributed here

The NVIDIA vGPU host driver, the GRID guest driver, their installers, `vgpuConfig.xml`, and any
license file. Those come from NVIDIA's licensing portal and are not public downloads. This
repository contains only scripts, original kernel modules, and documentation.

The diagnostic modules under `kmod/` and the operating scripts under `scripts/` are original to
this project.
