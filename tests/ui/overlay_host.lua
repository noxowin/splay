-- Offline UI fixture. Runner copies this as splay.lua so directed commands have
-- the same recipient as production. This does not exercise the network core.
local mp=require 'mp'
local utils=require 'mp.utils'
local input=require 'mp.input'
local count=0
local function action(kind,value)
    count=count+1
    mp.set_property_native('user-data/overlay-test/action',{count=count,kind=kind,value=value})
end
mp.register_script_message('splay-overlay-ready',function() action('handshake',true) end)
mp.register_script_message('splay-open',function(mode)
    action('panel',mode)
    if mode=='uosc' then
        mp.commandv('script-message-to','uosc','open-menu',utils.format_json({type='splay',title='同步面板 · 离线界面测试',items={{title='本测试使用模拟核心',selectable=false}}}))
    else input.select({prompt='同步面板 · 离线界面测试',items={'本测试使用模拟核心'},submit=function() end}) end
end)
mp.register_script_message('splay-command',function(json)
    local value=utils.parse_json(json)
    assert(value.action=='ready' and type(value.ready)=='boolean')
    action('ready',value.ready)
end)
mp.register_script_message('splay-chat',function()
    action('chat',true)
    input.get({prompt='发送聊天',submit=function(value) action('chat-submit',value) end})
end)
