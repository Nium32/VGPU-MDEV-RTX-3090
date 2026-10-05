// Dump GA102 FIFO runlist registers from kernel space.
//
// Userspace cannot do this: nvidia.ko calls pci_request_regions() on BAR0, so
// mmap of /sys/bus/pci/devices/.../resource0 returns EINVAL. ioremap from a
// module is not blocked by that claim.
//
// Reads only - never writes. Maps just the runlist window (0xc00000..0xc04000),
// not the whole 16 MB BAR, to avoid the large-ioremap warning.
//
// Loads, prints to dmesg, then returns -EAGAIN so insmod fails and nothing stays
// resident. Use:  sudo insmod fifopeek.ko ; dmesg | tail -40
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/delay.h>

#define RL_BASE   0xc00000u
#define RL_STRIDE 0x400u
#define RL_COUNT  16u
#define WIN_LEN   (RL_STRIDE * RL_COUNT)

static int samples = 5;
module_param(samples, int, 0444);
MODULE_PARM_DESC(samples, "how many times to re-read the BLOCK bits");

static int __init fifopeek_init(void)
{
    struct pci_dev *pdev;
    resource_size_t bar0;
    void __iomem *rl;
    unsigned int i, s;

    pdev = pci_get_device(0x10de, PCI_ANY_ID, NULL);
    while (pdev && ((pdev->class >> 8) != PCI_CLASS_DISPLAY_VGA &&
                    (pdev->class >> 8) != PCI_CLASS_DISPLAY_3D))
        pdev = pci_get_device(0x10de, PCI_ANY_ID, pdev);
    if (!pdev) {
        pr_err("fifopeek: no NVIDIA display device found\n");
        return -ENODEV;
    }
    bar0 = pci_resource_start(pdev, 0);
    pr_info("fifopeek: %s BAR0=0x%llx len=0x%llx\n", pci_name(pdev),
            (unsigned long long)bar0,
            (unsigned long long)pci_resource_len(pdev, 0));

    rl = ioremap(bar0 + RL_BASE, WIN_LEN);
    if (!rl) {
        pr_err("fifopeek: ioremap failed\n");
        pci_dev_put(pdev);
        return -ENOMEM;
    }

    for (i = 0; i < RL_COUNT; i++) {
        u32 off = i * RL_STRIDE;
        u32 v00 = ioread32(rl + off + 0x00);
        u32 v94 = ioread32(rl + off + 0x94);
        u32 v98 = ioread32(rl + off + 0x98);
        if (v00 == 0xffffffffu && v94 == 0xffffffffu)
            continue;
        pr_info("fifopeek: rl%-2u @0x%06x +00=0x%08x +94=0x%08x BLOCK=%u +98=0x%08x\n",
                i, RL_BASE + off, v00, v94, v94 & 1u, v98);
    }

    for (s = 0; s < (unsigned)samples; s++) {
        u32 b = 0;
        for (i = 0; i < 8; i++)
            b |= (ioread32(rl + i * RL_STRIDE + 0x94) & 1u) << i;
        pr_info("fifopeek: sample %u BLOCK bits rl0..rl7 = 0x%02x\n", s, b);
        msleep(200);
    }

    iounmap(rl);
    pci_dev_put(pdev);
    pr_info("fifopeek: done (returning -EAGAIN so nothing stays loaded)\n");
    return -EAGAIN;
}

static void __exit fifopeek_exit(void) { }

module_init(fifopeek_init);
module_exit(fifopeek_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("read-only GA102 FIFO runlist register dump");
