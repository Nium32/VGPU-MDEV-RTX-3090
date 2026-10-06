# vGPU licensing, and the throttle that looks like a hardware fault

An unlicensed NVIDIA vGPU does not fail loudly. It runs at full speed for a grace
period, then drops to a restricted mode and throttles the GPU hard. On the reference
machine a game went from **60 fps to 15 fps** with the host GPU sitting at 1–7 %
utilisation — nothing saturated, nothing in `dmesg`, no Xid. It reads exactly like a
driver or display bug, and it is neither.

The one line that tells you:

```bash
# in the guest
nvidia-smi -q | grep -A3 'vGPU Software Licensed Product'
```

```
Product Name   : NVIDIA RTX Virtual Workstation
License Status : Unlicensed (Restricted)      <- throttled
License Status : Unlicensed (Unrestricted)    <- full speed, grace period running
License Status : Licensed (Expiry: ...)       <- what you want
```

**Check this first** whenever performance collapses for no visible reason. It cost a
long afternoon here, chased through the display stack and the encoder, before anyone
looked at the licence state.

---

## The approach used here

Self-hosted [FastAPI-DLS](https://git.collinwebdesigns.de/oscar.krause/fastapi-dls)
on the Proxmox host, with the guests pointed at it. This follows
[this gist](https://gist.github.com/sovajri7/fb594c49fa97f00216786f190933b39a),
which is the clearest end-to-end write-up of the method; the sections below record
what actually happened on this hardware, including the parts that did not go the way
the guide expects.

The machine here is a consumer RTX 3090 presented as an RTX A5000 through
`vgpu_unlock`, so no NVIDIA entitlement applies to it. If you *do* hold a real
entitlement, point the guests at NVIDIA's CLS instead — it issues a genuine lease
and none of this is needed.

### 1. Host: run the DLS

```bash
apt-get install -y docker.io
install -d /opt/fastapi-dls/cert && cd /opt/fastapi-dls/cert

openssl genrsa -out instance.private.pem 2048
openssl rsa -in instance.private.pem -outform PEM -pubout -out instance.public.pem
```

The webserver certificate **must carry a Subject Alternative Name**. A certificate
with only a Common Name is rejected by modern TLS stacks, and the failure is silent —
the client simply never progresses. Generate it from a config file:

```ini
# san.cnf
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = <host-ip>
[v3]
subjectAltName   = @alt
basicConstraints = critical,CA:TRUE
keyUsage         = critical,digitalSignature,keyCertSign,keyEncipherment
extendedKeyUsage = serverAuth
[alt]
IP.1 = <host-ip>
```

```bash
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout webserver.key -out webserver.crt -config san.cnf

docker run -d --name fastapi-dls --restart unless-stopped \
    -e DLS_URL=<host-ip> -e DLS_PORT=443 -e TZ=<your-tz> \
    -p 443:443 \
    -v /opt/fastapi-dls/cert:/app/cert \
    -v dls-db:/app/database \
    collinwebdesigns/fastapi-dls:latest
```

Confirm it is healthy before touching a guest:

```bash
docker ps --filter name=fastapi-dls     # expect "Up ... (healthy)"
```

### 2. Guest: install the token

```powershell
$dir = "C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken"
curl.exe --insecure -L "https://<host-ip>/-/client-token" `
    -o "$dir\client_configuration_token_$(Get-Date -f 'dd-MM-yy-HH-mm-ss').tok"
Restart-Service NVDisplay.ContainerLocalSystem
```

Clear out any older `.tok` files first. Several stale tokens in that directory is a
needless variable when something goes wrong.

### 3. Verify the handshake, not just the status line

Watch the server while the guest restarts its licensing service:

```bash
docker logs -f fastapi-dls
```

A **successful** acquisition walks the whole sequence:

```
POST /auth/v1/origin           200 OK
POST /auth/v1/code             200 OK
POST /auth/v1/token            200 OK
GET  /leasing/v1/lessor/leases 200 OK
POST /leasing/v1/lessor        200 OK   <- the lease
```

A **failing** one loops on `origin` forever and never reaches `code`. If that is what
you see, the cause is almost certainly the clock — see below.

---

## The clock is the thing that breaks this

DLS tokens are time-signed. A guest whose clock disagrees with the server fails
validation and retries `origin` indefinitely, with no error that names time anywhere
in the chain.

On the reference machine the guest was **three hours ahead in UTC**:

```
HOST  utc : 2026-10-06 15:29:17
GUEST utc : 2026-10-06 18:29:17
GUEST tz  : Pacific Standard Time
Source: Local CMOS Clock      Last Successful Sync Time: unspecified
```

Two separate faults stacked:

* The VM runs with `localtime 1`, so the guest reads the host RTC as *local* time. The
  host keeps Eastern; the guest believed Pacific. Its UTC was therefore wrong by the
  zone difference.
* `w32time` had never synced once, and would not: `w32tm /resync` returned
  `The computer did not resync because no time data was available`.

The second fault has a non-obvious cause. **Windows refuses to correct a clock that is
off by more than a default threshold**, and simply gives up rather than saying so. A
three-hour error exceeds it. Raising the limits is what finally let it sync:

```powershell
tzutil /s "<same zone as the host>"
Set-Service -Name w32time -StartupType Automatic
w32tm /config /manualpeerlist:"<gateway>,0x8 time.windows.com,0x9" `
      /syncfromflags:manual /reliable:yes /update
reg add "HKLM\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" `
    /v SpecialPollInterval /t REG_DWORD /d 900 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config" `
    /v MaxPosPhaseCorrection /t REG_DWORD /d 0xFFFFFFFF /f
reg add "HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config" `
    /v MaxNegPhaseCorrection /t REG_DWORD /d 0xFFFFFFFF /f
Restart-Service w32time
w32tm /resync /force
```

Compare **UTC on both sides**, not local time — a timezone difference and a real skew
look identical otherwise:

```bash
date -u '+%Y-%m-%d %H:%M:%S'                      # host
```
```powershell
(Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')   # guest
```

Because `w32time` is trigger-started and can still fail to reach a source,
[`scripts/vgpu-guest-timesync.sh`](../scripts/vgpu-guest-timesync.sh) runs on the host
from a timer, reads each guest's clock through the QEMU guest agent and corrects any
that drifts. Two independent layers, because the failure is silent and expensive.

---

## What did not work, so you can skip it

The guide offers a driver patch for the case where a guest registers but never gets a
lease. On this hardware that was a dead end, and the clock was the real cause.

| Attempt | Result |
|---|---|
| Certificate with SAN | Correct and necessary, but did not by itself fix it |
| Importing the DLS cert into the guest's `LocalMachine\Root` and `\CA` | **No effect.** NVIDIA pins its own CA inside the driver, not the Windows store |
| `gridd-unlock-patcher` 1.1 against `nvxdapix.dll` from driver **539.72** | **Failed:** `Failed to find the hardcoded NLS certificates!` — produced a byte-identical file |
| Prebuilt patched `nvxdapix.dll` | Not viable: the published one targets driver 573.39 (vGPU 18.x), which will not negotiate with a 535 host |
| **Fixing the guest clock** | **This was it.** Lease issued immediately afterwards |

So on vGPU 17.x (`535.x` host, `539.72` guest), no binary patching was needed at all.
If you reach for the patcher first, as happened here, you will waste time on a
component that was never the blocker.

---

## Operational notes

* The licence renews against the DLS roughly every 13 days, and the client token here
  is valid for 12 years. The container must keep running — `--restart unless-stopped`
  covers reboots.
* Losing the DLS does not instantly throttle a guest; it falls back to the grace
  period and only restricts once that expires. That delay is exactly what makes the
  symptom hard to attribute.
* `nvidia-smi vgpu` on the **host** reports `No supported devices in vGPU mode` on an
  unlocked card, because the spoof lives in the `LD_PRELOAD`ed daemons while
  `nvidia-smi` talks to `nvidia.ko`. Read licence state in the guest instead.

## Legal note

This runs a self-hosted reimplementation of NVIDIA's licensing service against
hardware that carries no NVIDIA vGPU entitlement. That is a licensing circumvention,
and it is documented here because the rest of this repository only works with it. If
you hold a real entitlement, use NVIDIA's CLS — it is less work than any of the above.
