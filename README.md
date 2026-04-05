# Isaac Sim on Nebius AI Cloud

Scripts and docs to run NVIDIA Isaac Sim / Isaac Lab on Nebius GPU instances with WebRTC streaming.

Validated 2026-04-04 on Nebius L40S with Isaac Lab 3.0 (Isaac Sim 6.0).

## Files

| File | Purpose |
|------|---------|
| `deploy_nebius_isaacsim.sh` | One-shot setup: installs Vulkan libs, configures Docker, pulls container |
| `launch_isaacsim_streaming.sh` | Launch Isaac Sim GUI or training with WebRTC streaming |
| `benchmark_nebius.py` | Benchmark physics throughput, VRAM, multi-env scaling |
| `nebius-cloud-init.yaml` | Cloud-init for auto-setup at instance creation |

## The Problem

Nebius GPU instances ship with **compute-only NVIDIA drivers** — CUDA works, but two critical pieces are missing:

- `libnvidia-gl-{VER}` — Vulkan/OpenGL graphics libraries (Isaac Sim needs Vulkan to render, even headless)
- `libnvidia-encode-{VER}` — NVENC hardware video encoder (WebRTC streaming needs this)

The kernel driver and the userspace libs must be the **same version**. Nebius pre-installs kernel driver 550.x, so you need the 550 userspace libs — not 580, not anything else.

## Quick Start

```bash
# 1. Create instance (see "Creating a Nebius Instance" section below)

# 2. SSH in and run the setup script
scp deploy_nebius_isaacsim.sh chloepv@<PUBLIC_IP>:~/
ssh chloepv@<PUBLIC_IP>
bash deploy_nebius_isaacsim.sh

# 3. Launch Isaac Sim with streaming
bash launch_isaacsim_streaming.sh

# 4. Connect from your Mac
#    Open Omniverse Streaming Client → enter just the IP, no port
```

## What the Setup Script Does

1. Detects the kernel driver version (e.g. 550.163.01)
2. Installs matching `libnvidia-gl-550` and `libnvidia-encode-550`
3. Handles package conflicts (Nebius images have stale `libnvidia-extra-550`)
4. Verifies Vulkan detects the NVIDIA GPU
5. Configures Docker with NVIDIA runtime
6. Pulls `nvcr.io/nvidia/isaac-lab:3.0.0-beta1` (~22GB)
7. Tests GPU access inside the container

## Launching Isaac Sim with Streaming

**Critical:** Do NOT use `isaac-sim.sh` — it hardcodes `isaacsim.exp.full.kit` as the first argument, which loads the non-streaming GUI. Instead, call the `kit` binary directly with the streaming kit:

```bash
PUBLIC_IP=$(curl -s ifconfig.me)

docker run --gpus all --network host -d \
  -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
  --entrypoint bash \
  --name islab-live \
  nvcr.io/nvidia/isaac-lab:3.0.0-beta1 -c '
/isaac-sim/kit/kit \
  /isaac-sim/apps/isaacsim.exp.full.streaming.kit \
  --allow-root \
  --no-window \
  --/exts/omni.kit.livestream.app/primaryStream/publicIp='"$PUBLIC_IP"' \
  2>&1
'
```

### Why `kit` directly and not `isaac-sim.sh`?

`isaac-sim.sh` does this internally:
```bash
exec "$SCRIPT_DIR/kit/kit" "$SCRIPT_DIR/apps/isaacsim.exp.full.kit" "$@"
```

It always loads `isaacsim.exp.full.kit` first. Passing `--experience isaacsim.exp.full.streaming.kit` as an extra arg doesn't override the first kit file — it becomes an overlay that doesn't properly activate streaming.

Calling `kit` directly with `isaacsim.exp.full.streaming.kit` as the primary kit file is what makes streaming work.

### Running a task with streaming

To run Isaac Lab training with streaming (e.g. Factory PegInsert):

```bash
PUBLIC_IP=$(curl -s ifconfig.me)

docker run --gpus all --network host -d \
  -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e OMNI_KIT_ALLOW_ROOT=1 \
  -e PUBLIC_IP=$PUBLIC_IP \
  --entrypoint bash \
  --name islab-train \
  nvcr.io/nvidia/isaac-lab:3.0.0-beta1 -c '
/workspace/isaaclab/isaaclab.sh -p \
  /workspace/isaaclab/scripts/reinforcement_learning/rl_games/train.py \
  --task Isaac-Factory-PegInsert-Direct-v0 \
  --num_envs 4 \
  --enable_cameras --livestream 1 \
  --experience /isaac-sim/apps/isaacsim.exp.full.streaming.kit 2>&1
'
```

Note: When using `isaaclab.sh -p`, the `--experience` flag works because AppLauncher handles it differently than `isaac-sim.sh`.

## Creating a Nebius Instance

### Via CLI

```bash
# 1. Create boot disk (200GB, Ubuntu 22.04 + CUDA)
nebius compute disk create \
  --name isaacsim-boot-disk \
  --size-gibibytes 200 \
  --type network_ssd \
  --source-image-family-image-family ubuntu22.04-cuda12 \
  --block-size-bytes 4096

# 2. Create L40S instance (note the disk ID from step 1)
nebius compute instance create \
  --name isaacsim-test \
  --resources-platform gpu-l40s-a \
  --resources-preset 1gpu-8vcpu-32gb \
  --boot-disk-existing-disk-id <DISK_ID> \
  --boot-disk-attach-mode read_write \
  --network-interfaces '[{"name": "eth0", "ip_address": {}, "public_ip_address": {}, "subnet_id": "<SUBNET_ID>"}]' \
  --cloud-init-user-data "$(cat nebius-cloud-init.yaml)"
```

