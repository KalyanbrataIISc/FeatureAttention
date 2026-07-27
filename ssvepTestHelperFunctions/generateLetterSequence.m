function [letters, xCount] = generateLetterSequence(numLetters, letterPool, xCountMin, xCountMax)
% generateLetterSequence  Builds a numLetters-long sequence drawn from
% letterPool (a char array that must include 'X') with two constraints:
% the same letter never appears on two consecutive slots, and 'X' appears
% exactly xCount times, xCount drawn uniformly from [xCountMin, xCountMax]
% (clamped to what fits without ever placing two X's back to back).
%
% X placement uses the standard bijection for choosing k non-adjacent
% slots out of n: pick k indices from the first (n-k+1) slots without
% replacement, sort them, then spread them out by adding 0,1,...,k-1 - this
% always lands on k slots with no two adjacent, and can represent every
% such arrangement.

    maxPossibleXCount = ceil(numLetters / 2);
    xCountMax = min(xCountMax, maxPossibleXCount);
    xCountMin = min(xCountMin, xCountMax);
    xCount = randi([xCountMin, xCountMax]);

    numGapSlots = numLetters - xCount + 1;
    compressedPositions = sort(randperm(numGapSlots, xCount));
    xPositions = compressedPositions + (0:xCount - 1);

    nonXPool = letterPool(letterPool ~= 'X');
    letters = repmat('X', 1, numLetters);
    isXSlot = false(1, numLetters);
    isXSlot(xPositions) = true;

    prevLetter = char(0); % sentinel that can't equal any real letter, so slot 1 is unconstrained
    for i = 1:numLetters
        if isXSlot(i)
            prevLetter = 'X';
            continue;
        end
        candidates = nonXPool(nonXPool ~= prevLetter);
        letters(i) = candidates(randi(numel(candidates)));
        prevLetter = letters(i);
    end
end
