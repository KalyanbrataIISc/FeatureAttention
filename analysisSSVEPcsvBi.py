"""Plot EEG power and spectral SNR by cue side and across all SSVEP trials."""

import csv
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.ticker import MultipleLocator
import numpy as np
from scipy import signal

# OVERT
RAW_EEG_CSV_FILE_PATH = (
    Path("logs") / "eeg_20260909_172031" / "eeg_20260909_172031_raw.csv"
)

# # COVERT
# RAW_EEG_CSV_FILE_PATH = (
#     Path("logs") / "eeg_20260909_152805" / "eeg_20260909_152805_raw.csv"
# )

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
SAVE_INDIVIDUAL_PLOTS = True
PLOT_OUTPUT_DIRECTORY = Path("analysis/results/analysisSSVEPcsvBi")
SAVED_PLOT_FORMATS = ("pdf", "png")
SAVED_PLOT_DPI = 600
VIDEO_WINDOW_SECONDS = 2.0
VIDEO_STEP_SECONDS = 0.1
VIDEO_FRAMES_PER_SECOND = 10
VIDEO_DPI = 150
CIRCULAR_TRIAL_WINDOW = 20
CIRCULAR_VIDEO_DURATION_SECONDS = 10.0
MULTITAPER_TIME_BANDWIDTH = 1.0
MULTITAPER_COUNT = 1
CIRCULAR_AUTO_EXCLUDE_BAD_TRIALS = True
CIRCULAR_BAD_TRIAL_ROBUST_Z_THRESHOLD = 2.5
# One-based chronological trial numbers, applied in addition to auto exclusions.
CIRCULAR_MANUAL_EXCLUDED_TRIALS = ()

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

# CHANNELS = {
#     # "raw9": "Cz",
#     "raw10": "Pz",
#     "raw11": "P4",
#     # "raw12": "T6",
#     # "raw13": "T5",
#     "raw14": "P3",
#     "raw15": "O2",
#     "raw16": "O1",
# }


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


def preprocess(eeg_uv: np.ndarray, apply_common_average: bool = True) -> np.ndarray:
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

    if apply_common_average:
        # Common-average reference across the eight mapped EEG electrodes.
        eeg_uv = eeg_uv - eeg_uv.mean(axis=1, keepdims=True)
    return eeg_uv


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


