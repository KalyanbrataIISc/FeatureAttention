"""Exercise the real MATLAB bridge with TCP and a simulated serial adapter.

Requires MATLAB R2019a or later and Python on the development computer.
Uses the legacy serial API; no physical serial port opens.
"""
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def matlab_path(path):
    return str(path).replace('\\', '/').replace("'", "''")


def receive_record(client):
    data = bytearray()
    while len(data) < 24:
        part = client.recv(24 - len(data))
        if not part:
            raise AssertionError('TCP connection closed before a complete NF record')
        data.extend(part)
    return struct.unpack('<ddd', data)


def run_case(marker, disconnect=False):
    with tempfile.TemporaryDirectory(prefix='biosemi-bridge-test-') as directory:
        fixture = Path(directory)
        assert fixture.resolve().parent == Path(tempfile.gettempdir()).resolve()
        log = fixture / 'serial.log'
        nf = fixture / 'nf.txt'
        output_file = fixture / 'matlab.log'
        nf.write_bytes(struct.pack('<ddd', 0.25, -0.25, 1))
        (fixture / 'instrhwinfo.m').write_text(
            "function varargout=instrhwinfo(varargin)\nerror('BiosemiTest:UnavailableFunction','instrhwinfo is unavailable on P');\nend\n",
            encoding='utf-8',
        )
        (fixture / 'serial.m').write_text(
            "function port=serial(varargin)\nport=FakeBiosemiSerial;\nend\n",
            encoding='utf-8',
        )
        (fixture / 'FakeBiosemiSerial.m').write_text('''classdef FakeBiosemiSerial < handle
    properties
        Status = 'closed';
        ValuesSent = 0;
    end
    methods
        function fopen(obj), obj.Status='open'; obj.ValuesSent=0; end
        function fclose(obj), obj.Status='closed'; end
        function fwrite(obj,value,varargin)
            assert(strcmp(obj.Status,'open'));
            assert(isequal(varargin,{'uint8','sync'}));
            if value==98, error('FakeSerial:Disconnected','Simulated adapter unplugged'); end
            if value==99, return; end
            fid=fopen(getenv('BIOSEMI_TEST_LOG'),'a');
            fprintf(fid,'%d\\n',value);
            fclose(fid);
            obj.ValuesSent=obj.ValuesSent+numel(value);
        end
        function value=get(obj,name), value=obj.(name); end
        function delete(obj)
            fid=fopen(getenv('BIOSEMI_TEST_LOG'),'a');
            fprintf(fid,'CLOSED\\n'); fclose(fid);
            obj.Status='closed';
        end
    end
end
''', encoding='utf-8')
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        script = fixture / 'verify_bridge.m'
        resolver = matlab_path(REPO / 'Register-BiosemiTriggerAdapter.ps1')
        script.write_text(f'''addpath('{matlab_path(REPO)}');
issues=checkcode(fullfile('{matlab_path(REPO)}','run_biosemi_usb_bridge.m'),'-id');
for k=1:numel(issues), disp(issues(k).message); end
[status,output]=system('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{resolver}" -SelfTest');
assert(status==0,output);
assert(~isempty(strfind(output,'PASS:')),output);
disp('MATLAB PowerShell launch and stdout: PASS');
addpath('{matlab_path(fixture)}','-begin');
caught=false;
try
    run_biosemi_usb_bridge('{matlab_path(nf)}','COM12',{port});
catch err
    assert(strcmp(err.identifier,'BiosemiUsbBridge:SerialDisconnected'),err.getReport());
    disp(err.message);
    caught=true;
end
assert(caught,'Failed serial handle was retained instead of terminating the bridge');
disp('MATLAB bridge failure recovery: PASS');
''', encoding='utf-8')
        environment = dict(os.environ, BIOSEMI_TEST_LOG=str(log))
        with output_file.open('wb') as output:
            process = subprocess.Popen(
                [shutil.which('matlab'), '-batch', f"run('{matlab_path(script)}')"],
                cwd=str(REPO), env=environment, stdout=output, stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
            )
            try:
                deadline = time.monotonic() + 50
                client = None
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise AssertionError(output_file.read_text(errors='replace'))
                    try:
                        client = socket.create_connection(('127.0.0.1', port), timeout=0.5)
                        break
                    except OSError:
                        time.sleep(0.2)
                if client is None:
                    raise AssertionError('Bridge did not start in time')
                with client:
                    client.settimeout(5)
                    assert receive_record(client) == (0.25, -0.25, 1)
                    if disconnect:
                        client.sendall(b'0\n20\n')
                    else:
                        client.sendall(b'0\n20\n21\n40\n30\nnot-a-marker\n')
                        nf.write_bytes(struct.pack('<ddd', 0.6, -0.6, 2))
                        # Idle heartbeat can race the file update; read until the new count.
                        for _ in range(4):
                            if receive_record(client) == (0.6, -0.6, 2):
                                break
                        else:
                            raise AssertionError('Changed NF record was not forwarded')
                        client.sendall(b'R 2\n' + str(marker).encode() + b'\n')
                        while client.recv(256):
                            pass
                if disconnect:
                    deadline = time.monotonic() + 6
                    while time.monotonic() < deadline:
                        if log.exists() and '30\n' in log.read_text():
                            break
                        time.sleep(0.1)
                    else:
                        raise AssertionError('Tablet disconnect did not emit trial stop 30')
                    with socket.create_connection(('127.0.0.1', port), timeout=5) as second:
                        assert receive_record(second) == (0.25, -0.25, 1)
                        second.sendall(str(marker).encode() + b'\n')
                        while second.recv(256):
                            pass
                process.wait(timeout=15)
                if process.returncode:
                    raise AssertionError(output_file.read_text(errors='replace'))
                lines = log.read_text().splitlines()
                expected = ['0', '20', '30'] if disconnect else ['0', '20', '21', '40', '30']
                assert lines[:len(expected)] == expected, lines
                assert 'CLOSED' in lines, 'Serial adapter was not cleaned up'
                report = output_file.read_text(errors='replace')
                assert 'MATLAB PowerShell launch and stdout: PASS' in report, report
                assert 'MATLAB bridge failure recovery: PASS' in report, report
                print(f'PASS: marker {marker}, disconnect={disconnect}: legacy no-output serial fwrite, unavailable instrhwinfo, real TCP NF, marker bytes and cleanup', flush=True)
            except BaseException:
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                else:
                    process.kill()
                process.wait(timeout=15)
                print(output_file.read_text(errors='replace'), flush=True)
                raise


if __name__ == '__main__':
    if not shutil.which('matlab'):
        raise SystemExit('MATLAB must be on PATH')
    run_case(99)
    run_case(98)
    run_case(99, disconnect=True)
    print('PASS: all three real MATLAB bridge scenarios; physical P-to-A hardware remains to be checked.', flush=True)