function value = truncatedExpRnd(meanSec, capSec)
% truncatedExpRnd  Draws from an exponential distribution with mean
% meanSec (via inverse transform, no toolbox required), resampling if the
% draw exceeds capSec. This keeps the foreperiod bounded while preserving
% the flat-hazard property of the exponential distribution.

    maxAttempts = 100;
    value = capSec;
    for attempt = 1:maxAttempts
        candidate = -meanSec * log(rand());
        if candidate <= capSec
            value = candidate;
            return;
        end
    end
end
