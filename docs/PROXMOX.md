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
