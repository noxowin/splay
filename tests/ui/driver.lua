local utils=require 'mp.utils'
local opt={mode='native',output=''}
require('mp.options').read_options(opt,'driver')
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
                after(.6,function()
                    print('UOSC_MENU '..(mp.get_property_native('user-data/uosc/menu/type') or 'none'))
                    mp.osd_message('',0)
                    if opt.output~='' then mp.commandv('screenshot-to-file',opt.output..'/home-disconnected.png','window') end
                    mp.commandv('script-message-to','uosc','close-menu','splay')
                    mp.commandv('script-message-to','console','disable')
                    after(.2,function()
                        local duration=mp.get_property_native('duration')
                        assert(type(duration)=='number' and duration>0,'isolated fixture media must be loaded')
                        mp.commandv('script-message-to','splay','splay-state',utils.format_json({schema=1,
                            connection='connected',host='syncplay.test',port=8999,username='本机',room='UI 验收房间',ready=true,
                            autostart={enabled=false,pending=false,reason='disabled'},
                            members={{username='本机',room='UI 验收房间',ready=true,file={name='**Hidden filename**',duration=duration}},
                                {username='同伴',room='UI 验收房间',ready=true,file={name='另一剪辑版.mp4',duration=duration+12.3}}}}))
                        mp.commandv('script-message-to','splay','splay-open',opt.mode)
                        after(.25,function()
                            if opt.output~='' then mp.commandv('screenshot-to-file',opt.output..'/home-connected.png','window') end
                            mp.commandv('script-message-to','splay','splay-action','members')
                            after(.4,function()
                                local opened=opt.mode=='uosc' and mp.get_property_native('user-data/uosc/menu/type')=='splay' or
                                    opt.mode=='native' and mp.get_property_native('user-data/mpv/console/open')==true
                                assert(opened,'production member details must open')
                                if opt.output~='' then mp.commandv('screenshot-to-file',opt.output..'/members.png','window') end
                                mp.commandv('script-message-to','splay','splay-action','member-details:同伴')
                                after(.35,function()
                                    if opt.output~='' then mp.commandv('screenshot-to-file',opt.output..'/members-details.png','window') end
                                    print('UI_MEMBER_DETAILS '..opt.mode)
                                    after(.15,function() print('UI_SMOKE_COMPLETED');mp.commandv('quit') end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end)
