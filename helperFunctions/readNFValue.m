function nfVal = readNFValue(pathToNF, nfIndex)
% readNFValue  Reads the nfIndex-th double from the binary NF file written
% externally by the real-time SSVEP acquisition process (RT_acquisition_7),
% which fwrites a 5-element double vector [AMI_dir1, AMI_dir2, SMI_14gt18,
% SMI_18gt14, sampleCount] roughly every 100 ms. Returns 0 (neutral - no
% lateralisation) if the file is missing, unreadable, or caught mid-write
% by the external process and shorter than expected, so a transient race
% with the writer never crashes the trial loop.

    nfVal = 0;
    if ~exist(pathToNF, 'file')
        return;
    end

    fid = fopen(pathToNF, 'r');
    if fid == -1
        return;
    end
    temp = fread(fid, 'double');
    fclose(fid);

    if numel(temp) >= nfIndex
        nfVal = temp(nfIndex);
    end
end
