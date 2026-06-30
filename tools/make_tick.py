"""Synthesize a soft, click-free metronome tick.

Pure Python stdlib (no numpy). Produces a short 16-bit mono WAV. Re-run to
regenerate the asset:  python3 tools/make_tick.py

Design (brief §4 "short, dry, soft percussive tick; no harsh/high sounds", plus
de-clicking): a low-pitched tone (~250 Hz) with a small fade-in so the onset
"blooms" instead of snapping, an exponential decay tail so it tails off softly, a
gentle one-pole low-pass to remove any harsh high-frequency transient, and a
final fade-out to zero. Because it's an enveloped sine it's inherently
click/pop-free (starts and ends at a zero crossing). Kept soft so it sits under
speech. Same format the player already uses (44.1 kHz / 16-bit / mono).
"""
import math
import struct
import wave

SAMPLE_RATE = 44100
DURATION_S = 0.14          # longer so the tail can decay smoothly
ATTACK_S = 0.005           # ~5 ms fade-in (bloom, not a snap)
RELEASE_S = 0.012          # final fade-out to guarantee a zero ending
DECAY_TAU_S = 0.030        # gentle exponential decay tail (~30 ms)
PARTIALS = [(250, 1.0), (500, 0.18)]  # soft low "tock", slight body
PEAK = 1.20                # loud + clearly audible for the beat-focused phases (the
                           # tick is muted under the spoken guide + during capture, so
                           # it never fights speech or bleeds into the mic). Only scales
                           # amplitude — the attack/decay/LPF envelope is unchanged, so
                           # it stays click-free. The synth's intrinsic peak is ~0.72,
                           # so 1.20 lands near -1.4 dBFS with headroom (no clipping).
LPF_CUTOFF_HZ = 1200       # soften any high-frequency edge
OUT = "assets/audio/tick.wav"

n = int(SAMPLE_RATE * DURATION_S)
attack_n = max(1, int(SAMPLE_RATE * ATTACK_S))
release_n = max(1, int(SAMPLE_RATE * RELEASE_S))
gain_sum = sum(g for _, g in PARTIALS)

# 1. Enveloped sine partials.
raw = []
for i in range(n):
    t = i / SAMPLE_RATE
    env = math.exp(-t / DECAY_TAU_S)
    if i < attack_n:                 # smooth fade-in
        env *= i / attack_n
    s = sum(gain * math.sin(2 * math.pi * f * t) for f, gain in PARTIALS) / gain_sum
    raw.append(env * s)

# 2. One-pole low-pass to round off the transient.
rc = 1.0 / (2 * math.pi * LPF_CUTOFF_HZ)
dt = 1.0 / SAMPLE_RATE
alpha = dt / (rc + dt)
lp = []
prev = 0.0
for x in raw:
    prev = prev + alpha * (x - prev)
    lp.append(prev)

# 3. Final fade-out to zero (kills any end-edge pop).
for k in range(release_n):
    idx = n - 1 - k
    lp[idx] *= k / release_n

with wave.open(OUT, "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)  # 16-bit
    w.setframerate(SAMPLE_RATE)
    w.writeframes(b"".join(
        struct.pack("<h", max(-32768, min(32767, int(PEAK * s * 32767)))) for s in lp
    ))

print(f"wrote {OUT}: {n} samples, {DURATION_S*1000:.0f} ms")
