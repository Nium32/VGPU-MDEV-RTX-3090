// Is the host's BAR1 aperture backed at all, or only dead where USERD lives?
//
// Measured: the plugin's USERD sits at phys 0xefef0200, i.e. BAR1 (0xe0000000-0xefffffff)
// offset 0x0fef0200 - the very top of the 256 MB window. Its PTE is correctly UC- (PCD=1,
// PWT=0, PAT=0) yet a clean kernel readl() returns an incrementing 0xbad0acNN counter, so the
// poison is real hardware behaviour for an unbacked BAR1 read, not a gdb artifact.
//
// This samples BAR1 at several offsets with a fresh small ioremap each time. A dword that
// increments between two back-to-back reads of the SAME address is the poison counter; a
// stable value is real backing store.
//
// Safe: no PRAMIN, no 0x001700, no writes anywhere.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>

static unsigned long bar1 = 0xe0000000UL;
static unsigned long bar1_size = 0x10000000UL;
module_param(bar1, ulong, 0444);
module_param(bar1_size, ulong, 0444);

static void probe(unsigned long off)
{
    void __iomem *io = ioremap(bar1 + off, 0x1000);
    u32 a, b;
    if (!io) { pr_info("barscan: +0x%08lx ioremap failed\n", off); return; }
    a = readl(io);
    b = readl(io);
    pr_info("barscan: +0x%08lx (phys 0x%08lx) = 0x%08x 0x%08x  %s\n",
            off, bar1 + off, a, b,
            ((a >> 8) == 0xbad0ac) ? (a != b ? "POISON (increments = unbacked)" : "POISON (stable)")
                                   : (a == b ? "REAL (stable)" : "REAL (changing)"));
    iounmap(io);
}

static int __init bs_init(void)
{
    pr_info("barscan: BAR1 = 0x%lx size 0x%lx\n", bar1, bar1_size);
    probe(0x00000000);
    probe(0x00001000);
    probe(0x00100000);
    probe(0x01000000);
    probe(0x04000000);
    probe(0x08000000);
    probe(0x0c000000);
    probe(0x0f000000);
    probe(0x0fe00000);
    probe(0x0fef0000);   /* the page USERD lives in */
    probe(0x0ffff000);
    return -EINVAL;      /* print once, never stay loaded */
}
static void __exit bs_exit(void) { }
module_init(bs_init);
module_exit(bs_exit);
MODULE_LICENSE("GPL");
