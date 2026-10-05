// Dump a runlist buffer from vidmem and then read the chosen channel's USERD from the GPU side.
//
// Why: the plugin's CE channel (doorbell token 0x10001 = runlist 1 = CE2, chid 1) shows
// ENABLE NEXT ON_PBDMA ON_ENG in CHRAM, yet FB at the copy destination never changes, so the
// pushbuffer is not executing. If GP_PUT read from the GPU side is still 0 while the plugin
// demonstrably writes 1 to USERD+0x8c, then host writes into the USERD BAR page are not
// reaching the GPU.
//
// Runlist regs: base at 0xc00000 + rl*0x400; +0x080/+0x084 submit base (an FB address),
// +0x088 entry count. Entries are 16 bytes:
//   TSG : d0=(timeslice<<24)|(3<<16)|1, d1=chan count, d2=tsgid
//   CHAN: d0=userd_lo|(runq<<1), d1=userd_hi, d2=inst_lo|chid(11:0), d3=inst_hi
// Everything is read through the BAR0 PRAMIN window (0x001700 = base>>16, data at
// BAR0+0x700000), saving and restoring the window because RM shares it.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>

static unsigned long bar0 = 0xf5000000UL;
static unsigned int rl = 1;          /* runlist index: 1 = CE2 */
static unsigned int want_chid = 1;
module_param(bar0, ulong, 0444);
module_param(rl, uint, 0444);
module_param(want_chid, uint, 0444);

#define WINREG 0x001700UL
#define PRAMIN 0x700000UL

static void __iomem *io;
static u32 win_saved;

static void win_set(unsigned long addr) { writel(addr >> 16, io + WINREG); (void)readl(io + WINREG); }
static u32  pram_rd(unsigned long addr) { win_set(addr); return readl(io + PRAMIN + (addr & 0xffff)); }

static int __init rl_init(void)
{
    unsigned long rlbase = 0xc00000UL + rl * 0x400UL;
    u32 lo, hi, cnt, i;
    u64 rlbuf;
    u64 found_userd = 0; int found = 0;

    io = ioremap(bar0, 0x1000000);   /* BAR0 is 16 MB; FIFO regs live at 0xc00000, past 8 MB - a 0x800000 map oopsed here */
    if (!io) { pr_err("rldump2: ioremap failed\n"); return -ENOMEM; }
    win_saved = readl(io + WINREG);

    lo  = readl(io + rlbase + 0x080);
    hi  = readl(io + rlbase + 0x084);
    cnt = readl(io + rlbase + 0x088) & 0xffff;
    rlbuf = ((u64)hi << 32) | lo;
    pr_info("rldump2: rl=%u regs=0x%lx submit_base=0x%llx entries=%u (saved WINDOW=0x%08x)\n",
            rl, rlbase, rlbuf, cnt, win_saved);
    if (!rlbuf || cnt == 0 || cnt > 256) {
        pr_info("rldump2: nothing sane to dump\n"); goto out;
    }
    for (i = 0; i < cnt; i++) {
        unsigned long ea = (unsigned long)(rlbuf + i * 16);
        u32 d0 = pram_rd(ea), d1 = pram_rd(ea+4), d2 = pram_rd(ea+8), d3 = pram_rd(ea+12);
        int is_tsg = ((d0 & 0xffff) == 0x0001) && (((d0 >> 16) & 0xf) == 3);
        if (is_tsg)
            pr_info("rldump2:  [%02u] TSG  tsgid=%u chans=%u timeslice=%u (raw %08x %08x %08x %08x)\n",
                    i, d2, d1, d0 >> 24, d0, d1, d2, d3);
        else {
            u32 chid = d2 & 0xfff;
            u64 userd = ((u64)d1 << 32) | (d0 & 0xfffffffc);
            pr_info("rldump2:  [%02u] CHAN chid=%u userd=0x%llx inst=0x%llx (raw %08x %08x %08x %08x)\n",
                    i, chid, userd, (((u64)d3 << 32) | (d2 & 0xfffff000)), d0, d1, d2, d3);
            if (chid == want_chid && !found) { found_userd = userd; found = 1; }
        }
    }
    if (found) {
        u32 g = pram_rd((unsigned long)(found_userd + 0x88));
        u32 p = pram_rd((unsigned long)(found_userd + 0x8c));
        pr_info("rldump2: chid=%u USERD=0x%llx  GP_GET=0x%08x  GP_PUT=0x%08x\n",
                want_chid, found_userd, g, p);
        if (g == p) pr_info("rldump2: GP_GET == GP_PUT -> GPU has consumed everything submitted\n");
        else        pr_info("rldump2: GP_GET != GP_PUT -> work is pending and NOT being fetched\n");
    } else
        pr_info("rldump2: chid=%u not found in this runlist\n", want_chid);
out:
    writel(win_saved, io + WINREG); (void)readl(io + WINREG);
    pr_info("rldump2: WINDOW restored to 0x%08x\n", readl(io + WINREG));
    iounmap(io);
    return -EINVAL;
}
static void __exit rl_exit(void) { }
module_init(rl_init);
module_exit(rl_exit);
MODULE_LICENSE("GPL");
