#!/bin/sh
# Charging status LED: blink RED while charging, solid GREEN when full, off otherwise.
# Uses ring LED rgb:indicator-0 as the status LED (PMIC CHGLED not in DT yet).
LED=/sys/class/leds/rgb:indicator-0
BAT=/sys/class/power_supply/axp20x-battery/status
setled() { echo "$1" > $LED/multi_intensity 2>/dev/null; echo "$2" > $LED/brightness 2>/dev/null; }
while true; do
    S=$(cat $BAT 2>/dev/null)
    case "$S" in
        Charging)  setled "0 255 0" 255; sleep 1; setled "0 255 0" 0; sleep 1 ;;
        Full)      setled "0 255 0" 255 ;;
        *)         setled "0 0 0" 0 ;;
    esac
    sleep 1
done
