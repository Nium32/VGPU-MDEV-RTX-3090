# Proxmox VE on a working kernel

Proxmox is viable, but not from its own installer. Every current Proxmox ISO ships a kernel that
fails for vGPU on this hardware:

| Proxmox | default kernel | usable here |
|---|---|---|
| 8.2 – 8.4 | 6.8 | **no** — measured at 50 pteblit timeouts and 100 plugin errors |
| 9.0 | 6.14 | no |
| 9.1 | 6.17 | no |
| 9.2 | 7.0 | no |

The route that works is **Debian 12 first, Proxmox on top, Debian's 6.1 kernel kept**.

## What was actually done

Install Debian 12 bookworm normally, then build and verify the vGPU stack on it **before**
touching Proxmox — see [BUILDING-ON-DEBIAN.md](BUILDING-ON-DEBIAN.md). Doing it in that order
means that if something breaks afterwards you know Proxmox caused it, rather than changing three
variables at once.

Then:

```bash
# hostname must resolve to the real address, not 127.0.1.1
echo "192.168.1.4   myhost.localdomain   myhost" >> /etc/hosts

curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
     https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
     > /etc/apt/sources.list.d/pve-install-repo.list
apt update
apt install proxmox-ve postfix open-iscsi chrony
```

Run that **detached** — `setsid nohup ... &` — not in a foreground SSH session. `proxmox-ve` pulls
`ifupdown2`, which can bounce the network mid-install. It did drop the SSH session here, briefly,
on the first boot afterwards. Detaching means a dropped connection cannot leave a half-configured
system.

## `proxmox-ve` installs a 6.8 kernel and you cannot stop it

`proxmox-ve` hard-depends on `proxmox-default-kernel`, so 6.8 is installed whatever you do. That is
fine. What matters is that it never becomes the default boot entry — and by default **it is listed
first**, so an unpinned reboot lands on the broken kernel.

This is a Debian install with its own ESP and ordinary GRUB, so `proxmox-boot-tool` does not apply.
Pin with GRUB's menu ids:

```bash
WANT=6.1.0-53-amd64
SUB=$(grep -oP "gnulinux-advanced-[0-9a-f-]+" /boot/grub/grub.cfg | head -1)
ID=$(grep -oP "gnulinux-$WANT-advanced-[0-9a-f-]+" /boot/grub/grub.cfg | head -1)
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$SUB>$ID\"|" /etc/default/grub
update-grub
```

Do not use a numeric index. The menu order changes whenever a kernel is added or removed, and the
index that meant 6.1 last week can mean 6.8 after the next upgrade.

Verify the pin survived, because `update-grub` runs again when the Proxmox kernel finishes
configuring:

```bash
grep -m1 '^set default=' /boot/grub/grub.cfg    # must name the 6.1 entry id
```

`grub-reboot "<same id>"` sets a one-shot next-boot target as a belt-and-braces first reboot.

## Result

```
pve-manager/8.4.21   running kernel: 6.1.0-53-amd64
pvedaemon, pveproxy, pvestatd   active
web UI               *:8006
nvidia               535.309.01
kprobe               _nv042311rm+0x28
profiles             18, nvidia-664 = RTXA5000-8Q, avail=3
nouveau              0
xid                  0
```

The vGPU stack behaves exactly as it does on plain Debian. Proxmox changes nothing about it.

## Verified under Proxmox

The guest was booted on the Proxmox host and the in-guest test read its result back:

```
==== CUDA test 2026-10-06 04:57:19 user=Test ====
device='NVIDIA RTXA5000-8Q' computeCapability=8.6
COPY-PASS (4 MiB roundtrip verified)
cuLaunchKernel rc=0 grid=4097 block=256
verified 1052 sampled elements
COMPUTE-PASS (every sampled element matches the kernel output)
CUDA-ALL-PASS
```

`pteblit=0`, `errors=0`, `Xid 0` for the whole boot. The result file was checked against a marker
stamped before the trigger, so it is from that run.

## QEMU aborts on teardown and leaks the mdev

Worth knowing because it looks alarming and is not:

```
qemu-system-x86_64: ../util/qemu-thread-posix.c:92:
    qemu_mutex_lock_impl: Assertion `mutex->initialized' failed.
```

Seen on `pve-qemu-kvm 9.2.0-8` after `system_powerdown`. It fires during teardown, **after** the
guest has shut down and flushed - the result file was written and the NTFS filesystem mounted
clean afterwards. The guest is fine.

The consequence is real though: QEMU dies before releasing the mdev, so `available_instances`
drops by one every run and the profile is exhausted after three. Reap orphans before creating a
new one, skipping any still referenced by a live process:

```bash
for m in /sys/bus/mdev/devices/*; do
    u=${m##*/}
    grep -lqs "$u" /proc/[0-9]*/cmdline 2>/dev/null && continue
    timeout 25 sh -c "echo 1 > /sys/bus/mdev/devices/$u/remove"
done
```

`scripts/startguest.sh` already handles this: QEMU runs inside a wrapper subshell that releases
the mdev when QEMU exits, whatever the exit status. A hand-rolled launcher will not.

## Coming up at boot

`host-config/vgpu-bringup.service` runs `bringup.sh` at boot. Without it the modules are not
loaded after a reboot, no mdev types are registered, and starting a guest fails with nothing
obvious to point at.

```bash
sudo mkdir -p /opt/vgpu-scripts
sudo cp -r lib scripts /opt/vgpu-scripts/
sudo cp vgpu.conf /etc/vgpu.conf
sudo cp host-config/vgpu-bringup.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable vgpu-bringup.service
```

Verified across a real reboot: `Result=success`, 18 profiles, `nvidia-664 avail=3`,
`nvidia-vgpu-mgr active`, `nouveau 0`, `xid 0`, with no manual step. It costs about 24 seconds of
boot time and is the largest single item in `systemd-analyze blame` on this host, which is the
price of a PCI reset plus a driver reload.

**Do not give that unit `Before=nvidia-vgpud.service`.** It deadlocks: `bringup.sh` starts
`nvidia-vgpud` itself and waits for it, while `Before=` tells systemd not to start that unit until
`bringup.sh` has exited. The unit hangs at step 2 until `TimeoutStartSec`. This was tried.

## What Proxmox does and does not give you here

It gives you the web UI, the storage and backup layer, and the VM lifecycle tooling.

It does **not** manage the vGPU guest for you. The mdev is created by hand against
`mdev_supported_types` and the guest is launched with a raw QEMU command line, because the vGPU
needs `vfio-pci,sysfsdev=` pointed at a specific mdev UUID and the profile has to be resolved by
name. Proxmox's own `hostpci` mdev support assumes a licensed vGPU deployment and a profile table
it recognises.

Two further caveats on this host:

- **No bridge was created.** `vmbr0` is the normal Proxmox setup, but converting a live interface
  to a bridge over SSH risks locking yourself out. The guest here uses QEMU user-mode networking
  with a forwarded RDP port, which needs no bridge. Add one from the console if you want
  Proxmox-managed VMs with bridged networking.
- **The address is DHCP.** Proxmox prefers static. It has been stable, but a lease change would
  move the web UI.

## Do not install ZFS

Keeping Debian's kernel means there are no ZFS modules built for it. Use LVM or ext4. This is the
real cost of the approach and it is worth knowing before you plan storage.
