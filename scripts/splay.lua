-- splay: optional Syncplay UI. The native core saves non-secret history and separately encrypted credentials.
local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'
local options = require 'mp.options'
-- Config supplies first-run defaults; saved preferences restore the last form.
local cfg = {host='', port=0, username='', room='', tls='', ui='native', history_enabled=true, remember_password=true}
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
local messages, seen_events, message_serial = {}, {}, 0
local credential_saved, credential_initialized = false, false
local credential_pending, credential_error
local credential_serial, credential_request, credential_init_request = 0, nil, nil
local credential_ready, credential_connect_waiting = false, false
local enabled, page, input_open, enter_bound, history_bound = false, 'home', false, false, false
local current_ui=cfg.ui
local chat_generation=0
local password, menu_open, nonce = '', false, 0
local input_generation=0
local show, act, publish, update_enter, chat, notice, connect, init_credentials
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
local function endpoint_host(value) return tostring(value or ''):match('^%s*(.-)%s*$'):lower() end
local function credential_id()
    credential_serial=credential_serial+1;return credential_serial
end
local function credential_reset()
    credential_saved=false;credential_ready=false;credential_error=nil
    credential_pending=nil;credential_request=nil;credential_connect_waiting=false
end
local function credential_dispatch()
    if not credential_initialized then if init_credentials then init_credentials() end;return end
    if credential_request then return end
    local pending=credential_pending
    local action=pending and pending.action or 'credential-status'
    local id=credential_id()
    credential_request={id=id,action=action,host=endpoint_host(cfg.host),port=tonumber(cfg.port)}
    send({action=action,request_id=id,host=cfg.host,port=tonumber(cfg.port),password=pending and pending.secret or nil})
end
local function credential_status()
    if credential_pending then return end
    credential_ready=false;credential_request=nil;credential_error=nil
    credential_dispatch()
end
local function credential_change(action,secret)
    credential_connect_waiting=false;credential_ready=false;credential_error=nil;credential_request=nil
    credential_pending={action=action,secret=secret}
    if action=='credential-save' then password=secret else password='';credential_saved=false end
    credential_dispatch()
