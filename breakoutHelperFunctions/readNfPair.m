function [nf17, nf20, readOk] = readNfPair(pathToNF, nfIndex17, nfIndex20)
% readNfPair  Reads *both* SSVEP-lateralisation values out of the binary NF
% file in a single fopen/fread/fclose.
%
% This is the two-value counterpart of helperFunctions/readNFValue.m, which
% the leaves task uses. The leaves task only ever needs one column per trial
% (whichever one the cue makes "correct"), so reading one value is enough.
% gameBreakout needs both columns on every frame, because the paddle's
% velocity is driven by their difference - and this loop runs ~60 times a
% second for the whole block, so it opens the file once rather than twice.
%
% nf.txt is written externally by the real-time acquisition process
% (RT_files/RT_acquisition_8.m) as a 3-element double vector
% [SMI_17gt20, SMI_20gt17, sampleCount], via fopen(...,'w') - which truncates
% the file to empty - then fwrite then fclose, roughly every 100 ms.
%
% readOk is false when the file could not be opened, or was caught mid-write
% and is therefore shorter than expected. Either way that is an I/O race
% against the external writer, not a genuine "zero lateralisation" sample:
% callers must keep their last successfully-read values rather than treat a
% failed read as a real measurement of 0, otherwise the paddle would jerk to
% a halt every time a read lost the race.

    nf17 = 0;
    nf20 = 0;
    readOk = false;

    fid = fopen(pathToNF, 'r');
    if fid == -1
        return;
    end
    temp = fread(fid, 'double');
    fclose(fid);

    if numel(temp) >= max(nfIndex17, nfIndex20)
        nf17 = temp(nfIndex17);
        nf20 = temp(nfIndex20);
        readOk = true;
    end
end
