function [prepData, downsampleFactor, targetFs] = preprocessContinuousEeg( ...
    rawData, desiredTargetFs, prepBand, prepBandOrd, useNotch50)
% preprocessContinuousEeg  Downsamples then band-pass/notch-filters one
% continuous FieldTrip-style raw struct (e.g. from loadConcatenatedGdfRaw.m),
% in that order - matching
% analysis/singleParticipantBehaviourOffline.m's pipeline, which resamples
% first and only then filters, so the (much cheaper) filtfilt-based
% bandpass/notch runs on the downsampled signal rather than the full native
% rate.
%
% downsampleFactor is chosen as round(rawFs/desiredTargetFs) and applied as
% an exact integer decimation (actual targetFs = rawFs/downsampleFactor,
% which may differ slightly from desiredTargetFs) rather than an arbitrary
% resampling ratio, so that raw-domain sample indices (e.g. trial
% boundaries from GDF trigger events) can be converted to the downsampled
% timeline exactly via rawSampleToResampledIndex.m.
%
%   rawData: continuous FieldTrip raw struct at native sampling rate.
%   desiredTargetFs: preferred post-downsample sampling rate (Hz).
%   prepBand: [lowHz highHz] band-pass edges.
%   prepBandOrd: Butterworth filter order for the band-pass.
%   useNotch50: true to also apply a 50Hz mains notch (dftfilter).
%
% Returns prepData (filtered, downsampled continuous struct),
% downsampleFactor (integer), and the actually-achieved targetFs.

    downsampleFactor = max(1, round(rawData.fsample / desiredTargetFs));
    targetFs = rawData.fsample / downsampleFactor;

    cfgResample = [];
    cfgResample.demean = 'yes';
    cfgResample.resamplefs = targetFs;
    resampledData = ft_resampledata(cfgResample, rawData);

    cfgFilter = [];
    cfgFilter.bpfilter = 'yes';
    cfgFilter.bpfreq = prepBand;
    cfgFilter.bpfiltord = prepBandOrd;
    cfgFilter.bpfilttype = 'but';
    if useNotch50
        cfgFilter.dftfilter = 'yes';
        cfgFilter.dftfreq = 50;
    end
    prepData = ft_preprocessing(cfgFilter, resampledData);
end
