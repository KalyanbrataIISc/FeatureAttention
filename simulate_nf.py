#!/usr/bin/env python3
"""Writes randomized SSVEP neurofeedback values into nf.txt, mimicking the
binary format and write cadence RT_acquisition_7.m uses in the real
experiment room, so gameNF.m can be exercised on mac without real EEG
hardware.

nf.txt format (matches RT_acquisition_7.m): 5 little-endian doubles
    [AMI_dir1, AMI_dir2, SMI_14gt18, SMI_18gt14, sampleCount]
gameNF.m only reads SMI_14gt18 / SMI_18gt14 (1-based indices 3/4), so those
two are what actually drive the leaf color; AMI_dir1/AMI_dir2 are filled in
only to keep the file's shape identical to what the real system produces.

Each value follows its own bounded random walk (AR(1), clipped to
[-1, 1]) rather than independent noise per write, since real SSVEP
lateralisation drifts smoothly rather than jumping every ~100ms - this
makes gameNF.m's leaf-color modulation move the way a real NF signal would
instead of flickering randomly every write.

The real system writes every 13 samples at its 128 Hz EEG sampling rate
(~101.6ms); this script reproduces that exact cadence. Unlike the real
system, it does not reset to zero at trial start/stop - it has no access to
gameNF.m's Cedrus/paraport trigger stream - it just free-runs continuously
for as long as it's left running.
"""
import argparse
import random
import struct
import time

SAMPLE_RATE_HZ = 128.0
SAMPLES_PER_WRITE = 13
WRITE_INTERVAL_SEC = SAMPLES_PER_WRITE / SAMPLE_RATE_HZ  # ~0.1016s, matches RT_acquisition_7's cadence

AR_COEFF = 0.95   # closer to 1 = slower/smoother drift
NOISE_STD = 0.12  # per-step Gaussian noise scale, before clipping to [-1, 1]


def next_value(value):
    value = AR_COEFF * value + random.gauss(0, NOISE_STD)
    return max(-1.0, min(1.0, value))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--path', default='nf.txt',
                         help='Path to nf.txt to write (default: ./nf.txt)')
    parser.add_argument('--seed', type=int, default=None,
                         help='Random seed, for reproducible test runs')
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    ami1 = ami2 = smi1 = smi2 = 0.0
    sample_count = 0
    next_write_time = time.monotonic()

    print(f'Writing simulated NF values to {args.path} every '
          f'{WRITE_INTERVAL_SEC * 1000:.1f}ms. Ctrl+C to stop.')
    try:
        while True:
            ami1 = next_value(ami1)
            ami2 = next_value(ami2)
            smi1 = next_value(smi1)
            smi2 = next_value(smi2)
            sample_count += 1

            with open(args.path, 'wb') as f:
                f.write(struct.pack('<5d', ami1, ami2, smi1, smi2, float(sample_count)))

            next_write_time += WRITE_INTERVAL_SEC
            sleep_for = next_write_time - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)
            else:
                next_write_time = time.monotonic()  # fell behind - resync instead of spinning to catch up
    except KeyboardInterrupt:
        print('\nStopped.')


if __name__ == '__main__':
    main()
