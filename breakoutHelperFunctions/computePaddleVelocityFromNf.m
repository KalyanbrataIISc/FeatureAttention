function paddleVxPxPerFrame = computePaddleVelocityFromNf(nf17, nf20, ...
    gainPxPerSecPerNf, maxSpeedPxPerSec, deadzone, interFrameInterval)
% computePaddleVelocityFromNf  Maps real-time SSVEP lateralisation to the
% paddle's horizontal velocity. This is the neurofeedback loop of the task:
% the paddle the participant needs in order to keep the ball alive is the
% same object whose two flickering gratings generate the signal that moves it.
%
% Mapping. nf17 is positive when 17 Hz SSVEP power exceeds 20 Hz, nf20 is
% positive when 20 Hz exceeds 17 Hz. 17 Hz dominance drives the paddle LEFT
% (-x), 20 Hz dominance drives it RIGHT (+x), so the signed drive is
%
%     nfSigned = nf20 - nf17
%
% Both columns are used rather than just one: RT_acquisition_8 writes them as
% two separately-computed measures, so differencing them is symmetric and
% stays correct even if they are not exact negatives of each other.
%
% Speed is linear in that drive (gainPxPerSecPerNf), clamped to
% +/- maxSpeedPxPerSec. The deadzone pins near-neutral lateralisation to
% exactly zero, so the paddle sits still instead of jittering on top of the
% noise floor. Set deadzone to 0 to disable it.
%
% Returns px per displayed frame, ready to add to the paddle's position.

    nfSigned = nf20 - nf17;        % + = right, - = left
    if abs(nfSigned) < deadzone
        nfSigned = 0;
    end

    vxPxPerSec = gainPxPerSecPerNf * nfSigned;
    vxPxPerSec = max(-maxSpeedPxPerSec, min(maxSpeedPxPerSec, vxPxPerSec));

    paddleVxPxPerFrame = vxPxPerSec * interFrameInterval;
end
