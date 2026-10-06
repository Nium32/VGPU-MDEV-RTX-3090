# What didn't work

The useful half of this project. Roughly 80 distinct approaches were measured; most failed. If you
are attempting something similar, this list is worth more than the configuration that works,
because it is where the time went.

Everything here was measured on the hardware in [HARDWARE-SCOPE.md](../docs/HARDWARE-SCOPE.md).
Nothing below is speculation about what might fail.

## First, what actually became the fix

So the negatives have something to be negative against:

- One kprobe, `zfmulti spec=_nv042311rm+0x28:1`, suppressing an interrupt handler that disabled
  the graphics runlist 572 times with zero re-enables. The comparable balanced path showed 15
  disables against 15 enables. With no kprobe at all, everything hangs.
- Guest registry `RMSetClientRMAllocatedCtxBuffer=0`. Without it the guest promotes its own
  context buffers while the host keeps and initialises its own, FECS switches to an all-zero MAIN
  context, and every run raises `Xid 44 ... Ch 00000008, intr 00000000`.
- Guest registry `RmRcWatchdog=0`. RM's own watchdog channel was the first thing to need GR
  context buffers and took the whole adapter down with it:
  `krcWatchdogInit_IMPL` returned `NV_ERR_INVALID_STATE` on every call. With it set, 0 failures.
  With it at 1, 4 failures and "No devices were found".
- Host RM registry string: `RMSetSriovMode=0` and nothing else. `NVreg_EnableGpuFirmware=0` is
  also set, but that is a separate module parameter, not part of the registry string.
- No `RMInstLoc` at all. The GR context stays in its default location.
- Kernel 6.1.71.

Two real bugs were found and fixed along the way that turned out **not** to be the cause: a
conftest generated against the wrong kernel's headers, so every `#if defined(NV_...)` silently
chose the wrong branch; and a `remap_pfn_range` call inside a `.fault` handler, which trips an
mmap-lock assertion on newer kernels. Both were genuine defects. Neither explained the failure.

## Driver and version axes, all closed

| attempt | result |
|---|---|
| Driver 580.126.08 | architecturally walled. The FIFO HAL is SR-IOV-only, and consumer GA102 has no SR-IOV. |
| The 580 XenServer bundle | cannot build a KVM host at all |
| Driver 550 (vGPU 17.x) | explored, never reached bring-up. Status unknown, not a working configuration. |
| Pre-GSP guest 512.78 (vGPU 14.2) against the 535 host | installs, negotiates cross-branch at vGPU version 0xd0001, still fails |
| Matched pre-GSP pair: 510.73.06 host + 512.78 guest, same branch | still fails. The "version mismatch" hypothesis is dead. |
| Host GSP firmware enabled | cannot boot on this card: `Xid 119 GSP_INIT_DONE` timeout, wedges the GPU, destroys the mdev types |
| A 5.15 kernel on this root filesystem | two independent kernels tried, neither boots. See the filesystem explanation in KERNEL-REQUIREMENTS.md. |
| Profile `nvidia-672` (8A) instead of 8Q | strictly worse: `cuCtxCreate` returns 801 NOT_SUPPORTED and no TSG is ever scheduled |

A Linux guest was also tried against the same host and failed identically
(`RmInitAdapter failed! 0x41:0x40:2639`), which eliminated "it's a Windows-guest problem" as an
axis entirely.

## Guest-side approaches that failed

- **Binary patching the guest driver's VA clamp** from 40-bit to 49-bit. Live-tested, no change.
- **Forcing the main GR context-buffer mapping to succeed.** Also live-tested. VA mapping fails
  systemically, not at one site.
- **Rebinding the guest's PDB-commit slot to the real implementation** instead of a stub. Closed
  three independent ways: binding the real `channelCommitPdb_GK104` produced a byte-identical
  RMCTRL and the same clean failure, because the real code path hits a null-resource exit. The
  guest cannot own the PDB commit; the engine context is host-owned.
