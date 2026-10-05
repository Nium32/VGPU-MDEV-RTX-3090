// SPDX-License-Identifier: GPL-2.0
/*
 * isrfind - find the call site that disables something and never re-enables it.
 *
 * Background
 * ----------
 * On this project's hardware the guest's graphics channel was scheduled exactly
 * once and then never again, with nothing logged anywhere. The cause was a
 * single call site inside the NVIDIA RM interrupt handler that disabled the
 * graphics runlist without a matching re-enable:
 *
 *     site A (an ISR handler)   disables=572   enables=0      <-- the leak
 *     site B (normal path)      disables=15    enables=15     <-- balanced
 *
 * Finding that by hand means disassembling an anonymised 48000-function blob.
 * Finding it with this module means running it for a minute and reading a table.
 *
 * What it does
 * ------------
 * You give it the symbol of the function that performs the enable/disable (the
 * writer), and which argument carries the flag. It places a kprobe on the
 * writer, and on every call records:
 *
 *   - the RETURN ADDRESS, which identifies the caller, and
 *   - the flag argument, which says whether this call enabled or disabled.
 *
 * On unload it prints one line per distinct call site with its enable and
 * disable counts. A site with many disables and zero enables is your target.
 * Its address minus the module base is the offset you then disassemble - a few
 * instructions, not a whole driver.
 *
 * Usage
 * -----
 *   insmod isrfind.ko sym=_nv023170rm argn=3
 *   # reproduce the hang, wait, then:
 *   rmmod isrfind
 *   dmesg | grep isrfind
 *
 * argn selects which argument holds the flag, using the SysV AMD64 integer
 * argument order: 1=rdi 2=rsi 3=rdx 4=rcx 5=r8 6=r9. A nonzero value is
 * counted as "disable" by default; pass invert=1 if your writer uses the
 * opposite sense. If you do not know, set argn=0 and every call is counted in
 * the "calls" column only, which still shows you which site is hot.
 *
 * Safety
 * ------
 * Read-only. It never modifies registers, never changes control flow and never
 * writes to the target. The return address is read with
 * copy_from_kernel_nofault, so a bad stack cannot panic the machine.
 *
 * Do NOT do arithmetic on regs->ip in a kprobe pre-handler. On x86 it is
 * probe_addr+1 inside the handler, and treating it as the function entry has
 * oopsed this host before.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/kallsyms.h>
#include <linux/uaccess.h>

#define ISRFIND_MAX_SITES 64

static char *sym;
module_param(sym, charp, 0444);
MODULE_PARM_DESC(sym, "symbol of the function that enables/disables (required)");

static int argn;
module_param(argn, int, 0444);
MODULE_PARM_DESC(argn, "which integer argument holds the flag, 1..6; 0 = just count calls");

static int invert;
module_param(invert, int, 0444);
MODULE_PARM_DESC(invert, "treat a ZERO flag as the disable instead of a nonzero one");

static int verbose;
module_param(verbose, int, 0644);
MODULE_PARM_DESC(verbose, "also log every single call as it happens (very noisy)");

struct site {
	unsigned long ret;	/* return address: identifies the caller */
	unsigned long calls;
	unsigned long disables;
	unsigned long enables;
};

static struct site sites[ISRFIND_MAX_SITES];
static int nr_sites;
static unsigned long total_calls;
static unsigned long dropped_sites;	/* calls from sites beyond the table */
static DEFINE_SPINLOCK(sites_lock);

static struct kprobe kp;

static unsigned long arg_value(struct pt_regs *regs, int which)
{
	switch (which) {
	case 1: return regs->di;
	case 2: return regs->si;
	case 3: return regs->dx;
	case 4: return regs->cx;
	case 5: return regs->r8;
	case 6: return regs->r9;
	default: return 0;
	}
}

static int isrfind_pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long ret = 0;
	unsigned long flag = 0;
	int is_disable = 0;
	int i;
	unsigned long irqflags;

	/*
	 * At function entry on x86_64 the return address sits at the top of the
	 * stack. Read it without faulting: this runs in interrupt context on a
	 * path we do not control.
	 */
	if (copy_from_kernel_nofault(&ret, (void *)regs->sp, sizeof(ret)))
		ret = 0;

	if (argn >= 1 && argn <= 6) {
		flag = arg_value(regs, argn);
		is_disable = invert ? (flag == 0) : (flag != 0);
	}

	spin_lock_irqsave(&sites_lock, irqflags);
	total_calls++;
	for (i = 0; i < nr_sites; i++) {
		if (sites[i].ret == ret)
			goto found;
	}
	if (nr_sites >= ISRFIND_MAX_SITES) {
		dropped_sites++;
		spin_unlock_irqrestore(&sites_lock, irqflags);
		return 0;
	}
	i = nr_sites++;
	sites[i].ret = ret;
