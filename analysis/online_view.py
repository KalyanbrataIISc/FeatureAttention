#!/usr/bin/env python3
"""Interactive, memory-safe GDF playback and spectrum viewer.

The selected recording is read lazily.  If ``recording.gdf`` is selected,
numbered siblings such as ``recording_1.gdf`` and ``recording_2.gdf`` are
discovered and appended in numeric order.  Selecting one of the numbered
parts discovers the same complete set.
"""

import math
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

import mne
import numpy as np
from PyQt5.QtCore import Qt, QTimer, pyqtSignal
from PyQt5.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSlider,
    QSpinBox,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)
import pyqtgraph as pg
from scipy import fft as scipy_fft
from scipy import signal


OPENGL_PLOTS_ENABLED = (
    sys.platform == "darwin"
    and os.environ.get("QT_QPA_PLATFORM", "").lower() != "offscreen"
    and os.environ.get("GDF_VIEWER_DISABLE_OPENGL", "0") != "1"
)
pg.setConfigOptions(
    background="#0d1117",
    foreground="#c9d1d9",
    antialias=False,
    useOpenGL=OPENGL_PLOTS_ENABLED,
    segmentedLineMode="on",
)

TARGET_CHANNELS = [f"A{i}" for i in range(1, 33)] + [f"B{i}" for i in range(1, 10)]
CHANNEL_COLORS = [
    "#58a6ff", "#f78166", "#56d364", "#e3b341", "#bc8cff", "#ff7b72",
    "#3fb950", "#d29922", "#79c0ff", "#ffa657", "#7ee787", "#d2a8ff",
    "#ffa198", "#39c5cf", "#db61a2", "#a5d6ff",
]
AVERAGE_COLOR = "#ffffff"
SLIDER_STEPS = 1_000_000
DEFAULT_OUTPUT_RATE = 256
DEFAULT_HISTORY_SECONDS = 5.0
MAX_READ_SECONDS = 4.0
SIGNAL_REFRESH_SECONDS = 0.08
TRIAL_START_CODE = 20
TRIAL_STOP_CODE = 30
_AUTO_FFT_BACKEND = None
_AUTO_FFT_LOCK = threading.Lock()
_MLX_CORE = None
_MLX_IMPORT_ATTEMPTED = False


def format_time(seconds):
    """Format seconds as H:MM:SS.s or MM:SS.s."""
    seconds = max(0.0, float(seconds))
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:04.1f}"
    return f"{minutes:02d}:{secs:04.1f}"


def discover_gdf_parts(selected_path):
    """Return base.gdf, base_1.gdf, ... in recording order.

    The match is case-insensitive for both the stem and ``.gdf`` extension.
    A selected numbered part (for example ``test_2.gdf``) is mapped back to
    the same base name before sibling discovery.
    """
    selected = Path(selected_path).expanduser().resolve()
    if selected.suffix.lower() != ".gdf":
        raise ValueError("Please select a .gdf file.")
    if not selected.is_file():
        raise FileNotFoundError(f"GDF file not found: {selected}")

    numbered_match = re.fullmatch(r"(.+)_([0-9]+)", selected.stem)
    base_stem = numbered_match.group(1) if numbered_match else selected.stem
    sibling_pattern = re.compile(
        rf"^{re.escape(base_stem)}(?:_([0-9]+))?$", re.IGNORECASE
    )

    candidates = []
    for candidate in selected.parent.iterdir():
        if not candidate.is_file() or candidate.suffix.lower() != ".gdf":
            continue
        match = sibling_pattern.fullmatch(candidate.stem)
        if match is None:
            continue
        part_number = -1 if match.group(1) is None else int(match.group(1))
        candidates.append((part_number, candidate.resolve()))

    candidates.sort(key=lambda item: (item[0], item[1].name.lower()))
    paths = [path for _, path in candidates]
    return paths if paths else [selected]


def decode_status_code(value):
    """Decode plain triggers or BioSemi/GDF values stored in the high byte."""
    value = int(value)
    return ((value >> 8) & 0xFF) if value > 0xFF else value


def extract_trial_intervals(events, sfreq, first_sample=0):
    """Pair trial-start (20) and trial-stop (30) events in chronological order."""
    intervals = []
    open_start = None
    for sample, _, raw_value in np.asarray(events, dtype=np.int64):
        code = decode_status_code(raw_value)
        event_time = (int(sample) - int(first_sample)) / float(sfreq)
        if code == TRIAL_START_CODE:
            open_start = max(0.0, event_time)
        elif code == TRIAL_STOP_CODE and open_start is not None:
            if event_time >= open_start:
                intervals.append((open_start, event_time))
            open_start = None
    return np.asarray(intervals, dtype=np.float64).reshape(-1, 2)


@dataclass
class RecordingInfo:
    raw: object
    paths: list
    channel_names: list
    channel_indices: list
    native_sfreq: float
    duration: float
    trial_intervals: np.ndarray

    def close(self):
        self.raw.close()

    def is_in_trial(self, playback_time):
        if self.trial_intervals.size == 0:
            return False
        starts = self.trial_intervals[:, 0]
        interval_index = int(np.searchsorted(starts, playback_time, side="right") - 1)
        return (
            interval_index >= 0
            and playback_time < self.trial_intervals[interval_index, 1]
        )

    def read_interval(self, start_time, end_time, output_sfreq):
        """Read and resample only a requested time interval.

        Extra samples are read on both sides before polyphase resampling so
        filter-edge effects are kept outside the returned interval.
        """
        output_sfreq = float(output_sfreq)
        start_time = max(0.0, float(start_time))
        end_time = min(self.duration, float(end_time))
        first_out = int(math.ceil(start_time * output_sfreq - 1e-9))
        last_out = int(math.ceil(end_time * output_sfreq - 1e-9))
        if last_out <= first_out:
            return np.empty((len(self.channel_names), 0), dtype=np.float32)

        requested_times = np.arange(first_out, last_out, dtype=np.float64) / output_sfreq
        native_sfreq = self.native_sfreq
        padding_seconds = min(0.5, max(0.1, 64.0 / native_sfreq))
        source_start = max(
            0, int(math.floor((requested_times[0] - padding_seconds) * native_sfreq))
        )
        source_stop = min(
            self.raw.n_times,
            int(math.ceil((requested_times[-1] + padding_seconds) * native_sfreq)) + 2,
        )
        if source_stop <= source_start:
            return np.empty((len(self.channel_names), 0), dtype=np.float32)

        source = self.raw.get_data(
            picks=self.channel_indices,
            start=source_start,
            stop=source_stop,
            reject_by_annotation=None,
            verbose=False,
        )
        source *= 1e6  # MNE EEG data are stored in volts; display microvolts.

        ratio = Fraction(output_sfreq / native_sfreq).limit_denominator(10_000)
        resampled = signal.resample_poly(
            source,
            ratio.numerator,
            ratio.denominator,
            axis=1,
            padtype="line",
        )
        effective_rate = native_sfreq * ratio.numerator / ratio.denominator
        resampled_start_time = source_start / native_sfreq
        sample_indices = np.rint(
            (requested_times - resampled_start_time) * effective_rate
        ).astype(np.int64)
        sample_indices = np.clip(sample_indices, 0, resampled.shape[1] - 1)
        return np.asarray(resampled[:, sample_indices], dtype=np.float32)


