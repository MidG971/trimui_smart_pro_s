# Status LED matrix (Smart Pro S)

One software status LED (ring `rgb:indicator-0`, the logo position) plus the
PMIC CHGLED (solid red whenever plugged, hardware-driven, now in DT via the
leds-axp20x driver as `red:charging`):

- plugged & charging -> software LED blinks RED, CHGLED solid red
- plugged & full     -> software LED solid GREEN
- on & unplugged     -> software LED solid WHITE (lights the device logo)

Reads /sys/class/power_supply/axp20x-battery/status. HW-verified 2026-11-16.
