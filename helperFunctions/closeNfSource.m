function nfState = closeNfSource(nfState)
% closeNfSource  Releases whatever openNfSource.m opened. A no-op for the
% file source (nothing is held open between reads there), and for TCP it
% closes the socket so a re-run of the script can connect again without the
% server still holding a dead client.
%
% Every step is wrapped: this is called from cleanup paths, including the
% error path, where the connection may already be gone and where throwing
% would mask the original error.

    if ~isstruct(nfState) || ~isfield(nfState, 'client') || isempty(nfState.client)
        return;
    end

    try
        if nfState.useLegacyTcpip
            fclose(nfState.client);
        end
        delete(nfState.client);
    catch
    end

    % The socket only actually closes once the LAST reference to the client
    % object is gone, so the caller has to take the emptied struct back -
    % nfState = closeNfSource(nfState) - or its own copy keeps the
    % connection alive and the server keeps a dead client on its list.
    nfState.client = [];
    nfState.buffer = uint8([]);
end
