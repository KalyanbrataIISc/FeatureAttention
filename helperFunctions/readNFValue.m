function NF = readNFValue(pathToNF)
    NF = 0;
    if ~exist(pathToNF, 'file')
        return;
    end

    fid = fopen(pathToNF,'r');
    if fid == -1
        return;
    end
    temp = fread(fid,'double');
    fclose(fid);

    if ~isempty(temp)
        NF = temp(1);
    end
end
