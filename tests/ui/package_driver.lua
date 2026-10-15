local utils = require 'mp.utils'
mp.add_timeout(0.8, function()
    -- Lua state has no protocol test double: splay requests status from the DLL.
    mp.commandv('script-message-to', 'splay', 'splay-open', 'native')
end)
mp.add_timeout(1.5, function()
    assert(mp.get_property_native('user-data/mpv/console/open') == true, 'native panel must open')
    local overlay=mp.get_property_native('user-data/splay-overlay')
    assert(type(overlay)=='table' and overlay.enabled==false and overlay.status_shown==false,
        'packaged overlay must initialize with the feature disabled and status hidden')
    print('PACKAGE_OVERLAY_LOADED true')
    local playlist=mp.get_property_native('user-data/splay-playlist')
    assert(type(playlist)=='table' and playlist.follow==false and playlist.count==0,
        'packaged playlist must initialize without following or replacing media')
    print('PACKAGE_PLAYLIST_LOADED true')
    print('PACKAGE_NATIVE_OPEN true')
    print('PACKAGE_SMOKE_COMPLETED')
    mp.commandv('quit')
end)
