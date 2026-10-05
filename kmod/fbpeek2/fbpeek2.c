// Did the CE actually execute the pteblit copy?
//
// The decoded pushbuffer copies 256 bytes to FB PHYSICAL 0x1e6ed000 (LAUNCH_DMA 0x2186,
// DST_TYPE=PHYSICAL, LINE_LENGTH_IN=256, LINE_COUNT=1) and only afterwards releases the
// semaphore. The plugin's semaphore page never changes, so read the copy destination instead:
// if FB at 0x1e6ed000 changes across kicks the CE is running and only the release is lost; if
// it never changes the CE is not executing the pushbuffer at all.
//
// Read through the BAR0 PRAMIN window: PBUS_BAR0_WINDOW (0x001700) holds base>>16, data
// appears at BAR0+0x700000. The window register is SHARED with RM, so save it and put it back.
// One shot only - do not poll PRAMIN in a loop.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>
#include <linux/delay.h>

static unsigned long bar0 = 0xf5000000UL;
static unsigned long fbaddr = 0x1e6ed000UL;
static unsigned int gap_ms = 4000;
module_param(bar0, ulong, 0444);
module_param(fbaddr, ulong, 0444);
module_param(gap_ms, uint, 0444);

#define WINREG  0x001700UL
#define PRAMIN  0x700000UL

static void snap(void __iomem *io, u32 *out, int n, unsigned long addr)
{
    int i;
    u32 base = addr >> 16;
    u32 off  = addr & 0xffff;
    writel(base, io + WINREG);
    (void)readl(io + WINREG);            /* post the write */
    for (i = 0; i < n; i++)
        out[i] = readl(io + PRAMIN + off + i * 4);
}

static int __init fb_init(void)
{
    void __iomem *io;
    u32 saved, a[16], b[16];
    int i, diff = 0;

    io = ioremap(bar0, 0x800000);
    if (!io) { pr_err("fbpeek2: ioremap failed\n"); return -ENOMEM; }
    saved = readl(io + WINREG);
    pr_info("fbpeek2: BAR0=0x%lx fb=0x%lx saved WINDOW=0x%08x gap=%ums\n",
            bar0, fbaddr, saved, gap_ms);

    snap(io, a, 16, fbaddr);
    msleep(gap_ms);
    snap(io, b, 16, fbaddr);

    writel(saved, io + WINREG);           /* restore RM's window */
    (void)readl(io + WINREG);
    pr_info("fbpeek2: WINDOW restored to 0x%08x\n", readl(io + WINREG));

    for (i = 0; i < 16; i++) {
        if (a[i] != b[i]) diff++;
        pr_info("fbpeek2:   fb+0x%02x : 0x%08x -> 0x%08x%s\n",
                i * 4, a[i], b[i], (a[i] != b[i]) ? "   CHANGED" : "");
    }
    if (diff) pr_info("fbpeek2: %d/16 dwords CHANGED -> the CE IS executing the copy\n", diff);
    else      pr_info("fbpeek2: nothing changed -> the CE is NOT executing the pushbuffer\n");

    iounmap(io);
    return -EINVAL;   /* print once, never stay loaded */
}
static void __exit fb_exit(void) { }
module_init(fb_init);
module_exit(fb_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("one-shot FB read via BAR0 PRAMIN, save/restore window");
