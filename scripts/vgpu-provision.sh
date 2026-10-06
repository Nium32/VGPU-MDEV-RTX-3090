#!/bin/bash
# vgpu-provision.sh <vmid> [staging-dir]
#
# Set a Windows guest up from scratch: NVIDIA guest driver, the two registry tuning
# values, QEMU guest agent, Sunshine, the virtual display driver, and the licence
# token. You supply the driver; everything else is fetched or already staged.
#
# Put the NVIDIA vGPU guest driver .exe in the staging directory (default
# /srv/vgpu/staging). Anything else found there is copied in too.
#
# Phases, because they have different requirements:
#   offline - guest stopped: files are copied straight into the image and the
#             registry keys are written to the hive. No agent needed.
#   online  - guest running with the agent answering: installers are run.
#
# The guest agent is the bootstrap problem. An image that has never had it needs
# virtio-win-guest-tools.exe run once by hand through the Proxmox console; after
# that this script needs no console at all. An image that already has it (or a clone
# of one that does) is fully hands-off.
set -uo pipefail

VMID=${1:?usage: $0 <vmid> [staging-dir]}
STAGING=${2:-/srv/vgpu/staging}
GEXEC=${GEXEC:-/srv/vgpu/gexec.sh}
IMAGES=${IMAGES:-/srv/vgpu/pve/images}
DLS=${DLS:-192.168.1.4}
NBD=${NBD:-/dev/nbd8}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -e "/etc/pve/qemu-server/$VMID.conf" ] || { echo "VM $VMID does not exist" >&2; exit 1; }
mkdir -p "$STAGING"

DISK="$IMAGES/$VMID/vm-$VMID-disk-0.qcow2"
[ -r "$DISK" ] || { echo "no disk at $DISK" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- fetch extras
say "staging directory: $STAGING"
fetch() {  # url, filename
    [ -s "$STAGING/$2" ] && { echo "   have $2"; return; }
    echo "   fetching $2"
    curl -sfL -o "$STAGING/$2" "$1" || echo "   could not fetch $2 (continuing)"
}
fetch "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe" virtio-win-guest-tools.exe
SUN=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
      | grep -oE '"browser_download_url": "[^"]+Windows-AMD64-installer\.msi"' | cut -d'"' -f4 || true)
[ -n "$SUN" ] && fetch "$SUN" Sunshine.msi
VDD=https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23
fetch "$VDD/VDD.Control.25.7.23.zip" VDD-Control.zip

DRV=$(find "$STAGING" -maxdepth 1 -iname '*.exe' | grep -iE 'grid|quadro|nvidia|dch' | head -1 || true)
if [ -n "$DRV" ]; then
    echo "   NVIDIA driver: $(basename "$DRV")"
else
    echo "   NOTE: no NVIDIA driver .exe in $STAGING - the guest driver step will be skipped"
fi

# ------------------------------------------------------------- offline phase
say "offline: stopping VM $VMID and copying files in"
qm shutdown "$VMID" --timeout 90 >/dev/null 2>&1 || true
for _ in $(seq 1 50); do [ "$(qm status "$VMID" 2>/dev/null)" = "status: stopped" ] && break; sleep 2; done
[ "$(qm status "$VMID" 2>/dev/null)" = "status: stopped" ] || qm stop "$VMID" >/dev/null 2>&1
sleep 3

WORK=$(mktemp -d); MNT="$WORK/mnt"; mkdir -p "$MNT"
cleanup() {
    if mountpoint -q "$MNT"; then umount "$MNT" || true; fi
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT
modprobe nbd max_part=16
qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
qemu-nbd --connect="$NBD" "$DISK"; sleep 2
PART=$(lsblk -bnro NAME,SIZE "$NBD" | awk 'NR>1{print $1, $2}' | sort -k2 -n | tail -1 | cut -d' ' -f1)
mount -t ntfs3 "/dev/$PART" "$MNT" 2>/dev/null \
  || ntfs-3g -o remove_hiberfile "/dev/$PART" "$MNT" 2>/dev/null \
  || mount "/dev/$PART" "$MNT"
case ",$(findmnt -no OPTIONS "$MNT")," in
    *,ro,*) echo "guest filesystem mounted read-only - aborting" >&2; exit 1 ;;
esac

