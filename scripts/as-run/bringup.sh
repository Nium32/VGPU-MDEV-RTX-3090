#!/bin/bash
# Full clean bring-up of the vGPU host stack on CachyOS.
# Order is load-bearing:
#   nvidia.ko -> vgpud (configures RM via the LD_PRELOAD spoof) -> nvidia-vgpu-vfio
#   -> nvidia-uvm -> vgpu-mgr (drives the per-GPU probe that registers mdev types)
# A PCI FLR is mandatory after any hand reload, or init_device_instance fails
# with error 7 (init frame copy engine).
set +e
exec >> /home/vgpu/bringup.log 2>&1
# Module set is per kernel: modules-<uname -r> if present, else the old modules-lts.
M=/srv/vgpu/VMs/driver/modules-$(uname -r)
[ -d "$M" ] || M=/srv/vgpu/VMs/driver/modules-lts
V=/srv/vgpu/VMs
P=0000:0a:00.0
echo "================ $(date '+%F %T') clean bring-up ================"

echo "=== tear down ==="
sudo pkill -KILL -f "qemu-system.*win-key0" 2>/dev/null; sleep 3
for m in $(ls /sys/bus/mdev/devices/ 2>/dev/null); do
  timeout 30 bash -c "echo 1 | sudo tee /sys/bus/mdev/devices/$m/remove >/dev/null 2>&1"
done
sudo systemctl stop nvidia-vgpu-mgr nvidia-vgpud 2>/dev/null
sudo rmmod zfmulti mdguest 2>/dev/null
for m in nvidia_uvm nvidia_vgpu_vfio nvidia; do
  lsmod | grep -q "^$m " && sudo rmmod "$m" 2>&1 | sed 's|^|    |'
done
echo "  nvidia modules left: $(lsmod | grep -c '^nvidia')"
[ "$(lsmod | grep -c '^nvidia')" -ne 0 ] && { echo "  REFUSING FLR - modules still loaded"; exit 1; }

echo "=== PCI FLR ==="
sudo sh -c "echo 1 > /sys/bus/pci/devices/$P/reset" && echo "  FLR-OK" || echo "  FLR failed"
sleep 3

# nvidia-vgpu-vfio.ko links against these; without them insmod fails with
# "Unknown symbol in module". The known-good Ubuntu loader modprobes them first.
sudo modprobe -a mdev vfio vfio_pci_core irqbypass 2>&1 | sed "s|^|    |"
echo "  deps: $(for m in mdev vfio vfio_pci_core irqbypass; do printf '%s=%s ' $m $(lsmod | grep -cE "^$m "); done)"
echo "=== 1. nvidia.ko ==="
sudo insmod "$M/nvidia.ko" NVreg_RegistryDwords=RMSetSriovMode=0 NVreg_EnableGpuFirmware=0
sudo udevadm settle --timeout=15
echo "  $(cat /sys/module/nvidia/version 2>/dev/null)"

echo "=== 2. vgpud ==="
sudo systemctl restart nvidia-vgpud; sleep 6
sudo journalctl -u nvidia-vgpud -b --no-pager 2>/dev/null | grep -cE "DevId: 0x10de / 0x2231" | sed 's|^|  spoofed DevId lines: |'

echo "=== 3. nvidia-vgpu-vfio.ko ==="
sudo insmod "$M/nvidia-vgpu-vfio.ko"; sudo udevadm settle --timeout=15; sleep 3

echo "=== 4. nvidia-uvm.ko ==="
sudo insmod "$M/nvidia-uvm.ko"
U=$(awk '$2=="nvidia-uvm"{print $1}' /proc/devices)
[ -n "$U" ] && { sudo mknod -m 666 /dev/nvidia-uvm c "$U" 0 2>/dev/null; sudo mknod -m 666 /dev/nvidia-uvm-tools c "$U" 1 2>/dev/null; }

echo "=== 5. kprobes (FIX 1 + memdesc flag) ==="
# helper modules are per-kernel: prefer zfmulti-$(uname -r).ko, fall back to zfmulti.ko
ZF="$V/kmod/zfmulti/zfmulti-$(uname -r).ko"; [ -f "$ZF" ] || ZF="$V/kmod/zfmulti/zfmulti.ko"
sudo insmod "$ZF" spec="_nv042311rm+0x28:1"
MG="$V/kmod/mdguest/mdguest-$(uname -r).ko"; [ -f "$MG" ] || MG="$V/kmod/mdguest/mdguest.ko"
sudo insmod "$MG" apply=1
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
sudo cat /sys/kernel/debug/kprobes/list 2>/dev/null | sed 's|^|  |'

echo "=== 6. vgpu-mgr (this is what registers the mdev types) ==="
sudo systemctl restart nvidia-vgpu-mgr; sleep 6
sudo systemctl is-active nvidia-vgpu-mgr | sed 's|^|  mgr: |'

echo
echo "=== STATE ==="
T=/sys/devices/pci0000:00/0000:00:03.1/$P/mdev_supported_types
echo "  kernel   : $(uname -r)"
echo "  nvidia   : $(cat /sys/module/nvidia/version)"
echo "  profiles : $(ls $T 2>/dev/null | wc -l)"
echo "  664 avail: $(cat $T/nvidia-664/available_instances 2>/dev/null)"
echo "  Xid      : $(sudo dmesg | grep -ci xid)"
echo "  plugin errors: $(sudo journalctl -t nvidia-vgpu-mgr --since '2 min ago' --no-pager 2>/dev/null | grep -ci 'error:')"
echo "================ READY ================"
