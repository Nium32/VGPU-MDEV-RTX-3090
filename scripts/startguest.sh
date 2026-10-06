#!/bin/bash
# Create a fresh mdev from the configured profile and boot the guest on it.
#
# Usage: startguest.sh [vgpu_params]
#   vgpu_params defaults to $VGPU_PARAMS from vgpu.conf.
#
# A note on the disk: the guest boots $VM_BASE/$VM_NAME/$VM_DISK. If that image
# is an overlay on a backing file, do not also boot the backing file read-write
# from another script. QEMU's locking stops both being open at once, but nothing
# stops you doing it sequentially, and that silently invalidates the overlay.

set +e
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
need_root

VGP="${1:-$VGPU_PARAMS}"
D="$VM_BASE/$VM_NAME"

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
command -v uuidgen >/dev/null || die "uuidgen not installed (util-linux)"
[ -d "$D" ] || die "guest directory $D does not exist"
[ -f "$D/$VM_DISK" ] || die "disk $D/$VM_DISK does not exist"
[ -f "$D/OVMF_VARS.fd" ] || die "$D/OVMF_VARS.fd missing; copy the 4MB OVMF vars template in"
assert_own_nvram "$D/OVMF_VARS.fd"
assert_not_a_backing_file "$D/$VM_DISK" ||
    die "refusing to boot $VM_DISK read-write: another image overlays it"

OVMF=$(detect_ovmf) || die "no 4MB OVMF code image found; set OVMF_CODE in vgpu.conf"
BDF=$(detect_gpu_bdf) || exit 1
TYPE=$(resolve_vgpu_type "$BDF") || die "no vGPU profile resolved; run preflight.sh"
TDIR=$(mdev_types_dir "$BDF")

avail=$(cat "$TDIR/$TYPE/available_instances" 2>/dev/null)
[ "${avail:-0}" -lt 1 ] && die "profile $TYPE has no instances left (available_instances=$avail)"

mkdir -p "$LOG_DIR"

U=$(uuidgen)
say "creating mdev $U on $BDF as $TYPE ($(cat "$TDIR/$TYPE/name" 2>/dev/null))"
echo "$U" > "$TDIR/$TYPE/create" || die "mdev create failed"
sleep 3
[ -e "/sys/bus/mdev/devices/$U" ] || die "mdev $U did not appear"

echo "$VGP" > "/sys/bus/mdev/devices/$U/nvidia/vgpu_params" \
    || warn "could not set vgpu_params"
info "vgpu_params: $VGP"

# Journal mark, so the health checks can scope their greps to this run only.
# Per-VM and under LOG_DIR, not a fixed name in /tmp that any user could
# pre-create as a symlink.
MARK_FILE="$LOG_DIR/$VM_NAME.mark"
date '+%Y-%m-%d %H:%M:%S' > "$MARK_FILE"
info "journal mark: $MARK_FILE"

rm -f "$D/monitor.sock"

# Bind the QEMU console to loopback. Binding it to 0.0.0.0 with no password
# hands anyone on the network the guest keyboard, mouse and screen.
VNC_ARG=(-display none)
if [ "${QEMU_VNC_DISPLAY:--1}" -ge 0 ] 2>/dev/null; then
    VNC_ARG=(-vga std -vnc "$QEMU_VNC_BIND:$QEMU_VNC_DISPLAY")
    info "console on $QEMU_VNC_BIND:$((5900 + QEMU_VNC_DISPLAY)) - tunnel to it, do not expose it"
fi

# shellcheck disable=SC2054  # the commas belong to the QEMU argument values
NET_ARG=(-netdev user,id=net0 -device e1000e,netdev=net0)
if [ "${RDP_HOST_PORT:-0}" -gt 0 ]; then
    # shellcheck disable=SC2054
    NET_ARG=(-netdev "user,id=net0,hostfwd=tcp:$RDP_BIND:$RDP_HOST_PORT-:3389" -device e1000e,netdev=net0)
    info "forwarding host port $RDP_HOST_PORT to guest 3389"
fi

say "booting $VM_NAME"
# Wrapped so the mdev is released whenever the guest exits, not only when it
# fails to start. Without this every run leaks one, and the profile offers three.
( setsid --wait qemu-system-x86_64 -name "$VM_NAME" -uuid "$U" \
    -machine q35,accel=kvm,hpet=off \
    -smp "sockets=1,cores=$VM_CORES,threads=$VM_THREADS" -m "$VM_MEM_MB" \
    -rtc base=localtime,driftfix=slew -global kvm-pit.lost_tick_policy=discard \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF" \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -cpu host,kvm=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer \
    "${VNC_ARG[@]}" \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
    -device "vfio-pci,sysfsdev=/sys/bus/mdev/devices/$U" \
    -boot menu=off -monitor "unix:$D/monitor.sock,server,nowait" \
    -device ich9-ahci,id=ahci \
    -drive "file=$D/$VM_DISK,if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap" \
    -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
    "${NET_ARG[@]}" \
    -pidfile "$D/qemu.pid"
  _rc=$?
  timeout 30 sh -c "echo 1 > /sys/bus/mdev/devices/$U/remove" 2>/dev/null
  exit $_rc
) >> "$LOG_DIR/$VM_NAME-qemu.log" 2>&1 &
QPID=$!

sleep 15
# kill -0 on the wrapper, not a pgrep pattern: a pattern match would also count
# an unrelated guest whose name merely contains this one.
if ! kill -0 "$QPID" 2>/dev/null; then
    warn "qemu exited. Last lines of $LOG_DIR/$VM_NAME-qemu.log:"
    tail -5 "$LOG_DIR/$VM_NAME-qemu.log" | cut -c1-200 | sed 's|^|     |'
    warn "the wrapper has already released mdev $U"
    exit 1
fi
info "mdev=$U  qemu pid=$(cat "$D/qemu.pid" 2>/dev/null)"
say "up. monitor: socat - UNIX-CONNECT:$D/monitor.sock"
