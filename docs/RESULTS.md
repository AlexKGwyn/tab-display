# Results on real hardware

Measured 2026-10-04 on a MacBook Air M3 (macOS 26.3, 60 Hz built-in panel) and a Galaxy Tab S9 (SM-X710,
Android 16) over a USB 3 (5 Gb/s) cable.

## Feasibility probes

| Unknown | Finding |
| --- | --- |
| `CGVirtualDisplay` | Works: 1280×800 pt HiDPI = 2560×1600 px, modes report 120 Hz. **But WindowServer composites virtual displays at 60 Hz** on this Mac, whatever the requested rate (120, 90 and 60 all give 60.3 Hz in `probes/vd_rate_probe.swift`). ScreenCaptureKit therefore delivers ≤ 60 frames/s. A ProMotion Mac or an HDMI dummy plug may behave differently (untested). |
| VideoToolbox low-latency RC | Accepted for HEVC, but slower at this size: ~11 ms/frame vs ~6.3 ms with standard real-time RC. Encode time is ≈ 2.4 ms + 2.1 ms/Mpx (single media engine on base M3). `PrioritizeEncodingSpeedOverQuality` and `MaxFrameDelayCount` are rejected. **Shipped: HEVC, standard RC, no reordering.** |
| AOA | Handshake works (AOA v2); the tablet re-enumerates as `18D1:2D01` (accessory + adb), bulk max packet 1024. **Sustained 80 MB/s (640 Mbps)** Mac → tablet, limited by the tablet's 16 KB accessory reads. |
| Tablet decoder | `c2.qti.hevc.decoder`; `FEATURE_LowLatency` = false; profiles Main/Main10/Main Still (no 4:4:4, so no "Sharp text" toggle). Vendor params include `qti-ext-dec-picture-order` but **no `qti-ext-dec-low-latency`**. |

## Latency (moving test pattern, USB, Balanced 80 Mbps)

Stages are measured from `SCStreamFrameInfo.displayTime`, with clocks aligned by PING/PONG (RTT ≈ 0.4 ms).

