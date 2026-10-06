# Running the guest as a Proxmox-managed VM

[PROXMOX.md](PROXMOX.md) covers getting Proxmox onto a kernel that works. This document covers the
next step: taking the guest that `scripts/startguest.sh` boots from a hand-written QEMU command
line and turning it into a normal Proxmox VM, so it appears in the web UI with Start, Stop, Console
and Clone, and so additional guests are a repeatable procedure instead of a second copy of a shell
script.

Everything below was measured on the reference machine, not reasoned about. The result:

| | |
|---|---|
| Host | Proxmox VE 8.4, kernel `6.5.13-6-pve` |
| GPU | one RTX 3090 (`10de:2204`) spoofed to RTX A5000 (`10de:2231`) |
| Profile | `nvidia-664` = `RTXA5000-8Q`, 8192 MiB per guest, 3 instances |
| Guests | two concurrent Windows 11 Pro VMs, driver `539.72`, `vGPU version 0x120001` |
| Result | `ConfigManagerErrorCode = 0` in both guests, `nvidia-smi` reports `8192 MiB`, host `Xid` count 0 |

The vGPU composites the Windows desktop in both guests: `explorer.exe`, `ShellHost.exe` and
`SearchHost.exe` show up under Processes in `nvidia-smi`.

> The host stack must already be up before any of this matters. `scripts/bringup.sh` loads the
> modules, starts `nvidia-vgpud` / `nvidia-vgpu-mgr` and installs the kprobe described in
> [FINDING-THE-ISR-OFFSET.md](FINDING-THE-ISR-OFFSET.md). Proxmox does not replace any of that; it
> only replaces the part that launches QEMU.

---

## 1. One-time host setup

### Storage

Proxmox refuses to attach a disk by absolute path:

```
unable to associate path '/var/lib/vgpu-vm/win-key0/win-test.qcow2' to any storage
```

Disks have to live inside a registered storage, laid out as `images/<vmid>/`. Register the
filesystem that holds the guest images:

```bash
pvesm add dir vgpussd --path /srv/vgpu/pve --content images,iso,vztmpl,backup
```

Adjust the path to wherever you keep them. From here on disks are referenced as
`vgpussd:<vmid>/<file>`, never as a path.

### A bridge for the guests

Proxmox wants a bridge for guest networking. **Do not enslave the interface you administer the
host over** unless you are physically at the machine — moving the host IP onto a bridge over SSH
will lock you out if anything is mistyped.

An isolated bridge with NAT avoids that entirely and is what was used here:

```bash
# /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o <uplink> -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o <uplink> -j MASQUERADE
```

Guests get outbound access and can reach the host at `10.10.10.1`; nothing on the LAN can reach
them. If you want them on the LAN instead, use a normal bridged setup and accept the usual risk.

Nothing hands out addresses on an isolated bridge, so run a DHCP server bound to that bridge only:

```bash
dnsmasq -d -z -i vmbr0 --bind-interfaces \
  --dhcp-range=10.10.10.50,10.10.10.99,12h \
  --dhcp-option=3,10.10.10.1 --dhcp-option=6,1.1.1.1,8.8.8.8 \
  --dhcp-authoritative
```

`-i vmbr0 --bind-interfaces` matters. Without it dnsmasq also answers on the LAN interface and you
have put a second DHCP server on your network.

---

## 2. Importing an existing guest

The guest disk is a qcow2 overlay on a backing chain. Give the new VM **its own** overlay rather
than handing it the one `startguest.sh` uses, so the two launch paths cannot fight over the same
file:

```bash
VMID=100
install -d /srv/vgpu/pve/images/$VMID

qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/vgpu-vm/win-key0/win-key0.qcow2 \
  /srv/vgpu/pve/images/$VMID/vm-$VMID-disk-0.qcow2

# Reuse the existing EFI vars: they already contain the Windows Boot Manager entry,
# so the VM boots straight into Windows instead of dropping to the EFI shell.
cp /var/lib/vgpu-vm/win-key0/OVMF_VARS.fd \
   /srv/vgpu/pve/images/$VMID/vm-$VMID-disk-1.raw
```

