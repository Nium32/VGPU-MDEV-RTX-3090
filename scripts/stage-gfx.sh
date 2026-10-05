#!/bin/bash
# Stage the 535.309.01 graphics userspace in an ISOLATED prefix. Nothing in /usr is
# touched: the system keeps its 580 DKMS userspace, and we select 535 per-process with
# LD_LIBRARY_PATH + __EGL_VENDOR_LIBRARY_FILENAMES + VK_DRIVER_FILES.
set +e
exec >> /home/vgpu/stage-gfx.log 2>&1
SRC=/srv/vgpu/VMs/driver/vgpu-merged-build/merged-535.309.01
P=/opt/nv535-gfx
echo "=== $(date +%T) staging into $P ==="
sudo rm -rf $P
sudo mkdir -p $P/lib $P/egl_vendor.d $P/vulkan/icd.d
n=0
for f in $(sudo ls -1 $SRC | grep -E '^lib.*\.so\.535\.309\.01$'); do
  sudo cp -n "$SRC/$f" "$P/lib/$f" 2>/dev/null && n=$((n+1))
done
echo "copied $n libraries"
# auto-create SONAME symlinks from each library's own DT_SONAME - no guessing
for f in $P/lib/*.so.535.309.01; do
  SO=$(readelf -d "$f" 2>/dev/null | awk -F'[][]' '/SONAME/{print $2}')
  [ -n "$SO" ] && [ "$SO" != "$(basename $f)" ] && sudo ln -sf "$(basename $f)" "$P/lib/$SO"
  BASE=$(basename "$f" .so.535.309.01)
  sudo ln -sf "$(basename $f)" "$P/lib/${BASE}.so"
done
echo "soname links: $(ls -1 $P/lib/*.so.[0-9]* 2>/dev/null | grep -v 535.309.01 | wc -l)"
# Vulkan ICD with an ABSOLUTE path so it cannot pick up the system 580 driver
GLX=$P/lib/libGLX_nvidia.so.535.309.01
sudo tee $P/vulkan/icd.d/nvidia_icd.json >/dev/null <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "$GLX",
        "api_version" : "1.3.242"
    }
}
EOF
# glvnd EGL vendor, absolute path
sudo tee $P/egl_vendor.d/10_nvidia.json >/dev/null <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "$P/lib/libEGL_nvidia.so.535.309.01"
    }
}
EOF
# one env file to source for any 535 GPU process
sudo tee $P/env.sh >/dev/null <<EOF
# source this to use the 535.309.01 NVIDIA userspace (CUDA + OpenGL + Vulkan + NVENC)
export LD_LIBRARY_PATH=$P/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export __EGL_VENDOR_LIBRARY_FILENAMES=$P/egl_vendor.d/10_nvidia.json
export VK_DRIVER_FILES=$P/vulkan/icd.d/nvidia_icd.json
export VK_ICD_FILENAMES=$P/vulkan/icd.d/nvidia_icd.json
export __GLX_VENDOR_LIBRARY_NAME=nvidia
EOF
sudo cp -n $SRC/nvidia-application-profiles-535.309.01-rc $P/ 2>/dev/null
echo "--- staged tree ---"
ls -1 $P; echo "libs: $(ls -1 $P/lib | wc -l)"
echo "key libs present:"
for l in libGLX_nvidia.so.535.309.01 libEGL_nvidia.so.535.309.01 libnvidia-glcore.so.535.309.01 libnvidia-eglcore.so.535.309.01 libnvidia-glvkspirv.so.535.309.01 libcuda.so.535.309.01 libnvidia-encode.so.535.309.01 libnvcuvid.so.535.309.01 libnvidia-tls.so.535.309.01 libnvidia-rtcore.so.535.309.01; do
  printf "  %-44s %s\n" "$l" "$([ -f $P/lib/$l ] && echo ok || echo MISSING)"
done
echo "--- system paths untouched? ---"
echo "  system nvidia_icd.json still: $(grep -o '\"library_path\"[^,]*' /usr/share/vulkan/icd.d/nvidia_icd.json 2>/dev/null)"
echo "  system libGLX_nvidia.so.0 -> $(readlink /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 2>/dev/null)"
echo "===== STAGE DONE ====="
