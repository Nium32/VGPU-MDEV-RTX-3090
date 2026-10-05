#!/bin/bash
# Recover the GPU after a scheduler wedge, without rebooting.
# Order matters: stop consumers, unload, FLR, reload, restart services.
set +e
echo "=== stopping guest VM and probes ==="
sudo pkill -f qemu-system-x86_64 2>/dev/null
sleep 3
sudo rmmod grallow grwat rlall rlfb ptop retlog argdump ring regdump fbpeek \
      promotedrop mdguest nvzf zf2 ptr nvprobe 2>/dev/null
echo "=== stopping vgpu services ==="
sudo systemctl stop vgpu535-515-mgr.service vgpu535-515-vgpud.service 2>/dev/null
sleep 2
echo "=== unloading driver ==="
sudo rmmod nvidia_vgpu_vfio 2>/dev/null
sudo rmmod nvidia 2>/dev/null
lsmod | grep -E "^nvidia" || echo "driver unloaded"
echo "=== PCI FLR ==="
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:0a:00.0/reset' && echo FLR-OK || echo FLR-FAILED
sleep 3
echo "=== reloading stack ==="
sudo /usr/local/sbin/vgpu535-515-load
sudo systemctl start vgpu535-515-vgpud.service
sudo systemctl start vgpu535-515-mgr.service
sleep 4
echo "=== state ==="
cat /proc/driver/nvidia/version 2>/dev/null | head -1
LD_LIBRARY_PATH=/opt/nvidia-vgpu-535/merged/535.309.01/lib/x86_64-linux-gnu \
  /opt/nvidia-vgpu-535/merged/535.309.01/bin/nvidia-smi \
  --query-gpu=name,driver_version,memory.used --format=csv,noheader 2>&1 | head -2
for f in /sys/class/mdev_bus/0000:0a:00.0/mdev_supported_types/*/available_instances; do
  v=$(cat "$f" 2>/dev/null); [ "$v" != "0" ] && echo "$(basename $(dirname $f)) avail=$v"
done
