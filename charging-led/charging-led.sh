#!/bin/sh
# Status LED matrix (ring LED rgb:indicator-0 = logo/status position):
#   plugged & charging -> blink RED (PMIC CHGLED also solid red, hardware)
#   plugged & full     -> solid GREEN
#   on & unplugged     -> solid WHITE (lights the device logo)
LED=/sys/class/leds/rgb:indicator-0
BAT=/sys/class/power_supply/axp20x-battery/status
setled() { echo "$1" > $LED/multi_intensity 2>/dev/null; echo "$2" > $LED/brightness 2>/dev/null; }
while true; do
    S=$(cat $BAT 2>/dev/null)
    case "$S" in
        Charging) setled "255 0 0" 255; sleep 1; setled "255 0 0" 0; sleep 1 ;;
        Full)     setled "0 255 0" 255 ;;
        *)        setled "255 255 255" 255 ;;   # on & unplugged: white logo
    esac
    sleep 1
done
