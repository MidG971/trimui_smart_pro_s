<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# dedump — read-only A523 display register dump

Dumps the live TCON-LCD1, DSI1, combo-PHY and DE33 "detop" blocks at exactly the
offsets captured from the vendor firmware in [`../../../docs/STOCK-DSI-REGISTERS.md`](../../../docs/STOCK-DSI-REGISTERS.md),
so the two can be diffed column by column.

## Why a module and not `devmem`

On this board `/dev/mem` returns `EFAULT` for these ranges even with
`CONFIG_STRICT_DEVMEM=n`, and there is no `devmem`/busybox binary in the image.
An `ioremap()` from a module is the reliable way in.

**Only read blocks that are powered and clocked.** Reading an unclocked MMIO
block on this SoC stalls the bus and hangs the device. Everything dumped here is
live while the display pipeline is up; do not extend the offset tables to blocks
you have not confirmed are on (check `/sys/kernel/debug/pm_genpd/pm_genpd_summary`).

## Use

```sh
make -C kernel/debug/dedump KDIR=/path/to/linux
# copy dedump.ko to the device, then:
insmod /root/dedump.ko          # "fails" by design, see below
dmesg | grep DEDUMP
```

`init` returns `-EINVAL` on purpose so the module unloads itself after printing;
`insmod` reporting "Invalid parameters" is the expected, successful outcome.
