#!/bin/bash
# =============================================================================
# Launch Isaac Sim with WebRTC streaming on a Nebius instance
#
# Run AFTER deploy_nebius_isaacsim.sh has completed.
# Connect with Omniverse Streaming Client using just the IP (no port).
#
# Usage:
#   bash launch_isaacsim_streaming.sh              # GUI only
#   bash launch_isaacsim_streaming.sh train        # Factory PegInsert training
#   bash launch_isaacsim_streaming.sh benchmark    # Run physics benchmark
#
# Datacenter assets:
#   If ~/datacenter_assets/ exists, it will be mounted automatically
#   at /workspace/datacenter_assets inside the container.
#
# Stop:
#   docker stop islab-live && docker rm islab-live
# =============================================================================

set -euo pipefail

PUBLIC_IP=$(curl -s ifconfig.me)
CONTAINER_NAME="islab-live"
MODE="${1:-gui}"
IMAGE="nvcr.io/nvidia/isaac-lab:3.0.0-beta1"

# Clean up old container if exists
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Auto-mount datacenter assets if they exist
VOLUME_MOUNTS=""
if [ -d "$HOME/datacenter_assets" ]; then
  VOLUME_MOUNTS="-v $HOME/datacenter_assets:/workspace/datacenter_assets:ro"
  echo "Mounting datacenter assets from ~/datacenter_assets"
fi

if [ "$MODE" = "train" ]; then
  echo "Launching Isaac Lab training + streaming..."
  echo "  Task: Isaac-Factory-PegInsert-Direct-v0"
  echo "  Public IP: $PUBLIC_IP"

  docker run --gpus all --network host -d \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
    -e PUBLIC_IP="$PUBLIC_IP" \
    $VOLUME_MOUNTS \
    --entrypoint bash \
    --name "$CONTAINER_NAME" \
    "$IMAGE" -c "
  /workspace/isaaclab/isaaclab.sh -p \
    /workspace/isaaclab/scripts/reinforcement_learning/rl_games/train.py \
    --task Isaac-Factory-PegInsert-Direct-v0 \
    --num_envs 4 \
    --enable_cameras --livestream 1 \
    --experience /isaac-sim/apps/isaacsim.exp.full.streaming.kit 2>&1
  "

elif [ "$MODE" = "benchmark" ]; then
  echo "Running physics benchmark..."

  docker run --gpus all --network host --rm \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
    -v "$HOME":/workspace/benchmark \
    --entrypoint bash \
    --name islab-bench \
    "$IMAGE" -c "
  cp -r /isaac-sim/kit/python/lib/python3.12/site-packages/packaging \
    /isaac-sim/exts/omni.isaac.core_archive/pip_prebundle/packaging 2>/dev/null || true
  /isaac-sim/python.sh /workspace/benchmark/benchmark_nebius.py \
    --output /workspace/benchmark/benchmark_results.json 2>&1
  "
  echo "Results saved to ~/benchmark_results.json"
  exit 0

else
  echo "Launching Isaac Sim GUI with streaming..."
  echo "  Public IP: $PUBLIC_IP"

  # IMPORTANT: Call kit directly, NOT isaac-sim.sh
  # isaac-sim.sh hardcodes isaacsim.exp.full.kit which doesn't enable streaming.
  docker run --gpus all --network host -d \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
    $VOLUME_MOUNTS \
    --entrypoint bash \
    --name "$CONTAINER_NAME" \
    "$IMAGE" -c "
  /isaac-sim/kit/kit \
    /isaac-sim/apps/isaacsim.exp.full.streaming.kit \
    --allow-root \
    --no-window \
    --/exts/omni.kit.livestream.app/primaryStream/publicIp=$PUBLIC_IP \
    2>&1
  "
fi

echo ""
echo "Container '$CONTAINER_NAME' started."
echo "Isaac Sim takes ~90 seconds to boot."
echo ""
echo "Watch logs:  docker logs -f $CONTAINER_NAME"
echo "Connect:     Omniverse Streaming Client → $PUBLIC_IP"
echo "Stop:        docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME"
if [ -n "$VOLUME_MOUNTS" ]; then
  echo ""
  echo "Datacenter assets available at: /workspace/datacenter_assets"
  echo "  In Content browser navigate to:"
  echo "  /workspace/datacenter_assets/Assets/DigitalTwin/Assets/Datacenter/Facilities/Stages/Data_Hall/"
fi