def load_recording(selected_path):
    """Open all matching GDF chunks without loading their samples into RAM."""
    paths = discover_gdf_parts(selected_path)
    raw_parts = []
    try:
        for path in paths:
            raw_parts.append(mne.io.read_raw_gdf(path, preload=False, verbose=False))

        reference_names = raw_parts[0].ch_names
        reference_sfreq = float(raw_parts[0].info["sfreq"])
        for path, raw in zip(paths[1:], raw_parts[1:]):
            if raw.ch_names != reference_names:
                raise ValueError(
                    f"Channel names/order differ in {path.name}; chunks cannot be "
                    "joined safely."
                )
            if not math.isclose(
                float(raw.info["sfreq"]), reference_sfreq, rel_tol=0.0, abs_tol=1e-9
            ):
                raise ValueError(
                    f"Sampling rate differs in {path.name}; chunks cannot be "
                    "joined safely."
                )

        channel_names = [name for name in TARGET_CHANNELS if name in reference_names]
        if not channel_names:
            raise ValueError(
                "None of the expected A1-A32/B1-B9 channels were found in the GDF."
            )
        channel_indices = [reference_names.index(name) for name in channel_names]
        combined = mne.concatenate_raws(
            raw_parts, preload=False, on_mismatch="raise", verbose=False
        )
        if "STATUS" in combined.ch_names:
            events = mne.find_events(
                combined,
                stim_channel="STATUS",
                shortest_event=1,
                initial_event=True,
                verbose=False,
            )
            trial_intervals = extract_trial_intervals(
                events, reference_sfreq, combined.first_samp
            )
        else:
            trial_intervals = np.empty((0, 2), dtype=np.float64)
        duration = combined.n_times / reference_sfreq
        return RecordingInfo(
            raw=combined,
            paths=paths,
            channel_names=channel_names,
            channel_indices=channel_indices,
            native_sfreq=reference_sfreq,
            duration=duration,
            trial_intervals=trial_intervals,
        )
    except Exception:
        for raw in raw_parts:
            try:
                raw.close()
            except Exception:
                pass
        raise


class DataStore:
    """Thread-safe bounded display history."""

    def __init__(self):
        self.lock = threading.Lock()
        self.channel_names = []
        self.sfreq = float(DEFAULT_OUTPUT_RATE)
        self.max_samples = int(DEFAULT_OUTPUT_RATE * DEFAULT_HISTORY_SECONDS)
        self.data = np.empty((0, 0), dtype=np.float32)

    def configure(self, channel_names, sfreq, history_seconds):
        with self.lock:
            self.channel_names = list(channel_names)
            self.sfreq = float(sfreq)
            self.max_samples = max(2, int(round(self.sfreq * history_seconds)))
            self.data = np.empty((len(self.channel_names), 0), dtype=np.float32)

    def clear(self):
        with self.lock:
            self.data = np.empty((len(self.channel_names), 0), dtype=np.float32)

    def replace(self, samples):
        with self.lock:
            self.data = np.asarray(samples[:, -self.max_samples:], dtype=np.float32)

    def append(self, samples):
        if samples.size == 0:
            return
        with self.lock:
            if self.data.size == 0:
                combined = samples
            else:
                combined = np.concatenate((self.data, samples), axis=1)
            self.data = np.asarray(combined[:, -self.max_samples:], dtype=np.float32)

    def snapshot(self):
        with self.lock:
            return self.data.copy(), self.sfreq, list(self.channel_names)


def spectrum_settings(sfreq, duration, requested_resolution):
    """Return sample count, FFT length, bin spacing, and physical resolution."""
    window_samples = max(2, int(round(float(sfreq) * float(duration))))
    requested_nfft = max(window_samples, int(math.ceil(float(sfreq) / requested_resolution)))
    nfft = scipy_fft.next_fast_len(requested_nfft, real=True)
    return window_samples, nfft, float(sfreq) / nfft, float(sfreq) / window_samples


def _scipy_rfft(data, nfft, workers):
    return scipy_fft.rfft(
        data,
        n=nfft,
        axis=1,
        workers=max(1, int(workers)),
    )


def _metal_rfft(data, nfft):
    global _MLX_CORE, _MLX_IMPORT_ATTEMPTED
    if not _MLX_IMPORT_ATTEMPTED:
        _MLX_IMPORT_ATTEMPTED = True
        try:
            import mlx.core as mlx_module

            _MLX_CORE = mlx_module
        except ImportError:
            _MLX_CORE = None
    if _MLX_CORE is None:
        raise RuntimeError("MLX is not installed.")
    metal_input = _MLX_CORE.array(np.asarray(data, dtype=np.float32))
    coefficients = _MLX_CORE.fft.rfft(
        metal_input,
        n=nfft,
        axis=1,
        stream=_MLX_CORE.gpu,
    )
    _MLX_CORE.eval(coefficients)
    return np.asarray(coefficients)


def _automatic_rfft(data, nfft, workers):
    """Benchmark once and retain the faster synchronized FFT backend."""
    global _AUTO_FFT_BACKEND
    with _AUTO_FFT_LOCK:
        if _AUTO_FFT_BACKEND is None:
            _scipy_rfft(data, nfft, workers)  # Warm worker pool before timing.
            cpu_start = time.perf_counter()
            cpu_coefficients = _scipy_rfft(data, nfft, workers)
            cpu_ms = (time.perf_counter() - cpu_start) * 1000.0
            gpu_ms = math.inf
            try:
                _metal_rfft(data, nfft)  # Warm Metal before timing.
                gpu_start = time.perf_counter()
                _metal_rfft(data, nfft)
                gpu_ms = (time.perf_counter() - gpu_start) * 1000.0
            except Exception:
                pass
            _AUTO_FFT_BACKEND = (
                "metal" if gpu_ms < cpu_ms * 0.9 else "cpu",
                cpu_ms,
                gpu_ms,
            )
            if _AUTO_FFT_BACKEND[0] == "cpu":
                return cpu_coefficients, (
                    f"Auto → CPU ({cpu_ms:.2f} ms CPU vs "
                    f"{gpu_ms:.2f} ms GPU)"
                )

        backend, cpu_ms, gpu_ms = _AUTO_FFT_BACKEND
    if backend == "metal":
        return _metal_rfft(data, nfft), (
            f"Auto → Metal GPU ({gpu_ms:.2f} ms GPU vs {cpu_ms:.2f} ms CPU)"
        )
    return _scipy_rfft(data, nfft, workers), (
        f"Auto → CPU ({cpu_ms:.2f} ms CPU vs {gpu_ms:.2f} ms GPU)"
    )