def sliding_window_psds(
    epochs: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """PSD of the trial-mean waveform in each onset-locked window.

    Channels remain separate until after spectral estimation: averaging their
    voltages would cancel the common-average referenced EEG.
    """
    window_samples = round(VIDEO_WINDOW_SECONDS * SAMPLING_RATE)
    step_samples = round(VIDEO_STEP_SECONDS * SAMPLING_RATE)
    if len(epochs) == 0 or epochs.shape[1] < window_samples:
        raise ValueError("At least one full video window is required")
    if step_samples < 1:
        raise ValueError("VIDEO_STEP_SECONDS must be at least one sample")

    trial_mean = epochs.mean(axis=0)
    starts = np.arange(0, len(trial_mean) - window_samples + 1, step_samples)
    spectra = []
    for start in starts:
        frequencies, power = periodogram(trial_mean[start : start + window_samples])
        spectra.append(power)
    return starts / SAMPLING_RATE, frequencies, np.stack(spectra)


def save_sliding_psd_videos(
    eeg_uv: np.ndarray, markers: np.ndarray, source: Path
) -> list[Path]:
    """Save onset-locked one-second PSD videos for left, right, and all trials."""
    starts = trial_start_rows(markers)
    stops = first_rows_of_marker_runs(markers, TRIAL_END_TRIGGER)
    pairs = pair_trial_bounds(starts, stops)
    window_samples = round(VIDEO_WINDOW_SECONDS * SAMPLING_RATE)
    pairs = [(start, stop) for start, stop in pairs if stop - start >= window_samples]
    if not pairs:
        raise ValueError("No paired trial contains a full video window")

    # A shared duration keeps the same trials in every frame, even when marker
    # intervals differ slightly between trials.
    shared_samples = min(stop - start for start, stop in pairs)
    epochs = np.stack([eeg_uv[start : start + shared_samples] for start, _ in pairs])
    trial_types = np.asarray([markers[start] for start, _ in pairs])
    print(f"Video trials: {len(pairs)}; common duration: {shared_samples / SAMPLING_RATE:.3f} s")

    conditions = (
        (trial_types == LEFT_TRIAL_START_TRIGGER, "Left trials (marker 20)", "left_trials"),
        (trial_types == RIGHT_TRIAL_START_TRIGGER, "Right trials (marker 21)", "right_trials"),
        (np.ones(len(trial_types), dtype=bool), "All trials", "all_trials"),
    )
    saved_paths = []
    for mask, title, slug in conditions:
        if not mask.any():
            print(f"Skipping {title}: no trials")
            continue
        times, frequencies, power = sliding_window_psds(epochs[mask])
        frequency_mask = (frequencies >= PLOT_RANGE_HZ[0]) & (frequencies <= PLOT_RANGE_HZ[1])
        frequencies = frequencies[frequency_mask]
        power_db = 10 * np.log10(np.maximum(power[:, frequency_mask], np.finfo(float).tiny))
        # Average channel PSDs in linear units before converting to dB.
        mean_db = 10 * np.log10(
            np.maximum(power[:, frequency_mask].mean(axis=2), np.finfo(float).tiny)
        )
        ymin = min(power_db.min(), mean_db.min())
        ymax = max(power_db.max(), mean_db.max())
        padding = max((ymax - ymin) * 0.08, 1.0)

        fig, ax = plt.subplots(figsize=(8, 5), constrained_layout=True)
        channel_lines = [
            ax.plot(frequencies, power_db[0, :, index], linewidth=1, alpha=0.7, label=label)[0]
            for index, label in enumerate(CHANNELS.values())
        ]
        mean_line, = ax.plot(frequencies, mean_db[0], color="black", linewidth=2.4, label="Channel-mean PSD")
        for target in TARGET_FREQUENCIES_HZ:
            ax.axvline(target, color="crimson", linestyle="--", alpha=0.7)
        ax.set(xlabel="Frequency (Hz)", ylabel=r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)",
               xlim=PLOT_RANGE_HZ, ylim=(ymin - padding, ymax + padding))
        ax.xaxis.set_major_locator(MultipleLocator(1.0))
        ax.grid(alpha=0.25)
        ax.legend(ncol=3, fontsize=8, loc="upper right")
        output_path = PLOT_OUTPUT_DIRECTORY / f"{source.stem}_{slug}_sliding_psd.mp4"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        writer = FFMpegWriter(fps=VIDEO_FRAMES_PER_SECOND, codec="libx264", bitrate=2500,
                              extra_args=["-pix_fmt", "yuv420p"])
        with writer.saving(fig, str(output_path), VIDEO_DPI):
            for frame, start_time in enumerate(times):
                for channel_index, line in enumerate(channel_lines):
                    line.set_ydata(power_db[frame, :, channel_index])
                mean_line.set_ydata(mean_db[frame])
                ax.set_title(
                    f"{title}: trial-mean PSD (n={mask.sum()})\n"
                    f"{start_time:.1f}–{start_time + VIDEO_WINDOW_SECONDS:.1f} s after trial onset"
                )
                writer.grab_frame()
        plt.close(fig)
        saved_paths.append(output_path)
        print(f"Saved {len(times)} frames: {output_path}")
    return saved_paths


def multitaper_psd(x: np.ndarray, axis: int = -1) -> tuple[np.ndarray, np.ndarray]:
    """Return a one-sided DPSS multitaper PSD using tapers [1 1]."""
    sample_count = x.shape[axis]
    tapers = signal.windows.dpss(
        sample_count,
        NW=MULTITAPER_TIME_BANDWIDTH,
        Kmax=MULTITAPER_COUNT,
        sym=False,
    )
    spectra = []
    for taper in tapers:
        frequencies, power = signal.periodogram(
            x,
            fs=SAMPLING_RATE,
            window=taper,
            detrend="constant",
            scaling="density",
            axis=axis,
        )
        spectra.append(power)
    return frequencies, np.mean(spectra, axis=0)


