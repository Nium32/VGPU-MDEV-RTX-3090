// Resolve a USERD virtual address in the vGPU plugin, report its PTE caching attributes, and
// read GP_GET/GP_PUT through a fresh uncached kernel mapping of the same physical page.
//
// WHY THIS TEST
// The decoded CE pushbuffer is well formed and the doorbell is rung every kick, the channel is
// ENABLE NEXT ON_PBDMA ON_ENG in CHRAM with zero faults, yet FB at the copy destination never
// changes and the semaphore page is never written. So the GPU is not seeing GP_PUT advance.
// GP_PUT is stored by the plugin to USERD+0x8c, and USERD is a /dev/nvidia0 BAR page. If
// nvidia.ko mapped that page write-back cacheable instead of UC, the store sits in the CPU
// cache and never reaches the GPU - which matches every observation. The PTE bits say so
// directly: PWT (bit 3) and PCD (bit 4), plus the PAT bit (bit 7) select the cache mode.
//
// SAFETY
// No PRAMIN and no touching 0x001700. Looping that window register is what wedged this host on
// 2026-10-05 and needed a physical power cycle. This only walks page tables and ioremaps one
// page, so it cannot disturb RM's window state.
//
// Reading GP_PUT back through our own UC mapping also discriminates the two cases:
//   our UC read shows GP_PUT == 1  -> the value IS in the BAR, so the GPU should have seen it
//   our UC read shows GP_PUT == 0  -> the plugin's store never reached the BAR (cache or PTE)
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/pid.h>
#include <linux/io.h>

static int pid = 0;
static unsigned long va = 0;
module_param(pid, int, 0444);
module_param(va, ulong, 0444);

static int __init up_init(void)
{
    struct task_struct *tsk;
    struct mm_struct *mm;
    pgd_t *pgd; p4d_t *p4d; pud_t *pud; pmd_t *pmd; pte_t *ptep, pte;
    unsigned long phys = 0, pfn = 0, flags = 0;
    void __iomem *io;
    int rc = -EINVAL, i;

    if (!pid || !va) { pr_err("userdpeek: need pid= and va=\n"); return -EINVAL; }

    rcu_read_lock();
    tsk = pid_task(find_vpid(pid), PIDTYPE_PID);
    if (tsk) get_task_struct(tsk);
    rcu_read_unlock();
    if (!tsk) { pr_err("userdpeek: no task %d\n", pid); return -ESRCH; }

    mm = get_task_mm(tsk);
    if (!mm) { pr_err("userdpeek: no mm\n"); put_task_struct(tsk); return -ESRCH; }

    mmap_read_lock(mm);
    pgd = pgd_offset(mm, va);
    if (pgd_none(*pgd) || pgd_bad(*pgd)) { pr_err("userdpeek: pgd none/bad\n"); goto unlock; }
    p4d = p4d_offset(pgd, va);
    if (p4d_none(*p4d) || p4d_bad(*p4d)) { pr_err("userdpeek: p4d none/bad\n"); goto unlock; }
    pud = pud_offset(p4d, va);
    if (pud_none(*pud)) { pr_err("userdpeek: pud none\n"); goto unlock; }
    if (pud_leaf(*pud)) {
        pfn   = pud_pfn(*pud);
        flags = pud_val(*pud);
        phys  = (pfn << PAGE_SHIFT) | (va & ~PUD_MASK);
        pr_info("userdpeek: 1G leaf mapping\n");
        goto got;
    }
    pmd = pmd_offset(pud, va);
    if (pmd_none(*pmd)) { pr_err("userdpeek: pmd none\n"); goto unlock; }
    if (pmd_leaf(*pmd)) {
        pfn   = pmd_pfn(*pmd);
        flags = pmd_val(*pmd);
        phys  = (pfn << PAGE_SHIFT) | (va & ~PMD_MASK);
        pr_info("userdpeek: 2M leaf mapping\n");
        goto got;
    }
    ptep = pte_offset_map(pmd, va);
    if (!ptep) { pr_err("userdpeek: pte_offset_map failed\n"); goto unlock; }
    pte = ptep_get(ptep);
    pte_unmap(ptep);
    if (!pte_present(pte)) { pr_err("userdpeek: PTE NOT PRESENT\n"); goto unlock; }
    pfn   = pte_pfn(pte);
    flags = pte_val(pte);
    phys  = (pfn << PAGE_SHIFT) | (va & ~PAGE_MASK);

got:
    mmap_read_unlock(mm);
    pr_info("userdpeek: pid=%d va=0x%lx -> pfn=0x%lx phys=0x%lx\n", pid, va, pfn, phys);
    pr_info("userdpeek: pte=0x%lx  PWT(bit3)=%lu PCD(bit4)=%lu PAT(bit7)=%lu  => cache mode idx %lu\n",
            flags, (flags >> 3) & 1, (flags >> 4) & 1, (flags >> 7) & 1,
            (((flags >> 7) & 1) << 2) | (((flags >> 4) & 1) << 1) | ((flags >> 3) & 1));
    pr_info("userdpeek: (x86 PAT default: idx0=WB idx1=WC idx2=UC- idx3=UC idx4=WB idx5=WC idx6=UC- idx7=UC)\n");
    pr_info("userdpeek: NX=%lu RW=%lu USER=%lu GLOBAL=%lu\n",
            (flags >> 63) & 1, (flags >> 1) & 1, (flags >> 2) & 1, (flags >> 8) & 1);

    io = ioremap(phys & PAGE_MASK, PAGE_SIZE);
    if (!io) { pr_err("userdpeek: ioremap(0x%lx) failed\n", phys & PAGE_MASK); goto out; }
    pr_info("userdpeek: --- USERD read back through a FRESH UC kernel mapping ---\n");
    for (i = 0x80; i < 0xa0; i += 4)
        pr_info("userdpeek:   USERD+0x%02x = 0x%08x\n", i, readl(io + (phys & ~PAGE_MASK) + i));
    pr_info("userdpeek: GP_GET(+0x88)=0x%08x  GP_PUT(+0x8c)=0x%08x\n",
            readl(io + (phys & ~PAGE_MASK) + 0x88),
            readl(io + (phys & ~PAGE_MASK) + 0x8c));
    iounmap(io);
    goto out;

unlock:
    mmap_read_unlock(mm);
out:
    mmput(mm);
    put_task_struct(tsk);
    return rc;   /* always fails on purpose: print once, never stay loaded */
}
static void __exit up_exit(void) { }
module_init(up_init);
module_exit(up_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("resolve a user VA, report PTE cache bits, read USERD via a fresh UC mapping");