### Security Group Rules

The default Nebius security group only allows traffic within itself. You must create rules for external access.

```bash
# Find or create a security group
nebius vpc security-group list

# Add rules (replace SG_ID with your security group ID)
SG_ID=vpcsecuritygroup-xxxxx

nebius vpc security-rule create --parent-id $SG_ID \
  --name "allow-ssh" --access allow --protocol tcp \
  --ingress-source-cidrs "0.0.0.0/0" --ingress-destination-ports 22

nebius vpc security-rule create --parent-id $SG_ID \
  --name "allow-webrtc-signaling" --access allow --protocol tcp \
  --ingress-source-cidrs "0.0.0.0/0" --ingress-destination-ports 49100

nebius vpc security-rule create --parent-id $SG_ID \
  --name "allow-webrtc-media" --access allow --protocol udp \
  --ingress-source-cidrs "0.0.0.0/0" --ingress-destination-ports 47998

nebius vpc security-rule create --parent-id $SG_ID \
  --name "allow-webrtc-fallback" --access allow --protocol tcp \
  --ingress-source-cidrs "0.0.0.0/0" --ingress-destination-ports 48010

nebius vpc security-rule create --parent-id $SG_ID \
  --name "allow-all-egress" --access allow --protocol any \
  --egress-destination-cidrs "0.0.0.0/0"
```

Then attach to the instance:
```bash
nebius compute instance update \
  --id <INSTANCE_ID> \
  --network-interfaces '[{"name": "eth0", "ip_address": {}, "public_ip_address": {}, "subnet_id": "<SUBNET_ID>", "security_groups": [{"id": "<SG_ID>"}]}]'
```

### Ports Required

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 49100 | TCP | WebRTC signaling |
| 47998 | UDP | WebRTC media stream |
| 48010 | TCP | WebRTC media fallback |

## Connecting

Use **Omniverse Streaming Client** (download from NVIDIA):
- Enter just the IP address (e.g. `89.169.120.76`)
- Do NOT add a port — it auto-discovers via 49100
- If you get a grey screen, you probably added `:49100`

## Driver Details

Nebius ships 4 driver components but only installs 2:

| Package | Installed by Nebius? | Purpose |
|---------|---------------------|---------|
| `libnvidia-compute-550` | Yes | CUDA (math on GPU) |
| `nvidia-dkms-550` | Yes | Kernel module |
| `libnvidia-gl-550` | **No** | Vulkan + OpenGL (rendering) |
| `libnvidia-encode-550` | **No** | NVENC (video encoding for streaming) |

The kernel module and userspace libs share a single NVIDIA driver codebase. Cloud providers strip the graphics libs because most workloads are pure compute (PyTorch, etc). Isaac Sim needs the full stack.

### Version Matching

If you see `Driver/library version mismatch`:
```bash
# Check kernel driver
cat /proc/driver/nvidia/version
# NVIDIA UNIX x86_64 Kernel Module  550.163.01

# The major version (550) must match your userspace libs
dpkg -l | grep libnvidia-gl
# Should show 550.x, not 580.x
```

## Cost

| Preset | GPU | VRAM | vCPUs | RAM | $/hr |
|--------|-----|------|-------|-----|------|
| gpu-l40s-a.1gpu-8vcpu-32gb | L40S | 48GB | 8 | 32GB | ~$1.86 |
| gpu-l40s-a.1gpu-16vcpu-64gb | L40S | 48GB | 16 | 64GB | ~$2.10 |

## Troubleshooting

### `NVST_DISCONN_SERVER_VIDEO_ENCODER_INIT_DLL_LOAD_FAILED`
Missing NVENC. Install: `sudo apt-get install -y libnvidia-encode-550`

### `NVST_R_GENERIC_ERROR Got stop event while waiting for client connection`
Firewall issue. Ports 49100 TCP + 47998 UDP must be open in your Nebius security group (not just on the instance).

### No streaming extensions in logs
You're using `isaac-sim.sh` instead of calling `kit` directly. See "Why kit directly" section above.

### `Driver/library version mismatch`
Kernel driver and GL libs are different versions. Check both:
```bash
cat /proc/driver/nvidia/version   # kernel driver
dpkg -l | grep libnvidia-gl       # userspace libs
```

### Package conflicts during install
```bash
# Remove stale packages
sudo apt-get remove -y libnvidia-extra-550
sudo dpkg --configure -a
sudo apt-get -f install -y
# Retry
sudo apt-get install -y libnvidia-gl-550
```

### Streaming Client shows nothing / can't connect
1. Check container is running: `docker ps`
2. Check port 49100 is listening: `ss -tlnp | grep 49100`
3. Check logs for errors: `docker logs islab-live 2>&1 | grep -i error | tail -10`
4. Make sure security group rules are attached to the instance (not just created)

## Cleanup

```bash
# Stop and remove container
ssh chloepv@<IP> "docker stop islab-live; docker rm islab-live"

# Delete Nebius instance
nebius compute instance delete --id <INSTANCE_ID>

# Delete boot disk (optional — keep for faster next launch)
nebius compute disk delete --id <DISK_ID>
```