- **A 730-key guest registry sweep.** Nothing in it moved the failure.
- **`KmdHeapSizeIncr`** and the whole VRAM-arena-exhaustion hypothesis. The arena was downstream
  of the real blocker, not the blocker.

## Host knob sweeps

The mechanism proof that ended this family of attempts: with the context-buffer key at 0, the
guest never emits `PROMOTE_CTX` at all; with it at 1, it dies at an unimplemented PDB-update stub.
No host-side setting can reach between those two states. After that, sweeping host knobs stopped.

Specific rejects: `RMInstLoc=65536` (breaks mdev creation), `pte_blit_enabled=0` (trades the blit
timeouts for `Guest FB pfn out-of-range`, Xid 43 and a TDR), `vgpu_device_caps` with bit 5 cleared
(Xid 31), PTE-blit buffer sizing keys, and the version-check keys which are simply ignored.

Also ruled out and worth naming because they are the obvious guesses: PAT and write-combining,
`nopat`, transparent huge pages, the QEMU version, `iommu=pt`, and Resizable BAR / BAR1 resize.
A `follow_pfn` backport was disproven by its own instrumentation.

## Low-level pokes

This is where the project spent the most effort for the least result.

- **The entire GR scheduling layer is a proven negative.** `GPFIFO_SCHEDULE size=2 bEnable=1`
  returns `NV_OK` and leaves CHRAM unchanged, because the channel is already enabled natively.
  The migration-restore path makes it worse, not better.
- **Every FIFO poke aimed at waking the pending channel.** None worked.
- **Searching for whoever writes the runlist BLOCK bit.** 16 RM MMIO accessors probed, zero hits
  across a whole session, while the bit demonstrably toggled. The search was exhausted without
  finding the writer.
- **Driving the FECS context-switch handshake before clearing BLOCK.** `BIND_POINTER` and
  `CTRL_CTXSW 0x39` both return OK in about a microsecond for the guest context, and the channel
  still dies. This also proved a set of register writes previously believed load-bearing are not.
- **Five separate attempts to stop an illegal software method reaching the GR engine**, including
  patching libcuda in three confirmed-loaded sites. All no-ops.
- **Acking the illegal-method interrupt instead of performing the method.** Negative.
- **Clearing `ACQUIRE_SWITCH_TSG`.** It is load-bearing; clearing it made things worse.
- **Fence forging.** It satisfied CUDA and returned `rc=0`, which is exactly why it is dangerous:
  a full buffer test showed the copy engine worked while `memset32` and `memset8` both silently
  did nothing, and a readback returned the original pattern. Device memory was never written.
  Fences can be forged. Compute cannot.
- **Hand-mapping the GR context, forcing a golden context image, and every variant of
  `PROMOTE_CTX` entry manipulation.** All negative.
- **`skipfn` and `retzero`**, two earlier interventions, turned out to be not merely vestigial but
  actively harmful: removing them fixed context recycling.

## Things that damaged the machine

Listed because they cost real time and one of them cost a physical power cycle.

| action | consequence |
|---|---|
| `kthread_stop()` on a self-exited kthread | oopsed `rmmod` through a freed `task_struct`. The real cause of two hard-downs, and it was our own bug. |
| Looping the BAR0 PRAMIN window while RM is live | wedged the host. Set the window once per 64 KB, never per entry. |
| A bare write of 0 to `0xc00094` | needed a physical power cycle |
| `pgfix fix=1` | oopsed the host |
| `skipinsn` doing arithmetic on `regs->ip` in a kprobe pre-handler | oopsed the host. `regs->ip` is `probe_addr + 1`. |
| Writing 3 MB to `/dev/fb0` | silently corrupted the running guest. efifb shares BAR1 with the vGPU aperture. |
| Loading `nvidia_modeset` | wedges the display engine; refcount never drops; pins `nvidia.ko`; costs a reboot. Three were spent on this. |

## Claims that were wrong

The most useful section, because a confident wrong conclusion wastes more time than an open
question. These were all stated as findings at some point and later had to be retracted:

