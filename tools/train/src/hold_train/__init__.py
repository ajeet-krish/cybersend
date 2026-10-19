"""CyberSend hold detector training pipeline (Apache-2.0 stack only).

Modules are runnable via the console scripts declared in pyproject.toml:
hold-download, hold-convert, hold-split, hold-train-smoke, hold-export.
"""

__all__ = [
    "common",
    "build_dataset",
    "dataset_download",
    "export_onnx",
    "labelme_to_coco",
    "split_dataset",
    "train_d1",
    "train_smoke",
]
