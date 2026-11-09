# Android ASCII Screen: device research and continuation

Research snapshot: **9 November 2026**. Original session:
https://app.devin.ai/sessions/0463afb7463845a48ea07a709737a359

## Bottom line

**Xiaomi 17 Pro is the strongest near-compact persistent-root lead found in this
audit, not a guaranteed purchase-ready unlock path.** An owner describes working
root after multiple reboots on a named Xiaomi.eu build. We have not established
how every newly purchased, locked handset reaches that state.

The Android prototype builds, but **successful screenshot/OCR output has not been
observed in this session**. No selected physical phone has been tested. Rooting,
capture reliability, NPU execution and battery life are separate questions.

## Resources on this branch

- [HANDOFF.md](HANDOFF.md): existing prototype, Ubuntu emulator setup, source map,
  known implementation gaps and the non-root acceptance tests.
- [Market data](research/phone-market-2026-11-09.json): 112 model, regional or
  family entries across 20 Android brands. Each entry includes release dates,
  original model/region, hardware, battery/endurance, evidence class, exact known
  firmware, source URLs, physical-fit verdict and missing checks.
- [Interactive market comparison](research/phone-market-2026-11-09.html): download
  and open in a browser for search and filters. Its data is embedded; the renderer
  loads the Devin artifact kit from `static.devin.ai`.
- [OCR benchmark](research/ocr-benchmark-2026-11-08.md): tested corpora, Samsung
  AI Hub timings and the limits of transferring those results to another phone.
- [MODEL_SHA256SUMS](MODEL_SHA256SUMS): checksums for the bundled OCR assets.

These are research snapshots, not guarantees about later updates or retail stock.
There are not 112 independently verified rooted phones: variants, oversized
family representatives and explicitly older fallbacks are included. The audit is
broad, not a catalog of every Android ever sold.

## User's intended system

One personal device, not a generic Android product:

```text
screen pixels -> sample/diff at about 1 fps -> Chinese/English OCR
              -> lines/layout/ASCII -> compressed local history
              -> local search -> historical summaries
```

Use screenshot OCR, not accessibility-tree text. Prefer GPU/NPU inference, with
CPU preprocessing/postprocessing as needed. Korean is not required. The useful
lifecycle target is capture during use, pause when the display is off, and resume
after unlock without manually restarting the recorder.

Hardware preferences: modern flagship-class performance, long battery life,
non-folding, reputable maker, approximately iPhone Pro size/weight; price is not
the constraint. The reference used was iPhone 16 Pro, 149.6 x 71.5 x 8.25 mm and
199 g. Most near-compact candidates are slightly larger, not literal fits.

The user explicitly values **actual community unlock/root evidence over official
manufacturer permission**. Official policy is not an automatic veto. Conversely,
a generic guide, a seller's "unlocked/global ROM" listing, a sibling phone's
success or an OEM-unlocking toggle is not proof for the intended handset.
SIM-unlocked is not bootloader-unlocked.

## Xiaomi 17 Pro: what the evidence establishes

| Item | Finding |
|---|---|
| Hardware target | China model 25098PN5AC; codename `pandora` |
| Announcement / first sale | 25 / 27 September 2025 in China |
| Processor | Snapdragon 8 Elite Gen 5 |
| Dimensions / weight | 151.1 x 71.8 x 8.0 mm; 192 g |
| Battery | 6,300 mAh China model |
| Working owner configuration | Xiaomi.eu `OS3.0.318.0.WBLCNXM`, Android 16; kernel `6.12.23-android16-5`; KernelSU Next v3.3.0 |
| Strongest statement | Owner reports root "Working after multiple reboots" |

