function escapePressed = checkEscape(escapeKey)
    [keyIsDown, ~, keyCode] = KbCheck(-1);
    escapePressed = keyIsDown && keyCode(escapeKey);
end
