local utils = require 'mp.utils'
-- Startup time varies: mpv sets up its fonts on the first OSD text and the
-- packaged scripts work through their first messages meanwhile. Ask for the
-- panel, then wait for it instead of checking at one fixed moment.
local function panel_open() return mp.get_property_native('user-data/mpv/console/open') == true end
local started, asked = mp.get_time(), nil
local timer
timer = mp.add_periodic_timer(0.1, function()
    local now = mp.get_time()
    if now - started < 0.8 then return end
    if not panel_open() then
        assert(now - started < 8, 'native panel must open')
        -- Lua state has no protocol test double: splay requests status from the DLL.
        -- A request that arrives before the interface is ready is repeated.
        if not asked or now - asked > 2 then
            asked = now
            mp.commandv('script-message-to', 'splay', 'splay-open', 'native')
        end
        return
    end
    timer:kill()
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
