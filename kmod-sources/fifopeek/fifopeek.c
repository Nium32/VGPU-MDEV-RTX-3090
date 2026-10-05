// Dump GA102 FIFO runlist + CHRAM state by ioremapping BAR0.
//
// /dev/mem cannot be used: CONFIG_IO_STRICT_DEVMEM=y refuses MMIO claimed by a driver, and
// nvidia.ko owns BAR0. gdb cannot read the plugin's BAR mappings either (generic_access_phys
// returns an incrementing 0xbad0acNN counter) and pagemap does not report PFNs for
// VM_IO|VM_PFNMAP. Reading BAR0 PRI registers from kernel context is the supported way in.
//
// init() prints everything and then returns -EINVAL on purpose, so the module never stays
// loaded and needs no rmmod. Read the output with dmesg.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>

static unsigned long bar0 = 0xf5000000UL;
module_param(bar0, ulong, 0444);

#define RL_OFF   0xc00000UL
#define WIN_SZ   0x40000UL          /* 0xc00000 .. 0xc40000 covers regs + CHRAM */

struct rl { unsigned int off; const char *name; };
static const struct rl rls[] = {
    { 0x0000, "GR+CE0+CE1" }, { 0x0400, "CE2" }, { 0x0800, "CE3" }, { 0x0c00, "CE4" },
    { 0x1000, "NVDEC" }, { 0x1800, "NVENC" }, { 0x1c00, "OFA" }, { 0x2000, "SEC2" },
};

static int __init fp_init(void)
{
    void __iomem *io;
    int i, chid, found, total = 0;

    io = ioremap(bar0 + RL_OFF, WIN_SZ);
    if (!io) { pr_err("fifopeek: ioremap(0x%lx) failed\n", bar0 + RL_OFF); return -ENOMEM; }
    pr_info("fifopeek: BAR0=0x%lx window 0x%lx+0x%lx\n", bar0, RL_OFF, WIN_SZ);

    for (i = 0; i < ARRAY_SIZE(rls); i++) {
        unsigned int o = rls[i].off;
        unsigned int chcfg = readl(io + o + 0x004);
        unsigned int chram, cnt, ents, blk, updpend;
        if (chcfg == 0 || chcfg == 0xffffffff || (chcfg >> 8) == 0xbad0ac) {
            pr_info("fifopeek: %-11s chcfg=0x%08x <absent/unreadable>\n", rls[i].name, chcfg);
            continue;
        }
        chram   = chcfg & 0xfffffff0;
        cnt     = 1u << (chcfg & 0xf);
        ents    = readl(io + o + 0x088) & 0xffff;
        updpend = (readl(io + o + 0x08c) >> 15) & 1;
        blk     = readl(io + o + 0x094) & 1;
        pr_info("fifopeek: %-11s chcfg=0x%08x CHRAM=0x%08x chans=%u entries=%u BLOCK=%u updpend=%u\n",
                rls[i].name, chcfg, chram, cnt, ents, blk, updpend);

        if (chram < RL_OFF || chram + cnt * 4 > RL_OFF + WIN_SZ) {
            pr_info("fifopeek:   CHRAM 0x%08x outside window, skipped\n", chram);
            continue;
        }
        found = 0;
        for (chid = 0; chid < cnt; chid++) {
            unsigned int v = readl(io + (chram - RL_OFF) + chid * 4);
            if (v == 0 || v == 0xffffffff || (v >> 8) == 0xbad0ac) continue;
            pr_info("fifopeek:   %-11s chid=%-4d word=0x%08x%s%s%s%s%s%s%s%s%s%s\n",
                    rls[i].name, chid, v,
                    (v & (1u<<1)) ? " ENABLE" : "",       (v & (1u<<2)) ? " NEXT" : "",
                    (v & (1u<<3)) ? " BUSY" : "",         (v & (1u<<4)) ? " PBDMA_FAULTED" : "",
                    (v & (1u<<5)) ? " ENG_FAULTED" : "",  (v & (1u<<6)) ? " ON_PBDMA" : "",
                    (v & (1u<<7)) ? " ON_ENG" : "",       (v & (1u<<8)) ? " PENDING" : "",
                    (v & (1u<<9)) ? " CTX_RELOAD" : "",   (v & (1u<<12)) ? " ACQUIRE_FAIL" : "");
            if (++found >= 24) { pr_info("fifopeek:   ... truncated\n"); break; }
            total++;
        }
        if (!found) pr_info("fifopeek:   %-11s no active channels\n", rls[i].name);
    }
    pr_info("fifopeek: total active channels printed = %d\n", total);
    iounmap(io);
    return -EINVAL;   /* deliberate: print once, never stay loaded */
}
static void __exit fp_exit(void) { }
module_init(fp_init);
module_exit(fp_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("one-shot GA102 FIFO runlist/CHRAM dumper");
