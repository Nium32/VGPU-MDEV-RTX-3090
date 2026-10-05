#!/bin/bash
# Install kernel 6.1.71 into @vgpu580 and build the vGPU stack for it.
#
# WHY 6.1: the vGPU 535 host stack works on 5.15.95 (the Ubuntu install on this same machine)
# and fails identically on 6.8.9 and 6.18.52 with the SAME source and the SAME
# libnvidia-vgpu.so (md5 115d8f304c1fd22ba6a93c07ef494940), so the kernel is the variable.
# The boundary is somewhere in (5.15, 6.8]; the vfio_pin_pages signature change in 6.0 is the
# likeliest line. 6.1 is also the LOWEST kernel that can mount this root, because the btrfs
# superblock has compat_ro_flags 0xb including BLOCK_GROUP_TREE, which 5.15 cannot read.
# If 6.1 works we are done with no filesystem surgery; if it fails the 6.0 boundary is
# confirmed and the only remaining options are converting the btrfs or using Ubuntu.
#
# Installs into the @vgpu580 subvolume only. The working "@" CachyOS install is not touched:
# pacman writes to this subvolume's /usr and /boot, and GRUB loads /@vgpu580/boot/... .
set +e

# This replaces the running root's linux-lts. The header promises it only
# touches the experiment subvolume, but nothing enforced that, so running it
# from the working install destroyed that install's kernel.
if ! findmnt -no OPTIONS / 2>/dev/null | grep -q 'subvol=/@vgpu580'; then
    echo "REFUSING: / is not the @vgpu580 subvolume. This would overwrite the"
    echo "          kernel of whichever install is currently booted."
    exit 1
fi
exec > /home/vgpu/k61.log 2>&1
V=/srv/vgpu/VMs
BK=$V/kernel-backup
say(){ echo; echo "######## $* ########"; }
say "$(date '+%F %T') install 6.1.71 + build vGPU stack"

say "A  preserve the installed 5.15.94 kernel bits (pacman will replace linux-lts)"
sudo mkdir -p $BK
for f in /boot/vmlinuz-linux-lts /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts-fallback.img; do
  [ -f "$f" ] && sudo cp -n "$f" "$BK/$(basename $f).5.15.94-1-lts" && echo "  saved $(basename $f)"
done
if [ -d /usr/lib/modules/5.15.94-1-lts ] && [ ! -d $BK/modules-5.15.94-1-lts ]; then
  sudo cp -a /usr/lib/modules/5.15.94-1-lts $BK/modules-5.15.94-1-lts && echo "  saved /usr/lib/modules/5.15.94-1-lts"
fi
echo "  backup dir: $(sudo du -sh $BK 2>/dev/null | cut -f1)"

say "B  install linux-lts 6.1.71 + headers from the Arch archive"
cd /tmp
A=https://archive.archlinux.org/packages/l
sudo pacman -U --noconfirm  \
  "$A/linux-lts/linux-lts-6.1.71-1-x86_64.pkg.tar.zst" \
  "$A/linux-lts-headers/linux-lts-headers-6.1.71-1-x86_64.pkg.tar.zst" 2>&1 | tail -12 | sed 's/^/  /'
echo "  linux-lts now: $(pacman -Q linux-lts 2>/dev/null)"
echo "  /usr/lib/modules dirs: $(ls /usr/lib/modules/ | tr '\n' ' ')"
ls -l /boot/vmlinuz-linux-lts /boot/initramfs-linux-lts.img 2>/dev/null | awk '{print "  "$5" "$9}'

KV=6.1.71-1-lts
B=/usr/lib/modules/$KV/build
echo "  target KV=$KV  build dir exists: $(test -d $B && echo yes || echo NO)"
[ -d "$B" ] || { echo "  NO BUILD DIR - aborting"; exit 1; }

say "C  build the merged-535 tree for $KV (fresh conftest, pristine source)"
T=$V/driver/vgpu-merged-build/merged-535.309.01/kernel
OUT=$V/driver/modules-$KV
cd "$T" || exit 1
sudo rm -rf conftest conftest.h
sudo find . -name '*.o' ! -name 'nv-kernel.o' ! -name 'nv-modeset-kernel.o' -delete 2>/dev/null; sudo find . -name '*.ko' -delete 2>/dev/null
sudo rm -f Module.symvers modules.order
# Do NOT touch these into existence. Kbuild only tests that they exist, so an
# empty pair passes the "Kernel configuration is invalid" check and the whole
# driver then compiles with no CONFIG_* defined: wrong struct layouts, wrong
# conftest answers, a module that loads and oopses. Reinstall the headers.
for _f in "$B/include/config/auto.conf" "$B/include/generated/autoconf.h"; do
    [ -s "$_f" ] || { echo "MISSING or EMPTY: $_f - reinstall the kernel headers"; exit 1; }
done
sudo make -j"$(nproc)" SYSSRC="$B" SYSOUT="$B" KERNEL_UNAME="$KV" \
     NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem" \
     modules > /home/vgpu/k61.raw 2>&1
echo "  make exit=$?"
grep -iE "error:|Error [0-9]" /home/vgpu/k61.raw | head -8 | sed 's/^/    /'
echo "  conftest uts_release: $(sudo cat $T/conftest/uts_release 2>/dev/null)"
sudo mkdir -p "$OUT"
for m in nvidia.ko nvidia-uvm.ko nvidia-vgpu-vfio.ko; do
  [ -f "$T/$m" ] && sudo cp -f "$T/$m" "$OUT/" && echo "  staged $m vermagic=$(modinfo -F vermagic $OUT/$m)"
done

say "D  build helper modules for $KV"
for k in zfmulti mdguest; do
  D=$V/kmod/$k
  sudo make -C "$B" M="$D" clean >/dev/null 2>&1
  sudo make -C "$B" M="$D" modules >/dev/null 2>&1
  if [ -f "$D/$k.ko" ]; then
    sudo cp -f "$D/$k.ko" "$D/$k-$KV.ko"
    echo "  $k-$KV.ko vermagic=$(modinfo -F vermagic $D/$k-$KV.ko)"
  else echo "  $k FAILED"; fi
done

say "E  summary"
echo "  modules dir for bringup: $OUT"
ls -l "$OUT"/*.ko 2>/dev/null | awk '{print "    "$5"  "$9}'
say "k61 done"