The backing files are opened read-only, so this does not touch the protected parent images.

Then define the VM:

```bash
qm create $VMID --name winguest-vgpu --machine q35 --bios ovmf --ostype win11 \
  --cpu host --cores 8 --sockets 1 --memory 12288 --balloon 0 --localtime 1 \
  --scsihw virtio-scsi-single --net0 e1000e,bridge=vmbr0

qm set $VMID --sata0    vgpussd:$VMID/vm-$VMID-disk-0.qcow2,cache=writeback,discard=on
qm set $VMID --efidisk0 vgpussd:$VMID/vm-$VMID-disk-1.raw,efitype=4m,pre-enrolled-keys=0
qm set $VMID --boot     order=sata0
qm set $VMID --hostpci0 <gpu-bdf>,mdev=nvidia-664,pcie=1
qm set $VMID --smbios1  uuid=$(printf "00000000-0000-0000-0000-%012d" "$VMID")
```

### Why each non-default setting

| Setting | Reason |
|---|---|
| `sata0`, not `scsi0` | The image was installed on `ich9-ahci` + `ide-hd`. Attaching it to virtio-scsi gives `INACCESSIBLE_BOOT_DEVICE`, because the installed Windows has no boot-time virtio-scsi driver. `sata0` on q35 is the same AHCI controller it was built on. |
| `pcie=1` | Without it Proxmox puts the device on the legacy `pci.0` bridge. The hand-written launch lets QEMU place `vfio-pci` on the q35 PCIe root. `pcie=1` gets it onto a real PCIe root port. |
| `balloon 0` | vfio pins all guest memory. A balloon device works against that and buys nothing when the whole guest is pinned anyway. |
| `efitype=4m` | Matches the 4 MB OVMF `CODE` + `VARS` pairing the guest was installed with. |
| `localtime 1` | Matches `-rtc base=localtime` in the working launch; Windows expects the RTC in local time. |
| `smbios1 uuid=` | Makes the VM UUID equal the mdev UUID, as the hand-written launch does with `-uuid "$U"`. Proxmox derives the mdev UUID from the VM ID, so VM 100 gets `…000000000100`. |

Proxmox creates and destroys the mdev itself from the `hostpci0` line. Do not pre-create one.

---

## 3. The Code 43 that appears right after importing

A freshly imported guest boots to the Windows desktop and looks fine, but the GPU is dead:

```
Name                   : NVIDIA RTXA5000-8Q
DriverVersion          : 31.0.15.3972
Status                 : Error
ConfigManagerErrorCode : 43
```

The desktop you are looking at is the emulated `Microsoft Basic Display Adapter`, not the vGPU.

**Cause.** The two tuning values this project needs —

```
RMSetClientRMAllocatedCtxBuffer = 0
RmRcWatchdog                    = 0
```

— live under a **per-device-instance** subkey:

```
HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\NNNN
```

`NNNN` is allocated by Windows per PCI instance path. Moving the card from the slot the
hand-written launch gave it to a Proxmox PCIe root port changes that path, so Windows allocates a
**new** subkey — and the new one has neither value. The old subkeys still have them, which is why
the problem looks mysterious: the keys are plainly present in the registry, just not on the subkey
the live device is bound to.

You can see which subkey is live from inside the guest:

```powershell
Get-PnpDevice -Class Display | ForEach-Object {
  $p = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Driver').Data
  $c = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
  '{0} | {1} | problem={2}' -f $_.FriendlyName, $p, $c
}
```

On the reference machine that printed `problem=43` against subkey `\0006`, while the working values
sat on `\0001` and `\0002`.

**Fix.** [`scripts/pve-fix-nvidia-regkeys.sh`](../scripts/pve-fix-nvidia-regkeys.sh) writes both
values into every existing display-class subkey of a **stopped** guest, offline, via `qemu-nbd` and
`hivexregedit`:

