# SPDX-License-Identifier: GPL-2.0
# Build against a configured A523 kernel tree:
#   make -C kernel/debug/dedump KDIR=/path/to/linux
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := dedump.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 \
		CROSS_COMPILE=aarch64-linux-gnu- modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
