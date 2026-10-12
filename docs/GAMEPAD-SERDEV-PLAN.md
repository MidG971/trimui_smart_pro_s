<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
<!-- Copyright (C) 2026 Midgy BALON -->

# Gamepad driver (in-kernel serdev) — status & history

## Where it stands

**Done and working on hardware (2026-10-01):** an in-kernel **serdev** driver merges the two
gamepad microcontrollers into a single virtual Xbox-360 pad ("TRIMUI Player1", `045e:028e`), with
full button/axis mapping and **FF/rumble**. `evtest` passes end-to-end, rumble is felt, and the
module **auto-loads** (installed to `/lib/modules` + `depmod`); the old userspace daemon is disabled.
Driver: `kernel/drivers/gamepad-trimui-smart-pro-s.c`; build wiring (Kconfig/Makefile under
`drivers/input/joystick/`) is `kernel/patches/0038`.

**Hardware:** the pad is **two 19200-baud, RX-only MCUs** — `uart5` (ttyAS5, PK17) and `uart7`
(ttyAS7, PK13) — each carrying half the controls; rumble is a PWM motor the driver owns. (The
side-board only streams once **PK15 +5 V** is enabled — see `ON-DEVICE-FINDINGS.md`.)

**Mapping** (matches the verified stock contract, `GAMEPAD-STOCK-GOAL.md`): D-pad → `ABS_HAT0X/Y`;
L2/R2 → `ABS_Z/RZ` (digital 0/255); sticks → `±32767` with per-axis calibration, a 10 % integer
deadzone, Y inverted. Both serdev instances share one `input_dev` via a kref'd module-level
singleton (serdev children must live under their own UART controller, so they can't share a DT
parent — the singleton keeps it trivial since there is exactly one pad).

## DT (reference)

Serdev children under the two gamepad UARTs (already in the board DTS). A serdev child has **no
`reg`**, and binding it turns the port into a serdev bus — so `/dev/ttyAS5` / `/dev/ttyAS7`
disappear (expected).

```dts
&uart5 {
	pinctrl-names = "default";
	pinctrl-0 = <&uart5_pk17_pin>;
	status = "okay";
	gamepad_left: gamepad {
		compatible = "trimui,smart-pro-s-gamepad-left";
		current-speed = <19200>;
	};
};
&uart7 {
	pinctrl-names = "default";
	pinctrl-0 = <&uart7_pk13_pin>;
	status = "okay";
	gamepad_right: gamepad {
		compatible = "trimui,smart-pro-s-gamepad-right";
		current-speed = <19200>;
	};
};
```
Compatibles are `-left` / `-right` (the MCU's function), not `-uart5`/`-uart7` (the node already
lives under the right controller). Rumble `pwms` + `vcc-supply` are gated to the LEFT node.

## Upstream status / what's left

Upstream home: `drivers/input/joystick/gamepad-trimui-smart-pro-s.c`; binding
`Documentation/devicetree/bindings/input/trimui,smart-pro-s-gamepad.yaml` (two compatibles,
`current-speed` const 19200, `pwms`+`vcc-supply` gated to the left node via `allOf`/`if`). Remaining
before submission: run `dt_binding_check` (needs a dtschema host), the binding header/compatible
naming per the Krzysztof conventions, and keep the posting terse with HW results framed as a report
(not `Tested-by`) — see `[[linux-sunxi-maintainer-guidance]]`.

## How we got here (history)

1. **Skeleton (2026-09-25, offline)** — serdev driver + DT nodes drafted; frame-sync + logging only.
2. **Protocol reverse-engineering** — with no serdev child bound, the raw tty was read one capture
   per held control (`stty -F /dev/ttyAS5 19200 raw`; `cat` per button/axis), analysed offline into
   a protocol map (frame length, sync byte/offset, per-button byte/bit, per-axis byte/range).
3. **Fill** — the map was transcribed into the per-UART frame descriptors + button/axis tables, with
   Xbox-style `BTN_`/`ABS_` codes.
4. **Single-pad merge (2026-10-01)** — the kref'd singleton `input_dev` replaced the two-device
   approach.
5. **FF/rumble + persistence** — rumble wired to the PWM motor, module installed + depmod'd for
   auto-load; verified on hardware.
