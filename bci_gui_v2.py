import sys
import os
import time
import math
import csv
import argparse
import threading
from collections import deque
import numpy as np
import pyqtgraph as pg
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
                             QTabWidget, QGroupBox, QLabel, QPushButton, QLineEdit, QSpinBox, 
                             QDoubleSpinBox, QCheckBox, QFileDialog, QFormLayout, QFrame, QScrollArea,
                             QTableWidget, QTableWidgetItem, QHeaderView, QGridLayout, QMessageBox)
from PyQt5.QtCore import QTimer, Qt, pyqtSignal

import eeg_tcp_server

# ── Configuration & Theming ──────────────────────────────────────
pg.setConfigOption('background', '#0d1117')
pg.setConfigOption('foreground', '#c9d1d9')
pg.setConfigOption('antialias', True)

NUM_CH    = 32
FS        = 250
DISP_SAMP = FS * 5
FFT_NPTS  = 500
RAW_PORT  = 5005

# Trigger code definitions matching Config.h / MATLAB
TRIGGER_TRIAL_START = 20
TRIGGER_TRIAL_STOP  = 60
TRIGGER_BLOCK_STOP  = 25
TRIGGER_RESET       = 0

TRIGGER_START_CODES = {20, 21, 22, 23, 24, 31, 32, 33, 34}
TRIGGER_STOP_CODES  = {60, 30, 25, 0}

CH_COLORS = [
    '#58a6ff','#f78166','#56d364','#e3b341','#bc8cff','#ff7b72','#3fb950','#d29922',
    '#58a6ff','#f78166','#56d364','#e3b341','#bc8cff','#ff7b72','#3fb950','#d29922',
    '#58a6ff','#f78166','#56d364','#e3b341','#bc8cff','#ff7b72','#3fb950','#d29922',
    '#58a6ff','#f78166','#56d364','#e3b341','#bc8cff','#ff7b72','#3fb950','#d29922',
]

# ── Data Store ───────────────────────────────────────────────────
TAVG_WIN = FS  # 1-second window = 250 samples

