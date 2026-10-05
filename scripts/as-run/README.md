# As-run scripts

These are the scripts exactly as they run on the machine this was developed on, with
machine-specific values replaced by placeholders. They are kept for provenance: they are the
versions that produced the measured results, and they are shorter and easier to read than the
generalised ones in the parent directory.

They are **not** portable. They hard-code a PCI address, an IOMMU group, a profile id, an OVMF
path and a VM name. Use `../bringup.sh`, `../startguest.sh` and `../hardreset.sh` instead,
which discover all of that at runtime, and run `../preflight.sh` first.

Two bugs in these versions, found while generalising them and worth knowing if you read them:

- `startguest.sh` loads OVMF from `/usr/share/OVMF/OVMF_CODE_4M.fd`, which is the Debian path.
  On the Arch-family host it actually ran on, the file is at
  `/usr/share/edk2/x64/OVMF_CODE.4m.fd`.
- `hardreset.sh` describes the wedged IOMMU group as group 22 in its comments. The group number
  is per-machine and changes across reboots; on the same host it was later group 15.
