#!/usr/bin/env python3
"""Benchmark Isaac Sim / Isaac Lab on a Nebius L40S instance.

Tests physics throughput, rendering, VRAM usage, and multi-env scaling
to validate the instance is suitable for professional robotics work.

Usage (inside Isaac Lab container on Nebius):
    /isaac-sim/python.sh /workspace/benchmark/benchmark_nebius.py

    # Quick test (fewer envs):
    /isaac-sim/python.sh /workspace/benchmark/benchmark_nebius.py --quick
"""

from __future__ import annotations

import argparse
import time
import json
import ctypes
import sys

parser = argparse.ArgumentParser(description="Benchmark Nebius L40S for Isaac Sim")
parser.add_argument("--quick", action="store_true", help="Run quick version (fewer envs)")
parser.add_argument("--output", type=str, default=None, help="Save results to JSON file")
args = parser.parse_args()

# Boot Isaac Sim
from isaaclab.app import AppLauncher
app_launcher = AppLauncher(headless=True)
simulation_app = app_launcher.app

import torch
import gymnasium as gym
import isaaclab_tasks  # noqa: F401
from isaaclab_tasks.utils import parse_env_cfg


# ============================================================
# GPU Info
# ============================================================

def get_gpu_info() -> dict:
    """Get GPU name, VRAM, driver info."""
    info = {
        "gpu_name": torch.cuda.get_device_name(0),
        "vram_total_gb": round(torch.cuda.get_device_properties(0).total_memory / 1024**3, 1),
        "cuda_version": torch.version.cuda,
        "torch_version": torch.__version__,
    }
    try:
        nvml = ctypes.CDLL("libnvidia-ml.so.1")
        nvml.nvmlInit()

        class MemInfo(ctypes.Structure):
            _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]

        handle = ctypes.c_void_p()
        nvml.nvmlDeviceGetHandleByIndex(0, ctypes.byref(handle))
        mem = MemInfo()
        nvml.nvmlDeviceGetMemoryInfo(handle, ctypes.byref(mem))
        info["vram_used_gb"] = round(mem.used / 1024**3, 1)
        info["vram_free_gb"] = round(mem.free / 1024**3, 1)
    except Exception:
        pass
    return info


def get_vram_used_gb() -> float:
    """Get current VRAM usage in GB."""
    try:
        nvml = ctypes.CDLL("libnvidia-ml.so.1")
        nvml.nvmlInit()
        class MemInfo(ctypes.Structure):
            _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]
        handle = ctypes.c_void_p()
        nvml.nvmlDeviceGetHandleByIndex(0, ctypes.byref(handle))
        mem = MemInfo()
        nvml.nvmlDeviceGetMemoryInfo(handle, ctypes.byref(mem))
        return round(mem.used / 1024**3, 2)
    except Exception:
        return -1


# ============================================================
# Benchmarks
# ============================================================

def benchmark_env(env_id: str, num_envs: int, num_steps: int = 200, warmup: int = 50) -> dict:
    """Benchmark a single env configuration.

    Returns dict with steps/sec, VRAM, timing info.
    """
    print(f"  {env_id} @ {num_envs} envs, {num_steps} steps...", end=" ", flush=True)

    vram_before = get_vram_used_gb()

    env_cfg = parse_env_cfg(env_id, num_envs=num_envs, device="cuda:0")
    t0 = time.perf_counter()
    env = gym.make(env_id, cfg=env_cfg)
    t_create = time.perf_counter() - t0

    obs, info = env.reset()
    vram_after_create = get_vram_used_gb()

    # Warmup
    for _ in range(warmup):
        action = torch.tensor(env.action_space.sample(), device="cuda:0")
        obs, reward, terminated, truncated, info = env.step(action)

    torch.cuda.synchronize()

    # Timed run
    t_start = time.perf_counter()
    total_reward = 0.0
    for _ in range(num_steps):
        action = torch.tensor(env.action_space.sample(), device="cuda:0")
        obs, reward, terminated, truncated, info = env.step(action)
        total_reward += reward.sum().item()
    torch.cuda.synchronize()
    t_elapsed = time.perf_counter() - t_start

    vram_peak = get_vram_used_gb()
    steps_per_sec = num_steps / t_elapsed
    env_steps_per_sec = (num_steps * num_envs) / t_elapsed

    env.close()

    result = {
        "env_id": env_id,
        "num_envs": num_envs,
        "num_steps": num_steps,
        "create_time_s": round(t_create, 2),
        "elapsed_s": round(t_elapsed, 2),
        "steps_per_sec": round(steps_per_sec, 1),
        "env_steps_per_sec": round(env_steps_per_sec, 0),
        "vram_before_gb": vram_before,
        "vram_after_create_gb": vram_after_create,
        "vram_peak_gb": vram_peak,
        "vram_env_gb": round(vram_after_create - vram_before, 2),
        "mean_reward": round(total_reward / (num_steps * num_envs), 4),
    }
    print(f"{steps_per_sec:.0f} steps/s, {env_steps_per_sec:.0f} env-steps/s, "
          f"VRAM={vram_peak:.1f}GB (+{result['vram_env_gb']:.1f}GB)")
    return result


