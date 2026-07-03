function elapsedTime = getElapsedTime(startTime)
% getElapsedTime  Convenience wrapper around Psychtoolbox GetSecs.
%
%   elapsedTime = getElapsedTime(startTime) returns the number of seconds
%   that have elapsed since the reference time `startTime`, typically the
%   experiment start timestamp (obtained via GetSecs).

    elapsedTime = GetSecs - startTime;
end 