-- Offline presentation fixture: no native core or network.
local mp=require 'mp'
local utils=require 'mp.utils'
local input=require 'mp.input'
local state={schema=1,enabled=false,connection='disconnected',members={}}
local count=0
local function action(kind,value)
    count=count+1
    mp.set_property_native('user-data/overlay-test/action',{count=count,kind=kind,value=value})
end
local function publish()
    mp.commandv('script-message-to','splay_overlay','splay-state',utils.format_json(state))
    mp.commandv('script-message-to','splay_overlay','splay-menu-model',utils.format_json({
        title='同步播放',enabled=state.enabled,items={
            {title=state.enabled and '关闭同步播放' or '启用同步播放',value='toggle-enabled'},
            {title='连接设置…',value='settings'},
            {title='房间与成员…',value='members',selectable=state.enabled},
            {title=state.ready and '取消准备' or '我已准备',value='ready',selectable=state.enabled and state.connection=='connected'},
            {title='发送聊天…',value='chat',selectable=state.enabled and state.connection=='connected'},
            {title='服务器历史…',value='history'}}}))
end
mp.register_script_message('splay-overlay-ready',function() action('handshake',true); publish() end)
mp.register_script_message('fixture-test-state',function(json) state=utils.parse_json(json); publish() end)
mp.register_script_message('splay-action',function(value)
    action('action',value)
    if value=='toggle-enabled' then state.enabled=not state.enabled; publish(); return end
    mp.commandv('script-message-to','splay_overlay','splay-menu-close')
    if value=='ready' then state.ready=not state.ready; publish()
    elseif value=='chat' then
        input.get({prompt='发送聊天',submit=function(text) action('chat-submit',text) end})
    elseif mp.get_property_native('user-data/overlay-test/mode')=='uosc' then
        mp.commandv('script-message-to','uosc','open-menu',utils.format_json({type='splay',title='同步设置 · 离线测试',items={{title='本测试使用模拟核心',selectable=false}}}))
    else input.select({prompt='同步设置 · 离线测试',items={'本测试使用模拟核心'},submit=function() end}) end
end)

mp.register_script_message('fixture-foreign-menu',function()
    input.select({prompt='其他输入',items={'原有菜单'},submit=function() end})
end)
