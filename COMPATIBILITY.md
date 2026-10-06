# Compatibility table

What is known to work, what is known to fail, and what nobody has tried. This is the most useful
thing this repository can grow, and it can only grow from other people's results.

**If you test a combination, please add a row and open a pull request** — including a failure. A
confirmed "this does not work" saves the next person as much time as a success.

## Host kernels

Driver 535.309.01 throughout. Same host, same configuration, only the kernel changed.

| kernel | works | pteblit timeouts | plugin errors | notes |
|---|---|---|---|---|
| 5.15.95-051595-generic | yes | 0 | 0 | measured on a separate install; unusable on a btrfs root with `BLOCK_GROUP_TREE` |
| 6.1.71-1-lts | **yes** | 0 | 0 | the reference configuration |
| 6.2.x | **untried** | | | |
| 6.3.x | **untried** | | | |
| 6.4.x | **untried** | | | |
| 6.5.x | **untried** | | | |
| 6.6.x LTS | **untried** | | | the obvious one to test — an LTS in the unknown gap |
| 6.7.x | **untried** | | | |
| 6.8.9-arch1-2 | no | 50 | 100 | `Immediate pteblit ... timed out` |
| 6.12.x LTS | **untried** | | | |
| 6.18.52-1-cachyos-lts | no | ~76 | ~152 | approximate counts, recorded with tildes |

The boundary is somewhere between 6.1 and 6.8 and **the mechanism is not identified**. An early
guess blamed the vfio pin-page rework at 6.0; that was wrong, since 6.1 works. Reading the 550
driver's handling of that API showed no defect.

Testing 6.6 LTS would be the single most valuable datapoint anyone could contribute.

## GPUs

| GPU | chip | PCI ID | spoofed as | works | notes |
|---|---|---|---|---|---|
| GeForce RTX 3090 | GA102 | `10de:2204` | `10de:2231` RTX A5000 | **yes** | the reference card. VBIOS 94.02.42.40.b7 |
| RTX 3080 / 3080 Ti | GA102/GA102 | | | **untried** | same chip family, so the most likely next success |
| RTX 3090 Ti | GA102 | `10de:2203` | | **untried** | |
| RTX 3070 / 3060 | GA104/GA106 | | | **untried** | different chip, FIFO map may differ |
| Turing (20-series) | TUxxx | | | **untried** | |
| Ada (40-series) | ADxxx | | | **untried** | |
| Blackwell (50-series) | GB202 | | | **no** | fused off in hardware. [bird/vgpu-unlock-blackwell](https://github.com/bird/vgpu-unlock-blackwell) got the whole CPU-side pipeline working and still hit it: VF PRIV regs at `0x111xxx` read `0xbadf1002`, and the plugin now lives in GSP firmware with nothing left to intercept |

Anything that is not GA102 needs the ISR offset re-derived. That is
[docs/FINDING-THE-ISR-OFFSET.md](docs/FINDING-THE-ISR-OFFSET.md), and `kmod/isrfind` automates the
tedious part of it.

## Host drivers

| driver | works | notes |
|---|---|---|
| 535.309.01 (merged vgpu-kvm) | **yes** | the reference. ISR offset `_nv042311rm+0x28` |
| 550.163.02 | unknown | builds on 6.18, never brought up. ISR symbol unchecked. |
| 580.126.08 | no | the FIFO HAL is SR-IOV-only, and consumer Ampere has no SR-IOV |
| 510.73.06 | no | tried as a matched pre-GSP pair with guest 512.78; still fails |

## Guest drivers

| driver | works | notes |
|---|---|---|
| 539.72 GRID DCH (Windows) | **yes** | the reference. CUDA 12.2, compute capability 8.6 |
| 512.78 (vGPU 14.2, Windows) | no | negotiates cross-branch at vGPU version `0xd0001`, still fails |
| 553.74 (Windows) | no | more stubbed than 539.72 on the relevant path |
| Linux GRID guest on a 535 host | no | `RmInitAdapter failed! 0x41:0x40:2639` — same failure, so the Windows-guest axis was eliminated |

## Profiles

| profile | works | notes |
|---|---|---|
| `RTXA5000-8Q` (`nvidia-664`) | **yes** | the reference. 8192 MB, max 3 instances |
| `RTXA5000-8A` (`nvidia-672`) | no | `cuCtxCreate` returns 801 NOT_SUPPORTED, no channel ever scheduled |
| other `Q` profiles | **untried** | the 12Q and 24Q ones should be tested |
| any `B` profile | **untried** | |

Resolve profiles by **name**, never by the `nvidia-NNN` id — the number is assigned per driver
version and per board.

## Host platforms

| platform | works | notes |
|---|---|---|
| Ryzen 7 2700, ASUS PRIME X370-PRO, BIOS 6232 | **yes** | the reference. No `amd_iommu=` parameter needed, no ACS override, ReBAR untouched |
| any Intel platform | **untried** | would need `intel_iommu=on` |
| any other AMD platform | **untried** | |

The platform has never been the hard part. A six-year-old eight-core on a first-generation Ryzen
chipset is sufficient.

## Host distributions

| distribution | works | notes |
|---|---|---|
| CachyOS (arch-like), rolling | **yes** | the reference |
| Arch | **untried** | should be identical |
| Debian 12 bookworm | **yes — CUDA-ALL-PASS** | kernel 6.1.0-53-amd64, compute verified by readback. Needs the split-header fix and `/etc/vgpu_unlock/config.toml`; see [BUILDING-ON-DEBIAN.md](docs/BUILDING-ON-DEBIAN.md) |
| Ubuntu | **untried** | same header split as Debian, so the same fix should apply |
| Proxmox VE 8.4 on Debian 12 | **yes — CUDA-ALL-PASS** | installed on top of Debian 12 keeping the 6.1 kernel; `pve-manager/8.4.21` on 6.1.0-53-amd64, 18 profiles, Xid 0. See [PROXMOX.md](docs/PROXMOX.md). Not installable from its own ISO - every current Proxmox kernel is 6.8 or newer |
| Fedora / RHEL | **untried** | some ship a 2 MB OVMF under a generic name, which will not pair with a 4 MB VARS |

## How to add a row

Include, at minimum:

- exact kernel (`uname -r`) and exact host driver version
- the GPU, its real PCI ID, and what you spoofed it to
- the profile name you used
- whether guest CUDA **verified by reading data back** — not merely "no errors"
- the three counters over your run: `Immediate pteblit`, `error:`, `XID [0-9]+ detected`
- if you found a new ISR offset, the symbol, the offset, and how you confirmed the leak went to zero

The output of `scripts/preflight.sh` covers most of that on its own.
