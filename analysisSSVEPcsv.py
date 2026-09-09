"""Plot phase-locked and average EEG power spectra from 5-second trials."""

from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator
import numpy as np
from scipy import signal


RAW_EEG_CSV_FILE_PATH = Path(
    r"logs\eeg_20260909_152805\eeg_20260909_152805_raw.csv"
)
SAMPLING_RATE = 250.0
TRIAL_START_TRIGGER = 20
TRIAL_END_TRIGGER = 30
EPOCH_SECONDS = 5.0

# Standard OpenBCI Cyton conversion for an ADS1299 at 4.5 V and gain 24.
MICROVOLTS_PER_COUNT = 4.5 / 24 / (2**23 - 1) * 1e6
MAINS_FREQUENCY = 50.0
BANDPASS_HZ = (1.0, 45.0)
MAX_PEAK_TO_PEAK_UV = 250.0
PLOT_RANGE_HZ = (1.0, 45.0)

# CSV channel number -> scalp label (from the acquisition montage).
CHANNELS = {
    "raw9": "Cz",
    "raw10": "Pz",
    "raw11": "P4",
    "raw12": "T6",
    "raw13": "T5",
    "raw14": "P3",
    "raw15": "O2",
    "raw16": "O1",
}


def first_rows_of_marker_runs(markers: np.ndarray, value: int) -> np.ndarray:
    """Return the first row of every consecutive run of ``value``."""
    is_value = markers == value
    return np.flatnonzero(is_value & np.r_[True, ~is_value[:-1]])


def pair_trial_bounds(starts: np.ndarray, stops: np.ndarray) -> list[tuple[int, int]]:
    """Pair each start with the first unused stop that follows it."""
    pairs: list[tuple[int, int]] = []
    stop_index = 0
    for start in starts:
        while stop_index < len(stops) and stops[stop_index] <= start:
            stop_index += 1
        if stop_index == len(stops):
            break
        pairs.append((int(start), int(stops[stop_index])))
        stop_index += 1
    return pairs


