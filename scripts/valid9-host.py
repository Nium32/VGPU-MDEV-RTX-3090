# Strong validation v9. Two changes from v8:
#   - .version 7.5 (sm_86 requires PTX ISA >= 7.1; .version 7.0 + .target sm_86 is invalid)
#   - cuModuleLoadDataEx with CU_JIT_ERROR_LOG_BUFFER so the driver reports the real error
import ctypes, sys, time

cu = ctypes.CDLL("libcuda.so.1")

def err(rc):
    b = ctypes.c_char_p()
    try: cu.cuGetErrorString(ctypes.c_int(rc), ctypes.byref(b))
    except Exception: return ""
    return (b.value or b"").decode()

def chk(name, rc):
    print("%-24s rc=%d %s" % (name, rc, err(rc) if rc else ""), flush=True)
    if rc != 0: sys.exit(1)

MINI = b"""//
.version 7.5
.target sm_86
.address_size 64
.visible .entry nop_k(.param .u64 nop_k_p0)
{
    .reg .b32 %r<2>;
    .reg .b64 %rd<3>;
    ld.param.u64    %rd1, [nop_k_p0];
    cvta.to.global.u64 %rd2, %rd1;
    mov.u32         %r1, 1431655765;
    st.global.u32   [%rd2], %r1;
    ret;
}
"""

FULL = b"""//
.version 7.5
.target sm_86
.address_size 64
.visible .entry fill(.param .u64 fill_p0, .param .u32 fill_p1)
{
    .reg .pred %p<2>;
    .reg .b32  %r<10>;
    .reg .b64  %rd<6>;
    ld.param.u64    %rd1, [fill_p0];
    ld.param.u32    %r1,  [fill_p1];
    cvta.to.global.u64 %rd2, %rd1;
    mov.u32         %r2, %ctaid.x;
    mov.u32         %r3, %ntid.x;
    mov.u32         %r4, %tid.x;
    mad.lo.s32      %r5, %r2, %r3, %r4;
    setp.ge.s32     %p1, %r5, %r1;
    @%p1 bra        $L_fill_done;
    mul.wide.s32    %rd3, %r5, 4;
    add.s64         %rd4, %rd2, %rd3;
    mul.lo.s32      %r6, %r5, 3;
    add.s32         %r7, %r6, 7;
    st.global.u32   [%rd4], %r7;
$L_fill_done:
    ret;
}
.visible .entry dbl(.param .u64 dbl_p0, .param .u32 dbl_p1)
{
    .reg .pred %p<2>;
    .reg .b32  %r<10>;
    .reg .b64  %rd<6>;
    ld.param.u64    %rd1, [dbl_p0];
    ld.param.u32    %r1,  [dbl_p1];
    cvta.to.global.u64 %rd2, %rd1;
    mov.u32         %r2, %ctaid.x;
    mov.u32         %r3, %ntid.x;
    mov.u32         %r4, %tid.x;
    mad.lo.s32      %r5, %r2, %r3, %r4;
    setp.ge.s32     %p1, %r5, %r1;
    @%p1 bra        $L_dbl_done;
    mul.wide.s32    %rd3, %r5, 4;
    add.s64         %rd4, %rd2, %rd3;
    ld.global.u32   %r6, [%rd4];
    shl.b32         %r7, %r6, 1;
    st.global.u32   [%rd4], %r7;
$L_dbl_done:
    ret;
}
"""

CU_JIT_INFO_LOG_BUFFER = 3
CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES = 4
CU_JIT_ERROR_LOG_BUFFER = 5
CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES = 6

def load_ex(ptx, tag):
    LOGSZ = 16384
    ilog = ctypes.create_string_buffer(LOGSZ)
    elog = ctypes.create_string_buffer(LOGSZ)
    opts = (ctypes.c_int * 4)(CU_JIT_INFO_LOG_BUFFER, CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES,
                              CU_JIT_ERROR_LOG_BUFFER, CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES)
    vals = (ctypes.c_void_p * 4)(ctypes.cast(ilog, ctypes.c_void_p), ctypes.c_void_p(LOGSZ),
                                 ctypes.cast(elog, ctypes.c_void_p), ctypes.c_void_p(LOGSZ))
    mod = ctypes.c_void_p()
    rc = cu.cuModuleLoadDataEx(ctypes.byref(mod), ptx, ctypes.c_uint(4), opts, vals)
    print("cuModuleLoadDataEx[%s] rc=%d %s" % (tag, rc, err(rc) if rc else ""), flush=True)
    if ilog.value: print("  JIT info : %s" % ilog.value.decode(errors="replace"), flush=True)
    if elog.value: print("  JIT error: %s" % elog.value.decode(errors="replace"), flush=True)
    return rc, mod

chk("cuInit", cu.cuInit(0))
dev = ctypes.c_int()
chk("cuDeviceGet", cu.cuDeviceGet(ctypes.byref(dev), 0))
nm = ctypes.create_string_buffer(128); cu.cuDeviceGetName(nm, 128, dev)
cc_maj = ctypes.c_int(); cc_min = ctypes.c_int()
cu.cuDeviceComputeCapability(ctypes.byref(cc_maj), ctypes.byref(cc_min), dev)
print("device: %s  cc=%d.%d" % (nm.value.decode(), cc_maj.value, cc_min.value), flush=True)
ctx = ctypes.c_void_p()
chk("cuCtxCreate_v2", cu.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev))

