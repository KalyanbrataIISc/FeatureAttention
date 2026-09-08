"""Plot EEG power and spectral SNR for left- and right-cued SSVEP trials."""

from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator
import numpy as np
from scipy import signal


RAW_EEG_CSV_FILE_PATH = Path(
    r"logs\eeg_20260908_194158\eeg_20260908_194158_raw.csv"
)
SAMPLING_RATE = 250.0
LEFT_TRIAL_START_TRIGGER = 20
RIGHT_TRIAL_START_TRIGGER = 21
TRIAL_START_TRIGGERS = (LEFT_TRIAL_START_TRIGGER, RIGHT_TRIAL_START_TRIGGER)
TRIAL_END_TRIGGER = 30
TRIAL_ANALYSIS_DELAY_SECONDS = 1.0
EPOCH_SECONDS = 8.0

# Standard OpenBCI Cyton conversion for an ADS1299 at 4.5 V and gain 24.
MICROVOLTS_PER_COUNT = 4.5 / 24 / (2**23 - 1) * 1e6
MAINS_FREQUENCY = 50.0
BANDPASS_HZ = (5.0, 45.0)
MAX_PEAK_TO_PEAK_UV = 250.0
PLOT_RANGE_HZ = (5.0, 30.0)
TARGET_FREQUENCIES_HZ = (16.0, 20.0)
SNR_GUARD_BINS = 2
SNR_NOISE_BINS = 16

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


def trial_start_rows(markers: np.ndarray) -> np.ndarray:
    """Return left (20) and right (21) trial starts in chronological order."""
    starts = [
        first_rows_of_marker_runs(markers, trigger)
        for trigger in TRIAL_START_TRIGGERS
    ]
    return np.sort(np.concatenate(starts))


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
) -> tuple[np.ndarray, np.ndarray, list[tuple[int, int]]]:
    """Extract one fixed-length sustained-response epoch from each trial.

    The first second is omitted to reduce cue/onset transients. Using an exact
    sample count rather than resampling the variable-duration marker interval
    preserves the frequencies and phases of the steady-state response.
    """
    starts = trial_start_rows(markers)
    stops = first_rows_of_marker_runs(markers, TRIAL_END_TRIGGER)
    pairs = pair_trial_bounds(starts, stops)
    delay_samples = int(round(TRIAL_ANALYSIS_DELAY_SECONDS * SAMPLING_RATE))
    epoch_samples = int(round(EPOCH_SECONDS * SAMPLING_RATE))

    epochs: list[np.ndarray] = []
    trial_types: list[int] = []
    usable_pairs: list[tuple[int, int]] = []
    for start, stop in pairs:
        epoch_start = start + delay_samples
        epoch_stop = epoch_start + epoch_samples
        if epoch_stop > stop or epoch_stop > len(eeg_uv):
            continue

        epochs.append(eeg_uv[epoch_start:epoch_stop])
        trial_types.append(int(markers[start]))
        usable_pairs.append((start, stop))

    if not epochs:
        raise ValueError(
            "No usable samples were found between paired start/stop triggers"
        )
    return np.stack(epochs), np.asarray(trial_types), usable_pairs


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


def spectral_snr_db(power: np.ndarray) -> np.ndarray:
    """Normalize each frequency bin by nearby bins, expressed in decibels."""
    snr = np.full_like(power, np.nan, dtype=float)
    for index in range(SNR_NOISE_BINS, len(power) - SNR_NOISE_BINS):
        left = power[index - SNR_NOISE_BINS : index - SNR_GUARD_BINS]
        right = power[index + SNR_GUARD_BINS + 1 : index + SNR_NOISE_BINS + 1]
        local_noise = np.concatenate((left, right), axis=0).mean(axis=0)
        snr[index] = 10.0 * np.log10(
            np.maximum(power[index], np.finfo(float).tiny)
            / np.maximum(local_noise, np.finfo(float).tiny)
        )
    return snr


