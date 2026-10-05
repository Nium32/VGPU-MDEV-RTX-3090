# Convenience targets. Nothing here touches the GPU or loads anything.
#
#   make modules   build the two required kernel modules plus isrfind
#   make probes    build the read-only diagnostic modules as well
#   make check     syntax and shellcheck the supported scripts
#   make install   copy the built modules into VGPU_ROOT with per-kernel names
#   make clean     remove build output

KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build
VGPU_ROOT ?= /srv/vgpu/VMs

# Needed at runtime. zfmulti is the one necessary intervention; mdguest is
# loaded by the working configuration although it measures as inert.
REQUIRED  := zfmulti mdguest
# Useful when porting to a driver build whose ISR offset is not known yet.
TOOLS     := isrfind
# Read-only probes used during the investigation. Not needed to run anything.
PROBES    := fifopeek barscan barregs fbpeek2 instpeek bar1walk userdpeek rldump2 chram cedbg

# The scripts that are supported and must stay clean. The ones under
# scripts/as-run/ are kept for provenance and are deliberately not checked:
# they hard-code one machine and are documented as not for reuse.
SUPPORTED := lib/common.sh \
             scripts/preflight.sh \
             scripts/bringup.sh \
             scripts/startguest.sh \
             scripts/hardreset.sh

.PHONY: all modules probes tools check shellcheck syntax install clean help

all: modules

help:
	@sed -n '2,8p' $(MAKEFILE_LIST)

modules: $(addprefix build-,$(REQUIRED) $(TOOLS))

probes: modules $(addprefix build-,$(PROBES))

tools: $(addprefix build-,$(TOOLS))

build-%:
	@if [ -d kmod/$* ]; then \
	    echo "==> kmod/$*"; \
	    $(MAKE) -s -C $(KDIR) M=$(CURDIR)/kmod/$* modules || exit 1; \
	else \
	    echo "==> kmod/$* not present, skipping"; \
	fi

# A module built for one kernel cannot load on another: insmod rejects the
# version magic. So everything is installed with the kernel version in the name
# and the scripts look for that first.
install: modules
	@for m in $(REQUIRED) $(TOOLS); do \
	    if [ -f kmod/$$m/$$m.ko ]; then \
	        install -d "$(VGPU_ROOT)/kmod/$$m"; \
	        install -m 0644 kmod/$$m/$$m.ko "$(VGPU_ROOT)/kmod/$$m/$$m-$(KVER).ko"; \
	        echo "installed $(VGPU_ROOT)/kmod/$$m/$$m-$(KVER).ko"; \
	    fi; \
	done

check: syntax shellcheck

syntax:
	@fail=0; \
	for f in $$(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh'); do \
	    bash -n "$$f" || fail=1; \
	    if tr -cd '\000' < "$$f" | read -r _; then \
	        echo "$$f: contains a NUL byte"; fail=1; \
	    fi; \
	done; \
	[ $$fail -eq 0 ] && echo "bash -n: clean, no NUL bytes" || exit 1

# The supported scripts must be clean at -S warning. Keep them that way.
shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck -S warning -e SC1091 $(SUPPORTED) \
	        && echo "shellcheck: supported scripts clean"; \
	    echo "--- scripts/as-run/ and the not-yet-generalised scripts, informational only ---"; \
	    shellcheck -S warning -e SC1091 $$(git ls-files 'scripts/*.sh' 'scripts/as-run/*.sh' 2>/dev/null \
	        | grep -vxF -e scripts/preflight.sh -e scripts/bringup.sh \
	                    -e scripts/startguest.sh -e scripts/hardreset.sh) \
	        2>/dev/null | grep -c '^In ' | sed 's/^/findings: /' || true; \
	else \
	    echo "shellcheck not installed - skipping. Install it to run this check:"; \
	    echo "  pacman -S shellcheck   |   apt install shellcheck   |   winget install koalaman.shellcheck"; \
	fi

clean:
	@for d in kmod/*/; do \
	    [ -f "$$d/Makefile" ] && $(MAKE) -s -C $(KDIR) M=$(CURDIR)/$$d clean >/dev/null 2>&1; \
	done; \
	echo "cleaned"
