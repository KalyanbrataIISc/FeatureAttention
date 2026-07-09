function miniEpochs = extractMiniEpochs(channelData, epochLenSamples)
% extractMiniEpochs  Chops one trial's [channels x samples] signal into
% sequential, non-overlapping, demeaned epochLenSamples-long mini-epochs -
% the same fixed-length sliding-epoch approach
% analysis/singleParticipantBehaviourOffline.m's processSinglePSSpectra
% uses to pool many short segments into one induced/evoked power estimate
% (there, per trial; here, the resulting epochs get pooled across every
% matched trial). A trial shorter than one epoch contributes none.
%
%   channelData: channels x samples (one trial's window, one channel set).
%   epochLenSamples: mini-epoch length in samples.
%
% Returns miniEpochs: channels x epochLenSamples x nEpochs (nEpochs may be
% 0, i.e. an empty 3rd dimension, if the trial is too short).

    numChannels = size(channelData, 1);
    numSamples = size(channelData, 2);
    numEpochs = floor(numSamples / epochLenSamples);

    miniEpochs = nan(numChannels, epochLenSamples, numEpochs);
    for epochIdx = 1:numEpochs
        startIdx = (epochIdx - 1) * epochLenSamples + 1;
        stopIdx = startIdx + epochLenSamples - 1;
        segment = channelData(:, startIdx:stopIdx);
        miniEpochs(:, :, epochIdx) = segment - mean(segment, 2);
    end
end
