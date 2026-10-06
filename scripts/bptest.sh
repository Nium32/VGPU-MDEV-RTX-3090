#!/bin/bash
# Deploy and test the bp535 backport.
#
# RANK 1 fix: nv_follow_flavors() in nvidia/os-mlock.c is an unconditional `return -1` on
# 6.18 (follow_pfn no longer exists; the replacements are EXPORT_SYMBOL_GPL and nvidia.ko is
# MODULE_LICENSE("NVIDIA")). Both call sites are in os_lookup_user_io_memory(), which the RM
# blob references, and the failure is SILENT - which matches "error 7" with zero NVRM lines.
# The patch derives the pfn from vma->vm_pgoff, which remap_pfn_range already set, so no GPL
# symbol is needed. A pr_info_once("deriving PFN") fires the first time RM takes the path.
#
# Decision rule for this run:
#   "deriving PFN" present  -> RANK 1 was really on the path
#   error 7 gone / pteblit 0 with the blit path ENABLED -> the backport fixed the root
#   "deriving PFN" absent while error 7 persists -> RANK 1 exonerated, go to RANK 2
set +e
exec > /home/vgpu/bptest.log 2>&1
V=/srv/vgpu/VMs
H=/home/vgpu
D=/var/lib/vgpu-vm/win-key0
M=$D/monitor.sock
PCI=0000:0a:00.0
PROF=nvidia-664
SHOT=$H/shots7
say(){ echo; echo "################ $* ############"; }
mon(){ printf "%s\n" "$1" | sudo socat - UNIX-CONNECT:$M >/dev/null 2>&1; }
rdp(){ python3 - <<'PY' 2>/dev/null
import socket,sys
try:
    s=socket.create_connection(("127.0.0.1",3390),timeout=4); s.settimeout(4)
    s.sendall(bytes.fromhex("030000130ee000000000000100080003000000"))
    d=s.recv(64); s.close(); sys.stdout.write(d.hex())
except Exception: pass
PY
}
mkdir -p $SHOT

say "$(date "+%F %T") bp535 backport test"

say "A  free the GPU"
sudo pkill -9 -f "qemu-system-x86_64" >/dev/null 2>&1
sleep 5
for m in $(ls /sys/bus/mdev/devices/ 2>/dev/null); do
  timeout 30 bash -c "echo 1 | sudo tee /sys/bus/mdev/devices/$m/remove >/dev/null 2>&1"
done
sleep 3
sudo systemctl stop nvidia-vgpu-mgr.service nvidia-vgpud.service 2>/dev/null
sleep 2; sudo pkill -9 -f nvidia-vgpu-mgr 2>/dev/null; sleep 2
sudo rmmod nvidia_vgpu_vfio 2>/dev/null; sudo rmmod nvidia_uvm 2>/dev/null; sudo rmmod nvidia 2>/dev/null
lsmod | grep -c '^nvidia' | sed 's|^|  nvidia modules still loaded: |'

say "B  install the backported nvidia.ko (modules-lts and modules-6.18 share one inode)"
MM=$V/driver/modules-6.18.52-1-cachyos-lts
echo "  inode check: modules-lts=$(stat -c %i $V/driver/modules-lts/nvidia.ko) modules-6.18=$(stat -c %i $MM/nvidia.ko)"
[ -f "$MM/nvidia.ko.before-bp535" ] || sudo cp -a $MM/nvidia.ko $MM/nvidia.ko.before-bp535
echo "  backup: $(ls -la $MM/nvidia.ko.before-bp535 2>/dev/null | awk '{print $5}') bytes"
sudo cp $H/bp535/kernel/nvidia.ko $MM/nvidia.ko && echo "  installed"
echo "  live path srcversion now: $(modinfo -F srcversion $V/driver/modules-lts/nvidia.ko)"
echo "  (was 46F9FFD8A34386D1A7E8280, new should be D0A8905B945228D9A4AB102)"
echo "  'deriving PFN' string present in the .ko: $(strings $MM/nvidia.ko | grep -c 'deriving PFN')"