mkdir -p "$MNT/vgpu-setup"
cp "$STAGING"/* "$MNT/vgpu-setup/" 2>/dev/null || true
printf "   copied: %s file(s) to C:\\\\vgpu-setup\n" "$(find "$MNT/vgpu-setup" -type f | wc -l)"
umount "$MNT"; qemu-nbd --disconnect "$NBD" >/dev/null 2>&1

# The two tuning values must exist on whichever display-class subkey Windows binds.
"$(dirname "$0")/pve-fix-nvidia-regkeys.sh" "$DISK" 2>&1 | sed 's/^/   /'

say "starting VM $VMID"
qm start "$VMID" >/dev/null 2>&1
for _ in $(seq 1 60); do qm agent "$VMID" ping >/dev/null 2>&1 && break; sleep 5; done
if ! qm agent "$VMID" ping >/dev/null 2>&1; then
    cat <<EOF

The guest agent is not answering, so the install phase cannot run.
Open the Proxmox console for VM $VMID and run, once:
    C:\\vgpu-setup\\virtio-win-guest-tools.exe
reboot the guest, then run this script again. Everything else is already staged.
EOF
    exit 1
fi
echo "   agent is up"

# -------------------------------------------------------------- online phase
run_guest() { "$GEXEC" "$VMID"; }

say "installing in the guest (this takes a few minutes)"
run_guest <<'PS'
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$s = "C:\vgpu-setup"

$drv = Get-ChildItem $s -Filter *.exe -EA 0 | Where-Object { $_.Name -match 'grid|quadro|nvidia|dch' } | Select-Object -First 1
if ($drv) {
  "installing NVIDIA driver: $($drv.Name)"
  Start-Process -FilePath $drv.FullName -ArgumentList '-s','-noreboot','-clean' -Wait -NoNewWindow
} else { "no NVIDIA driver staged, skipped" }

if (Test-Path "$s\Sunshine.msi") {
  "installing Sunshine"
  Start-Process msiexec -ArgumentList '/i',"$s\Sunshine.msi",'/qn' -Wait -NoNewWindow
}

if (Test-Path "$s\VDD-Control.zip") {
  "installing virtual display driver"
  New-Item -ItemType Directory -Force -Path C:\VDDControl | Out-Null
  Expand-Archive -Path "$s\VDD-Control.zip" -DestinationPath C:\VDDControl -Force
  $dst = "C:\VirtualDisplayDriver"
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item "C:\VDDControl\SignedDrivers\x86\VDD\*" $dst -Force
  $sig = Get-AuthenticodeSignature "$dst\mttvdd.cat"
  if ($sig.SignerCertificate) {
    foreach ($store in 'Root','TrustedPublisher') {
      $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($store,'LocalMachine')
      $st.Open('ReadWrite'); $st.Add($sig.SignerCertificate); $st.Close()
    }
  }
  $x = "$dst\vdd_settings.xml"
  $c = Get-Content $x -Raw
  $c = $c -replace '<friendlyname>default</friendlyname>','<friendlyname>NVIDIA RTXA5000-8Q</friendlyname>'
  $c = $c -replace '<refresh_rate>30</refresh_rate>','<refresh_rate>120</refresh_rate>'
  Set-Content -Path $x -Value $c -Encoding UTF8
  & C:\VDDControl\Dependencies\devcon.exe remove "Root\MttVDD" 2>&1 | Out-Null
  pnputil /add-driver "$dst\MttVDD.inf" /install 2>&1 | Out-Null
  & C:\VDDControl\Dependencies\devcon.exe install "$dst\MttVDD.inf" "Root\MttVDD" 2>&1 | Out-Null
}
"install phase done"
PS

say "clock (licensing fails silently if this is wrong)"
run_guest <<PS
tzutil /s "Eastern Standard Time"
Set-Service -Name w32time -StartupType Automatic
w32tm /config /manualpeerlist:"$DLS,0x8 time.windows.com,0x9" /syncfromflags:manual /reliable:yes /update | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config" /v MaxPosPhaseCorrection /t REG_DWORD /d 0xFFFFFFFF /f | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config" /v MaxNegPhaseCorrection /t REG_DWORD /d 0xFFFFFFFF /f | Out-Null
Restart-Service w32time -Force
w32tm /resync /force 2>&1 | Out-Null
"guest utc now: {0}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss')
PS
echo "   host  utc now: $(date -u '+%H:%M:%S')"
"$(dirname "$0")/vgpu-guest-timesync.sh" >/dev/null 2>&1 || true

say "licence token"
run_guest <<PS
\$dir = "C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken"
if (Test-Path \$dir) {
  New-Item -ItemType Directory -Force -Path C:\token-archive | Out-Null
  Get-ChildItem \$dir -File -EA 0 | ForEach-Object { Move-Item \$_.FullName C:\token-archive -Force -EA 0 }
  \$out = Join-Path \$dir ("client_configuration_token_" + (Get-Date -f 'dd-MM-yy-HH-mm-ss') + ".tok")
  & curl.exe --insecure -L -s "https://$DLS/-/client-token" -o \$out
  Restart-Service NVDisplay.ContainerLocalSystem -Force
  "token: {0} bytes" -f (Get-Item \$out -EA 0).Length
} else { "licensing directory absent - is the NVIDIA driver installed?" }
PS

say "result"
sleep 30
run_guest <<'PS'
Get-CimInstance Win32_VideoController | ForEach-Object {
  "   {0} | err={1}" -f $_.Name, $_.ConfigManagerErrorCode
}
& "C:\Windows\System32\nvidia-smi.exe" -q 2>&1 | Select-String 'License Status' | Select-Object -First 1
PS
echo
echo "Done. If the GPU shows err=43, reboot the guest once: the driver binds a new"
echo "display-class subkey on first sight of the card and the tuning keys land on reboot."