end
local function append_message(text,category,id)
    local key=id and ('native:'..tostring(id)) or nil
    if key and seen_events[key] then return false end
    if key then seen_events[key]=true end
    messages[#messages+1]={text=plain(text),category=category or 'notice',time=os.date('%H:%M:%S'),key=key}
    if #messages>300 then
        local removed=table.remove(messages,1)
        if removed.key then seen_events[removed.key]=nil end
    end
    return true
end
notice=function(text,category)
    if not enabled or type(text)~='string' or text=='' then return end
    message_serial=message_serial+1
    append_message(text,category)
    overlay('splay-event',utils.format_json({schema=1,id='ui:'..message_serial,type='notice',text=plain(text),category=category or 'notice'}))
end
local function report(text,seconds,category)
    mp.osd_message(text,seconds or 3);notice(text,category or 'notice')
end
local function save(remember,freeze)
    if not cfg.history_enabled then return end
    if remember and not room_valid(cfg.room) then report('请先输入或选择房间',3);return end
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
    local changed_endpoint=(key=='host' or key=='port') and cfg[key]~=value
    credential_connect_waiting=false
    if changed_endpoint then password='';credential_reset() end
    cfg[key]=value; touched[key]=true; save(false);publish()
    if changed_endpoint then credential_status() end
end
connect=function()
    if not enabled then return end
    if not room_valid(cfg.room) then
        report('请先输入或选择房间，然后点击连接',3)
        mp.add_timeout(0,function() act('room') end);return
    end
    if cfg.remember_password then
        if credential_error then report('密码存储尚未就绪: '..plain(credential_error),5,'error');return end
        if not credential_initialized or not credential_ready or credential_pending or credential_request then
            credential_connect_waiting=true;credential_dispatch()
            report('正在读取或保存服务器密码，完成后连接',2);return
        end
    end
    credential_connect_waiting=false
    chat_generation=chat_generation+1
    save(true,true)
    send({action='connect',host=cfg.host,port=tonumber(cfg.port),username=cfg.username,
        room=cfg.room,password=password,tls=cfg.tls,use_saved_password=cfg.remember_password and password=='' and credential_saved,
        remember_password=cfg.remember_password})
    if cfg.remember_password then password='' end
end
local function close_menu()
    menu_open=false
    overlay('splay-menu-close')
    mp.commandv('script-message-to','uosc','close-menu','splay')
end
local function begin_input()
    input_generation=input_generation+1
    local generation=input_generation
    input_open=true;update_enter()
    return function()
        if generation==input_generation then input_open=false;update_enter() end
    end
end
local function prompt(label,initial,callback,secret,reopen)
    close_menu(); nonce=nonce+1
    local closed=begin_input()
    input.get({prompt=label..(secret and '（输入本机可见）: ' or ': '),
        default_text=secret and '' or tostring(initial or ''),
        id=secret and ('splay-secret-'..nonce) or ('splay-'..label),
        closed=closed,
        submit=function(value)
            if type(value)=='string' and #value<=4096 and not value:find('[%c]') then callback(value) end
            if reopen~=false then mp.add_timeout(0,function() show(nil,page) end) end
        end})
end
local function select(title,items,callback)
    close_menu()
    local closed=begin_input()
    input.select({prompt=title,items=items,submit=callback,closed=closed})
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
local function current_members()
    local members={}
    for _,member in ipairs(state.members or {}) do
        if type(member)=='table' and type(state.room)=='string' and member.room==state.room then members[#members+1]=member end
    end
    return members
end
local function rows(which)
    which=which or page
    local toggle={title='splay: '..(enabled and '开启（点击关闭）' or '关闭（点击开启）'),value='toggle-enabled'}
    if not enabled then return {toggle} end
    if which=='connection' then return {
        {title='‹ 返回',value='home'},
        {title='服务器: '..plain(cfg.host)..' : '..plain(cfg.port),value='endpoint'},
        {title='昵称: '..plain(cfg.username),value='username'},
        {title='房间: '..(room_valid(cfg.room) and plain(cfg.room) or '请先输入或选择'),value='room'},
        {title=state.connection=='connected' and '使用填写值重新连接' or '连接',value='connect'},
        {title=state.connection=='connected' and '断开连接' or '历史连接组合（仅填表）: '..#(history.profiles or {}),value=state.connection=='connected' and 'disconnect' or 'profiles'},
    } end
    if which=='settings' then return {
        {title='‹ 返回',value='home'},
        {title='TLS: '..plain(cfg.tls),value='tls'},
        {title='服务器密码: '..(credential_saved and (cfg.remember_password and '已加密保存' or '已保存（当前不使用）') or (password=='' and '空' or '仅本次')),value='password-settings'},
        {title='显示设置',value='display'},
        {title='保存当前连接组合',value='save-profile'},
        {title='历史连接组合（仅填表）: '..#(history.profiles or {}),value='profiles'},
        {title='房间操作',value='room-actions'},
    } end
    if which=='endpoint' then return {
        {title='‹ 返回连接设置',value='connection'},
        {title='服务器: '..plain(cfg.host),value='host'},
        {title='端口: '..plain(cfg.port),value='port'},
    } end
    if which=='password-settings' then return {
        {title='‹ 返回设置',value='settings'},
        {title='密码: '..(credential_saved and (cfg.remember_password and '已加密保存' or '已保存（当前不使用）') or (password=='' and '空' or '仅本次')),value='password'},
        {title='记住并使用已保存密码: '..(cfg.remember_password and '是' or '否'),value='toggle-remember-password'},
        {title='清除本次输入并删除已保存密码',value='clear-password'},
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
        {title='房间成员: '..#current_members(),value='members'},
    } end
    if which=='members' then
        local result={{title='‹ 返回房间操作',value='room-actions'}}
        for _,member in ipairs(current_members()) do
            result[#result+1]={title=plain(member.username)..' | '..plain(member.room)..' | '..
                (member.ready==true and '已准备' or (member.ready==false and '未准备' or '准备状态未知'))..
                (member.is_controller and ' | 操作员' or ''),value='noop',selectable=false}
        end
        if #result==1 then result[2]={title='暂无成员',value='noop',selectable=false} end
        return result
    end
    local result={toggle}
    result[#result+1]={title='服务器: '..plain(cfg.host)..':'..plain(cfg.port)..' · 房间: '..(room_valid(cfg.room) and plain(cfg.room) or '未填写'),value='connection'}
    if state.connection=='connected' then
        result[#result+1]={title='准备: '..(state.ready==true and '是' or '否'),value='ready'}
    else result[#result+1]={title='连接',value='connect'} end
    result[#result+1]={title='共享播放列表',value='playlist'}
    result[#result+1]={title='消息记录（Shift+h）: '..#messages,value='message-history'}
    result[#result+1]={title='设置',value='settings'}
    return result
end
local page_titles={home='splay',connection='连接设置',endpoint='服务器与端口',settings='设置',display='显示设置',members='房间成员',['room-actions']='房间操作',['password-settings']='服务器密码'}
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
    if enabled and not history_bound then
        mp.add_key_binding('Shift+h','splay-message-history',function() act('message-history') end)
        history_bound=true
    elseif not enabled and history_bound then
        mp.remove_key_binding('splay-message-history');history_bound=false
    end
    -- Display local filename only; never send this enriched UI state to the core.
    state.local_file=plain(mp.get_property_native('filename') or mp.get_property_native('media-title') or '')
    overlay('splay-state',utils.format_json(state))
    mp.commandv('script-message-to','splay_playlist','splay-state',utils.format_json(state))
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
                menu_open=false;report('uosc 无响应，打开原生面板',3);show('native',page)
            end
        end)
    else
        if mp.get_property_native('options/load-console')==false then
            report('splay 需要 mpv console 脚本；请启用 load-console',5);return
        end
        local entries,labels=rows(),{}
        for i,item in ipairs(entries) do labels[i]=item.title end
        local closed=begin_input()
        input.select({prompt=menu().title,items=labels,closed=closed,submit=function(i)
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
        if count>limit then report('聊天超过服务器字符上限 '..limit,4,'error');return end
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
                    if not value or value<1 or value>65535 or value%1~=0 then report('端口必须为 1–65535',3,'error');return end
                elseif value=='' and key~='room' then report('字段不能为空',3,'error');return end
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
            credential_connect_waiting=false
            send({action='disconnect'})
            state={schema=1,connection='disconnected',members={},ready=false}
            if input_open then input.terminate();input_open=false end
        end
        page='home';publish();return
    end
    if action=='home' or action=='connection' or action=='endpoint' or action=='members' or action=='settings' or action=='display' or action=='room-actions' or action=='password-settings' then
        show(nil,action);return
    end
    if not enabled then return end
    overlay('splay-menu-close')
    if action=='refresh' then show(nil,page)
    elseif action=='connect' then connect()
    elseif action=='disconnect' then credential_connect_waiting=false;chat_generation=chat_generation+1;send({action='disconnect'})
    elseif action=='join-room' then
        if state.connection~='connected' then report('请先连接',3)
        elseif not room_valid(cfg.room) then report('请先输入或选择房间',3)
        else chat_generation=chat_generation+1;send({action='room',room=cfg.room});save(true) end
    elseif action=='ready' then if state.connection=='connected' then send({action='ready',ready=not state.ready}) end
    elseif action=='clear-password' then
        password='';credential_change('credential-delete')
    elseif action=='toggle-remember-password' then
        cfg.remember_password=not cfg.remember_password
        credential_connect_waiting=false
        if cfg.remember_password and password~='' then
            credential_change('credential-save',password)
        end
    elseif action=='playlist' then
        close_menu();mp.commandv('script-message-to','splay_playlist','splay-playlist-open',current_ui)
    elseif action=='save-profile' then save(true)
    elseif action=='profiles' then
        local labels={}
        for i,p in ipairs(history.profiles or {}) do labels[i]=plain(p.host)..':'..plain(p.port)..' | '..plain(p.username)..' | '..plain(p.room)..' | '..plain(p.tls) end
        if #labels==0 then report('尚无历史连接组合',3);return end
        select('选择历史连接组合（仅填表）',labels,function(i)
            local profile=history.profiles[i];if not profile then return end
            password=''
            credential_reset()
            for _,key in ipairs(fields) do cfg[key]=profile[key];touched[key]=true end
            credential_status()
            save(false);publish();report('历史已填入；点击连接或切换房间才应用',3)
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
    elseif action=='chat-history' or action=='message-history' then
        local labels={}
        for i,event in ipairs(messages) do labels[i]='['..event.time..'] '..event.text end
        if #labels==0 then mp.osd_message('尚无消息记录',3);return end
        select('所有消息记录（最多 300 条；本进程内保留）',labels,function() end)
    elseif action=='toggle-status' then overlay('overlay-toggle-status')
    elseif action=='toggle-buttons' then overlay('overlay-toggle-buttons')
    elseif action=='authenticate' then prompt('操作员密码 AB-123-456','',function(value) send({action='authenticate',password=value}) end,true)
    elseif action=='create-room' then
        prompt('新受控房间','',function(room)
            if not room_valid(room) then report('请先输入或选择房间',3);return end
            edit('room',room)
            mp.add_timeout(0.01,function() prompt('新操作员密码 AB-123-456','',function(value)
                if enabled then send({action='create-room',room=room,password=value}) end
            end,true) end)
        end,false,false)
    elseif action=='password' then prompt('服务器密码（留空不删除；删除请使用清除按钮）','',function(value)
        if value=='' then return end
        if #value>1024 then report('服务器密码最多 1024 字节',4,'error');return end
        if cfg.remember_password then
            credential_change('credential-save',value)
        else password=value end
    end,true)
    elseif field_labels[action] then field_edit(action) end
    publish()
end
mp.register_script_message('splay-history',function(json)
    if type(json)~='string' or #json>16777216 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 or type(value.profiles)~='table' or type(value.values)~='table' then return end
    history=value
    if not history_loaded then
        local previous_host,previous_port=endpoint_host(cfg.host),tonumber(cfg.port)
        history_loaded=true
        for _,key in ipairs(fields) do
            if not touched[key] and type(value.last)=='table' and value.last[key]~=nil then
                cfg[key]=value.last[key]
                if key=='room' and type(cfg[key])=='string' and cfg[key]:lower()=='default' then cfg[key]='' end
            end
        end
        if endpoint_host(cfg.host)~=previous_host or tonumber(cfg.port)~=previous_port then
            password='';credential_reset()
        end
        credential_status()
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
    if enabled and value.error then report('splay 历史: '..plain(value.error),5,'error') end
    publish()
end)
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    if state.connection~=value.connection or state.room~=value.room or state.username~=value.username then chat_generation=chat_generation+1 end
    if enabled then
        if value.warning and value.warning~='' and value.warning~=state.warning then notice(warning_labels[value.warning] or value.warning,'warning') end
        if value.error and value.error~='' and value.error~=state.error then notice(value.error,'error') end
    end
    state=value;publish()
end)
local function event_text(value)
    local user=plain(value.username or value.user)
    if value.type=='chat' and type(value.text)=='string' then return user..': '..value.text end
    if value.type=='playback' then
        local position=tonumber(value.position)
        return user..(value.seek and ' 跳转' or (value.paused and ' 暂停' or ' 播放'))..(position and (' · '..math.floor(position)..' 秒') or '')
    end
    if value.type=='connection' then return '连接: '..(connection_labels[value.connection] or plain(value.connection)) end
    if value.type=='room' then return '切换房间: '..plain(value.room) end
    if value.type=='ready' then return user..(value.ready==true and ' 已准备' or (value.ready==false and ' 未准备' or ' 准备状态未知')) end
    if value.type=='user' then
        if value.action=='file' then
            local file=type(value.file)=='table' and value.file.name or value.file
            return user..' 更换媒体: '..plain(file)
        end
        local action=({joined=' 加入房间: ',left=' 离开房间: ',room=' 切换房间: '})[value.action]
        if action then return user..action..plain(value.room) end
    end
    if value.type=='playlist' then
        if value.action=='files' and type(value.files)=='table' then return user..' 更新共享播放列表: '..#value.files..' 项' end
        local index=tonumber(value.index)
        return user..' 切换共享播放项: '..(index and tostring(index+1) or '无')
    end
end
mp.register_script_message('splay-event',function(json)
    if not enabled or type(json)~='string' or #json>65536 then return end
    local value=parse_event(json)
    if type(value)~='table' or value.schema~=1 then return end
    if value.type=='user' and (type(state.room)~='string' or state.room=='' or
        (value.room~=state.room and value.previous_room~=state.room)) then return end
    local text=event_text(value)
    if not text or not append_message(text,value.type,value.id) then return end
    if value.type=='chat' or value.type=='playback' then overlay('splay-event',json)
    else
        message_serial=message_serial+1
        overlay('splay-event',utils.format_json({schema=1,id='ui:'..message_serial,type='notice',text=plain(text),category=value.type}))
    end
    publish()
end)
mp.register_script_message('splay-notice',function(json)
    if type(json)~='string' or #json>65536 then return end
    local value=parse_event(json)
    if type(value)=='table' then notice(value.text,value.category);publish() end
end)
mp.register_script_message('splay-credential',function(json)
    if type(json)~='string' or #json>16384 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 then return end
    if value.host==nil and value.port==nil then
        if not credential_init_request or value.request_id~=credential_init_request then return end
        credential_init_request=nil;credential_initialized=not value.error
        credential_error=value.error
        if credential_initialized then credential_dispatch()
        elseif credential_connect_waiting then credential_connect_waiting=false;report('密码存储: '..plain(value.error),5,'error') end
        publish();return
    end
    local request=credential_request
    if not request or value.request_id~=request.id or
        endpoint_host(value.host)~=request.host or tonumber(value.port)~=request.port or
        endpoint_host(value.host)~=endpoint_host(cfg.host) or tonumber(value.port)~=tonumber(cfg.port) then return end
    credential_request=nil;credential_ready=not value.error
    credential_saved=value.saved==true
    if value.error and value.error~=credential_error then notice('密码存储: '..plain(value.error),'error') end
    credential_error=value.error
    if credential_pending and request.action==credential_pending.action then
        if not value.error then
            if cfg.remember_password and request.action=='credential-save' and password==credential_pending.secret then password='' end
            notice(request.action=='credential-save' and '服务器密码已加密保存' or '已清除服务器密码','credential')
        end
        credential_pending=nil
    end
    if credential_connect_waiting then
        credential_connect_waiting=false
        if value.error then report('密码存储: '..plain(value.error),5,'error')
        elseif enabled then connect() end
    end
    publish()
end)
mp.register_script_message('splay-overlay-ready',publish)
mp.register_script_message('splay-playlist-ready',publish)
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
    if type(json)~='string' or #json>131072 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or type(value.action)~='string' then return end
    if value.action=='connect' then
        if not room_valid(value.room) then report('请先输入或选择房间',3);return end
        chat_generation=chat_generation+1
        enabled=true
        credential_reset()
        password=''
        for _,key in ipairs(fields) do if value[key]~=nil then cfg[key]=value[key];touched[key]=true end end
        password=type(value.password)=='string' and value.password or ''
        credential_status()
        save(true,true)
    elseif not enabled and value.action~='status' and value.action~='history-load' and value.action~='history-save' then return
    elseif value.action=='room' and type(value.room)=='string' then
        if not room_valid(value.room) then report('请先输入或选择房间',3);return end
        chat_generation=chat_generation+1
        cfg.room=value.room;touched.room=true;save(true)
    elseif value.action=='create-room' and not room_valid(value.room) then report('请先输入或选择房间',3);return
    end
    send(value);publish()
    if value.action=='connect' then password='' end
end)
mp.add_key_binding('Shift+s','splay-panel',function() show() end)
local history_path=mp.command_native({'expand-path','~~/splay-history.json'})
local credential_path=mp.command_native({'expand-path','~~/splay-credentials.json'})
init_credentials=function()
    if not credential_initialized and type(credential_path)=='string' and credential_path~='' then
        if not credential_init_request then credential_init_request=credential_id() end
        send({action='credential-init',path=credential_path,request_id=credential_init_request})
    end
end
local function load_history()
    if cfg.history_enabled and not history_loaded and type(history_path)=='string' and history_path~='' then
        send({action='history-load',path=history_path})
    end
end
load_history()
init_credentials()
for _,delay in ipairs({0.2,0.5,1,2}) do mp.add_timeout(delay,function() load_history();init_credentials() end) end
for _,property in ipairs({'path','idle-active','user-data/mpv/console/open','user-data/mpv/context-menu/open','user-data/uosc/menu/type','user-data/splay-overlay'}) do
    mp.observe_property(property,'native',function() update_enter() end)
end
publish()
mp.register_event('shutdown',function() password='';messages={};seen_events={} end)