def compute_spectra(
    selected_data,
    sfreq,
    duration,
    window_name,
    requested_resolution,
    workers,
    backend="auto",
):
    """Return frequencies, power, and phase for channels plus their mean signal."""
    if selected_data.size == 0:
        empty = np.empty((0, 0), dtype=np.float64)
        return np.empty(0), empty, empty, "No channels selected"

    window_samples, nfft, _, _ = spectrum_settings(
        sfreq, duration, requested_resolution
    )
    if selected_data.shape[1] >= window_samples:
        segment = selected_data[:, -window_samples:].astype(np.float64, copy=True)
    else:
        missing = window_samples - selected_data.shape[1]
        segment = np.pad(
            selected_data.astype(np.float64),
            ((0, 0), (missing, 0)),
            mode="constant",
        )

    average_signal = np.mean(segment, axis=0, keepdims=True)
    segment = np.vstack((segment, average_signal))
    segment = signal.detrend(segment, axis=1, type="linear")

    scipy_window_name = {
        "Hann": "hann",
        "Hamming": "hamming",
        "Blackman": "blackman",
        "Rectangular": "boxcar",
    }[window_name]
    taper = signal.get_window(scipy_window_name, window_samples, fftbins=True)
    tapered = segment * taper[np.newaxis, :]

    if backend == "metal":
        try:
            coefficients = _metal_rfft(tapered, nfft)
            backend_label = "Metal GPU (MLX)"
        except Exception as error:
            coefficients = _scipy_rfft(tapered, nfft, workers)
            backend_label = f"CPU fallback: {error}"
    elif backend == "cpu":
        coefficients = _scipy_rfft(tapered, nfft, workers)
        backend_label = f"Multicore CPU ({max(1, int(workers))} workers)"
    else:
        coefficients, backend_label = _automatic_rfft(tapered, nfft, workers)
    frequencies = scipy_fft.rfftfreq(nfft, 1.0 / sfreq)
    power = (np.abs(coefficients) ** 2) / (sfreq * np.sum(taper ** 2))
    if nfft % 2 == 0:
        power[:, 1:-1] *= 2.0
    else:
        power[:, 1:] *= 2.0
    phase = np.rad2deg(np.angle(coefficients))
    return frequencies, power, phase, backend_label


