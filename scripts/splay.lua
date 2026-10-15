-- splay: optional Syncplay UI. Only non-secret history is saved by the native core.
local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'
local options = require 'mp.options'
-- Config supplies first-run defaults; saved preferences restore the last form.
local cfg = {host='', port=0, username='', room='', tls='', ui='native', history_enabled=true}
options.read_options(cfg, 'splay')
local defaults = {host='syncplay.pl', port=8999, username='splayuser', room='', tls='prefer'}
local fields = {'host','port','username','room','tls'}
local explicit, touched = {}, {}
for _,key in ipairs(fields) do
    explicit[key] = cfg[key]~='' and cfg[key]~=0
    if not explicit[key] then cfg[key]=defaults[key] end
end
local state = {schema=1,connection='disconnected',members={},ready=false}
local history = {last={},profiles={},values={}}
local history_loaded = false
local pending_saves = {}
local chats = {}
local enabled, page, input_open, enter_bound = false, 'home', false, false
local current_ui=cfg.ui
local chat_generation=0
local password, menu_open, nonce = '', false, 0
local show, act, publish, update_enter, chat
local function room_valid(room) return type(room)=='string' and room:find('%S')~=nil end
local function plain(v)
    local text=tostring(v or ''):gsub('[%c{}\\]',' ')
    if #text<=256 then return text end
    local finish=256
    while finish>0 and text:byte(finish+1)>=128 and text:byte(finish+1)<=191 do finish=finish-1 end
    return text:sub(1,finish)..'…'
end
local function parse_event(json)
    -- mpv strings end at NUL; preserve following text with a visible marker.
    json=json:gsub('(\\+)u0000',function(slashes)
        if #slashes%2==1 then return slashes:sub(1,-2)..'␀' end
        return slashes..'u0000'
    end)
    return utils.parse_json(json)
end
local function send(t)
    mp.commandv('script-message-to', 'splay_core', 'splay-command', utils.format_json(t))
end
local function overlay(name, payload)
    mp.commandv('script-message-to', 'splay_overlay', name, payload or '')