class DataStore:
    def __init__(self):
        self.lock       = threading.Lock()
        self.raw        = [deque([0.0]*DISP_SAMP, maxlen=DISP_SAMP) for _ in range(NUM_CH)]
        self.seq        = 0
        self.pkt_count  = 0
        self.connected  = False
        self.stats      = {}  # Telemetry stats from TCP server
        
        self.alpha      = [deque([0.0]*1000, maxlen=1000) for _ in range(8)]
        self.ssvep_pA   = [deque([0.0]*1000, maxlen=1000) for _ in range(8)]
        self.ssvep_pB   = [deque([0.0]*1000, maxlen=1000) for _ in range(8)]
        self.nf_smi_14gt18 = deque([0.0]*1000, maxlen=1000)
        self.nf_smi_18gt14 = deque([0.0]*1000, maxlen=1000)

        # ── Trigger-Gated & Latency Tracking State ─────────────────
        self.gate_open           = False
        self.last_trigger_sent   = 0
        self.last_trigger_sent_t = 0.0
        self.marker_echo_lat_ms  = 0.0
        self.first_data_lat_ms   = 0.0
        self.last_data_lat_ms    = 0.0
        self.waiting_first_data  = False
        self.waiting_stop_data   = False
        self.stop_trigger_t      = 0.0
        self.latched_marker      = 0

        self.trial_active        = False
        self.trial_start_t       = 0.0
        self.trial_samples       = 0
        self.trial_start_seq     = 0
        self.trial_history       = []

        # ── Time-Averaged SSVEP Accumulation State ─────────────────
        self._tavg_win_buf   = [[] for _ in range(NUM_CH)]  # per-channel sample buffer for current 1s window
        self._tavg_n_fft     = TAVG_WIN                      # FFT length = 1 second of samples
        self._tavg_freqs     = np.fft.rfftfreq(TAVG_WIN, 1.0 / FS)
        self._tavg_n_bins    = len(self._tavg_freqs)
        self._tavg_sum       = np.zeros((NUM_CH, len(self._tavg_freqs)), dtype=np.float64)  # cumulative power sum
        self._tavg_count     = 0                              # number of windows accumulated
        self._tavg_block     = 0                              # block counter (increments each trial)
        self._tavg_active    = False                          # whether we are currently accumulating

    def push_raw(self, vals, seq):
        with self.lock:
            now = time.time()
            self.seq = seq
            self.pkt_count += 1
            self.connected = True
            if self.waiting_first_data and self.last_trigger_sent_t > 0:
                self.first_data_lat_ms = (now - self.last_trigger_sent_t) * 1000.0
                self.waiting_first_data = False
            if self.waiting_stop_data and self.stop_trigger_t > 0:
                elapsed_ms = (now - self.stop_trigger_t) * 1000.0
                if elapsed_ms <= 5000.0:
                    self.last_data_lat_ms = elapsed_ms
                    if self.trial_history:
                        self.trial_history[-1]["last_data_lat"] = elapsed_ms
                else:
                    self.waiting_stop_data = False
            if self.trial_active:
                self.trial_samples += 1
            for i in range(min(len(vals), NUM_CH)):
                self.raw[i].append(vals[i])

            # ── Time-Averaged SSVEP: accumulate into 1s windows ─────
            if self._tavg_active:
                n_ch = min(len(vals), NUM_CH)
                for i in range(n_ch):
                    self._tavg_win_buf[i].append(vals[i])
                # Check if we have a full 1-second window
                if len(self._tavg_win_buf[0]) >= TAVG_WIN:
                    for i in range(NUM_CH):
                        seg = np.array(self._tavg_win_buf[i][:TAVG_WIN], dtype=np.float64)
                        seg = seg - np.mean(seg)  # remove DC
                        # linear detrend
                        t = np.arange(TAVG_WIN)
                        p = np.polyfit(t, seg, 1)
                        seg = seg - np.polyval(p, t)
                        Y = np.fft.rfft(seg, n=TAVG_WIN)
                        pwr = (np.abs(Y) / TAVG_WIN) ** 2
                        pwr[1:-1] *= 2  # single-sided
                        self._tavg_sum[i] += pwr
                        # clear used samples (keep remainder for next window)
                        self._tavg_win_buf[i] = self._tavg_win_buf[i][TAVG_WIN:]
                    self._tavg_count += 1

    def push_stats(self, stats):
        with self.lock:
            self.stats = stats
            self.connected = True
            if "marker" in stats:
                self.latched_marker = stats["marker"]

    def push_marker(self, code, seq):
        with self.lock:
            now = time.time()
            self.latched_marker = code
            if self.last_trigger_sent_t > 0 and self.last_trigger_sent == code:
                self.marker_echo_lat_ms = (now - self.last_trigger_sent_t) * 1000.0
                if self.trial_history and code in TRIGGER_STOP_CODES:
                    self.trial_history[-1]["echo_lat"] = self.marker_echo_lat_ms

            if code in TRIGGER_START_CODES:
                self.gate_open = True
                if not self.trial_active:
                    self.trial_active = True
                    self.trial_start_t = now
                    self.trial_samples = 0
                    self.trial_start_seq = seq
                    self.stop_trigger_t = 0.0
                    self.waiting_stop_data = False
                # Start time-avg accumulation (reset buffers for new trial)
                self._tavg_active = True
                self._tavg_win_buf = [[] for _ in range(NUM_CH)]
                # Don't reset _tavg_sum/_tavg_count here — we accumulate across
                # the entire block.  Reset only on explicit user action or block stop.
            elif code in TRIGGER_STOP_CODES:
                self.stop_trigger_t = now
                self.waiting_stop_data = True
                # Stop time-avg accumulation
                self._tavg_active = False
                if self.trial_active:
                    dur = now - self.trial_start_t
                    sps = (self.trial_samples / dur) if dur > 0 else 0.0
                    summary = {
                        "ts": time.strftime("%H:%M:%S"),
                        "trigger": code,
                        "dur": dur,
                        "samples": self.trial_samples,
                        "sps": sps,
                        "echo_lat": self.marker_echo_lat_ms,
                        "data_lat": self.first_data_lat_ms,
                        "last_data_lat": self.last_data_lat_ms,
                    }
                    self.trial_history.append(summary)
                    if len(self.trial_history) > 100:
                        self.trial_history.pop(0)
                self.gate_open = False
                self.trial_active = False

    def push_alpha(self, vals, seq):
        with self.lock:
            for i in range(min(len(vals), 8)):
                self.alpha[i].append(vals[i])

    def push_ssvep(self, vals, seq):
        with self.lock:
            pA, sA, pB, sB = vals
            for i in range(min(len(pA), 8)):
                self.ssvep_pA[i].append(pA[i])
                self.ssvep_pB[i].append(pB[i])

    def push_nf(self, vals, seq):
        with self.lock:
            self.nf_smi_14gt18.append(vals[0])
            self.nf_smi_18gt14.append(vals[1])

    def get_ch(self, ch):
        with self.lock:
            return np.array(self.raw[ch], dtype=np.float32)

    def get_fft(self, ch):
        with self.lock:
            arr = np.array(self.raw[ch], dtype=np.float64)
        N = FFT_NPTS
        seg = arr[-N:] if len(arr) >= N else np.pad(arr, (N - len(arr), 0))
        if np.std(seg) < 0.001:
            return np.fft.rfftfreq(N, 1.0/FS), np.zeros(N//2 + 1)
        seg = seg - np.mean(seg)
        t = np.arange(N); p = np.polyfit(t, seg, 1)
        seg = seg - np.polyval(p, t)
        Y   = np.fft.rfft(seg, n=N)
        P2  = (np.abs(Y) / N) ** 2
        P1  = P2.copy(); P1[1:-1] *= 2
        return np.fft.rfftfreq(N, 1.0/FS), P1

    def get_tavg_spectrum(self):
        """Return (freqs, avg_power[NUM_CH, n_bins], count, is_active, block_id)."""
        with self.lock:
            count = self._tavg_count
            if count > 0:
                avg = self._tavg_sum.copy() / count
            else:
                avg = np.zeros_like(self._tavg_sum)
            return (self._tavg_freqs.copy(), avg, count,
                    self._tavg_active, self._tavg_block)

    def reset_tavg(self):
        """Reset the time-averaged accumulation buffers (e.g. on new block)."""
        with self.lock:
            self._tavg_sum[:] = 0.0
            self._tavg_count = 0
            self._tavg_win_buf = [[] for _ in range(NUM_CH)]
            self._tavg_block += 1

store = DataStore()


# ── Callbacks for TCP Server ──────────────────────────────────────
def _on_raw(counts, seq):
    uvs = [c * eeg_tcp_server.CFG["uv_per_count"] for c in counts]
    store.push_raw(uvs, seq)

def _on_proc(uvs, seq):
    # Only push if we haven't already pushed this seq via RAW (if both are streaming)
    if store.seq != seq:
        store.push_raw(uvs, seq)

def _on_stats(stats):
    store.push_stats(stats)

def _on_marker(code, seq):
    store.push_marker(code, seq)

def _on_marker_sent(code):
    now = time.time()
    with store.lock:
        store.last_trigger_sent = code
        store.last_trigger_sent_t = now
        if code in TRIGGER_START_CODES:
            store.gate_open = True
            store.trial_active = True
            store.trial_start_t = now
            store.trial_samples = 0
            store.waiting_first_data = True
            store.waiting_stop_data = False
            store.stop_trigger_t = 0.0
            store.marker_echo_lat_ms = 0.0
            store.first_data_lat_ms = 0.0
            store.last_data_lat_ms = 0.0
            store._tavg_active = True
            store._tavg_win_buf = [[] for _ in range(NUM_CH)]
        elif code in TRIGGER_STOP_CODES:
            store.stop_trigger_t = now
            store.waiting_stop_data = True
            store.last_data_lat_ms = 0.0
            store._tavg_active = False
            if store.trial_active:
                dur = now - store.trial_start_t
                sps = (store.trial_samples / dur) if dur > 0 else 0.0
                summary = {
                    "ts": time.strftime("%H:%M:%S"),
                    "trigger": code,
                    "dur": dur,
                    "samples": store.trial_samples,
                    "sps": sps,
                    "echo_lat": store.marker_echo_lat_ms,
                    "data_lat": store.first_data_lat_ms,
                    "last_data_lat": 0.0,
                }
                store.trial_history.append(summary)
                if len(store.trial_history) > 100:
                    store.trial_history.pop(0)
            store.gate_open = False
            store.trial_active = False
        elif code == TRIGGER_RESET:
            store.gate_open = False
            store.trial_active = False
            store._tavg_active = False

def _on_alpha(vals, seq):
    store.push_alpha(vals, seq)

def _on_ssvep(vals, seq):
    store.push_ssvep(vals, seq)

def _on_nf(vals, seq):
    store.push_nf(vals, seq)

def _run_eeg_server():
    eeg_tcp_server.GUI_RAW_CALLBACK = _on_raw
    eeg_tcp_server.GUI_PROC_CALLBACK = _on_proc
    eeg_tcp_server.GUI_STATS_CALLBACK = _on_stats
    eeg_tcp_server.GUI_MARKER_CALLBACK = _on_marker
    eeg_tcp_server.GUI_MARKER_SENT_CALLBACK = _on_marker_sent
    eeg_tcp_server.GUI_ALPHA_CALLBACK = _on_alpha
    eeg_tcp_server.GUI_SSVEP_CALLBACK = _on_ssvep
    eeg_tcp_server.GUI_NF_CALLBACK = _on_nf
    sys.argv = [sys.argv[0], "--debug", "--log"]
    eeg_tcp_server.main()


# ── UI Components ────────────────────────────────────────────────
class StyledSidebar(QFrame):
    def __init__(self):
        super().__init__()
        self.setFixedWidth(280)
        self.setStyleSheet("""
            QFrame {
                background: #161b22;
                border-right: 1px solid #30363d;
            }
            QLabel { color: #c9d1d9; font-size: 10pt; }
            .Header { color: #58a6ff; font-weight: bold; font-size: 11pt; margin-top: 15px; margin-bottom: 5px; border-bottom: 1px solid #30363d; }
            .Value { font-weight: bold; color: white; }
        """)
        
        layout = QVBoxLayout(self)
        layout.setContentsMargins(15, 20, 15, 20)
        layout.setSpacing(5)

        # Branding
        title = QLabel("BCI Telemetry V2")
        title.setStyleSheet("color: white; font-size: 16pt; font-weight: 800; border: none; letter-spacing: 1px;")
        title.setAlignment(Qt.AlignCenter)
        layout.addWidget(title)
        
        self.lbl_conn = QLabel("⬤ Disconnected")
        self.lbl_conn.setStyleSheet("color: #f78166; font-weight: bold; font-size: 12pt; border: none;")
        self.lbl_conn.setAlignment(Qt.AlignCenter)
        layout.addWidget(self.lbl_conn)
        
        layout.addSpacing(20)

        # Form layout for stats
        form = QFormLayout()
        form.setLabelAlignment(Qt.AlignLeft)
        form.setFormAlignment(Qt.AlignLeft | Qt.AlignTop)
        form.setHorizontalSpacing(15)
        form.setVerticalSpacing(8)

        self.val_labels = {}
        
        def add_stat(key, label):
            lbl_key = QLabel(label)
            lbl_val = QLabel("—")
            lbl_val.setProperty("class", "Value")
            self.val_labels[key] = lbl_val
            form.addRow(lbl_key, lbl_val)

        lbl = QLabel("NETWORK"); lbl.setProperty("class", "Header"); layout.addWidget(lbl)
        add_stat("frames", "Frames / Sec:")

        layout.addLayout(form)
        layout.addSpacing(5)

        # ── PACKET LOSS — every loss category in ONE place ──────────────────
        #   board_drops : ring full on the board       (Transport dropCount)
        #   pc_gaps     : sequence gaps seen at the PC  (board skipped / reconnect)
        #   board_bad   : bad SPI-status frames         (board, cumulative)
        #   board_miss  : missed DRDY / DSP overruns    (board, cumulative)
        #   srv_bad     : malformed frames this server rejected
        #   dsp_max     : peak DSP burst (µs) — >4000 means loop() is over budget
        formL = QFormLayout(); formL.setHorizontalSpacing(15); formL.setVerticalSpacing(8)
        self._loss_hdr = QLabel("PACKET LOSS"); self._loss_hdr.setProperty("class", "Header")
        layout.addWidget(self._loss_hdr)
        def add_loss(key, label):
            lbl_key = QLabel(label); lbl_val = QLabel("—")
            lbl_val.setProperty("class", "Value")
            self.val_labels[key] = lbl_val
            formL.addRow(lbl_key, lbl_val)
        add_loss("board_drops", "Board ring drops:")
        add_loss("pc_gaps",     "PC seq gaps:")
        add_loss("board_bad",   "Board SPI bad:")
        add_loss("board_miss",  "Board missed DRDY:")
        add_loss("srv_bad",     "Server malformed:")
        add_loss("board_dspmax","DSP peak (µs):")
        layout.addLayout(formL)
        layout.addSpacing(5)
        
        form2 = QFormLayout(); form2.setHorizontalSpacing(15); form2.setVerticalSpacing(8)
        lbl2 = QLabel("PARITY / FILTER"); lbl2.setProperty("class", "Header"); layout.addWidget(lbl2)
        add_stat("f_max", "Worst |D| uV:")
        add_stat("a_relmax", "Alpha rel|D|:")
        add_stat("sv_p_relmax", "SSVEP P rel|D|:")
        layout.addLayout(form2)
        
        layout.addSpacing(5)
        
        form3 = QFormLayout(); form3.setHorizontalSpacing(15); form3.setVerticalSpacing(8)
        lbl3 = QLabel("BOARD HARDWARE"); lbl3.setProperty("class", "Header"); layout.addWidget(lbl3)
        add_stat("heap", "Free Heap:")
        add_stat("marker", "Curr Marker:")
        layout.addLayout(form3)

        layout.addStretch()
        
    def refresh(self):
        connected = store.connected
        col = '#56d364' if connected else '#f78166'
        status = "Connected" if connected else "Disconnected"
        self.lbl_conn.setText(f"<font color='{col}'>⬤</font> {status}")
        
        with store.lock:
            st = store.stats.copy()
        
        if st:
            def update(k, fmt="{v}"):
                if k in st: self.val_labels[k].setText(fmt.format(v=st[k]))
                
            update("frames", "{v} fps")

            # ── PACKET LOSS panel ──────────────────────────────────────────
            pc_gaps = st.get("gaps_r", 0) + st.get("gaps_p", 0)
            loss_vals = {
                "board_drops": st.get("board_drops", 0),
                "pc_gaps":     pc_gaps,
                "board_bad":   st.get("board_bad", 0),
                "board_miss":  st.get("board_miss", 0),
                "srv_bad":     st.get("srv_bad", st.get("bad", 0)),
                "board_dspmax":st.get("board_dspmax", 0),
            }
            for k, v in loss_vals.items():
                if k in self.val_labels:
                    self.val_labels[k].setText(str(v))
            # header goes red if ANY loss category is nonzero (dsp_max excluded —
            # it's a timing gauge, not a loss count)
            any_loss = any(loss_vals[k] for k in
                           ("board_drops","pc_gaps","board_bad","board_miss","srv_bad"))
            self._loss_hdr.setStyleSheet(
                "color: #f78166; font-weight: bold; font-size: 11pt;" if any_loss
                else "color: #56d364; font-weight: bold; font-size: 11pt;")

            def fmt_e(k):
                if k in st: self.val_labels[k].setText(f"{st[k]:.2e}")
            fmt_e("f_max"); fmt_e("a_relmax"); fmt_e("sv_p_relmax")
            
            update("heap")
            update("marker")


class SignalTab(QWidget):
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(5, 5, 5, 5)

        ctrl = QHBoxLayout()
        self.cb_dc = QCheckBox("Remove DC offset (Centered)")
        self.cb_dc.setChecked(True)
        ctrl.addWidget(self.cb_dc)
        
        self.cb_autoscale = QCheckBox("Autoscale Y")
        self.cb_autoscale.setChecked(True)
        self.cb_autoscale.toggled.connect(self._on_autoscale_changed)
        ctrl.addWidget(self.cb_autoscale)
        
        ctrl.addWidget(QLabel(" Fixed Y Range (µV):"))
        self.sp_yrange = QDoubleSpinBox()
        self.sp_yrange.setRange(1, 100000); self.sp_yrange.setValue(200)
        self.sp_yrange.setEnabled(False)
        ctrl.addWidget(self.sp_yrange)
        
        ctrl.addStretch()
        layout.addLayout(ctrl)

        # Checkbox Panel for Channel Selection
        sa_ch = QScrollArea()
        sa_ch.setWidgetResizable(True)
        sa_ch.setFixedHeight(80)
        sw_ch = QWidget()
        sl_ch = QFormLayout(sw_ch)
        
        self.ch_checks = []
        row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0,0,0,0)
        for i in range(NUM_CH):
            cb = QCheckBox(f"CH{i+1}")
            cb.setStyleSheet(f"color: {CH_COLORS[i % len(CH_COLORS)]}; font-weight: bold;")
            if 8 <= i < 16:
                cb.setChecked(True)
            else:
                cb.setChecked(False)
            cb.toggled.connect(self._update_visibility)
            self.ch_checks.append(cb)
            row_l.addWidget(cb)
            if (i+1) % 8 == 0:
                sl_ch.addRow(row_w)
                row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0,0,0,0)
        if (NUM_CH) % 8 != 0: sl_ch.addRow(row_w)
        
        sa_ch.setWidget(sw_ch)
        layout.addWidget(sa_ch)

        # Scroll area for separate plots
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll_widget = QWidget()
        self.scroll_layout = QVBoxLayout(self.scroll_widget)
        self.scroll_layout.setContentsMargins(5, 5, 5, 5)
        self.scroll_layout.setSpacing(5)
        
        self.plots = []
        self.curves = []
        self.t_axis = np.linspace(-5, 0, DISP_SAMP)
        
        for i in range(NUM_CH):
            pw = pg.PlotWidget(title=f"Channel {i+1}")
            pw.showGrid(x=True, y=True, alpha=0.3)
            pw.setLabel('bottom', 'Time', 's')
            pw.setXRange(-5, 0, padding=0)
            pw.setFixedHeight(160)
            c = pw.plot(pen=pg.mkPen(CH_COLORS[i % len(CH_COLORS)], width=1.2))
            
            self.plots.append(pw)
            self.curves.append(c)
            self.scroll_layout.addWidget(pw)
            
        self.scroll.setWidget(self.scroll_widget)
        layout.addWidget(self.scroll, stretch=1)
        
        self._update_visibility()

    def _on_autoscale_changed(self, checked):
        self.sp_yrange.setEnabled(not checked)

    def _update_visibility(self):
        for i in range(NUM_CH):
            visible = self.ch_checks[i].isChecked()
            self.plots[i].setVisible(visible)

    def refresh(self):
        remove_dc = self.cb_dc.isChecked()
        autoscale = self.cb_autoscale.isChecked()
        yrange = self.sp_yrange.value()
        
        for i in range(NUM_CH):
            if not self.ch_checks[i].isChecked():
                continue
                
            d = store.get_ch(i).astype(np.float64)
            if remove_dc:
                d = d - float(d.mean())
                
            self.curves[i].setData(self.t_axis, d)
            
            if not autoscale:
                self.plots[i].setYRange(-yrange/2.0, yrange/2.0, padding=0)
            else:
                self.plots[i].enableAutoRange(axis=pg.ViewBox.YAxis, enable=True)


