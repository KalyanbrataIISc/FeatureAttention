#!/usr/bin/env python3
# ============================================================================
#  eeg_tcp_server.py  —  receiver / parser / PARITY CHECK / NF fan-out
#
#  PC is the TCP SERVER; the ESP32 connects out to it (start this first).
#
#  Frames (LE [0xAA 0x55][type][seq:4][len:2][payload]):
#    0x00 HELLO    = config handshake
#    0x01 RAW      = 32 x int32 counts
#    0x02 PROC     = 32 x float32 filtered uV
#    0x03 ANALYSIS = 8 x float32 alpha band power
#    0x04 SSVEP    = powerA[8], snrA[8], powerB[8], snrB[8]
#    0x05 NF       = ami, smi (float32)   — board features
#
#  Parity: an independent copy of the firmware filter + analysis recomputes
#  everything from RAW and diffs against the board's frames (filter, alpha,
#  SSVEP power/SNR, and AMI/SMI). Automatic — watch the numbers sit near zero.
#
#  NF fan-out: the board's AMI/SMI go through rolling-median subtraction + tanh
#  (ported from the old buildNFPacket) and are emitted as the old game's exact
#  40-byte double[5] {alphaNF,-alphaNF,ssvepNF,-ssvepNF,seq} on UDP 5005.
#  
#  Run:
#   python eeg_tcp_server.py --log                      # participant: quiet, logs, fan-out
#   python eeg_tcp_server.py --log --debug              # verbose parity while logging
#   python eeg_tcp_server.py --log --ssvep-perchannel   # add the 32 SSVEP columns
#
#  Standard library only.
# ============================================================================
import socket, struct, time, math, bisect, threading, os, sys, collections, queue

# NumPy is optional but strongly recommended — install with: pip install numpy
# Without it the server falls back to pure-Python FIR (functional but ~50x slower).
try:
    import numpy as np
    _NUMPY = True
except ImportError:
    _NUMPY = False
    np = None

HOST, PORT = "0.0.0.0", 5005
MAGIC0, MAGIC1 = 0xAA, 0x55
TYPE_HELLO, TYPE_RAW, TYPE_PROC, TYPE_ANALYSIS, TYPE_SSVEP, TYPE_NF = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05
TYPE_HEALTH, TYPE_MARKER, TYPE_CMD, TYPE_ML = 0x06, 0x07, 0x08, 0x09
HDR = 9
RECV_TIMEOUT = 1.5   # was 5.0 — detect ESP reset quickly for fast reconnect

# Path where the game expects to read the binary stream
NF_FILE_PATH = r"d:\Projects\BCI\Latest-NF-Game\FeatureAttention-main\nf.txt"

# ── Filter identity (must match Filters.cpp) ─────────────────────────────────
FIR_TAPS = [
 -0.00099466,-0.00077284,-0.00042938,-0.00013094,-0.00015535,-0.00077160,-0.00199424,
 -0.00337223,-0.00405970,-0.00329292,-0.00108023,+0.00138682,+0.00209163,-0.00061387,
 -0.00656834,-0.01313540,-0.01612714,-0.01222944,-0.00170691,+0.01043901,+0.01617968,
 +0.00880215,-0.01215392,-0.03831770,-0.05446000,-0.04493830,-0.00189225,+0.06899984,
 +0.14865678,+0.21130672,+0.23504422,+0.21130672,+0.14865678,+0.06899984,-0.00189225,
 -0.04493830,-0.05446000,-0.03831770,-0.01215392,+0.00880215,+0.01617968,+0.01043901,
 -0.00170691,-0.01222944,-0.01612714,-0.01313540,-0.00656834,-0.00061387,+0.00209163,
 +0.00138682,-0.00108023,-0.00329292,-0.00405970,-0.00337223,-0.00199424,-0.00077160,
 -0.00015535,-0.00013094,-0.00042938,-0.00077284,-0.00099466]
FIR_LEN, DC_R = 61, 0.9995
RAW_CLAMP_UV, PROC_CLAMP_UV, GRADIENT_THRESH_UV = 500000.0, 50000.0, 5000.0

# [B] Pre-compute numpy tap array — used by ChanFilter when numpy is available.
_FIR_NP = np.array(FIR_TAPS, dtype=np.float64) if _NUMPY else None

# ── Analysis / SSVEP / NF identity (must match Config.h + Analysis/Neurofeedback) ──
ANALYSIS_CH, ANALYSIS_WIN, ANALYSIS_HOP = 8, 500, 25
ALPHA_LO, ALPHA_HI, ALPHA_STEP = 8.0, 13.0, 0.5
ANALYSIS_IDX = list(range(8, 16))
ALPHA_NB = int(round((ALPHA_HI - ALPHA_LO) / ALPHA_STEP)) + 1
HANN = [0.5 - 0.5 * math.cos(2 * math.pi * n / (ANALYSIS_WIN - 1)) for n in range(ANALYSIS_WIN)]

SSVEP_FA, SSVEP_FB = 14.0, 18.0
SSVEP_GUARD, SSVEP_NOISEB = 1, 4

AMP_EMA = 0.12                    # AMP_EMA_ALPHA_NF
SSVEP_POWER_FLOOR = 0.25             # SSVEP_POWER_FLOOR_UV2
HEMI_L = list(range(16))               # LEFT hemisphere montage indices
HEMI_R = list(range(16, 32))               # RIGHT hemisphere montage indices
NF_MEDIAN_WIN = 300
NF_AMI_SCALE, NF_SMI_SCALE = 1.0, 1.0
# NF fan-out: a SECOND TCP listener the game connects to as a client. The ESP
# uses the main TCP port (5005); the game gets its own port so the two roles
# never collide. Same 40-byte double[5] records, now streamed over TCP.
GAME_FANOUT_PORT = 5006
_nf_clients = []                              # connected game sockets
_nf_lock = threading.Lock()
CURRENT_CONN = None                           # ESP socket for upstream marker commands
CURRENT_RUN_DIR = None                        # Active run directory path
CURRENT_RUN_TS = None                         # Active run timestamp
GUI_RAW_CALLBACK = None                       # Callback for GUI integration (RAW data)
GUI_PROC_CALLBACK = None                      # Callback for GUI integration (PROC data)
GUI_STATS_CALLBACK = None                     # Callback for GUI telemetry stats
GUI_ALPHA_CALLBACK = None
GUI_SSVEP_CALLBACK = None
GUI_NF_CALLBACK = None
GUI_MARKER_CALLBACK = None
GUI_MARKER_SENT_CALLBACK = None               # Callback when a marker command is sent upstream

