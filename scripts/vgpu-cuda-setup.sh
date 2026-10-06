#!/bin/bash
# Apply the WORKING CUDA-on-vGPU host configuration. Idempotent, safe to re-run.
#
# One RTX 3090 (GA102, 10de:2204 spoofed to DEV_2231/A5000). The Linux host keeps the
# GPU; a Linux guest receives an NVIDIA mediated (mdev, non-SR-IOV) vGPU. Host RM is
# monolithic/legacy, GSP off, driver 535.309.01, profile nvidia-664 (RTXA5000-8Q).
#
# Verified 2026-10-02 on exactly this module set:
#   STRONG-VALIDATION-PASS  real PTX kernels JIT and execute; 4M-element fill verified
#                           element by element; DtoD copy + second kernel verified
#   CTXCHURN-PASS           60 context create/destroy rounds, 8 streams each, 0 failures
#   SOAK-PASS               200 iterations, 100x read-modify-write accumulate exact,
#                           4 concurrent streams, second concurrent context verified
#   ENDURANCE-PASS          7237 MiB single alloc full-range verified; 34609 kernel
#                           iterations over 300 s, 0 fails
#   HtoD 11.1 / DtoH 10.0 GiB/s; zero Xid, zero host oops, zero guest lockups
#
# THE ENTIRE HOST-SIDE INTERVENTION IS NOW ONE KPROBE:
#   zfmulti _nv042311rm+0x28 ZF=1   FIX 1. _nv042311rm is an ISR event-0xe handler; the
#                                   suppressed jne otherwise reaches a FIFO vtable call
#                                   at fifo+0x410 with (pGpu, pFifo, 0xd334df00,
#                                   bDisable=1, bPreempt=1). Measured without it: 572 GR
#                                   runlist disables with ZERO re-enables in 70 s, which
#                                   is what made cuCtxCreate_v2 spin forever.
#   mdguest apply=1                 PCI-ID spoofing for the mdev stack.
# No forged return values. No binary patching. No fence or BLOCK poking.
#
# DELIBERATELY NOT LOADED, all three were needed only by OLDER configurations and are
# vestigial AND harmful now. Do not re-add any of them:
#   skipfn  _nv022681rm  - made it return NV_FALSE, so the TSG preempt helper
#       _nv022694rm took its error path after already clearing channel-group state bit 0
#       at +0x138 (_nv032642rm) while the paired setter in _nv022696rm+0x10e was skipped.
#       The only reader of that bit is channel construct (_nv015983rm), which then
#       pre-incremented the new channel disableRefCount so it was born disabled. Symptom:
#       context recycling died with cuCtxCreate rc=999 on the second round, and RMCTRL
#       0xa06c0105 failed 0xffff on every run. Removing skipfn fixed both.
#   retzero _nv046812rm  - masked that handler's 0xffff. With skipfn gone the handler
#       returns 0x0 natively (observed: "orig_ret=0x0 -> 0x0"), so the mask was only ever
#       papering over the skipfn breakage.
#   promotedrop, nvzf, skipinsn, RMInstLoc - all retired.
#
# Guest must have, and nothing else:
#   NVreg_RegistryDwords="RmRcWatchdog=0;RMSetClientRMAllocatedCtxBuffer=0"
# NO RMInstLoc (GR context must stay in vidmem; every sysmem value dies at
# ALLOC_OBJECT 0x1a).
set +e
test "$(uname -r)" = "5.15.95-051595-generic" || { echo "wrong kernel: $(uname -r)"; exit 0; }
grep -qE '^nvidia ' /proc/modules || { echo "nvidia not loaded; run /usr/local/sbin/vgpu535-515-load first"; exit 1; }

# never leave a retired or harmful probe behind
sudo rmmod skipfn retzero skipinsn promotedrop nvzf 2>/dev/null

load() {
    local path="$1" name="$2"; shift 2
    if lsmod | grep -qE "^$name "; then echo "= $name already loaded"; return 0; fi
    if sudo insmod "$path" "$@" 2>/dev/null; then echo "+ $name"; else echo "! $name FAILED"; return 1; fi
}

load /home/user/zfmulti/zfmulti.ko zfmulti spec="_nv042311rm+0x28:1"
load /home/user/mdguest/mdguest.ko mdguest apply=1

echo "--- state ---"
lsmod | grep -E "^(zfmulti|mdguest) " | awk '{print "  "$1}'
for bad in skipfn retzero skipinsn promotedrop nvzf; do
    lsmod | grep -qE "^$bad " && echo "  !! $bad is loaded and must not be"
done
sudo dmesg | sed 's/^\[[^]]*\] //' | grep -E "^zfmulti: armed" | tail -2
echo "  mdev 664 avail=$(cat /sys/class/mdev_bus/0000:0a:00.0/mdev_supported_types/nvidia-664/available_instances 2>/dev/null)"
echo "vgpu-cuda-setup: ready"

# --- host CUDA: nvidia-uvm is built in the merged tree but the vgpu loader never
# --- loads it. Without it libcuda returns no device on the host. Additive only.
if ! lsmod | grep -q '^nvidia_uvm'; then
  insmod /home/user/nvbuild535-515/nvidia-uvm.ko 2>/dev/null \
    || modprobe nvidia-uvm 2>/dev/null
fi
UVM_MAJOR=$(awk '$2=="nvidia-uvm"{print $1}' /proc/devices)
if [ -n "$UVM_MAJOR" ]; then
  [ -e /dev/nvidia-uvm ]       || mknod -m 666 /dev/nvidia-uvm       c "$UVM_MAJOR" 0
  [ -e /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c "$UVM_MAJOR" 1
fi
