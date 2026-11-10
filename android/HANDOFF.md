# Android capture + OCR: Ubuntu handoff

## Start here

Continue from this branch of `smolfroggo/ascii-screenshot`:

```sh
git clone --branch devin/1794216461-android-capture-handoff https://github.com/smolfroggo/ascii-screenshot.git
cd ascii-screenshot/android
```

The complete Android prototype, Gradle wrapper, and compiled OCR models are in this directory. No dependency on the previous Mac's filesystem. Nothing was merged. The parent repo's JavaScript/Python programs are separate; you do not need their dependencies to build this app.

Original session: https://app.devin.ai/sessions/0463afb7463845a48ea07a709737a359

Later device-selection research and the Xiaomi 17 Pro continuation notes are in
[DEVICE_RESEARCH.md](DEVICE_RESEARCH.md). That document links the 112-entry market
audit and OCR benchmark. It does not replace the non-root emulator acceptance
tests below, and no physical phone has been validated.

## User's actual request

The user challenged whether Android accessibility screenshot capture really works without root, then said:

> get an android emulator working and make it work

Then requested this handoff for a new Ubuntu Devin and said:

> put on a branch or sth

**Prove the non-root screenshot capture path on Android. Do not restart phone-shopping research or build the full product first.**

The eventual product captures phone screens at about 1 fps, OCRs Chinese/English text locally, and stores searchable activity history. The user explicitly rejected accessibility-tree text: use screenshot pixels for OCR. Reading accessibility events only to label the foreground package is fine. Production neural inference must use GPU/NPU, not CPU. CPU preprocessing/decoding is acceptable. One particular phone is sufficient; generic Android support is not a goal. No hardware purchase is authorized.

## What is verified, and what is NOT

**Update 2026-11-10:** the Ubuntu emulator run is done. See [EMULATOR_RESULTS.md](EMULATOR_RESULTS.md). The Mac notes below are kept for history.

Verified in the previous Mac VM:

- `./gradlew --no-daemon assembleDebug lintDebug --console=plain` succeeds (JDK 17). Java compilation is included. Gradle reports deprecation warnings, not a failed build. No runtime/instrumentation tests exist yet.
- APK contains arm64-v8a, armeabi-v7a, and x86_64 native LiteRT libraries.
- Android Studio's ARM Android 16/API 36 image could not boot in the Mac VM: `HV_UNSUPPORTED`, no nested virtualization. Even `-accel off` tried HVF. Do not repeat this on Ubuntu.
- As a fallback, Bliss OS Android 13/API 33 x86_64 booted under software QEMU. `sys.boot_completed=1`; ADB shell UID was 2000; APK installation returned `Success`.
- **No successful accessibility screenshot or on-device OCR output was observed.** The session was suspended while attempting to enable the service and inspect its log. Do not count that command as successful. All emulator processes are now gone; the live-CD guest was not a durable Android test environment.

Not verified: permission setup through Android Settings, 1 fps screenshot delivery, app switching, service survival after swipe-away, lock/unlock recovery, reboot recovery, FLAG_SECURE behavior, battery/heat, OEM process management, and Android GPU/NPU integration.

Bliss had custom kernel/root facilities and permissive SELinux; even if it had produced output, it would not establish stock non-root behavior. Prefer an official Google Play emulator image with enforcing SELinux and a normal sandboxed app UID for the actual proof.

## Source map and current behavior

- `app/src/main/AndroidManifest.xml`: main Activity and accessibility service protected by `android.permission.BIND_ACCESSIBILITY_SERVICE`. No root/su permission, no MediaProjection permission, no screen-recording consent flow, no network permission.
- `app/src/main/res/xml/capture_service.xml`: `canTakeScreenshot=true`; subscribes only to window-state events; does not request the accessibility text tree.
- `CaptureService.java`: calls `AccessibilityService.takeScreenshot(Display.DEFAULT_DISPLAY, ...)`, copies the hardware bitmap, hashes pixels, runs OCR if changed, and appends JSONL to private app storage. Records SCREEN_ON/OFF, USER_PRESENT, service lifecycle, foreground package, screenshot errors, timing and OCR lines/boxes.
- `Ocr.java`: Java PP-OCRv6 small detector/recognizer pipeline; axis-aligned connected-component box extraction, crop/resize, wide-line splitting, CTC decoding.
- `MainActivity.java`: button to open accessibility settings and a live tail of the capture log. Do not use its changing log display as the sole capture test: it creates a feedback loop. Switch to other apps.
- `app/src/main/assets/`: detector `v6_small_det608.tflite` (~9.9 MB), recognizer `v6_small_rec640.tflite` (~21.1 MB), Chinese/English dictionary. Model inputs are NCHW float32: detector `[1,3,1280,608]`; recognizer `[1,3,48,640]`. Model files were compiled by Qualcomm AI Hub in the previous session.

