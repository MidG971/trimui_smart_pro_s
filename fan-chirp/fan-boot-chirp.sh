#!/bin/bash
# fan-boot-chirp — spin the cooling fan hard for ~3s at boot.
#
# Why: the panel can't yet serve as a power indicator, so a fan that audibly
# spins is how you tell the device is ON. The DTB sets a quiet always-on floor
# (pwm 96, ~37%) via &pwm_fan cooling-levels[0], but 96 may sit at/under the
# fan's stiction threshold from a dead stop. This one-shot kicks the fan to its
# max cooling state for ~3s to (a) break stiction so the floor reliably sustains,
# and (b) give an unmistakable "it's on" signal at every boot.
#
# After the kick we release control; the thermal governor resumes and holds the
# DTB floor whenever the SoC is cool, ramping up on the 60/72/85 C trips.
set -u

find_fan() {
	local c
	# Prefer a cooling device whose type names the fan.
	for c in /sys/class/thermal/cooling_device*; do
		[ -r "$c/type" ] || continue
		if grep -qi fan "$c/type" 2>/dev/null; then echo "$c"; return 0; fi
	done
	# Fallback: our pwm-fan has 6 cooling-levels -> max_state 5.
	for c in /sys/class/thermal/cooling_device*; do
		[ -r "$c/max_state" ] || continue
		if [ "$(cat "$c/max_state" 2>/dev/null)" = "5" ]; then echo "$c"; return 0; fi
	done
	return 1
}

CD=$(find_fan) || { logger -t fan-boot-chirp "no fan cooling device found"; exit 0; }
MAX=$(cat "$CD/max_state" 2>/dev/null || echo 5)
logger -t fan-boot-chirp "kicking $(cat "$CD/type" 2>/dev/null) ($CD) to state $MAX for ~3s"

# Re-assert the max state every 0.3s for ~3s: the thermal governor polls once a
# second and would otherwise drop us back to the floor between our writes.
i=0
while [ "$i" -lt 10 ]; do
	echo "$MAX" > "$CD/cur_state" 2>/dev/null || true
	sleep 0.3
	i=$((i + 1))
done

# Return to state 0 = the DTB cooling-levels floor. This is REQUIRED: the thermal
# governor only rewrites cur_state when its own computed target changes, so after
# our manual kick it will NOT re-assert the floor on its own — without this the fan
# would stay pinned at max until the next trip crossing. When the SoC later warms
# past a trip, the governor takes over and ramps up again.
# (HW note 2026-10-16: the current floor pwm 96/~37% does not reliably sustain spin
# from a stop on this fan, so the boot chirp above is the dependable power-on signal;
# raise the DTB floor toward the measured sustain duty to also get a steady idle spin.)
echo 0 > "$CD/cur_state" 2>/dev/null || true
exit 0
