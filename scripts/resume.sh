#!/bin/bash
# Post-power-cycle resume: verify the box, then run the ONE decisive test.
#
# Hypothesis under test: the plugin's store of GP_PUT to USERD+0x8c never reaches the GPU,
# because nvidia.ko mapped that /dev/nvidia0 BAR page write-back cacheable instead of UC.
# Everything else is already measured and consistent with it - pushbuffer well formed, doorbell
# rung every kick, channel ENABLE NEXT ON_PBDMA ON_ENG with zero faults, FB copy destination
# never written, semaphore page never written, Xid 0.
#
# SAFETY: nothing here touches the PRAMIN window register 0x001700. Looping that is what
# wedged the host and forced the power cycle. fifopeek reads PRI registers only; userdpeek
# walks page tables and ioremaps a single page.
set +e
exec > /home/vgpu/resume.log 2>&1
V=/srv/vgpu/VMs
B=/usr/lib/modules/$(uname -r)/build
H=/home/vgpu
PCI=0000:0a:00.0
PROF=nvidia-664
D=/var/lib/vgpu-vm/win-key0
say(){ echo; echo "######## $* ########"; }

say "$(date '+%F %T') resume after power cycle"
echo "  kernel=$(uname -r) subvol=$(findmnt -no SOURCE /) uptime=$(uptime -p)"
echo "  cmdline: $(cat /proc/cmdline)"
echo "  nopat=$(grep -c nopat /proc/cmdline) pci=realloc=$(grep -c 'pci=realloc' /proc/cmdline)"

say "A  kernel build tree intact? (an out-of-tree build deleted these once)"
for f in include/generated/autoconf.h include/generated/rustc_cfg include/config/auto.conf; do
  printf "  %-34s %s\n" "$f" "$(test -e $B/$f && echo present || echo MISSING)"
done
sudo touch $B/include/config/auto.conf $B/include/generated/autoconf.h $B/include/generated/rustc_cfg 2>/dev/null

say "B  protected parent images (must never change)"
for f in /var/lib/vgpu-vm/win-vgpu-wsys53972/win-vgpu-wsys53972.qcow2 \
         /var/lib/vgpu-vm/win-vgpu-test/win-vgpu-test.qcow2; do
  sudo stat -c "  inode=%i size=%s mtime=%y %n" "$f" 2>/dev/null
done
echo "  expect inode=204230 and inode=204233"

say "C  stack state"
echo "  nvidia modules=$(lsmod | grep -c '^nvidia')  kprobes=$(sudo cat /sys/kernel/debug/kprobes/list 2>/dev/null | wc -l)"
echo "  664 avail: $(cat /sys/class/mdev_bus/$PCI/mdev_supported_types/$PROF/available_instances 2>/dev/null)"
echo "  qemu=$(pgrep -cf 'qemu-system-x86_64.*win-key0')"
if [ "$(lsmod | grep -c '^nvidia')" -eq 0 ]; then
  echo "  bringing up the stack"
  bash $H/bringup.sh >/dev/null 2>&1; tail -3 $H/bringup.log | sed 's/^/    /'
fi
echo "  vfio .ko uses vmf_insert_pfn_prot: $(nm -u $V/driver/modules-lts/nvidia-vgpu-vfio.ko 2>/dev/null | grep -c vmf_insert_pfn_prot)"
echo "  conftest targets: $(sudo cat $V/driver/vgpu-merged-build/merged-535.309.01/kernel/conftest/uts_release 2>/dev/null)"

say "D  start the Windows guest if not running"
if [ "$(pgrep -cf 'qemu-system-x86_64.*win-key0')" = "0" ]; then
  U=$(uuidgen)
  echo "$U" | sudo tee /sys/class/mdev_bus/$PCI/mdev_supported_types/$PROF/create >/dev/null
  sleep 3
  [ -e /sys/bus/mdev/devices/$U ] || { echo "  MDEV CREATE FAILED"; exit 1; }
  echo 'loglevel=5,disable_vnc=1' | sudo tee /sys/bus/mdev/devices/$U/nvidia/vgpu_params >/dev/null
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
  sleep 95
fi
echo "  qemu=$(pgrep -cf 'qemu-system-x86_64.*win-key0')  pteblit30s=$(sudo journalctl -t nvidia-vgpu-mgr --since '-30s' --no-pager 2>/dev/null | grep -ci 'Immediate pteblit')"

say "E  build userdpeek"
DU=$V/kmod/userdpeek
sudo mkdir -p $DU
sudo cp -f $H/userdpeek.c $DU/ 2>/dev/null
sudo tee $DU/Makefile >/dev/null <<'MK'
obj-m := userdpeek.o
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
MK
sudo make -C "$B" M="$DU" modules 2>&1 | grep -E "LD \[M\]|error:|Error" | tail -5 | sed 's/^/  /'
[ -f $DU/userdpeek.ko ] || { echo "  BUILD FAILED - stopping"; exit 1; }
echo "  built $(stat -c %s $DU/userdpeek.ko) bytes"

say "F  capture the plugin's USERD virtual address"
PID=$(for p in $(ls /proc | grep -E '^[0-9]+$'); do sudo grep -ql libnvidia-vgpu /proc/$p/maps 2>/dev/null && echo $p; done | head -1)
[ -z "$PID" ] && { echo "  no plugin process"; exit 1; }
BASE=$(sudo grep -m1 libnvidia-vgpu.so /proc/$PID/maps | cut -d- -f1)
PUT=$(printf '%x' $(( 0x$BASE + 0xd897f )))
cat > /tmp/uv.gdb <<GDB
set confirm off
set pagination off
set height 0
break *0x$PUT if \$r8d == 1
commands
silent
printf "USERD_VA=0x%llx\n", \$rax
delete
continue
end
continue
GDB
UVA=$(sudo timeout 50 gdb -q -p $PID -x /tmp/uv.gdb 2>&1 | grep -aoE "USERD_VA=0x[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  pid=$PID USERD_VA=$UVA"
[ -z "$UVA" ] && { echo "  capture failed"; exit 1; }
sudo awk -v t=$((UVA)) '{split($1,a,"-"); s=strtonum("0x"a[1]); e=strtonum("0x"a[2]); if (s<=t && t<e) print "  vma: "$0}' /proc/$PID/maps

say "G  THE TEST: PTE cache bits + USERD read through a fresh UC mapping"
sudo dmesg -C >/dev/null 2>&1
sudo insmod $DU/userdpeek.ko pid=$PID va=$UVA 2>&1 | grep -v "Invalid parameters" | sed 's/^/  insmod: /'
sudo dmesg | grep -a "userdpeek:" | sed 's/^.*userdpeek: /  /'

say "H  interpretation"
echo "  cache idx 0 or 4 = WB  -> stores sit in CPU cache, GPU never sees GP_PUT. THAT IS THE BUG."
echo "  cache idx 3 or 7 = UC  -> mapping is correct; then if our UC read shows GP_PUT=1 the"
echo "                            value is really in the BAR and the GPU is ignoring it."
echo "  GP_PUT=0 via UC read   -> the plugin's store never landed at all."
echo
echo "  stack after: modules=$(lsmod | grep -c '^nvidia') xid=$(sudo journalctl -t nvidia-vgpu-mgr --since '-2min' --no-pager 2>/dev/null | grep -cE 'XID [0-9]+ detected')"
say "resume done"
