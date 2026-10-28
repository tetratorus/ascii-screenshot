# Verification

macOS only: the Swift app in `macos/` is the whole product. There are no other platform ports; don't add any.

- Build: `swift build -c release --package-path macos`.
- Test the renderer, line detector, pipeline and history/search: `swift test -c release --package-path macos`.
- Test the benchmark summarizer: `python3 -m unittest discover -s tests -v` (standard library only).
- Check benchmark-runner syntax with `node --check macos/benchmarks/energy.mjs`. The runner requires a Node version with built-in `fetch` and `WebSocket` support, such as Node 22+.
- Check the installer: `bash -n macos/install.sh`.

# Benchmark safety

- Live benchmarks capture the display and occupy a dedicated Chrome test window. Run them only with explicit approval.
- Benchmark outputs must remain outside the repository. Do not commit captures, OCR text, profiles, power logs, or machine-specific measurements.
- `macos/benchmarks/energy.mjs --prepare` opens only the synthetic fixture. `--run` starts capture and requires an already-running power sampler.
- Use `--only after-default-1x --workload static` for a single native case. `--output` must name a new directory; omitting it creates a private temporary directory.
- The runner waits for the first native output before warmup. Cold initialization must not be reported as steady-state OCR latency.
- Summarize completed runs with `python3 macos/benchmarks/summarize.py <events.jsonl> <power-log>`. System rail power is not app-attributed power, and process Energy Impact is not an Activity Monitor UI reading.
- `macos/install.sh` installs a LaunchAgent and starts capturing the display; run it only with explicit approval. Screen Recording for the agent is granted per bundle id in System Settings and cannot be scripted (the TCC database is SIP-protected).

# Screen history index

- `~/.ascii-screen/history/YYYY-MM-DD.txt.gz` (gzip members of `@@ <ISO-8601 time>` + frame text records) is the source of truth. `index.sqlite` beside it is rebuilt from them, so it can be deleted.
- `ascii-screen --search <query> --json` prints one `{"start","end","frames","line"}` object per run of consecutive matching frames, newest first; exit 1 means no match, exit 2 a bad query. Feed `start` to `--at` or `--play --from` to see the screen.
- Query it directly with `sqlite3 -readonly`: `frames(id, time, day, offset, seq)` places each frame in a day file (`time` is Unix seconds, `offset` the gzip member's byte offset, `seq` the record within that member); `words` is a contentless FTS5 table (`detail=none`) with rowid = `frames.id`; `vocab` (fts5vocab, `term`/`doc`) lists every indexed word with the number of frames containing it.
- Search has no fuzzy matching built in. OCR misreads words, so for near-misses look up spellings first, e.g. `SELECT term, doc FROM vocab WHERE term LIKE 'inv%ice%'`, then search `invoice OR lnvoice`.
- Example: frames containing a word in a time range, newest first: `SELECT f.time, f.day, f.offset, f.seq FROM words JOIN frames f ON f.id = words.rowid WHERE words MATCH 'invoice' AND f.time > strftime('%s','now','-7 days') ORDER BY f.id DESC LIMIT 20`.
