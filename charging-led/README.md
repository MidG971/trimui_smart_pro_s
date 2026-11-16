# Charging status LED

The PMIC's own CHGLED stays solid red whenever the device is plugged in
(hardware-driven, not in DT yet — see the status-led TODO). The ring LED
`rgb:indicator-0` is used as the software status LED: **blink green while
charging, solid green when full**, off otherwise. Reads
/sys/class/power_supply/axp20x-battery/status. HW-verified 2026-11-16.
