# Off-mode charging (Smart Pro S / AXP717)

The AXP717 powers the SoC on when VBUS is inserted — that is an efuse
customization (datasheet 6.5.4.1), not a runtime register, so it cannot be
disabled in hardware. Instead, on boot we read REG 0x20 (PWRON status,
AXP717C datasheet 6.14.2.16): bits 1..3 = VBUS insert / BAT>3.3V charging /
BAT insert, i.e. "woken by charger". If set, the boot diverts to a minimal
`offcharge.target` (no network/sshd, status LED blinks green); when VBUS is
removed the monitor powers the PMIC off. A warm reboot (SOFT_PWROFF) reads
reg20=0 and boots normally. Power button while off still boots full.

HW-verified 2026-11-16: charger plug while off -> boots into offcharge.target
(no ssh, tailscale offline), instead of full boot.

Deploy: install the two scripts to /usr/local/bin, the units to
/etc/systemd/system, then `systemctl daemon-reload && systemctl enable
offcharge-check.service`.