class FFTTab(QWidget):
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)

        ctrl = QHBoxLayout()
        ctrl.addWidget(QLabel("X Max (Hz):"))
        self.sp_xmax = QSpinBox(); self.sp_xmax.setRange(20, 125); self.sp_xmax.setValue(60)
        self.sp_xmax.valueChanged.connect(self._on_xmax)
        ctrl.addWidget(self.sp_xmax)
        
        self.cb_auto = QCheckBox("Autoscale Y")
        self.cb_auto.setChecked(True)
        ctrl.addWidget(self.cb_auto)
        
        ctrl.addWidget(QLabel(" Fixed Y:"))
        self.sp_ymax = QDoubleSpinBox()
        self.sp_ymax.setRange(1, 100000); self.sp_ymax.setValue(100)
        self.sp_ymax.setSingleStep(50)
        ctrl.addWidget(self.sp_ymax)
        
        ctrl.addStretch()
        layout.addLayout(ctrl)

        self.pw = pg.PlotWidget(title="FFT Power Spectrum")
        self.pw.showGrid(x=True, y=True, alpha=0.3)
        self.pw.setXRange(0, 60, padding=0.01)
        self.pw.setLabel('bottom', 'Frequency', 'Hz')
        layout.addWidget(self.pw, stretch=1)

        self.curves = []
        for i in range(NUM_CH):
            c = self.pw.plot(pen=pg.mkPen(CH_COLORS[i % len(CH_COLORS)], width=1.5))
            self.curves.append(c)
            
        sa = QScrollArea()
        sa.setWidgetResizable(True)
        sa.setFixedHeight(140)
        sw = QWidget()
        sl = QFormLayout(sw)
        
        self.ch_checks = []
        row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0,0,0,0)
        for i in range(NUM_CH):
            cb = QCheckBox(f"CH{i+1}")
            cb.setStyleSheet(f"color: {CH_COLORS[i % len(CH_COLORS)]}; font-weight: bold;")
            if 8 <= i < 16:
                cb.setChecked(True)
            else:
                cb.setChecked(False)
            self.ch_checks.append(cb)
            row_l.addWidget(cb)
            if (i+1) % 8 == 0:
                sl.addRow(row_w)
                row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0,0,0,0)
        if (NUM_CH) % 8 != 0: sl.addRow(row_w)
        
        sa.setWidget(sw)
        layout.addWidget(sa)

    def _on_xmax(self, v):
        self.pw.setXRange(0, v, padding=0.01)

    def refresh(self):
        peak = 0.0
        xmax = self.sp_xmax.value()
        
        for i in range(NUM_CH):
            if not self.ch_checks[i].isChecked():
                self.curves[i].setData([], [])
                continue
                
            freqs, pwr = store.get_fft(i)
            pwr[0] = 0
            self.curves[i].setData(freqs, pwr)
            
            mask = (freqs > 0.5) & (freqs <= xmax)
            if np.any(mask):
                m = np.max(pwr[mask])
                if m > peak: peak = m

        if self.cb_auto.isChecked() and peak > 1e-9:
            self.pw.setYRange(0, peak * 1.3, padding=0)
        elif not self.cb_auto.isChecked():
            self.pw.setYRange(0, self.sp_ymax.value(), padding=0)