**Current app uses LiteRT `Interpreter` with four CPU threads, no GPU/NPU delegate.** This is an emulator plumbing prototype, not compliance with the production accelerator requirement. Keep that distinction explicit. An emulator cannot prove Snapdragon NPU use, phone battery life, or OEM service reliability.

The current loop is serial: screenshot -> OCR -> next screenshot, targeting a 1000 ms interval. If OCR is slow, capture will be slower than 1 fps. Consider a capture-only diagnostic mode first, or separating sampling from newest-frame-wins OCR, so emulator CPU speed is not mistaken for an accessibility API restriction. Log capture timestamps separately from OCR completion. Do not falsely report achieved 1 fps just because the timer is configured to 1000 ms.

Other rough edges to inspect rather than assume fixed: cleanup/callback races when disabling or reconnecting, writer not closed in `onDestroy`, no receiver/exported log viewer, no boot receiver or foreground service/watchdog, sampled whole-frame hash rather than upstream tile diffs. Runtime exceptions go to Logcat; screenshot callback failures go to JSONL. No ASCII renderer, SQLite FTS, incremental-region OCR, or summaries have been ported into this Android prototype yet.

## Build on Ubuntu

Versions currently pinned: AGP 9.5.1; Gradle wrapper 9.8.2; LiteRT 2.3.2; Java 17; compile/target SDK 36; min SDK 33. The last uncommitted Mac edit lowered min SDK 34 -> 33 only to try Bliss; it is included here.

Inspect Ubuntu's architecture/JDK/SDK and existing emulator support before installing anything. Use an x86_64 image on an x86_64 host. For example, after installing official Android command-line tools:

```sh
export ANDROID_HOME="$HOME/Android/Sdk"  # adjust to actual SDK
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
sdkmanager --licenses
sdkmanager 'platform-tools' 'emulator' 'platforms;android-36' 'build-tools;36.0.0'
./gradlew --no-daemon assembleDebug lintDebug
```

The settings include Google's Maven Central mirror because `repo.maven.apache.org` returned HTTP 429 in the Mac VM. Keep it if useful. Do not copy Mac `local.properties`, SDKs, build outputs, signing keys, or `.gradle` caches.

## Emulator setup and non-root proof

For native x86_64 Ubuntu, inspect `/dev/kvm`, CPU virtualization flags and `emulator -accel-check`. Use KVM if available; if absent, investigate the Linux emulator's software fallback or another Ubuntu environment instead of switching to the user's personal Mac. Device/image identifiers below are examples: enumerate them first.

```sh
sdkmanager 'system-images;android-36;google_apis_playstore;x86_64'
avdmanager list device
avdmanager create avd -n capture36 -k 'system-images;android-36;google_apis_playstore;x86_64' -d pixel_9
emulator -avd capture36 -no-snapshot -no-audio -gpu swiftshader_indirect
```

Use supported graphics flags for the installed emulator version; run visibly when recording UI tests. Google Play image is preferred because it is production-style/non-root. If unavailable, clearly document the image used and its limits. Verify `getprop ro.build.version.sdk`, `getprop ro.build.type`, `getenforce`, ADB shell `id`, and the installed app's UID. Do NOT use `adb root`, `su`, root modules, hidden screenshot commands, or a privileged/system app to make the test pass. App capture must come from the public accessibility API.

Install via ADB and launch (select the actual emulator serial):

```sh
adb -s emulator-5554 install -r app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am start -n dev.smolfroggo.asciiscreen/.MainActivity
```

Enable **AsciiScreen capture** in Android Accessibility Settings, accepting the normal permission disclosure. If restricted settings blocks a sideload, use the documented app-info setting and record that requirement. Do not claim a no-root user flow is verified if permission was enabled only by `adb shell settings put secure ...`. That is fine for diagnostics but not the final proof. Do not use MediaProjection as a replacement.

