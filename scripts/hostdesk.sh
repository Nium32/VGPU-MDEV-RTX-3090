#!/bin/bash
# Bring up a real X11 server + KDE on the vGPU host, CONCURRENTLY with the vGPU guest.
#
# The 3090 is owned by the vgpu-kvm RM, which exposes no KMS connectors, so physical scanout
# is impossible (see the elimination list in memory). This uses the dummy video driver, so X
# touches no GPU hardware at all and cannot disturb the guest. GL is llvmpipe (software).
# Viewable over VNC on 5901.
set +e
exec > /home/vgpu/hostdesk.log 2>&1
say(){ echo; echo "######## $* ########"; }
say "$(date '+%F %T') host X11 desktop"

sudo systemctl stop plasmalogin 2>/dev/null
pkill -f "x11vnc -display :1" 2>/dev/null
pkill -f "Xorg :1" 2>/dev/null; sudo pkill -f "X :1" 2>/dev/null
sleep 2

say "A  start X on :1 with the dummy driver"
setsid sudo X :1 -config /etc/X11/xorg-dummy.conf -logfile /tmp/xdummy.log -noreset >/dev/null 2>&1 &
sleep 6
echo "  X procs: $(pgrep -cf 'X :1')"
sudo grep -aE "\(EE\)|dummy|Screen|Fatal|NOUVEAU|modeset" /tmp/xdummy.log 2>/dev/null | head -10 | sed 's/^/    /'
export DISPLAY=:1
echo "  xdpyinfo: $(DISPLAY=:1 xdpyinfo 2>/dev/null | grep -E 'dimensions|depth of root' | tr '\n' ' ')"

say "B  start KDE (X11 session) as vgpu"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
setsid env DISPLAY=:1 XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR XDG_SESSION_TYPE=x11 \
      dbus-run-session startplasma-x11 >/home/vgpu/plasma.log 2>&1 &
sleep 25
echo "  kwin_x11=$(pgrep -cf kwin_x11) plasmashell=$(pgrep -cf plasmashell) ksmserver=$(pgrep -cf ksmserver)"
tail -4 /home/vgpu/plasma.log 2>/dev/null | cut -c1-140 | sed 's/^/    /'

say "C  expose it over VNC on 5901"
# -localhost no is INVALID and makes x11vnc exit silently; use -bg instead
setsid x11vnc -display :1 -rfbport 5901 -forever -shared -rfbauth "$HOME/.vnc/passwd" -bg -o /home/vgpu/x11vnc.log >/dev/null 2>&1
sleep 4
echo "  x11vnc: $(pgrep -cf 'x11vnc -display :1')"
ss -ltn 2>/dev/null | grep -E "5901" | sed 's/^/    /'
sudo ufw allow from <your-subnet>/24 to any port 5901 proto tcp comment 'vGPU host KDE over VNC' >/dev/null 2>&1
sudo ufw status 2>/dev/null | grep 5901 | sed 's/^/    /'

say "D  VERDICT - X11 and the VM at the same time?"
MARK=$(cat /tmp/mark.txt 2>/dev/null); J(){ sudo journalctl -t nvidia-vgpu-mgr --since "$MARK" --no-pager 2>/dev/null; }
echo "  HOST X11 : X=$(pgrep -cf 'X :1') kwin_x11=$(pgrep -cf kwin_x11) plasmashell=$(pgrep -cf plasmashell) vnc=$(pgrep -cf 'x11vnc -display :1')"
echo "  GL renderer: $(DISPLAY=:1 glxinfo 2>/dev/null | grep -m1 'OpenGL renderer' || echo 'glxinfo not installed')"
echo "  GUEST    : qemu=$(pgrep -cf 'qemu-system-x86_64.*win-key0') guestdrv=$(J|grep -c 'Guest NVIDIA Driver') pteblit=$(J|grep -ci 'Immediate pteblit') errors=$(J|grep -c 'error:') xid=$(J|grep -cE 'XID [0-9]+ detected')"
python3 - <<'PY' 2>/dev/null
import socket
try:
    s=socket.create_connection(("127.0.0.1",3390),timeout=6); s.settimeout(6)
    s.sendall(bytes.fromhex("030000130ee000000000000100080003000000"))
    print("  guest RDP:", s.recv(64).hex()[:40]); s.close()
except Exception as e: print("  guest RDP: no reply (%s)" % e)
PY
say hostdesk done
