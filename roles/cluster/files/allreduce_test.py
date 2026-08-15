#!/usr/bin/env python3
"""Two-node NCCL all-reduce over the GX10 ConnectX-7 link.

Run the SAME command on both boxes, changing only --node_rank. Addresses come
from /etc/hosts, which the cluster role populates:

    # on odysseus
    torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
             --master_addr odysseus --master_port 29500 allreduce_test.py

    # on poseidon
    torchrun --nnodes 2 --nproc_per_node 1 --node_rank 1 \
             --master_addr odysseus --master_port 29500 allreduce_test.py

Published two-node GB10 figures are around 10 GB/s bus bandwidth. Well under
that suggests the collective fell back to TCP over the LAN instead of RoCE
over the direct link -- run again with NCCL_DEBUG=INFO, which prints the
transport and interface it selected.
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
        if world == 1:
            print("NOTE: single process -- this measures nothing. Launch on both nodes.")

    # Correctness first, on a small tensor: summing ones across the world must
    # give exactly world_size on every rank.
    probe = torch.ones(8, device="cuda")
    dist.all_reduce(probe)
    assert torch.allclose(probe, torch.full_like(probe, float(world))), (
        f"rank {rank}: all-reduce produced {probe[0].item()}, expected {world}"
    )
    if rank == 0:
        print("correctness: ok")

    # 1 GiB of fp32 - large enough that the measurement reflects link
    # bandwidth rather than launch latency.
    x = torch.ones(256 * 1024 * 1024, dtype=torch.float32, device="cuda")

    for _ in range(3):  # warm up: the first collective pays connection setup
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
        algbw = nbytes * iters / elapsed / 1e9
        print(f"size={nbytes / 1e9:.2f} GB  iters={iters}  algbw={algbw:.1f} GB/s")
        if world > 1:
            # Ring all-reduce moves 2*(N-1)/N of the buffer per rank.
            print(f"busbw={algbw * 2 * (world - 1) / world:.1f} GB/s")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
