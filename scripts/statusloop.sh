#!/bin/bash
# One status line per minute, so progress can be read cheaply without blocking.
while true; do
  Q=$(pgrep -cf 'qemu-system-x86_64.*win-key0')
  S=$(ps -o etimes= -C qemu-system-x86_64 2>/dev/null | head -1 | tr -d ' ')
  P=$(sudo grep -c 'nvpin:' /sys/kernel/tracing/trace 2>/dev/null)
  F=$(sudo grep -c nvpinf /sys/kernel/tracing/trace 2>/dev/null)
  X=$(sudo dmesg | grep -ci xid)
  R=$(python3 /home/vgpu/rdpprobe.py 2>/dev/null | cut -c1-12)
  U=$(ls /home/vgpu/vgpuhttp/up/ 2>/dev/null | tr '\n' ',')
  printf '%s qemu=%s up=%ss pins=%s pinfail=%s xid=%s rdp=%s uploads=%s\n' \
     "$(date +%H:%M:%S)" "$Q" "$S" "$P" "$F" "$X" "${R:-none}" "${U:-none}"
  sleep 60
done