```bash
qm stop $VMID
scripts/pve-fix-nvidia-regkeys.sh /srv/vgpu/pve/images/$VMID/vm-$VMID-disk-0.qcow2
qm start $VMID
```

It needs `libhivex-bin` and `ntfs-3g`. It only touches subkeys that already exist — inventing new
ones confuses `setupapi` — and it aborts rather than continuing if the filesystem comes up
read-only, so a failed edit cannot be mistaken for a successful one.

---

## 4. Adding another VM

Because the subkey is created the first time Windows sees the device at its new address, a brand
new VM needs **one throwaway boot** before the fix can land.

[`scripts/pve-newvm.sh`](../scripts/pve-newvm.sh) does the whole cycle, including that boot and the
wait for Windows to finish coming up:

```bash
scripts/pve-newvm.sh 102                 # create, throwaway boot, fix, start
scripts/pve-newvm.sh -n 102              # dry run: print every command, change nothing
```

It refuses up front rather than halfway through if the VM id is taken, the parent image or EFI
template is unreadable, or the profile has no instances left. Defaults (`GPU_BDF`, `MDEV_TYPE`,
`STORAGE`, `PARENT`, `MEM`, `CORES`) are environment overrides; the GPU is auto-discovered from
`lspci`.

The manual sequence it automates, for reference:

```bash
SRC=100           # the VM you are copying
VMID=101          # the new one
install -d /srv/vgpu/pve/images/$VMID

# 1. Own overlay on the shared read-only parent. Instant, and costs no disk up front.
qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/vgpu-vm/win-key0/win-key0.qcow2 \
  /srv/vgpu/pve/images/$VMID/vm-$VMID-disk-0.qcow2
cp /srv/vgpu/pve/images/$SRC/vm-$SRC-disk-1.raw \
   /srv/vgpu/pve/images/$VMID/vm-$VMID-disk-1.raw

# 2. Same config as section 2, with the new ID in the UUID.
qm create $VMID --name winguest-vgpu-2 --machine q35 --bios ovmf --ostype win11 \
  --cpu host --cores 8 --sockets 1 --memory 12288 --balloon 0 --localtime 1 \
  --scsihw virtio-scsi-single --net0 e1000e,bridge=vmbr0
qm set $VMID --sata0    vgpussd:$VMID/vm-$VMID-disk-0.qcow2,cache=writeback,discard=on
qm set $VMID --efidisk0 vgpussd:$VMID/vm-$VMID-disk-1.raw,efitype=4m,pre-enrolled-keys=0
qm set $VMID --boot     order=sata0
qm set $VMID --hostpci0 <gpu-bdf>,mdev=nvidia-664,pcie=1
qm set $VMID --smbios1  uuid=$(printf "00000000-0000-0000-0000-%012d" "$VMID")

# 3. Throwaway boot so Windows allocates the subkey. Expect Code 43 here.
qm start $VMID
#    wait for the desktop, then:
qm stop $VMID

# 4. Now the subkey exists, so patch it and boot for real.
scripts/pve-fix-nvidia-regkeys.sh /srv/vgpu/pve/images/$VMID/vm-$VMID-disk-0.qcow2
qm start $VMID
```

Verified on the reference machine: after step 4, VM 101 reported `ConfigManagerErrorCode 0` and
`RTXA5000-8Q, 539.72, 8192 MiB`, running at the same time as VM 100, with the host `Xid` count
still 0 and `available_instances` down from 3 to 1.

### Cloning from the web UI

Right-click the VM → **Clone** works, and is genuinely two clicks, with three caveats:

* A full clone flattens the whole backing chain into one standalone image. That is a real
  multi-tens-of-GB copy, where the overlay above is instant. For a linked clone Proxmox requires
  the source to be converted to a template first, and a template can no longer be started.
* The clone inherits `hostpci0`, but **not** a correct UUID. Fix it afterwards:
  `qm set <newid> --smbios1 uuid=$(printf "00000000-0000-0000-0000-%012d" <newid>)`
* The clone still needs the throwaway boot and the registry fix from step 3–4.

### Limits