def plot_spectra(
    epochs: np.ndarray, trial_types: np.ndarray, source: Path
) -> None:
    """Plot conventional PSD and locally normalized SSVEP spectra by side."""
    frequencies, _ = periodogram(epochs[0])
    trial_psds = np.stack([periodogram(epoch)[1] for epoch in epochs])
    frequency_mask = (
        (frequencies >= PLOT_RANGE_HZ[0]) & (frequencies <= PLOT_RANGE_HZ[1])
    )
    labels = list(CHANNELS.values())
    eps = np.finfo(float).tiny
    conditions = (
        (LEFT_TRIAL_START_TRIGGER, "Left trials (marker 20)"),
        (RIGHT_TRIAL_START_TRIGGER, "Right trials (marker 21)"),
    )

    fig, axes = plt.subplots(
        2, 2, figsize=(15, 9), sharex=True, constrained_layout=True
    )
    for row, (trigger, condition_title) in enumerate(conditions):
        condition_psds = trial_psds[trial_types == trigger]
        if not len(condition_psds):
            for ax in axes[row]:
                ax.text(0.5, 0.5, "No clean trials", ha="center", va="center")
            continue

        average_psd = condition_psds.mean(axis=0)
        displays = (
            (
                10.0 * np.log10(np.maximum(average_psd, eps)),
                r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)",
                "Average power",
            ),
            (
                spectral_snr_db(average_psd),
                "Spectral SNR (dB)",
                "Local spectral SNR",
            ),
        )
        for column, (display, ylabel, metric_title) in enumerate(displays):
            ax = axes[row, column]
            for channel_index, label in enumerate(labels):
                ax.plot(
                    frequencies[frequency_mask],
                    display[frequency_mask, channel_index],
                    linewidth=1.0,
                    alpha=0.68,
                    label=label,
                )
            ax.plot(
                frequencies[frequency_mask],
                display[frequency_mask].mean(axis=1),
                color="black",
                linewidth=2.2,
                label="channel mean",
            )
            for target in TARGET_FREQUENCIES_HZ:
                ax.axvline(target, color="crimson", linestyle="--", alpha=0.7)
            ax.set_title(f"{condition_title}: {metric_title}")
            ax.set_ylabel(ylabel)
            ax.grid(alpha=0.25)

    axes[0, 0].legend(ncol=3, fontsize=9)
    for ax in axes[-1]:
        ax.set_xlabel("Frequency (Hz)")
    for ax in axes.flat:
        ax.set_xlim(PLOT_RANGE_HZ)
        ax.xaxis.set_major_locator(MultipleLocator(1.0))
    fig.suptitle(
        f"{source.name} — {len(epochs)} clean {EPOCH_SECONDS:g}-s trials",
        fontsize=13,
    )
    plt.show()


def main() -> None:
    eeg_uv, markers = load_raw_csv(RAW_EEG_CSV_FILE_PATH)
    eeg_uv = preprocess(eeg_uv)
    epochs, trial_types, trial_pairs = make_epochs(eeg_uv, markers)
    epochs, keep = reject_artifacts(epochs)
    trial_types = trial_types[keep]

    starts = trial_start_rows(markers)
    stops = first_rows_of_marker_runs(markers, TRIAL_END_TRIGGER)
    print(f"Detected marker runs: {len(starts)} starts, {len(stops)} stops")
    print(f"Paired trials used: {len(trial_pairs)}")
    print(
        f"Sustained-response {EPOCH_SECONDS:g}-s epochs: "
        f"{len(keep)} total, {np.count_nonzero(~keep)} rejected, {len(epochs)} kept"
    )
    print(
        f"Clean trials by marker: left 20 = "
        f"{np.count_nonzero(trial_types == LEFT_TRIAL_START_TRIGGER)}, right 21 = "
        f"{np.count_nonzero(trial_types == RIGHT_TRIAL_START_TRIGGER)}"
    )
    plot_spectra(epochs, trial_types, RAW_EEG_CSV_FILE_PATH)


if __name__ == "__main__":
    main()
