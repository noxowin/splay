local utils=require 'mp.utils'
local opts={stage='profile'}
require('mp.options').read_options(opts,'history_restart')
local function after(seconds,callback)
    mp.add_timeout(seconds,function()
        local ok,reason=xpcall(callback,debug.traceback)
        if not ok then mp.msg.error(reason);mp.commandv('quit',2) end
    end)
end
local function action(value) mp.commandv('script-message-to','splay','splay-action',value) end
local function submit_text(value)
    -- Use the real console's keys: recent mpv uses per-request input-event/N
    -- handlers, so tests must not assume the older private callback name.
    assert(mp.get_property_native('user-data/mpv/console/open')==true,'text prompt must be open')
    mp.commandv('keypress','Ctrl+a');mp.commandv('keypress','Ctrl+k')
    for character in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do mp.commandv('keypress',character) end
    mp.commandv('keypress','ENTER')
end
local host_shortcuts=0
mp.add_key_binding('Shift+h','history-host-shortcut',function() host_shortcuts=host_shortcuts+1 end)
mp.observe_property('user-data/splay','native',function(_,value)
    if type(value)=='table' then
        if value.connection=='connecting' or value.connection=='connected' then
            mp.msg.error('history must not reconnect');mp.commandv('quit',2)
        end
    end
end)
after(.8,function() mp.commandv('keypress','Shift+h') end)
after(1.0,function()
    local value=mp.get_property_native('user-data/splay')
    assert(type(value)=='table' and value.enabled==false,'every fresh player must start disabled')
    assert(host_shortcuts==1,'disabled splay must preserve the host history shortcut')
    print('HISTORY_RESTART_DISABLED true')
    action('toggle-enabled')
end)
after(1.3,function()
    if opts.stage=='profile' then action('save-profile')
    else action(opts.stage=='draft' and 'room' or 'username') end
end)
after(1.6,function()
    if opts.stage~='profile' then
        assert(mp.get_property_native('user-data/mpv/console/open')==true,'history selector must open')
        mp.commandv('keypress','ENTER') -- The selected first row is manual input.
    else
        mp.commandv('script-message-to','splay','splay-notice',utils.format_json({text='history shortcut fixture'}))
        after(.05,function() mp.commandv('keypress','Shift+h') end)
    end
end)
after(1.9,function()
    if opts.stage~='profile' then submit_text(opts.stage=='draft' and '' or '重启昵称')
    else
        assert(mp.get_property_native('user-data/mpv/console/open')==true,'enabled Shift+h must open production message history')
        assert(host_shortcuts==1,'enabled splay shortcut must receive its own binding')
        mp.commandv('keypress','ESC')
    end
end)
after(2.3,function()
    if opts.stage~='profile' then
        action('save-profile') -- blank room must never create a complete profile
        action('connect') -- blank room must be stopped before the native connection command
    end
end)
after(2.8,function()
    local value=mp.get_property_native('user-data/splay')
    assert(type(value)=='table' and value.enabled==true and value.connection=='disconnected')
    print('HISTORY_RESTART_SAVED '..opts.stage)
    action('toggle-enabled')
end)
after(3.0,function() mp.commandv('keypress','Shift+h') end)
after(3.2,function()
    assert(host_shortcuts==2,'disabling splay must restore the host history shortcut')
    print('HISTORY_SHORTCUT_RESTORED true')
    mp.commandv('quit')
end)
