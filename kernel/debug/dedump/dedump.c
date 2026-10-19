// SPDX-License-Identifier: GPL-2.0
/* Read-only dump of the A523 display path, to diff against the stock oracle. */
#include <linux/module.h>
#include <linux/io.h>

static void dump(const char *name, phys_addr_t base, size_t len,
		 const u16 *offs, unsigned int n)
{
	void __iomem *p = ioremap(base, len);
	unsigned int i;

	if (!p) {
		pr_info("DEDUMP %s: ioremap failed\n", name);
		return;
	}
	for (i = 0; i < n; i += 4) {
		pr_info("DEDUMP %s %03x=%08x %03x=%08x %03x=%08x %03x=%08x\n", name,
			offs[i],   readl(p + offs[i]),
			i+1 < n ? offs[i+1] : 0, i+1 < n ? readl(p + offs[i+1]) : 0,
			i+2 < n ? offs[i+2] : 0, i+2 < n ? readl(p + offs[i+2]) : 0,
			i+3 < n ? offs[i+3] : 0, i+3 < n ? readl(p + offs[i+3]) : 0);
	}
	iounmap(p);
}

/* exactly the offsets the stock capture lists */
static const u16 tcon_o[] = { 0x000,0x004,0x040,0x044,0x048,0x04c,0x050,0x054,
			      0x058,0x060,0x0fc };
static const u16 dsi_o[]  = { 0x000,0x004,0x00c,0x010,0x014,0x018,0x01c,0x020,
			      0x024,0x028,0x02c,0x030,0x034,0x038,0x03c,0x040,
			      0x044,0x048,0x04c,0x054,0x060,0x07c,0x080,0x0b0,
			      0x0b4,0x0b8,0x0bc,0x0c0,0x0c4,0x0c8,0x0cc,0x0d0,
			      0x0f4,0x2f0,0x2f4,0x2e0 };
static const u16 phy_o[]  = { 0x000,0x004,0x010,0x04c,0x050,0x054,0x058,0x05c,
			      0x0e0 };
static const u16 detop_o[]= { 0x000,0x004,0x008,0x010,0x014,0x018,0x01c,0x020,
			      0x024,0x028,0x02c,0x030 };

static int __init dd_init(void)
{
	dump("TCON1", 0x5502000, 0x1000, tcon_o,  ARRAY_SIZE(tcon_o));
	dump("DSI1",  0x5508000, 0x1000, dsi_o,   ARRAY_SIZE(dsi_o));
	dump("PHY",   0x5509000, 0x1000, phy_o,   ARRAY_SIZE(phy_o));
	dump("DETOP", 0x5008000, 0x1000, detop_o, ARRAY_SIZE(detop_o));
	return -EINVAL;		/* self-unload */
}
module_init(dd_init);
MODULE_LICENSE("GPL");