`available_instances` on `nvidia-664` is **3**, so three concurrent guests on this card. Check
before starting another:

```bash
cat /sys/bus/pci/devices/<gpu-bdf>/mdev_supported_types/nvidia-664/available_instances
```

Starting a fourth fails at mdev creation.

**One profile type per physical GPU.** vGPU does not mix profiles on one card, and the sysfs
numbers show it directly: with two `nvidia-664` (8Q) guests up, every other profile on the card
reads `available_instances = 0`, including the ones that were non-zero before the first guest
started. So the choice of profile is made once, for all guests on that GPU, and the 8Q profile's
three instances are the ceiling. Picking `nvidia-665` (12Q) instead would cap you at two.

`nvidia-672` (`RTXA5000-8A`) also shows instances, because the A-series profile has the same
framebuffer size. Do not use it: it was measured here returning `cuCtxCreate rc=801
NOT_SUPPORTED` with no TSG ever scheduled. The Q profile is the one that works.

Host RAM and cores are the other ceiling. The reference machine ran two 12 GB / 8-core guests on
46 GB and 16 threads without pressure; at that point 26 GB was committed and 20 GB still
allocatable, so a third 12 GB guest fits but leaves little headroom. vCPUs oversubscribe fine —
three 8-core guests on 16 threads is 1.5×, which is normal for desktop workloads.

---

## 5. Connecting to the guests

On an isolated bridge the guests are deliberately unreachable from the LAN, so there are two
routes in. Both were tested.

### The Proxmox console — nothing to set up

Web UI → the VM → **Console**. This is noVNC against QEMU's emulated VGA.

It always works, which makes it the right tool for installing, for the throwaway boot in section 4,
and for anything that happens before Windows is up. What it is *not* is the vGPU's output — once
the NVIDIA driver takes over as the primary display, the accelerated desktop goes to the vGPU and
this console keeps showing the emulated head. A visible symptom is desktop icons disappearing from
the console view while the taskbar clock keeps ticking.

### RDP — the accelerated desktop

The desktop is composited on the vGPU, so RDP is how you see what the card is actually doing:
`nvidia-smi` in the guest lists `explorer.exe`, `ShellHost.exe` and `SearchHost.exe` as `C+G`
clients.

One correction to an earlier version of this document, which claimed RDP "renders and encodes" on
the vGPU. Rendering, yes. **Encoding, not by default** — H.264/AVC hardware encode of the RDP
stream is a separate Group Policy toggle, and on a stock guest the values simply do not exist:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services
    AVCHardwareEncodePreferred   (absent)
    AVC444ModePreferred          (absent)
