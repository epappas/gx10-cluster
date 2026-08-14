#!/usr/bin/env python3
"""Two-node NCCL all-reduce over the GX10 ConnectX-7 link.

Launch from node 0 (rank 0) and node 1 simultaneously:

    torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
             --master_addr 10.10.10.1 --master_port 29500 allreduce_test.py

    torchrun --nnodes 2 --nproc_per_node 1 --node_rank 1 \
             --master_addr 10.10.10.1 --master_port 29500 allreduce_test.py

A correct run prints a bus bandwidth in the tens of GB/s. Single-digit GB/s
means the collective fell back to TCP over the LAN instead of using RDMA on
the direct link - check NCCL_SOCKET_IFNAME and that ibv_devices lists a device.
"""

import os
import time

import torch
import torch.distributed as dist


def main() -> None:
    rank = int(os.environ["RANK"])
    world = int(os.environ["WORLD_SIZE"])
    local_rank = int(os.environ["LOCAL_RANK"])

    torch.cuda.set_device(local_rank)
    dist.init_process_group(backend="nccl")

    if rank == 0:
        print(f"world_size={world}  device={torch.cuda.get_device_name(local_rank)}")

    # Correctness first, on a small tensor: summing ones across the world
    # must give exactly world_size on every rank.
    probe = torch.ones(8, device="cuda")
    dist.all_reduce(probe)
    assert torch.allclose(probe, torch.full_like(probe, float(world))), (
        f"rank {rank}: all-reduce produced {probe[0].item()}, expected {world}"
    )
    if rank == 0:
        print("correctness: ok")

    # 1 GiB of fp32 - large enough that the measurement reflects link
    # bandwidth rather than launch latency.
    numel = 256 * 1024 * 1024
    x = torch.ones(numel, dtype=torch.float32, device="cuda")

    for _ in range(3):  # warm up: first collective pays connection setup
        dist.all_reduce(x)
    torch.cuda.synchronize()

    iters = 10
    start = time.perf_counter()
    for _ in range(iters):
        dist.all_reduce(x)
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - start

    if rank == 0:
        nbytes = x.numel() * x.element_size()
        # Ring all-reduce moves 2*(N-1)/N of the buffer per rank.
        algbw = nbytes * iters / elapsed / 1e9
        busbw = algbw * 2 * (world - 1) / world
        print(f"size={nbytes / 1e9:.2f} GB  iters={iters}")
        print(f"algbw={algbw:.1f} GB/s  busbw={busbw:.1f} GB/s")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