class AnalysisSpectrumTab(QWidget):
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)

        ctrl = QHBoxLayout()
        ctrl.addWidget(QLabel("X Min (Hz):"))
        self.sp_xmin = QSpinBox(); self.sp_xmin.setRange(0, 125); self.sp_xmin.setValue(5)
        self.sp_xmin.valueChanged.connect(self._on_xrange)
        ctrl.addWidget(self.sp_xmin)
        
        ctrl.addWidget(QLabel("X Max (Hz):"))
        self.sp_xmax = QSpinBox(); self.sp_xmax.setRange(20, 125); self.sp_xmax.setValue(40)
        self.sp_xmax.valueChanged.connect(self._on_xrange)
        ctrl.addWidget(self.sp_xmax)
        
        self.cb_auto = QCheckBox("Autoscale Y")
        self.cb_auto.setChecked(True)
        ctrl.addWidget(self.cb_auto)
        
        ctrl.addWidget(QLabel(" Fixed Y:"))
        self.sp_ymax = QDoubleSpinBox()
        self.sp_ymax.setRange(1, 100000); self.sp_ymax.setValue(100)
        self.sp_ymax.setSingleStep(50)
        ctrl.addWidget(self.sp_ymax)
        
        self.btn_log = QPushButton("Log 8-30Hz to CSV")
        self.btn_log.setCheckable(True)
        self.btn_log.clicked.connect(self._toggle_logging)
        ctrl.addWidget(self.btn_log)
        
        ctrl.addStretch()
        layout.addLayout(ctrl)

        self.log_file = None
        self.log_freqs = None
        self.current_log_run_dir = None

        self.pw = pg.PlotWidget(title="Analysis Power Spectrum (32 Channels)")
        self.pw.showGrid(x=True, y=True, alpha=0.3)
        self.pw.setXRange(5, 40, padding=0.01)
        self.pw.setLabel('bottom', 'Frequency', 'Hz')
        self.pw.setLabel('left', 'Power')
        self.pw.addLegend()
        layout.addWidget(self.pw, stretch=1)

        self.curves = []
        for i in range(NUM_CH):
            c = self.pw.plot(pen=pg.mkPen(CH_COLORS[i % len(CH_COLORS)], width=1.5), name=f"CH{i+1}")
            self.curves.append(c)
            
        sa = QScrollArea()
        sa.setWidgetResizable(True)
        sa.setFixedHeight(80)
        sw = QWidget()
        sl = QFormLayout(sw)
        
        self.ch_checks = []
        row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0,0,0,0)
        for i in range(NUM_CH):
            cb = QCheckBox(f"CH{i+1}")
            cb.setStyleSheet(f"color: {CH_COLORS[i % len(CH_COLORS)]}; font-weight: bold;")
            if 8 <= i < 16:
                cb.setChecked(True)
            else:
                cb.setChecked(False)
            self.ch_checks.append(cb)
            row_l.addWidget(cb)
            if (i+1) % 8 == 0:
                sl.addRow(row_w)
                row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0,0,0,0)
        if NUM_CH % 8 != 0: sl.addRow(row_w)
        
        sa.setWidget(sw)
        layout.addWidget(sa)

    def _on_xrange(self, v):
        self.pw.setXRange(self.sp_xmin.value(), self.sp_xmax.value(), padding=0.01)

    def _toggle_logging(self, checked):
        if checked:
            self._start_fft_logging()
        else:
            self._stop_fft_logging()

    def _start_fft_logging(self):
        if self.log_file:
            try: self.log_file.close()
            except Exception: pass
            self.log_file = None

        run_dir = getattr(eeg_tcp_server, "CURRENT_RUN_DIR", None)
        run_ts = getattr(eeg_tcp_server, "CURRENT_RUN_TS", None)

        if run_dir and run_ts:
            self.current_log_run_dir = run_dir
            os.makedirs(run_dir, exist_ok=True)
            self.log_file = open(os.path.join(run_dir, f"eeg_{run_ts}_spectrum_8_30Hz.csv"), "w", buffering=1<<16)
        else:
            self.current_log_run_dir = None
            os.makedirs("logs", exist_ok=True)
            ts = time.strftime("%Y%m%d_%H%M%S")
            self.log_file = open(f"logs/eeg_{ts}_spectrum_8_30Hz.csv", "w", buffering=1<<16)

        freqs = np.fft.rfftfreq(FFT_NPTS, 1.0/FS)
        mask = (freqs >= 8.0) & (freqs <= 30.0)
        self.log_freqs = freqs[mask]

        header = "time,seq,channel," + ",".join([f"{f:.1f}Hz" for f in self.log_freqs])
        self.log_file.write(header + "\n")
        self.btn_log.setText("Stop Logging")
        self.btn_log.setStyleSheet("background: #da3633;")

    def _stop_fft_logging(self):
        if self.log_file:
            try: self.log_file.close()
            except Exception: pass
            self.log_file = None
        self.current_log_run_dir = None
        self.btn_log.setText("Log 8-30Hz to CSV")
        self.btn_log.setStyleSheet("")

    def refresh(self):
        if self.btn_log.isChecked():
            active_run_dir = getattr(eeg_tcp_server, "CURRENT_RUN_DIR", None)
            if active_run_dir != self.current_log_run_dir:
                self._start_fft_logging()

        peak = 0.0
        xmin = self.sp_xmin.value()
        xmax = self.sp_xmax.value()
        
        log_data = []
        now_str = time.strftime("%H:%M:%S") if self.log_file else ""
        
        for i in range(NUM_CH):
            if not self.ch_checks[i].isChecked():
                self.curves[i].setData([], [])
                continue
                
            freqs, pwr = store.get_fft(i)
            pwr[0] = 0
            self.curves[i].setData(freqs, pwr)
            
            if self.log_file is not None:
                mask_log = (freqs >= 8.0) & (freqs <= 30.0)
                pwr_log = pwr[mask_log]
                row = f"{now_str},{store.seq},CH{i+1}," + ",".join([f"{x:.6f}" for x in pwr_log])
                log_data.append(row)
            
            mask = (freqs >= xmin) & (freqs <= xmax)
            if np.any(mask):
                m = np.max(pwr[mask])
                if m > peak: peak = m

        if self.log_file is not None and log_data:
            self.log_file.write("\n".join(log_data) + "\n")

        if self.cb_auto.isChecked() and peak > 1e-9:
            self.pw.setYRange(0, peak * 1.3, padding=0)
        elif not self.cb_auto.isChecked():
            self.pw.setYRange(0, self.sp_ymax.value(), padding=0)