end
local function save(remember,freeze)
    if not cfg.history_enabled then return end
    if remember and not room_valid(cfg.room) then mp.osd_message('请先输入或选择房间',3);return end
    local settings={}
    for _,key in ipairs(fields) do settings[key]=cfg[key] end
    settings.port=tonumber(settings.port)
    local command={action='history-save',settings=settings,remember_profile=remember==true}
    if not history_loaded then
        local edited={}
        for _,key in ipairs(fields) do edited[key]=touched[key]==true end
        pending_saves[#pending_saves+1]={command=command,edited=edited,freeze=freeze==true}
    else send(command) end
end
local function edit(key,value)
    if cfg[key]~=value then password='' end
    cfg[key]=value; touched[key]=true; save(false);publish()
end
local function connect()
    if not enabled then return end
    if not room_valid(cfg.room) then
        mp.osd_message('请先输入或选择房间，然后点击连接',3)
        mp.add_timeout(0,function() act('room') end);return
    end
    chat_generation=chat_generation+1
    save(true,true)
    send({action='connect',host=cfg.host,port=tonumber(cfg.port),username=cfg.username,
        room=cfg.room,password=password,tls=cfg.tls})
end
local function close_menu()
    menu_open=false
    overlay('splay-menu-close')
    mp.commandv('script-message-to','uosc','close-menu','splay')
end
local function prompt(label,initial,callback,secret,reopen)
    close_menu(); nonce=nonce+1;input_open=true;update_enter()
    input.get({prompt=label..(secret and '（本机可见，仅内存；可能留在本进程输入历史）: ' or ': '),
        default_text=secret and '' or tostring(initial or ''),
        id=secret and ('splay-secret-'..nonce) or ('splay-'..label),
        closed=function() input_open=false;update_enter() end,
        submit=function(value)
            if type(value)=='string' and #value<=4096 and not value:find('[%c]') then callback(value) end
            if reopen~=false then mp.add_timeout(0,function() show(nil,page) end) end
        end})
end
local function select(title,items,callback)
    close_menu();input_open=true;update_enter()
    input.select({prompt=title,items=items,submit=callback,closed=function() input_open=false;update_enter() end})
end
local connection_labels={disconnected='未连接',connecting='连接中',connected='已连接',error='错误'}
local warning_labels={
    ['Waiting for media; synchronization is suspended']='等待媒体；同步已暂停',
    ['Synchronization requires playback speed 1.0; synchronization is suspended']='同步需要 1x 播放速度；同步已暂停',
    ['Buffering or seeking; synchronization is suspended']='缓冲或跳转中；同步已暂停',
    ['Media is not seekable; position synchronization is unavailable']='媒体不可跳转；无法同步播放位置',
}
local function connection_label() return connection_labels[state.connection] or plain(state.connection) end
local function warning_label() return plain(warning_labels[state.warning] or state.warning) end
local function rows(which)
    which=which or page
    local toggle={title='splay: '..(enabled and '开启（点击关闭）' or '关闭（点击开启）'),value='toggle-enabled'}
    if not enabled then return {toggle} end
    if which=='connection' then return {
        {title='‹ 返回',value='home'},
        {title='服务器: '..plain(cfg.host),value='host'},
        {title='端口: '..plain(cfg.port),value='port'},
        {title='昵称: '..plain(cfg.username),value='username'},
        {title='房间: '..(room_valid(cfg.room) and plain(cfg.room) or '请先输入或选择'),value='room'},
        {title=state.connection=='connected' and '使用填写值重新连接' or '连接',value='connect'},
        {title=state.connection=='connected' and '断开连接' or '历史连接组合（仅填表）: '..#(history.profiles or {}),value=state.connection=='connected' and 'disconnect' or 'profiles'},
    } end
    if which=='settings' then return {
        {title='‹ 返回',value='home'},
        {title='TLS: '..plain(cfg.tls),value='tls'},
        {title='服务器密码: '..(password=='' and '空' or '仅内存'),value='password'},
        {title='显示设置',value='display'},
        {title='保存当前连接组合',value='save-profile'},
        {title='历史连接组合（仅填表）: '..#(history.profiles or {}),value='profiles'},
        {title='房间操作',value='room-actions'},
    } end
    if which=='display' then return {
        {title='‹ 返回设置',value='settings'},
        {title='显示 / 隐藏状态文字',value='toggle-status'},
        {title='显示 / 隐藏鼠标按钮',value='toggle-buttons'},
    } end
    if which=='room-actions' then return {
        {title='‹ 返回',value='home'},
        {title='填写 / 选择房间',value='room'},
        {title='切换到填写房间',value='join-room'},
        {title='认证房间操作员',value='authenticate'},
        {title='创建受控房间',value='create-room'},
        {title='本连接聊天记录: '..#chats,value='chat-history'},
    } end
    if which=='members' then
        local result={{title='‹ 返回',value='home'}}
        for _,member in ipairs(state.members or {}) do
            result[#result+1]={title=plain(member.username)..' | '..plain(member.room)..' | '..
                (member.ready==true and '已准备' or (member.ready==false and '未准备' or '准备状态未知'))..
                (member.is_controller and ' | 操作员' or ''),value='noop',selectable=false}
        end
        if #result==1 then result[2]={title='暂无成员',value='noop',selectable=false} end
        return result
    end
    local result={toggle}
    if state.connection~='connected' then result[#result+1]={title='连接',value='connect'} end
    result[#result+1]={title='连接设置 · '..(room_valid(cfg.room) and plain(cfg.room) or '房间未填写'),value='connection'}
    if state.connection=='connected' then
        result[#result+1]={title='准备: '..(state.ready==true and '是' or '否'),value='ready'}
        result[#result+1]={title='发送聊天（Enter）',value='chat'}
        result[#result+1]={title='房间成员: '..#(state.members or {}),value='members'}
    end
    result[#result+1]={title='设置',value='settings'}
    return result
end
local page_titles={home='splay',connection='连接设置',settings='设置',display='显示设置',members='房间成员',['room-actions']='房间操作'}
local function title(which)
    return (page_titles[which] or 'splay')..' | '..(enabled and connection_label() or '已关闭')
end
local function menu()
    return {type='splay',title=title(page),footnote=enabled and (plain(state.error)~='' and plain(state.error) or warning_label()) or '',
        items=rows(),callback={'splay','splay-menu-event'},
        on_close={'script-message-to','splay','splay-menu-closed'}}
end
publish=function()
    state.enabled=enabled
    overlay('splay-state',utils.format_json(state))
    overlay('splay-menu-model',utils.format_json({title=title('home'),items=rows('home'),enabled=enabled}))
    mp.set_property_native('user-data/splay',{enabled=enabled,connection=state.connection,room=state.room})
    if menu_open then mp.commandv('script-message-to','uosc','update-menu',utils.format_json(menu())) end
    update_enter()
end
show=function(mode,which)
    current_ui=mode or current_ui
    page=which or 'home'
    if not enabled then page='home' end
    if enabled then send({action='status'}) end
    close_menu()
    if current_ui=='uosc' then
        menu_open=true;update_enter()
        mp.commandv('script-message-to','uosc','open-menu',utils.format_json(menu()))
        mp.add_timeout(0.4,function()
            if menu_open and mp.get_property_native('user-data/uosc/menu/type')~='splay' then
                menu_open=false;mp.osd_message('uosc 无响应，打开原生面板',3);show('native',page)
            end
        end)
    else
        if mp.get_property_native('options/load-console')==false then
            mp.osd_message('splay 需要 mpv console 脚本；请启用 load-console',5);return
        end
        local entries,labels=rows(),{}
        for i,item in ipairs(entries) do labels[i]=item.title end
        input_open=true;update_enter()
        input.select({prompt=menu().title,items=labels,closed=function() input_open=false;update_enter() end,submit=function(i)
            if entries[i] and entries[i].selectable~=false then mp.add_timeout(0,function()
                act(entries[i].value)
                if entries[i].value=='toggle-enabled' then show('native') end
            end) end
        end})
    end
end
local function chat_available()
    return enabled and state.connection=='connected' and state.chat_supported==true and
        (tonumber(state.chat_max_length) or 150)>0 and
        type(mp.get_property_native('path'))=='string' and mp.get_property_native('path')~='' and
        mp.get_property_native('idle-active')~=true
end
local function other_input_open()
    local popup=mp.get_property_native('user-data/splay-overlay')
    return input_open or menu_open or mp.get_property_native('user-data/mpv/console/open')==true or
        mp.get_property_native('user-data/mpv/context-menu/open')==true or
        mp.get_property_native('user-data/uosc/menu/type')~=nil or
        (type(popup)=='table' and popup.popup_open==true)
end
update_enter=function()
    local wanted=chat_available() and not other_input_open()
    if wanted and not enter_bound then
        mp.add_forced_key_binding('ENTER','splay-chat-enter',function() if chat_available() and not other_input_open() then chat() end end)
        enter_bound=true
    elseif not wanted and enter_bound then mp.remove_key_binding('splay-chat-enter');enter_bound=false end
end
chat=function()
    if not chat_available() or other_input_open() then return end
    local limit=tonumber(state.chat_max_length) or 150
    local generation=chat_generation
    prompt('发送聊天（Enter 发送，Esc 取消；最多 '..limit..' 字符）','',function(text)
        local _,count=text:gsub('[^\128-\191]','')
        if count>limit then mp.osd_message('聊天超过服务器字符上限 '..limit,4);return end
        if text~='' and chat_available() and generation==chat_generation then send({action='chat',text=text}) end
    end,false,false)
end
local field_labels={host='服务器',port='端口',username='昵称',room='房间',tls='TLS'}
local function field_edit(key)
    local function manual()
        if key=='tls' then
            select('TLS 策略',{'prefer（明确不支持时允许明文）','require（强制 TLS）','off（明文）'},function(i)
                local value=({'prefer','require','off'})[i];if value then edit(key,value) end
            end)
        else
            prompt(field_labels[key],cfg[key],function(value)
                if key=='port' then
                    value=tonumber(value)
                    if not value or value<1 or value>65535 or value%1~=0 then mp.osd_message('端口必须为 1–65535',3);return end
                elseif value=='' and key~='room' then mp.osd_message('字段不能为空',3);return end
                edit(key,value)
            end)
        end
    end
    local values=(history.values or {})[key] or {}
    if #values==0 then manual();return end
    local labels={'手动输入 / 选择'}
    for _,value in ipairs(values) do labels[#labels+1]=plain(value) end
    select(field_labels[key]..'历史（仅填表）',labels,function(i)
        if i==1 then mp.add_timeout(0,manual) elseif values[i-1]~=nil then edit(key,values[i-1]) end
    end)
end
act=function(action)
    if action=='toggle-enabled' then
        enabled=not enabled
        chat_generation=chat_generation+1
        if enabled then send({action='status'})
        else
            send({action='disconnect'});chats={}
            state={schema=1,connection='disconnected',members={},ready=false}
            if input_open then input.terminate();input_open=false end
        end
        page='home';publish();return
    end
    if action=='home' or action=='connection' or action=='members' or action=='settings' or action=='display' or action=='room-actions' then
        show(nil,action);return
    end
    if not enabled then return end
    overlay('splay-menu-close')
    if action=='refresh' then show(nil,page)
    elseif action=='connect' then connect()
    elseif action=='disconnect' then chat_generation=chat_generation+1;send({action='disconnect'})
    elseif action=='join-room' then
        if state.connection~='connected' then mp.osd_message('请先连接',3)
        elseif not room_valid(cfg.room) then mp.osd_message('请先输入或选择房间',3)
        else chat_generation=chat_generation+1;send({action='room',room=cfg.room});save(true) end
    elseif action=='ready' then if state.connection=='connected' then send({action='ready',ready=not state.ready}) end
    elseif action=='clear-password' then password=''
    elseif action=='save-profile' then save(true)
    elseif action=='profiles' then
        local labels={}
        for i,p in ipairs(history.profiles or {}) do labels[i]=plain(p.host)..':'..plain(p.port)..' | '..plain(p.username)..' | '..plain(p.room)..' | '..plain(p.tls) end
        if #labels==0 then mp.osd_message('尚无历史连接组合',3);return end
        select('选择历史连接组合（仅填表；密码已清除）',labels,function(i)
            local profile=history.profiles[i];if not profile then return end
            password=''
            for _,key in ipairs(fields) do cfg[key]=profile[key];touched[key]=true end
            save(false);publish();mp.osd_message('历史已填入；点击连接或切换房间才应用',3)
        end)
    elseif action=='chat' then
        close_menu()
        -- Overlay/uosc menus close in another Lua client; wait for their published
        -- open flags before opening mp.input, which must own Enter itself.
        local attempts=0
        local function open_chat()
            if not other_input_open() then chat()
            elseif attempts<25 then attempts=attempts+1;mp.add_timeout(0.02,open_chat) end
        end
        open_chat()
    elseif action=='chat-history' then
        local labels={}
        for i,event in ipairs(chats) do labels[i]=plain(event.username)..': '..plain(event.text) end
        if #labels==0 then mp.osd_message('本连接房间尚无聊天记录',3);return end
        select('本连接房间聊天记录（最多 100 条；不保存到磁盘）',labels,function() end)
    elseif action=='toggle-status' then overlay('overlay-toggle-status')
    elseif action=='toggle-buttons' then overlay('overlay-toggle-buttons')
    elseif action=='authenticate' then prompt('操作员密码 AB-123-456','',function(value) send({action='authenticate',password=value}) end,true)
    elseif action=='create-room' then
        prompt('新受控房间','',function(room)
            if not room_valid(room) then mp.osd_message('请先输入或选择房间',3);return end
            edit('room',room)
            mp.add_timeout(0.01,function() prompt('新操作员密码 AB-123-456','',function(value)
                if enabled then send({action='create-room',room=room,password=value}) end
            end,true) end)
        end,false,false)
    elseif action=='password' then prompt('服务器密码','',function(value) password=value end,true)
    elseif field_labels[action] then field_edit(action) end
    publish()
end
mp.register_script_message('splay-history',function(json)
    if type(json)~='string' or #json>16777216 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 or type(value.profiles)~='table' or type(value.values)~='table' then return end
    history=value
    if not history_loaded then
        history_loaded=true
        for _,key in ipairs(fields) do
            if not touched[key] and type(value.last)=='table' and value.last[key]~=nil then
                cfg[key]=value.last[key]
                if key=='room' and type(cfg[key])=='string' and cfg[key]:lower()=='default' then cfg[key]='' end
            end
        end
        local queued=pending_saves;pending_saves={}
        for _,pending in ipairs(queued) do
            if not pending.freeze then
                for _,key in ipairs(fields) do
                    if not pending.edited[key] then pending.command.settings[key]=cfg[key] end
                end
            end
            send(pending.command)
        end
    end
    if enabled and value.error then mp.osd_message('splay 历史: '..plain(value.error),5) end
    publish()
end)
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    if state.connection~=value.connection or state.room~=value.room or state.username~=value.username then chat_generation=chat_generation+1 end
    if state.room~=value.room or (state.connection=='connected' and value.connection~='connected') then chats={} end
    state=value;publish()
end)
mp.register_script_message('splay-event',function(json)
    if not enabled or type(json)~='string' or #json>65536 then return end
    local value=parse_event(json)
    if type(value)~='table' or value.schema~=1 or (value.type~='chat' and value.type~='playback') then return end
    if value.type=='chat' and type(value.text)=='string' then
        chats[#chats+1]=value
        if #chats>100 then table.remove(chats,1) end
    end
    overlay('splay-event',json)
end)
mp.register_script_message('splay-overlay-ready',publish)
mp.register_script_message('splay-action',act)
mp.register_script_message('splay-chat',chat)
mp.register_script_message('splay-open',function(mode) show(mode=='uosc' and 'uosc' or 'native') end)
mp.register_script_message('splay-menu-closed',function() menu_open=false;update_enter() end)
mp.register_script_message('splay-menu-event',function(json)
    local event=utils.parse_json(json or '')
    if type(event)=='table' and event.type=='activate' and type(event.value)=='string' then act(event.value) end
end)
-- Automation forwards its exact command; only whitelisted settings enter history.
mp.register_script_message('splay-command',function(json)
    if type(json)~='string' or #json>16384 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or type(value.action)~='string' then return end
    if value.action=='connect' then
        if not room_valid(value.room) then mp.osd_message('请先输入或选择房间',3);return end
        chat_generation=chat_generation+1
        enabled=true
        password=''
        for _,key in ipairs(fields) do if value[key]~=nil then cfg[key]=value[key];touched[key]=true end end
        password=type(value.password)=='string' and value.password or ''
        save(true,true)
    elseif not enabled and value.action~='status' and value.action~='history-load' and value.action~='history-save' then return
    elseif value.action=='room' and type(value.room)=='string' then
        if not room_valid(value.room) then mp.osd_message('请先输入或选择房间',3);return end
        chat_generation=chat_generation+1
        cfg.room=value.room;touched.room=true;password='';save(true)
    elseif value.action=='create-room' and not room_valid(value.room) then mp.osd_message('请先输入或选择房间',3);return
    end
    send(value);publish()
end)
mp.add_key_binding('Shift+s','splay-panel',function() show() end)
local history_path=mp.command_native({'expand-path','~~/splay-history.json'})
local function load_history()
    if cfg.history_enabled and not history_loaded and type(history_path)=='string' and history_path~='' then
        send({action='history-load',path=history_path})
    end
end
load_history()
for _,delay in ipairs({0.2,0.5,1,2}) do mp.add_timeout(delay,load_history) end
for _,property in ipairs({'path','idle-active','user-data/mpv/console/open','user-data/mpv/context-menu/open','user-data/uosc/menu/type','user-data/splay-overlay'}) do
    mp.observe_property(property,'native',function() update_enter() end)
end
publish()
mp.register_event('shutdown',function() password='';chats={} end)
