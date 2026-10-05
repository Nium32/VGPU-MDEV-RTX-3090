# Finding the ISR offset for your driver build

This is the one step that is not configuration. If you are on driver 535.309.01 the answer is
already known and you can skip the whole document:

```
ZFMULTI_SPEC=_nv042311rm+0x28:1
```

On any other driver build that string is almost certainly wrong, and nothing will tell you so —
the stack comes up, the guest boots, and its graphics channel runs once and then stops forever
with no error anywhere.

The good news: most of the work is mechanical, and `kmod/isrfind` does it for you.

## What you are looking for

Somewhere in the RM interrupt handling path there is a call that disables the GPU's graphics
runlist and never re-enables it. On 535.309.01, counting calls by call site over about 70 seconds
with a guest hung:

```
site _nv042311rm+0x77    disables=572   enables=0      <-- one-way
site _nv023182rm+0xad    disables=15    enables=15     <-- correctly paired
site _nv023182rm+0x192   disables=15    enables=15     <-- correctly paired
                         ---------------------------
total                    disables=587   enables=15     LEAK=572
```

You want the one-way site. The fix is a kprobe that forces the branch guarding that call so the
disable never happens.

## Step 1: find the writer function

The writer is the function that actually pokes the scheduling-disable register. You need its
symbol name before `isrfind` can watch it.

On 535.309.01 it is `_nv023170rm`, reached through a `KernelFifo` HAL slot. On your build the name
will differ, because NVIDIA anonymises these symbols and the numbering is not stable.

Two ways to find it:

**From the binary.** Look for the runlist register base in `nv-kernel.o_binary` and work out which
function writes the scheduling-disable field. Mapping the anonymised names is much easier if you
cross-reference against NVIDIA's open-source RM, which has the real names and the same structure —
see [../REFERENCES.md](../REFERENCES.md). The guest Windows driver is also useful here because it
retains `NV_PRINTF` format strings you can match back to function names.

**From the symbol table.** List the module's symbols and look for the FIFO/runlist cluster:

```bash
sudo grep -w nvidia /proc/kallsyms | awk '$2=="t" {print $3}' | sort > /tmp/nvsyms
```

Note two things about `/proc/kallsyms`: module symbol lines end with a tab and `[nvidia]`, so an
end-anchored grep like `grep ' _nv023170rm$'` never matches; and the address column reads all
zeroes unless `/proc/sys/kernel/kptr_restrict` is `0`.

## Step 2: let isrfind do the attribution

This is the tedious part and it is fully automated. Build it:

```bash
make -C kmod/isrfind
```

Load it on your candidate writer. `argn` says which integer argument carries the enable/disable
flag, in SysV AMD64 order — 1 is `rdi`, 2 `rsi`, 3 `rdx`, 4 `rcx`, 5 `r8`, 6 `r9`:

```bash
sudo insmod kmod/isrfind/isrfind.ko sym=_nv023170rm argn=3
```

If you do not yet know which argument holds the flag, use `argn=0`. You then only get call counts,
but that is still enough to see which site is hot.

Now reproduce the failure: bring the stack up, start a guest, and let it sit in the hung state for
a minute or so. Then:

```bash
sudo rmmod isrfind
sudo dmesg | grep isrfind
```

You get one line per distinct call site, with `calls`, `disables`, `enables` and a `leak` column,
and the one-way site is flagged explicitly:

```
isrfind: site _nv042311rm+0x77 [nvidia]  calls=572 disables=572 enables=0 leak=+572   <-- ONE WAY, this is your site
isrfind: site _nv023182rm+0xad [nvidia]  calls=15  disables=15  enables=15 leak=+0
```

`%pS` resolves the raw return address to `symbol+offset [module]` for you, so you do not have to
subtract the module base by hand.

If the flag sense is backwards for your writer — a zero meaning "disable" — add `invert=1`.

`isrfind` is read-only. It never modifies registers, never changes control flow, and reads the
return address with `copy_from_kernel_nofault` so a bad stack cannot panic the machine.

## Step 3: disassemble just that function

You now have a symbol and an offset, which is a few instructions instead of a 48000-function blob.
Disassemble the containing function and find the conditional that decides whether the disable
happens. On 535.309.01 `_nv042311rm` is the handler for interrupt event type `0xe`, at `.text`
offset `0x7eeb10`, total size `0xcd` — under 210 bytes. The deciding branch was a single
`test`/`jne` pair on a flag at `pGpu+0x44ec & 0x10`, sitting at `+0x28`.

## Step 4: write the spec

`zfmulti` takes `symbol+offset:value`. The offset is the instruction whose flags you want forced,
and the value is what to force the zero flag to:

```
ZFMULTI_SPEC=_nv042311rm+0x28:1
```

Put that in `vgpu.conf` and re-run `bringup.sh`.

**Probe the test, not the predicate.** Force the flags at the comparison; do not try to patch the
condition itself or rewrite the branch. Forcing the flags is reversible, leaves the code intact and
survives a module reload. Patching bytes does not.

## Step 5: confirm the leak is gone

Re-run `isrfind` on the same writer with the kprobe active. The one-way site should drop to zero
disables. On 535.309.01 with the fix in place the leak goes to 0, `SCHED_DISABLE` stays 0, and the
guest's graphics channel runs its queued work without any further intervention.

If the leak is gone but the guest still does nothing, the offset is right and something else is
wrong — read [../notes/WHAT-DIDNT-WORK.md](../notes/WHAT-DIDNT-WORK.md) before starting a new
investigation, because roughly 80 approaches were already measured and most of them failed.

## Two warnings

**A kprobe does not pin its target module.** When `nvidia.ko` is unloaded the module-going notifier
kills the probe. After a reload the probe shows as `[GONE]` in
`/sys/kernel/debug/kprobes/list` while `lsmod` still lists `zfmulti`. So "is zfmulti loaded" is not
a valid check that the fix is active — re-run `bringup.sh` after any driver reload.

**Never do arithmetic on `regs->ip` in a kprobe pre-handler.** On x86 it is `probe_addr + 1` inside
the handler, and treating it as the function entry address has oopsed this host.

## If you find a working offset for another build

Please add it to [../COMPATIBILITY.md](../COMPATIBILITY.md) and open a pull request. The offset
table is the single most useful thing this repository could grow, and it can only come from people
running other hardware and other driver versions.
