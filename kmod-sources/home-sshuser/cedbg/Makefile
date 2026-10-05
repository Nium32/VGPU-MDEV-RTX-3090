obj-m := cepeek.o cedis.o cepeek2.o
KDIR ?= /usr/lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
