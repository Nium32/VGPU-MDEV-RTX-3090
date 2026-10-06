#!/bin/bash
# pve-fix-nvidia-regkeys.sh <guest-disk.qcow2>
#
# Writes the two NVIDIA driver tuning values this project needs into EVERY
# display-class subkey of a stopped Windows guest's SYSTEM hive, offline.
#
# Why this exists: the values live under a per-device-instance subkey of
#   HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}
# and Windows creates a NEW numbered subkey whenever the card turns up at a
# different PCI instance path. Moving the guest from a hand-rolled QEMU line to
# Proxmox does exactly that, because Proxmox puts the device behind a PCIe root
# port. The freshly created subkey then has no tuning values and the guest comes
# up with Code 43. Writing every subkey also survives any later slot change.
set -euo pipefail

DISK="${1:?usage: $0 <guest-disk.qcow2>}"
CLASS='Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
NBD="${NBD:-/dev/nbd3}"
WORK=$(mktemp -d)
MNT="$WORK/mnt"; mkdir -p "$MNT"

command -v hivexregedit >/dev/null || { echo "need libhivex-bin: apt install libhivex-bin" >&2; exit 1; }
[ -r "$DISK" ] || { echo "cannot read $DISK" >&2; exit 1; }

cleanup() {
    if mountpoint -q "$MNT"; then umount "$MNT" || true; fi
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

modprobe nbd max_part=16
qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
qemu-nbd --connect="$NBD" "$DISK"
sleep 2

# The Windows partition is the largest one on the disk.
PART=$(lsblk -bnro NAME,SIZE "$NBD" | awk 'NR>1{print $1, $2}' | sort -k2 -n | tail -1 | cut -d' ' -f1)
[ -n "$PART" ] || { echo "no partitions on $NBD" >&2; exit 1; }
# Windows Fast Startup leaves a hiberfil, and both ntfs3 and ntfs-3g then mount
# read-only, which would make the hive edit a silent no-op. Dropping that saved
# session is exactly what we want here: we are forcing a cold boot anyway.
mount -t ntfs3 "/dev/$PART" "$MNT" 2>/dev/null \
  || ntfs-3g -o remove_hiberfile "/dev/$PART" "$MNT" 2>/dev/null \
  || mount "/dev/$PART" "$MNT"
# The word is comma-wrapped on both sides, so one pattern covers first, middle and last.
case ",$(findmnt -no OPTIONS "$MNT")," in
    *,ro,*) echo "$MNT mounted read-only - refusing to pretend the edit worked" >&2; exit 1 ;;
esac

HIVE="$MNT/Windows/System32/config/SYSTEM"
[ -f "$HIVE" ] || { echo "no SYSTEM hive at $HIVE - wrong partition?" >&2; exit 1; }

# Honour whichever control set the guest actually boots.
CUR=$(hivexsh -w "$HIVE" <<<$'cd Select\nlsval\nclose' | sed -n 's/^"Current"=dword:0*\([0-9a-f]\+\)$/\1/p')
CS=$(printf 'ControlSet%03d' "$((16#${CUR:-1}))")
echo "control set: $CS"

REG="$WORK/fix.reg"
echo 'Windows Registry Editor Version 5.00' > "$REG"; echo >> "$REG"
n=0
for i in $(seq -w 0 9); do
    # Only touch subkeys that already exist; inventing new ones confuses setupapi.
    hivexregedit --export "$HIVE" "$CS\\$CLASS\\000$i" >/dev/null 2>&1 || continue
    {
        printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\%s\\%s\\000%s]\n' "$CS" "$CLASS" "$i"
        printf '"RMSetClientRMAllocatedCtxBuffer"=dword:00000000\n'
        printf '"RmRcWatchdog"=dword:00000000\n\n'
    } >> "$REG"
    n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "no display-class subkeys found" >&2; exit 1; }

hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$HIVE" "$REG"
echo "patched $n display-class subkey(s) in $DISK"