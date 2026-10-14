local utils = require 'mp.utils'
mp.add_timeout(0.8, function()
    -- Lua state has no protocol test double: splay requests status from the DLL.
    mp.commandv('script-message-to', 'splay', 'splay-open', 'native')
end)
mp.add_timeout(1.5, function()
    assert(mp.get_property_native('user-data/mpv/console/open') == true, 'native panel must open')
    print('PACKAGE_NATIVE_OPEN true')
    print('PACKAGE_SMOKE_COMPLETED')
    mp.commandv('quit')
end)