class FeaturesTab(QWidget):
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(10)

        self.pw_alpha = pg.PlotWidget(title="Alpha Band Power (8 Channels)")
        self.pw_alpha.showGrid(x=True, y=True, alpha=0.3)
        self.pw_alpha.setLabel('bottom', 'Time (Samples)')
        
        self.pw_ssvep = pg.PlotWidget(title="SSVEP Power (A: 14Hz Solid, B: 18Hz Dashed)")
        self.pw_ssvep.showGrid(x=True, y=True, alpha=0.3)
        self.pw_ssvep.setLabel('bottom', 'Time (Samples)')

        self.pw_nf = pg.PlotWidget(title="Neurofeedback (SMI 14>18, SMI 18>14)")
        self.pw_nf.showGrid(x=True, y=True, alpha=0.3)
        self.pw_nf.setLabel('bottom', 'Time (Samples)')

        layout.addWidget(self.pw_alpha)
        layout.addWidget(self.pw_ssvep)
        layout.addWidget(self.pw_nf)
        
        self.curves_alpha = []
        self.curves_ssvepA = []
        self.curves_ssvepB = []
        
        for i in range(8):
            color = CH_COLORS[i % len(CH_COLORS)]
            self.curves_alpha.append(self.pw_alpha.plot(pen=pg.mkPen(color, width=1.5)))
            self.curves_ssvepA.append(self.pw_ssvep.plot(pen=pg.mkPen(color, width=1.5)))
            self.curves_ssvepB.append(self.pw_ssvep.plot(pen=pg.mkPen(color, width=1.5, style=Qt.DashLine)))
            
        self.curve_nf1 = self.pw_nf.plot(pen=pg.mkPen('#58a6ff', width=2), name="SMI 14>18")
        self.curve_nf2 = self.pw_nf.plot(pen=pg.mkPen('#f78166', width=2), name="SMI 18>14")

    def refresh(self):
        with store.lock:
            a_data = [np.array(store.alpha[i]) for i in range(8)]
            sa_data = [np.array(store.ssvep_pA[i]) for i in range(8)]
            sb_data = [np.array(store.ssvep_pB[i]) for i in range(8)]
            nf1_data = np.array(store.nf_smi_14gt18)
            nf2_data = np.array(store.nf_smi_18gt14)

        for i in range(8):
            self.curves_alpha[i].setData(a_data[i])
            self.curves_ssvepA[i].setData(sa_data[i])
            self.curves_ssvepB[i].setData(sb_data[i])
            
        self.curve_nf1.setData(nf1_data)
        self.curve_nf2.setData(nf2_data)


