#!/bin/bash
# vgpu-stress.sh [cycles]   exercise the paths that have actually broken on this rig.
#
# Each cycle: full recover (stop all, reload stack, start all), then verify every
# guest reaches a usable state - network up, guest agent answering, vGPU with no
# device error, licence Licensed - and that the host logs no Xid and no pte-blit
# failure. Anything that regresses is printed and counted.
set -uo pipefail

CYCLES=${1:-3}
GEXEC=${GEXEC:-/srv/vgpu/gexec.sh}
RECOVER=${RECOVER:-/srv/vgpu/vgpu-recover.sh}
LOG=${LOG:-/var/log/vgpu-stress.log}
# Guests are discovered rather than hardcoded: any VM with a vGPU attached, and its
# current address resolved from its MAC, so this works on any machine.
mapfile -t VMS < <(grep -ls '^hostpci0:.*mdev=' /etc/pve/qemu-server/*.conf 2>/dev/null \
                   | xargs -r -n1 basename | sed 's/\.conf$//' | sort -n)

guest_ip() {
    local mac
    mac=$(sed -n 's/^net0: .*=\([0-9A-Fa-f:]*\),bridge.*/\1/p' "/etc/pve/qemu-server/$1.conf" 2>/dev/null | head -1)
    [ -n "$mac" ] || return
    ip neigh | grep -i "$mac" | grep -v FAILED | awk '{print $1}' | head -1
}

pass=0; fail=0
say() { printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
bad() { say "    FAIL: $*"; fail=$((fail+1)); }
ok()  { say "    ok  : $*"; pass=$((pass+1)); }

xid_before=$(dmesg | grep -ci xid || true)

for c in $(seq 1 "$CYCLES"); do
    say "== cycle $c/$CYCLES =="
    mark=$(date '+%Y-%m-%d %H:%M:%S')

    "$RECOVER" >/dev/null 2>&1

    for v in "${VMS[@]}"; do
        if [ "$(qm status "$v" 2>/dev/null)" = "status: running" ]; then
            ok "vm$v running"
        else
            bad "vm$v not running"
        fi
    done

    # Give Windows time to boot before judging it.
    for _ in $(seq 1 40); do
        up=0
        for v in "${VMS[@]}"; do
            if ping -c1 -W1 "$(guest_ip "$v")" >/dev/null 2>&1; then up=$((up+1)); fi
        done
        if [ "$up" -eq 2 ]; then break; fi
        sleep 5
    done
    sleep 90

    for v in "${VMS[@]}"; do
        if ping -c1 -W2 "$(guest_ip "$v")" >/dev/null 2>&1; then ok "vm$v network"; else bad "vm$v network down"; fi
        if qm agent "$v" ping >/dev/null 2>&1; then ok "vm$v agent"; else bad "vm$v agent dead"; fi

        out=$("$GEXEC" "$v" <<'PS' 2>/dev/null
$g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*NVIDIA*' }
"ERR={0}" -f $g.ConfigManagerErrorCode
$l = & "C:\Windows\System32\nvidia-smi.exe" -q 2>&1 | Select-String 'License Status'
"LIC={0}" -f ($l -replace '.*:\s*','')
PS
)
        if printf '%s' "$out" | grep -q 'ERR=0'; then
            ok "vm$v gpu err=0"
        else
            bad "vm$v gpu $(printf '%s' "$out" | grep -o 'ERR=[0-9]*' | head -1)"
        fi
        if printf '%s' "$out" | grep -qi 'LIC=Licensed'; then
            ok "vm$v licensed"
        else
            bad "vm$v $(printf '%s' "$out" | grep -o 'LIC=.*' | head -1)"
        fi
    done

    newxid=$(dmesg | grep -ci xid || true)
    if [ "$newxid" -le "$xid_before" ]; then
        ok "no new Xid"
    else
        bad "Xid went $xid_before -> $newxid"
        xid_before=$newxid
    fi

    pte=$(journalctl -u nvidia-vgpu-mgr --since "$mark" --no-pager 2>/dev/null | grep -ci 'pte blit' || true)
    if [ "$pte" -eq 0 ]; then ok "no pte-blit failure"; else bad "$pte pte-blit errors"; fi
done

say "== result: $pass passed, $fail failed over $CYCLES cycle(s) =="
[ "$fail" -eq 0 ]