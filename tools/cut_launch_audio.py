#!/usr/bin/env python3
"""Cuts the liftoff out of a long NASA pad-microphone recording.

Input: any audio file ffmpeg reads. Output: <out>.ogg (mono, 44.1 kHz) with
`--before` seconds before and `--after` seconds after the loudest moment (the
rocket passing the microphone), and the per-second loudness printed to the log.
"""
import argparse
import subprocess

import numpy as np

RATE = 22050


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--before", type=float, default=30.0)
    ap.add_argument("--after", type=float, default=110.0)
    a = ap.parse_args()
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", a.src, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
                         check=True, capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    n = len(x) // RATE
    rms = np.sqrt((x[: n * RATE].reshape(n, RATE) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    # Liftoff: the loudest 20 s stretch.
    win = 20
    smooth = np.convolve(db, np.ones(win) / win, mode="valid")
    peak = int(np.argmax(smooth))
    print("length %d s, loudest 20 s from %d s (%.1f dBFS)" % (n, peak, smooth[peak]))
    for s in range(max(peak - 60, 0), min(peak + 150, n)):
        print("  t=%5d  %6.1f dB" % (s, db[s]))
    start = max(peak - a.before, 0)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(start), "-t", str(a.before + a.after), "-i", a.src,
                    "-ac", "1", "-ar", "44100", "-c:a", "libvorbis", "-q:a", "6", a.out + ".ogg"], check=True)


if __name__ == "__main__":
    main()
