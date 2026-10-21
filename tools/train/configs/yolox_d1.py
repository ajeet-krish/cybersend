"""CyberSend D1 comparison experiment: YOLOX-Nano on the merged hold dataset.

Single class ("hold"), Apache-2.0 Megvii YOLOX only (the Ultralytics YOLO stack
is AGPL and excluded by decision, see tools/train/LICENSES.md). The yolox
package is intentionally NOT a dependency of tools/train; install it in an
isolated environment (tools/train/.venv-yolox), then apply
tools/train/patches/yolox-0.3.0-mps.patch (Megvii YOLOX targets CUDA; the
patch adds MPS/CPU device selection). See tools/train README.md, section "D1
comparison run: YOLOX-Nano", for the exact commands and the layout adapter
(datasets/merged_yolox of symlinks pointing at datasets/merged).

Recipe status: approved by the user 2026-10-20 as the low-memory variant for
the 16 GB development Mac, mirroring the rf_detr_d1_lowmem knobs (multi-scale
off, batch 4, single-process loading; see that config's header for the memory
rationale and the accepted deviations).

YOLOX loads COCO data as data_dir/<name>/<file_name>, where file_name comes
from the annotation JSON ("images/<file>"). With the adapter, name resolves to
the merged split folder, so images resolve to merged/<split>/images/<file>.
"""

from yolox.exp import Exp as YoloxBaseExp  # type: ignore[import-not-found]


class Exp(YoloxBaseExp):  # noqa: N801 (YOLOX exp files use the class name Exp)
    """YOLOX-Nano (depth 0.33, width 0.25) single-class hold detector."""

    def __init__(self) -> None:
        super().__init__()
        # Model scale: YOLOX-Nano.
        self.depth = 0.33
        self.width = 0.25
        self.num_classes = 1

        # Data: symlink adapter over tools/train/datasets/merged (see module docstring).
        self.data_dir = "datasets/merged_yolox"
        self.name = "train2017"       # -> merged/train via adapter symlink
        self.val_name = "val2017"     # -> merged/val via adapter symlink
        self.train_ann = "annotations/instances_train2017.json"
        self.val_ann = "annotations/instances_val2017.json"

        # Input: shared 640x640 contract (docs/architecture.md).
        self.input_size = (640, 640)
        self.test_size = (640, 640)
        self.eval_interval = 5
        # Low-memory recipe (user approved 2026-10-20): no multi-scale jitter.
        # YoloxBaseExp defaults multiscale_range to 5, which would resize every
        # 10 iterations into the 480..800 px range. Fixed 640 keeps the memory
        # footprint flat and matches the rf_detr_d1_lowmem decision (both D1
        # baselines train at fixed letterbox 640).
        self.multiscale_range = 0
        # Checkpoints and logs go under the gitignored artifacts directory,
        # same convention as the RF-DETR runs (relative to tools/train).
        self.output_dir = "artifacts/train_yolox_d1"

        # Schedule, matched to the D1 RF-DETR baseline for a fair comparison.
        self.max_epoch = 40
        # Low-memory: batch 4 (runbook default was 8). YOLOX scales the LR by
        # batch through basic_lr_per_img * batch in the trainer, so per-image
        # learning rate is unchanged by this; pass -b 4 on the command line
        # because args.batch_size (not exp.batch_size) drives the trainer.
        self.batch_size = 4
        self.basic_lr_per_img = 0.001 / 64
        self.warmup_epochs = 5
        self.no_aug_epochs = 5
        # Low-memory: decode in process, no forked workers (mirrors the
        # rf_detr_d1_lowmem num_workers 0 knob on the 16 GB Mac).
        self.data_num_workers = 0

        # Run identity: YoloxBaseExp derives exp_name from its own module
        # filename ("yolox_base"); name this experiment so checkpoints land in
        # artifacts/train_yolox_d1/yolox_d1/.
        self.exp_name = "yolox_d1"

        # Determinism, matching hold-build / hold-train-d1 seeds.
        self.seed = 20261019