found:
	sites[i].calls++;
	if (argn >= 1 && argn <= 6) {
		if (is_disable)
			sites[i].disables++;
		else
			sites[i].enables++;
	}
	spin_unlock_irqrestore(&sites_lock, irqflags);

	if (verbose)
		pr_info("isrfind: call from %pS flag=0x%lx\n", (void *)ret, flag);

	return 0;
}

static void isrfind_report(void)
{
	int i;
	unsigned long irqflags;
	struct site *snap;
	int n;

	/* On the heap: a 64-entry snapshot on the stack is a 2KB frame, which
	 * trips -Wframe-larger-than. This runs in process context on rmmod, so
	 * GFP_KERNEL is fine. */
	snap = kmalloc_array(ISRFIND_MAX_SITES, sizeof(*snap), GFP_KERNEL);
	if (!snap) {
		pr_err("isrfind: out of memory, cannot print the report\n");
		return;
	}

	spin_lock_irqsave(&sites_lock, irqflags);
	n = nr_sites;
	memcpy(snap, sites, sizeof(*snap) * n);
	spin_unlock_irqrestore(&sites_lock, irqflags);

	pr_info("isrfind: ==================== report ====================\n");
	pr_info("isrfind: target %s, %lu calls from %d distinct sites\n",
		sym ? sym : "(none)", total_calls, n);
	if (dropped_sites)
		pr_warn("isrfind: %lu calls came from sites beyond the %d-entry table\n",
			dropped_sites, ISRFIND_MAX_SITES);
	if (argn < 1 || argn > 6)
		pr_info("isrfind: argn not set, so only the call column is meaningful\n");

	for (i = 0; i < n; i++) {
		long leak = (long)snap[i].disables - (long)snap[i].enables;

		pr_info("isrfind: site %pS  calls=%lu disables=%lu enables=%lu leak=%+ld%s\n",
			(void *)snap[i].ret, snap[i].calls,
			snap[i].disables, snap[i].enables, leak,
			(snap[i].disables > 0 && snap[i].enables == 0) ?
				"   <-- ONE WAY, this is your site" : "");
	}

	pr_info("isrfind: a site with many disables and zero enables is the leak.\n");
	pr_info("isrfind: subtract the module base to get the offset to disassemble:\n");
	pr_info("isrfind:   grep nvidia /proc/modules   # first field after the size\n");
	pr_info("isrfind: ================== end report ==================\n");
	kfree(snap);
}

static int __init isrfind_init(void)
{
	int rc;

	if (!sym || !*sym) {
		pr_err("isrfind: sym= is required. Give the symbol of the function that\n");
		pr_err("isrfind: performs the enable/disable, e.g. sym=_nv023170rm\n");
		return -EINVAL;
	}

	memset(&kp, 0, sizeof(kp));
	kp.symbol_name = sym;
	kp.pre_handler = isrfind_pre;

	rc = register_kprobe(&kp);
	if (rc < 0) {
		pr_err("isrfind: register_kprobe on '%s' failed: %d\n", sym, rc);
		if (rc == -ENOENT) {
			pr_err("isrfind: that symbol was not found. Check with:\n"
			       "isrfind:   sudo grep -w %s /proc/kallsyms\n", sym);
			pr_err("isrfind: module symbol lines end with a tab and [module], so an\n");
			pr_err("isrfind: end-anchored grep such as ' %s$' never matches.\n", sym);
			pr_err("isrfind: the address column reads all zeroes unless\n");
			pr_err("isrfind: /proc/sys/kernel/kptr_restrict is 0.\n");
		}
		return rc;
	}

	pr_info("isrfind: watching %s at %p (argn=%d invert=%d)\n",
		sym, kp.addr, argn, invert);
	pr_info("isrfind: reproduce the hang, then rmmod isrfind and read dmesg\n");
	return 0;
}

static void __exit isrfind_exit(void)
{
	unregister_kprobe(&kp);
	isrfind_report();
}

module_init(isrfind_init);
module_exit(isrfind_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Attribute enable/disable calls to their call sites to find a one-way leak");
