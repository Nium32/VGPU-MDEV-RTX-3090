// Read the BAR1 instance block to see whether BAR1 has page tables at all.
//
// NV_PBUS_BAR1_BLOCK (BAR0+0x001704) = 0x805fff91 on this rig: bit31 = VIRTUAL mode,
// target bits 29:28 = 0 = VID_MEM, ptr bits 27:0 = 0x5fff91, so the instance block is at
// FB 0x5fff91000. In the RAMIN layout the page-directory base lives at inst+0x0200/0x0204
// (lower/upper), with the aperture/limit words just after. If the PD base reads back as zero
// then BAR1 has no page tables, which is exactly why every BAR1 offset returns the
// incrementing 0xbad0acNN unbacked-access counter while BAR0 and BAR3 read fine.
//
// SAFETY: the PRAMIN window register 0x001700 is set EXACTLY ONCE here and restored at the
// end. Re-programming it per read is what wedged this host and forced a power cycle.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>

static unsigned long bar0 = 0xf5000000UL;
static unsigned long inst = 0x5fff91000UL;    /* from BAR1_BLOCK ptr<<12 */
module_param(bar0, ulong, 0444);
module_param(inst, ulong, 0444);

#define WINREG 0x001700UL
#define PRAMIN 0x700000UL

static int __init ip_init(void)
{
    void __iomem *io;
    u32 saved, w[8];
    unsigned long woff;
    int i;

    io = ioremap(bar0, 0x1000000);
    if (!io) { pr_err("instpeek: ioremap failed\n"); return -ENOMEM; }

    saved = readl(io + WINREG);
    pr_info("instpeek: BAR1_BLOCK reg = 0x%08x\n", readl(io + 0x001704));
    pr_info("instpeek: inst block FB addr = 0x%lx   (saved WINDOW=0x%08x)\n", inst, saved);

    /* ONE window set for the whole 64 KB page that contains the instance block */
    writel(inst >> 16, io + WINREG);
    (void)readl(io + WINREG);
    woff = inst & 0xffff;

    for (i = 0; i < 8; i++)
        w[i] = readl(io + PRAMIN + woff + 0x0200 + i * 4);
    for (i = 0; i < 8; i++)
        pr_info("instpeek:   inst+0x%03x = 0x%08x\n", 0x0200 + i * 4, w[i]);
    pr_info("instpeek: PD base = 0x%llx  (lo=0x%08x hi=0x%08x)\n",
            (((u64)w[1]) << 32) | w[0], w[0], w[1]);
    pr_info("instpeek:   inst+0x000 = 0x%08x  inst+0x004 = 0x%08x\n",
            readl(io + PRAMIN + woff + 0), readl(io + PRAMIN + woff + 4));

    writel(saved, io + WINREG);
    (void)readl(io + WINREG);
    pr_info("instpeek: WINDOW restored to 0x%08x\n", readl(io + WINREG));
    iounmap(io);
    return -EINVAL;
}
static void __exit ip_exit(void) { }
module_init(ip_init);
module_exit(ip_exit);
MODULE_LICENSE("GPL");
