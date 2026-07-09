function resampledIndex = rawSampleToResampledIndex(rawSample, downsampleFactor)
% rawSampleToResampledIndex  Converts a 1-based sample index in the native
% (raw) sampling-rate timeline into the corresponding 1-based index after
% decimating by the integer downsampleFactor (as used by
% preprocessContinuousEeg.m). Matches the convention used in
% analysis/singleParticipantBehaviourOffline.m's rawToDownsampledSample.

    resampledIndex = round((rawSample - 1) / downsampleFactor) + 1;
end
