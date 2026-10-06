#!/bin/bash
# Create a fresh mdev and boot the Windows guest. Writes the journal mark to /tmp/mark.txt.
set +e
H=/home/vgpu
D=/var/lib/vgpu-vm/win-key0
PCI=0000:0a:00.0
PROF=nvidia-664
VGP="${1:-loglevel=5,disable_vnc=1}"
U=$(uuidgen)
echo "$U" | sudo tee /sys/class/mdev_bus/$PCI/mdev_supported_types/$PROF/create >/dev/null
sleep 3
[ -e /sys/bus/mdev/devices/$U ] || { echo "MDEV CREATE FAILED"; exit 1; }
 echo "$VGP" | sudo tee /sys/bus/mdev/devices/$U/nvidia/vgpu_params >/dev/null
date '+%Y-%m-%d %H:%M:%S' > /tmp/mark.txt
sudo rm -f $D/monitor.sock
sudo qemu-system-x86_64 -name win-key0 -uuid $U \
  -machine q35,accel=kvm,hpet=off -smp sockets=1,cores=4,threads=2 -m 12288 \
  -rtc base=localtime,driftfix=slew -global kvm-pit.lost_tick_policy=discard \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd \
  -cpu host,kvm=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer \
  -vga std -vnc 0.0.0.0:2 \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
  -device vfio-pci,sysfsdev=/sys/bus/mdev/devices/$U,enable-migration=off \
  -boot menu=off -monitor unix:$D/monitor.sock,server,nowait \
  -device ich9-ahci,id=ahci \
  -drive file=$D/win-test.qcow2,if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap \
  -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
  -netdev user,id=net0,hostfwd=tcp::3390-:3389 -device e1000e,netdev=net0 \
  >> $H/key0-qemu.log 2>&1 &
sleep 15
echo "mdev=$U qemu=$(pgrep -cf 'qemu-system-x86_64.*win-key0')"
[ "$(pgrep -cf 'qemu-system-x86_64.*win-key0')" = "0" ] && tail -3 $H/key0-qemu.log | cut -c1-170