Extract evidence from this debuggable app (run-as is only for log retrieval, not screenshot capture):

```sh
adb -s emulator-5554 shell run-as dev.smolfroggo.asciiscreen cat files/capture.jsonl > capture.jsonl
adb -s emulator-5554 logcat -d -s AsciiScreen AndroidRuntime > capture-logcat.txt
adb -s emulator-5554 shell dumpsys accessibility > accessibility-state.txt
```

## Acceptance tests

1. **Non-root setup:** official image, enforcing SELinux, ordinary installed app, service enabled in Settings. Record actual versions and UID evidence.
2. **Screenshots + OCR from other apps:** switch between at least Settings, launcher, and a separate app/browser with visible English and Chinese text. Match recognized text/boxes to screenshots. App-package labels alone are not proof of pixels/OCR. Verify changing content is captured.
3. **Cadence:** measure successful screenshot timestamps over a useful interval, including changed screens. Report actual intervals, errors, dropped/skipped frames, and OCR duration. Separate capture-only results from the full OCR loop.
4. **Background:** leave the Activity, switch apps, and swipe it out of recents. Verify capture from the other app continues or report the precise failure.
5. **Lock/unlock:** use a genuine configured lock screen, not merely screen-off or dismissed keyguard. Leave it locked for a meaningful interval; unlock and verify the service resumes capturing without another capture-consent prompt. A dark/off screen has no useful content to capture; distinguish that from service death. Record behavior while locked rather than promising it works.
6. **Secure windows:** use a controlled FLAG_SECURE fixture if practical. Report blocked/blank capture/error honestly. Do not bypass secure screens.
7. **Disable/re-enable and reboot:** test service recovery, distinguish before-first-unlock from after-unlock. Reboot persistence is not currently implemented explicitly, so do not promise it.

Fix the minimal prototype as needed to obtain honest results; do not mask errors or broaden into a full app. Deliver one short recording, raw JSONL/Logcat and a concise verdict. Explicitly mark untested cases. User approval for UI-driven testing is the exact sentence quoted above; if using the testing agent, pass that as approval evidence and let it own emulator/UI setup. This handoff itself did not perform UI testing.

## Prior OCR work (separate from this capture test)

Qualcomm AI Hub compiled/profiled PP-OCRv6 small on its Samsung Galaxy S26 family target (Snapdragon 8 Elite Gen 5 **for Galaxy**): detector 1280x608 about 6.24 ms/invocation, all 175 layers NPU; recognizer 48x640 about 3.88 ms/line, all 210 layers NPU. These are neural inference times only, not full-screen throughput or energy. No Android delegate is wired into this app. Do not generalize the Samsung result to Xiaomi/OnePlus without device-specific validation.

Accuracy of the compiled models was evaluated locally on the Mac, NOT by running the full Android app on the cloud phone: about 98.6% character accuracy on synthetic Chinese/English screens and 94.6% on mobile websites, versus Apple Vision 98.5%/94.6%. Corpus/ground truth has limitations; this is not proof of universal equivalence or superiority. Java's simplified postprocess has not been validated on-device.

The AI Hub token was saved as the user-scoped secret `QAIHUB_API_TOKEN`. It is not in this branch. Discover available secrets if further Hub work is needed; never print, commit, or paste the token. It is not needed for the emulator capture test.

## History / guardrails

- iOS app was built/tested, but capture stopped on locking the physical iPhone. Prior promises were too strong; the user is asking for evidence, not more confident guesses.
- Prior iOS work: https://github.com/smolfroggo/ios-ascii-screenshot/pull/1 (reported merged), https://github.com/smolfroggo/ios-ascii-screenshot/pull/2 (reported open). Original combined port: https://github.com/smolfroggo/ascii-screenshot/pull/4 (closed without merging). Statuses are historical; check if relevant.
- Phone constraints later: iPhone Pro-sized, approximately its weight, long battery life, non-folding, reputable maker, rootability important, price not a concern. **No final device is validated.** Earlier phone/root recommendations were provisional and sometimes overconfident; re-verify current SKU/firmware before relying on them.
- Do not purchase a phone, modify the user's computer, merge a PR, bypass secure windows, or claim physical-phone/battery/NPU proof from emulator results.

Next action: get a stock-style Android emulator running on Ubuntu and prove/fix the accessibility screenshot service with observable logs. No need to repeat the entire research phase.