def send_marker_code(code: int) -> bool:
    """Send marker command frame (0x08) to the connected ESP32."""
    c = CURRENT_CONN
    if c is not None:
        try:
            pkt = struct.pack("<BBBIH", MAGIC0, MAGIC1, TYPE_CMD, 0, 2) + struct.pack("<H", int(code) & 0xFFFF)
            c.sendall(pkt)
            print(f"[MARKER] sent code {code}")
            if GUI_MARKER_SENT_CALLBACK is not None:
                try:
                    GUI_MARKER_SENT_CALLBACK(int(code))
                except Exception:
                    pass
            return True
        except Exception as e:
            print(f"[MARKER] send failed: {e}")
            return False
    return False

def _marker_stdin_loop():
    """Operator types a number + Enter -> send a marker command (0x08) upstream."""
    while True:
        try: line = sys.stdin.readline()
        except Exception: break
        if not line: break
        line = line.strip()
        if not line: continue
        try: code = int(line)
        except ValueError:
            print(f"[MARKER] type a number 0-999 (got '{line}')"); continue
        send_marker_code(code)

def _marker_udp_loop():
    """Listen for marker codes via UDP (e.g. from MATLAB's cog_send_triggers) and forward upstream."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 5007))
    while True:
        try:
            data, _ = sock.recvfrom(1024)
            code = int(data.decode("utf-8").strip())
            send_marker_code(code)
            print(f"[MARKER] Received via UDP from MATLAB, forwarded to ESP32: {code}")
        except Exception:
            pass

def _nf_accept_loop(listener):
    while True:
        try:
            c, a = listener.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with _nf_lock:
                _nf_clients.append(c)
            print(f"[NF] game client connected from {a[0]}:{a[1]}")
        except OSError:
            break

def nf_broadcast(pkt):
    """Send one 40-byte record to every connected game client; drop dead ones."""
    with _nf_lock:
        dead = []
        for c in _nf_clients:
            try:
                c.sendall(pkt)
            except OSError:
                dead.append(c)
        for c in dead:
            _nf_clients.remove(c)
            try: c.close()
            except OSError: pass

CFG = {"fs": 250, "num_ch": 32, "uv_per_count": 0.02235174}
DEBUG = False                       # --debug: per-second parity + verbose prints
LOG_SSVEP_PERCHANNEL = False        # --ssvep-perchannel: add 32 SSVEP columns


class CSVLogger:
    """PC-side logging (Stage 12). Three timestamped CSVs per connection:
       *_signals.csv  — per sample: seq + 32 filtered uV (PROC over WiFi)
       *_features.csv — per hop:    seq, marker, ami, smi, alphaNF, ssvepNF,
                                    alpha[8], powerA/B[8], snrA/B[8]
       *_health.csv   — ~1 Hz + marker events: board_ms, drops, pc_gaps, heap, marker
       (RAW is archived board-side on SD, not on the PC.)
    """
    def __init__(self, run_dir, ts):
        os.makedirs(run_dir, exist_ok=True)
        self.raw_log = open(os.path.join(run_dir, f"eeg_{ts}_raw.csv"), "w", buffering=1 << 16)
        self.sig  = open(os.path.join(run_dir, f"eeg_{ts}_signals.csv"),  "w", buffering=1 << 16)
        self.feat = open(os.path.join(run_dir, f"eeg_{ts}_features.csv"), "w", buffering=1 << 16)
        self.hlth = open(os.path.join(run_dir, f"eeg_{ts}_health.csv"),   "w", buffering=1)
        self.raw_log.write("seq," + ",".join(f"raw{c+1}" for c in range(32)) + ",marker\n")
        self.sig.write("seq," + ",".join(f"filt{c+1}" for c in range(32)) + ",marker\n")
        # UPDATED: Replaced 'ami', 'smi' with 'smi_14gt18' and 'smi_18gt14' to match new firmware payload.
        # Kept the legacy columns (alphaNF, etc.) with default 0s to avoid breaking MATLAB plotting scripts.
        cols = ["seq", "marker", "smi_14gt18", "smi_18gt14", "smi_14gt18_shaped", "smi_18gt14_shaped", "alphaNF", "ssvepNF",
                "alphaLeft", "alphaRight", "ssvepRight14", "ssvepLeft18"]   # aggregates
        cols += [f"alpha{c+1}" for c in range(8)]                            # alpha per-ch (always)
        if LOG_SSVEP_PERCHANNEL:                                            # SSVEP per-ch (optional)
            cols += [f"powerA{c+1}" for c in range(8)] + [f"powerB{c+1}" for c in range(8)]
            cols += [f"snrA{c+1}"   for c in range(8)] + [f"snrB{c+1}"   for c in range(8)]
        self.feat.write(",".join(cols) + "\n")
        # Centralised loss/health telemetry — every packet-loss category in one row:
        #   board_drops : ring-full drops on the board (Transport dropCount)
        #   pc_gaps     : sequence gaps seen at the PC (board skipped a seq / reconnect)
        #   board_bad   : bad SPI-status frames on the board (cumulative)
        #   board_miss  : missed DRDY events / DSP overruns on the board (cumulative)
        #   board_dspmax: peak DSP-burst microseconds that second
        #   srv_bad     : malformed frames rejected by THIS server (cumulative)
        self.hlth.write("wall_clock,board_ms,seq,board_drops,pc_gaps,board_bad,board_miss,"
                        "board_dspmax_us,srv_bad,free_heap,marker,event\n")
        print(f"[LOG] -> {self.raw_log.name}")
        print(f"[LOG] -> {self.sig.name}")
        print(f"[LOG] -> {self.feat.name}")
        print(f"[LOG] -> {self.hlth.name}")

    def raw(self, seq, counts, marker=0):
        self.raw_log.write(f"{seq}," + ",".join(str(x) for x in counts) + f",{marker}\n")

    def signals(self, seq, filt, marker=0):
        self.sig.write(f"{seq}," + ",".join(f"{x:.6f}" for x in filt) + f",{marker}\n")

    # UPDATED: Changed parameter names ami -> smi_14gt18, smi -> smi_18gt14
    def features(self, seq, marker, smi_14gt18, smi_18gt14, smi_14gt18_shaped, smi_18gt14_shaped, aNF, sNF, alpha, ssvep, aggr):
        zero8 = [0.0] * 8
        a = list(alpha) if alpha is not None else zero8
        pA, sA, pB, sB = ssvep if ssvep is not None else (zero8, zero8, zero8, zero8)
        aL, aR, sR14, sL18 = aggr
        vals = [str(marker), f"{smi_14gt18:.6f}", f"{smi_18gt14:.6f}", f"{smi_14gt18_shaped:.6f}", f"{smi_18gt14_shaped:.6f}", f"{aNF:.6f}", f"{sNF:.6f}",
                f"{aL:.6f}", f"{aR:.6f}", f"{sR14:.6f}", f"{sL18:.6f}"]
        vals += [f"{x:.6f}" for x in a]
        if LOG_SSVEP_PERCHANNEL:
            vals += [f"{x:.6f}" for x in pA] + [f"{x:.6f}" for x in pB] \
                  + [f"{x:.6f}" for x in sA] + [f"{x:.6f}" for x in sB]
        self.feat.write(f"{seq}," + ",".join(vals) + "\n")

    def health(self, board_ms, seq, board_drops, pc_gaps, heap, marker, event="",
               board_bad=0, board_miss=0, board_dspmax=0, srv_bad=0):
        self.hlth.write(f"{time.strftime('%H:%M:%S')},{board_ms},{seq},{board_drops},"
                        f"{pc_gaps},{board_bad},{board_miss},{board_dspmax},{srv_bad},"
                        f"{heap},{marker},{event}\n")

    def close(self):
        for f in (self.raw_log, self.sig, self.feat, self.hlth):
            try: f.close()
            except Exception: pass


# [B] ChanFilter with numpy FIR fast path.
class ChanFilter:
    """Per-channel DC-blocker + 61-tap FIR filter, mirroring Filters.cpp.

    When numpy is available, _process() uses np.dot() on the pre-built tap array
    (_FIR_NP) and a numpy circular buffer — roughly 50x faster than the Python
    scalar loop for 61 taps × 32 channels × 500 SPS = ~1M multiply-adds/sec.
    Falls back to the pure-Python loop transparently if numpy is not installed.
    """
    __slots__ = ("buf", "head", "dcx", "dcy", "prevUV")

    def __init__(self):
        self.buf  = np.zeros(FIR_LEN, dtype=np.float64) if _NUMPY else [0.0] * FIR_LEN
        self.head = 0
        self.dcx = 0.0; self.dcy = 0.0; self.prevUV = 0.0

    def _process(self, x):
        dco = x - self.dcx + DC_R * self.dcy
        self.dcx = x; self.dcy = dco
        self.buf[self.head] = dco
        self.head = (self.head + 1) % FIR_LEN
        if _NUMPY:
            h = self.head
            return float(np.dot(_FIR_NP, np.concatenate((self.buf[h:], self.buf[:h]))))
        else:
            y = 0.0
            for i in range(FIR_LEN):
                y += FIR_TAPS[i] * self.buf[(self.head + i) % FIR_LEN]
            return y

    def condition(self, raw, warmed):
        if raw >  RAW_CLAMP_UV: raw =  RAW_CLAMP_UV
        if raw < -RAW_CLAMP_UV: raw = -RAW_CLAMP_UV
        glitch = warmed and (abs(raw - self.prevUV) > GRADIENT_THRESH_UV)
        p = self._process(self.prevUV if glitch else raw)
        if p >  PROC_CLAMP_UV: p =  PROC_CLAMP_UV
        if p < -PROC_CLAMP_UV: p = -PROC_CLAMP_UV
        self.prevUV = (0.9 * self.prevUV + 0.1 * raw) if glitch else raw
        return p


def make_alpha_coeffs(fs):
    return [2.0 * math.cos(2 * math.pi * (ALPHA_LO + b * ALPHA_STEP) / fs) for b in range(ALPHA_NB)]


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        try: chunk = sock.recv(n - len(buf))
        except (socket.timeout, OSError): return None
        if not chunk: return None
        buf.extend(chunk)
    return bytes(buf)


def resync(sock):
    window = bytearray()
    while True:
        try: b = sock.recv(1)
        except (socket.timeout, OSError): return False
        if not b: return False
        window.extend(b)
        if len(window) > 2: window = window[-2:]
        if len(window) == 2 and window[0] == MAGIC0 and window[1] == MAGIC1: return True


def parse_hello(payload):
    if len(payload) < 14: print("[!] HELLO too short"); return
    fs, nch, nchips = struct.unpack_from("<HBB", payload, 0)
    uvpc = struct.unpack_from("<f", payload, 4)[0]
    fir_len = struct.unpack_from("<H", payload, 8)[0]
    dcr = struct.unpack_from("<f", payload, 10)[0]
    CFG["fs"], CFG["num_ch"], CFG["uv_per_count"] = fs, nch, uvpc
    print(f"[HELLO] fs={fs} ch={nch} chips={nchips} uv/count={uvpc:.8f} fir_len={fir_len} dcR={dcr:.4f}")
    if fir_len != FIR_LEN: print(f"[!!] FIR length mismatch board={fir_len} server={FIR_LEN}")
    if abs(dcr - DC_R) > 1e-6: print(f"[!!] DC_R mismatch board={dcr} server={DC_R}")
    # Montage descriptor (optional, appended): analysis_ch + hemisphere maps.
    if len(payload) >= 17:
        a_ch, hl_n, hr_n = payload[14], payload[15], payload[16]
        off = 17
        hemi_l = list(payload[off:off + hl_n]); off += hl_n
        hemi_r = list(payload[off:off + hr_n]); off += hr_n
        CFG["analysis_ch"] = a_ch
        CFG["hemi_l"] = hemi_l
        CFG["hemi_r"] = hemi_r
        print(f"[MONTAGE] analysis_ch={a_ch}  HEMI_L={hemi_l}  HEMI_R={hemi_r}")
        if a_ch != ANALYSIS_CH:
            print(f"[!!] MONTAGE size mismatch: board analysis_ch={a_ch} but server "
                  f"ANALYSIS_CH={ANALYSIS_CH}. Update ANALYSIS_CH in the server to {a_ch} "
                  f"and restart — feature parsing/parity will be wrong until you do.")


def handle(conn, addr, logdir=None):
    print(f"[+] ESP32 connected from {addr[0]}:{addr[1]}")
    global CURRENT_CONN, CURRENT_RUN_DIR, CURRENT_RUN_TS
    CURRENT_CONN = conn
    if logdir:
        ts = time.strftime("%Y%m%d_%H%M%S")
        CURRENT_RUN_TS = ts
        CURRENT_RUN_DIR = os.path.join(logdir, f"eeg_{ts}")
        logger = CSVLogger(CURRENT_RUN_DIR, ts)
    else:
        CURRENT_RUN_DIR = None
        CURRENT_RUN_TS = None
        logger = None
    log_alpha = {}; log_ssvep = {}                   # per-seq buffers for logging
    raw_seen = False                                 # True once RAW arrives (validation)
    current_marker = 0
    board_ms = board_drops = free_heap = 0
    board_bad = board_miss = board_dspmax = 0   # from the board's extended HEALTH frame
    nch = CFG["num_ch"]
    filts = [ChanFilter() for _ in range(nch)]
    warmed = False

    acoeff = make_alpha_coeffs(CFG["fs"])
    awin = [[0.0] * ANALYSIS_WIN for _ in range(ANALYSIS_CH)]
    ahead = 0
    anTotal = 0

    def server_alpha(ch, head):
        m = sum(awin[ch]) / ANALYSIS_WIN
        tot = 0.0
        for b in range(ALPHA_NB):
            c = acoeff[b]; s1 = s2 = 0.0
            for i in range(ANALYSIS_WIN):
                x = (awin[ch][(head + i) % ANALYSIS_WIN] - m) * HANN[i]
                s0 = x + c * s1 - s2; s2 = s1; s1 = s0
            tot += s1 * s1 + s2 * s2 - c * s1 * s2
        return tot / ANALYSIS_WIN

    def s_gp(ch, mean, f, head):
        coeff = 2.0 * math.cos(2 * math.pi * f / CFG["fs"]); s1 = s2 = 0.0
        for i in range(ANALYSIS_WIN):
            x = (awin[ch][(head + i) % ANALYSIS_WIN] - mean) * HANN[i]
            s0 = x + coeff * s1 - s2; s2 = s1; s1 = s0
        return s1 * s1 + s2 * s2 - coeff * s1 * s2

    def s_pow(ch, mean, f, head):
        return s_gp(ch, mean, f, head)

    def s_target(ch, mean, f, head):
        p = s_gp(ch, mean, f, head); binHz = CFG["fs"] / ANALYSIS_WIN
        noise = 0.0; cnt = 0
        for k in range(1, SSVEP_NOISEB + 1):
            off = (SSVEP_GUARD + k) * binHz
            noise += s_gp(ch, mean, f - off, head); noise += s_gp(ch, mean, f + off, head); cnt += 2
        noise /= cnt
        return p, (p / noise if noise > 1e-12 else 0.0)

    def server_ssvep(head):
        pA=[0.0]*ANALYSIS_CH; sA=[0.0]*ANALYSIS_CH; pB=[0.0]*ANALYSIS_CH; sB=[0.0]*ANALYSIS_CH
        for c in range(ANALYSIS_CH):
            m = sum(awin[c]) / ANALYSIS_WIN
            pA[c], sA[c] = s_target(c, m, SSVEP_FA, head)
            pB[c], sB[c] = s_target(c, m, SSVEP_FB, head)
        return (pA, sA, pB, sB)

    # power (old goertzel_amp) = p * 16 / N^2
    def s_power(ch, f, head):
        m = sum(awin[ch]) / ANALYSIS_WIN
        p = s_gp(ch, m, f, head)
        return max(p, 0.0) * 16.0 / (ANALYSIS_WIN * ANALYSIS_WIN)

    # server AMI/SMI — mirrors Neurofeedback.cpp (incl. power EMA on 14/18)
    s_powerA = [0.0]*ANALYSIS_CH; s_powerB = [0.0]*ANALYSIS_CH; s_powerInit = [False]*ANALYSIS_CH
    def server_ami_smi(alpha_vec, head):
        for ch in range(ANALYSIS_CH):
            rA = s_power(ch, SSVEP_FA, head); rB = s_power(ch, SSVEP_FB, head)
            if not s_powerInit[ch]: s_powerA[ch]=rA; s_powerB[ch]=rB; s_powerInit[ch]=True
            else: s_powerA[ch]+=AMP_EMA*(rA-s_powerA[ch]); s_powerB[ch]+=AMP_EMA*(rB-s_powerB[ch])
        
        s14=0.0; n14=0
        for ch in range(ANALYSIS_CH):
            ref=max((s_power(ch,SSVEP_FA-1,head)+s_power(ch,SSVEP_FA+1,head))*0.5, SSVEP_POWER_FLOOR)
            if s_powerA[ch] > 0: s14+=s_powerA[ch]/ref; n14+=1
        s18=0.0; n18=0
        for ch in range(ANALYSIS_CH):
            ref=max((s_power(ch,SSVEP_FB-1,head)+s_power(ch,SSVEP_FB+1,head))*0.5, SSVEP_POWER_FLOOR)
            if s_powerB[ch] > 0: s18+=s_powerB[ch]/ref; n18+=1
        
        m14=s14/n14 if n14 else 1.0; m18=s18/n18 if n18 else 1.0
        smi_14gt18 = math.log(m14+1e-10) - math.log(m18+1e-10)
        smi_18gt14 = math.log(m18+1e-10) - math.log(m14+1e-10)
        return smi_14gt18, smi_18gt14

    pending_filt = {}
    board_alpha = {}; srv_alpha_map = {}
    board_ssvep = {}; srv_ssvep = {}
    board_nf = {}; srv_nf = {}

    features_active = False       # True once ANALYSIS/SSVEP/NF frames arrive (Stage 8+)
    last_sample_seq = None        # Track last sample sequence number
    current_sample_seq = None     # Current sample sequence number
    frames = 0
    gaps = {TYPE_RAW: 0, TYPE_PROC: 0}
    expected = {TYPE_RAW: None, TYPE_PROC: None}
    bad = 0
    f_matched = 0; f_max = 0.0; f_max_ch = 0; f_ch_max = [0.0] * nch
    a_recv = a_matched = 0; a_relmax = 0.0; a_relmax_ch = 0; a_ch_relmax = [0.0]*ANALYSIS_CH
    sv_recv = sv_matched = 0; sv_p_relmax = sv_s_relmax = 0.0; sv_p_ch = [0.0]*ANALYSIS_CH; sv_s_ch = [0.0]*ANALYSIS_CH
    nf_recv = nf_matched = 0; nf_ami_max = nf_smi_max = 0.0
    last_perf = time.perf_counter()
    last_nf_write = time.time()

    def match_alpha(seq):
        nonlocal a_matched, a_relmax, a_relmax_ch
        b = board_alpha.get(seq); sv = srv_alpha_map.get(seq)
        if b is None or sv is None: return
        board_alpha.pop(seq, None); srv_alpha_map.pop(seq, None)
        a_matched += 1
        for c in range(ANALYSIS_CH):
            d = abs(b[c] - sv[c]); rel = d/abs(b[c]) if abs(b[c]) > 1e-6 else d
            if rel > a_relmax: a_relmax, a_relmax_ch = rel, c
            if rel > a_ch_relmax[c]: a_ch_relmax[c] = rel

    def match_ssvep(seq):
        nonlocal sv_matched, sv_p_relmax, sv_s_relmax
        b = board_ssvep.get(seq); sv = srv_ssvep.get(seq)
        if b is None or sv is None: return
        board_ssvep.pop(seq, None); srv_ssvep.pop(seq, None)
        sv_matched += 1
        (bpA, bsA, bpB, bsB) = b; (spA, ssA, spB, ssB) = sv
        for c in range(ANALYSIS_CH):
            for bp, sp in ((bpA[c], spA[c]), (bpB[c], spB[c])):
                if abs(bp) > 1e-6:
                    r = abs(bp - sp) / abs(bp)
                    if r > sv_p_relmax: sv_p_relmax = r
                    if r > sv_p_ch[c]: sv_p_ch[c] = r
            for bs, ss in ((bsA[c], ssA[c]), (bsB[c], ssB[c])):
                if abs(bs) > 1e-6:
                    r = abs(bs - ss) / abs(bs)
                    if r > sv_s_relmax: sv_s_relmax = r
                    if r > sv_s_ch[c]: sv_s_ch[c] = r

    def match_nf(seq):
        nonlocal nf_matched, nf_ami_max, nf_smi_max
        b = board_nf.get(seq); sv = srv_nf.get(seq)
        if b is None or sv is None: return
        board_nf.pop(seq, None); srv_nf.pop(seq, None)
        nf_matched += 1
        nf_ami_max = max(nf_ami_max, abs(b[0]-sv[0]))
        nf_smi_max = max(nf_smi_max, abs(b[1]-sv[1]))

    # ── [A] Recv / process split ──────────────────────────────────────────────
    #  Problem (original): recv_exact() + frame processing ran inline on one thread.
    #  The pure-Python FIR (32 ch × 61 taps) and per-hop Goertzel burst blocked
    #  socket reads for ~200-400 µs / sample, causing TCP back-pressure the ESP32
    #  felt as send-buffer stalls → unsmooth / bursty throughput at the board.
    #
    #  Fix: _recv_loop() runs on a dedicated thread — its only job is to read bytes
    #  and enqueue (ftype, seq, payload) tuples. handle() drains frame_q and runs
    #  all heavy computation without ever blocking the socket read path.
    frame_q = queue.Queue(maxsize=4096)   # (ftype, seq, payload) tuples; None = sentinel

    def _recv_loop():
        """Thin receive thread: reads bytes, never processes. Puts None on disconnect."""
        if not resync(conn):
            print("[-] disconnected during resync"); frame_q.put(None); return
        first = True
        while True:
            if first:
                rest = recv_exact(conn, HDR - 2)
                if rest is None: frame_q.put(None); return
                hdr = bytes([MAGIC0, MAGIC1]) + rest; first = False
            else:
                hdr = recv_exact(conn, HDR)
                if hdr is None: frame_q.put(None); return
                if hdr[0] != MAGIC0 or hdr[1] != MAGIC1:
                    if not resync(conn): frame_q.put(None); return
                    first = True; continue
            ftype   = hdr[2]
            seq     = struct.unpack_from("<I", hdr, 3)[0]
            plen    = struct.unpack_from("<H", hdr, 7)[0]
            payload = recv_exact(conn, plen)
            if payload is None: frame_q.put(None); return
            try:
                frame_q.put((ftype, seq, payload), timeout=2.0)
            except queue.Full:
                print("[!] frame_q full — process thread overloaded; dropping connection")
                frame_q.put(None); return

    recv_t = threading.Thread(target=_recv_loop, daemon=True, name=f"recv-{addr[0]}")
    recv_t.start()

    # Process frames; all CPU-heavy work (FIR filter, Goertzel, logging) lives here.
    # The recv thread stays thin and never waits on computation.
    while True:
        try:
            item = frame_q.get(timeout=3.0)
        except queue.Empty:
            if not recv_t.is_alive():
                break       # recv thread died without putting a sentinel
            continue        # spurious timeout; keep waiting
        if item is None:
            break           # recv thread sent disconnect sentinel
        ftype, seq, payload = item
        plen = len(payload)

        if ftype == TYPE_HELLO:
            parse_hello(payload)
            acoeff = make_alpha_coeffs(CFG["fs"])
            if CFG["num_ch"] != nch:
                nch = CFG["num_ch"]; filts = [ChanFilter() for _ in range(nch)]; f_ch_max = [0.0]*nch
            continue

        if ftype in expected:
            if expected[ftype] is not None and seq != expected[ftype]:
                gaps[ftype] += (seq - expected[ftype]) & 0xFFFFFFFF
            expected[ftype] = (seq + 1) & 0xFFFFFFFF

        uvpc = CFG["uv_per_count"]

        if ftype == TYPE_RAW and (plen == nch * 4 or plen == nch * 4 + 2):
            current_sample_seq = seq
            counts = struct.unpack_from(f"<{nch}i", payload, 0)
            sample_marker = struct.unpack_from("<H", payload, nch * 4)[0] if plen >= nch * 4 + 2 else current_marker
            if logger is not None:
                logger.raw(seq, counts, sample_marker)
            if GUI_RAW_CALLBACK: GUI_RAW_CALLBACK(counts, seq)
            raw_seen = True
            sfilt = [filts[c].condition(counts[c] * uvpc, warmed) for c in range(nch)]
            warmed = True
            pending_filt[seq] = sfilt
            if len(pending_filt) > 8: pending_filt.pop(next(iter(pending_filt)))

            # Only run Goertzel DFT matrix if feature frames are active (Stage 8+)
            if features_active:
                for c in range(ANALYSIS_CH):
                    awin[c][ahead] = sfilt[ANALYSIS_IDX[c]]
                ahead = (ahead + 1) % ANALYSIS_WIN
                anTotal += 1
                if anTotal >= ANALYSIS_WIN and (anTotal - ANALYSIS_WIN) % ANALYSIS_HOP == 0:
                    salpha = [server_alpha(c, ahead) for c in range(ANALYSIS_CH)]
                    srv_alpha_map[seq] = salpha
                    if len(srv_alpha_map) > 128: srv_alpha_map.pop(next(iter(srv_alpha_map)))
                    match_alpha(seq)
                    srv_ssvep[seq] = server_ssvep(ahead)
                    if len(srv_ssvep) > 128: srv_ssvep.pop(next(iter(srv_ssvep)))
                    match_ssvep(seq)
                    srv_nf[seq] = server_ami_smi(salpha, ahead)
                    if len(srv_nf) > 128: srv_nf.pop(next(iter(srv_nf)))
                    match_nf(seq)

        elif ftype == TYPE_PROC and (plen == nch * 4 or plen == nch * 4 + 2):
            current_sample_seq = seq
            board = struct.unpack_from(f"<{nch}f", payload, 0)
            sample_marker = struct.unpack_from("<H", payload, nch * 4)[0] if plen >= nch * 4 + 2 else current_marker
            if GUI_PROC_CALLBACK: GUI_PROC_CALLBACK(board, seq)
            if logger is not None:
                logger.signals(seq, board, sample_marker)
            sfilt = pending_filt.pop(seq, None)
            if sfilt is not None:
                f_matched += 1
                for c in range(nch):
                    d = abs(board[c] - sfilt[c])
                    if d > f_max: f_max, f_max_ch = d, c
                    if d > f_ch_max[c]: f_ch_max[c] = d

        elif ftype == TYPE_ANALYSIS and plen == ANALYSIS_CH * 4:
            features_active = True
            a_recv += 1
            board_alpha[seq] = struct.unpack_from(f"<{ANALYSIS_CH}f", payload, 0)
            if GUI_ALPHA_CALLBACK: GUI_ALPHA_CALLBACK(board_alpha[seq], seq)
            if logger is not None:
                log_alpha[seq] = board_alpha[seq]
                if len(log_alpha) > 256: log_alpha.pop(next(iter(log_alpha)))
            if len(board_alpha) > 128: board_alpha.pop(next(iter(board_alpha)))
            match_alpha(seq)

        elif ftype == TYPE_SSVEP and plen == ANALYSIS_CH * 4 * 4:
            features_active = True
            sv_recv += 1
            v = struct.unpack_from(f"<{ANALYSIS_CH*4}f", payload, 0)
            board_ssvep[seq] = (v[0:8], v[8:16], v[16:24], v[24:32])
            if GUI_SSVEP_CALLBACK: GUI_SSVEP_CALLBACK(board_ssvep[seq], seq)
            if logger is not None:
                log_ssvep[seq] = board_ssvep[seq]
                if len(log_ssvep) > 256: log_ssvep.pop(next(iter(log_ssvep)))
            if len(board_ssvep) > 128: board_ssvep.pop(next(iter(board_ssvep)))
            match_ssvep(seq)

        elif ftype == TYPE_NF and plen in (12, 14, 22):
            features_active = True
            if plen >= 22:
                smi_14gt18, smi_18gt14, smi_14gt18_shaped, smi_18gt14_shaped, sampleCount = struct.unpack_from("<ffffi", payload, 0)
                nf_marker = struct.unpack_from("<H", payload, 20)[0]
            else:
                smi_14gt18, smi_18gt14, sampleCount = struct.unpack_from("<ffi", payload, 0)
                smi_14gt18_shaped = smi_18gt14_shaped = 0.0
                nf_marker = struct.unpack_from("<H", payload, 12)[0] if plen == 14 else current_marker
            
            board_nf[seq] = (smi_14gt18, smi_18gt14)
            if GUI_NF_CALLBACK: GUI_NF_CALLBACK(board_nf[seq], seq)
            if len(board_nf) > 128: board_nf.pop(next(iter(board_nf)))
            nf_recv += 1
            match_nf(seq)
            
            # ADDED: Restore logging for features.csv. 
            # We pop the buffered alpha and ssvep data for this sequence and pass it to the logger.
            # We pass 0.0 for the legacy aggregate fields (alphaNF, ssvepNF, aL, aR, sR14, sL18) 
            # because they were removed from the firmware to save bandwidth, but the CSV structure keeps them.
            a = log_alpha.pop(seq, None)
            sv = log_ssvep.pop(seq, None)
            
            # Default to 0 in the GUI if these packets weren't sent/received for this seq
            if a is None and GUI_ALPHA_CALLBACK:
                GUI_ALPHA_CALLBACK([0.0]*8, seq)
            if sv is None and GUI_SSVEP_CALLBACK:
                GUI_SSVEP_CALLBACK(([0.0]*8, [0.0]*8, [0.0]*8, [0.0]*8), seq)
 
            if logger is not None:
                logger.features(seq, nf_marker, smi_14gt18, smi_18gt14, smi_14gt18_shaped, smi_18gt14_shaped, 0.0, 0.0, a, sv, (0.0, 0.0, 0.0, 0.0))
            
            # Enforce 10Hz (100ms) cadence to nf.txt for smooth gameplay
            now_nf = time.time()
            if now_nf - last_nf_write >= 0.1:
                try:
                    with open(NF_FILE_PATH, "wb") as f:
                        f.write(struct.pack("<3d", float(smi_14gt18_shaped), float(smi_18gt14_shaped), float(sampleCount)))
                    last_nf_write = now_nf
                except Exception:
                    pass # Ignore if MATLAB is locking the file              except Exception:
                    pass # Ignore if MATLAB is locking the file
        elif ftype == TYPE_HEALTH and plen in (14, 26):
            # 14-byte = legacy firmware (ms, drops, heap, marker).
            # 26-byte = extended firmware, adds bad / miss / dspMaxUs so every
            # board-side loss counter reaches the PC instead of only the serial
            # console. We accept both so an old board still logs.
            board_ms, board_drops, free_heap = struct.unpack_from("<III", payload, 0)
            current_marker = struct.unpack_from("<H", payload, 12)[0]
            if plen == 26:
                board_bad, board_miss, board_dspmax = struct.unpack_from("<III", payload, 14)
            if logger is not None:
                logger.health(board_ms, seq, board_drops, gaps[TYPE_RAW] + gaps[TYPE_PROC],
                              free_heap, current_marker,
                              board_bad=board_bad, board_miss=board_miss,
                              board_dspmax=board_dspmax, srv_bad=bad)

        elif ftype == TYPE_MARKER and plen == 2:
            current_marker = struct.unpack_from("<H", payload, 0)[0]
            print(f"[MARKER] board latched {current_marker} @ seq {seq}")
            if GUI_MARKER_CALLBACK:
                GUI_MARKER_CALLBACK(current_marker, seq)
            if logger is not None:
                logger.health(board_ms, seq, board_drops, gaps[TYPE_RAW] + gaps[TYPE_PROC],
                              free_heap, current_marker, event="marker",
                              board_bad=board_bad, board_miss=board_miss,
                              board_dspmax=board_dspmax, srv_bad=bad)
        elif ftype == TYPE_ML and plen == 9:
            pred_class, confidence, latency_ms = struct.unpack_from("<Bff", payload, 0)
            print(f"[ML] seq={seq} class={pred_class} conf={confidence:.3f} latency={latency_ms:.2f}ms")
        else:
            bad += 1

        frames += 1
        now_perf = time.perf_counter()
        dt = now_perf - last_perf
        if dt >= 1.0:
            wire_fps = int(round(frames / dt))
            # True Hardware SPS computed directly from monotonic ADC sequence counter
            if last_sample_seq is not None and current_sample_seq is not None and current_sample_seq >= last_sample_seq:
                seq_delta = (current_sample_seq - last_sample_seq) & 0xFFFFFFFF
                sps = int(round(seq_delta / dt))
            else:
                sps = wire_fps
            last_sample_seq = current_sample_seq
            last_perf = now_perf

            if GUI_STATS_CALLBACK:
                GUI_STATS_CALLBACK({
                    "frames": sps, "gaps_r": gaps[TYPE_RAW], "gaps_p": gaps[TYPE_PROC],
                    "bad": bad, "f_max": f_max, "a_relmax": a_relmax, "a_m": a_matched,
                    "sv_p_relmax": sv_p_relmax, "sv_m": sv_matched, "nf_ami_max": nf_ami_max,
                    "nf_smi_max": nf_smi_max, "nf_m": nf_matched, "board_drops": board_drops,
                    "heap": free_heap, "marker": current_marker,
                    # centralised loss telemetry (all five categories in one dict)
                    "board_bad": board_bad, "board_miss": board_miss,
                    "board_dspmax": board_dspmax, "srv_bad": bad,
                })

            disp_seq = current_sample_seq if current_sample_seq is not None else seq
            if DEBUG:
                print(f"[METRICS] t={time.strftime('%H:%M:%S')} (seq={disp_seq})")
                print(f"  • Hardware Sampling Rate : {sps} SPS")
                print(f"  • Wire Throughput        : {wire_fps} frames/sec")
                print(f"  • Packet Gaps            : RAW={gaps[TYPE_RAW]}, PROC={gaps[TYPE_PROC]}, Bad={bad}")
                print(f"  • Filter Parity          : worst |D| = {f_max:.1e} uV")
                print(f"  • Alpha Parity           : rel|D| = {a_relmax:.1e} (matched={a_matched})")
                print(f"  • SSVEP Parity           : P rel|D| = {sv_p_relmax:.1e} (matched={sv_matched})")
                print(f"  • NF Parity              : |dAMI| = {nf_ami_max:.1e}, |dSMI| = {nf_smi_max:.1e} (matched={nf_matched})")
                print(f"  • Board Telemetry        : Heap={free_heap} B, Marker={current_marker}")
                print(f"  • Packet Loss            : Board Drops={board_drops}, Board Missed DRDY={board_miss}, Board Bad={board_bad}, PC Gaps={gaps[TYPE_RAW] + gaps[TYPE_PROC]}")
                print()
            else:
                print(f"[LOSS] board_drops={board_drops} pc_gaps={gaps[TYPE_RAW] + gaps[TYPE_PROC]} board_bad={board_bad} board_miss={board_miss} dspMax={board_dspmax}us srv_bad={bad}")

            frames = 0; f_matched = a_matched = a_recv = 0; f_max = a_relmax = 0.0
            sv_matched = sv_recv = 0; sv_p_relmax = sv_s_relmax = 0.0
            nf_matched = nf_recv = 0; nf_ami_max = nf_smi_max = 0.0

    recv_t.join(timeout=1.0)
    if logger is not None: logger.close()
    CURRENT_CONN = None
    CURRENT_RUN_DIR = None
    CURRENT_RUN_TS = None
    print(f"[-] {addr[0]} disconnected (gaps r={gaps[TYPE_RAW]}, p={gaps[TYPE_PROC]}, bad={bad})")
    fw = max(f_ch_max) if f_ch_max else 0.0
    aw = max(a_ch_relmax) if a_ch_relmax else 0.0
    pw = max(sv_p_ch) if sv_p_ch else 0.0
    sw = max(sv_s_ch) if sv_s_ch else 0.0
    if raw_seen and DEBUG:
        print(f"    filter parity — worst |D|    = {fw:.3e} uV")
        print(f"    alpha  parity — worst rel|D| = {aw:.3e}")
        print(f"    ssvep power   — worst rel|D| = {pw:.3e}   ssvep SNR — worst rel|D| = {sw:.3e}")
        print(f"    nf AMI parity — worst |D|    = {nf_ami_max:.3e}   nf SMI parity — worst |D| = {nf_smi_max:.3e}")
        ok = (aw < 1e-3) and (pw < 1e-3) and (sw < 1e-2) and (nf_ami_max < 1e-3) and (nf_smi_max < 1e-2)
        print(f"    -> {'PASS (board==server)' if ok else 'CHECK — see above'}")
    else:
        print("    -> participant mode (no RAW streamed): logging + NF fan-out only, parity N/A")


def main():
    global DEBUG, LOG_SSVEP_PERCHANNEL
    logdir = None
    if "--log" in sys.argv:
        logdir = "logs"
        if "--logdir" in sys.argv:
            logdir = sys.argv[sys.argv.index("--logdir") + 1]
    if "--debug" in sys.argv:            DEBUG = True
    if "--ssvep-perchannel" in sys.argv: LOG_SSVEP_PERCHANNEL = True

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT)); srv.listen(5)
    print(f"[*] TCP server listening on port {PORT}")
    try: print(f"[*] this PC appears to be {socket.gethostbyname(socket.gethostname())}")
    except Exception: pass
    print("[*] in SoftAP mode the PC is usually 192.168.4.2 on the ESP's network")
    nf_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    nf_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    nf_listener.bind((HOST, GAME_FANOUT_PORT)); nf_listener.listen(5)
    threading.Thread(target=_nf_accept_loop, args=(nf_listener,), daemon=True).start()
    threading.Thread(target=_marker_stdin_loop, daemon=True).start()
    threading.Thread(target=_marker_udp_loop, daemon=True).start()
    print(f"[*] NF fan-out -> TCP port {GAME_FANOUT_PORT} (game connects here as a client)")
    print("[*] markers: type a number + Enter in this terminal to send a marker to the board")
    if DEBUG: print("[*] DEBUG on: per-second parity + verbose prints")
    if logdir: print(f"[*] logging ENABLED -> {logdir}/ (one pair of CSVs per connection)")
    if _NUMPY:
        print("[*] numpy detected — fast FIR path active")
    else:
        print("[*] numpy not found — using pure-Python FIR (pip install numpy to enable fast path)")
    print("[*] waiting for the ESP32 to connect...")
    while True:
        conn, addr = srv.accept()
        print(f"[+] {addr[0]} connected")
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        conn.settimeout(RECV_TIMEOUT)
        try: 
            handle(conn, addr, logdir)
        except ConnectionError as e:
            print(f"[-] Connection error with {addr[0]}: {e}")
        except Exception as e:
            print(f"[-] Unexpected error with {addr[0]}: {e}")
        finally: 
            conn.close()
            CURRENT_RUN_DIR = None
            CURRENT_RUN_TS = None
        print("[*] waiting for the ESP32 to reconnect...")


if __name__ == "__main__":
    main()