def benchmark_physics_only(num_envs: int = 1024, num_steps: int = 500) -> dict:
    """Benchmark raw physics throughput without rendering."""
    print(f"\n--- Physics-only benchmark ({num_envs} envs, {num_steps} steps) ---")
    return benchmark_env("Isaac-Factory-PegInsert-Direct-v0", num_envs, num_steps)


def benchmark_scaling(env_id: str, env_counts: list[int], steps: int = 100) -> list[dict]:
    """Test how throughput scales with env count."""
    print(f"\n--- Scaling benchmark: {env_id} ---")
    results = []
    for n in env_counts:
        try:
            r = benchmark_env(env_id, n, steps)
            results.append(r)
        except Exception as e:
            print(f"  FAILED at {n} envs: {e}")
            results.append({"num_envs": n, "error": str(e)})
            break
    return results


def benchmark_rendering(num_steps: int = 100) -> dict:
    """Benchmark rendering by running with cameras enabled."""
    print(f"\n--- Rendering benchmark (4 envs, cameras) ---")
    env_id = "Isaac-Factory-PegInsert-Direct-v0"
    return benchmark_env(env_id, 4, num_steps)


# ============================================================
# Main
# ============================================================

def main():
    print("=" * 60)
    print("  NEBIUS L40S — ISAAC SIM BENCHMARK")
    print("=" * 60)

    # GPU Info
    gpu = get_gpu_info()
    print(f"\nGPU:          {gpu['gpu_name']}")
    print(f"VRAM:         {gpu['vram_total_gb']} GB total, {gpu.get('vram_used_gb', '?')} GB used")
    print(f"CUDA:         {gpu['cuda_version']}")
    print(f"PyTorch:      {gpu['torch_version']}")

    results = {"gpu": gpu, "benchmarks": {}}

    # 1. Physics throughput at different scales
    if args.quick:
        env_counts = [4, 64, 256]
    else:
        env_counts = [4, 64, 256, 1024, 2048, 4096]

    scaling = benchmark_scaling("Isaac-Factory-PegInsert-Direct-v0", env_counts)
    results["benchmarks"]["scaling"] = scaling

    # 2. Large-scale physics
    if not args.quick:
        physics = benchmark_physics_only(1024, 500)
        results["benchmarks"]["physics_1024"] = physics

    # 3. Rendering benchmark (few envs, with cameras)
    rendering = benchmark_rendering(100)
    results["benchmarks"]["rendering"] = rendering

    # Print summary
    print("\n" + "=" * 60)
    print("  RESULTS SUMMARY")
    print("=" * 60)

    print(f"\n{'Envs':>6} | {'Steps/s':>9} | {'Env-Steps/s':>12} | {'VRAM':>8} | {'Create':>7}")
    print("-" * 58)
    for r in scaling:
        if "error" in r:
            print(f"{r['num_envs']:>6} | {'FAILED':>9} | {r['error'][:20]}")
        else:
            print(f"{r['num_envs']:>6} | {r['steps_per_sec']:>8.0f}  | {r['env_steps_per_sec']:>11.0f} | {r['vram_peak_gb']:>6.1f}GB | {r['create_time_s']:>5.1f}s")

    # Assessment
    print("\n--- Assessment ---")
    max_envs = max(r["num_envs"] for r in scaling if "error" not in r)
    max_throughput = max(r["env_steps_per_sec"] for r in scaling if "error" not in r)
    peak_vram = max(r["vram_peak_gb"] for r in scaling if "error" not in r)
    vram_headroom = gpu["vram_total_gb"] - peak_vram

    print(f"Max parallel envs tested:  {max_envs}")
    print(f"Peak throughput:           {max_throughput:.0f} env-steps/sec")
    print(f"Peak VRAM usage:           {peak_vram:.1f} GB / {gpu['vram_total_gb']} GB")
    print(f"VRAM headroom:             {vram_headroom:.1f} GB")

    if max_throughput > 50000:
        print("Verdict: EXCELLENT for RL training")
    elif max_throughput > 10000:
        print("Verdict: GOOD for RL training")
    elif max_throughput > 1000:
        print("Verdict: ADEQUATE for RL training")
    else:
        print("Verdict: MAY BE INSUFFICIENT for large-scale RL")

    if vram_headroom > 10:
        print(f"VRAM: Plenty of headroom ({vram_headroom:.0f}GB free) for complex scenes")
    elif vram_headroom > 5:
        print(f"VRAM: Moderate headroom ({vram_headroom:.0f}GB free)")
    else:
        print(f"VRAM: Tight ({vram_headroom:.0f}GB free) — may limit env count or scene complexity")

    # Save results
    if args.output:
        with open(args.output, "w") as f:
            json.dump(results, f, indent=2)
        print(f"\nResults saved to: {args.output}")

    print("\nDone.")
    simulation_app.close()


if __name__ == "__main__":
    main()
