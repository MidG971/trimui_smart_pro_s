#!/bin/sh
# Boot rumble: 3 s of vibration at startup, alongside the fan chirp.
set -u
exec python3 - << 'PYEOF'
import glob, os, time, fcntl, ctypes, struct

class Trigger(ctypes.Structure):
    _fields_ = [('button', ctypes.c_uint16), ('interval', ctypes.c_uint16)]
class Replay(ctypes.Structure):
    _fields_ = [('length', ctypes.c_uint16), ('delay', ctypes.c_uint16)]
class Envelope(ctypes.Structure):
    _fields_ = [('attack_length', ctypes.c_uint16), ('attack_level', ctypes.c_uint16),
                ('fade_length', ctypes.c_uint16), ('fade_level', ctypes.c_uint16)]
class Periodic(ctypes.Structure):
    _fields_ = [('envelope', Envelope), ('period', ctypes.c_uint16), ('magnitude', ctypes.c_int16),
                ('offset', ctypes.c_int16), ('phase', ctypes.c_uint16), ('custom_len', ctypes.c_uint16),
                ('custom', ctypes.c_void_p)]
class Rumble(ctypes.Structure):
    _fields_ = [('strong_magnitude', ctypes.c_uint16), ('weak_magnitude', ctypes.c_uint16)]
class U(ctypes.Union):
    _fields_ = [('rumble', Rumble), ('periodic', Periodic)]
class Effect(ctypes.Structure):
    _fields_ = [('type', ctypes.c_uint16), ('id', ctypes.c_int16), ('direction', ctypes.c_uint16),
                ('trigger', Trigger), ('replay', Replay), ('u', U)]

EV_FF, FF_RUMBLE = 0x15, 0x50
def ioc(d, nr, sz): return (d << 30) | (sz << 16) | (ord('E') << 8) | nr
print('sizeof(ff_effect) =', ctypes.sizeof(Effect), flush=True)
EVIOCSFF = ioc(1, 0x80, ctypes.sizeof(Effect))
EVIOCRMFF = ioc(1, 0x81, 2)

dev = devname = None
for p in sorted(glob.glob('/dev/input/event*')):
    name = open('/sys/class/input/%s/device/name' % os.path.basename(p)).read().strip()
    if any(k in name.lower() for k in ('vibra', 'motor', 'rumble', 'trimui')):
        dev, devname = p, name
        break
if not dev:
    print('rumble-boot: no FF device', flush=True); raise SystemExit(0)

eff = Effect()
eff.type = FF_RUMBLE; eff.id = -1
eff.replay.length = 3000
eff.u.rumble.strong_magnitude = 0x7FFF
eff.u.rumble.weak_magnitude = 0x7FFF
f = os.open(dev, os.O_RDWR)
fcntl.ioctl(f, EVIOCSFF, eff)   # pass struct by ref: kernel fills eff.id
eid = eff.id
print('rumble-boot: uploaded effect id', eid, 'on', dev, devname, flush=True)
os.write(f, struct.pack('<QQHHi', 0, 0, EV_FF, eid, 1))
print('rumble-boot: playing 3s', flush=True)
time.sleep(3)
try:
    os.write(f, struct.pack('<QQHHi', 0, 0, EV_FF, eid, 0))
    fcntl.ioctl(f, EVIOCRMFF, struct.pack('<H', eid))
except OSError:
    pass
os.close(f)
PYEOF
