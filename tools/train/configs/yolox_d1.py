"""CyberSend D1 comparison experiment: YOLOX-Nano on the merged hold dataset.

Single class ("hold"), Apache-2.0 Megvii YOLOX only (the Ultralytics YOLO stack
is AGPL and excluded by decision, see tools/train/LICENSES.md). The yolox
package is intentionally NOT a dependency of tools/train; install it in an
isolated environment when the comparison run is approved. See tools/train
README.md, section "D1 comparison run: YOLOX-Nano", for the exact commands and
the layout adapter (datasets/merged_yolox of symlinks pointing at
datasets/merged). Nothing here has been executed; this file is scaffolding.

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

        # Schedule, matched to the D1 RF-DETR baseline for a fair comparison.
        self.max_epoch = 40
        self.batch_size = 8
        self.basic_lr_per_img = 0.001 / 64
        self.warmup_epochs = 5
        self.no_aug_epochs = 5
        self.data_num_workers = 4

        # Determinism, matching hold-build / hold-train-d1 seeds.
        self.seed = 20261019
