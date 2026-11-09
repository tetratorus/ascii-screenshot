# Mixed Chinese/English OCR: measured results and limits

Snapshot: 8 November 2026. These are results recorded in the original session,
not a fresh benchmark run by this documentation commit.

## Two different experiments

1. **Accuracy:** locally on the Mac, comparing Apple Vision, RapidOCR/ONNX
   reference models and the AI Hub-compiled TFLite files in a phone-style
   pipeline. This was not the Android Java pipeline running on a phone.
2. **Neural inference timing/delegation:** Qualcomm AI Hub on a Samsung Galaxy
   S26-family Snapdragon 8 Elite Gen 5 **for Galaxy** target. This excludes
   screenshot acquisition and CPU preprocessing/postprocessing.

The synthetic corpus contained nine mixed Chinese/English phone-style screens.
The web corpus contained nine mobile-site pages. Text was compared against
line/DOM ground truth using edit distance; web ground truth includes noise such
as icon fonts, unsupported script and image text. Scores are corpus-specific,
not a universal accuracy guarantee.

## Character accuracy

| Engine | Synthetic screens | Mobile web pages |
|---|---:|---:|
| Apple Vision, Simplified/Traditional Chinese and English | 98.5% | 94.6% |
| PP-OCRv6 small, RapidOCR/ONNX reference | 98.6% | 95.7% |
| PP-OCRv6 small, AI Hub-compiled TFLite, larger input shapes | 98.6% | 94.6% |
| PP-OCRv6 tiny, reference | 98.5% | 95.2% |
| PP-OCRv4, reference | 98.7% | 94.8% |
| Qualcomm prebuilt PP-OCRv5 int8 | 93.5% | 91.5% |

The larger-shape PP-OCRv6 small files matched Vision on the tested web corpus and
were not worse on the synthetic corpus. This does not establish universal
superiority or phone-side end-to-end equivalence. In particular, Android's Java
postprocessing is a simplified port and still needs output-parity validation.

## Samsung AI Hub NPU measurements

Inputs are NCHW float32. The model output still requires CPU box extraction,
cropping and CTC decoding.

| PP-OCRv6 small model | Input shape | Reported inference | Reported NPU layers |
|---|---|---:|---:|
| Detector | 1 x 3 x 960 x 448 | 3.44 ms | 175/175 |
| Detector used in prototype | 1 x 3 x 1280 x 608 | 6.24 ms | 175/175 |
| Recognizer | 1 x 3 x 48 x 320 | 2.01 ms | 210/210 |
| Recognizer used in prototype | 1 x 3 x 48 x 640 | 3.88 ms per crop | 210/210 |
| Batched recognizer | 8 x 3 x 48 x 320 | 14.58 ms per batch | 211/211 |

These prove full neural-model NPU delegation for those jobs on that Samsung
target, **not on Xiaomi, OnePlus, Tensor, MediaTek or a newer Snapdragon**.
The 48 x 640 recognizer reduced long Chinese-line splitting errors in the tested
pipeline. A rough sum of model invocations is not a measured full-screen runtime
or an energy estimate.

## Current implementation and unresolved work

- The prototype bundles the detector/recognizer TFLite files and dictionary;
  from the `android/` directory, run `shasum -a 256 -c MODEL_SHA256SUMS`.
- Its LiteRT `Interpreter` currently uses four **CPU** threads. Compiling models
  via AI Hub does not automatically enable an Android NPU delegate.
- Verify supported delegate/runtime/driver versions on the actual chosen phone,
  observed partitioning/fallbacks, numerical output parity and sustained latency.
- Capture, resize, box postprocess, crops, CTC, ASCII, compression and indexing
  all contribute to end-to-end work outside the timed neural invocations.
- Neither experiment measured phone battery, heat, OEM lifecycle survival or
  actual 1 fps screenshot-to-history throughput.
- An AI Hub credential is available to the original user's Devin environment as
  `QAIHUB_API_TOKEN`; no credential value is in this branch. It is unnecessary
  for the emulator capture test. Never print or commit its value.

For a new run, keep exact model hashes, compiler/runtime versions, target device,
input shapes, hardware-delegation reports and measured timings with the results.
Do not claim that the original session's private benchmark workspace or all raw
AI Hub logs are included here; this branch preserves the model assets and the
result summary, not the entire experimental workspace.
