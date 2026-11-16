# Boot rumble

3 s of pwm-vibrator rumble at startup, fired alongside fan-boot-chirp.service
(same multi-user.target), so the user can tell the device is booting in
crowded environments. Drives the vibrator input device's EV_FF directly
(FF_RUMBLE, 3 s replay). No-op if no FF device is found.