def circular_trial_window_indices(
    trial_count: int, window_size: int = CIRCULAR_TRIAL_WINDOW
) -> np.ndarray:
    """Return one wrapping trial window starting at every trial."""
    if trial_count < 1:
        raise ValueError("At least one trial is required")
    if not 1 <= window_size <= trial_count:
        raise ValueError("Circular trial window must fit within the condition")
    starts = np.arange(trial_count)[:, None]
    offsets = np.arange(window_size)[None, :]
    return (starts + offsets) % trial_count


def circular_trial_window_spectra(
    epochs: np.ndarray, method: str
) -> tuple[np.ndarray, np.ndarray]:
    """Calculate spectra for all circular trial windows using one averaging order."""
    windows = circular_trial_window_indices(len(epochs))
    spectra = []
    for indices in windows:
        trial_window = epochs[indices]
        if method == "trace_average":
            # Average channels and trials in the time domain, then estimate PSD.
            trace = trial_window.mean(axis=(0, 2))
            frequencies, power = multitaper_psd(trace)
        elif method == "psd_average":
            # Average channels within each trial, estimate each PSD, then trials.
            trial_traces = trial_window.mean(axis=2)
            frequencies, trial_power = multitaper_psd(trial_traces, axis=1)
            power = trial_power.mean(axis=0)
        else:
            raise ValueError(f"Unknown circular spectrum method: {method}")
        spectra.append(power)
    return frequencies, np.stack(spectra)


def score_circular_trial_quality(
    epochs: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """Score each trial by 5-30 Hz power of its channel-average trace."""
    trial_traces = epochs.mean(axis=2)
    frequencies, power = multitaper_psd(trial_traces, axis=1)
    frequency_mask = (
        (frequencies >= PLOT_RANGE_HZ[0])
        & (frequencies <= PLOT_RANGE_HZ[1])
    )
    broadband_db = 10 * np.log10(
        np.maximum(power[:, frequency_mask].mean(axis=1), np.finfo(float).tiny)
    )
    median = np.median(broadband_db)
    mad = np.median(np.abs(broadband_db - median))
    if mad <= np.finfo(float).eps:
        robust_z = np.zeros_like(broadband_db)
    else:
        robust_z = 0.67448975 * (broadband_db - median) / mad
    return broadband_db, robust_z


def save_circular_trial_quality_csv(
    source: Path,
    trial_types: np.ndarray,
    broadband_db: np.ndarray,
    robust_z: np.ndarray,
    auto_excluded: np.ndarray,
    manual_excluded: np.ndarray,
) -> Path:
    """Save trial-level power scores and exclusion decisions for review."""
    output_path = PLOT_OUTPUT_DIRECTORY / f"{source.stem}_circular_trial_quality.csv"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            (
                "TrialNumber",
                "Marker",
                "CueSide",
                "BroadbandPowerDb",
                "RobustZ",
                "AutoExcluded",
                "ManualExcluded",
                "Excluded",
            )
        )
        for index, marker in enumerate(trial_types):
            side = "left" if marker == LEFT_TRIAL_START_TRIGGER else "right"
            writer.writerow(
                (
                    index + 1,
                    marker,
                    side,
                    f"{broadband_db[index]:.6f}",
                    f"{robust_z[index]:.6f}",
                    int(auto_excluded[index]),
                    int(manual_excluded[index]),
                    int(auto_excluded[index] or manual_excluded[index]),
                )
            )
    return output_path


