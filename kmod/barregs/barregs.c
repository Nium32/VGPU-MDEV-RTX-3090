// Read the BAR0 registers that control the BAR1 aperture.
//
// The whole of BAR1 (0xe0000000-0xefffffff) returns an incrementing 0xbad0acNN poison counter
// from kernel context through a correct UC mapping, while BAR0 PRI reads return real data.
// So BAR1 is not backed. NV_PBUS_BAR1_BLOCK (0x001704) holds the instance-block pointer that
// defines BAR1's page tables; if it is zero or bogus, every BAR1 access fails exactly this way.
// 0x001700 is the PRAMIN window (do NOT write it), 0x001714 is the BAR2 block.
//
// Reads only. No PRAMIN window writes - looping those wedged this host once already.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>
static unsigned long bar0 = 0xf5000000UL;
module_param(bar0, ulong, 0444);
struct r { unsigned long off; const char *name; };
static const struct r regs[] = {
    { 0x001700, "PBUS_BAR0_WINDOW (PRAMIN base>>16)" },
    { 0x001704, "PBUS_BAR1_BLOCK  (BAR1 inst block)" },
    { 0x001708, "PBUS_BAR1_BLOCK+4 / aux" },
    { 0x00170c, "PBUS_BAR2_BLOCK? / aux" },
    { 0x001714, "PBUS_BAR2_BLOCK  (BAR2 inst block)" },
    { 0x001718, "aux" },
    { 0x100c80, "PFB_NISO_FLUSH / scratch" },
    { 0x000000, "PMC_BOOT_0 (chip id)" },
    { 0x000200, "PMC_ENABLE" },
    { 0x000140, "PMC_INTR_EN" },
};
static int __init br_init(void)
{
    void __iomem *io = ioremap(bar0, 0x1000000);
    int i;
    if (!io) { pr_err("barregs: ioremap failed\n"); return -ENOMEM; }
    pr_info("barregs: BAR0=0x%lx\n", bar0);
    for (i = 0; i < ARRAY_SIZE(regs); i++)
        pr_info("barregs:  0x%06lx %-38s = 0x%08x\n",
                regs[i].off, regs[i].name, readl(io + regs[i].off));
    iounmap(io);
    return -EINVAL;
}
static void __exit br_exit(void) { }
module_init(br_init);
module_exit(br_exit);
MODULE_LICENSE("GPL");
