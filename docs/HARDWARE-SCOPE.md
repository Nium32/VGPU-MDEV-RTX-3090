# What this is proven on

One GPU. One card, in one machine, on one driver, on one kernel.

If you came here hoping for a general consumer-vGPU recipe, this is not that. What follows is an
honest account of how narrow the tested envelope is and what you would have to redo yourself.

## The card

```
chip            GA102
board           GeForce RTX 3090
real PCI ID     10de:2204  (rev a1)
subsystem       1458:4043
VBIOS           94.02.42.40.b7
framebuffer     24 GB, BAR1 at the stock 256 MB
```

Presented to the vGPU userspace as:

```
spoofed ID      10de:2231  (GA102GL, NVIDIA RTX A5000)
subsystem       10de:1562
```

The spoof is `LD_PRELOAD`ed into `nvidia-vgpud` and `nvidia-vgpu-mgr` only. **`nvidia.ko` always
sees the real `10de:2204`.** Nothing in the driver is patched: `vgpuConfig.xml` is byte-identical
to its backup, and the string `vup_` appears zero times in `nv-kernel.o_binary`. Any description
of this as a patched driver would be wrong.

## The host it ran on

```
CPU             AMD Ryzen 7 2700, 8 cores / 16 threads
motherboard     ASUSTeK PRIME X370-PRO
BIOS            AMI 6232, 2024-09-29
kernel          6.1.71-1-lts
distribution    CachyOS (arch-like)
qemu            11.1.1
```

Worth saying plainly: this is a six-year-old eight-core CPU on a first-generation Ryzen chipset.
The platform is not the hard part and you do not need anything exotic.

### IOMMU

Active as AMD-Vi `ivhd0`, 23 groups, with **no** `amd_iommu=` or `iommu=` on the kernel command
line. The GPU's group holds only the GPU and its own audio function, so no ACS override patch is
needed either.

The group number is discovered at runtime, never assumed. It was group 15 when this was written
and group 22 earlier in the project's history, on the same machine. Anything that hard-codes it
is wrong.

The only NVIDIA-related kernel parameter is `nvidia.NVreg_EnableGpuFirmware=0`.

### No BIOS tuning was required

Nothing beyond defaults mattered. Resizable BAR in particular was never touched: the capability
is present and BAR1 could be set to 32 GB, but it ran at 256 MB throughout and no part of this
work involved it. Treat ReBAR as untested, not as a requirement and not as a tuning step.

## What is specific to this card

### The kprobe offset

`_nv042311rm+0x28` is the whole intervention, and it is the least portable thing here. The symbol
name is anonymised by NVIDIA and both the name and the offset move between driver versions. Within
driver 535.309.01 alone, that same symbol sat at two different addresses across two kernel builds.

Whether the symbol even exists on 550 or 580 is **unknown** — the driver trees for those versions
on this machine ship no `nvidia.ko` to inspect.

On a different driver build you must locate the handler yourself. That is disassembly work, not
configuration.

### The FIFO and runlist register map

The investigation depended on GA102 specifics: runlist blocks 0x400 apart, the runlist buffer
living in video memory rather than system memory, and a particular CHRAM layout. This is recorded
prior work and was not re-confirmed when this repository was assembled. On another chip generation
these offsets will differ.

### The legacy mdev path itself

Consumer Ampere has no SR-IOV, which forces `RMSetSriovMode=0` and the legacy mediated-device
path. A datacenter card would use a different mechanism entirely and none of this would apply.

### The profile list

`nvidia-664` = `RTXA5000-8Q` exists because the card is being presented as an A5000. Spoof to a
different board and you get a different profile table with different numeric ids. Always resolve
by name.

## What you would have to re-derive on another card

1. **The spoof target.** A board whose vGPU profiles your driver version actually publishes.
2. **The ISR offset.** Find the handler that disables the graphics runlist without re-enabling it,
   for your exact driver build. This is the hard part.
3. **A working kernel.** The 6.1-to-6.8 boundary found here may or may not apply to you. The
   mechanism was never identified, so it cannot be predicted.
4. **The profile id**, if you insist on hard-coding one instead of resolving by name.
5. **Possibly the FIFO register map**, if anything needs debugging at that level.

Items 2 and 5 are reverse engineering, not setup.

## Explicitly not tested

- Any other Ampere card, including the 3080, 3090 Ti and the A-series proper
- Any other GPU generation: Turing, Ada, Blackwell
- Any other motherboard or CPU
- Any other host distribution. It is arch-like here; nothing should depend on that, but nothing
  proves it either.
- SR-IOV capable datacenter cards, which do not need any of this
- Driver 550 on this card: builds, never brought up
- Driver 580 on this card: hits the SR-IOV wall

## The display limitation is structural

The vgpu-kvm RM core registers **no KMS connectors**. Measured with both display modules
unloaded: `/sys/class/drm` contains nothing but `version`, and `/dev/dri` does not exist.

Earlier in the project, with `nvidia_modeset` and `nvidia_drm modeset=1` loaded, a `card0` did
appear — with zero connectors. That result is from the project's notes and was not reproduced
here, because reproducing it needs an `insmod` that is recorded as reboot-forcing.

This was ruled out as a configuration problem by elimination. It is not `RMSetSriovMode=0`, not
the device-ID spoof, not the merged driver build, and not the framebuffer console. There is no
scanout engine to drive. Put a second GPU in the machine if you want a monitor.

Two related hazards, both learned expensively:

- **Never write to `/dev/fb0`.** The EFI framebuffer is mapped inside BAR1 at the same aperture
  the vGPU stack uses. A 3 MB write there silently corrupted a running guest.
- **Never load `nvidia_modeset`** on the vGPU host. Its refcount never drops, it pins `nvidia.ko`,
  and only a reboot clears it.

## nvidia-smi lies here

With a guest running and consuming 8104 MiB, `nvidia-smi` reported:

```
GPU Virtualization Mode
    Virtualization Mode : None
    Host VGPU Mode      : N/A
```

It is not a reliable way to confirm vGPU is working on this setup. Check
`/sys/bus/mdev/devices/` and ask the guest instead.

`nvidia-smi` is also not on `PATH` in this configuration, and `/usr/bin/nvidia-modprobe` is a
zero-byte file. It only runs as a deliberate pairing of the 535 userland with the 535 binary.