def save_circular_trial_psd_videos(
    filtered_eeg_uv: np.ndarray, markers: np.ndarray, source: Path
) -> list[Path]:
    """Save two triplets of circular-trial multitaper PSD videos."""
    starts = trial_start_rows(markers)
    stops = first_rows_of_marker_runs(markers, TRIAL_END_TRIGGER)
    pairs = pair_trial_bounds(starts, stops)
    if not pairs:
        raise ValueError("No paired trials were found for circular videos")

    shared_samples = min(stop - start for start, stop in pairs)
    epochs = np.stack(
        [filtered_eeg_uv[start : start + shared_samples] for start, _ in pairs]
    )
    trial_types = np.asarray([markers[start] for start, _ in pairs])
    trial_numbers = np.arange(1, len(epochs) + 1)
    broadband_db, robust_z = score_circular_trial_quality(epochs)
    auto_excluded = (
        robust_z > CIRCULAR_BAD_TRIAL_ROBUST_Z_THRESHOLD
        if CIRCULAR_AUTO_EXCLUDE_BAD_TRIALS
        else np.zeros(len(epochs), dtype=bool)
    )
    manual_numbers = np.asarray(CIRCULAR_MANUAL_EXCLUDED_TRIALS, dtype=int)
    if len(manual_numbers) and (
        np.any(manual_numbers < 1) or np.any(manual_numbers > len(epochs))
    ):
        raise ValueError(
            f"Manual circular trial exclusions must be between 1 and {len(epochs)}"
        )
    manual_excluded = np.isin(trial_numbers, manual_numbers)
    excluded = auto_excluded | manual_excluded
    quality_path = save_circular_trial_quality_csv(
        source,
        trial_types,
        broadband_db,
        robust_z,
        auto_excluded,
        manual_excluded,
    )
    if excluded.any():
        print("Excluded circular-video trials:")
        for index in np.flatnonzero(excluded):
            reasons = []
            if auto_excluded[index]:
                reasons.append("automatic")
            if manual_excluded[index]:
                reasons.append("manual")
            print(
                f"  trial {index + 1}: marker {trial_types[index]}, "
                f"broadband {broadband_db[index]:.2f} dB, robust z "
                f"{robust_z[index]:.2f} ({'+'.join(reasons)})"
            )
        epochs = epochs[~excluded]
        trial_types = trial_types[~excluded]
    print(f"Saved circular trial-quality scores: {quality_path}")
    conditions = (
        (trial_types == LEFT_TRIAL_START_TRIGGER, "Left trials (marker 20)", "left_trials"),
        (trial_types == RIGHT_TRIAL_START_TRIGGER, "Right trials (marker 21)", "right_trials"),
        (np.ones(len(trial_types), dtype=bool), "All trials", "all_trials"),
    )
    methods = (
        (
            "trace_average",
            "Trace average, then multitaper PSD",
            "circular_trace_average_multitaper",
        ),
        (
            "psd_average",
            "Average multitaper trial PSDs",
            "circular_psd_average_multitaper",
        ),
    )
    saved_paths = []
    for mask, condition_title, condition_slug in conditions:
        condition_epochs = epochs[mask]
        if len(condition_epochs) < CIRCULAR_TRIAL_WINDOW:
            print(
                f"Skipping {condition_title}: {len(condition_epochs)} trials cannot "
                f"fill a {CIRCULAR_TRIAL_WINDOW}-trial window"
            )
            continue
        frame_rate = len(condition_epochs) / CIRCULAR_VIDEO_DURATION_SECONDS
        for method, method_title, method_slug in methods:
            frequencies, power = circular_trial_window_spectra(
                condition_epochs, method
            )
            frequency_mask = (
                (frequencies >= PLOT_RANGE_HZ[0])
                & (frequencies <= PLOT_RANGE_HZ[1])
            )
            frequencies_to_plot = frequencies[frequency_mask]
            power_db = 10 * np.log10(
                np.maximum(power[:, frequency_mask], np.finfo(float).tiny)
            )
            ymin, ymax = power_db.min(), power_db.max()
            padding = max((ymax - ymin) * 0.08, 1.0)

            fig, ax = plt.subplots(figsize=(8, 5))
            fig.subplots_adjust(left=0.1, right=0.98, bottom=0.12, top=0.97)
            axes_position = ax.get_position().frozen()
            line, = ax.plot(frequencies_to_plot, power_db[0], color="black", linewidth=2)
            for target in TARGET_FREQUENCIES_HZ:
                ax.axvline(target, color="crimson", linestyle="--", alpha=0.7)
            ax.set(
                xlabel="Frequency (Hz)",
                ylabel=r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)",
                xlim=PLOT_RANGE_HZ,
                ylim=(ymin - padding, ymax + padding),
            )
            ax.xaxis.set_major_locator(MultipleLocator(1.0))
            ax.grid(alpha=0.25)
            output_path = (
                PLOT_OUTPUT_DIRECTORY
                / f"{source.stem}_{condition_slug}_{method_slug}.mp4"
            )
            output_path.parent.mkdir(parents=True, exist_ok=True)
            writer = FFMpegWriter(
                fps=frame_rate,
                codec="libx264",
                bitrate=5000,
                extra_args=["-pix_fmt", "yuv420p", "-g", "1"],
            )
            with writer.saving(fig, str(output_path), VIDEO_DPI):
                for frame in range(len(condition_epochs)):
                    ax.set_position(axes_position)
                    line.set_ydata(power_db[frame])
                    writer.grab_frame()
            plt.close(fig)
            saved_paths.append(output_path)
            print(
                f"Saved {len(condition_epochs)} frames at {frame_rate:g} fps: "
                f"{output_path}"
            )
    return saved_paths


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


