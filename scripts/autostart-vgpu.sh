#!/bin/bash
# Restore the vGPU experiment stack and resume the key sweep after a reboot.
# Safe to run repeatedly: every step is idempotent.
set +e
exec >> /home/user/autostart.log 2>&1
echo "=== $(date '+%F %T') autostart ==="
test "$(uname -r)" = "5.15.95-051595-generic" || { echo "wrong kernel: $(uname -r); not touching anything"; exit 0; }
grep -qE '^nvidia ' /proc/modules || /usr/local/sbin/vgpu535-515-load
systemctl is-active --quiet vgpu535-515-vgpud.service || systemctl start vgpu535-515-vgpud.service
systemctl is-active --quiet vgpu535-515-mgr.service   || systemctl start vgpu535-515-mgr.service
sleep 3
echo "mdev types: $(ls /sys/class/mdev_bus/0000:0a:00.0/mdev_supported_types/ 2>/dev/null | wc -l)"
if ! grep -q GRIND-COMPLETE /home/user/grind-results.txt 2>/dev/null; then
    if [ "$(ps -eo args | grep -c '[g]rind.sh')" -eq 0 ]; then
        echo "resuming sweep at $(grep -c '^KEY=' /home/user/grind-results.txt 2>/dev/null) results"
        setsid nohup sudo -u user /home/user/grind.sh < /dev/null >> /home/user/grind.log 2>&1 &
    fi
fi

# Apply the verified CUDA-on-vGPU host module config (idempotent).
sudo -u user bash /home/user/vgpu-cuda-setup.sh || true
