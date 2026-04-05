#!/bin/bash
# =============================================================================
# Launch Isaac Sim with WebRTC streaming on a Nebius instance
#
# Run AFTER deploy_nebius_isaacsim.sh has completed.
# Connect with Omniverse Streaming Client using just the IP (no port).
#
# Usage:
#   bash launch_isaacsim_streaming.sh          # GUI only
#   bash launch_isaacsim_streaming.sh train    # Factory PegInsert training
#
# Stop:
#   docker stop islab-live && docker rm islab-live
# =============================================================================

set -euo pipefail

PUBLIC_IP=$(curl -s ifconfig.me)
CONTAINER_NAME="islab-live"
MODE="${1:-gui}"

# Clean up old container if exists
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

if [ "$MODE" = "train" ]; then
  echo "Launching Isaac Lab training + streaming..."
  echo "  Task: Isaac-Factory-PegInsert-Direct-v0"
  echo "  Public IP: $PUBLIC_IP"

  docker run --gpus all --network host -d \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
    -e PUBLIC_IP="$PUBLIC_IP" \
    --entrypoint bash \
    --name "$CONTAINER_NAME" \
    nvcr.io/nvidia/isaac-lab:3.0.0-beta1 -c "
  /workspace/isaaclab/isaaclab.sh -p \
    /workspace/isaaclab/scripts/reinforcement_learning/rl_games/train.py \
    --task Isaac-Factory-PegInsert-Direct-v0 \
    --num_envs 4 \
    --enable_cameras --livestream 1 \
    --experience /isaac-sim/apps/isaacsim.exp.full.streaming.kit 2>&1
  "
else
  echo "Launching Isaac Sim GUI with streaming..."
  echo "  Public IP: $PUBLIC_IP"

  # IMPORTANT: Call kit directly, NOT isaac-sim.sh
  # isaac-sim.sh hardcodes isaacsim.exp.full.kit which doesn't enable streaming.
  docker run --gpus all --network host -d \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
    --entrypoint bash \
    --name "$CONTAINER_NAME" \
    nvcr.io/nvidia/isaac-lab:3.0.0-beta1 -c "
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
