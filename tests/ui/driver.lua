local utils=require 'mp.utils'
mp.register_script_message('ui-test-command',function(json)
    print('COMMAND '..json)
end)
local function after(delay,callback)
    mp.add_timeout(delay,function()
        local ok,reason=xpcall(callback,debug.traceback)
        if not ok then mp.msg.error(reason);mp.commandv('quit',2) end
    end)
end
local function wait_until(description,condition,done)
    local deadline=mp.get_time()+5
    local function poll()
        if condition() then done()
        elseif mp.get_time()>deadline then error('Timed out: '..description)
        else after(.05,poll) end
    end
    after(0,poll)
end
after(0.5,function()
    assert(mp.get_property_native('user-data/splay').enabled==false,'splay must start disabled')
    mp.commandv('script-message-to','splay','splay-state',utils.format_json({schema=1,
        connection='disconnected',encrypted=false,members={{username='{bad}\\N',room='x',ready=false}},ready=false}))
    mp.commandv('script-message-to','splay','splay-open','native')
    wait_until('native panel opens',function() return mp.get_property_native('user-data/mpv/console/open')==true end,function()
        mp.commandv('script-message-to','console','disable')
        wait_until('native panel closes',function() return mp.get_property_native('user-data/mpv/console/open')~=true end,function()
            mp.commandv('script-message-to','splay','splay-action','toggle-enabled')
            wait_until('splay enables',function() return mp.get_property_native('user-data/splay').enabled==true end,function()
                mp.commandv('script-message-to','splay','splay-open','uosc')
                after(.35,function()
                    print('UOSC_MENU '..(mp.get_property_native('user-data/uosc/menu/type') or 'none'))
                    print('UI_SMOKE_COMPLETED');mp.commandv('quit')
                end)
            end)
        end)
    end)
end)
