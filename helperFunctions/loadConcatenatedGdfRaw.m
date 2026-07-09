function [contData, eventSamples, eventValues, rawFs] = loadConcatenatedGdfRaw(gdfFiles, scalpLabels)
% loadConcatenatedGdfRaw  Reads and concatenates raw (unfiltered, native
% sample rate) scalp-channel data and STATUS trigger events across one
% participant's GDF file(s), which may be split into several files purely
% on a byte-size cap by the acquisition software (see
% findParticipantGdfFiles.m). Filtering/resampling is deliberately left to
% a later step so it can run once on the fully concatenated continuous
% signal - filtering each split file separately first would risk a filter
% edge artifact landing exactly at the file-boundary sample, which could
% fall inside a trial's window.
%
%   gdfFiles: cell array of GDF file paths, in chronological order.
%   scalpLabels: cell array of channel labels to keep (e.g. {'A1',...,'D32'}),
%       requested in this fixed order from every file so channel order is
%       guaranteed identical across the concatenation.
%
% Returns:
%   contData: a single-trial FieldTrip-style raw struct with fields label,
%       fsample, trial{1} ([nChan x nSamplesTotal], single precision to
%       bound memory for long multi-file recordings), time{1}.
%   eventSamples, eventValues: STATUS trigger events pooled across all
%       files, sample indices translated into the concatenated (global,
%       native-sample-rate) timeline.
%   rawFs: the native sampling rate (asserted identical across all files).

    rawFs = [];
    dataChunks = cell(numel(gdfFiles), 1);
    eventSampleChunks = cell(numel(gdfFiles), 1);
    eventValueChunks = cell(numel(gdfFiles), 1);
    cumulativeSamples = 0;

    for fileIdx = 1:numel(gdfFiles)
        gdfFile = gdfFiles{fileIdx};

        cfg = [];
        cfg.dataset = gdfFile;
        cfg.channel = scalpLabels;
        fileData = ft_preprocessing(cfg);

        if isempty(rawFs)
            rawFs = fileData.fsample;
        elseif fileData.fsample ~= rawFs
            error('loadConcatenatedGdfRaw:fsMismatch', ...
                'Sampling rate mismatch between split GDF files: %s is %g Hz, expected %g Hz.', ...
                gdfFile, fileData.fsample, rawFs);
        end
        if ~isequal(fileData.label(:), scalpLabels(:))
            error('loadConcatenatedGdfRaw:labelMismatch', ...
                'Channel label order mismatch in %s.', gdfFile);
        end

        dataChunks{fileIdx} = single(fileData.trial{1});
        nSamplesThisFile = size(dataChunks{fileIdx}, 2);

        events = ft_read_event(gdfFile);
        events = events(strcmp({events.type}, 'STATUS'));
        eventSampleChunks{fileIdx} = [events.sample] + cumulativeSamples;
        eventValueChunks{fileIdx} = [events.value];

        cumulativeSamples = cumulativeSamples + nSamplesThisFile;
    end

    contData = struct();
    contData.label = scalpLabels(:);
    contData.fsample = rawFs;
    contData.trial = {horzcat(dataChunks{:})};
    nSamplesTotal = size(contData.trial{1}, 2);
    contData.time = {(0:nSamplesTotal - 1) / rawFs};
    contData.sampleinfo = [1, nSamplesTotal];

    eventSamples = horzcat(eventSampleChunks{:});
    eventValues = horzcat(eventValueChunks{:});
end
