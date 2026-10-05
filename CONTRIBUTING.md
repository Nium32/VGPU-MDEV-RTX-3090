# Contributing

The most valuable thing you can contribute is **a row in
[COMPATIBILITY.md](COMPATIBILITY.md)**, including a failure. A confirmed "this combination does not
work" saves the next person as much time as a success does, and right now most of that table reads
"untried".

## What is most wanted, in order

1. **Kernel 6.6 LTS.** The working/broken boundary sits somewhere between 6.1 and 6.8 and nobody
   has tested anything in that gap. One datapoint there is worth more than everything else on this
   list.
2. **An ISR offset for another driver build.** `kmod/isrfind` automates the attribution; see
   [docs/FINDING-THE-ISR-OFFSET.md](docs/FINDING-THE-ISR-OFFSET.md). This is what makes the project
   usable by anyone the NVIDIA portal hands a version other than 535.309.01.
3. **Another GA102 card.** A 3080 or 3080 Ti should be the closest thing to a free win.
4. **A non-Arch host.** Debian, Proxmox and Fedora put OVMF in different places and some ship a
   2 MB image under a generic name.
5. **Driver 550.** It builds and was never brought up. Status genuinely unknown.

## Ground rules for results

**Verify compute by reading data back.** This is not pedantry. On this project a test once
returned `rc=0` while `memset32` silently did nothing and a readback showed the original pattern —
fences can be forged, so "no errors" proves nothing. A copy test only proves the copy engine; the
copy engine worked here for a long time while graphics never executed. Run a kernel, read the
result, compare every element you care about.

**Report the three counters** for your run, scoped with the mark file:

```bash
MARK=$(cat /var/log/vgpu/<vm>.mark)
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -ci 'Immediate pteblit'
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -c  'error:'
journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager | grep -cE 'XID [0-9]+ detected'
```

**Mark measured versus read.** Say which numbers you observed yourself and which you took from
somewhere else. Several of this project's own "root causes" were confidently wrong and had to be
retracted; `notes/WHAT-DIDNT-WORK.md` has the list. Distinguishing the two is why that list is
trustworthy.

`scripts/preflight.sh` output covers most of what a row needs on its own.

## Code

```bash
make check
```

That runs `bash -n` on every script, fails on an embedded NUL byte, and runs
`shellcheck -S warning` on the supported set. **The supported set must stay at zero findings:**
`lib/common.sh`, `scripts/preflight.sh`, `scripts/bringup.sh`, `scripts/startguest.sh`,
`scripts/hardreset.sh`.

`scripts/as-run/` and the other not-yet-generalised scripts are reported informationally and are
expected to be dirty. They are kept because they are the exact text that produced the measurements;
they hard-code one machine and are not meant for reuse. Please do not "fix" them into something
that no longer matches what ran — generalise a copy instead.

### Things this codebase has been bitten by

Worth knowing before you send a patch:

- Nothing may hard-code a PCI address, an IOMMU group, an `nvidia-NNN` profile id, or a
  distribution-specific path. Discover it at runtime; `lib/common.sh` has the helpers. The IOMMU
  group in particular changes across reboots on the same machine.
- Resolve vGPU profiles by **name**. The numeric id is assigned per driver version and per board.
- Never `SIGKILL` a QEMU holding an mdev — it wedges the IOMMU group, which is the exact state
  `hardreset.sh` exists to undo. TERM, wait, then escalate.
- Never write `remove` to an mdev a live process holds. It blocks in
  `vfio_unregister_group_dev` and the retry is uninterruptible, so `timeout` will not save you.
- "Is the module in `lsmod`" is not a driver-bound check: `nouveau`, `nvidiafb` and `vfio-pci` all
  pass it. Read `/sys/bus/pci/devices/<bdf>/driver`.
- A kprobe does not pin its target module. After an `nvidia.ko` reload the probe is `[GONE]` while
  `lsmod` still lists the probe module, so any "already loaded, skipping" check silently leaves the
  fix inactive.
- Do not redirect a script's whole output to a log before its first `die()`, or refusals go only to
  the log and the operator sees a silent prompt return.
- Never bind a QEMU VNC console to `0.0.0.0`. It is an unauthenticated keyboard, mouse and screen.
- `bash -n` is not enough. It passes a script containing a literal `\n` where a line continuation
  was meant, and it passes a script with an embedded NUL byte. Both have happened here and both
  broke real commands. Run `make check`.

## Kernel modules

Anything in `kmod/` is GPL-2.0, not by preference — they call GPL-only exported symbols such as
`register_kprobe` and must declare `MODULE_LICENSE("GPL")`.

Diagnostic probes should stay read-only and should return `-EINVAL` from `init` so they cannot be
left loaded by accident. If a probe must touch the GPU, say so loudly in its header comment and
explain the recovery path, because some pokes on this hardware have required a physical power
cycle.

Never do arithmetic on `regs->ip` in a kprobe pre-handler. On x86 it is `probe_addr + 1` inside the
handler, and treating it as the function entry has oopsed this host.

## Licence

By contributing you agree your work goes out under the same terms as the rest: GPL-2.0 for
`kmod/`, MIT for scripts, CC-BY-4.0 for documentation. All three require attribution. See
[LICENSE](LICENSE).