class TriggerControlTab(QWidget):
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(15, 15, 15, 15)
        layout.setSpacing(12)

        # ── Group 1: Action Controls & Triggers ──
        grp_ctrl = QGroupBox("⚡ Trigger Actions & Transmission Gate Control")
        grp_ctrl.setStyleSheet("QGroupBox { font-weight: bold; color: #58a6ff; font-size: 11pt; border: 1px solid #30363d; border-radius: 6px; margin-top: 8px; padding-top: 15px; }")
        l_ctrl = QVBoxLayout(grp_ctrl)
        l_ctrl.setSpacing(10)

        btn_row = QHBoxLayout()
        btn_row.setSpacing(12)
        
        self.btn_start = QPushButton("▶ START TRIAL (Code 20)")
        self.btn_start.setStyleSheet("""
            QPushButton {
                background: #0d1117;
                border: 1px solid #30363d;
                border-radius: 6px;
                color: #c9d1d9;
                font-size: 11pt;
                padding: 12px 20px;
                font-weight: 800;
            }
            QPushButton:hover {
                border: 1px solid #2ea043;
                color: #3fb950;
                background: #0d1117;
            }
            QPushButton:pressed {
                background: #161b22;
                border: 1px solid #238636;
            }
        """)
        self.btn_start.clicked.connect(lambda: self._send_trigger(TRIGGER_TRIAL_START))
        btn_row.addWidget(self.btn_start)

        self.btn_stop = QPushButton("⏹ STOP TRIAL (Code 30)")
        self.btn_stop.setStyleSheet("""
            QPushButton {
                background: #0d1117;
                border: 1px solid #30363d;
                border-radius: 6px;
                color: #c9d1d9;
                font-size: 11pt;
                padding: 12px 20px;
                font-weight: 800;
            }
            QPushButton:hover {
                border: 1px solid #f85149;
                color: #ff7b72;
                background: #0d1117;
            }
            QPushButton:pressed {
                background: #161b22;
                border: 1px solid #da3633;
            }
        """)
        self.btn_stop.clicked.connect(lambda: self._send_trigger(TRIGGER_TRIAL_STOP))
        btn_row.addWidget(self.btn_stop)

        self.btn_block = QPushButton("⏸ BLOCK STOP (Code 25)")
        self.btn_block.setStyleSheet("""
            QPushButton {
                background: #0d1117;
                border: 1px solid #30363d;
                border-radius: 6px;
                color: #c9d1d9;
                font-size: 10pt;
                padding: 12px 16px;
                font-weight: bold;
            }
            QPushButton:hover {
                border: 1px solid #e3b341;
                color: #e3b341;
                background: #0d1117;
            }
            QPushButton:pressed {
                background: #161b22;
                border: 1px solid #bb8009;
            }
        """)
        self.btn_block.clicked.connect(lambda: self._send_trigger(TRIGGER_BLOCK_STOP))
        btn_row.addWidget(self.btn_block)

        self.btn_reset = QPushButton("↺ RESET (Code 0)")
        self.btn_reset.setStyleSheet("""
            QPushButton {
                background: #0d1117;
                border: 1px solid #30363d;
                border-radius: 6px;
                color: #c9d1d9;
                font-size: 10pt;
                padding: 12px 16px;
                font-weight: bold;
            }
            QPushButton:hover {
                border: 1px solid #8b949e;
                color: #ffffff;
                background: #0d1117;
            }
            QPushButton:pressed {
                background: #161b22;
                border: 1px solid #484f58;
            }
        """)
        self.btn_reset.clicked.connect(lambda: self._send_trigger(TRIGGER_RESET))
        btn_row.addWidget(self.btn_reset)
        l_ctrl.addLayout(btn_row)

        # Second row: Timed auto-run & Custom Trigger
        row2 = QHBoxLayout()
        row2.setSpacing(10)
        row2.addWidget(QLabel("⏱ Auto-Run Timed Trial (s):"))
        self.sp_timed = QDoubleSpinBox()
        self.sp_timed.setRange(0.5, 300.0); self.sp_timed.setValue(5.0); self.sp_timed.setSingleStep(1.0)
        self.sp_timed.setFixedWidth(80)
        row2.addWidget(self.sp_timed)

        self.btn_timed = QPushButton("▶ Run Timed Test")
        self.btn_timed.setStyleSheet("background: #1f6feb; border: 1px solid #388bfd; padding: 6px 16px; font-weight: bold;")
        self.btn_timed.clicked.connect(self._run_timed_trial)
        row2.addWidget(self.btn_timed)

        row2.addSpacing(30)
        row2.addWidget(QLabel("Custom Trigger Code:"))
        self.sp_custom = QSpinBox()
        self.sp_custom.setRange(0, 65535); self.sp_custom.setValue(1)
        self.sp_custom.setFixedWidth(90)
        row2.addWidget(self.sp_custom)

        self.btn_custom = QPushButton("Send Code")
        self.btn_custom.setStyleSheet("background: #21262d; border: 1px solid #30363d; padding: 6px 14px;")
        self.btn_custom.clicked.connect(lambda: self._send_trigger(self.sp_custom.value()))
        row2.addWidget(self.btn_custom)
        row2.addStretch()
        l_ctrl.addLayout(row2)

        layout.addWidget(grp_ctrl)

        # ── Group 2: Live Metrics & Latency Benchmarks ──
        grp_stats = QGroupBox("📊 Live Telemetry & Latency Benchmarking")
        grp_stats.setStyleSheet("QGroupBox { font-weight: bold; color: #58a6ff; font-size: 11pt; border: 1px solid #30363d; border-radius: 6px; margin-top: 8px; padding-top: 15px; }")
        grid = QGridLayout(grp_stats)
        grid.setHorizontalSpacing(15); grid.setVerticalSpacing(10)

        def make_card(title_text, initial="—"):
            f = QFrame()
            f.setStyleSheet("QFrame { background: #161b22; border: 1px solid #30363d; border-radius: 6px; }")
            fl = QVBoxLayout(f)
            fl.setContentsMargins(12, 10, 12, 10)
            fl.setSpacing(4)
            tl = QLabel(title_text)
            tl.setStyleSheet("color: #8b949e; font-size: 9pt; font-weight: bold;")
            vl = QLabel(initial)
            vl.setStyleSheet("color: white; font-size: 13pt; font-weight: 800;")
            fl.addWidget(tl); fl.addWidget(vl)
            return f, vl

        self.card_gate, self.lbl_gate = make_card("TRANSMISSION GATE", "🔴 CLOSED (Gated / Holding)")
        self.lbl_gate.setStyleSheet("color: #f78166; font-size: 12pt; font-weight: 800;")
        grid.addWidget(self.card_gate, 0, 0)

        self.card_time, self.lbl_time = make_card("ACTIVE TRIAL DURATION", "00:00.00")
        grid.addWidget(self.card_time, 0, 1)

        self.card_samples, self.lbl_samples = make_card("TRIAL SAMPLES RECEIVED", "0")
        grid.addWidget(self.card_samples, 0, 2)

        self.card_sps, self.lbl_sps = make_card("MEASURED TRIAL SPS", "0.0 SPS")
        grid.addWidget(self.card_sps, 1, 0)

        self.card_marker, self.lbl_cur_marker = make_card("LATCHED MARKER CODE", "0")
        grid.addWidget(self.card_marker, 1, 1)

        self.card_gaps, self.lbl_gaps = make_card("SEQUENCE GAPS IN TRIAL", "0")
        grid.addWidget(self.card_gaps, 1, 2)

        self.card_echo, self.lbl_echo = make_card("MARKER ECHO LATENCY (0x07)", "— ms")
        grid.addWidget(self.card_echo, 2, 0)

        self.card_first, self.lbl_first = make_card("FIRST DATA LATENCY (0x01)", "— ms")
        grid.addWidget(self.card_first, 2, 1)

        self.card_last_data, self.lbl_last_data = make_card("LAST DATA LATENCY (STOP)", "— ms")
        grid.addWidget(self.card_last_data, 2, 2)

        layout.addWidget(grp_stats)

        # ── Group 3: Trial History Log Table ──
        grp_hist = QGroupBox("📜 Trial History & Benchmarking Log")
        grp_hist.setStyleSheet("QGroupBox { font-weight: bold; color: #58a6ff; font-size: 11pt; border: 1px solid #30363d; border-radius: 6px; margin-top: 8px; padding-top: 15px; }")
        l_hist = QVBoxLayout(grp_hist)
        l_hist.setContentsMargins(12, 12, 12, 12)
        l_hist.setSpacing(8)

        self.table = QTableWidget(0, 8)
        self.table.setHorizontalHeaderLabels([
            "Timestamp", "Trigger Code", "Duration (s)", "Samples", "Effective SPS", "Echo Latency", "1st Data Latency", "Last Data Latency"
        ])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        self.table.setStyleSheet("""
            QTableWidget { background: #161b22; border: 1px solid #30363d; gridline-color: #21262d; color: #c9d1d9; font-size: 9.5pt; }
            QHeaderView::section { background: #21262d; color: #58a6ff; font-weight: bold; padding: 6px; border: 1px solid #30363d; }
        """)
        l_hist.addWidget(self.table)

        btn_hist_row = QHBoxLayout()
        btn_clear = QPushButton("🗑 Clear History")
        btn_clear.setStyleSheet("background: #21262d; border: 1px solid #30363d; color: #c9d1d9; padding: 5px 12px;")
        btn_clear.clicked.connect(self._clear_history)
        btn_hist_row.addWidget(btn_clear)

        btn_export = QPushButton("💾 Export Trial History CSV")
        btn_export.setStyleSheet("background: #21262d; border: 1px solid #30363d; color: #c9d1d9; padding: 5px 12px;")
        btn_export.clicked.connect(self._export_history)
        btn_hist_row.addWidget(btn_export)
        btn_hist_row.addStretch()
        l_hist.addLayout(btn_hist_row)

        layout.addWidget(grp_hist, stretch=1)

        self.timed_timer = QTimer()
        self.timed_timer.setSingleShot(True)
        self.timed_timer.timeout.connect(self._on_timed_trial_end)
        self._last_hist_len = 0

    def _send_trigger(self, code: int):
        success = eeg_tcp_server.send_marker_code(code)
        if not success:
            QMessageBox.warning(self, "No Connection", "ESP32 board is not connected yet! Cannot send trigger.")

    def _run_timed_trial(self):
        dur = self.sp_timed.value()
        self._send_trigger(TRIGGER_TRIAL_START)
        self.timed_timer.start(int(dur * 1000))

    def _on_timed_trial_end(self):
        self._send_trigger(TRIGGER_TRIAL_STOP)

    def _clear_history(self):
        with store.lock:
            store.trial_history.clear()
        self.table.setRowCount(0)
        self._last_hist_len = 0

    def _export_history(self):
        with store.lock:
            history = list(store.trial_history)
        if not history:
            QMessageBox.information(self, "Export", "No trial records to export.")
            return
        path, _ = QFileDialog.getSaveFileName(self, "Export Trial History", "trial_history.csv", "CSV Files (*.csv)")
        if path:
            try:
                with open(path, "w", newline="") as f:
                    writer = csv.writer(f)
                    writer.writerow(["Timestamp", "Trigger_Code", "Duration_sec", "Samples_Count", "Effective_SPS", "Marker_Echo_Latency_ms", "First_Data_Latency_ms", "Last_Data_Latency_ms"])
                    for r in history:
                        writer.writerow([r["ts"], r["trigger"], f"{r['dur']:.3f}", r["samples"], f"{r['sps']:.1f}", f"{r['echo_lat']:.2f}", f"{r['data_lat']:.2f}", f"{r.get('last_data_lat', 0.0):.2f}"])
                QMessageBox.information(self, "Export Success", f"Exported {len(history)} trial records to {path}")
            except Exception as e:
                QMessageBox.critical(self, "Export Failed", f"Failed to save file: {e}")

    def refresh(self):
        with store.lock:
            gate_open = store.gate_open
            trial_active = store.trial_active
            trial_start_t = store.trial_start_t
            trial_samples = store.trial_samples
            echo_lat = store.marker_echo_lat_ms
            first_lat = store.first_data_lat_ms
            last_data_lat = store.last_data_lat_ms
            latched = store.latched_marker
            history = list(store.trial_history)
            st = store.stats.copy()

        # Gate indicator
        if gate_open:
            self.lbl_gate.setText("🟢 GATE OPEN (Streaming)")
            self.lbl_gate.setStyleSheet("color: #56d364; font-size: 12pt; font-weight: 800;")
        else:
            self.lbl_gate.setText("🔴 GATE CLOSED (Gated / Holding)")
            self.lbl_gate.setStyleSheet("color: #f78166; font-size: 12pt; font-weight: 800;")

        # Active trial stats
        if trial_active:
            elapsed = time.time() - trial_start_t
            mins = int(elapsed // 60)
            secs = elapsed % 60
            self.lbl_time.setText(f"{mins:02d}:{secs:05.2f}")
            self.lbl_samples.setText(f"{trial_samples:,}")
            sps = (trial_samples / elapsed) if elapsed > 0 else 0.0
            self.lbl_sps.setText(f"{sps:.1f} SPS")
        elif history:
            last = history[-1]
            mins = int(last["dur"] // 60)
            secs = last["dur"] % 60
            self.lbl_time.setText(f"{mins:02d}:{secs:05.2f} (Last)")
            self.lbl_samples.setText(f"{last['samples']:,} (Last)")
            self.lbl_sps.setText(f"{last['sps']:.1f} SPS")

        # Latencies
        if echo_lat > 0:
            self.lbl_echo.setText(f"{echo_lat:.1f} ms")
        else:
            self.lbl_echo.setText("— ms")

        if first_lat > 0:
            self.lbl_first.setText(f"{first_lat:.1f} ms")
        else:
            self.lbl_first.setText("— ms")

        if last_data_lat > 0:
            self.lbl_last_data.setText(f"{last_data_lat:.1f} ms")
        else:
            self.lbl_last_data.setText("— ms")

        self.lbl_cur_marker.setText(str(latched))
        gaps = st.get("gaps_r", 0) + st.get("gaps_p", 0)
        self.lbl_gaps.setText(str(gaps))

        # Update History Table
        if len(history) != self._last_hist_len:
            self.table.setRowCount(len(history))
            for row, item in enumerate(history):
                self.table.setItem(row, 0, QTableWidgetItem(str(item["ts"])))
                self.table.setItem(row, 1, QTableWidgetItem(f"Code {item['trigger']}"))
                self.table.setItem(row, 2, QTableWidgetItem(f"{item['dur']:.2f} s"))
                self.table.setItem(row, 3, QTableWidgetItem(f"{item['samples']:,}"))
                self.table.setItem(row, 4, QTableWidgetItem(f"{item['sps']:.1f}"))
                self.table.setItem(row, 5, QTableWidgetItem(f"{item['echo_lat']:.1f} ms" if item.get('echo_lat', 0) > 0 else "—"))
                self.table.setItem(row, 6, QTableWidgetItem(f"{item['data_lat']:.1f} ms" if item.get('data_lat', 0) > 0 else "—"))
                self.table.setItem(row, 7, QTableWidgetItem(f"{item['last_data_lat']:.1f} ms" if item.get('last_data_lat', 0) > 0 else "—"))
            self.table.scrollToBottom()
            self._last_hist_len = len(history)
        elif history:
            last_row = len(history) - 1
            item = history[-1]
            self.table.setItem(last_row, 5, QTableWidgetItem(f"{item['echo_lat']:.1f} ms" if item.get('echo_lat', 0) > 0 else "—"))
            self.table.setItem(last_row, 6, QTableWidgetItem(f"{item['data_lat']:.1f} ms" if item.get('data_lat', 0) > 0 else "—"))
            self.table.setItem(last_row, 7, QTableWidgetItem(f"{item['last_data_lat']:.1f} ms" if item.get('last_data_lat', 0) > 0 else "—"))


class TimeAvgSSVEPTab(QWidget):
    """Time-Averaged SSVEP Power Spectrum.
    
    Accumulates FFT power spectra in 1-second non-overlapping windows
    during active trials (between trigger start and stop).  The cumulative
    average is plotted as Power vs Frequency, which suppresses broadband
    noise and sharpens narrow-band SSVEP peaks into prominent spikes.
    """
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)

        # ── Controls row ──────────────────────────────────────────
        ctrl = QHBoxLayout()
        ctrl.addWidget(QLabel("X Min (Hz):"))
        self.sp_xmin = QSpinBox(); self.sp_xmin.setRange(0, 125); self.sp_xmin.setValue(5)
        self.sp_xmin.valueChanged.connect(self._on_xrange)
        ctrl.addWidget(self.sp_xmin)

        ctrl.addWidget(QLabel("X Max (Hz):"))
        self.sp_xmax = QSpinBox(); self.sp_xmax.setRange(5, 125); self.sp_xmax.setValue(40)
        self.sp_xmax.valueChanged.connect(self._on_xrange)
        ctrl.addWidget(self.sp_xmax)

        self.cb_auto = QCheckBox("Autoscale Y")
        self.cb_auto.setChecked(True)
        ctrl.addWidget(self.cb_auto)

        ctrl.addWidget(QLabel(" Fixed Y:"))
        self.sp_ymax = QDoubleSpinBox()
        self.sp_ymax.setRange(0.001, 100000); self.sp_ymax.setValue(100)
        self.sp_ymax.setSingleStep(10)
        ctrl.addWidget(self.sp_ymax)

        ctrl.addSpacing(20)
        self.btn_reset = QPushButton("↺ Reset Accumulator")
        self.btn_reset.setStyleSheet(
            "background: #21262d; border: 1px solid #30363d; color: #c9d1d9; "
            "padding: 6px 14px; font-weight: bold;")
        self.btn_reset.clicked.connect(self._reset_accumulator)
        ctrl.addWidget(self.btn_reset)

        ctrl.addStretch()
        layout.addLayout(ctrl)

        # ── Status bar ─────────────────────────────────────────────
        status_row = QHBoxLayout()
        self.lbl_status = QLabel("⏸ Idle — waiting for trial")
        self.lbl_status.setStyleSheet("color: #8b949e; font-size: 10pt; font-weight: bold;")
        status_row.addWidget(self.lbl_status)

        self.lbl_windows = QLabel("Windows: 0")
        self.lbl_windows.setStyleSheet("color: #58a6ff; font-size: 10pt; font-weight: bold;")
        status_row.addWidget(self.lbl_windows)

        self.lbl_block = QLabel("Block: 0")
        self.lbl_block.setStyleSheet("color: #bc8cff; font-size: 10pt; font-weight: bold;")
        status_row.addWidget(self.lbl_block)
        status_row.addStretch()
        layout.addLayout(status_row)

        # ── Plot ───────────────────────────────────────────────────
        self.pw = pg.PlotWidget(title="Time-Averaged SSVEP Power Spectrum")
        self.pw.showGrid(x=True, y=True, alpha=0.3)
        self.pw.setXRange(5, 40, padding=0.01)
        self.pw.setLabel('bottom', 'Frequency', 'Hz')
        self.pw.setLabel('left', 'Averaged Power')
        self.pw.addLegend()
        layout.addWidget(self.pw, stretch=1)

        self.curves = []
        for i in range(NUM_CH):
            c = self.pw.plot(
                pen=pg.mkPen(CH_COLORS[i % len(CH_COLORS)], width=1.5),
                name=f"CH{i+1}")
            self.curves.append(c)

        # ── Channel selector ───────────────────────────────────────
        sa = QScrollArea()
        sa.setWidgetResizable(True)
        sa.setFixedHeight(80)
        sw = QWidget()
        sl = QFormLayout(sw)

        self.ch_checks = []
        row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0, 0, 0, 0)
        for i in range(NUM_CH):
            cb = QCheckBox(f"CH{i+1}")
            cb.setStyleSheet(f"color: {CH_COLORS[i % len(CH_COLORS)]}; font-weight: bold;")
            cb.setChecked(8 <= i < 16)
            self.ch_checks.append(cb)
            row_l.addWidget(cb)
            if (i + 1) % 8 == 0:
                sl.addRow(row_w)
                row_w = QWidget(); row_l = QHBoxLayout(row_w); row_l.setContentsMargins(0, 0, 0, 0)
        if NUM_CH % 8 != 0:
            sl.addRow(row_w)

        sa.setWidget(sw)
        layout.addWidget(sa)

    def _on_xrange(self, _v=None):
        self.pw.setXRange(self.sp_xmin.value(), self.sp_xmax.value(), padding=0.01)

    def _reset_accumulator(self):
        store.reset_tavg()

    def refresh(self):
        freqs, avg, count, is_active, block_id = store.get_tavg_spectrum()

        # Update status labels
        if is_active:
            self.lbl_status.setText("🔴 ACCUMULATING — trial in progress")
            self.lbl_status.setStyleSheet("color: #f78166; font-size: 10pt; font-weight: bold;")
        elif count > 0:
            self.lbl_status.setText(f"✅ Accumulated — {count} window{'s' if count != 1 else ''}")
            self.lbl_status.setStyleSheet("color: #56d364; font-size: 10pt; font-weight: bold;")
        else:
            self.lbl_status.setText("⏸ Idle — waiting for trial")
            self.lbl_status.setStyleSheet("color: #8b949e; font-size: 10pt; font-weight: bold;")

        self.lbl_windows.setText(f"Windows: {count}")
        self.lbl_block.setText(f"Block: {block_id}")

        # Plot
        xmin = self.sp_xmin.value()
        xmax = self.sp_xmax.value()
        peak = 0.0

        for i in range(NUM_CH):
            if not self.ch_checks[i].isChecked():
                self.curves[i].setData([], [])
                continue

            pwr = avg[i].copy()
            pwr[0] = 0  # suppress DC bin
            self.curves[i].setData(freqs, pwr)

            mask = (freqs >= xmin) & (freqs <= xmax)
            if np.any(mask):
                m = np.max(pwr[mask])
                if m > peak:
                    peak = m

        if self.cb_auto.isChecked() and peak > 1e-12:
            self.pw.setYRange(0, peak * 1.3, padding=0)
        elif not self.cb_auto.isChecked():
            self.pw.setYRange(0, self.sp_ymax.value(), padding=0)


