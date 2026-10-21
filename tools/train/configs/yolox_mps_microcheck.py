"""Micro-validation of the applied yolox 0.3.0 MPS patch (not a training run).

Exercises the patched code paths on the installed package without touching the
merged dataset: Trainer device selection, DataPrefetcher batch movement,
random_resize without CUDA, an eval forward, and a training forward + backward
through SimOTA label assignment (the riskiest MPS path). Runs in seconds.

Usage (from tools/train):
    .venv-yolox/bin/python configs/yolox_mps_microcheck.py
"""

from __future__ import annotations

import sys

import torch

from yolox.exp import get_exp
from yolox.tools.train import make_parser


def main() -> int:
    sys.argv = ["yolox_mps_microcheck", "-f", "configs/yolox_d1.py", "-b", "4"]
    args = make_parser().parse_args()
    exp = get_exp(args.exp_file, args.name)
    exp.merge(args.opts)
    if not args.experiment_name:
        args.experiment_name = exp.exp_name

    assert torch.backends.mps.is_available(), "MPS not available on this host"

    # 1. Trainer construction: device selection and artifact paths.
    trainer = exp.get_trainer(args)
    assert trainer.device == "mps", f"expected mps, got {trainer.device}"
    print(f"[1/5] Trainer device={trainer.device} file_name={trainer.file_name}")
    assert "artifacts/train_yolox_d1" in trainer.file_name, trainer.file_name

    # 2. DataPrefetcher: COCO-shaped 4-tuples move to mps.
    from yolox.data import DataPrefetcher

    class FakeCocoDataset(torch.utils.data.Dataset):
        def __len__(self) -> int:
            return 4

        def __getitem__(self, idx: int):
            img = torch.rand(3, 640, 640)
            targets = torch.tensor(
                [[0.0, 100.0, 100.0, 200.0, 200.0],
                 [0.0, 300.0, 300.0, 420.0, 450.0],
                 [0.0, 50.0, 400.0, 180.0, 560.0]]
            )
            info_imgs = (640, 640)
            img_id = idx
            return img, targets, info_imgs, img_id

    loader = torch.utils.data.DataLoader(FakeCocoDataset(), batch_size=2, num_workers=0)
    prefetcher = DataPrefetcher(loader)
    inps, targets = prefetcher.next()
    assert inps.device.type == "mps", f"prefetcher input on {inps.device}"
    assert targets.device.type == "mps", f"prefetcher targets on {targets.device}"
    inps2, targets2 = prefetcher.next()
    assert inps2 is not None and targets2 is not None
    print(f"[2/5] DataPrefetcher moves batches to {inps.device} (4-tuple COCO shape)")

    # 3. random_resize without CUDA, multiscale_range 0 keeps 640 fixed.
    size = exp.random_resize(None, epoch=0, rank=0, is_distributed=False)
    assert tuple(size) == (640, 640), f"expected fixed 640, got {size}"
    print(f"[3/5] random_resize -> {size} (multiscale_range=0)")

    # 4. Eval forward on mps.
    model = exp.get_model().to("mps")
    model.eval()
    with torch.no_grad():
        out = model(torch.rand(1, 3, 640, 640, device="mps"))
    print(f"[4/5] eval forward OK, output type={type(out).__name__}")

    # 5. Training forward + backward: SimOTA assignment and loss on mps.
    model.train()
    x = torch.rand(2, 3, 640, 640, device="mps")
    gt = torch.tensor(
        [[0.0, 100.0, 100.0, 200.0, 200.0],
         [0.0, 300.0, 300.0, 420.0, 450.0],
         [0.0, 50.0, 400.0, 180.0, 560.0]],
        device="mps",
    )
    targets = gt.unsqueeze(0).repeat(2, 1, 1)
    losses = model(x, targets)
    total = losses["total_loss"]
    assert torch.isfinite(total), f"non-finite loss: {total}"
    total.backward()
    grads_ok = all(
        p.grad is None or torch.isfinite(p.grad).all()
        for p in model.parameters()
        if p.requires_grad
    )
    assert grads_ok, "non-finite gradients after backward"
    print(f"[5/5] train forward + backward OK on mps (total_loss={total.detach().item():.4f})")
    print("MPS patch microcheck: all 5 checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
