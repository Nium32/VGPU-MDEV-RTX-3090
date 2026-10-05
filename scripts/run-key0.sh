#!/bin/bash
# Canonical launcher for the working Windows vGPU guest.
# DO NOT add or remove -device entries: changing the PCI layout makes Windows create a new
# driver instance under a new {4d36e968-...}\NNNN class subkey, which strands the guest
# registry keys on the old (then phantom) node and Code 43 comes back.
set +e
VM=win-key0; D=/var/lib/vgpu-vm/$VM; M=$D/monitor.sock; P=0000:0a:00.0; PROF=nvidia-664
for m in $(ls /sys/bus/mdev/devices/ 2>/dev/null); do
  timeout 30 bash -c "echo 1 | sudo tee /sys/bus/mdev/devices/$m/remove >/dev/null 2>&1"
done
U=$(uuidgen)
echo "$U" | sudo tee /sys/class/mdev_bus/$P/mdev_supported_types/$PROF/create >/dev/null
sleep 2
[ -e /sys/bus/mdev/devices/$U ] || { echo "MDEV CREATE FAILED"; exit 1; }
echo 'loglevel=5' | sudo tee /sys/bus/mdev/devices/$U/nvidia/vgpu_params >/dev/null
echo "$U" > /home/user/key0.uuid
date '+%Y-%m-%d %H:%M:%S' > /home/user/key0.mark
sudo rm -f $M
sudo qemu-system-x86_64 -name $VM -uuid $U \
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
  -drive file=$D/$VM.qcow2,if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap \
  -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
  -netdev user,id=net0,hostfwd=tcp::3390-:3389 -device e1000e,netdev=net0 >> /home/user/key0-qemu.log 2>&1 &
echo "win-key0 started, mdev $U, VNC 0.0.0.0:5902"
