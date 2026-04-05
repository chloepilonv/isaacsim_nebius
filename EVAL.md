# Nebius L40S — Isaac Sim Evaluation

Instance: Nebius `gpu-l40s-a.1gpu-8vcpu-32gb` (L40S 48GB, 8 vCPUs, 32GB RAM)
Date: 2026-04-04
Image: `ubuntu22.04-cuda12` + `nvcr.io/nvidia/isaac-lab:3.0.0-beta1`

## 1. Streaming Latency

| Metric | Result | Verdict |
|--------|--------|---------|
| Streaming client connection | Works | PASS |
| Protocol | WebRTC via `kit` binary + `isaacsim.exp.full.streaming.kit` | |
| Subjective latency | _TODO: measure_ | |
| Usable for interactive work? | _TODO_ | |

Notes:
- `isaac-sim.sh` does NOT work for streaming (hardcodes non-streaming kit)
- Must call `/isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.full.streaming.kit` directly
- Streaming Client: enter IP only, no port

## 2. Physics Throughput

Results from `benchmark_nebius.py --quick` (Isaac-Factory-PegInsert-Direct-v0):

| Envs | Steps/s | Env-Steps/s | VRAM Used | VRAM for Env | Create Time |
|------|---------|-------------|-----------|--------------|-------------|
| 4 | 4.6 | 18 | 5.0 GB | +4.0 GB | 25.6s (first run, asset download) |
| 64 | 4.2 | 267 | 5.7 GB | +3.9 GB | 1.5s |
| 256 | 4.1 | 1,042 | 6.4 GB | +4.0 GB | 2.5s |

**Key observations:**
- Steps/sec is ~4.1-4.6 regardless of env count (physics step is the bottleneck, not GPU)
- Env-steps/sec scales linearly: 18 → 267 → 1,042 (near-perfect GPU parallelism)
- VRAM usage is very modest: only ~4 GB for the env, ~6.4 GB peak at 256 envs
- First env creation takes 25s (downloading assets); subsequent ones take 1-2s
- **38+ GB VRAM headroom** — could likely run 4096+ envs

Verdict: **GOOD** — linear scaling, minimal VRAM usage, plenty of room to scale up

## 3. Rendering Quality

| Test | Result |
|------|--------|
| Scene loads via streaming | _TODO_ |
| Materials render correctly | _TODO_ |
| Lighting / shadows visible | _TODO_ |
| Ray tracing works | _TODO_ |

Test scene: _TODO: load Data Center Assets Pack or built-in demo scene_

## 4. VRAM Headroom

| State | VRAM Used | VRAM Free |
|-------|-----------|-----------|
| Isaac Sim idle (GUI + streaming) | 3.6 GB | 41.3 GB |
| Isaac Sim idle (headless) | 1.0 GB | 43.5 GB |
| 4 envs PegInsert | 5.0 GB | 39.5 GB |
| 64 envs PegInsert | 5.7 GB | 38.8 GB |
| 256 envs PegInsert | 6.4 GB | 38.1 GB |

Total VRAM: 44.5 GB (usable) / 48 GB (physical)

Verdict: **EXCELLENT** — 38+ GB free even with 256 envs. The L40S is massively over-provisioned for Factory PegInsert. Complex scenes (gaussian splats, high-poly meshes) or 4096+ envs would use more.

## 5. Multi-Env Scaling

_Does throughput scale linearly with env count?_

| Envs | Env-Steps/s | Per-Env Steps/s | Scaling vs 4 envs |
|------|-------------|-----------------|-------------------|
| 4 | 18 | 4.6 | 1.0x (baseline) |
| 64 | 267 | 4.2 | 14.8x (ideal: 16x) |
| 256 | 1,042 | 4.1 | 57.9x (ideal: 64x) |

Scaling efficiency: **~90%** — near-linear. The L40S handles GPU parallelism well.

At this rate, 4096 envs would yield ~16,000 env-steps/sec and use ~10-12 GB VRAM.

## Setup Requirements

What Nebius does NOT provide out of the box (must install manually):

| Package | Why Needed | Install |
|---------|-----------|---------|
| `libnvidia-gl-550` | Vulkan rendering | `sudo apt-get install -y libnvidia-gl-550` |
| `libnvidia-encode-550` | NVENC for WebRTC streaming | `sudo apt-get install -y libnvidia-encode-550` |

Version must match kernel driver (check with `cat /proc/driver/nvidia/version`).

## Known Limitations

- Cannot see live RL training in the streaming GUI (training loop blocks Kit event loop)
- `isaac-sim.sh` hardcodes `isaacsim.exp.full.kit` — must call `kit` binary directly for streaming
- **Nebius requires BOTH custom + default security groups** — removing the default SG breaks outbound internet, even with explicit allow-all-egress. Always attach both.
- **First env creation downloads assets from NVIDIA S3** (~25s) — subsequent creations are fast (1-2s) from cache.
- `nvidia-smi` gets removed during package install shuffle — use pynvml/ctypes instead
- Default Nebius security group blocks all external inbound traffic — must create custom rules

## Overall Verdict

| Criteria | Rating | Notes |
|----------|--------|-------|
| Can run Isaac Sim? | **YES** | After installing `libnvidia-gl` + `libnvidia-encode` |
| Can stream to client? | **YES** | WebRTC works (must call `kit` directly, not `isaac-sim.sh`) |
| RL training throughput | **GOOD** | ~1,042 env-steps/s @ 256 envs, scales linearly |
| VRAM headroom | **EXCELLENT** | 38+ GB free @ 256 envs (44.5 GB total) |
| Multi-env scaling | **90%** | Near-linear, GPU parallelism works well |
| Interactive latency | _TODO: subjective test_ | |
| Production-ready? | **YES, with setup** | Requires manual driver lib install + security group config |
| Cost-effective? | **~$1.86/hr** | Comparable to Brev L40S ($1.63/hr), but more setup required |

### Nebius vs Brev

| | Nebius L40S | Brev L40S (Shadeform/Verda) |
|---|---|---|
| Price | ~$1.86/hr | ~$1.63/hr |
| Vulkan out-of-box | No (must install) | Yes |
| NVENC out-of-box | No (must install) | Yes |
| Security group setup | Manual (complex) | Automatic |
| Internet egress | Requires default SG | Works by default |
| Docker + nvidia-ctk | Pre-installed | Pre-installed |
| Setup time | ~15 min (scripted) | ~5 min |
| Instance control | Full CLI (`nebius compute`) | Brev CLI |

**Bottom line:** Nebius works for Isaac Sim but requires more setup. Use `deploy_nebius_isaacsim.sh` to automate it. Brev is easier out-of-the-box. Both are viable for professional use.
