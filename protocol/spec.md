# Wire protocol v1

Little-endian binary framing, identical over AOA bulk endpoints and the TCP (`adb forward`) dev transport.
Constants live in `gen.py`; run `python3 protocol/gen.py` after changing them.

## Header (20 bytes)

| Offset | Field | Type | Notes |
| --- | --- | --- | --- |
| 0 | magic | u16 | `0x5344` |
| 2 | type | u8 | see below |
| 3 | flags | u8 | per type |
| 4 | seq | u32 | per-type counter (VIDEO: per access unit; gap ⇒ keyframe recovery) |
| 8 | timestamp_ns | u64 | sender's monotonic clock (Mac: `CLOCK_UPTIME_RAW`, Android: `CLOCK_MONOTONIC`) |
| 16 | length | u32 | payload bytes that follow |

Receivers skip unknown types by `length`.

**USB short-packet rule.** A bulk transfer whose length is a multiple of the endpoint's max packet size
does not end with a short packet, so the receiving side's read stays pending until more data arrives.
Writers therefore append a header-only `NOP` message whenever a write's total length is a multiple of 512.

## Messages

| Type | # | Dir | Payload |
| --- | --- | --- | --- |
| NOP | 0 | both | empty; padding |
| HELLO | 1 | both | `version u32, panel_w u32, panel_h u32, refresh f32, codec_mask u32, flags u32, name_len u16, name utf8`, then optionally `width_mm u32, height_mm u32` (panel physical size; 0 from the Mac) and `version_len u16, app_version utf8` (e.g. "1.0.0", used to warn when one app is out of date). Tablet: video area (its window) in pixels in the current orientation, codec_mask = hardware decoders it has. |
| CONFIG | 2 | Mac→tab | `codec u32, width u32, height u32, fps u32, full_range u32, session_id u32` |
| VIDEO | 3 | Mac→tab | one Annex B access unit (VPS/SPS/PPS prepended on keyframes), then trailer `capture_cb_ns u64, encode_done_ns u64`. Header timestamp = `SCStreamFrameInfo.displayTime`. flags: bit0 keyframe, bit1 idle refinement |
| KEYFRAME_REQUEST | 4 | tab→Mac | `reason u32` |
| PEN | 5 | tab→Mac | `count u16`, then `count` × 35-byte samples: `t_ns u64, x f32, y f32, pressure f32, tiltX f32, tiltY f32, rotation f32, buttons u8, phase u8, tool u8` |
| TOUCH | 6 | tab→Mac | `count u16`, then `count` × 18-byte samples: `t_ns u64, pointer_id u8, action u8, x f32, y f32` |
| PING | 7 | both | `t1 u64` (sender clock) |
| PONG | 8 | both | `t1 u64, t2 u64, t3 u64` (t2 = receive, t3 = reply, responder clock) |
| FRAME_STATS | 9 | tab→Mac | `seq u32, recv_ns u64, decoded_ns u64, rendered_ns u64` (tablet clock; rendered may be 0 if dropped) |
| BYE | 10 | both | `reason u32` |
| DISPLAY_SIZE | 11 | tab→Mac | `width u32, height u32, width_mm u32, height_mm u32`: the tablet's video area changed (rotation, split screen, free-form resize). The Mac reshapes the virtual display, restarts capture/encode at the new size and sends a new CONFIG. |

Coordinates (`x`, `y`) are normalized 0–1 over the video area. Tilt X/Y are in −1…1 (macOS convention:
+X right, +Y toward the bottom of the screen). Rotation is degrees.

## Session

1. Transport connects. Both sides send `HELLO`.
2. Mac sends `CONFIG`, then starts streaming `VIDEO` beginning with a keyframe.
3. Both sides send `PING` every 2 s. The clock offset (`remote − local`) is taken from the lowest-RTT
   sample of the last 8: `offset = ((t2 − t1) + (t3 − t4)) / 2`.
4. Tablet sends `FRAME_STATS` per displayed frame and `KEYFRAME_REQUEST` on decoder error or seq gap.
5. Either side sends `BYE` before closing.