class BCI_GUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("BCI Telemetry V2")
        self.resize(1400, 900)
        self.setStyleSheet("""
            QMainWindow, QWidget { background: #0d1117; color: #c9d1d9; font-family: 'Segoe UI', Arial, sans-serif; }
            QTabWidget::pane { border: 1px solid #30363d; background: #0d1117; border-radius: 4px; }
            QTabBar::tab { background: #161b22; color: #8b949e; padding: 12px 24px; font-size: 11pt; border: 1px solid #30363d; border-top-left-radius: 4px; border-top-right-radius: 4px; margin-right: 2px; }
            QTabBar::tab:selected { background: #1f2937; color: white; border-bottom: 3px solid #58a6ff; font-weight: bold; }
            QPushButton { background: #238636; border: 1px solid #2ea043; border-radius: 5px; color: white; padding: 6px 16px; font-weight: bold; font-size: 10pt; }
            QPushButton:hover { background: #2ea043; }
            QSpinBox, QDoubleSpinBox { background: #161b22; border: 1px solid #30363d; padding: 4px; color: white; border-radius: 4px; font-size: 10pt; }
            QCheckBox { spacing: 6px; font-size: 10pt; }
            QCheckBox::indicator { width: 18px; height: 18px; border: 1px solid #30363d; border-radius: 4px; background: #161b22; }
            QCheckBox::indicator:checked { background: #58a6ff; border: 1px solid #58a6ff; }
            QScrollArea { border: 1px solid #30363d; border-radius: 4px; background: #161b22; }
        """)

        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QHBoxLayout(central)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        self.sidebar = StyledSidebar()
        main_layout.addWidget(self.sidebar)

        tabs_container = QWidget()
        tabs_layout = QVBoxLayout(tabs_container)
        tabs_layout.setContentsMargins(15, 15, 15, 15)
        
        self.tabs = QTabWidget()
        self.tab_trigger = TriggerControlTab()
        self.tab_sig = SignalTab()
        self.tab_fft = FFTTab()
        self.tab_analysis = AnalysisSpectrumTab()
        self.tab_feat = FeaturesTab()
        self.tab_tavg = TimeAvgSSVEPTab()
        
        self.tabs.addTab(self.tab_sig, "📈 Multi-Channel Raw EEG")
        self.tabs.addTab(self.tab_fft, "📊 FFT Spectrum")
        self.tabs.addTab(self.tab_analysis, "🔎 Analysis Spectrum")
        self.tabs.addTab(self.tab_feat, "🧠 Features (Alpha/SSVEP/NF)")
        self.tabs.addTab(self.tab_trigger, "⚡ Trigger & Trial Controls")
        self.tabs.addTab(self.tab_tavg, "📐 Time-Averaged SSVEP")
        
        # Info note about logging
        info_log = QLabel("Note: CSV logging (features.csv, signals.csv, health.csv) is automatically running in the background while the ESP32 is connected.")
        info_log.setStyleSheet("color: #8b949e; font-style: italic;")
        
        tabs_layout.addWidget(self.tabs)
        tabs_layout.addWidget(info_log)
        main_layout.addWidget(tabs_container, stretch=1)

        self._tick = 0
        self.timer = QTimer()
        self.timer.timeout.connect(self._refresh)
        self.timer.start(40)
        
        self._wd = QTimer()
        self._wd.timeout.connect(self._watchdog)
        self._wd.start(2000)
        self._last_pkts = 0

    def _refresh(self):
        self._tick += 1
        if self._tick % 5 == 0: 
            self.sidebar.refresh()

        curr = self.tabs.currentWidget()
        if curr == self.tab_sig:
            self.tab_sig.refresh()
        elif curr == self.tab_fft and self._tick % 2 == 0:
            self.tab_fft.refresh()
        elif curr == self.tab_analysis and self._tick % 2 == 0:
            self.tab_analysis.refresh()
        elif curr == self.tab_feat and self._tick % 2 == 0:
            self.tab_feat.refresh()
        elif curr == self.tab_trigger:
            self.tab_trigger.refresh()
        elif curr == self.tab_tavg and self._tick % 2 == 0:
            self.tab_tavg.refresh()

    def _watchdog(self):
        pkts = store.pkt_count
        if pkts == self._last_pkts:
            store.connected = False
            store.stats.clear()
        self._last_pkts = pkts

    def closeEvent(self, event):
        super().closeEvent(event)


def main():
    app = QApplication(sys.argv)
    threading.Thread(target=_run_eeg_server, daemon=True).start()
    win = BCI_GUI()
    win.showMaximized()
    sys.exit(app.exec_())

if __name__ == '__main__':
    main()
