/* Force the x86 ZF flag at several <symbol>+<offset> sites.
 * spec syntax:  sym+0xOFF:V,sym+0xOFF:V,...   V=1 set ZF, V=0 clear ZF
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/slab.h>
#include <linux/string.h>

#define MAXS 12
#define ZF (1UL << 6)

static char *spec = "";
module_param(spec, charp, 0444);

struct site {
	char name[40];
	unsigned long off;
	int val;
	struct kprobe kp;
	unsigned long hits;
	int armed;
};
static struct site tab[MAXS];
static int ns;

static int pre(struct kprobe *p, struct pt_regs *regs)
{
	int i;
	for (i = 0; i < ns; i++) {
		if (&tab[i].kp != p) continue;
		tab[i].hits++;
		if (tab[i].val) regs->flags |= ZF;
		else regs->flags &= ~ZF;
		return 0;
	}
	return 0;
}

static int __init m_init(void)
{
	char *dup, *p, *tok;
	int rc;
	dup = kstrdup(spec, GFP_KERNEL);
	if (!dup) return -ENOMEM;
	p = dup;
	while ((tok = strsep(&p, ",")) && ns < MAXS) {
		char *plus, *colon;
		if (!*tok) continue;
		plus = strchr(tok, '+');
		colon = strrchr(tok, ':');
		if (!plus || !colon || colon < plus) { pr_info("zfmulti: bad spec '%s'\n", tok); continue; }
		*plus = 0; *colon = 0;
		strscpy(tab[ns].name, tok, sizeof(tab[ns].name));
		if (kstrtoul(plus + 1, 0, &tab[ns].off)) { pr_info("zfmulti: bad off\n"); continue; }
		tab[ns].val = (colon[1] != '0');
		tab[ns].kp.pre_handler = pre;
		tab[ns].kp.symbol_name = tab[ns].name;
		tab[ns].kp.offset = (unsigned int)tab[ns].off;
		rc = register_kprobe(&tab[ns].kp);
		if (rc) {
			pr_info("zfmulti: FAILED %s+0x%lx rc=%d\n", tab[ns].name, tab[ns].off, rc);
			tab[ns].armed = 0;
		} else {
			tab[ns].armed = 1;
			pr_info("zfmulti: armed %s+0x%lx setzf=%d\n", tab[ns].name, tab[ns].off, tab[ns].val);
		}
		ns++;
	}
	kfree(dup);
	return 0;
}
static void __exit m_exit(void)
{
	int i;
	for (i = 0; i < ns; i++) {
		if (tab[i].armed) unregister_kprobe(&tab[i].kp);
		pr_info("zfmulti: TOTAL %s+0x%lx setzf=%d hits=%lu\n",
			tab[i].name, tab[i].off, tab[i].val, tab[i].hits);
	}
}
module_init(m_init);
module_exit(m_exit);
MODULE_LICENSE("GPL");
