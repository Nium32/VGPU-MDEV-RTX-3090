// Read-only GA102 FIFO + PBDMA dump. Runlist blocks, every non-zero CHRAM word,
// and the full PBDMA register block for units 0..9, so a stuck host channel can
// be identified and its pending method read. Writes nothing; -EAGAIN on exit.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/delay.h>

#define RL_BASE   0xc00000u
#define RL_STRIDE 0x400u
#define RL_COUNT  16u
#define RL_LEN    (RL_STRIDE * RL_COUNT)
#define CH_BASE   0xc20000u
#define CH_LEN    0x12000u
#define PB_BASE   0x040000u
#define PB_STRIDE 0x800u
#define PB_COUNT  10u
#define PB_LEN    (PB_STRIDE * PB_COUNT)

static int samples = 10;
module_param(samples, int, 0444);
static int maxchid = 512;
module_param(maxchid, int, 0444);
static int chram = 1;
module_param(chram, int, 0444);

static const char *chb(u32 v, char *buf, int n)
{
	buf[0] = 0;
	if (v & (1u<<1)) strlcat(buf, "ENABLE|", n);
	if (v & (1u<<2)) strlcat(buf, "NEXT|", n);
	if (v & (1u<<3)) strlcat(buf, "BUSY|", n);
	if (v & (1u<<4)) strlcat(buf, "PBDMA_FAULTED|", n);
	if (v & (1u<<5)) strlcat(buf, "ENG_FAULTED|", n);
	if (v & (1u<<6)) strlcat(buf, "ON_PBDMA|", n);
	if (v & (1u<<7)) strlcat(buf, "ON_ENG|", n);
	if (v & (1u<<8)) strlcat(buf, "PENDING|", n);
	if (v & (1u<<9)) strlcat(buf, "CTX_RELOAD|", n);
	if (v & (1u<<12)) strlcat(buf, "ACQUIRE_FAIL|", n);
	return buf;
}

static int __init cepeek2_init(void)
{
	struct pci_dev *pdev;
	resource_size_t bar0;
	void __iomem *rl = NULL, *ch = NULL, *pb = NULL;
	unsigned int i, s, c;
	char b[160];

	pdev = pci_get_device(0x10de, PCI_ANY_ID, NULL);
	while (pdev && ((pdev->class >> 8) != PCI_CLASS_DISPLAY_VGA &&
	                (pdev->class >> 8) != PCI_CLASS_DISPLAY_3D))
		pdev = pci_get_device(0x10de, PCI_ANY_ID, pdev);
	if (!pdev) { pr_err("cepeek2: no NVIDIA device\n"); return -ENODEV; }
	bar0 = pci_resource_start(pdev, 0);
	pr_info("cepeek2: %s BAR0=0x%llx\n", pci_name(pdev), (unsigned long long)bar0);

	rl = ioremap(bar0 + RL_BASE, RL_LEN);
	ch = ioremap(bar0 + CH_BASE, CH_LEN);
	pb = ioremap(bar0 + PB_BASE, PB_LEN);
	if (!rl || !ch || !pb) { pr_err("cepeek2: ioremap failed\n"); goto out; }

	for (i = 0; i < RL_COUNT; i++) {
		u32 o = i * RL_STRIDE;
		u32 v00 = ioread32(rl + o + 0x00);
		u32 v04 = ioread32(rl + o + 0x04);
		u32 s80 = ioread32(rl + o + 0x80), s84 = ioread32(rl + o + 0x84);
		u32 s88 = ioread32(rl + o + 0x88), s8c = ioread32(rl + o + 0x8c);
		u32 v94 = ioread32(rl + o + 0x94), v98 = ioread32(rl + o + 0x98);
		if (v00 == 0xbadf1100u || v00 == 0xffffffffu) continue;
		pr_info("cepeek2: rl%-2u CHRAM=0x%06x sub=%08x_%08x cnt=%u upd=%08x BLOCK=%u +98=%08x pb=[%08x %08x]\n",
			i, v04 & 0xfffffff0u, s84, s80, s88 & 0xffffu, s8c, v94 & 1u, v98,
			ioread32(rl + o + 0x10), ioread32(rl + o + 0x14));
	}

	if (chram) for (c = 0; c < (unsigned)maxchid; c++) {
		for (i = 0; i < 9; i++) {
			u32 base = CH_BASE + i*0x2000u;
			u32 v;
			if (base - CH_BASE + c*4 >= CH_LEN) continue;
			v = ioread32(ch + (base - CH_BASE) + c*4);
			if (v == 0 || v == 0xbadf1100u || v == 0xffffffffu) continue;
			pr_info("cepeek2: CHRAM rl%u chid %-4u = 0x%08x %s\n", i, c, v, chb(v, b, sizeof(b)));
		}
	}

	for (i = 0; i < PB_COUNT; i++) {
		u32 o = i * PB_STRIDE;
		u32 sig = ioread32(pb + o + 0x010);
		u32 chn = ioread32(pb + o + 0x120);
		u32 cid = ioread32(pb + o + 0x124);
		u32 i0  = ioread32(pb + o + 0x108);
		u32 i1  = ioread32(pb + o + 0x148);
		u32 st  = ioread32(pb + o + 0x15c);
		u32 m0  = ioread32(pb + o + 0x0c0), d0 = ioread32(pb + o + 0x0c4);
		u32 m1  = ioread32(pb + o + 0x0c8), d1 = ioread32(pb + o + 0x0cc);
		u32 sp  = ioread32(pb + o + 0x038), sa = ioread32(pb + o + 0x03c);
		u32 gl  = ioread32(pb + o + 0x048), gh = ioread32(pb + o + 0x04c);
		u32 inst= ioread32(pb + o + 0x130), ud = ioread32(pb + o + 0x140);
		if (sig == 0xbadf1100u || sig == 0xffffffffu) continue;
		pr_info("cepeek2: PB%u sig=%08x CHAN=%08x chid=%u INTR0=%08x INTR1=%08x stat=%08x\n",
			i, sig, chn, cid, i0, i1, st);
		pr_info("cepeek2: PB%u   M0=%08x D0=%08x M1=%08x D1=%08x sem=%08x@%08x gp=%08x_%08x inst=%08x userd=%08x\n",
			i, m0, d0, m1, d1, sp, sa, gh, gl, inst, ud);
	}

	for (s = 0; s < (unsigned)samples; s++) {
		char line[320]; unsigned int i2; line[0] = 0;
		for (i2 = 0; i2 < 9; i2++) {
			u32 o = i2 * RL_STRIDE;
			scnprintf(line + strlen(line), sizeof(line) - strlen(line),
				"%u:b%u/n%u ", i2, ioread32(rl+o+0x94)&1u, ioread32(rl+o+0x88)&0xffffu);
		}
		pr_info("cepeek2: s%u %s\n", s, line);
		msleep(150);
	}
out:
	if (pb) iounmap(pb);
	if (ch) iounmap(ch);
	if (rl) iounmap(rl);
	pci_dev_put(pdev);
	pr_info("cepeek2: done (-EAGAIN)\n");
	return -EAGAIN;
}
static void __exit cepeek2_exit(void) { }
module_init(cepeek2_init);
module_exit(cepeek2_exit);
MODULE_LICENSE("GPL");
