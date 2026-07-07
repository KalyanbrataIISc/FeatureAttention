function csvFile = ensureCsvWithHeader(csvBaseDir, baseName, csvHeader)
% ensureCsvWithHeader  Returns the path to baseName inside csvBaseDir with
% csvHeader already written as its first line. If baseName already exists
% with a different header (the CSV schema changed since a prior run), a
% timestamped filename is used instead, so old data is never silently
% overwritten or mixed with rows from a different schema.

    csvFile = fullfile(csvBaseDir, baseName);
    if ~exist(csvFile, 'file')
        fid = fopen(csvFile, 'w');
        fprintf(fid, '%s\n', csvHeader);
        fclose(fid);
        return;
    end

    fid = fopen(csvFile, 'r');
    existingCsvHeader = fgetl(fid);
    fclose(fid);
    if ~ischar(existingCsvHeader) || ~strcmp(strtrim(existingCsvHeader), csvHeader)
        [~, baseNoExt, ext] = fileparts(baseName);
        csvFile = fullfile(csvBaseDir, sprintf('%s_%s%s', baseNoExt, datestr(now, 'yyyymmdd_HHMMSS'), ext));
        fid = fopen(csvFile, 'w');
        fprintf(fid, '%s\n', csvHeader);
        fclose(fid);
        fprintf('Existing CSV header did not match. Writing this run to %s\n', csvFile);
    end
end
