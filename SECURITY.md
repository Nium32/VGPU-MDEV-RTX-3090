# Security notes

This is not a hardened product. It is an unsupported GPU virtualisation setup that loads kernel
modules, resets PCI devices and places kprobes at hard-coded offsets inside a proprietary driver.
Read this before exposing any of it to a network.

## Defaults here are loopback, on purpose

An earlier version of `startguest.sh` launched every guest with `-vnc 0.0.0.0:2` and no password.
That is an unauthenticated keyboard, mouse and screen for the guest, reachable from every interface
on TCP 5902. Anyone who could reach the host had the guest's console.

It now binds loopback, and so does the forwarded RDP port:

```
QEMU_VNC_BIND=127.0.0.1
RDP_BIND=127.0.0.1
```

Reach them over an SSH tunnel rather than changing those:

```bash
ssh -L 5902:127.0.0.1:5902 user@host     # QEMU console
ssh -L 3390:127.0.0.1:3390 user@host     # guest RDP
```

If you do set either to `0.0.0.0`, understand that the QEMU VNC console has **no authentication at
all** unless you add it explicitly. RDP at least authenticates against Windows.

`scripts/hostdesk.sh` starts `x11vnc`. It requires a password file (`~/.vnc/passwd`) and will not
run without one; an earlier version passed `-nopw`.

## What is deliberately not in this repository

- No NVIDIA driver, installer, `vgpuConfig.xml` or licence file.
- **No signing keys.** The project used a test-signing CA to load patched guest drivers. That key
  material is excluded by pattern in `.gitignore` (`*.key`, `*.pem`, `*.pfx`, `*.cer`,
  `testsign-*/`) and its absence was verified across every blob in the history, not just the
  working tree.
- No machine-specific values. CI rejects IP addresses and filesystem UUIDs in the tracked files.

If you fork this and add your own `vgpu.conf`, note it is gitignored for the same reason — it
contains your PCI address, mount paths and port numbers.

## Guest isolation is NVIDIA's, not ours

A vGPU guest is isolated from the host and from other guests by the vGPU stack itself. Nothing in
this repository strengthens that, and two things are worth knowing:

- The device-ID spoof makes the driver serve profiles it otherwise refuses. It does not alter the
  isolation mechanism, but you are running the stack in a configuration the vendor does not test.
- One kprobe suppresses a branch inside the RM interrupt handler. It was chosen because that
  branch leaks a scheduling disable, and the effect was measured — but it is a modification to
  interrupt handling in a proprietary driver, and the full consequences are not knowable from
  outside.

Do not treat a guest here as a security boundary you would bet on. For untrusted workloads, use
hardware the vendor supports for it.

## Things that can take the machine down

Not vulnerabilities, but operational hazards with real consequences. The full list is Part 11 of
[docs/TUTORIAL.md](docs/TUTORIAL.md). The ones that cost the most here:

- Loading `nvidia_modeset` wedges the display engine; its refcount never drops, it pins
  `nvidia.ko`, and only a reboot clears it.
- Writing to `/dev/fb0` corrupted a running guest, because the EFI framebuffer shares BAR1 with the
  vGPU aperture.
- Looping the BAR0 PRAMIN window while RM is live wedged the host hard enough to need a physical
  power cycle.
- `SIGKILL` on a QEMU holding an mdev wedges the IOMMU group until the vfio core modules are
  unloaded.

## Reporting something

Open an issue **with a reproduction**. If it is a real vulnerability rather than an operational
hazard, say so in the title and leave the exploit details out until it is triaged.

Note that this project does not answer questions - see the No support section of the README. A
security report with concrete steps will be read. A question will not be answered.

Please do not report the following as vulnerabilities — they are documented, intentional, and
explained above or in the tutorial:

- that the project circumvents a device-ID check (that is what it is)
- that `scripts/as-run/` contains machine-specific scripts with known defects (they are provenance;
  see `scripts/as-run/README.md` and `DANGER-run-key0.md`)
- that the kprobe modifies proprietary driver behaviour
