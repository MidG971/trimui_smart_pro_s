#!/bin/sh
# While in off-charge: blink status LED green; power off when VBUS removed;
# full boot when power key pressed.
LED=/sys/class/leds/green:status
while true; do
    VB=$(i2cget -f -y 0 0x34 0x00 2>/dev/null || echo 0x00)
    if [ $((VB & 0x20)) -eq 0 ]; then
        echo "offcharge: VBUS gone -> poweroff" >> /run/offcharge.log
        systemctl poweroff
        exit 0
    fi
    if [ -d "$LED" ]; then echo 255 > $LED/brightness 2>/dev/null; sleep 1; echo 0 > $LED/brightness 2>/dev/null; fi
    sleep 1
done