def load_raw_csv(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Load selected EEG channels and the marker column from the recorder CSV."""
    if not path.exists():
        raise FileNotFoundError(f"EEG file not found: {path.resolve()}")

    table = np.genfromtxt(path, delimiter=",", names=True, dtype=np.float64)
    missing = (set(CHANNELS) | {"marker"}) - set(table.dtype.names or ())
    if missing:
        raise ValueError(f"Missing CSV columns: {', '.join(sorted(missing))}")

    eeg_uv = np.column_stack([table[name] for name in CHANNELS])
    eeg_uv *= MICROVOLTS_PER_COUNT
    markers = table["marker"].astype(np.int64)
    return eeg_uv, markers


def preprocess(eeg_uv: np.ndarray) -> np.ndarray:
    """Apply conventional offline EEG preprocessing to continuous data."""
    if not np.isfinite(eeg_uv).all():
        raise ValueError("Selected EEG channels contain NaN or infinite values")

    # Zero-phase filtering avoids shifting the phase-locked response.
    eeg_uv = signal.detrend(eeg_uv, axis=0, type="linear")
    notch_b, notch_a = signal.iirnotch(MAINS_FREQUENCY, Q=30, fs=SAMPLING_RATE)
    eeg_uv = signal.sosfiltfilt(
        signal.tf2sos(notch_b, notch_a), eeg_uv, axis=0
    )
    band_sos = signal.butter(
        4, BANDPASS_HZ, btype="bandpass", fs=SAMPLING_RATE, output="sos"
    )
    eeg_uv = signal.sosfiltfilt(band_sos, eeg_uv, axis=0)

    # Common-average reference across the eight mapped EEG electrodes.
    return eeg_uv - eeg_uv.mean(axis=1, keepdims=True)


def make_epochs(
    eeg_uv: np.ndarray, markers: np.ndarray
) -> tuple[np.ndarray, list[tuple[int, int]]]:
    """Split every complete trial into non-overlapping, start-locked epochs.

    Recorder/trigger timing makes nominal 5-second blocks differ by a few
    samples.  Each trial is therefore divided into the nearest whole number of
    5-second blocks, using every sample from its first start-marker row up to
    (but not including) its first stop-marker row.  Blocks are then resampled
    to exactly five seconds so they can be averaged and compared on one FFT
    frequency grid.
    """
    starts = first_rows_of_marker_runs(markers, TRIAL_START_TRIGGER)
    stops = first_rows_of_marker_runs(markers, TRIAL_END_TRIGGER)
    pairs = pair_trial_bounds(starts, stops)
    epoch_samples = int(round(EPOCH_SECONDS * SAMPLING_RATE))

    epochs: list[np.ndarray] = []
    usable_pairs = []
    for start, stop in pairs:
        trial_samples = stop - start
        if trial_samples <= 0 or stop > len(eeg_uv):
            continue

        number_of_epochs = max(1, int(round(trial_samples / epoch_samples)))
        trial = eeg_uv[start:stop]
        for chunk in np.array_split(trial, number_of_epochs):
            if len(chunk) != epoch_samples:
                chunk = signal.resample(chunk, epoch_samples, axis=0)
            epochs.append(chunk)
        usable_pairs.append((start, stop))

    if not epochs:
        raise ValueError(
            "No usable samples were found between paired start/stop triggers"
        )
    return np.stack(epochs), usable_pairs


def reject_artifacts(epochs: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Reject a trial when any selected channel exceeds the PTP threshold."""
    peak_to_peak = np.ptp(epochs, axis=1)
    keep = np.all(peak_to_peak <= MAX_PEAK_TO_PEAK_UV, axis=1)
    if not keep.any():
        raise ValueError(
            "All epochs failed artifact rejection; increase MAX_PEAK_TO_PEAK_UV "
            "only after inspecting the data"
        )
    return epochs[keep], keep


def periodogram(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Return one-sided Hann-window PSD along the sample axis (axis 0)."""
    return signal.periodogram(
        x,
        fs=SAMPLING_RATE,
        window="hann",
        detrend="constant",
        scaling="density",
        axis=0,
    )


def plot_spectra(epochs: np.ndarray, source: Path) -> None:
    # Averaging the waveform first cancels non-phase-locked activity.
    frequencies, evoked_psd = periodogram(epochs.mean(axis=0))

    # PSD first, then trial averaging retains evoked and induced activity.
    trial_psds = np.stack([periodogram(epoch)[1] for epoch in epochs])
    average_psd = trial_psds.mean(axis=0)

    frequency_mask = (
        (frequencies >= PLOT_RANGE_HZ[0]) & (frequencies <= PLOT_RANGE_HZ[1])
    )
    labels = list(CHANNELS.values())
    eps = np.finfo(float).tiny

    fig, axes = plt.subplots(
        2, 1, figsize=(12, 9), sharex=True, constrained_layout=True
    )
    panels = (
        (evoked_psd, "Evoked (phase-locked) power: PSD of trial average"),
        (average_psd, "Average power: mean PSD across trials"),
    )
    for ax, (power, title) in zip(axes, panels):
        power_db = 10.0 * np.log10(np.maximum(power[frequency_mask], eps))
        for channel_index, label in enumerate(labels):
            ax.plot(
                frequencies[frequency_mask],
                power_db[:, channel_index],
                linewidth=1.0,
                alpha=0.72,
                label=label,
            )
        channel_mean_db = 10.0 * np.log10(
            np.maximum(power[frequency_mask].mean(axis=1), eps)
        )
        ax.plot(
            frequencies[frequency_mask],
            channel_mean_db,
            color="black",
            linewidth=2.2,
            label="channel mean",
        )
        ax.set_title(title)
        ax.set_ylabel(r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)")
        ax.grid(alpha=0.25)

    axes[0].legend(ncol=3, fontsize=9)
    axes[1].set_xlabel("Frequency (Hz)")
    axes[1].set_xlim(PLOT_RANGE_HZ)
    axes[1].xaxis.set_major_locator(MultipleLocator(0.5))
    axes[1].tick_params(axis="x", labelrotation=90)
    fig.suptitle(
        f"{source.name} — {len(epochs)} clean {EPOCH_SECONDS:g}-s trials",
        fontsize=13,
    )
    plt.show()


def main() -> None:
    eeg_uv, markers = load_raw_csv(RAW_EEG_CSV_FILE_PATH)
    eeg_uv = preprocess(eeg_uv)
    epochs, trial_pairs = make_epochs(eeg_uv, markers)
    epochs, keep = reject_artifacts(epochs)

    starts = first_rows_of_marker_runs(markers, TRIAL_START_TRIGGER)
    stops = first_rows_of_marker_runs(markers, TRIAL_END_TRIGGER)
    print(f"Detected marker runs: {len(starts)} starts, {len(stops)} stops")
    print(f"Paired trials used: {len(trial_pairs)}")
    print(
        f"Non-overlapping {EPOCH_SECONDS:g}-s epochs: "
        f"{len(keep)} total, {np.count_nonzero(~keep)} rejected, {len(epochs)} kept"
    )
    plot_spectra(epochs, RAW_EEG_CSV_FILE_PATH)


if __name__ == "__main__":
    main()
