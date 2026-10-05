# Why `run-key0.sh` is dangerous

`run-key0.sh` boots `win-key0.qcow2` **read-write**. On the machine this was developed on,
`win-key0.qcow2` is not a leaf — it is the backing file of the image the guest actually runs:

```
win-test.qcow2            <- what startguest.sh boots
  └─ win-key0.qcow2       <- what run-key0.sh boots, read-write
       └─ win-vgpu-wsys53972.qcow2
            └─ win-vgpu-test.qcow2
```

QEMU's file locking stops both being open simultaneously, so this never fails loudly. It fails
*sequentially*: boot `run-key0.sh` once after the overlay exists, and `win-test.qcow2` is silently
invalidated along with everything layered on it. The guest then boots into a corrupted filesystem.

`win-key0.qcow2` also backs `win-nogpu.qcow2` and `win-trigger/trig.qcow2`, so a single
read-write boot of it invalidates three overlays at once.

Separately, `run-key0.sh`, `resume.sh` and `bptest.sh` all pass the **same** `$D/OVMF_VARS.fd`.
Two guests sharing one NVRAM file overwrite each other's boot entries.

## If you want to use it

- Protect the base: `chmod 0444 win-key0.qcow2`, so QEMU and `qemu-nbd` refuse a read-write open
  instead of silently succeeding.
- Give every guest its own directory with its own qcow2 and its own `OVMF_VARS.fd`.
- Check before you boot anything read-write:
  ```bash
  qemu-img info -U --backing-chain /var/lib/vgpu-vm/<vm>/<disk>.qcow2
  ```

`../startguest.sh` now does that check itself and refuses to boot a disk that another image in the
same directory overlays.