class Sidebar(QFrame):
    fileSelected = pyqtSignal(str)
    startRequested = pyqtSignal()
    playRequested = pyqtSignal()
    pauseRequested = pyqtSignal()
    seekRequested = pyqtSignal(float)
    selectionChanged = pyqtSignal()
    displayOptionsChanged = pyqtSignal()
    playbackSpeedChanged = pyqtSignal(float)
    processingSettingsChanged = pyqtSignal()

    def __init__(self):
        super().__init__()
        self.file_path = ""
        self.duration = 0.0
        self.setMinimumWidth(350)
        self.setMaximumWidth(420)
        self.setStyleSheet(
            """
            QFrame { background: #161b22; border-right: 1px solid #30363d; }
            QLabel { color: #c9d1d9; font-size: 10pt; }
            QPushButton { padding: 6px; }
            QListWidget { background: #0d1117; border: 1px solid #30363d; }
            .Header { color: #58a6ff; font-weight: bold; font-size: 11pt;
                      margin-top: 9px; border-bottom: 1px solid #30363d; }
            """
        )

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        contents = QWidget()
        self.layout = QVBoxLayout(contents)
        self.layout.setContentsMargins(14, 14, 14, 14)
        scroll.setWidget(contents)
        outer.addWidget(scroll)

        title = QLabel("GDF Playback Studio")
        title.setStyleSheet("color: white; font-size: 15pt; font-weight: 800;")
        title.setAlignment(Qt.AlignCenter)
        self.layout.addWidget(title)

        self.status_label = QLabel("● No recording loaded")
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setStyleSheet("color: #f78166; font-weight: bold;")
        self.layout.addWidget(self.status_label)

        self.trial_state_label = QLabel("TRIAL STATE UNAVAILABLE")
        self.trial_state_label.setAlignment(Qt.AlignCenter)
        self.trial_state_label.setMinimumHeight(48)
        self.layout.addWidget(self.trial_state_label)
        self.set_trial_state(False, available=False)

        self._add_header("RECORDING")
        self.file_button = QPushButton("Choose GDF recording…")
        self.file_button.clicked.connect(self._choose_file)
        self.layout.addWidget(self.file_button)
        self.file_label = QLabel("No file selected")
        self.file_label.setWordWrap(True)
        self.file_label.setStyleSheet("color: #8b949e; font-size: 9pt;")
        self.layout.addWidget(self.file_label)
        self.recording_label = QLabel("—")
        self.recording_label.setWordWrap(True)
        self.layout.addWidget(self.recording_label)

        transport_row = QHBoxLayout()
        self.start_button = QPushButton("Start / Reload")
        self.play_button = QPushButton("Play")
        self.pause_button = QPushButton("Pause")
        self.start_button.clicked.connect(self.startRequested.emit)
        self.play_button.clicked.connect(self.playRequested.emit)
        self.pause_button.clicked.connect(self.pauseRequested.emit)
        transport_row.addWidget(self.start_button)
        transport_row.addWidget(self.play_button)
        transport_row.addWidget(self.pause_button)
        self.layout.addLayout(transport_row)

        self.time_slider = QSlider(Qt.Horizontal)
        self.time_slider.setRange(0, SLIDER_STEPS)
        self.time_slider.sliderReleased.connect(self._emit_seek)
        self.time_slider.valueChanged.connect(self._preview_slider_time)
        self.layout.addWidget(self.time_slider)
        self.time_label = QLabel("00:00.0 / 00:00.0")
        self.time_label.setAlignment(Qt.AlignCenter)
        self.layout.addWidget(self.time_label)

        transport_form = QFormLayout()
        self.speed_combo = QComboBox()
        for speed in (0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0):
            self.speed_combo.addItem(f"{speed:g}×", speed)
        self.speed_combo.setCurrentIndex(2)
        self.speed_combo.currentIndexChanged.connect(
            lambda: self.playbackSpeedChanged.emit(self.playback_speed())
        )
        transport_form.addRow("Playback speed:", self.speed_combo)
        self.layout.addLayout(transport_form)

        self._add_header("CHANNELS")
        channel_hint = QLabel("Shift-click for ranges; Command-click to add/remove channels.")
        channel_hint.setWordWrap(True)
        channel_hint.setStyleSheet("color: #8b949e; font-size: 9pt;")
        self.layout.addWidget(channel_hint)
        self.channel_list = QListWidget()
        self.channel_list.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.channel_list.setMinimumHeight(190)
        self.channel_list.itemSelectionChanged.connect(self.selectionChanged.emit)
        self.layout.addWidget(self.channel_list)
        channel_buttons = QHBoxLayout()
        for label, callback in (
            ("All", self.select_all_channels),
            ("A1–A32", lambda: self.select_channel_prefix("A")),
            ("B1–B9", lambda: self.select_channel_prefix("B")),
            ("Clear", self.channel_list.clearSelection),
        ):
            button = QPushButton(label)
            button.clicked.connect(callback)
            channel_buttons.addWidget(button)
        self.layout.addLayout(channel_buttons)
        self.average_only_checkbox = QCheckBox(
            "Only show the selected-channel average"
        )
        self.average_only_checkbox.toggled.connect(
            lambda _checked: self.displayOptionsChanged.emit()
        )
        self.layout.addWidget(self.average_only_checkbox)

        self._add_header("DISPLAY & FFT")
        settings_form = QFormLayout()
        self.output_rate_spin = QSpinBox()
        self.output_rate_spin.setRange(32, 2048)
        self.output_rate_spin.setSingleStep(32)
        self.output_rate_spin.setValue(DEFAULT_OUTPUT_RATE)
        self.output_rate_spin.setSuffix(" Hz")
        self.output_rate_spin.editingFinished.connect(
            self.processingSettingsChanged.emit
        )
        settings_form.addRow("Display sampling:", self.output_rate_spin)

        self.history_spin = QDoubleSpinBox()
        self.history_spin.setRange(1.0, 60.0)
        self.history_spin.setValue(DEFAULT_HISTORY_SECONDS)
        self.history_spin.setSuffix(" s")
        self.history_spin.editingFinished.connect(
            self.processingSettingsChanged.emit
        )
        settings_form.addRow("Signal history:", self.history_spin)

        self.fft_duration_spin = QDoubleSpinBox()
        self.fft_duration_spin.setRange(0.25, 60.0)
        self.fft_duration_spin.setDecimals(2)
        self.fft_duration_spin.setValue(2.0)
        self.fft_duration_spin.setSuffix(" s")
        self.fft_duration_spin.valueChanged.connect(self._update_resolution_label)
        settings_form.addRow("FFT duration:", self.fft_duration_spin)

        self.window_combo = QComboBox()
        self.window_combo.addItems(("Hann", "Hamming", "Blackman", "Rectangular"))
        settings_form.addRow("FFT window:", self.window_combo)

        self.fft_step_spin = QDoubleSpinBox()
        self.fft_step_spin.setRange(0.04, 10.0)
        self.fft_step_spin.setDecimals(2)
        self.fft_step_spin.setValue(0.10)
        self.fft_step_spin.setSuffix(" s")
        self.fft_step_spin.setToolTip("How often power and phase plots are refreshed.")
        settings_form.addRow("Sliding step:", self.fft_step_spin)

        self.resolution_spin = QDoubleSpinBox()
        self.resolution_spin.setRange(0.01, 20.0)
        self.resolution_spin.setDecimals(3)
        self.resolution_spin.setValue(0.5)
        self.resolution_spin.setSuffix(" Hz")
        self.resolution_spin.valueChanged.connect(self._update_resolution_label)
        settings_form.addRow("FFT bin target:", self.resolution_spin)

        self.frequency_auto_x_checkbox = QCheckBox("Auto")
        self.frequency_auto_x_checkbox.setChecked(False)
        settings_form.addRow("Frequency X scale:", self.frequency_auto_x_checkbox)

        self.frequency_min_spin = QDoubleSpinBox()
        self.frequency_min_spin.setRange(0.0, 1023.0)
        self.frequency_min_spin.setValue(1.0)
        self.frequency_min_spin.setSuffix(" Hz")
        settings_form.addRow("Frequency min:", self.frequency_min_spin)

        self.frequency_max_spin = QDoubleSpinBox()
        self.frequency_max_spin.setRange(1.0, 1024.0)
        self.frequency_max_spin.setValue(45.0)
        self.frequency_max_spin.setSuffix(" Hz")
        settings_form.addRow("Frequency max:", self.frequency_max_spin)
        self.frequency_auto_x_checkbox.toggled.connect(
            lambda checked: (
                self.frequency_min_spin.setEnabled(not checked),
                self.frequency_max_spin.setEnabled(not checked),
            )
        )

        self.power_auto_y_checkbox = QCheckBox("Auto")
        self.power_auto_y_checkbox.setChecked(True)
        settings_form.addRow("Power Y scale:", self.power_auto_y_checkbox)

        self.power_y_min_spin = QDoubleSpinBox()
        self.power_y_min_spin.setRange(0.0, 1e12)
        self.power_y_min_spin.setDecimals(4)
        self.power_y_min_spin.setValue(0.0)
        self.power_y_min_spin.setEnabled(False)
        settings_form.addRow("Power Y min:", self.power_y_min_spin)

        self.power_y_max_spin = QDoubleSpinBox()
        self.power_y_max_spin.setRange(0.0001, 1e12)
        self.power_y_max_spin.setDecimals(4)
        self.power_y_max_spin.setValue(100.0)
        self.power_y_max_spin.setEnabled(False)
        settings_form.addRow("Power Y max:", self.power_y_max_spin)
        self.power_auto_y_checkbox.toggled.connect(
            lambda checked: (
                self.power_y_min_spin.setEnabled(not checked),
                self.power_y_max_spin.setEnabled(not checked),
            )
        )

        self.phase_auto_y_checkbox = QCheckBox("Auto")
        self.phase_auto_y_checkbox.setChecked(False)
        settings_form.addRow("Phase Y scale:", self.phase_auto_y_checkbox)

        self.phase_y_min_spin = QDoubleSpinBox()
        self.phase_y_min_spin.setRange(-3600.0, 3600.0)
        self.phase_y_min_spin.setValue(-180.0)
        settings_form.addRow("Phase Y min:", self.phase_y_min_spin)

        self.phase_y_max_spin = QDoubleSpinBox()
        self.phase_y_max_spin.setRange(-3600.0, 3600.0)
        self.phase_y_max_spin.setValue(180.0)
        settings_form.addRow("Phase Y max:", self.phase_y_max_spin)
        self.phase_auto_y_checkbox.toggled.connect(
            lambda checked: (
                self.phase_y_min_spin.setEnabled(not checked),
                self.phase_y_max_spin.setEnabled(not checked),
            )
        )

        self.backend_combo = QComboBox()
        self.backend_combo.addItem("Auto (benchmark)", "auto")
        self.backend_combo.addItem("Metal GPU (MLX)", "metal")
        self.backend_combo.addItem("Multicore CPU (SciPy)", "cpu")
        self.backend_combo.currentIndexChanged.connect(
            lambda _index: self.displayOptionsChanged.emit()
        )
        settings_form.addRow("FFT backend:", self.backend_combo)

        self.worker_spin = QSpinBox()
        safe_workers = max(1, min(4, (os.cpu_count() or 2) // 2))
        self.worker_spin.setRange(1, max(1, os.cpu_count() or 1))
        self.worker_spin.setValue(safe_workers)
        self.worker_spin.setToolTip(
            "Bounded SciPy FFT worker count. Four is a conservative M1 Pro default."
        )
        settings_form.addRow("FFT CPU workers:", self.worker_spin)
        self.layout.addLayout(settings_form)

        self.backend_status_label = QLabel(
            f"Plots: {'OpenGL GPU' if OPENGL_PLOTS_ENABLED else 'software'} · "
            "FFT: waiting"
        )
        self.backend_status_label.setWordWrap(True)
        self.backend_status_label.setStyleSheet("color: #79c0ff; font-size: 9pt;")
        self.layout.addWidget(self.backend_status_label)

        self.resolution_label = QLabel()
        self.resolution_label.setWordWrap(True)
        self.resolution_label.setStyleSheet("color: #8b949e; font-size: 9pt;")
        self.layout.addWidget(self.resolution_label)
        self._update_resolution_label()
        self.layout.addStretch()

    def _add_header(self, text):
        label = QLabel(text)
        label.setProperty("class", "Header")
        self.layout.addWidget(label)

    def _choose_file(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Choose GDF recording", "", "GDF files (*.gdf *.GDF)"
        )
        if path:
            self.file_path = path
            self.file_label.setText(path)
            self.fileSelected.emit(path)

    def _emit_seek(self):
        fraction = self.time_slider.value() / SLIDER_STEPS
        self.seekRequested.emit(fraction * self.duration)

    def _preview_slider_time(self, value):
        if self.time_slider.isSliderDown():
            preview = self.duration * value / SLIDER_STEPS
            self.time_label.setText(
                f"{format_time(preview)} / {format_time(self.duration)}"
            )

    def _update_resolution_label(self):
        window_samples, nfft, bin_spacing, physical = spectrum_settings(
            self.output_rate_spin.value(),
            self.fft_duration_spin.value(),
            self.resolution_spin.value(),
        )
        self.resolution_label.setText(
            f"{window_samples} samples/window · {nfft}-point FFT · "
            f"{bin_spacing:.3f} Hz bins · {physical:.3f} Hz physical resolution. "
            "Finer bins use zero-padding; duration determines true resolution."
        )

    def set_busy(self, busy):
        self.start_button.setEnabled(not busy)
        self.file_button.setEnabled(not busy)
        self.play_button.setEnabled(not busy)
        self.pause_button.setEnabled(not busy)
        self.time_slider.setEnabled(not busy)

    def set_status(self, text, color):
        self.status_label.setText(f"● {text}")
        self.status_label.setStyleSheet(f"color: {color}; font-weight: bold;")

    def set_backend_status(self, fft_backend):
        plot_backend = "OpenGL GPU" if OPENGL_PLOTS_ENABLED else "software"
        self.backend_status_label.setText(
            f"Plots: {plot_backend} · FFT: {fft_backend}"
        )

    def set_trial_state(self, in_trial, available=True):
        if not available:
            text = "TRIAL STATE UNAVAILABLE"
            background = "#30363d"
            foreground = "#c9d1d9"
        elif in_trial:
            text = "● TRIAL ACTIVE"
            background = "#238636"
            foreground = "#ffffff"
        else:
            text = "● ITI"
            background = "#da3633"
            foreground = "#ffffff"
        self.trial_state_label.setText(text)
        self.trial_state_label.setStyleSheet(
            f"background: {background}; color: {foreground}; font-size: 12pt; "
            "font-weight: 800; border: 1px solid #6e7681; border-radius: 6px;"
        )

    def set_recording(self, recording):
        self.duration = recording.duration
        self.recording_label.setText(
            f"{len(recording.paths)} file(s) · {len(recording.channel_names)} channels · "
            f"{recording.native_sfreq:g} Hz native · {format_time(recording.duration)} · "
            f"{len(recording.trial_intervals)} trial(s)"
        )
        self.channel_list.blockSignals(True)
        self.channel_list.clear()
        for index, name in enumerate(recording.channel_names):
            item = QListWidgetItem(name)
            item.setForeground(pg.mkColor(CHANNEL_COLORS[index % len(CHANNEL_COLORS)]))
            self.channel_list.addItem(item)
            if index < 4:
                item.setSelected(True)
        self.channel_list.blockSignals(False)
        self.selectionChanged.emit()

    def set_time(self, current_time):
        if not self.time_slider.isSliderDown():
            fraction = 0.0 if self.duration <= 0 else current_time / self.duration
            self.time_slider.blockSignals(True)
            self.time_slider.setValue(
                int(round(np.clip(fraction, 0.0, 1.0) * SLIDER_STEPS))
            )
            self.time_slider.blockSignals(False)
            self.time_label.setText(
                f"{format_time(current_time)} / {format_time(self.duration)}"
            )

    def selected_indices(self):
        return sorted(self.channel_list.row(item) for item in self.channel_list.selectedItems())

    def select_all_channels(self):
        self.channel_list.selectAll()

    def select_channel_prefix(self, prefix):
        self.channel_list.clearSelection()
        for row in range(self.channel_list.count()):
            item = self.channel_list.item(row)
            if item.text().startswith(prefix):
                item.setSelected(True)

    def playback_speed(self):
        return float(self.speed_combo.currentData())

    def output_rate(self):
        return float(self.output_rate_spin.value())

    def history_seconds(self):
        return float(self.history_spin.value())

    def average_only(self):
        return self.average_only_checkbox.isChecked()

    def fft_settings(self):
        return {
            "duration": float(self.fft_duration_spin.value()),
            "window": self.window_combo.currentText(),
            "step": float(self.fft_step_spin.value()),
            "resolution": float(self.resolution_spin.value()),
            "frequency_auto_x": self.frequency_auto_x_checkbox.isChecked(),
            "frequency_min": float(self.frequency_min_spin.value()),
            "frequency_max": float(self.frequency_max_spin.value()),
            "power_auto_y": self.power_auto_y_checkbox.isChecked(),
            "power_y_min": float(self.power_y_min_spin.value()),
            "power_y_max": float(self.power_y_max_spin.value()),
            "phase_auto_y": self.phase_auto_y_checkbox.isChecked(),
            "phase_y_min": float(self.phase_y_min_spin.value()),
            "phase_y_max": float(self.phase_y_max_spin.value()),
            "average_only": self.average_only(),
            "backend": self.backend_combo.currentData(),
            "workers": int(self.worker_spin.value()),
        }


class SignalTab(QWidget):
    def __init__(self):
        super().__init__()
        self.channel_names = []
        self.plot_signature = None
        self.average_plot = None
        self.average_curve = None
        self.channel_plots = {}
        self.channel_curves = {}
        layout = QVBoxLayout(self)
        controls = QHBoxLayout()
        self.remove_dc = QCheckBox("Remove DC offset")
        self.remove_dc.setChecked(True)
        self.autoscale = QCheckBox("Autoscale Y")
        self.autoscale.setChecked(True)
        self.fixed_range = QDoubleSpinBox()
        self.fixed_range.setRange(1.0, 100_000.0)
        self.fixed_range.setValue(200.0)
        self.fixed_range.setSuffix(" µV")
        self.fixed_range.setEnabled(False)
        self.autoscale.toggled.connect(lambda checked: self.fixed_range.setEnabled(not checked))
        controls.addWidget(self.remove_dc)
        controls.addWidget(self.autoscale)
        controls.addWidget(QLabel("Fixed total Y range:"))
        controls.addWidget(self.fixed_range)
        controls.addStretch()
        layout.addLayout(controls)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.graphics = pg.GraphicsLayoutWidget()
        self.scroll.setWidget(self.graphics)
        layout.addWidget(self.scroll)

    def set_channels(self, channel_names):
        self.channel_names = list(channel_names)
        self.plot_signature = None

    def _configure_plot(self, plot, title):
        plot.setTitle(title)
        plot.showGrid(x=True, y=True, alpha=0.20)
        plot.setLabel("left", "µV")
        plot.setClipToView(True)
        plot.setDownsampling(auto=True, mode="peak")
        plot.setMenuEnabled(False)
        plot.hideButtons()
        plot.setMinimumHeight(145)

    def _rebuild_plots(self, selected_indices, average_only):
        signature = (tuple(self.channel_names), tuple(selected_indices), average_only)
        if signature == self.plot_signature:
            return
        self.plot_signature = signature
        self.graphics.clear()
        self.channel_plots = {}
        self.channel_curves = {}

        self.average_plot = self.graphics.addPlot(row=0, col=0)
        self._configure_plot(self.average_plot, "Average of selected channels")
        self.average_curve = self.average_plot.plot(
            pen=pg.mkPen(AVERAGE_COLOR, width=2)
        )

        if not average_only:
            for row, channel_index in enumerate(selected_indices, start=1):
                channel_name = self.channel_names[channel_index]
                channel_plot = self.graphics.addPlot(row=row, col=0)
                self._configure_plot(channel_plot, channel_name)
                channel_plot.setXLink(self.average_plot)
                curve = channel_plot.plot(
                    pen=pg.mkPen(
                        CHANNEL_COLORS[channel_index % len(CHANNEL_COLORS)],
                        width=1,
                    )
                )
                self.channel_plots[channel_index] = channel_plot
                self.channel_curves[channel_index] = curve

        plot_count = 1 if average_only else len(selected_indices) + 1
        self.graphics.setMinimumHeight(max(220, plot_count * 165))
        bottom_plot = (
            self.average_plot
            if average_only or not selected_indices
            else self.channel_plots[selected_indices[-1]]
        )
        bottom_plot.setLabel("bottom", "Time relative to playback head", "s")

    def refresh(self, data, sfreq, selected_indices, average_only=False):
        selected_indices = [
            index for index in selected_indices if index < len(self.channel_names)
        ]
        self._rebuild_plots(selected_indices, average_only)
        if data.size == 0:
            if self.average_curve is not None:
                self.average_curve.setData([], [])
            for curve in self.channel_curves.values():
                curve.setData([], [])
            return

        time_axis = (np.arange(data.shape[1]) - data.shape[1] + 1) / sfreq
        selected_data = []
        processed_channels = {}
        for index in selected_indices:
            channel = data[index].astype(np.float64, copy=False)
            if self.remove_dc.isChecked():
                channel = channel - np.mean(channel)
            processed_channels[index] = channel
            selected_data.append(channel)

        if selected_data:
            self.average_curve.setData(
                time_axis,
                np.mean(selected_data, axis=0),
                skipFiniteCheck=True,
            )
        else:
            self.average_curve.setData([], [])

        for index, curve in self.channel_curves.items():
            curve.setData(
                time_axis,
                processed_channels[index],
                skipFiniteCheck=True,
            )

        plots = [self.average_plot, *self.channel_plots.values()]
        if self.autoscale.isChecked():
            for plot in plots:
                plot.enableAutoRange(axis=pg.ViewBox.YAxis, enable=True)
        else:
            half_range = self.fixed_range.value() / 2.0
            for plot in plots:
                plot.setYRange(-half_range, half_range, padding=0)


class SpectrumTab(QWidget):
    def __init__(self, phase=False):
        super().__init__()
        self.phase = phase
        self.channel_names = []
        self.curves = []
        layout = QVBoxLayout(self)
        title = "FFT phase spectrum" if phase else "FFT power spectral density"
        self.plot = pg.PlotWidget(title=title)
        self.plot.showGrid(x=True, y=True, alpha=0.25)
        self.plot.setLabel("bottom", "Frequency", "Hz")
        self.plot.setClipToView(True)
        self.plot.setDownsampling(auto=True, mode="peak")
        if phase:
            self.plot.setLabel("left", "Phase", "degrees")
            self.plot.setYRange(-180.0, 180.0, padding=0.02)
        else:
            self.plot.setLabel("left", "Power spectral density", "µV²/Hz")
        self.plot.addLegend(offset=(10, 10))
        self.average_curve = self.plot.plot(
            pen=pg.mkPen(AVERAGE_COLOR, width=2), name="Selected-channel average"
        )
        layout.addWidget(self.plot)

    def set_channels(self, channel_names):
        for curve in self.curves:
            self.plot.removeItem(curve)
        self.channel_names = list(channel_names)
        self.curves = [
            self.plot.plot(pen=pg.mkPen(CHANNEL_COLORS[i % len(CHANNEL_COLORS)], width=1))
            for i in range(len(channel_names))
        ]

    def display_spectra(
        self,
        frequencies,
        power,
        phase,
        selected_indices,
        settings,
    ):
        if frequencies.size == 0 or not selected_indices:
            self.average_curve.setData([], [])
            for curve in self.curves:
                curve.setData([], [])
            return

        values = phase if self.phase else power
        nyquist = frequencies[-1]
        if settings["frequency_auto_x"]:
            minimum = 0.0
            maximum = nyquist
        else:
            minimum = min(
                settings["frequency_min"], settings["frequency_max"] - 0.01
            )
            maximum = max(settings["frequency_max"], minimum + 0.01)
            maximum = min(maximum, nyquist)
            minimum = min(minimum, max(0.0, maximum - 0.01))
        mask = (frequencies >= minimum) & (frequencies <= maximum)
        self.plot.setXRange(minimum, maximum, padding=0)

        average_only = settings["average_only"]
        selected_row_by_channel = {
            channel_index: row for row, channel_index in enumerate(selected_indices)
        }
        for channel_index, curve in enumerate(self.curves):
            row = selected_row_by_channel.get(channel_index)
            if row is None or average_only:
                curve.setData([], [])
            else:
                curve.setData(
                    frequencies[mask],
                    values[row, mask],
                    skipFiniteCheck=True,
                )
        self.average_curve.setData(
            frequencies[mask],
            values[-1, mask],
            skipFiniteCheck=True,
        )

        visible_values = (
            values[-1:, mask] if average_only else values[:, mask]
        )
        if self.phase:
            auto_y = settings["phase_auto_y"]
            fixed_min = settings["phase_y_min"]
            fixed_max = settings["phase_y_max"]
        else:
            auto_y = settings["power_auto_y"]
            fixed_min = settings["power_y_min"]
            fixed_max = settings["power_y_max"]

        if auto_y and visible_values.size and np.any(np.isfinite(visible_values)):
            visible_min = float(np.nanmin(visible_values))
            visible_max = float(np.nanmax(visible_values))
            if not self.phase:
                visible_min = min(0.0, visible_min)
            padding = max((visible_max - visible_min) * 0.08, 1e-9)
            self.plot.setYRange(
                visible_min - (padding if self.phase else 0.0),
                visible_max + padding,
                padding=0,
            )
        elif not auto_y:
            lower = min(fixed_min, fixed_max - 1e-9)
            upper = max(fixed_max, lower + 1e-9)
            self.plot.setYRange(lower, upper, padding=0)


class GdfViewer(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("GDF Playback Studio")
        self.resize(1500, 950)
        self.setStyleSheet(
            """
            QMainWindow, QWidget { background: #0d1117; color: #c9d1d9;
                                  font-family: Arial, sans-serif; }
            QTabWidget::pane { border: 1px solid #30363d; }
            QTabBar::tab { background: #161b22; color: #8b949e;
                           padding: 12px 22px; border: 1px solid #30363d; }
            QTabBar::tab:selected { background: #1f2937; color: white;
                                    border-bottom: 3px solid #58a6ff; }
            """
        )

        self.recording = None
        self.store = DataStore()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="gdf-io")
        self.fft_executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="spectrum"
        )
        self.job = None
        self.job_kind = None
        self.job_end_time = 0.0
        self.current_time = 0.0
        self.playing = False
        self.play_anchor_wall = time.monotonic()
        self.play_anchor_time = 0.0
        self.resume_after_seek = False
        self.pending_seek = None
        self.pending_load_path = None
        self.last_fft_refresh = 0.0
        self.last_signal_refresh = 0.0
        self.fft_job = None
        self.fft_job_payload = None
        self.fft_generation = 0

        central = QWidget()
        self.setCentralWidget(central)
        root_layout = QHBoxLayout(central)
        root_layout.setContentsMargins(0, 0, 0, 0)

        self.sidebar = Sidebar()
        root_layout.addWidget(self.sidebar)

        self.tabs = QTabWidget()
        self.signal_tab = SignalTab()
        self.power_tab = SpectrumTab(phase=False)
        self.phase_tab = SpectrumTab(phase=True)
        self.tabs.addTab(self.signal_tab, "Live signals")
        self.tabs.addTab(self.power_tab, "FFT power")
        self.tabs.addTab(self.phase_tab, "FFT phase")
        root_layout.addWidget(self.tabs, stretch=1)

        self.sidebar.startRequested.connect(self.start_recording)
        self.sidebar.playRequested.connect(self.play)
        self.sidebar.pauseRequested.connect(self.pause)
        self.sidebar.seekRequested.connect(self.seek)
        self.sidebar.playbackSpeedChanged.connect(self._speed_changed)
        self.sidebar.processingSettingsChanged.connect(self._processing_changed)
        self.sidebar.selectionChanged.connect(self._display_options_changed)
        self.sidebar.displayOptionsChanged.connect(self._display_options_changed)
        self.tabs.currentChanged.connect(self._display_options_changed)

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._tick)
        self.timer.start(40)

    def start_recording(self):
        if not self.sidebar.file_path:
            self.sidebar._choose_file()
            if not self.sidebar.file_path:
                return
        self.pause()
        self.pending_seek = None
        self.sidebar.set_busy(True)
        self.sidebar.set_trial_state(False, available=False)
        if self.job is not None:
            self.pending_load_path = self.sidebar.file_path
            self.sidebar.set_status("Finishing active read before reload…", "#e3b341")
            return
        self._begin_load(self.sidebar.file_path)

    def _begin_load(self, path):
        self.pending_load_path = None
        self.sidebar.set_status("Reading headers and trigger timeline…", "#e3b341")
        self.job_kind = "load"
        self.job = self.executor.submit(load_recording, path)

    def _finish_load(self, recording):
        old_recording = self.recording
        self.recording = recording
        self.fft_generation += 1
        self.pending_seek = None
        self.resume_after_seek = False
        if old_recording is not None:
            old_recording.close()

        self.current_time = 0.0
        self.store.configure(
            recording.channel_names,
            self.sidebar.output_rate(),
            self.sidebar.history_seconds(),
        )
        self.signal_tab.set_channels(recording.channel_names)
        self.power_tab.set_channels(recording.channel_names)
        self.phase_tab.set_channels(recording.channel_names)
        self.sidebar.set_recording(recording)
        self.sidebar.set_busy(False)
        self.sidebar.set_time(0.0)
        self._update_trial_state()
        self.sidebar.set_status(
            f"Ready · joined {len(recording.paths)} file(s)", "#56d364"
        )
        self.play()

    def play(self):
        if self.recording is None:
            self.start_recording()
            return
        if self.current_time >= self.recording.duration:
            self.seek(0.0, resume=True)
            return
        self.playing = True
        self.play_anchor_wall = time.monotonic()
        self.play_anchor_time = self.current_time
        self.sidebar.set_status("Playing", "#56d364")

    def pause(self):
        self.playing = False
        self.resume_after_seek = False
        if self.pending_seek is not None:
            requested_time, _ = self.pending_seek
            self.pending_seek = (requested_time, False)
        if self.recording is not None:
            self.sidebar.set_status("Paused", "#e3b341")

    def seek(self, requested_time, resume=None):
        if self.recording is None:
            return
        was_playing = self.playing if resume is None else bool(resume)
        self.pause()
        requested_time = float(np.clip(requested_time, 0.0, self.recording.duration))
        self.current_time = requested_time
        self.sidebar.set_time(self.current_time)
        self._update_trial_state()
        self.store.clear()
        self.pending_seek = (requested_time, was_playing)
        if self.job is None:
            self._start_pending_seek()

    def _start_pending_seek(self):
        if self.recording is None or self.job is not None or self.pending_seek is None:
            return
        requested_time, should_resume = self.pending_seek
        self.pending_seek = None
        self.resume_after_seek = should_resume
        history_start = max(0.0, requested_time - self.sidebar.history_seconds())
        if requested_time > history_start:
            self._submit_read(history_start, requested_time, "seek")
        elif self.resume_after_seek:
            self.resume_after_seek = False
            self.play()

    def _submit_read(self, start_time, end_time, kind):
        if self.recording is None or self.job is not None:
            return
        output_rate = self.sidebar.output_rate()
        self.job_kind = kind
        self.job_end_time = end_time
        self.job = self.executor.submit(
            self.recording.read_interval, start_time, end_time, output_rate
        )

    def _finish_read(self, samples, kind, end_time):
        if kind == "seek":
            self.store.replace(samples)
            if self.resume_after_seek:
                self.resume_after_seek = False
                self.play()
        else:
            self.store.append(samples)
            self.current_time = end_time
            self.sidebar.set_time(self.current_time)
            self._update_trial_state()
            if self.current_time >= self.recording.duration:
                self.pause()
                self.sidebar.set_status("Finished", "#79c0ff")

    def _speed_changed(self, _speed):
        if self.playing:
            self.play_anchor_wall = time.monotonic()
            self.play_anchor_time = self.current_time

    def _processing_changed(self):
        self.sidebar._update_resolution_label()
        self._display_options_changed()
        if self.recording is None:
            return
        was_playing = self.playing
        self.pause()
        self.store.configure(
            self.recording.channel_names,
            self.sidebar.output_rate(),
            self.sidebar.history_seconds(),
        )
        self.seek(self.current_time, resume=was_playing)

    def _display_options_changed(self, *_args):
        self.fft_generation += 1
        self.last_fft_refresh = 0.0
        self.last_signal_refresh = 0.0
        self.signal_tab.plot_signature = None

    def _poll_job(self):
        if self.job is None or not self.job.done():
            return
        job = self.job
        kind = self.job_kind
        end_time = self.job_end_time
        self.job = None
        self.job_kind = None
        try:
            result = job.result()
            if self.pending_load_path is not None and kind != "load":
                pending_path = self.pending_load_path
                self._begin_load(pending_path)
            elif kind == "load":
                self._finish_load(result)
            elif self.pending_seek is not None:
                self._start_pending_seek()
            else:
                self._finish_read(result, kind, end_time)
        except Exception as error:
            self.playing = False
            self.sidebar.set_busy(False)
            self.sidebar.set_status("Error", "#f78166")
            QMessageBox.critical(self, "GDF viewer error", str(error))

    def _schedule_playback_read(self):
        if not self.playing or self.recording is None or self.job is not None:
            return
        elapsed = time.monotonic() - self.play_anchor_wall
        desired_time = self.play_anchor_time + elapsed * self.sidebar.playback_speed()
        desired_time = min(desired_time, self.recording.duration)
        if desired_time <= self.current_time + 0.5 / self.sidebar.output_rate():
            return
        read_end = min(
            desired_time,
            self.current_time + MAX_READ_SECONDS,
            self.recording.duration,
        )
        self._submit_read(self.current_time, read_end, "playback")

    def _poll_fft_job(self):
        if self.fft_job is None or not self.fft_job.done():
            return
        job = self.fft_job
        generation, selected, settings = self.fft_job_payload
        self.fft_job = None
        self.fft_job_payload = None
        try:
            frequencies, power, phase, backend_label = job.result()
        except Exception as error:
            self.sidebar.set_backend_status(f"FFT error: {error}")
            return
        if generation != self.fft_generation:
            return
        self.sidebar.set_backend_status(backend_label)
        self.power_tab.display_spectra(
            frequencies, power, phase, selected, settings
        )
        self.phase_tab.display_spectra(
            frequencies, power, phase, selected, settings
        )

    def _schedule_fft(self):
        if self.fft_job is not None:
            return
        settings = self.sidebar.fft_settings()
        now = time.monotonic()
        if now - self.last_fft_refresh < settings["step"]:
            return
        data, sfreq, _ = self.store.snapshot()
        selected = [
            index
            for index in self.sidebar.selected_indices()
            if index < data.shape[0]
        ]
        if data.size == 0 or not selected:
            empty = np.empty((0, 0), dtype=np.float64)
            self.power_tab.display_spectra(
                np.empty(0), empty, empty, selected, settings
            )
            self.phase_tab.display_spectra(
                np.empty(0), empty, empty, selected, settings
            )
            return
        self.last_fft_refresh = now
        self.fft_job_payload = (self.fft_generation, selected, settings)
        self.fft_job = self.fft_executor.submit(
            compute_spectra,
            data[selected],
            sfreq,
            settings["duration"],
            settings["window"],
            settings["resolution"],
            settings["workers"],
            settings["backend"],
        )

    def _refresh_visible_tab(self):
        selected = self.sidebar.selected_indices()
        tab_index = self.tabs.currentIndex()
        if tab_index == 0:
            now = time.monotonic()
            if now - self.last_signal_refresh < SIGNAL_REFRESH_SECONDS:
                return
            self.last_signal_refresh = now
            data, sfreq, _ = self.store.snapshot()
            self.signal_tab.refresh(
                data,
                sfreq,
                selected,
                average_only=self.sidebar.average_only(),
            )
            return
        self._schedule_fft()

    def _update_trial_state(self):
        available = (
            self.recording is not None
            and self.job_kind != "load"
            and self.pending_load_path is None
            and self.recording.trial_intervals.size > 0
        )
        in_trial = (
            self.recording.is_in_trial(self.current_time) if available else False
        )
        self.sidebar.set_trial_state(in_trial, available=available)

    def _tick(self):
        self._poll_job()
        self._poll_fft_job()
        self._schedule_playback_read()
        self._update_trial_state()
        self._refresh_visible_tab()

    def closeEvent(self, event):
        self.playing = False
        self.timer.stop()
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.fft_executor.shutdown(wait=False, cancel_futures=True)
        if self.recording is not None and self.job is None:
            self.recording.close()
        event.accept()


def main():
    app = QApplication(sys.argv)
    window = GdfViewer()
    window.showMaximized()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