- "The illegal method is `0x08f0`." It is `0x023c`. The method field is bits 13:2; a decode error
  produced a phantom. The retraction took three passes.
- "The illegal method is a native blocker." It only appears when the BLOCK bit is forced clear. It
  is an artifact of the workaround. This was retracted, then re-asserted, then retracted again.
- "`SCHED_DISABLE=1` is the hardware idle resting state." It is software-held.
- "GR scheduling is unowned in this configuration." Retired: the plugin does contain a full
  rescheduler in its migration-restore path.
- "The scheduler never reloads the pending guest channel." Withdrawn — wrong runlist stride and
  wrong CHRAM base.
- "`nv-kernel.o` contains no reference to the runlist register base." Over-stated: the address
  occurs 515 times, of which 4 had been sampled.
- "Host CUDA is not available under the vGPU host driver." Wrong. It needs one `insmod` of the
  already-built `nvidia-uvm.ko`, a `mknod`, and the matching userland.
- "Host X and vGPU are mutually exclusive." Wrong; that was a stuck X process holding the device.
- "Code 43 is an architectural wall, not a debugging problem." Wrong, and this one nearly ended
  the project.
- "The kernel version is the differentiator." Retracted twice before finally being confirmed.
- "The host is stuck in SR-IOV mode." Refuted.
- "The `0xbad0ac` poison is guest-generated." Wrong.
- The memdesc flag `0x4` is `LOST_ON_SUSPEND`, not "contiguous".
- libcuda's 719 / `0x2cf` is not a retry code.
- "The fence lands exactly one short" was a real measurement and a real root cause, and was still
  superseded by a deeper one.

There were at least six successive confident "ROOT CAUSE" claims before the actual fix. Several
were measured correctly and were still wrong about what mattered.

## The teardown wedge — eliminated causes

Once any guest has run and been stopped, no guest starts until the NVIDIA kernel modules are
reloaded (`Timed out (6001 ms) trying to sync`, `init_device_instance failed for inst 0 with
error 7 (init frame copy engine)`, `start failed. status: 0x1`). Still unsolved. These were each
tested and ruled out, so nobody has to repeat them:

- **"It is a second concurrent instance."** No. It reproduces with *both* guests stopped and
  nothing holding the GPU. Guests started together after a fresh module load run side by side fine.
- **"A `vgpu` plugin child is leaking."** No. Children exit on guest stop; one parent process
  remains, no orphan, and the mdev is removed.
- **"It is userspace plugin state."** No. `systemctl restart nvidia-vgpu-mgr` does not clear it.
- **"The FIX 1 `zfmulti` kprobe interferes with re-init."** No. Unloading the module does not help.
- **`pte_blit_enabled=0`** — applied correctly through a udev rule, verified in
  `/sys/bus/mdev/devices/<uuid>/nvidia/vgpu_params`, no effect.
- **`frame_copy_engine=0`** — one restart succeeded, then 1 of 4.
- **`fb_scrubbing_enabled=0`** — 0 of 4, worse than leaving it alone, despite the teardown-time
  error `Wait for scrubbing completion failed with error: 0x7` pointing straight at it.
- **`bar1_length=64`** — this one came from a wrong premise. The reasoning was that the card's
  256 MiB BAR1 is consumed whole by the first guest; the override did silence the
  `pte blit resource initialization failed with error 7` messages, but restarts still failed, and
  two guests had been running concurrently on the stock setting both before and after. Reverted.

Two notes on method. The `pte blit` errors are a *symptom* of the wedge, not its cause — chasing
them produced a plausible-looking BAR1 theory that the rig had already disproved. And the only
experiment that actually narrowed anything was stopping every guest and showing the failure still
happened; everything before that was reasoning about concurrency that was never involved.

## One external check

A survey of published work found no implementation of this. The well-known unlock projects
disclose license and branding patches only — gates that were already cleared here — and a
Blackwell-focused project independently established that consumer VF PRIV registers are fused off.
Nothing published covers the scheduling problem that this project had to solve.
