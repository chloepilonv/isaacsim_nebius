# Isaac Sim on Nebius AI Cloud

Step-by-step guide to run NVIDIA Isaac Sim / Isaac Lab on a Nebius L40S GPU instance with WebRTC streaming.

Validated 2026-04-04. Isaac Lab 3.0 / Isaac Sim 6.0 / Nebius L40S 48GB.

## Prerequisites

- [Nebius CLI](https://docs.nebius.com/cli/install) installed and authenticated
- SSH key pair (your public key goes in `nebius-cloud-init.yaml`)
- [Omniverse Streaming Client](https://docs.omniverse.nvidia.com/streaming-client/latest/user-guide.html) on your Mac/PC

## Step 1: Create the Instance

```bash
# Find your subnet ID
nebius vpc subnet list
# Note the subnet ID (e.g. vpcsubnet-e00zg4dskf9gmh08he)

# Create a 200GB boot disk with Ubuntu 22.04 + CUDA
nebius compute disk create \
  --name isaacsim-boot-disk \
  --size-gibibytes 200 \
  --type network_ssd \
  --source-image-family-image-family ubuntu22.04-cuda12 \
  --block-size-bytes 4096
# Note the disk ID from the output (e.g. computedisk-e00fz3qeywp43j1pdx)

# Edit nebius-cloud-init.yaml — put YOUR SSH public key in ssh_authorized_keys

# Create L40S instance
nebius compute instance create \
  --name isaacsim \
  --resources-platform gpu-l40s-a \
  --resources-preset 1gpu-8vcpu-32gb \
  --boot-disk-existing-disk-id <DISK_ID> \
  --boot-disk-attach-mode read_write \
  --network-interfaces '[{"name": "eth0", "ip_address": {}, "public_ip_address": {}, "subnet_id": "<SUBNET_ID>"}]' \
  --cloud-init-user-data "$(cat nebius-cloud-init.yaml)"
# Note the public IP from the output
```

## Step 2: Open Firewall Ports

The default Nebius security group blocks all external inbound traffic. You need to create a custom security group with streaming ports.

```bash
# Create a security group (or reuse an existing one)
nebius vpc security-group list
# If you already have one (e.g. isaac-sim-streaming), use its ID
# Otherwise create one:
# nebius vpc security-group create --name isaac-sim-streaming --network-id <NETWORK_ID>

SG_ID=<YOUR_SECURITY_GROUP_ID>  # e.g. vpcsecuritygroup-e00s9qq77ydt42b588

# Add rules
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

**Attach BOTH the custom SG and the default SG to the instance.** Removing the default SG breaks outbound internet (even with explicit allow-all-egress).

```bash
# Find the default SG
nebius vpc security-group list
# Look for "default-security-group-*"
DEFAULT_SG_ID=<DEFAULT_SG_ID>

# Attach both to the instance
nebius compute instance update \
  --id <INSTANCE_ID> \
  --network-interfaces '[{
    "name": "eth0",
    "ip_address": {},
    "public_ip_address": {},
    "subnet_id": "<SUBNET_ID>",
    "security_groups": [
      {"id": "'"$SG_ID"'"},
      {"id": "'"$DEFAULT_SG_ID"'"}
    ]
  }]'
```

## Step 3: Install Drivers + Docker

SSH into the instance and run the setup script:

```bash
scp deploy_nebius_isaacsim.sh <USER>@<PUBLIC_IP>:~/
ssh <USER>@<PUBLIC_IP>
bash deploy_nebius_isaacsim.sh
```

This takes ~10 minutes (mostly pulling the 22GB Docker image). It:
1. Detects the kernel driver version (e.g. 550.163.01)
2. Installs matching `libnvidia-gl-550` (Vulkan) and `libnvidia-encode-550` (NVENC)
3. Handles package conflicts (Nebius has stale `libnvidia-extra-550`)
4. Verifies Vulkan detects the NVIDIA GPU
5. Configures Docker with NVIDIA runtime
6. Pulls `nvcr.io/nvidia/isaac-lab:3.0.0-beta1`
7. Tests GPU access inside the container

### Why this is needed

Nebius installs **compute-only** NVIDIA drivers — CUDA works, but Vulkan and NVENC are missing:

| Package | Installed by Nebius? | Purpose |
|---------|---------------------|---------|
| `libnvidia-compute-550` | Yes | CUDA |
| `nvidia-dkms-550` | Yes | Kernel module |
| `libnvidia-gl-550` | **No** | Vulkan + OpenGL (Isaac Sim needs this to render) |
| `libnvidia-encode-550` | **No** | NVENC (WebRTC streaming needs this) |

The kernel module and userspace libs must be the **same major version**. If the kernel has 550.x, you need `libnvidia-gl-550`.

## Step 4: Launch Isaac Sim

```bash
# On the instance:
scp launch_isaacsim_streaming.sh <USER>@<PUBLIC_IP>:~/
ssh <USER>@<PUBLIC_IP>
bash launch_isaacsim_streaming.sh
```

Isaac Sim takes ~90 seconds to boot. Watch logs with:
```bash
docker logs -f islab-live
```

Wait until you see `isaacsim.exp.full.streaming-6.0.0 startup` in the logs.

### How the launch script works

It calls the `kit` binary directly with the streaming kit file:
```bash
/isaac-sim/kit/kit \
  /isaac-sim/apps/isaacsim.exp.full.streaming.kit \
  --allow-root --no-window \
  --/exts/omni.kit.livestream.app/primaryStream/publicIp=$PUBLIC_IP
