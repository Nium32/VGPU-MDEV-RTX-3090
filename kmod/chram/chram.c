#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/delay.h>
#define WIN 0x1000000u
static int __init m_init(void){
    struct pci_dev *p=pci_get_device(0x10de,PCI_ANY_ID,NULL);
    void __iomem *b; resource_size_t bar0; u32 i,rl,cfg,cbase,nch,sub,pend;
    while(p&&((p->class>>8)!=PCI_CLASS_DISPLAY_VGA&&(p->class>>8)!=PCI_CLASS_DISPLAY_3D))
        p=pci_get_device(0x10de,PCI_ANY_ID,p);
    if(!p){pr_err("chram: no gpu\n");return -ENODEV;}
    bar0=pci_resource_start(p,0);
    b=ioremap(bar0,WIN);
    if(!b){pci_dev_put(p);return -ENOMEM;}
    for(rl=0;rl<=3;rl++){
        u32 base=0xc00000u+rl*0x400u;
        cfg =ioread32(b+base+0x04);
        sub =ioread32(b+base+0x88);
        pend=ioread32(b+base+0x8c);
        cbase=cfg&0xfffffff0u; nch=1u<<(cfg&0xfu);
        pr_info("chram: rl%u base=0x%06x cfg=0x%08x CHRAM=0x%06x nch=%u submit_len=%u pending=0x%08x BLOCK=%u\n",
                rl,base,cfg,cbase,nch,sub&0xffff,pend,ioread32(b+base+0x94)&1u);
        if(cbase>=0xc00000u && cbase<0xc00000u+WIN-0x4000u){
            for(i=0;i<32;i++){
                u32 c=ioread32(b+(cbase-0xc00000u)+i*4);
                if(c&&c!=0xbadf1100u)
                    pr_info("chram:   rl%u chid %2u = 0x%08x  EN=%u NEXT=%u BUSY=%u ON_PB=%u ON_ENG=%u PEND=%u ACQF=%u\n",
                        rl,i,c,!!(c&2),!!(c&4),!!(c&8),!!(c&64),!!(c&128),!!(c&256),!!(c&0x1000));
            }
        }
    }
    iounmap(b); pci_dev_put(p);
    pr_info("chram: done\n");
    return -EAGAIN;
}
static void __exit m_exit(void){}
module_init(m_init); module_exit(m_exit);
MODULE_LICENSE("GPL");
