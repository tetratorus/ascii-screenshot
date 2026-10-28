Vision OCR cost experiments (not part of the build).

    swiftc -O ocr-regions.swift -o /tmp/regions && /tmp/regions ../../shots/x.png [--fast] [--dump]
    swiftc -O ocr-sizes.swift -o /tmp/sizes && /tmp/sizes shot.png [--fast]
    swiftc -O ocr-batching.swift -o /tmp/batching && /tmp/batching

- regions: K changed text regions read as separate calls, one call with K ROIs, separate crops, or one packed image.
- sizes: cost of one call vs crop area.
- batching: fixed per-call cost, cost vs line count, and 10s temporal batching (every 1s vs latest only vs stitched).
