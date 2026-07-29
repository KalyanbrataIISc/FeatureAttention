function [seriesMat, windowCenterTimesSec] = computeTrialSsvepLogSnrSeries( ...
    signalRow, Fs, freqsHz, windowSec, stepSec, chronuxParams)
% computeTrialSsvepLogSnrSeries  Computes a sliding-window narrowband SNR
% time series at each frequency in freqsHz for one trial's single-channel
% (e.g. occipital-ROI-averaged) signal, using a Chronux multitaper spectrum
% per window - the same estimator
% (analysis/singleParticipantBehaviourOffline.m's computeWindowSpectrum/
% mtspectrumc with 1s windows) used by the reference offline pipeline this
% analysis follows. Per window, SNR is the power at the FFT bin nearest the
% target frequency divided by the mean power of its two immediately
% adjacent bins (not literally +/-1Hz, since bin spacing depends on
% Chronux's padding) - a simple, standard way to express each frequency's
% power relative to the local 1/f background. The log of that ratio is
% returned (log-SNR), matching the reference pipeline's use of log-power
% series before baseline subtraction and averaging.
%
% Windows are stepped backward from the last sample so the final window
% always ends exactly on the trial's last sample - this is what makes the
% resulting series correctly "locked to trial end" once handed to
% alignSeriesToTrialEnd.m.
%
%   signalRow: 1 x nSamples vector, already preprocessed, for exactly this
%       trial's [start, stop] sample range.
%   Fs: sampling rate of signalRow (Hz).
%   freqsHz: vector of target frequencies (e.g. [19 23]).
%   windowSec, stepSec: sliding-window length and step (seconds).
%   chronuxParams: struct of Chronux params for mtspectrumc (Fs, tapers,
%       pad, fpass, trialave, err).
%
% Returns seriesMat (numel(freqsHz) x nWindows, one row per frequency) and
% windowCenterTimesSec (1 x nWindows, each window's center time relative to
% signalRow's first sample). Both are empty if the trial is shorter than
% one window.

    nSamples = numel(signalRow);
    nWin = round(windowSec * Fs);
    nStep = round(stepSec * Fs);

    if nSamples < nWin
        seriesMat = zeros(numel(freqsHz), 0);
        windowCenterTimesSec = zeros(1, 0);
        return;
    end

    windowEnds = fliplr(nSamples:-nStep:nWin);
    nWindows = numel(windowEnds);
    seriesMat = nan(numel(freqsHz), nWindows);
    windowCenterTimesSec = ((windowEnds - nWin / 2) - 1) / Fs;

    for w = 1:nWindows
        segment = double(signalRow(windowEnds(w) - nWin + 1:windowEnds(w)));
        segment = segment - mean(segment, 'omitnan');
        segment = detrend(segment(:), 'linear');

        [psd, freqs] = mtspectrumc(segment, chronuxParams);

        for f = 1:numel(freqsHz)
            [~, targetIdx] = min(abs(freqs - freqsHz(f)));
            neighborIdx = [max(1, targetIdx - 1), min(numel(freqs), targetIdx + 1)];
            snr = psd(targetIdx) / mean(psd(neighborIdx));
            seriesMat(f, w) = log(snr);
        end
    end
end