rc, mmod = load_ex(MINI, "mini")
if rc == 0:
    k = ctypes.c_void_p()
    chk("cuModuleGetFunction/nop_k", cu.cuModuleGetFunction(ctypes.byref(k), mmod, b"nop_k"))
    d0 = ctypes.c_void_p()
    chk("cuMemAlloc_v2/mini", cu.cuMemAlloc_v2(ctypes.byref(d0), ctypes.c_size_t(4096)))
    cu.cuMemsetD32_v2(d0, ctypes.c_uint(0), ctypes.c_size_t(1024))
    a0 = (ctypes.c_void_p * 1)(ctypes.cast(ctypes.byref(d0), ctypes.c_void_p))
    chk("cuLaunchKernel/nop_k", cu.cuLaunchKernel(k, 1, 1, 1, 1, 1, 1, 0, None, a0, None))
    chk("cuCtxSynchronize/mini", cu.cuCtxSynchronize())
    h0 = (ctypes.c_uint * 1)()
    chk("cuMemcpyDtoH/mini", cu.cuMemcpyDtoH_v2(h0, d0, ctypes.c_size_t(4)))
    print("MINI-KERNEL: got %08x want 55555555 -> %s" % (h0[0], "PASS" if h0[0] == 0x55555555 else "FAIL"), flush=True)
    cu.cuMemFree_v2(d0); cu.cuModuleUnload(mmod)

rc, mod = load_ex(FULL, "full")
if rc != 0:
    print("STRONG-VALIDATION-FAIL (full module did not load)", flush=True)
    cu.cuCtxDestroy_v2(ctx); sys.exit(1)

kfill = ctypes.c_void_p(); kdbl = ctypes.c_void_p()
chk("cuModuleGetFunction/fill", cu.cuModuleGetFunction(ctypes.byref(kfill), mod, b"fill"))
chk("cuModuleGetFunction/dbl", cu.cuModuleGetFunction(ctypes.byref(kdbl), mod, b"dbl"))

N = 4 * 1024 * 1024
NB = N * 4
d = ctypes.c_void_p(); d2 = ctypes.c_void_p()
chk("cuMemAlloc_v2", cu.cuMemAlloc_v2(ctypes.byref(d), ctypes.c_size_t(NB)))
chk("cuMemAlloc_v2#2", cu.cuMemAlloc_v2(ctypes.byref(d2), ctypes.c_size_t(NB)))
chk("cuMemsetD32_v2", cu.cuMemsetD32_v2(d, ctypes.c_uint(0xA5A5A5A5), ctypes.c_size_t(N)))

TPB = 256; GRID = (N + TPB - 1) // TPB
pN = ctypes.c_int(N)
args = (ctypes.c_void_p * 2)(ctypes.cast(ctypes.byref(d), ctypes.c_void_p),
                             ctypes.cast(ctypes.byref(pN), ctypes.c_void_p))
t0 = time.time()
chk("cuLaunchKernel/fill", cu.cuLaunchKernel(kfill, GRID, 1, 1, TPB, 1, 1, 0, None, args, None))
chk("cuCtxSynchronize", cu.cuCtxSynchronize())
print("fill launch+sync %.3fs grid=%d tpb=%d" % (time.time() - t0, GRID, TPB), flush=True)

host = (ctypes.c_uint * N)()
chk("cuMemcpyDtoH_v2", cu.cuMemcpyDtoH_v2(host, d, ctypes.c_size_t(NB)))
bad = -1
for i in range(N):
    if host[i] != (i * 3 + 7) & 0xffffffff: bad = i; break
print("KERNEL-FILL verify: %s firstbad=%d first4=%08x %08x %08x %08x"
      % ("PASS" if bad < 0 else "FAIL", bad, host[0], host[1], host[2], host[3]), flush=True)

chk("cuMemcpyDtoD_v2", cu.cuMemcpyDtoD_v2(d2, d, ctypes.c_size_t(NB)))
args2 = (ctypes.c_void_p * 2)(ctypes.cast(ctypes.byref(d2), ctypes.c_void_p),
                              ctypes.cast(ctypes.byref(pN), ctypes.c_void_p))
chk("cuLaunchKernel/dbl", cu.cuLaunchKernel(kdbl, GRID, 1, 1, TPB, 1, 1, 0, None, args2, None))
chk("cuCtxSynchronize#2", cu.cuCtxSynchronize())
host2 = (ctypes.c_uint * N)()
chk("cuMemcpyDtoH_v2#2", cu.cuMemcpyDtoH_v2(host2, d2, ctypes.c_size_t(NB)))
bad2 = -1
for i in range(N):
    if host2[i] != ((i * 3 + 7) * 2) & 0xffffffff: bad2 = i; break
print("KERNEL-DBL  verify: %s firstbad=%d first4=%08x %08x %08x %08x"
      % ("PASS" if bad2 < 0 else "FAIL", bad2, host2[0], host2[1], host2[2], host2[3]), flush=True)

fails = 0
for it in range(10):
    cu.cuMemsetD32_v2(d, ctypes.c_uint(0), ctypes.c_size_t(N))
    cu.cuLaunchKernel(kfill, GRID, 1, 1, TPB, 1, 1, 0, None, args, None)
    cu.cuCtxSynchronize()
    cu.cuMemcpyDtoH_v2(host, d, ctypes.c_size_t(NB))
    if not all(host[j] == (j * 3 + 7) & 0xffffffff for j in (0, 1, N // 2, N - 1)): fails += 1
print("LOOP 10 iterations: fails=%d" % fails, flush=True)

cu.cuMemFree_v2(d); cu.cuMemFree_v2(d2); cu.cuModuleUnload(mod); cu.cuCtxDestroy_v2(ctx)
print("STRONG-VALIDATION-%s" % ("PASS" if (bad < 0 and bad2 < 0 and fails == 0) else "FAIL"), flush=True)
