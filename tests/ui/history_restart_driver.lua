local utils=require 'mp.utils'
local opts={stage='profile'}
require('mp.options').read_options(opts,'history_restart')
local function action(value) mp.commandv('script-message-to','splay','splay-action',value) end
local function submit(value)
    -- Exercise the real mp.input callback used by the native console form.
    mp.commandv('script-message-to','splay','input-event','submit',utils.format_json({value}))
end
mp.observe_property('user-data/splay','native',function(_,value)
    if type(value)=='table' then
        assert(value.connection~='connecting' and value.connection~='connected','history must not reconnect')
    end
end)
mp.add_timeout(1.0,function()
    local value=mp.get_property_native('user-data/splay')
    assert(type(value)=='table' and value.enabled==false,'every fresh player must start disabled')
    print('HISTORY_RESTART_DISABLED true')
    action('toggle-enabled')
end)
mp.add_timeout(1.3,function()
    if opts.stage=='profile' then action('save-profile')
    else action(opts.stage=='draft' and 'room' or 'username') end
end)
mp.add_timeout(1.6,function()
    if opts.stage~='profile' then submit(1) end -- history: manual input
end)
mp.add_timeout(1.9,function()
    if opts.stage~='profile' then submit(opts.stage=='draft' and '' or '重启昵称') end
end)
mp.add_timeout(2.3,function()
    if opts.stage~='profile' then
        action('save-profile') -- blank room must never create a complete profile
        action('connect') -- blank room must be stopped before the native connection command
    end
end)
mp.add_timeout(2.8,function()
    local value=mp.get_property_native('user-data/splay')
    assert(type(value)=='table' and value.enabled==true and value.connection=='disconnected')
    print('HISTORY_RESTART_SAVED '..opts.stage)
    mp.commandv('quit')
end)
