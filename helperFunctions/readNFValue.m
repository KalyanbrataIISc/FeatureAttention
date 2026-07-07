function [nfVal, readOk] = readNFValue(pathToNF, nfIndex)
% readNFValue  Reads the nfIndex-th double from the binary NF file written
% externally by the real-time SSVEP acquisition process (RT_acquisition_8),
% which fwrites a 3-element double vector [SMI_17gt20, SMI_20gt17,
% sampleCount] roughly every 100 ms via fopen(...,'w') -
% truncating the file to empty before writing the fresh bytes - then
% fwrite then fclose. Same lean fopen/fread/fclose read
% testing2DGoalField.m uses every frame, with no separate exist() check
% beforehand - fopen's own return value already tells us if the file
% couldn't be opened, so a second filesystem call to ask the same question
% first would just be redundant overhead on every one of the 60-ish calls
% this makes per second for the whole experiment.
%
% readOk is false whenever the file couldn't be opened or was caught
% mid-write by the external process (and so is shorter than expected).
% This is a plain I/O race (we're reading every displayed frame, much
% faster than the file is rewritten), not a genuine "zero lateralisation"
% sample - callers should keep using their last successfully-read value
% rather than treat readOk=false as a real measurement of 0.

    nfVal = 0;
    readOk = false;

    fid = fopen(pathToNF, 'r');
    if fid == -1
        return;
    end
    temp = fread(fid, 'double');
    fclose(fid);

    if numel(temp) >= nfIndex
        nfVal = temp(nfIndex);
        readOk = true;
    end
end
