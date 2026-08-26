#!/usr/bin/env python3
"""Serves the SSVEP neurofeedback stream over TCP instead of (or alongside)
nf.txt, so the game machine can read NF over Wi-Fi/Ethernet from another
computer instead of sharing a file.

The wire format is deliberately identical to nf.txt's: each NF sample is one
24-byte record of 3 little-endian doubles

    [SMI_19gt23, SMI_23gt19, sampleCount]

pushed to every connected client, back to back, with no header and no
framing bytes. TCP already guarantees order and delivery, so a client that
reads the stream from the moment it connects can never lose record
alignment - it just accumulates bytes and takes the newest complete 24-byte
group (see helperFunctions/readNfSample.m). Keeping the record identical to
the file means the MATLAB side parses the same three doubles either way.

Two sources:

  serve --source sim
      Generates fake values with the same bounded AR(1) random walk and the
      same 13-samples-at-128Hz (~101.6 ms) cadence as simulate_nf.py, for
      testing the whole chain on a machine with no EEG hardware.

  serve --source file --path X:\\FeatureAttention\\nf.txt
      Mirrors a real nf.txt written by RT_acquisition_8.m: polls the file
      and pushes whatever it currently holds. Run this on (or next to) the
      acquisition machine and the game machine no longer needs the network
      share. Reads that catch the file mid-rewrite (RT_acquisition_8 opens
      with 'w', which truncates, before writing the fresh bytes) are simply
      skipped - the same I/O race readNFValue.m already tolerates - rather
      than pushed as a spurious sample.

The stream is push-only: the server never reads from its clients, so a game
that stalls for a frame cannot make the server block. Clients that
disconnect are dropped silently; a client can reconnect at any time and
starts receiving from the next sample.

    probe HOST PORT
        Connects as a client, decodes the records, and prints them with the
        measured inter-record interval - the quickest way to check that the
        server, the network and the firewall are all letting the stream
        through, without involving MATLAB or PsychToolbox.
"""
import argparse
import errno
import random
import select
import socket
import struct
import sys
import time

SAMPLE_RATE_HZ = 128.0
SAMPLES_PER_WRITE = 13
WRITE_INTERVAL_SEC = SAMPLES_PER_WRITE / SAMPLE_RATE_HZ  # ~0.1016s, matches RT_acquisition_8's cadence

AR_COEFF = 0.95   # closer to 1 = slower/smoother drift
NOISE_STD = 0.12  # per-step Gaussian noise scale, before clipping to [-1, 1]

RECORD_FORMAT = '<3d'
RECORD_BYTES = struct.calcsize(RECORD_FORMAT)  # 24
DEFAULT_PORT = 5006


def next_value(value):
    value = AR_COEFF * value + random.gauss(0, NOISE_STD)
    return max(-1.0, min(1.0, value))


class SimSource(object):
    """Fake NF, one bounded random walk per SMI column - see simulate_nf.py."""

    interval = WRITE_INTERVAL_SEC

    def __init__(self, seed=None):
        if seed is not None:
            random.seed(seed)
        self.smi1 = 0.0
        self.smi2 = 0.0
        self.sample_count = 0

    def describe(self):
        return 'simulated NF (AR(1) walk, %.1f ms cadence)' % (self.interval * 1000)

    def sample(self):
        self.smi1 = next_value(self.smi1)
        self.smi2 = next_value(self.smi2)
        self.sample_count += 1
        return (self.smi1, self.smi2, float(self.sample_count))


class FileSource(object):
    """Real NF, mirrored out of the nf.txt RT_acquisition_8.m keeps rewriting."""

    def __init__(self, path, interval):
        self.path = path
        self.interval = interval
        self.warned_missing = False

    def describe(self):
        return 'nf.txt at %s (polled every %.0f ms)' % (self.path, self.interval * 1000)

    def sample(self):
        try:
            with open(self.path, 'rb') as f:
                raw = f.read(RECORD_BYTES)
        except (IOError, OSError) as exc:
            if not self.warned_missing:
                print('nf source unreadable (%s) - will keep retrying' % exc, file=sys.stderr)
                self.warned_missing = True
            return None
        if len(raw) < RECORD_BYTES:
            return None  # caught mid-rewrite; the next poll will get the whole record
        if self.warned_missing:
            print('nf source readable again: %s' % self.path, file=sys.stderr)
            self.warned_missing = False
        return struct.unpack(RECORD_FORMAT, raw)


