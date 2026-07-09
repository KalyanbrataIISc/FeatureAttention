function gdfFiles = findParticipantGdfFiles(gdfFolder, participantNum)
% findParticipantGdfFiles  Lists a participant's GDF recording file(s) inside
% gdfFolder, in chronological/continuation order: the base file
% "P<participantNum>.gdf" first, then any auto-split continuation files
% "P<participantNum>_1.gdf", "P<participantNum>_2.gdf", ... in ascending
% numeric order. Some acquisition software rolls over to a new file purely
% on a byte-size cap (observed here at ~1GiB) with no relationship to
% behavioural block boundaries, so the split count need not match the
% number of blocks - all split files for one participant must be treated as
% one continuous recording.

    baseName = sprintf('P%d.gdf', participantNum);
    baseFile = fullfile(gdfFolder, baseName);
    if ~isfile(baseFile)
        error('findParticipantGdfFiles:missingBaseFile', ...
            'Expected base GDF file not found: %s', baseFile);
    end

    listing = dir(fullfile(gdfFolder, sprintf('P%d_*.gdf', participantNum)));
    continuationIdx = nan(numel(listing), 1);
    for k = 1:numel(listing)
        tok = regexp(listing(k).name, sprintf('^P%d_(\\d+)\\.gdf$', participantNum), 'tokens', 'once');
        if ~isempty(tok)
            continuationIdx(k) = str2double(tok{1});
        end
    end
    validMask = ~isnan(continuationIdx);
    listing = listing(validMask);
    continuationIdx = continuationIdx(validMask);
    [~, sortOrder] = sort(continuationIdx);
    listing = listing(sortOrder);

    gdfFiles = [{baseFile}, arrayfun(@(f) fullfile(f.folder, f.name), listing, 'UniformOutput', false).'];
end