say "C  FLR + bring up"
sudo sh -c "echo 1 > /sys/bus/pci/devices/$PCI/reset" && echo "  FLR-OK" || echo "  FLR-FAILED"
sleep 4
sudo dmesg -C >/dev/null 2>&1
bash $H/bringup.sh >/dev/null 2>&1
tail -4 $H/bringup.log | sed "s|^|  |"
echo "  loaded nvidia srcversion: $(cat /sys/module/nvidia/srcversion 2>/dev/null)"
sudo cat /sys/kernel/debug/kprobes/list 2>/dev/null | sed "s|^|  kprobe: |"

say "D  boot Windows with the blit path ENABLED (stock params - the real test)"
U=$(uuidgen)
echo "$U" | sudo tee /sys/class/mdev_bus/$PCI/mdev_supported_types/$PROF/create >/dev/null
sleep 3
[ -e /sys/bus/mdev/devices/$U ] || { echo "  MDEV CREATE FAILED"; exit 1; }
echo 'loglevel=5' | sudo tee /sys/bus/mdev/devices/$U/nvidia/vgpu_params >/dev/null
MARK=$(date "+%Y-%m-%d %H:%M:%S")
sudo rm -f $M
sudo qemu-system-x86_64 -name win-key0 -uuid $U \
  -machine q35,accel=kvm,hpet=off -smp sockets=1,cores=4,threads=2 -m 12288 \
  -rtc base=localtime,driftfix=slew -global kvm-pit.lost_tick_policy=discard \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd \
  -cpu host,kvm=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer \
  -vga std -vnc 0.0.0.0:2 \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
  -device vfio-pci,sysfsdev=/sys/bus/mdev/devices/$U,enable-migration=off \
  -boot menu=off -monitor unix:$M,server,nowait \
  -device ich9-ahci,id=ahci \
  -drive file=$D/win-test.qcow2,if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap \
  -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
  -netdev user,id=net0,hostfwd=tcp::3390-:3389 -device e1000e,netdev=net0 \
  >> $H/key0-qemu.log 2>&1 &
sleep 12
[ "$(pgrep -cf 'qemu-system-x86_64.*win-key0')" = "0" ] && { echo "  QEMU FAILED"; tail -3 $H/key0-qemu.log | cut -c1-160; exit 1; }
echo "  qemu up"

say "E  the decisive signals"
J(){ sudo journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager 2>/dev/null; }
for i in $(seq 1 32); do
  sleep 15
  if [ $((i % 4)) -eq 0 ]; then
    echo "  t=$((i*15))s derivePFN=$(sudo dmesg | grep -c 'deriving PFN') ce_sync=$(J | grep -c 'Init frame copy engine') err7=$(J | grep -c 'error 7') pteblit=$(J | grep -ci pteblit) oor=$(J | grep -c 'out-of-range') pinfail=$(J | grep -c 'Failed to pin pages') xid=$(J | grep -cE 'XID [0-9]+ detected') rdp=$(rdp | cut -c1-6)"
  fi
  if [ $((i % 8)) -eq 0 ]; then mon "screendump /tmp/bp$i.ppm"; sleep 2; magick /tmp/bp$i.ppm $SHOT/t$((i*15)).png 2>/dev/null; fi
done

say "F  RESULT"
echo "  deriving-PFN hits : $(sudo dmesg | grep -c 'deriving PFN')"
sudo dmesg | grep -i 'deriving PFN' | head -3 | cut -c1-160 | sed "s|^|    |"
echo "  Init frame copy engine : $(J | grep -c 'Init frame copy engine')"
echo "  error 7                : $(J | grep -c 'error 7')"
echo "  pteblit timeouts       : $(J | grep -ci pteblit)"
echo "  out-of-range           : $(J | grep -c 'out-of-range')"
echo "  Failed to pin pages    : $(J | grep -c 'Failed to pin pages')"
echo "  XID                    : $(J | grep -cE 'XID [0-9]+ detected')"
echo "  RDP handshake          : $(rdp | cut -c1-12)"
echo "  screenshots:"; md5sum $SHOT/*.png 2>/dev/null | awk '{print "    ",substr($1,1,10),$2}'
echo "  guest uploads: $(ls $H/vgpuhttp/up/ 2>/dev/null | tr '\n' ' ')"
echo
echo "  BASELINE for comparison (pre-backport, blit ON): ce_sync=1 err7=30 pteblit=198 rdp=none"
say "bptest done - guest left running"
