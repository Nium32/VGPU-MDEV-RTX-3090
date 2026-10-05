#!/bin/bash
# Clean, unambiguous CUDA verification on kernel 6.1.71.
#
# The existing C:\Users\Public\vgpu-out.txt is an append-only log that starts 10/04 23:12, and
# host mtimes (22:10:42) cannot come from this boot (started 11:59:24, host time ~12:1x), so the
# CUDA-ALL-PASS dated 12:10:33 in it could be from an earlier run. Wipe both output files,
# stamp a marker, boot, trigger C:\t.cmd through the QEMU monitor (Win+R), then read the files
# back offline. Only output produced after the marker counts.
#
# t.cmd runs: whoami, display devices, nvidia-smi, then powershell C:\vgpucuda.ps1 which does
# cuInit / cuCtxCreate / 4 MiB HtoD+DtoH roundtrip / PTX module load / cuLaunchKernel /
# readback verify, and writes C:\Users\Public\vgpu-cuda.txt.
set +e
exec > /home/vgpu/cudarun61.log 2>&1
D=/var/lib/vgpu-vm/win-key0
H=/home/vgpu
say(){ echo; echo "######## $* ########"; }
mon(){ printf "%s\n" "$1" | sudo socat - UNIX-CONNECT:$D/monitor.sock >/dev/null 2>&1; }
rdp(){ python3 - <<'PY' 2>/dev/null
import socket,sys
try:
    s=socket.create_connection(("127.0.0.1",3390),timeout=4); s.settimeout(4)
    s.sendall(bytes.fromhex("030000130ee000000000000100080003000000"))
    sys.stdout.write(s.recv(64).hex()); s.close()
except Exception: pass
PY
}
say "$(date '+%F %T') clean CUDA run on $(uname -r)"

say "A  stop guest, wipe guest output files, stamp marker"
sudo pkill -9 -f "qemu-system-x86_64" >/dev/null 2>&1; sleep 5
for m in /mnt/win /mnt/nogpu /mnt/winro; do sudo umount -l $m >/dev/null 2>&1; done
sudo systemctl stop vgpudrv vgpunbd vgpunbd2 vgpurd 2>/dev/null
for i in 0 1 2 3; do sudo qemu-nbd --disconnect /dev/nbd$i >/dev/null 2>&1; done
sleep 2
[ "$(mount | grep -c nbd)" -ne 0 ] && { echo "  REFUSING: stale nbd mount"; exit 1; }
sudo modprobe nbd max_part=16 2>/dev/null
sudo systemd-run --unit=vgpudrv --slice=system.slice -p Type=forking \
     /usr/bin/qemu-nbd --connect=/dev/nbd0 --format=qcow2 $D/win-test.qcow2 >/dev/null 2>&1
sleep 4
sudo partx -a /dev/nbd0 >/dev/null 2>&1
sudo ntfsfix -b -d /dev/nbd0p3 >/dev/null 2>&1
sudo mkdir -p /mnt/win
sudo ntfs-3g -o rw,remove_hiberfile,windows_names /dev/nbd0p3 /mnt/win 2>&1 | head -1
mountpoint -q /mnt/win || { echo "  MOUNT FAILED"; exit 1; }
STAMP="KERNEL-$(uname -r)-RUN-$(date '+%Y%m%dT%H%M%S')"
sudo rm -f /mnt/win/Users/Public/vgpu-out.txt /mnt/win/Users/Public/vgpu-cuda.txt
printf 'MARKER %s\r\n' "$STAMP" | sudo tee /mnt/win/Users/Public/vgpu-marker.txt >/dev/null
echo "  wiped. marker=$STAMP"
echo "  t.cmd present: $(sudo stat -c %s /mnt/win/t.cmd) bytes ; vgpucuda.ps1: $(sudo stat -c %s /mnt/win/vgpucuda.ps1) bytes"
sudo sync; sudo umount /mnt/win
sudo systemctl stop vgpudrv >/dev/null 2>&1; sudo qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
echo "  image released; nbd mounts=$(mount | grep -c nbd)"

say "B  bring the stack up and boot the guest (default vgpu_params, blit ENABLED)"
bash $H/hardreset.sh "RMSetSriovMode=0" >/dev/null 2>&1
echo "  modules=$(lsmod|grep -c '^nvidia') kprobes=$(sudo cat /sys/kernel/debug/kprobes/list 2>/dev/null|wc -l) avail=$(cat /sys/class/mdev_bus/0000:0a:00.0/mdev_supported_types/nvidia-664/available_instances 2>/dev/null)"
bash $H/startguest.sh "loglevel=5,disable_vnc=1" | sed 's/^/  /'
MARK=$(cat /tmp/mark.txt)
[ "$(pgrep -cf 'qemu-system-x86_64.*win-key0')" = "0" ] && { echo "  GUEST FAILED"; exit 1; }

say "C  wait for the desktop"
HIT=""
for i in $(seq 1 26); do
  R=$(rdp); [ "${R:0:4}" = "0300" ] && { HIT=$((i*15)); echo "  desktop at t=${HIT}s"; break; }
  sleep 15
done
[ -z "$HIT" ] && echo "  desktop never answered"
sleep 50

say "D  trigger C:\t.cmd via Win+R"
mon "sendkey meta_l-r"; sleep 4
for k in c shift-semicolon backslash t dot c m d; do mon "sendkey $k"; sleep 0.3; done
sleep 1
mon "sendkey ret"
echo "  sent; waiting 180s for the test to finish"
sleep 180
J(){ sudo journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager 2>/dev/null; }
echo "  host side: pteblit=$(J | grep -ci 'Immediate pteblit') errors=$(J | grep -c 'error:') xid=$(J | grep -cE 'XID [0-9]+ detected')"

say "E  read the results back offline"
printf "system_powerdown\n" | sudo socat - UNIX-CONNECT:$D/monitor.sock >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(pgrep -cf 'qemu-system-x86_64.*win-key0')" = "0" ] && break; sleep 5; done
sudo pkill -9 -f "qemu-system-x86_64" >/dev/null 2>&1; sleep 4
sudo systemd-run --unit=vgpudrv2 --slice=system.slice -p Type=forking \
     /usr/bin/qemu-nbd --connect=/dev/nbd0 --format=qcow2 $D/win-test.qcow2 >/dev/null 2>&1
sleep 4
sudo partx -a /dev/nbd0 >/dev/null 2>&1
sudo ntfsfix -b -d /dev/nbd0p3 >/dev/null 2>&1
sudo ntfs-3g -o rw,remove_hiberfile,windows_names /dev/nbd0p3 /mnt/win 2>&1 | head -1
echo "  marker in image: $(sudo cat /mnt/win/Users/Public/vgpu-marker.txt 2>/dev/null | tr -d '\r')"
echo
echo "  ===== vgpu-cuda.txt (FRESH) ====="
sudo cat /mnt/win/Users/Public/vgpu-cuda.txt 2>/dev/null | tr -d '\r' | sed 's/^/    /'
echo "  ===== vgpu-out.txt head ====="
sudo head -8 /mnt/win/Users/Public/vgpu-out.txt 2>/dev/null | tr -d '\r' | sed 's/^/    /'
sudo sync; sudo umount /mnt/win
sudo systemctl stop vgpudrv2 >/dev/null 2>&1; sudo qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
echo "  released; nbd mounts=$(mount | grep -c nbd)"
say "cudarun61 done"