```

**Do NOT use `isaac-sim.sh`** — it hardcodes `isaacsim.exp.full.kit` which loads the non-streaming GUI. The streaming kit must be the primary kit file passed to `kit`.

## Step 5: Connect

Open **Omniverse Streaming Client** on your Mac:
- Enter just the IP address (e.g. `89.169.120.76`)
- **Do NOT add a port** — it auto-discovers via 49100
- If you get a grey screen, you probably added `:49100`

### Camera Controls

| Action | Mouse | Trackpad (Mac) |
|--------|-------|----------------|
| Orbit | Alt + Left click drag | Option (⌥) + click drag |
| Pan | Middle click drag | Option + two-finger click drag |
| Zoom | Scroll wheel | Two-finger scroll |
| Fly | Right click + WASD | Two-finger click + WASD |

A mouse with scroll wheel is strongly recommended.

## Step 6 (Optional): Load a Test Scene

### NVIDIA Data Center Assets Pack (9.2GB)

Download directly on the instance:
```bash
ssh <USER>@<PUBLIC_IP>
wget -O ~/datacenter_assets.zip \
  'https://d4i3qtqj3r0z5.cloudfront.net/Datacenter_NVD%4010012.zip'
mkdir -p ~/datacenter_assets
unzip datacenter_assets.zip -d ~/datacenter_assets
```

Stop the current container and relaunch with assets mounted:
```bash
docker stop islab-live && docker rm islab-live
bash launch_isaacsim_streaming.sh
# The script auto-detects ~/datacenter_assets and mounts it
```

In the Streaming Client, navigate the **Content** browser to:
```
/workspace/datacenter_assets/Assets/DigitalTwin/Assets/Datacenter/Facilities/Stages/Data_Hall/
```

| Scene | Description |
|-------|-------------|
| `DataHall_Full_01.usd` | Full datacenter with racks, servers, cabling, cooling |
| `DataHall_Full_B01.usd` | Alternative full layout |
| `DataHall_01.usd` | Empty hall (lighter, good for first test) |
| `DataHall_NoRacks_01.usd` | Hall structure only |
| `DataHall_Rack_42U_01.usd` | Hall with one 42U rack |

Individual components (DGX nodes, network switches, PDUs) are in subdirectories under `Assets/Datacenter/`.

## Step 7 (Optional): Run Benchmarks

```bash
scp benchmark_nebius.py <USER>@<PUBLIC_IP>:~/
ssh <USER>@<PUBLIC_IP>
bash launch_isaacsim_streaming.sh benchmark
cat ~/benchmark_results.json
```

See [EVAL.md](EVAL.md) for our benchmark results.

## Other Launch Modes

```bash
bash launch_isaacsim_streaming.sh            # GUI only (default)
bash launch_isaacsim_streaming.sh train      # Factory PegInsert RL training
bash launch_isaacsim_streaming.sh benchmark  # Physics benchmark
```

## Cost

| Preset | GPU | VRAM | vCPUs | RAM | $/hr |
|--------|-----|------|-------|-----|------|
| `gpu-l40s-a.1gpu-8vcpu-32gb` | L40S | 48GB | 8 | 32GB | ~$1.86 |
| `gpu-l40s-a.1gpu-16vcpu-64gb` | L40S | 48GB | 16 | 64GB | ~$2.10 |

## Cleanup

```bash
# Stop container
ssh <USER>@<IP> "docker stop islab-live; docker rm islab-live"

# Delete instance
nebius compute instance delete --id <INSTANCE_ID>

# Delete boot disk (optional — keep it for faster next launch)
nebius compute disk delete --id <DISK_ID>
```

## Troubleshooting

### `NVST_DISCONN_SERVER_VIDEO_ENCODER_INIT_DLL_LOAD_FAILED`
Missing NVENC library. Fix: `sudo apt-get install -y libnvidia-encode-550`

### `NVST_R_GENERIC_ERROR Got stop event while waiting for client connection`
Firewall issue. Check that ports 49100 (TCP) and 47998 (UDP) are open in your Nebius security group. Make sure the security group is actually **attached** to the instance.

### No streaming extensions in logs
You're using `isaac-sim.sh` instead of calling `kit` directly. See Step 4.

### `Driver/library version mismatch`
Kernel driver and userspace libs are different versions:
```bash
cat /proc/driver/nvidia/version   # kernel driver version
dpkg -l | grep libnvidia-gl       # userspace lib version
# Both must show the same major version (e.g. 550)
```

### No outbound internet (can't pull Docker images, download assets)
You removed the default security group. You must attach **both** the default SG and your custom SG. See Step 2.

### Package conflicts during driver install
```bash
sudo apt-get remove -y libnvidia-extra-550
sudo dpkg --configure -a
sudo apt-get -f install -y
sudo apt-get install -y libnvidia-gl-550
```

### Streaming Client shows nothing / can't connect
1. Container running? `docker ps`
2. Port listening? `ss -tlnp | grep 49100`
3. Errors? `docker logs islab-live 2>&1 | grep -i error | tail -10`
4. Security group attached? See Step 2.

## Files

| File | Purpose |
|------|---------|
| `deploy_nebius_isaacsim.sh` | Step 3: installs Vulkan/NVENC libs, configures Docker, pulls container |
| `launch_isaacsim_streaming.sh` | Step 4: launches Isaac Sim with streaming (GUI / train / benchmark) |
| `benchmark_nebius.py` | Step 7: physics throughput, VRAM, multi-env scaling benchmark |
| `nebius-cloud-init.yaml` | Step 1: cloud-init template for instance creation |
| `EVAL.md` | Benchmark results and evaluation |
