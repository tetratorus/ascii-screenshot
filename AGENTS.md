# Verification

- Build the native executable before parity tests: `swift build -c release --package-path macos`.
- Run native pipeline/output tests: `swift test -c release --package-path macos`.
- Run Python, JavaScript, and native parity tests: `.venv/bin/python -m unittest discover -s tests -v`.
- The Python suite skips native parity when `macos/.build/release/ascii-screen` is absent, so a passing Python-only run does not establish three-way parity.
- Check benchmark-runner syntax with `node --check macos/benchmarks/energy.mjs`. The runner requires a Node version with built-in `fetch` and `WebSocket` support, such as Node 22+.

# Benchmark safety

- Live benchmarks capture the display and occupy a dedicated Chrome test window. Run them only with explicit approval.
- Benchmark outputs must remain outside the repository. Do not commit captures, OCR text, profiles, power logs, or machine-specific measurements.
- `macos/benchmarks/energy.mjs --prepare` opens only the synthetic fixture. `--run` starts capture and requires an already-running power sampler.
- Use `--only after-default-1x --workload static` for a single native case. `--output` must name a new directory; omitting it creates a private temporary directory.
- The runner waits for the first native output before warmup. Cold initialization must not be reported as steady-state OCR latency.
- Summarize completed runs with `python3 macos/benchmarks/summarize.py <events.jsonl> <power-log>`. System rail power is not app-attributed power, and process Energy Impact is not an Activity Monitor UI reading.
- `macos/install.sh` installs a LaunchAgent and starts capturing the display; run it only with explicit approval. Screen Recording for the agent is granted per bundle id in System Settings and cannot be scripted (the TCC database is SIP-protected).
