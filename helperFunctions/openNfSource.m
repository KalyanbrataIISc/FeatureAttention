function nfState = openNfSource(sourceType, filePath, tcpHost, tcpPort, tcpTimeoutSec)
% openNfSource  Opens the neurofeedback stream, from either nf.txt or a TCP
% server, and returns the state struct readNfSample.m/closeNfSource.m take.
%
% sourceType    'file' - read nf.txt directly, exactly as every gameNF
%                        variant up to v8 does (via readNFValue.m). filePath
%                        is the file, tcpHost/tcpPort/tcpTimeoutSec unused.
%               'tcp'  - connect to nf_tcp_server.py on another machine (or
%                        this one) and read the same three doubles off the
%                        socket instead. filePath unused.
%
% The TCP wire format is byte-identical to nf.txt: back-to-back 24-byte
% records of 3 little-endian doubles [SMI_19gt23, SMI_23gt19, sampleCount],
% pushed by the server roughly every 100 ms. There is no header and no
% framing - TCP delivers bytes in order and without loss, so a client that
% reads from the moment it connects stays record-aligned for the whole
% session simply by counting bytes (see readNfSample.m).
%
% This deliberately does NOT fall back to nf.txt if the connection fails.
% An experiment that silently runs on a dead NF stream produces a whole
% block of unusable data, so a server that is not running, a wrong address,
% or a firewall in the way has to stop the script here - before a
% participant is seated - with a message saying which of those it was. For
% the same reason the connection is not considered open until a first real
% record has arrived: a TCP connect succeeding only proves something is
% listening on that port, not that NF is flowing.
%
% MATLAB's TCP client object is called tcpclient in every version that has
% it; the much older tcpip object is used as a fallback so this still works
% on a MATLAB whose Instrument Control Toolbox predates tcpclient. Which
% one was used, and which name that version spells the bytes-waiting
% property, are both resolved once here rather than on every frame.

    nfState = struct( ...
        'type',                 lower(sourceType), ...
        'filePath',             filePath, ...
        'host',                 tcpHost, ...
        'port',                 tcpPort, ...
        'client',               [], ...
        'useLegacyTcpip',       false, ...
        'useNumBytesAvailable', false, ...
        'recordBytes',          24, ...       % 3 doubles, same as nf.txt
        'buffer',               uint8([]), ...
        'lastRecord',           [], ...
        'samplesRead',          0, ...
        'staleReads',           0);

    switch nfState.type
        case 'file'
            fprintf('NF source: file %s\n', filePath);
            return;
        case 'tcp'
            % nothing yet - opened below
        otherwise
            error('openNfSource:badSource', ...
                'nfSourceType must be ''file'' or ''tcp'', got ''%s''.', sourceType);
    end

    fprintf('NF source: connecting to tcp://%s:%d ...\n', tcpHost, tcpPort);

    connectError = '';
    if exist('tcpclient', 'class') == 8 || exist('tcpclient', 'file') == 2
        try
            nfState.client = tcpclient(tcpHost, tcpPort, 'Timeout', tcpTimeoutSec);
        catch nvPairErr
            % Either the connection genuinely failed, or this MATLAB's
            % tcpclient predates the name/value pair - retry without it and
            % let the second failure be the one that is reported.
            try
                nfState.client = tcpclient(tcpHost, tcpPort);
                try
                    nfState.client.Timeout = tcpTimeoutSec;
                catch
                end
            catch bareErr
                connectError = bareErr.message;
            end
            if isempty(connectError) && isempty(nfState.client)
                connectError = nvPairErr.message;
            end
        end
        if isempty(connectError)
            % Newer MATLAB renamed BytesAvailable to NumBytesAvailable; ask once.
            try
                nfState.useNumBytesAvailable = ~isempty(nfState.client.NumBytesAvailable);
            catch
                nfState.useNumBytesAvailable = false;
            end
        end
    else
        nfState.useLegacyTcpip = true;
        try
            % Only reached on a MATLAB too old to have tcpclient, which is
            % also a MATLAB where tcpip is not yet deprecated.
            nfState.client = tcpip(tcpHost, tcpPort, 'NetworkRole', 'client'); %#ok<TCPC>
            set(nfState.client, 'InputBufferSize', 65536);
            set(nfState.client, 'Timeout', tcpTimeoutSec);
            fopen(nfState.client);
        catch legacyErr
            connectError = legacyErr.message;
        end
    end

    if ~isempty(connectError)
        error('openNfSource:connectFailed', ...
            ['Could not connect to the NF server at %s:%d (%s).\n' ...
             'Check that nf_tcp_server.py is running on that machine, that %s is its current ' ...
             'address on this network, and that its firewall allows inbound TCP on port %d.'], ...
            tcpHost, tcpPort, connectError, tcpHost, tcpPort);
    end

    % Wait for the stream itself, not just the connection (see above).
    % tic/toc and pause rather than PsychToolbox's GetSecs/WaitSecs: this all
    % happens at setup, long before any flip, so the extra precision buys
    % nothing and this way the NF source can be opened and tested from a
    % plain MATLAB session with no PsychToolbox on the path.
    firstRecordTimer = tic;
    gotFirstRecord = false;
    while toc(firstRecordTimer) < tcpTimeoutSec
        [~, readOk, nfState] = readNfSample(nfState, 1);
        if readOk
            gotFirstRecord = true;
            break;
        end
        pause(0.01);
    end

    if ~gotFirstRecord
        closeNfSource(nfState);
        error('openNfSource:noStream', ...
            ['Connected to %s:%d but no NF data arrived within %g s.\n' ...
             'The port is open, so something is listening, but it is not pushing NF records - ' ...
             'check that nf_tcp_server.py was started with "serve" (and, if --source file, that ' ...
             'the nf.txt it mirrors is actually being written).'], ...
            tcpHost, tcpPort, tcpTimeoutSec);
    end

    fprintf('NF source: tcp://%s:%d streaming (first sampleCount = %d).\n', ...
        tcpHost, tcpPort, round(nfState.lastRecord(3)));
end
