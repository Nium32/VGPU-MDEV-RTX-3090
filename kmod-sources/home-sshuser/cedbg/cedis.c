/* Count NV_RUNLIST_SCHED_DISABLE writes by call site and engine id.
 * _nv023170rm args: rdi=pGpu rsi=pKernelFifo rdx=engine rcx=bDisable r8=bPreempt
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

static char *syms = "_nv023170rm";
module_param(syms, charp, 0444);
static unsigned int maxlog = 12;
module_param(maxlog, uint, 0644);

#define MAXP 8
#define MAXSITE 48
static struct kprobe kps[MAXP];
static char *names[MAXP];
static unsigned long hits[MAXP], logged[MAXP];
static unsigned int nkp;

struct site { unsigned long ret; unsigned long eng; unsigned long ndis, nen; };
static struct site sites[MAXSITE];
static unsigned int nsite;
static unsigned long tot_dis, tot_en;

static int pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long *sp = (unsigned long *)regs->sp;
	unsigned int i, idx = MAXP;
	unsigned long ret = 0;
	int dis;

	for (i = 0; i < nkp; i++)
		if (&kps[i] == p) { idx = i; break; }
	if (idx == MAXP) return 0;
	hits[idx]++;
	if (copy_from_kernel_nofault(&ret, &sp[0], sizeof(ret))) ret = 0;

	if (idx == 0) {
		dis = (regs->cx != 0);
		if (dis) tot_dis++; else tot_en++;
		for (i = 0; i < nsite; i++)
			if (sites[i].ret == ret && sites[i].eng == regs->dx) break;
		if (i == nsite && nsite < MAXSITE) {
			sites[nsite].ret = ret; sites[nsite].eng = regs->dx; nsite++;
		}
		if (i < MAXSITE) { if (dis) sites[i].ndis++; else sites[i].nen++; }
	}
	if (logged[idx] < maxlog) {
		logged[idx]++;
		pr_info("cedis: %s hit#%lu cx=%lu(%s) dx=%lx r8=%lx RET %pS\n",
			names[idx], hits[idx], regs->cx, regs->cx ? "DISABLE" : "enable",
			regs->dx, regs->r8, (void *)ret);
	}
	return 0;
}

static int __init m_init(void)
{
	char *s, *tok, *dup; int rc;
	dup = kstrdup(syms, GFP_KERNEL);
	if (!dup) return -ENOMEM;
	s = dup;
	while ((tok = strsep(&s, ",")) && nkp < MAXP) {
		if (!*tok) continue;
		names[nkp] = kstrdup(tok, GFP_KERNEL);
		kps[nkp].symbol_name = names[nkp];
		kps[nkp].pre_handler = pre;
		rc = register_kprobe(&kps[nkp]);
		if (rc) { pr_info("cedis: FAILED %s rc=%d\n", tok, rc); kfree(names[nkp]); continue; }
		pr_info("cedis: armed %s\n", names[nkp]);
		nkp++;
	}
	kfree(dup);
	return 0;
}
static void __exit m_exit(void)
{
	unsigned int i;
	for (i = 0; i < nkp; i++) {
		unregister_kprobe(&kps[i]);
		pr_info("cedis: %s total hits=%lu\n", names[i], hits[i]);
		kfree(names[i]);
	}
	pr_info("cedis: BALANCE disables=%lu enables=%lu  LEAK=%ld\n",
		tot_dis, tot_en, (long)tot_dis - (long)tot_en);
	for (i = 0; i < nsite; i++)
		pr_info("cedis: site %pS eng=%lx  disables=%lu enables=%lu\n",
			(void *)sites[i].ret, sites[i].eng, sites[i].ndis, sites[i].nen);
}
module_init(m_init);
module_exit(m_exit);
MODULE_LICENSE("GPL");