def save_publication_plot(
    frequencies: np.ndarray,
    values: np.ndarray,
    ylabel: str,
    title: str,
    output_stem: Path,
) -> list[Path]:
    """Save one channel-mean spectrum as vector PDF and high-resolution PNG."""
    saved_paths: list[Path] = []
    publication_style = {
        "font.family": "sans-serif",
        "font.size": 11,
        "axes.labelsize": 12,
        "axes.titlesize": 13,
        "xtick.labelsize": 10,
        "ytick.labelsize": 10,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    }
    with plt.rc_context(publication_style):
        fig, ax = plt.subplots(figsize=(7.0, 4.5), constrained_layout=True)
        ax.plot(
            frequencies,
            values,
            color="black",
            linewidth=1.8,
            label="Channel mean",
        )
        for target in TARGET_FREQUENCIES_HZ:
            ax.axvline(
                target,
                color="#D55E00",
                linestyle="--",
                linewidth=1.2,
                alpha=0.9,
                label=f"{target:g} Hz",
            )
        ax.set(
            title=title,
            xlabel="Frequency (Hz)",
            ylabel=ylabel,
            xlim=PLOT_RANGE_HZ,
        )
        ax.xaxis.set_major_locator(MultipleLocator(1.0))
        ax.grid(axis="y", color="0.85", linewidth=0.7)
        ax.spines[["top", "right"]].set_visible(False)
        ax.legend(frameon=False, ncol=3, loc="best")

        output_stem.parent.mkdir(parents=True, exist_ok=True)
        for extension in SAVED_PLOT_FORMATS:
            output_path = output_stem.with_suffix(f".{extension}")
            fig.savefig(
                output_path,
                dpi=SAVED_PLOT_DPI,
                bbox_inches="tight",
                facecolor="white",
            )
            saved_paths.append(output_path)
        plt.close(fig)
    return saved_paths


