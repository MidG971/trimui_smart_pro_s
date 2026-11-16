#!/bin/sh
# Off-mode charge check: AXP717 powers on from VBUS by efuse customization
# (datasheet 6.5.4.1), so a charger plug wakes the SoC. REG 0x20 (PWRON status)
# bits 1..3 = VBUS insert / BAT>3.3V charging / BAT insert (charger-related).
# If woken by charger (and not by POK), divert to the minimal offcharge target.
R=$(i2cget -f -y 0 0x34 0x20 2>/dev/null || echo 0x00)
V=$((R & 0x0E))
if [ "$V" -ne 0 ]; then
    echo "offcharge: woken by charger (reg20=$R)" >> /run/offcharge.log
    touch /run/offcharge
    systemctl isolate offcharge.target
else
    echo "offcharge: normal boot (reg20=$R)" >> /run/offcharge.log
fi