def local_ip_hint():
    """Best guess at the LAN address a client on another machine should dial.

    Opens a UDP socket towards a public address - no packet is actually
    sent, but the OS has to pick the interface it would route through, which
    is the one the game machine can reach.
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(('8.8.8.8', 80))
        return probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()


def serve(args):
    if args.source == 'sim':
        source = SimSource(args.seed)
    else:
        source = FileSource(args.path, args.poll_interval)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.port))
    listener.listen(8)
    listener.setblocking(False)

    hint = local_ip_hint()
    print('NF TCP server listening on %s:%d' % (args.host, args.port))
    print('  source : %s' % source.describe())
    if hint and args.host in ('0.0.0.0', ''):
        print('  clients on other machines should connect to %s:%d' % (hint, args.port))
    print('  check it with: python nf_tcp_server.py probe %s %d' % (hint or '127.0.0.1', args.port))
    print('Ctrl+C to stop.')

    clients = []
    sent = 0
    skipped = 0
    next_tick = time.monotonic()
    try:
        while True:
            # Accept anyone who turned up since the last tick. select() with a
            # zero timeout keeps this from ever delaying the sample cadence.
            while True:
                readable, _, _ = select.select([listener], [], [], 0)
                if not readable:
                    break
                conn, addr = listener.accept()
                conn.setblocking(False)
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                clients.append((conn, addr))
                print('client connected: %s:%d (%d connected)' % (addr[0], addr[1], len(clients)))

            record = source.sample()
            if record is None:
                skipped += 1
            else:
                payload = struct.pack(RECORD_FORMAT, *record)
                still_connected = []
                for conn, addr in clients:
                    try:
                        conn.sendall(payload)
                        still_connected.append((conn, addr))
                    except OSError as exc:
                        if exc.errno not in (errno.EPIPE, errno.ECONNRESET, errno.EWOULDBLOCK, errno.EAGAIN):
                            raise
                        print('client disconnected: %s:%d' % (addr[0], addr[1]))
                        conn.close()
                clients = still_connected
                sent += 1

            if args.verbose and record is not None and sent % 10 == 0:
                print('sent %d records to %d client(s): [% .4f, % .4f, %d] (%d skipped)'
                      % (sent, len(clients), record[0], record[1], int(record[2]), skipped))

            next_tick += source.interval
            sleep_for = next_tick - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)
            else:
                next_tick = time.monotonic()  # fell behind - resync instead of spinning to catch up
    except KeyboardInterrupt:
        print('\nStopped after %d records (%d skipped).' % (sent, skipped))
    finally:
        for conn, _ in clients:
            conn.close()
        listener.close()


def probe(args):
    print('connecting to %s:%d ...' % (args.host, args.port))
    conn = socket.create_connection((args.host, args.port), timeout=args.timeout)
    conn.settimeout(args.timeout)
    print('connected. Ctrl+C to stop.')

    buffer = b''
    count = 0
    started = time.monotonic()
    previous = None
    try:
        while True:
            if args.seconds and time.monotonic() - started >= args.seconds:
                break
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                print('!! no data for %.1fs - server connected but is not sending' % args.timeout)
                continue
            if not chunk:
                print('!! server closed the connection')
                break
            buffer += chunk
            while len(buffer) >= RECORD_BYTES:
                smi1, smi2, sample_count = struct.unpack(RECORD_FORMAT, buffer[:RECORD_BYTES])
                buffer = buffer[RECORD_BYTES:]
                now = time.monotonic()
                gap_ms = (now - previous) * 1000 if previous is not None else float('nan')
                previous = now
                count += 1
                print('#%-6d SMI_19gt23=% .5f  SMI_23gt19=% .5f  sampleCount=%-8d  +%6.1f ms'
                      % (count, smi1, smi2, int(sample_count), gap_ms))
    except KeyboardInterrupt:
        pass
    finally:
        conn.close()

    elapsed = time.monotonic() - started
    if count:
        print('\n%d records in %.1fs (%.1f Hz) - stream is alive.' % (count, elapsed, count / elapsed))
    else:
        print('\nNo records received in %.1fs - the server is reachable but not streaming.' % elapsed)
    return 0 if count else 1


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command')

    p_serve = sub.add_parser('serve', help='stream NF records to connected clients')
    p_serve.add_argument('--source', choices=['sim', 'file'], default='sim',
                         help='sim = generated test values; file = mirror a real nf.txt (default: sim)')
    p_serve.add_argument('--path', default='nf.txt',
                         help='nf.txt to mirror when --source file (default: ./nf.txt)')
    p_serve.add_argument('--host', default='0.0.0.0',
                         help='interface to listen on; 0.0.0.0 = every interface, so other '
                              'machines on the network can connect (default: 0.0.0.0)')
    p_serve.add_argument('--port', type=int, default=DEFAULT_PORT,
                         help='TCP port to listen on (default: %d)' % DEFAULT_PORT)
    p_serve.add_argument('--poll-interval', type=float, default=0.05,
                         help='how often to re-read nf.txt when --source file, in seconds. '
                              'Default 0.05 = twice RT_acquisition_8 own ~0.1s write cadence, '
                              'so a fresh value is forwarded within ~50ms of being written.')
    p_serve.add_argument('--seed', type=int, default=None,
                         help='random seed for --source sim, for reproducible test runs')
    p_serve.add_argument('--verbose', action='store_true',
                         help='print every 10th record as it goes out')
    p_serve.set_defaults(func=serve)

    p_probe = sub.add_parser('probe', help='connect as a client and print the decoded stream')
    p_probe.add_argument('host', help='address of the machine running "serve"')
    p_probe.add_argument('port', type=int, nargs='?', default=DEFAULT_PORT,
                         help='port the server is listening on (default: %d)' % DEFAULT_PORT)
    p_probe.add_argument('--seconds', type=float, default=None,
                         help='stop after this many seconds instead of running until Ctrl+C')
    p_probe.add_argument('--timeout', type=float, default=3.0,
                         help='seconds of silence before complaining (default: 3)')
    p_probe.set_defaults(func=probe)

    args = parser.parse_args()
    if not getattr(args, 'command', None):
        parser.print_help()
        return 2
    return args.func(args) or 0


if __name__ == '__main__':
    sys.exit(main())
