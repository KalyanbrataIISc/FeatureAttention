function [spectrum, freqs] = computeEvokedSpectrum(miniEpochs, chronuxParams)
% computeEvokedSpectrum  Evoked (phase-locked) power spectrum: averages the
% raw mini-epochs (extractMiniEpochs.m) across epochs in the TIME domain
% first - which cancels non-phase-locked activity but reinforces any
% signal with a fixed phase relationship to each epoch's own start, as the
% continuous SSVEP flicker has (its phase runs off elapsed time from trial
% start, uninterrupted through pre-cue/response/feedback - see gameNFv3.m's
% SSVEP tagging section) - then computes one Chronux multitaper spectrum
% per channel of that averaged waveform. Matches
% analysis/singleParticipantBehaviourOffline.m's processSinglePSSpectra
% (SEvoked/fEvoked; trialave=0, pad=0 there, passed in via chronuxParams
% here).
%
%   miniEpochs: channels x epochLenSamples x nEpochs.
%   chronuxParams: struct for mtspectrumc (Fs, tapers, pad, fpass, err,
%       trialave - trialave should be 0, pad should be 0 to match the
%       reference pipeline).
%
% Returns spectrum: numChannels x numFreqBins, freqs: 1 x numFreqBins.

    numChannels = size(miniEpochs, 1);
    averagedWaveform = mean(miniEpochs, 3, 'omitnan');

    [s, freqs] = mtspectrumc(averagedWaveform(1, :).', chronuxParams);
    spectrum = zeros(numChannels, numel(s));
    spectrum(1, :) = s(:).';

    for ch = 2:numChannels
        [s, freqs] = mtspectrumc(averagedWaveform(ch, :).', chronuxParams);
        spectrum(ch, :) = s(:).';
    end
end
