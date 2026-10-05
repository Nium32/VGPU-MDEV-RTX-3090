// Walk BAR1's page tables for a given BAR1 offset, GP100/Ampere format.
//
// Format from nouveau nvkm/subdev/mmu/vmmgp100.c:
//   PTE : (addr >> 4) | aperture<<1 | BIT(0) VALID | BIT(3) VOL | BIT(6) RO
//   PDE : (addr >> 4) | aperture<<1        <-- NO bit0; presence IS aperture != 0
//         (gp100_vmm_pgd_pde writes only the target bits and addr>>4)
//   5 levels, leaf-first in nouveau's desc arrays. For 4 KB pages:
//     bits 11:0 offset | 20:12 L0 (9b,8B) | 28:21 L1 (8b,16B) | 37:29 L2 (9b,8B)
//     | 46:38 L3 (9b,8B) | 48:47 L4 (2b,8B) = root
//   Root PD address comes from inst+0x200/0x204 with low 12 bits as flags
//   (gf100_vmm_join_ writes `base | pd->addr`; 0xc00 = VER2 | 64KiB).
//
// SAFETY: PRAMIN window 0x001700 set once per read target, restored at the end. Never looped
// over many entries - that wedged this host once and cost a power cycle.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/io.h>

static unsigned long bar0 = 0xf5000000UL;
static unsigned long inst = 0x5fff91000UL;
static unsigned long off  = 0x0fef0200UL;
module_param(bar0, ulong, 0444);
module_param(inst, ulong, 0444);
module_param(off,  ulong, 0444);

#define WINREG 0x001700UL
#define PRAMIN 0x700000UL
static void __iomem *io;

static u64 rd64(unsigned long fb)
{
    u32 lo, hi;
    writel(fb >> 16, io + WINREG);
    (void)readl(io + WINREG);
    lo = readl(io + PRAMIN + (fb & 0xffff));
    hi = readl(io + PRAMIN + (fb & 0xffff) + 4);
    return ((u64)hi << 32) | lo;
}
static const char *ap(u64 e)
{
    switch ((e >> 1) & 3) { case 0: return "none"; case 1: return "VRAM";
                            case 2: return "HOSTc"; default: return "HOSTnc"; }
}
#define PRESENT_PDE(e) (((e) >> 1) & 3)
#define CHILD(e)       ((unsigned long)(((e) & ~0xffULL) << 4))

static int __init bw_init(void)
{
    u32 saved;
    u64 pdw, e, e1a, e1b;
    unsigned long a, i[5];
    int lvl;

    io = ioremap(bar0, 0x1000000);
    if (!io) return -ENOMEM;
    saved = readl(io + WINREG);

    i[0] = (off >> 12) & 0x1ff;
    i[1] = (off >> 21) & 0xff;
    i[2] = (off >> 29) & 0x1ff;
    i[3] = (off >> 38) & 0x1ff;
    i[4] = (off >> 47) & 0x3;
    pr_info("bar1walk: off=0x%lx  L4=%lu L3=%lu L2=%lu L1=%lu L0=%lu\n",
            off, i[4], i[3], i[2], i[1], i[0]);

    pdw = rd64(inst + 0x0200);
    a = (unsigned long)(pdw & ~0xfffULL);
    pr_info("bar1walk: inst+0x200=0x%016llx flags=0x%03llx root PD=0x%lx\n",
            pdw, pdw & 0xfff, a);
    if (!a) { pr_info("bar1walk: root PD is ZERO\n"); goto out; }

    /* dump all 4 root entries (2-bit index) */
    for (lvl = 0; lvl < 4; lvl++) {
        e = rd64(a + lvl * 8);
        pr_info("bar1walk: ROOT[%d] = 0x%016llx ap=%s child=0x%lx%s\n",
                lvl, e, ap(e), CHILD(e), PRESENT_PDE(e) ? "" : "  (not present)");
    }

    /* descend L4 -> L3 -> L2 using PDE semantics */
    for (lvl = 4; lvl >= 2; lvl--) {
        e = rd64(a + i[lvl] * 8);
        pr_info("bar1walk: L%d[%lu] = 0x%016llx ap=%s child=0x%lx\n",
                lvl, i[lvl], e, ap(e), CHILD(e));
        if (!PRESENT_PDE(e)) { pr_info("bar1walk: L%d PDE not present -> BAR1 offset unmapped\n", lvl); goto out; }
        a = CHILD(e);
    }

    /* L1 entries are 16 bytes: [0] = big/LPT, [8] = small/SPT */
    e1a = rd64(a + i[1] * 16);
    e1b = rd64(a + i[1] * 16 + 8);
    pr_info("bar1walk: L1[%lu].big   = 0x%016llx ap=%s child=0x%lx\n", i[1], e1a, ap(e1a), CHILD(e1a));
    pr_info("bar1walk: L1[%lu].small = 0x%016llx ap=%s child=0x%lx\n", i[1], e1b, ap(e1b), CHILD(e1b));
    if (PRESENT_PDE(e1b))      a = CHILD(e1b);
    else if (PRESENT_PDE(e1a)) a = CHILD(e1a);
    else { pr_info("bar1walk: no leaf page table for this range -> BAR1 offset unmapped\n"); goto out; }

    e = rd64(a + i[0] * 8);
    pr_info("bar1walk: L0[%lu] = 0x%016llx VALID=%llu ap=%s phys=0x%lx vol=%llu ro=%llu\n",
            i[0], e, e & 1, ap(e), CHILD(e), (e >> 3) & 1, (e >> 6) & 1);
    if (e & 1) pr_info("bar1walk: ==> BAR1+0x%lx IS mapped to 0x%lx (%s)\n", off, CHILD(e), ap(e));
    else       pr_info("bar1walk: ==> BAR1+0x%lx has NO VALID PTE\n", off);
out:
    writel(saved, io + WINREG); (void)readl(io + WINREG);
    pr_info("bar1walk: WINDOW restored to 0x%08x\n", readl(io + WINREG));
    iounmap(io);
    return -EINVAL;
}
static void __exit bw_exit(void) { }
module_init(bw_init);
module_exit(bw_exit);
MODULE_LICENSE("GPL");
