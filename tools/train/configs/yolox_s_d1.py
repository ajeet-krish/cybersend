"""CyberSend D1b scaling experiment: YOLOX-S on the merged hold dataset.

Why this run exists: YOLOX-Nano cannot reach the recall floor without giving up
precision (0.80 recall costs precision down to 0.7168 on val), and RF-DETR,
which does meet the accuracy bar, cannot meet the 15 MB int8 budget at 28.9M
parameters and fails decision-space parity once compressed. YOLOX-S is the
smallest step up in capacity that still fits: about 9.0M parameters, dense
convolutions only, roughly 9 MB at int8, no GridSample, no attention, and the
official Apache-2.0 COCO checkpoint is available for initialization.

Everything except the model scale matches configs/yolox_d1.py on purpose, so the
two runs are comparable on the same data, schedule, seed, and low-memory
settings (fixed 640, batch 4, single-process loading).

Recipe status: approved by the user 2026-10-21 as the branch to pursue after the
D1 gate result (docs/decisions.md). The training run itself still needs the
explicit approval the phase rules require.

Data layout: as with yolox_d1, YOLOX reads datasets/merged_yolox, a directory of
symlinks over datasets/merged (see configs/yolox_d1.py and README.md).
"""

from yolox.exp import Exp as YoloxBaseExp  # type: ignore[import-not-found]
from yolox.models import (  # type: ignore[import-not-found]
    YOLOX,
    YOLOPAFPN,
    YOLOXHead,
)


class Exp(YoloxBaseExp):  # noqa: N801 (YOLOX exp files use the class name Exp)
    """YOLOX-S (depth 0.33, width 0.50, dense convs), single class hold detector."""

    def __init__(self) -> None:
        super().__init__()
        # Model scale: YOLOX-S. Dense convolutions, which is what the official
        # yolox_s.pth checkpoint expects (the Nano build needed depthwise=True
        # to match its DWConv key names; S is the plain dense variant).
        self.depth = 0.33
        self.width = 0.50
        self.num_classes = 1

        # Data: same symlink adapter as the Nano run.
        self.data_dir = "datasets/merged_yolox"
        self.name = "train2017"
        self.val_name = "val2017"
        self.train_ann = "instances_train2017.json"
        self.val_ann = "instances_val2017.json"

        # Input: same 640x640 contract as every other D1 run.
        self.input_size = (640, 640)
        self.test_size = (640, 640)
        self.eval_interval = 5
        self.multiscale_range = 0

        # Separate output tree so the Nano artifacts stay intact.
        self.output_dir = "artifacts/train_yolox_s_d1"
        self.exp_name = "yolox_s_d1"

        # Schedule matched to yolox_d1 for a fair capacity comparison.
        self.max_epoch = 40
        self.batch_size = 4
        self.basic_lr_per_img = 0.001 / 64
        self.warmup_epochs = 5
        self.no_aug_epochs = 5
        self.data_num_workers = 0

        self.seed = 20261019

    def get_model(self):
        """Build the dense YOLOX-S model.

        The base Exp.get_model already builds this shape (depthwise False by
        default), but it is written out here so the checkpoint key overlap can be
        asserted rather than assumed: the official yolox_s.pth is a dense COCO
        model, and only the class head keys should differ at num_classes=1.
        """
        import torch.nn as nn

        def init_yolo(module):
            for m in module.modules():
                if isinstance(m, nn.BatchNorm2d):
                    m.eps = 1e-3
                    m.momentum = 0.03

        if getattr(self, "model", None) is None:
            in_channels = [256, 512, 1024]
            backbone = YOLOPAFPN(
                self.depth,
                self.width,
                in_channels=in_channels,
                depthwise=False,
                act=self.act,
            )
            head = YOLOXHead(
                self.num_classes,
                self.width,
                in_channels=in_channels,
                depthwise=False,
                act=self.act,
            )
            self.model = YOLOX(backbone, head)

        self.model.apply(init_yolo)
        self.model.head.initialize_biases(1e-2)
        self.model.train()
        return self.model