Primary source, read directly:
[Xiaomi.eu owner thread, September 2026](https://xiaomi.eu/community/threads/xiaomi-17-pro-pandora-%E2%80%94-kernelsu-next-works-but-wallet-contactless-and-revolut-login-still-fail.76746/).
The initial post identifies PANDORA and an already-unlocked bootloader. Later
posts describe another working kernel configuration. This is an owner report,
not our reproduction, and does not document the initial unlock acquisition.
Xiaomi.eu is a custom ROM, not a factory-global hardware SKU.

The phone is 1.5 mm taller and 0.3 mm wider than the reference, but 7 g lighter.
Its hardware is a September 2025 generation, not the newest 2026 generation.
One review reports PCMark endurance of 17 h 10 min on a Chinese-software unit;
that is neither recorder runtime nor directly comparable with web-browsing or
GSMArena Active Use hours. See the market row for review/specification sources.

**Not established:** unlocking from the actual shipping stock build, a complete
repeatable path for a fresh handset, support for later updates, Singapore carrier
compatibility, our capture service, NPU delegation, sustained heat or OCR drain.
The thread also documents payment/work-app compatibility problems, including
Intune rejecting root. Root success does not guarantee those apps will work.

## Other important leads and corrections

- **OnePlus 15T, PLZ110:** March 2026; Snapdragon 8 Elite Gen 5, 7,500 mAh,
  approximately 194 g, 150.56 x 71.82 mm. Notebookcheck measured over 34 hours of
  Wi-Fi browsing, not screenshot/OCR recording. A
  [June owner report](https://github.com/superturtlee/gbl_root_canoe/discussions/61)
  names firmware `16.0.8.300` and describes installing KernelSU and rebooting
  after an update. It lacks a post-reboot privilege check and the initial unlock
  route. [Maintained LineageOS support](https://wiki.lineageos.org/devices/fairlady/install/)
  names exact model PLZ110. A different October project demonstrates only
  reboot-ephemeral root on `PLZ110_17.0.0.106(CN01)`. Do not erase the older
  evidence, imply a controlled persistence test, or transfer methods across builds.
- **Galaxy S25:** 146.9 x 70.5 mm, 162 g, Snapdragon 8 Elite and 4,000 mAh.
  [An SM-S931B owner reports installed Magisk root](https://xdaforums.com/t/how-to-update-magisk-alpha-28-1-to-30-6-samsung-user-sm-s931b.4771808/).
  It is the recent flagship fallback for a literal footprint limit, not proof
  that current sealed stock or US/carrier variants can be unlocked. The other
  strict-fit phone in this inventory is the older, 2023 ASUS Zenfone 10.
- **Xiaomi 18 Pro:** September 2026 near-compact hardware. A
  [secondary report](https://ximitime.com/xiaomi-18-pro-and-fold-get-unofficial-bootloader-unlock-101065/)
  attributes a researcher bootloader unlock to an inaccessible original post.
  No public repeatable method/build or owner-persistent-root proof was verified.
- **OPPO Find X9s Pro, vivo X300 FE/X500 Pro, Honor Magic8 Pro Air/Magic9 and
  Meizu 22** belong in the comparison. Missing owner proof is *unknown*, not
  impossible. Magic9's exact-device temporary-root research also reports crash
  risk, making it a poor established basis for an unattended recorder.
- Sony, Motorola, ASUS, Nothing, Fairphone, Redmi/POCO, iQOO, Nubia and RedMagic
  were inventoried too. Most flagship alternatives fail the physical-size
  preference; compact fallbacks can instead compromise on age/performance.
- Do not call compact Pixel 11/11 Pro root confirmed from the stronger Pixel 11
  Pro XL report. Exact model, original region, build, method and persistence matter.
- Battery capacity is not runtime. Different reviews' PCMark, Wi-Fi, mixed-use
  and Active Use results cannot be ranked as one common scale.

The JSON preserves per-device details and sources rather than relying on this
short list. `OWNER_ROOT_REPORT` means reported rooted use without an explicit
post-reboot privilege check; `OWNER_PERSISTENT_ROOT` records stronger boot/root
reports, still not our own reproduction. Bootloader unlock, temporary root,
maintained project support, research demos, guides and commercial claims remain
separate, sometimes coexisting for different methods on the same phone.

## Continuing with an actual handset

First establish its original SKU, stock build, kernel/security patch and current
bootloader state. Record read-only device information before changing anything;
do not assume the forum's starting state matches the phone. A phone attached by
USB to a computer accessible to the engineer is needed for physical validation.

An already-unlocked unit avoids the initial acquisition problem. A locked unit
still needs a demonstrably applicable unlock route. Do not treat possession of
the handset, removed boot warnings or a working temporary-root project as proof
of persistent root or bootloader unlock.

Unlocking commonly erases data. Obtain explicit approval before a wipe or flash;
check matching images, hashes, recovery options and rollback restrictions. Do
not blindly flash forum images, downgrade speculatively or implement an exploit.
No phone has been purchased, connected, unlocked or flashed by this session.

For capture, start with the ordinary-app public
[AccessibilityService screenshot API](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)
used by the prototype. Accessibility permission is not root. Root may provide
options for lifecycle/device integration if measured failures justify it, but
does not itself guarantee reliable capture or efficient inference. MediaProjection
has separate consent/lock lifecycle constraints and is not proof that this route
works. Follow the non-root acceptance criteria in HANDOFF.md rather than making
that test pass through root privileges.

Phone-specific validation still includes changing pixels/OCR in other apps,
app switching, genuine lock/unlock recovery, disable/re-enable, reboot,
OEM process survival, actual screenshot cadence/errors, NPU/GPU delegation and
measured energy/thermals. Respect secure-window/DRM capture failures; do not
bypass them. No attestation or employer-policy bypass is proposed.

The Android code currently logs screenshots/OCR as JSONL and skips unchanged
whole-frame hashes. It does **not** yet implement the production ASCII/layout
renderer, compressed history, SQLite FTS, summaries, a boot/watchdog component
or a GPU/NPU delegate. A passing build is not a working recorder.

## Alternative architecture retained from the discussion

An iPhone could mirror wirelessly to a standalone Linux appliance that receives
AirPlay, decodes video, samples frames, runs local OCR and stores/searches history.
It need not forward to a MacBook or use an HDMI cable.
[UxPlay](https://github.com/FDH2/UxPlay) is the receiver starting point; a
[Radxa ROCK 5C](https://docs.radxa.com/en/rock5/rock5c/getting-started/introduction)
and [Rockchip OCR examples](https://github.com/airockchip/rknn_model_zoo/tree/main/examples/PPOCR)
were hardware/software leads, not a validated PP-OCRv6 appliance.

Unattended lock/unlock resumption, reconnection, portable networking, small-text
quality, battery and protected content remain untested. This architecture moves
recording outside iOS but cannot force the iPhone to keep transmitting. Running
usable iOS on an Android phone is not a practical alternative.