def plot_spectra(
    epochs: np.ndarray, trial_types: np.ndarray, source: Path
) -> list[Path]:
    """Plot induced, normalized, and evoked spectra by side and overall."""
    frequencies, _ = periodogram(epochs[0])
    trial_psds = np.stack([periodogram(epoch)[1] for epoch in epochs])
    frequency_mask = (
        (frequencies >= PLOT_RANGE_HZ[0]) & (frequencies <= PLOT_RANGE_HZ[1])
    )
    labels = list(CHANNELS.values())
    eps = np.finfo(float).tiny
    conditions = (
        (
            trial_types == LEFT_TRIAL_START_TRIGGER,
            "Left trials (marker 20)",
            "left_trials",
        ),
        (
            trial_types == RIGHT_TRIAL_START_TRIGGER,
            "Right trials (marker 21)",
            "right_trials",
        ),
        (np.ones(len(trial_types), dtype=bool), "All trials", "all_trials"),
    )
    saved_paths: list[Path] = []

    fig, axes = plt.subplots(
        len(conditions),
        3,
        figsize=(21, 13),
        sharex=True,
        constrained_layout=True,
    )
    for row, (trial_mask, condition_title, condition_slug) in enumerate(conditions):
        condition_epochs = epochs[trial_mask]
        if not len(condition_epochs):
            for ax in axes[row]:
                ax.text(0.5, 0.5, "No clean trials", ha="center", va="center")
            continue

        condition_psds = trial_psds[trial_mask]
        average_psd = condition_psds.mean(axis=0)
        displays = (
            (
                10.0 * np.log10(np.maximum(average_psd, eps)),
                r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)",
                "Average power",
                "average_power",
            ),
            (
                spectral_snr_db(average_psd),
                "Spectral SNR (dB)",
                "Local spectral SNR",
                "spectral_snr",
            ),
        )
        for column, (display, ylabel, metric_title, metric_slug) in enumerate(
            displays
        ):
            ax = axes[row, column]
            for channel_index, label in enumerate(labels):
                ax.plot(
                    frequencies[frequency_mask],
                    display[frequency_mask, channel_index],
                    linewidth=1.0,
                    alpha=0.68,
                    label=label,
                )
            channel_mean = display.mean(axis=1)
            ax.plot(
                frequencies[frequency_mask],
                channel_mean[frequency_mask],
                color="black",
                linewidth=2.2,
                label="channel mean",
            )
            for target in TARGET_FREQUENCIES_HZ:
                ax.axvline(target, color="crimson", linestyle="--", alpha=0.7)
            ax.set_title(f"{condition_title}: {metric_title}")
            ax.set_ylabel(ylabel)
            ax.grid(alpha=0.25)
            if SAVE_INDIVIDUAL_PLOTS:
                saved_paths.extend(
                    save_publication_plot(
                        frequencies[frequency_mask],
                        channel_mean[frequency_mask],
                        ylabel,
                        f"{condition_title}: {metric_title}",
                        PLOT_OUTPUT_DIRECTORY
                        / f"{source.stem}_{condition_slug}_{metric_slug}",
                    )
                )

        # Average epochs in the time domain before spectral estimation so this
        # panel emphasizes phase-locked activity. Keep channels separate here:
        # their voltage mean is zero by construction after average referencing.
        evoked_waveform = condition_epochs.mean(axis=0)
        _, evoked_power = periodogram(evoked_waveform)
        evoked_power_db = 10.0 * np.log10(np.maximum(evoked_power, eps))
        evoked_channel_mean = evoked_power_db.mean(axis=1)
        evoked_ax = axes[row, 2]
        for channel_index, label in enumerate(labels):
            evoked_ax.plot(
                frequencies[frequency_mask],
                evoked_power_db[frequency_mask, channel_index],
                linewidth=1.0,
                alpha=0.68,
                label=label,
            )
        evoked_ax.plot(
            frequencies[frequency_mask],
            evoked_channel_mean[frequency_mask],
            color="black",
            linewidth=2.2,
            label="channel mean",
        )
        for target in TARGET_FREQUENCIES_HZ:
            evoked_ax.axvline(target, color="crimson", linestyle="--", alpha=0.7)
        evoked_ax.set_title(f"{condition_title}: Evoked power")
        evoked_ax.set_ylabel(r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)")
        evoked_ax.grid(alpha=0.25)
        if SAVE_INDIVIDUAL_PLOTS:
            saved_paths.extend(
                save_publication_plot(
                    frequencies[frequency_mask],
                    evoked_channel_mean[frequency_mask],
                    r"PSD ($\mathrm{dB\;\mu V^2/Hz}$)",
                    f"{condition_title}: Evoked power",
                    PLOT_OUTPUT_DIRECTORY
                    / f"{source.stem}_{condition_slug}_evoked_power",
                )
            )

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
    return saved_paths


def main() -> None:
    raw_eeg_uv, markers = load_raw_csv(RAW_EEG_CSV_FILE_PATH)
    filtered_eeg_uv = preprocess(raw_eeg_uv, apply_common_average=False)
    eeg_uv = filtered_eeg_uv - filtered_eeg_uv.mean(axis=1, keepdims=True)
    video_paths = save_sliding_psd_videos(eeg_uv, markers, RAW_EEG_CSV_FILE_PATH)
    circular_video_paths = save_circular_trial_psd_videos(
        filtered_eeg_uv, markers, RAW_EEG_CSV_FILE_PATH
    )
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
    saved_paths = plot_spectra(epochs, trial_types, RAW_EEG_CSV_FILE_PATH)
    if saved_paths:
        print(
            f"Saved {len(saved_paths)} publication plots to "
            f"{PLOT_OUTPUT_DIRECTORY.resolve()}"
        )
    print(f"Saved {len(video_paths)} sliding PSD videos to {PLOT_OUTPUT_DIRECTORY.resolve()}")
    print(
        f"Saved {len(circular_video_paths)} circular-trial PSD videos to "
        f"{PLOT_OUTPUT_DIRECTORY.resolve()}"
    )


if __name__ == "__main__":
    main()