| Stage | p50 | p95 | Budget | Notes |
| --- | --- | --- | --- | --- |
| capture (display → callback) | −2 to −4 | 2–5 | 2 | ScreenCaptureKit calls back *before* `displayTime` (the frame's target vsync) |
| encode (callback → VT output) | 9.7 | 10.2 | 3 | Includes VT waiting on the capture's GPU fence; pure engine time ≈ 6.3 ms |
| transfer (VT output → last byte on tablet) | 0.45 | 0.8 | 2 | ✅ target ≤ 2 ms p95 |
| decode (read → decoder output) | 5–7 | 7–9 | 4 | Was 8.8 ms until `operating-rate = Short.MAX_VALUE` (max clocks) |
| present (output → expected on-panel) | 11–12 | 16 | 5 | Estimated from Choreographer frame timelines; see below |
| **total** | **22–31** | **31–39** | 16 / 25 | Bimodal per session (see below) |

- **Total is bimodal**: about 22 or 31 ms p50 per session. The gap is one tablet vsync, depending on the
  random phase between the Mac's 60 Hz composite and the tablet's 120 Hz deadline. Mean ≈ 26 ms.
- **Present** is Samsung's compositor: a buffer that makes the deadline is shown about 9.2 ms later
  (`presDeadline`), plus the wait for that deadline. The Qualcomm render callback does not report real
  display times (it passes the PTS back as `systemNano`), so this stage uses Choreographer's expected
  presentation time.
- **Pen input** (tablet `eventTime` → Mac injection): 1.8 ms p50 with `adb input` events. Real S Pen
  numbers are still to be measured.
- The original 16 / 25 ms (p50 / p95) target is not reachable with this hardware and SurfaceView composition. The floor
  is roughly encode 6 + decode 5 + compositor 9–13. Front-buffer rendering, which skips the compositor's
  queue, was tried and dropped (see below).
- No 240 fps camera ground-truth run yet (needs a camera).

## Other goals

| Goal | Status |
| --- | --- |
| Extended desktop on the tablet with per-stage HUD | ✅ at 60 fps (virtual-display limit above), tablet panel pinned at 120 Hz |
| Unplug/replug ×20 without hang or stuck display | ✅ 20/20 simulated (`tools/replug.sh`), ~2.1 s each, exactly one virtual display afterwards. Physical replugs not yet done. |
| Transfer p95 ≤ 2 ms | ✅ 0.8 ms |
| Pressure-sensitive strokes in a pressure-aware app | Pending a real S Pen test. Synthetic pen events arrive as tablet-point events with pressure (`tools/build/inputinspector`). |
| Input p95 ≤ 4 ms | Pending a real S Pen test |
| 12 pt text crisp after scrolling stops | ✅ Visually identical to the source at 4× zoom one second after stopping |
| Signed + notarized, < 2 min install | Self-signed locally; needs a Developer ID to notarize |

## Design decisions and why

- **Encoder RC**: standard real-time rate control instead of low-latency RC (faster at 2560×1600 on M3).
- **Two frames in flight in the encoder**: VideoToolbox waits on the capture's GPU fence, so a single
  in-flight frame left the engine idle and capped throughput.
- **Decoder output on its own thread**: a synchronous drain on the reader thread would leave decoded frames
  waiting until the next USB read returned.
- **Present timing from Choreographer**, not `setOnFrameRenderedListener` (broken on this decoder).
- **Short-packet rule**: writers append a header-only NOP when a write is a multiple of 512 bytes;
  otherwise the reader's bulk transfer would stall.
- **Dirty-area-aware frame caps not implemented**: with an 80 MB/s link, the full 160 KB cap already
  transmits in 2 ms, and the encoder makes small frames for small changes anyway (a caret is ~1–2 KB).
  Scaling the cap down would only cost quality.
- **Idle refinement** re-encodes the last frame up to twice with a capped quantizer (24, then 16) once
  capture reports idle for ≥ 20 ms. At the Balanced bitrate the static frame is already near-lossless,
  so the measured gain was nil, but it's kept for lower bitrates.
- **Black level (resolved)**: Android drew its default focus highlight, a translucent white tint, over the
  focused SurfaceView, so black showed as 41/255. Disabling it with `defaultFocusHighlightEnabled = false`
  restores true 0/255. The video pipeline was correct all along (the Mac decodes its own stream as 0–255).
  The encoder's color tags must match ScreenCaptureKit's (BT.709): tagging sRGB made VideoToolbox add a
  ~3 ms conversion pass.
- **Samsung AOA quirk**: `/dev/usb_accessory` admits one opener, and a USB function switch doesn't send
  `ACCESSORY_DETACHED`. The tablet therefore closes the fd as soon as its reader sees EIO; otherwise the next
  handshake fails with "could not open /dev/usb_accessory".

## Experiment: front-buffer present (removed)

The panel is a command-mode DSI panel (`PanelModeCaps 0x2`, 7.5 ms transfer). The experimental path
decodes into an `AImageReader`, then GPU-blits each frame into a single-buffered, auto-refreshing EGL
surface (`EGL_KHR_mutable_render_buffer` + `EGL_ANDROID_front_buffer_auto_refresh`), which the
display controller re-sends every vsync. The layer composites as a hardware overlay.

- Estimated present dropped from ~11–12 ms to ~6.4 ms p50 (GPU-done time plus half a refresh period).
  The p95 rose to ~18 ms because of occasional slow blits.
- **But it looked worse**: tearing (blits race the scan-out) and irregular frame pacing read as judder
  and a lower frame rate.
- A second attempt (on a Galaxy Tab S6 Lite) wrote each frame in strips just behind the scan line, with
  FIFO pacing. It measured tear-free and saved ~5 ms, but tearing was still visible on a Tab S9, and the
  latency still swung by a full refresh. The Mac's virtual display runs at exactly 60.000 Hz
  whatever fractional rate is requested, so it can't be matched to a 59.92 Hz panel. The present path is
  SurfaceView only.

## 60 Hz tablets: H.264 with low-latency rate control

On a Galaxy Tab S6 Lite (2000×1200, 60 Hz, `OMX.qcom.video.decoder.hevc`, ~15 ms decode at any size),
HEVC managed only ~50 fps with ~10 ms encode. H.264 with VideoToolbox's low-latency rate control encodes
in ~7.8 ms at a steady 60 fps, about 7–10 ms lower total. HEVC's low-latency mode stalls (0–18 fps). On
the Tab S9 (2560×1600 at 120 Hz), H.264 low-latency takes ~13 ms per frame, so the Mac keeps HEVC for
tablets above 60 Hz (`TD_CODEC=hevc|h264` overrides).

## Robustness fixes found while testing

- If the tablet app restarted mid-stream, it joined the byte stream mid-message. The reader now resyncs to the
  next valid header instead of dropping the connection.
- If the session ends while the accessory is still attached, the tablet reopens the accessory.
- The Mac treats 3 s of stalled USB writes as a dead link and reconnects. It now creates the virtual display
  only after the tablet answers HELLO, so retries against a closed app don't make a display flicker.
