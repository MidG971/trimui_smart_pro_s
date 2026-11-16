#!/bin/sh
# Boot rumble: 3 s of vibration at startup, alongside the fan chirp, so the
# user can tell the device is booting in crowded/noisy environments.
# Drives the pwm-vibrator input device (EV_FF) directly.
set -u
DEV=""
for e in /dev/input/event*; do
    n=$(cat "$e" 2>/dev/null </dev/null; true)
    name=$(cat /sys/class/input/$(basename $e)/device/name 2>/dev/null)
    case "$name" in *vibra*|*motor*|*rumble*|*TRIMUI*) caps=$(cat /sys/class/input/$(basename $e)/device/capabilities/ff 2>/dev/null); [ -n "$caps" ] && [ "$((caps & 0x01))" != "0" ] && { DEV=$e; break; };; esac
done
[ -z "$DEV" ] && { echo "rumble-boot: no FF device found" >&2; exit 0; }
python3 - "$DEV" << 'PYEOF'
import sys, time, struct, fcntl, os
# EVIOC: upload FF_RUMBLE effect, play for 3 s, erase
EVIOCGMAGIC=0x40004500
dev = sys.argv[1]
f = os.open(dev, os.O_RDWR)
# find a free effect id via EVIOCGBIT(EV_FF)
import array
ffbits = array.array('H', [0]*8)
fcntl.ioctl(f, 0x40004520, ffbits)  # EVIOCGBIT(EV_FF=0x15, ...) rough; fallback below
# simpler: use ffmemless-style fixed id 0
# struct ff_effect: type(2) id(2) direction(2) trigger(4+4) replay(4+4) u.ff_rumble(strong,weak)
eff = struct.pack('<HHHIHHIIHH', 0x50, 0, 0, 0, 0, 3000, 0, 0x7FFF, 0x7FFF)  # FF_RUMBLE, id0, replay 3000ms
fcntl.ioctl(f, 0x40304580, eff)   # EVIOCSFF
play = struct.pack('<HHI', 0, 0, 1)  # EV_FF, id0, value=1 (play once)
fcntl.ioctl(f, 0x40044581, play)  # EVIOC... write via write()
os.write(f, struct.pack('<HHI', 0x15, 0, 1))
time.sleep(3)
os.write(f, struct.pack('<HHI', 0x15, 0, 0))  # stop
fcntl.ioctl(f, 0x40304581, struct.pack('<H', 0))  # EVIOCRMFF id0
os.close(f)
print("rumble-boot: 3s rumble on", dev)
PYEOF
