#!/bin/bash
# pve-fix-rdp-wddm.sh <guest-disk.qcow2>
#
# Force the legacy XDDM display path for Remote Desktop sessions on a STOPPED guest.
#
# Symptom this fixes: RDP authenticates, a session is created, and the client then
# sits on "Welcome" forever before being dropped. The guest's own logs name the
# cause - RdpCoreTS event 145 "server has not sent data or graphics update", then
# event 102 terminating the connection. The session exists but never produces a
# frame, because the WDDM path used for remote sessions does not come up on a
# GPU-accelerated guest.
#
# Trade-off, stated plainly: the REMOTE DESKTOP surface is then composited through
# the legacy path rather than the vGPU. Applications still use the GPU - CUDA and
# Direct3D are unaffected - but do not expect the remote desktop itself to be
# GPU-composited afterwards.
set -euo pipefail

REVERT=0
if [ "${1:-}" = "-r" ]; then REVERT=1; shift; fi
DISK="${1:?usage: $0 [-r] <guest-disk.qcow2>}"
NBD="${NBD:-/dev/nbd4}"
WORK=$(mktemp -d)
MNT="$WORK/mnt"; mkdir -p "$MNT"

command -v hivexregedit >/dev/null || { echo "need libhivex-bin" >&2; exit 1; }
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

PART=$(lsblk -bnro NAME,SIZE "$NBD" | awk 'NR>1{print $1, $2}' | sort -k2 -n | tail -1 | cut -d' ' -f1)
[ -n "$PART" ] || { echo "no partitions on $NBD" >&2; exit 1; }
mount -t ntfs3 "/dev/$PART" "$MNT" 2>/dev/null \
  || ntfs-3g -o remove_hiberfile "/dev/$PART" "$MNT" 2>/dev/null \
  || mount "/dev/$PART" "$MNT"
case ",$(findmnt -no OPTIONS "$MNT")," in
    *,ro,*) echo "$MNT mounted read-only - refusing to pretend the edit worked" >&2; exit 1 ;;
esac

HIVE="$MNT/Windows/System32/config/SOFTWARE"
[ -f "$HIVE" ] || { echo "no SOFTWARE hive at $HIVE" >&2; exit 1; }

WANT=00000000
[ "$REVERT" = 1 ] && WANT=00000001

REG="$WORK/rdp.reg"
{
    echo 'Windows Registry Editor Version 5.00'
    echo
    printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services]\n'
    printf '"fEnableWddmDriver"=dword:%s\n' "$WANT"
} > "$REG"

hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$HIVE" "$REG"

# Read it back: a merge that silently did nothing is the failure mode worth catching.
if hivexregedit --export "$HIVE" 'Policies\Microsoft\Windows NT\Terminal Services' 2>/dev/null \
     | grep -qi "fEnableWddmDriver\"=dword:$WANT"; then
    if [ "$REVERT" = 1 ]; then
        echo "fEnableWddmDriver=1 restored in $DISK (WDDM back on, console renders again)"
    else
        echo "fEnableWddmDriver=0 set in $DISK"
    fi
else
    echo "merge did not take - value not present on read-back" >&2
    exit 1
fi