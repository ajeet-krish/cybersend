# Pose Corpus Filming Contract

Last updated: 2026-10-21

P0 deliverable. This is the capture standard for the clips that measure Vision pose accuracy and tune the Tier A metrics. Accuracy in this feature is dominated by capture geometry, not by the model, so these rules are load bearing. A clip that breaks them is still usable for the pipeline, but it cannot support a quality claim.

## Camera placement

| Setup | Allowed for | Rules |
|-------|-------------|-------|
| Tripod or wall mount | Everything, including comparison | Preferred. Lens at roughly chest height of the climber at the start, 3 to 6 m back, level or angled up by no more than 15 degrees |
| Propped on a bag or floor | Everything except spatial comparison | Three points of contact, no part of the phone touching a moving surface. Same angle rule |
| Handheld | Pipeline testing and relative metrics only | Recorded as handheld in the labels. Never used for comparison |

Framing rules, all clips:

1. The whole climber stays in frame from the pad to the top of the problem, for the whole attempt.
2. Body height occupies 40 to 70 percent of the frame height during the attempt. Closer than that and joints clip. Further and the wrist resolution collapses.
3. No zoom, no pan, no refocus during the attempt. Lock focus and exposure before the start.
4. Same orientation for every clip of the same climb, so the clips are comparable.
5. Leave 3 s before the start and 3 s after the fall or the send in the clip. Minimum 5 s, target 10 to 30 s.

## Capture settings

| Setting | Value | Reason |
|---------|-------|--------|
| Frame rate | 60 fps default, 120 fps for dynos and cruxes | Derivative quality. 240 fps is accepted but costs 4x decode and analysis time |
| Resolution | 1080p | 4K buys nothing after the 720 px analysis downscale |
| Stabilisation | Off if the phone is static, standard if handheld | Stabilisation moves the frame and corrupts global drift |
| HDR | Off | Avoids tone mapping variance between clips |
| Lighting | Front or side lit, no backlight, no silhouette | Body pose needs visible limb edges |

## Subject and scene

1. Contrasting clothing against the wall, top and trousers different from each other. Loose clothing that hides elbows and knees degrades wrist and knee confidence.
2. Chalk is fine. Chalk clouds in front of the hands are not.
3. One climber per clip. If someone walks through the frame, note it in the labels.
4. Note the wall angle and the problem grade. They matter for reading the progress curve.

## Corpus target

| Dimension | Minimum |
|-----------|---------|
| Clips | 30 |
| Falls | 10 |
| Gyms | 2 |
| Walls | 3 |
| Lighting conditions | 2 |
| Static setup clips | 10 |
| Handheld clips | 5 |
| Clips with a hand labelled wrist on about 50 frames | 5 |

Clips live outside the repository at `~/CyberSendPoseCorpus/clips/`. Video files are never committed. That directory is scaffolded with a `README.md` (drop and naming workflow), a `labels.json` skeleton matching the schema below, and a `checklist.md` that tracks the 30 clip targets. Labels are committed as JSON under `docs/pose-corpus-labels.json` once the corpus exists, or kept alongside the clips if they contain gym names you do not want in the repo.

## Label file

One JSON file for the corpus, one entry per clip.

```json
{
  "corpus_version": 1,
  "captured_at": "2026-10-22",
  "clips": [
    {
      "clip_id": "c001",
      "file": "clips/c001.mov",
      "device": "iPhone 17 Pro",
      "os": "26.5",
      "gym": "gym name",
      "wall": "wall id",
      "problem": "V5 red circuit",
      "wall_angle_deg": 15,
      "camera": {
        "setup": "tripod",
        "height_m": 1.2,
        "distance_m": 4.0,
        "orientation": "portrait",
        "fps": 60,
        "resolution": "1080p",
        "focus_exposure_locked": true
      },
      "lighting": "led",
      "expected_camera_class": "static",
      "attempts": [
        {
          "start_ms": 4200,
          "end_ms": 16500,
          "outcome": "fail",
          "fall_ms": 15800,
          "fall_note": "slipped on the right crimp"
        }
      ],
      "notes": ""
    }
  ]
}
```

Rules for labels: `start_ms` is when the climber leaves the ground, `end_ms` is the send or the moment the fall begins, `fall_ms` is the first frame of uncontrolled descent. Times are relative to the clip start, in milliseconds. If a clip holds more than one attempt, list them separately and keep the clip.

## What P0 measures from this corpus

| Measure | Gate |
|---------|------|
| Joint coverage on frames where the climber is visible | >= 95% |
| Vision latency at 720 px analysis size, p50 and p95 | Recorded against the 10 fps sustained budget |
| Peak memory during analysis | Recorded against 500 MB |
| Thermal state after 60 s of continuous frames | No serious pressure |
| Static clip jitter after smoothing | <= 0.02 body heights |
| Wrist error against hand labelled frames | Recorded, decides whether contact detection is viable at all |
| Attempt window agreement | Within 1.0 s on >= 80% of clips |
| Camera class classification | Correct on >= 80% of clips |
| Fall detection F1 | Measured against the 0.80 target |

The last two rows are the ones that decide how much of the plan survives. If wrist error is high, contact detection is cut. If fall F1 misses, the review surface narrows to progress and movement metrics.
