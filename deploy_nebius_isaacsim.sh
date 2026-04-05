#!/bin/bash
# =============================================================================
# Deploy Isaac Sim + Isaac Lab on a Nebius GPU instance
#
# Fixes the missing Vulkan/NVENC libraries that Nebius doesn't install.
# Validated 2026-04-04 on Nebius L40S (gpu-l40s-a, ubuntu22.04-cuda12).
#
# Usage:
#   scp scripts/deploy_nebius_isaacsim.sh chloepv@<IP>:~/
#   ssh chloepv@<IP>
#   bash deploy_nebius_isaacsim.sh
# =============================================================================

set -euo pipefail

echo "============================================"
echo " Isaac Sim / Isaac Lab — Nebius Deployment"
echo "============================================"

# ---------- 1. Detect kernel driver version ----------
DRIVER_VERSION=$(cat /proc/driver/nvidia/version | grep -oP '\d+\.\d+\.\d+' | head -1)
DRIVER_MAJOR=$(echo "$DRIVER_VERSION" | cut -d. -f1)
echo ""
echo "Kernel driver: $DRIVER_VERSION (major: $DRIVER_MAJOR)"

# ---------- 2. Remove conflicting packages ----------
echo ""
echo ">>> Removing stale packages..."
sudo apt-get remove -y "libnvidia-extra-${DRIVER_MAJOR}" 2>/dev/null || true
sudo dpkg --configure -a 2>/dev/null || true
sudo apt-get -f install -y 2>/dev/null || true

# ---------- 3. Install graphics + encoder libraries ----------
echo ""
echo ">>> Installing libnvidia-gl-${DRIVER_MAJOR} + libnvidia-encode-${DRIVER_MAJOR}..."
sudo apt-get update -qq
sudo apt-get install -y \
  "libnvidia-gl-${DRIVER_MAJOR}" \
  "libnvidia-encode-${DRIVER_MAJOR}" \
  vulkan-tools \
  2>&1 | tail -5

# ---------- 4. Verify Vulkan ----------
echo ""
echo ">>> Verifying Vulkan..."
VULKAN_GPU=$(vulkaninfo --summary 2>&1 | grep "deviceName.*NVIDIA" || true)
if [ -z "$VULKAN_GPU" ]; then
  echo "ERROR: Vulkan did not detect an NVIDIA GPU."
  echo "  Check: dpkg -l | grep libnvidia-gl"
  echo "  Check: cat /proc/driver/nvidia/version"
  exit 1
fi
echo "OK: $VULKAN_GPU"

# ---------- 5. Configure Docker ----------
echo ""
echo ">>> Configuring Docker NVIDIA runtime..."
sudo nvidia-ctk runtime configure --runtime=docker 2>&1 | tail -1
sudo systemctl restart docker

# ---------- 6. Pull Isaac Lab container ----------
echo ""
echo ">>> Pulling Isaac Lab 3.0 container (~22GB, takes a few minutes)..."
docker pull nvcr.io/nvidia/isaac-lab:3.0.0-beta1

# ---------- 7. Test GPU inside container ----------
echo ""
echo ">>> Testing GPU in container..."
GPU_NAME=$(docker run --rm --gpus all \
  -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
  --entrypoint bash \
  nvcr.io/nvidia/isaac-lab:3.0.0-beta1 \
  -c '/isaac-sim/python.sh -c "import torch; print(torch.cuda.get_device_name(0))"' 2>&1)
echo "OK: $GPU_NAME"

# ---------- Done ----------
PUBLIC_IP=$(curl -s ifconfig.me)
echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo "Launch Isaac Sim GUI with streaming:"
echo "  bash launch_isaacsim_streaming.sh"
echo ""
echo "Or manually:"
echo ""
echo "  docker run --gpus all --network host -d \\"
echo "    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \\"
echo "    --entrypoint bash --name islab-live \\"
echo "    nvcr.io/nvidia/isaac-lab:3.0.0-beta1 -c '"
echo "  /isaac-sim/kit/kit \\"
echo "    /isaac-sim/apps/isaacsim.exp.full.streaming.kit \\"
echo "    --allow-root --no-window \\"
echo "    --/exts/omni.kit.livestream.app/primaryStream/publicIp=$PUBLIC_IP'"
echo ""
echo "Then connect: Omniverse Streaming Client → $PUBLIC_IP"
