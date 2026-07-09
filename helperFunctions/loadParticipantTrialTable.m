function trialTable = loadParticipantTrialTable(participantDir, participantNum)
% loadParticipantTrialTable  Reads every
% "p<participantNum>_b<NN>_leaves_trialdata.csv" file in participantDir
% (gameNFv3.m's per-block behavioural log; see README.md's CSV output
% section), sorted by block number, and concatenates them into one table
% covering the whole session in trial order. Adds a Participant column, a
% Block column, and a TrialDurationSec column (TrialEnd - TrialStart) used
% downstream to match each row to its corresponding GDF trial-start/
% trial-stop trigger pair.

    pattern = fullfile(participantDir, sprintf('p%d_b*_leaves_trialdata.csv', participantNum));
    csvFiles = dir(pattern);
    if isempty(csvFiles)
        error('loadParticipantTrialTable:noFiles', ...
            'No trialdata CSV files found matching %s', pattern);
    end

    blockNumbers = nan(numel(csvFiles), 1);
    for k = 1:numel(csvFiles)
        tok = regexp(csvFiles(k).name, '_b(\d+)_leaves_trialdata\.csv$', 'tokens', 'once');
        if ~isempty(tok)
            blockNumbers(k) = str2double(tok{1});
        end
    end
    if any(isnan(blockNumbers))
        error('loadParticipantTrialTable:unparsableBlock', ...
            'Could not parse a block number from one of the trialdata filenames in %s', participantDir);
    end
    [blockNumbers, sortOrder] = sort(blockNumbers);
    csvFiles = csvFiles(sortOrder);

    blockTables = cell(numel(csvFiles), 1);
    for k = 1:numel(csvFiles)
        T = readtable(fullfile(csvFiles(k).folder, csvFiles(k).name), 'VariableNamingRule', 'preserve');
        T.Block = repmat(blockNumbers(k), height(T), 1);
        blockTables{k} = T;
    end

    trialTable = vertcat(blockTables{:});
    trialTable.TrialDurationSec = trialTable.TrialEnd - trialTable.TrialStart;
    trialTable.Participant = repmat(participantNum, height(trialTable), 1);
end
