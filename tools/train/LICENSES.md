# License Record: Hold Detector Training Pipeline (D1)

Last updated: 2026-10-19

License provenance for everything used under tools/train. This record supports the
US-1 licensing spike and the Phase 4 gate US-34 (model license and dataset
attributions). The machine-readable version of the model side of this record is
written by hold-export into `artifacts/manifest.json`, which the Phase 4 pipeline
copies into `assets/models/manifest.json`.

## Summary Table

| Component | License | Status |
|-----------|---------|--------|
| RF-DETR framework (roboflow/rf-detr) | Apache-2.0 | In use, approved |
| RF-DETR-Nano pretrained weights (rf-detr-nano.pth) | Apache-2.0 | In use, approved |
| YOLOX framework (Megvii-BaseDetection/YOLOX) | Apache-2.0 | D1 comparison run, approved but not yet installed or executed |
| PyTorch (torch, torchvision) | BSD-3-Clause | Toolchain only, not shipped |
| ONNX, onnxruntime (Python and Node) | Apache-2.0, MIT | Toolchain only, not shipped |
| PyYAML | MIT | Toolchain only, not shipped |
| climbtag "Climbing Hold Detection" v29 (Roboflow Universe) | CC BY 4.0 | Merged dataset source, in use, approved |
| blackcreed "Climbing Holds and Volumes" v14 (Roboflow Universe) | CC BY 4.0 | Merged dataset source, in use, approved |
| pwals "Bouldering holds" v18 (Roboflow Universe) | CC BY 4.0 (verified on Universe page 2026-10-19) | Merged dataset source; attribution required in app acknowledgements and NOTICE |
| Own labeled gym photos | User owned | Future held-out domain eval set, not yet collected |
| ClimbInst (Hugging Face, ClimbVision/ClimbInst) | CC BY-NC-SA 4.0 declared, license chain unclear | Retired: smoke subset and smoke artifacts deleted 2026-10-19, never shippable |
| Ultralytics YOLO stack | AGPL-3.0 | Excluded by decision, see below |

## RF-DETR (Apache-2.0)

Framework: roboflow/rf-detr, Apache-2.0. Version pinned in tools/train/pyproject.toml
(rfdetr[train,onnx] >=1.11.2, <2.0.0; 1.11.2 in the committed uv.lock).

Pretrained initialization: rf-detr-nano.pth downloaded by RF-DETR itself into
`~/.roboflow/models/` (shared cache, kept on the host), distributed by Roboflow
under the same Apache-2.0 license as the repository. A model fine-tuned from these
weights stays Apache-2.0, which is the "Apache-2.0 self-trained" path chosen in
docs/requirements.md section 1 and docs/decisions.md.

Shipped weights (Phase 4): the fine-tuned export (holds_detector.onnx) is licensed
Apache-2.0 by this project, with dataset attributions carried in
`assets/models/manifest.json` per US-34.

## YOLOX (Apache-2.0, D1 comparison)

The planned D1 comparison baseline is YOLOX-Nano from the Megvii
BaseDetection/YOLOX repository, Apache-2.0:
https://github.com/Megvii-BaseDetection/YOLOX

This is the only YOLO stack allowed in this project. It is deliberately NOT a
dependency of tools/train today; it gets installed in an isolated environment
only when the comparison run is approved (see the WARNING in
tools/train/README.md). The experiment file is configs/yolox_d1.py.

## climbtag "Climbing Hold Detection" (CC BY 4.0)

Roboflow Universe, v29 export (2026-06-02), 4,931 images, instance segmentation
polygons, classes hold and volume:
https://universe.roboflow.com/climbtag/climbing-hold-detection-7uehq

- Declared license: CC BY 4.0 (dataset README inside the export).
- In use as the largest source of the merged D1 dataset (see DATASET_CARD.md).
- CC BY 4.0 requires attribution in the app (settings/about), planned via US-34
  and the model manifest.

## blackcreed "Climbing Holds and Volumes" (CC BY 4.0)

Roboflow Universe, v14 export (2023-10-12), 4,301 images, bounding boxes, classes
"0" and "1" (hold and volume per the dataset description):
https://universe.roboflow.com/blackcreed-xpgxh/climbing-holds-and-volumes

- Declared license: CC BY 4.0 (dataset README inside the export).
- In use as a source of the merged D1 dataset. Programmatic redownload needs a
  Roboflow API key (see hold-download); the export on disk is the record copy.
- CC BY 4.0 attribution via US-34, same as climbtag.
- blackcreed material also appears inside the retired ClimbInst smoke subset;
  using the upstream dataset directly removes that license-chain ambiguity.

## pwals "Bouldering holds" (CC BY 4.0, verified 2026-10-19)

Roboflow Universe, v18 export (2024-02-22), 500 images, 16 color classes,
bounding boxes plus polygon segmentation:
https://universe.roboflow.com/pwals/bouldering-holds-9wavr

- The Roboflow export README states CC BY 4.0. Independently verified on the
  Universe project page on 2026-10-19: license badge shows CC BY 4.0;
  commercial use and model training allowed; attribution required. The same
  CC BY 4.0 attribution path as the other sources applies (US-34), so this
  adds no new obligations beyond crediting Pwals alongside the others.
- Residual (accepted) risk: the publisher is an individual Roboflow workspace
  with no description, so chain-of-title for the underlying gym photos is
  self-declared. This is a provenance caveat, not a license-term problem; if
  a takedown or challenge ever lands, remediation is remove pwals from the
  SOURCES list in build_dataset.py, rebuild with `uv run hold-build --force`,
  retrain (pwals contributes 46 of 2,977 merged images: a clean subtraction).
- Its 16 color classes are the seed labels for the optional color-family
  classifier (sidecar `datasets/merged/color_labels.json`, US-33).

## Own Gym Photos (user owned)

The primary Phase 4 evaluation data is Ajeet's own labeled gym photos (US-5: at
least 200 photos, at least 1500 hold instances, at least 3 walls, at least 2
lighting conditions). No third-party license applies; copyright stays with the
photographer. Storage stays local (local-first), and photos never leave the
device. Own photos are a separate held-out domain eval set; see DATASET_CARD.md
for the process of adding them.

## ClimbInst (retired, never shippable)

The ClimbInst Hugging Face subset (declared CC BY-NC-SA 4.0, license chain
unclear) was used only for the Phase 0 pipeline smoke run. The smoke subset under
`datasets/climbinst_smoke` and the smoke artifacts were deleted on 2026-10-19
when the merged D1 dataset replaced them. No model from that smoke run ships, and
nothing trained on ClimbInst material may ever ship (non-commercial clause).

## Ultralytics Exclusion (AGPL)

The Ultralytics YOLO ecosystem (code and pretrained weights) is AGPL-3.0 or
commercial-only. It is excluded from this project by user decision on 2026-10-19
(docs/decisions.md, docs/requirements.md section 7 OUT list). No Ultralytics
package is a dependency of tools/train or tools/eval, and no Ultralytics-trained
weights are used anywhere. The recorded fallback if the Apache-2.0 path fails:
cancel the Phase 4 feature or purchase an Ultralytics Enterprise License (US-1).

## How This Record Is Used

- assets/models/manifest.json (Phase 4): license id Apache-2.0 for the model
  artifact plus dataset attributions (climbtag CC BY 4.0, blackcreed CC BY 4.0,
  own photos; pwals only after verification clears).
- App settings/about (Phase 4): user-visible attribution text, US-34.
- artifacts/manifest.json per training run: same fields, written by hold-export.
