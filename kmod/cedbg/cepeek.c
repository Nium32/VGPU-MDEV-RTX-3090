// Read-only GA102 FIFO dump: every runlist block in full + every non-zero CHRAM
// word, so we can see WHERE the vgpu plugin's PTE-blit CE channel lives and what
// state it is in. Writes nothing. Returns -EAGAIN so nothing stays resident.
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
#define CH_LEN    0x10000u

static int samples = 8;
module_param(samples, int, 0444);
static int maxchid = 256;
module_param(maxchid, int, 0444);

static const char *chbits(u32 v, char *buf, int n)
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

static int __init cepeek_init(void)
{
	struct pci_dev *pdev;
	resource_size_t bar0;
	void __iomem *rl, *ch;
	unsigned int i, s, c;
	char b[128];

	pdev = pci_get_device(0x10de, PCI_ANY_ID, NULL);
	while (pdev && ((pdev->class >> 8) != PCI_CLASS_DISPLAY_VGA &&
	                (pdev->class >> 8) != PCI_CLASS_DISPLAY_3D))
		pdev = pci_get_device(0x10de, PCI_ANY_ID, pdev);
	if (!pdev) { pr_err("cepeek: no NVIDIA device\n"); return -ENODEV; }
	bar0 = pci_resource_start(pdev, 0);
	pr_info("cepeek: %s BAR0=0x%llx\n", pci_name(pdev), (unsigned long long)bar0);

	rl = ioremap(bar0 + RL_BASE, RL_LEN);
	ch = ioremap(bar0 + CH_BASE, CH_LEN);
	if (!rl || !ch) { pr_err("cepeek: ioremap failed\n"); goto out; }

	for (i = 0; i < RL_COUNT; i++) {
		u32 o = i * RL_STRIDE;
		u32 v00 = ioread32(rl + o + 0x00);
		u32 v04 = ioread32(rl + o + 0x04);
		u32 v08 = ioread32(rl + o + 0x08);
		u32 p0  = ioread32(rl + o + 0x10);
		u32 p1  = ioread32(rl + o + 0x14);
		u32 s80 = ioread32(rl + o + 0x80);
		u32 s84 = ioread32(rl + o + 0x84);
		u32 s88 = ioread32(rl + o + 0x88);
		u32 s8c = ioread32(rl + o + 0x8c);
		u32 v94 = ioread32(rl + o + 0x94);
		u32 v98 = ioread32(rl + o + 0x98);
		u32 v160= ioread32(rl + o + 0x160);
		if (v00 == 0xbadf1100u || v00 == 0xffffffffu) continue;
		pr_info("cepeek: rl%-2u @0x%06x cfg00=%08x chcfg=%08x(CHRAM=0x%06x n=%u) db08=%08x pb0=%08x pb1=%08x\n",
			i, RL_BASE+o, v00, v04, v04 & 0xfffffff0u, 1u << (v04 & 0xf), v08, p0, p1);
		pr_info("cepeek: rl%-2u   submit=%08x_%08x cnt=%u upd8c=%08x BLOCK=%u(+94=%08x) +98=%08x intr=%08x\n",
			i, s84, s80, s88 & 0xffffu, s8c, v94 & 1u, v94, v98, v160);
	}

	for (c = 0; c < (unsigned)maxchid; c++) {
		for (i = 0; i < 8; i++) {
			u32 chram = (CH_BASE + i*0x2000u);
			u32 v;
			if (chram + c*4 >= CH_BASE + CH_LEN) continue;
			v = ioread32(ch + (chram - CH_BASE) + c*4);
			if (v == 0 || v == 0xbadf1100u || v == 0xffffffffu) continue;
			pr_info("cepeek: CHRAM 0x%06x chid %-4u = 0x%08x %s\n",
				chram, c, v, chbits(v, b, sizeof(b)));
		}
	}

	for (s = 0; s < (unsigned)samples; s++) {
		u32 blk = 0, i2;
		char line[256]; line[0] = 0;
		for (i2 = 0; i2 < 9; i2++) {
			u32 o = i2 * RL_STRIDE;
			blk |= (ioread32(rl + o + 0x94) & 1u) << i2;
			scnprintf(line + strlen(line), sizeof(line) - strlen(line),
				"%u:%u/%u ", i2, ioread32(rl+o+0x94)&1u, ioread32(rl+o+0x88)&0xffffu);
		}
		pr_info("cepeek: s%u BLOCK=0x%03x  blk/cnt %s\n", s, blk, line);
		msleep(150);
	}

out:
	if (ch) iounmap(ch);
	if (rl) iounmap(rl);
	pci_dev_put(pdev);
	pr_info("cepeek: done (-EAGAIN, nothing stays loaded)\n");
	return -EAGAIN;
}
static void __exit cepeek_exit(void) { }
module_init(cepeek_init);
module_exit(cepeek_exit);
MODULE_LICENSE("GPL");
