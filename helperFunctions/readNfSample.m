function [nfVal, readOk, nfState] = readNfSample(nfState, nfIndex)
% readNfSample  Reads one NF value from whichever source openNfSource.m
% opened, returning the same [value, readOk] contract readNFValue.m has:
% readOk is false when no fresh sample was available, which is an I/O or
% network fact and not a genuine "zero lateralisation" measurement, so
% callers must keep their previous value rather than treat it as a real 0.
%
% nfState is passed in and returned because the TCP path carries state
% between frames (the leftover bytes of a record that had not fully arrived
% yet). Callers must keep the returned struct - dropping it would re-read
% the same partial record forever.
%
% file source
%   Identical to every gameNF variant up to v8: the whole file is re-read
%   fresh each call via readNFValue.m.
%
% tcp source
%   The socket is drained non-blocking every call and only the NEWEST
%   complete 24-byte record is kept; any older records that piled up since
%   the last call are discarded unread. The frame loop runs at ~60 Hz and
%   the server pushes at ~10 Hz, so in practice there is at most one, but
%   discarding rather than queueing is what guarantees the game can never
%   drift behind the live signal even if a frame is late or the network
%   hiccups and delivers a burst. Nothing is ever requested from the socket
%   beyond what has already arrived, so this cannot block a flip.
%
%   Alignment needs no framing bytes: TCP delivers the stream in order and
%   without loss, so counting 24 bytes per record from the moment of
%   connection stays correct for the whole session, and the trailing
%   incomplete record is carried in nfState.buffer until its remaining
%   bytes turn up on a later frame.
%
%   Records are little-endian doubles, matching nf.txt and every machine
%   this runs on (Intel/Apple silicon Macs, Windows PCs).

    nfVal = 0;
    readOk = false;

    if strcmp(nfState.type, 'file')
        [nfVal, readOk] = readNFValue(nfState.filePath, nfIndex);
    else
        if nfState.useLegacyTcpip
            bytesWaiting = get(nfState.client, 'BytesAvailable');
        elseif nfState.useNumBytesAvailable
            bytesWaiting = nfState.client.NumBytesAvailable;
        else
            bytesWaiting = nfState.client.BytesAvailable;
        end

        if bytesWaiting >= 1
            if nfState.useLegacyTcpip
                newBytes = fread(nfState.client, bytesWaiting, 'uint8');
            else
                newBytes = read(nfState.client, bytesWaiting, 'uint8');
            end
            nfState.buffer = [nfState.buffer, uint8(reshape(newBytes, 1, []))];
        end

        completeRecords = floor(numel(nfState.buffer) / nfState.recordBytes);
        if completeRecords >= 1
            newestStart = (completeRecords - 1) * nfState.recordBytes + 1;
            record = typecast(nfState.buffer(newestStart:newestStart + nfState.recordBytes - 1), 'double');
            nfState.buffer = nfState.buffer(completeRecords * nfState.recordBytes + 1:end);
            nfState.lastRecord = record;
            if numel(record) >= nfIndex
                nfVal = record(nfIndex);
                readOk = true;
            end
        end
    end

    % Read bookkeeping, so a caller can tell "the stream died mid-block"
    % (staleReads climbing without bound) from the ordinary case of polling
    % faster than the source is written (staleReads resetting constantly).
    if readOk
        nfState.samplesRead = nfState.samplesRead + 1;
        nfState.staleReads = 0;
    else
        nfState.staleReads = nfState.staleReads + 1;
    end
end