```

So the session is software-encoded unless you enable those under *Computer Configuration →
Administrative Templates → Windows Components → Remote Desktop Services → Remote Desktop Session
Host → Remote Session Environment*.

RDP is already enabled in the guest if `fDenyTSConnections` is `0` under
`HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server`. Credentials are the guest's own Windows
account.

#### Publishing the guests on the LAN

The convenient option: DNAT a host port to each guest, so a LAN client connects to
`<host-ip>:<port>` with no tunnel at all. [`scripts/pve-vgpu-portmap.sh`](../scripts/pve-vgpu-portmap.sh)
does this for every *running* guest that has a vGPU attached, using

```
port = 13289 + vmid          so VM 100 -> 13389, 101 -> 13390, 102 -> 13391
```

It resolves each guest's current DHCP lease by MAC, so it keeps working when addresses change, and
it keeps all its rules in a dedicated `VGPURDP` chain, so re-running it is idempotent and
`iptables -t nat -F VGPURDP` removes the lot. Drive it from a timer so the rules follow guests as
they start and stop:

```ini
# /etc/systemd/system/vgpu-rdp-portmap.timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
```

The script takes an exclusive `flock`. Without it a timer firing between the chain flush and the
appends duplicates rules — which is exactly what happened the first time this was run by hand while
the timer was active.

> **This exposes Windows RDP to your local network.** Anything on that network can reach the login
> prompt and try passwords. Use a strong password on the guest account, and do not forward these
> ports from a router to the internet.

#### Or keep them private, over an SSH tunnel

If you would rather expose nothing, tunnel instead. `AllowTcpForwarding` is on by default and
`GatewayPorts` is `no`, so the listening socket is only on your own machine:

```bash
ssh -N -L 13389:<guest-ip>:3389 <user>@<host-ip>
```

Then connect to `127.0.0.1:13389`. The tunnel must stay running for the whole session — if the
RDP client reports it cannot connect, check the `ssh` process is still alive before looking
anywhere else.

### Stable addresses

Guest addresses come from DHCP and will move. Pin them by MAC so the tunnel command keeps working:

```
# in the dnsmasq invocation from section 1
--dhcp-host=<guest-mac>,10.10.10.54
```

Take the MAC from `qm config <vmid>`, the `net0:` line.

### If you want them on the LAN instead

Replace the isolated bridge with a normal bridged setup and the guests become ordinary machines on
your network, reachable directly by RDP. That is the conventional Proxmox arrangement and it is
fine — it just means anything on the LAN can reach the guests, and converting the interface you
administer the host over carries the lockout risk described in section 1. Do it from the console,
not over SSH.

---

## 6. Proxmox-specific rough edges

**Migration errors on every stop.** Proxmox's QEMU has VFIO migration support compiled in, and the
NVIDIA vGPU vfio driver does not implement it. Every `qm stop` logs:

```
[nvidia-vgpu-vfio] <uuid>: Failed to notify migration state 0x57
[nvidia-vgpu-vfio] <uuid>: Failed to set stop-and-copy state -5
[nvidia-vgpu-vfio] <uuid>: Failed to configure vgpu device state -5
```

The guest stops correctly and the next start is clean. The practical consequence is that live
migration and RAM-inclusive snapshots are not available for these VMs — which was never going to
work on a single consumer card anyway.

**The mdev is not always reaped.** Starting a VM whose previous mdev survived prints
`mdev instance '…' already existed, using it.` That is harmless. If a start fails with no
instances available, check `ls /sys/bus/mdev/devices` and remove the stale one:

```bash
echo 1 | sudo tee /sys/bus/mdev/devices/<uuid>/remove
```

**`nvidia-smi vgpu` on the host reports "No supported devices in vGPU mode."** Expected. The spoof
lives in `nvidia-vgpud` / `nvidia-vgpu-mgr` via `LD_PRELOAD`; `nvidia-smi` talks to `nvidia.ko`,
which sees the real device ID. Use the guest's own `nvidia-smi` and the host plugin log instead.

**`nvidia-smi` inside the guest needs an elevated prompt** on some builds, and otherwise prints the
misleading "not running as an administrator or there is not at least one TCC device" message. That
message says nothing about whether the vGPU works — read `ConfigManagerErrorCode` instead.

**Windows Fast Startup breaks offline edits.** A guest stopped while hibernated leaves a
`hiberfil.sys`, and the partition then mounts read-only, so any hive edit silently does nothing.
The fix script handles this by dropping the saved session (`ntfs-3g -o remove_hiberfile`) and
aborts if the mount is still read-only. Disabling Fast Startup in the guest avoids it entirely:

```
powercfg /h off
```

---

## 7. Troubleshooting

| Symptom | Cause |
|---|---|
| `unable to associate path … to any storage` | Disk is outside a registered storage. See section 1. |
| Boots to EFI shell, no boot entry | EFI vars were created fresh instead of copied from the working guest. |
| `INACCESSIBLE_BOOT_DEVICE` | Disk attached as `scsi0`. Use `sata0`. |
| Desktop fine, `ConfigManagerErrorCode 43` | New driver Class subkey without the tuning values. Section 3. |
| Code 43 persists after running the fix | Script ran before the subkey existed, or the mount was read-only. Boot once, stop, run it again. |
| `qm start` fails, no instances | All three profile instances in use, or a stale mdev. Section 5. |
| Guest has no IP | No DHCP on the isolated bridge. Section 1. |
