# CyberSend Hold Detection Dataset Card (merged v1)

Last built: 2026-10-19 by `uv run hold-build` (seed 20261019). The authoritative
machine-readable record is `datasets/merged/manifest.json` (git-ignored,
re-creatable from `datasets/raw/`). This card documents what the dataset is, how
it was made, and what it is not good for.

## pwals license verified

The pwals source license was independently verified on the Roboflow Universe
project page on 2026-10-19: CC BY 4.0, commercial use and model training
allowed, attribution required (tracked in `tools/train/LICENSES.md`). No
provisional status remains.

## Sources

| Source | Roboflow project | Version | Export date | Classes (raw) | Raw images | Raw annotations | License |
|--------|------------------|---------|-------------|---------------|-----------|-----------------|---------|
| climbtag | [climbtag/climbing-hold-detection-7uehq](https://universe.roboflow.com/climbtag/climbing-hold-detection-7uehq) | v29 | 2026-06-02 | hold, volume (polygons) | 4,931 | 191,665 | CC BY 4.0 |
| blackcreed | [blackcreed-xpgxh/climbing-holds-and-volumes](https://universe.roboflow.com/blackcreed-xpgxh/climbing-holds-and-volumes) | v14 | 2023-10-13 | "0", "1" (boxes) | 4,301 | 149,233 | CC BY 4.0 |
| pwals | [pwals/bouldering-holds-9wavr](https://universe.roboflow.com/pwals/bouldering-holds-9wavr) | v18 | 2024-02-22 | 16 color classes (boxes) | 500 | 15,189 | CC BY 4.0 (verified 2026-10-19) |

Notes:

- climbtag v29 is an augmented export (about 3x Roboflow augmentation over about
  1,644 source photos). v25 is the unaugmented snapshot if a cleaner export is
  ever needed.
- blackcreed v14 is an augmented export (4,301 images over about 1,716 source
  photos). Classes "0" and "1" are hold and volume per the dataset description.
- climbtag and blackcreed share a large scraped photo pool (1,579 photo stems in
  common), which is why cross-source deduplication matters here.
- pwals contains 12 annotation entries whose file names exceed the 255 byte file
  name limit (280 characters), so those files never extracted and are dropped at
  load time (counted as `images_dropped_missing_file` in the manifest).

## Methodology (hold-build pipeline)

1. Category mapping. Every raw category maps to the single training class
   `hold` (category id 0): climbtag hold+volume, blackcreed "0"+"1", all 16
   pwals color classes. Roboflow synthetic parent categories (id 0, unannotated)
   are skipped.
2. Annotation normalization. Axis-aligned bboxes in source pixels; bbox derived
   from polygon min/max when absent; bboxes clipped to image bounds (881
   clipped, counted per source in the manifest); degenerate boxes under 2 px on
   a side dropped (186 dropped); `iscrowd=1` dropped (none present).
3. Deduplication (two verified stages):
   - Stage A (exact): every Roboflow variant family, images of one source
     sharing a photo stem (the name before the `.rf.<hash>` suffix,
     case-insensitive), is unioned. 6,196 family edges.
   - Stage B (verified): cross-family candidate pairs within pHash Hamming
     distance 6 (64-bit pHash: 32x32 LANCZOS grayscale, DCT-II, 8x8 median
     threshold) are verified by Pearson correlation of 64x64 grayscale
     thumbnails and merged only at correlation >= 0.975. 190,102 candidates,
     886 verified merges.
   - Why verification is required: climbing wall imagery is low-frequency
     homogeneous, so pHash alone over-merges badly on this corpus (different
     wall photos collide even at Hamming distance 0; blind single-linkage at
     distance 6 collapses 9,720 images into one cluster). The thumbnail
     correlation cleanly separates true duplicates (re-exports and
     cross-dataset reuse, correlation near 1.0) from merely similar walls
     (correlation near 0).
4. Representative selection. Each cluster keeps one image: largest resolution,
   then alphabetically first file name. 6,743 duplicates dropped.
5. Resplit (original Roboflow splits DISCARDED). They were split before
   augmentation, so augmented copies of one photo leak across them. Whole
   clusters are assigned to train/val/test 60/20/20 by
   `sha256('<seed>:<representative pHash hex>')` mod 10,000 (under 6,000 train,
   under 8,000 val, else test). Seed 20261019. The assignment is deterministic:
   two consecutive builds produced identical annotation-file SHA256 digests.
6. Sanity checks (fail loudly, recorded in the manifest): no cluster spans two
   splits (checked from the emitted split assignment; this guards the writer,
   not dedupe recall, see Known limitations), every image file referenced by an
   output annotation file exists on disk, every bbox sits inside its image.

## Final counts

| Split | Images | Annotations | climbtag (img/ann) | blackcreed (img/ann) | pwals (img/ann) | Frozen | annotations sha256 (first 16) |
|-------|--------|-------------|--------------------|----------------------|-----------------|--------|------------------------------|
| train | 1,804 | 66,985 | 938 / 35,931 | 838 / 30,022 | 28 / 1,032 | no | a5ffe520120197cc |
| val   | 591   | 22,782 | 321 / 13,120 | 260 / 9,410  | 10 / 252   | no | 79c18be326bcc6ce |
| test  | 582   | 24,160 | 316 / 13,219 | 258 / 10,711 | 8 / 230    | **yes (frozen)** | d1d4837786d27130 |

Totals: 2,977 images, 113,927 annotations, 2,977 clusters, 6,743 duplicate
images dropped, from 9,720 source images. On-disk size of `datasets/merged`:
about 290 MB (raw: about 1.0 GB).

Image ids and file names inside each split JSON are self-contained; image files
are prefixed with their source name (for example `climbtag__0_jpg.rf.<hash>.jpg`)
so cross-source name collisions are impossible.

## Color sidecar (`color_labels.json`)

For pwals images only, `datasets/merged/color_labels.json` maps split and image
id to per-box color families. This is seed data for the optional color-family
classifier (US-33) and is NOT part of detection training. Normalization: strip
the `-hold` suffix; classes with more than one color token (for example
`black-pink-hold`) map to `multi`. 13 families appear: black, blue, brown, cyan,
gray, green, multi, orange, pink, purple, red, white, yellow. 46 pwals images
carry sidecar labels (train 28, val 10, test 8).

## Known limitations

- Augmented exports. climbtag v29 and blackcreed v14 bake in Roboflow
  augmentation (rotation, exposure, blur). The dedupe collapses most variants
  of one photo into one representative, but the surviving representatives are
  still augmentation-processed images; baked-in synthetic transforms can look
  unrealistic for some gyms compared with raw phone photos.
- Domain shift. All three sources are proxy domains: other people's gyms,
  cameras, and lighting. The user's gym photos (different wall colors, hold
  wear, lighting, camera processing) will differ. Expect precision and recall
  on the user's domain to trail the proxy-domain numbers until US-5 data
  exists.
- The test split is proxy-domain and frozen, not user-domain. It gates
  tooling and proxy quality only (Phase 4 acceptance in docs/requirements.md
  section 6 must additionally be measured on the frozen self-collected test
  set from US-5).
- Dedupe recall. True duplicates that differ strongly (heavy crops, rotations,
  or recoloring across datasets) can survive the pHash shortlist plus
  correlation check. The cluster-level split still prevents the dominant leak
  path (Roboflow variant families), and the frozen test split should be
  audited for near-duplicates against the user's own eval photos before any
  cross-domain claims.
- blackcreed class semantics. "0" and "1" are mapped to hold and volume per the
  dataset description; the export itself does not document the mapping.
- 12 pwals files were never extractable (over-long file names) and are absent.
- Single class. Volumes are merged into `hold`; no hold-type or difficulty
  taxonomy is learned.

## Adding the user's own gym photos (Phase 0 US-5, Phase 4)

Own gym photos are a SEPARATE held-out domain evaluation set (and only later a
fine-tuning source). They are never merged into these splits:

1. Collect and label with labelme under `datasets/own_gym/<name>/` following
   US-5 (>= 200 photos, >= 1,500 hold instances, >= 3 walls, >= 2 lighting
   conditions, 10 percent double-annotated with a disagreement log).
2. Convert and split with the existing `hold-convert` and `hold-split` console
   scripts, freezing that test split before any training.
3. Evaluate the D1 model (and later the release candidate) on the frozen
   own-gym test split with `tools/eval`. Proxy-domain numbers from this merged
   dataset never substitute for own-domain numbers.
4. If fine-tuning on own photos is chosen later (typically better for domain
   shift), fine-tune FROM the D1 baseline checkpoint and record the decision in
   docs/decisions.md; do not rebuild the merged dataset with own photos mixed
   in, or the domain benchmark is lost.
