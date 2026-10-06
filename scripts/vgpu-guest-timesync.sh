#!/bin/bash
# vgpu-guest-timesync.sh - keep Windows guests' clocks matched to the host.
#
# Why this exists: the guests run with localtime=1, so they read the host RTC as
# local time. If the guest timezone and the host zone ever disagree the guest's UTC
# is wrong by the difference, and w32time on at least one guest cannot reach a time
# source at all ("no time data was available", Source: Local CMOS Clock).
#
# A skewed guest clock silently breaks vGPU licensing: the DLS token is time-signed,
# so the client loops on /auth/v1/origin and never gets a lease, and the vGPU drops
# to Unlicensed (Restricted) - which throttles the GPU hard. A 3 hour skew cost a
# whole debugging session, so this checks and corrects rather than trusting it.
#
# Uses the guest agent to READ the guest clock (get-time, nanoseconds) and PowerShell
# via the agent to SET it; qm does not expose the agent's set-time verb.
set -uo pipefail

MAX_SKEW=${MAX_SKEW:-3}          # seconds tolerated before correcting
GEXEC=${GEXEC:-/srv/vgpu/gexec.sh}
LOG=${LOG:-/var/log/vgpu-timesync.log}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

mapfile -t VMS < <(grep -ls '^hostpci0:.*mdev=' /etc/pve/qemu-server/*.conf 2>/dev/null \
                   | xargs -r -n1 basename | sed 's/\.conf$//' | sort -n)

for v in "${VMS[@]:-}"; do
    [ -n "$v" ] || continue
    [ "$(qm status "$v" 2>/dev/null)" = "status: running" ] || continue
    qm agent "$v" ping >/dev/null 2>&1 || { log "vm$v agent not responding"; continue; }

    gns=$(qm guest cmd "$v" get-time 2>/dev/null | tr -dc '0-9')
    [ -n "$gns" ] || { log "vm$v get-time returned nothing"; continue; }

    gsec=$(( gns / 1000000000 ))
    hsec=$(date -u +%s)
    skew=$(( gsec - hsec ))
    [ "$skew" -lt 0 ] && askew=$(( -skew )) || askew=$skew

    if [ "$askew" -le "$MAX_SKEW" ]; then
        log "vm$v ok (skew ${skew}s)"
        continue
    fi

    log "vm$v SKEW ${skew}s - correcting"
    utc=$(date -u '+%Y-%m-%d %H:%M:%S')
    "$GEXEC" "$v" <<PS >/dev/null 2>&1
\$u = [DateTime]::SpecifyKind([DateTime]::ParseExact('$utc','yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
Set-Date -Date \$u.AddSeconds(1).ToLocalTime() | Out-Null
PS
    sleep 2
    gns2=$(qm guest cmd "$v" get-time 2>/dev/null | tr -dc '0-9')
    if [ -n "$gns2" ]; then
        skew2=$(( gns2 / 1000000000 - $(date -u +%s) ))
        log "vm$v corrected, skew now ${skew2}s"
    fi
done