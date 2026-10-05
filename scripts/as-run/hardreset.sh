#!/bin/bash
# Full stack reset that ALSO unloads the vfio core modules.
#
# Why: after a qemu is killed with SIGKILL, iommu group 22 stays wedged - every later qemu
# fails with "error getting device from group 22 ... not already in use" even though nothing
# holds /dev/vfio/22 (fuser and lsof both show no holder, no qemu process, fresh mdev). Just
# rmmod'ing the nvidia modules plus a PCI FLR is NOT enough, because vfio_iommu_type1 /
# vfio_pci_core / vfio / mdev keep the group object alive. Unloading those destroys it.
set +e
REGSTR="${1:-RMSetSriovMode=0}"
exec > /home/vgpu/hardreset.log 2>&1
V=/srv/vgpu/VMs
M=$V/driver/modules-$(uname -r)
PCI=0000:0a:00.0
say(){ echo; echo "######## $* ########"; }
say "$(date '+%F %T') hard reset"

sudo pkill -9 -f "qemu-system-x86_64" >/dev/null 2>&1; sleep 4
for m in $(ls /sys/bus/mdev/devices/ 2>/dev/null); do timeout 25 bash -c "echo 1 | sudo tee /sys/bus/mdev/devices/$m/remove >/dev/null 2>&1"; done
sleep 2
sudo systemctl stop nvidia-vgpu-mgr.service nvidia-vgpud.service 2>/dev/null; sleep 2
sudo pkill -9 -f nvidia-vgpu-mgr 2>/dev/null
for p in $(for q in $(ls /proc | grep -E '^[0-9]+$'); do sudo grep -ql libnvidia-vgpu /proc/$q/maps 2>/dev/null && echo $q; done); do sudo kill -9 $p; done
sleep 3
for t in 1 2 3 4 5; do
  sudo rmmod zfmulti mdguest 2>/dev/null
  # nvidia_drm/nvidia_modeset pin nvidia.ko - they MUST come off first or rmmod nvidia fails
  sudo rmmod nvidia_drm 2>/dev/null; sudo rmmod nvidia_modeset 2>/dev/null
  sudo rmmod nvidia_vgpu_vfio 2>/dev/null; sudo rmmod nvidia_uvm 2>/dev/null; sudo rmmod nvidia 2>/dev/null
  n=$(lsmod | grep -c '^nvidia'); echo "  nvidia try $t: $n"; [ "$n" -eq 0 ] && break; sleep 3
done
[ "$(lsmod | grep -c '^nvidia')" -ne 0 ] && { echo "  CANNOT UNLOAD NVIDIA"; exit 1; }

say "unload vfio core so iommu group 22 is destroyed"
for t in 1 2 3; do
  sudo rmmod vfio_iommu_type1 2>/dev/null
  sudo rmmod vfio_pci_core  2>/dev/null
  sudo rmmod vfio           2>/dev/null
  sudo rmmod mdev           2>/dev/null
  echo "  try $t: vfio=$(lsmod | grep -cE '^vfio') mdev=$(lsmod | grep -cE '^mdev') /dev/vfio=$(ls /dev/vfio/ 2>/dev/null | tr '\n' ' ')"
  [ "$(lsmod | grep -cE '^vfio')" -eq 0 ] && break
  sleep 2
done

say "FLR"
sudo sh -c "echo 1 > /sys/bus/pci/devices/$PCI/reset" && echo "  FLR-OK" || echo "  FLR-FAILED"
sleep 5

say "reload with RMInstLoc=65536 (USERD -> COH sysmem)"
sudo modprobe -a mdev vfio vfio_pci_core vfio_iommu_type1 irqbypass 2>/dev/null
sudo insmod "$M/nvidia.ko" NVreg_RegistryDwords="$REGSTR" NVreg_EnableGpuFirmware=0 2>&1 | sed 's/^/  nvidia: /'
sleep 3
echo "  $(grep -i '^RegistryDwords:' /proc/driver/nvidia/params)"
sudo insmod "$M/nvidia-vgpu-vfio.ko" 2>&1 | sed 's/^/  vfio: /'
sudo udevadm settle --timeout=15; sleep 3
sudo insmod "$M/nvidia-uvm.ko" 2>&1 | sed 's/^/  uvm: /'
# helper modules are per-kernel; prefer zfmulti-$(uname -r).ko
ZF="$V/kmod/zfmulti/zfmulti-$(uname -r).ko"; [ -f "$ZF" ] || ZF="$V/kmod/zfmulti/zfmulti.ko"
sudo insmod "$ZF" spec="_nv042311rm+0x28:1" 2>&1 | sed 's/^/  zfmulti: /'
MG="$V/kmod/mdguest/mdguest-$(uname -r).ko"; [ -f "$MG" ] || MG="$V/kmod/mdguest/mdguest.ko"
sudo insmod "$MG" apply=1 2>&1 | sed 's/^/  mdguest: /'
sudo systemctl start nvidia-vgpud.service 2>/dev/null; sleep 3
sudo systemctl start nvidia-vgpu-mgr.service 2>/dev/null; sleep 4
echo "  modules=$(lsmod|grep -c '^nvidia') kprobes=$(sudo cat /sys/kernel/debug/kprobes/list 2>/dev/null|wc -l)"
echo "  664 avail: $(cat /sys/class/mdev_bus/$PCI/mdev_supported_types/nvidia-664/available_instances 2>/dev/null)"
echo "  /dev/vfio: $(ls /dev/vfio/ 2>/dev/null | tr '\n' ' ')"
say "hardreset done"
