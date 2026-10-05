/* The guest-supplied GR context memdesc reaches the host's IOMMU-map helper
 * (_nv040084rm) without MEMDESC_FLAGS_GUEST_ALLOCATED (bit 8), so RM tries to
 * DMA-map an OS allocation that does not exist and returns 0x1a. Label it as
 * guest-allocated, which is what it is, so the map step is skipped.
 * Fail-closed: only the exact unpopulated 0x196000 sysmem descriptor.        */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>

#define MEMDESC_FLAGS_GUEST_ALLOCATED   0x100ULL

static unsigned long wantsize = 0x196000;
module_param(wantsize, ulong, 0644);
static int apply = 1;
module_param(apply, int, 0644);
static unsigned int seen, matched, patched;
module_param(seen, uint, 0444);
module_param(matched, uint, 0444);
module_param(patched, uint, 0444);

static int pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned char *arg = (unsigned char *)regs->di;
	unsigned char *md;
	u64 flags, size, *pmem;
	u32 aspace;

	seen++;
	if (!arg)
		return 0;
	md = *(unsigned char **)(arg + 0x08);
	if (!md)
		return 0;
	flags  = *(u64 *)(md + 0x08);
	size   = *(u64 *)(md + 0x28);
	pmem   = *(u64 **)(md + 0x40);
	aspace = *(u32 *)(md + 0x68);

	if (size != wantsize || pmem || aspace != 1)
		return 0;
	if (flags & MEMDESC_FLAGS_GUEST_ALLOCATED)
		return 0;
	matched++;
	if (apply) {
		*(u64 *)(md + 0x08) = flags | MEMDESC_FLAGS_GUEST_ALLOCATED;
		wmb();
		patched++;
		pr_info("mdguest: md=%p flags 0x%llx -> 0x%llx (size=0x%llx aspace=%u)\n",
			md, flags, *(u64 *)(md + 0x08), size, aspace);
	} else {
		pr_info("mdguest: WOULD patch md=%p flags=0x%llx size=0x%llx aspace=%u\n",
			md, flags, size, aspace);
	}
	return 0;
}

static struct kprobe kp = { .symbol_name = "_nv040084rm", .pre_handler = pre };

static int __init m_init(void)
{
	int rc = register_kprobe(&kp);
	if (rc)
		return rc;
	pr_info("mdguest: armed on _nv040084rm apply=%d\n", apply);
	return 0;
}
static void __exit m_exit(void)
{
	unregister_kprobe(&kp);
	pr_info("mdguest: seen=%u matched=%u patched=%u\n", seen, matched, patched);
}
module_init(m_init);
module_exit(m_exit);
MODULE_LICENSE("GPL");
