-- splay: optional Syncplay UI. The native core saves non-secret history and separately encrypted credentials.
local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'
local options = require 'mp.options'
-- Config supplies first-run defaults; saved preferences restore the last form.
local cfg = {host='', port=0, username='', room='', tls='', ui='native', history_enabled=true, remember_password=true,auto_reconnect=true,latency_enabled=false}
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
local history_serial, history_applied, history_load_request = 0, 0, nil
local history_requests = {}
local ui_epoch = 0
local messages, seen_events, message_serial = {}, {}, 0
local credential_saved, credential_initialized = false, false
local credential_pending, credential_error
local credential_serial, credential_request, credential_init_request = 0, nil, nil
local credential_ready, credential_connect_waiting = false, false
local enabled, page, input_open, enter_bound, history_bound = false, 'home', false, false, false
local current_ui=cfg.ui
local chat_generation=0
local password_token, menu_open = nil, false
local has_private_password=false
local secret_serial, secret_request = 0, nil
local input_generation=0
local native_menu_page=nil
local detail_member_name=nil
local connection_intent,create_name_confirmed='join',false
local active_input_session=nil
local show, act, publish, update_enter, chat, notice, connect, init_credentials
local function room_valid(room) return type(room)=='string' and room:find('%S')~=nil end
local function plain(v,limit)
    limit=limit or 256
    local text=tostring(v or ''):gsub('[%c{}\\]',' ')
    if #text<=limit then return text end
    local finish=limit
    while finish>0 and text:byte(finish+1)>=128 and text:byte(finish+1)<=191 do finish=finish-1 end
    return text:sub(1,finish)..'…'
end
-- UI enrichment stays in this Lua client. Never pass these values to send().
local media_path=mp.get_property_native('path')
local media_loading=false
local function valid_duration(value)
    return type(value)=='number' and value==value and value>0 and value<math.huge and value or nil
end
local function media_name(value)
    if type(value)~='string' or #value>8192 then return nil end
    value=value:match('^%s*(.-)%s*$')
    if value=='' then return nil end
    local inspected=value:lower()
    -- Inspect escaped input as well; an encoded URL/path is still private data.
    for _=1,2 do inspected=inspected:gsub('%%(%x%x)',function(hex) return string.char(tonumber(hex,16)) end):lower() end
    if inspected:find('[%c/\\]') or inspected:find('^%a:') or inspected:find('^https?:') or
        inspected:find('^ftp:') or inspected:find('^rtsp:') or inspected:find('^data:') or inspected:find('^www%.') or
        inspected:find('[?#=]') or inspected:find('%*%*hidden') then return nil end
    local stem=inspected:gsub('%.[%w]+$','')
    if stem=='index' or stem=='master' or stem=='manifest' or stem=='playlist' or stem=='token' or
        stem=='stream' or stem=='live' or stem=='media' or stem=='video' or stem=='play' or
        inspected:find('%.m3u8$') or inspected:find('%.mpd$') or inspected:find('%.ism[l]?$') or
        inspected:find('%.f4m$') then return nil end
    return plain(value,2048),value:lower()
end
local function local_media()
    local path=mp.get_property_native('path')
    if media_loading or type(path)~='string' or path=='' or path~=media_path or
        mp.get_property_native('idle-active')==true then return {loaded=false,title=''} end
    local network=path:match('^%a[%w+.-]*:')~=nil and not path:match('^%a:[/\\]') and not path:lower():match('^file://')
    local basename,name_key
    if not network then
        -- Only a local basename is an acceptable fallback. Never derive a title
        -- from a network URL or its request/authorization parameters.
        basename,name_key=media_name(path:match('([^/\\]+)$'))
        if not basename then basename,name_key=media_name(mp.get_property_native('filename')) end
    end
    local title,title_key=media_name(mp.get_property_native('media-title'))
    return {loaded=true,title=title or basename or (network and '网络媒体' or '本机媒体'),
        duration=valid_duration(mp.get_property_native('duration'))},name_key or title_key,
        basename or title,name_key and '本机文件名' or title_key and '本机媒体标题' or '名称未提供'
end
local function duration_label(value)
    if not value then return '时长未知' end
    local seconds=math.floor(value+0.5)
    if seconds>=3600 then return string.format('%.0f:%02d:%02d',math.floor(seconds/3600),math.floor(seconds/60)%60,seconds%60) end
    return string.format('%d:%02d',math.floor(seconds/60),seconds%60)
end
local function seconds_label(value)
    if math.abs(value)>=1e9 then return string.format('%.6g',value) end
    return (string.format('%.6f',value):gsub('0+$',''):gsub('%.$',''))
end
local function delta_label(delta)
    if delta==0 then return '双方时长相同' end
    local amount=seconds_label(math.abs(delta))
    if amount=='0' then amount='不足 0.000001' end
    return '对方'..(delta>0 and '长 ' or '短 ')..amount..' 秒'
end
local function enrich_media()
    local own,own_name,own_comparison_name,own_name_source=local_media()
    state.local_media=own
    -- Keep the old local display field safe for existing consumers.
    state.local_file=own.title
    for _,member in ipairs(state.members or {}) do
        if type(member)=='table' then
            local self=type(state.username)=='string' and member.username==state.username
            local media,name,comparison_name
            if self then media={loaded=own.loaded,title=own.title,duration=own.duration}
            else
                local file=type(member.file)=='table' and member.file or {}
                local title
                title,name=media_name(file.name)
                comparison_name=title
                media={loaded=next(file)~=nil,title=title or (next(file)~=nil and '名称未提供' or ''),duration=valid_duration(file.duration)}
            end
            local check,label,detail='unknown','无法比对','需要双方已载入媒体并提供有效时长；隐藏名称或直播无法确认同片。'
            media.local_duration=own.duration
            media.name_basis='unavailable'
            local comparable=not self and type(state.room)=='string' and member.room==state.room and own.loaded and media.loaded
            if comparable then
                if own_name and name then
                    media.name_basis=own_name==name and 'same' or 'different'
                    media.name_detail='名称依据：'..own_name_source..'「'..own_comparison_name..'」；对方公开名称「'..comparison_name..'」。'
                else media.name_detail='名称依据：一方名称隐藏或缺少可信名称，未核对文件内容。' end
                if own.duration and media.duration and mp.get_property_native('seekable')~=false then
                    local delta=media.duration-own.duration
                    if delta==delta and delta>-math.huge and delta<math.huge then
                        media.duration_delta=delta
                        media.duration_delta_label=delta_label(delta)
                    end
                end
            end
            if self then check,label,detail='self','本机','本机媒体信息仅用于本地显示与比对。'
            elseif type(state.room)~='string' or member.room~=state.room then detail='仅比对当前房间成员。'
            elseif not own.loaded or not media.loaded then detail='一方尚未载入媒体，暂不比对。'
            elseif not own.duration or not media.duration or mp.get_property_native('seekable')==false then
                detail='时长未知或媒体不可跳转（可能为直播），暂不比对。'
            elseif media.duration_delta and math.abs(media.duration_delta)>2.5 then
                check,label,detail='duration_mismatch','时长不同','双方时长相差超过 2.5 秒；可能是不同版本或媒体。'
            elseif own_name and name and own_name~=name then
                check,label,detail='name_mismatch','名称不同','双方名称不同，时长接近；仅凭名称无法确定是否为同一影片。'
            elseif own_name and name then
                check,label,detail='metadata_match','疑似同片','名称相同且时长相差不超过 2.5 秒；未核对文件内容，无法确认同片。'
            else
                check,label,detail='duration_match','时长一致','时长相差不超过 2.5 秒；名称隐藏或未知，仅凭时长无法确认同片。'
            end
            if not self then
                detail='本机时长：'..(own.duration and duration_label(own.duration)..'（'..seconds_label(own.duration)..' 秒）' or '未知')..
                    '；对方时长：'..(media.duration and duration_label(media.duration)..'（'..seconds_label(media.duration)..' 秒）' or '未知')..'。\n'..
                    (media.duration_delta_label and media.duration_delta_label..'；' or '')..'时长接近阈值：2.5 秒。\n'..
                    (media.name_detail or '名称依据：当前无法比对。')..'\n'..detail
            end
            media.check,media.check_label,media.check_detail=check,label,detail
            member.media=media
        end
    end
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
local function history_send(command,message)
    history_serial=history_serial+1
    command.request_id=history_serial
    history_requests[history_serial]={epoch=ui_epoch,message=message}
    send(command)
    return history_serial
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
local function cancel_secret()
    if secret_request then send({action='secret-cancel',request_id=secret_request.id}) end
    secret_request=nil
end
local function credential_dispatch()
    if not credential_initialized then if init_credentials then init_credentials() end;return end
    if credential_request then return end
    local pending=credential_pending
    local action=pending and pending.action or 'credential-status'
    local id=credential_id()
    credential_request={id=id,action=action,host=endpoint_host(cfg.host),port=tonumber(cfg.port)}
    send({action=action,request_id=id,host=cfg.host,port=tonumber(cfg.port)})
end
local function credential_status()
    if credential_pending then return end
    credential_ready=false;credential_request=nil;credential_error=nil
    credential_dispatch()
end
local function credential_change(action)
    credential_connect_waiting=false;credential_ready=false;credential_error=nil;credential_request=nil
    credential_pending={action=action}
    password_token=nil;has_private_password=false;credential_saved=false
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
local function save(remember,freeze,message)
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
    else history_send(command,message) end
end
local function save_profile()
    if not cfg.history_enabled then report('连接记忆已关闭；未保存连接组合',4);return end
    if not room_valid(cfg.room) then report('请先输入或选择房间，再保存连接组合',4);return end
    if secret_request then report('请先完成或取消 Windows 密码输入，再保存连接组合',4);return end
    if cfg.remember_password then
        if credential_error then report('密码存储错误；未保存连接组合: '..plain(credential_error),5,'error');return end
        if not credential_initialized or not credential_ready or credential_pending or credential_request then
            credential_dispatch()
            report('正在读取或保存服务器密码；请等待完成后再次保存连接组合',4);return
        end
    end
    if not history_loaded then report('连接记忆正在读取；请稍后再次保存连接组合',4);return end
    local password_note=not cfg.remember_password and
        (credential_saved and '已有加密密码当前不使用；密码不随组合保存' or '密码不随组合保存') or
        credential_saved and '密码按服务器和端口单独加密保管' or
        ((password_token or has_private_password) and '仅本次密码不会随组合保存' or '当前无已保存的服务器密码')
    save(true,true,'连接组合已保存；'..password_note)
    report('正在保存连接组合…',2)
end
local function edit(key,value)
    local changed_endpoint=(key=='host' or key=='port') and cfg[key]~=value
    credential_connect_waiting=false
    if changed_endpoint then cancel_secret();password_token=nil;has_private_password=false;credential_reset() end
    cfg[key]=value; touched[key]=true; save(false);publish()
    if changed_endpoint then credential_status() end
end
connect=function()
    if not enabled then return end
    if connection_intent=='create' and not create_name_confirmed then
        report('请先填写新房间名称，再点击「创建并进入」',3)
        mp.add_timeout(0,function() act('room') end);return
    end
    if secret_request then
        if secret_request.purpose=='server' then credential_connect_waiting=true;report('完成 Windows 密码输入后连接',3)
        else report('请先完成或取消 Windows 密码输入',3) end
        return
    end
    if not room_valid(cfg.room) then
        report('请先输入或选择房间，再点击「加入」',3)
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
    if password_token then has_private_password=true end
    send({action='connect',host=cfg.host,port=tonumber(cfg.port),username=cfg.username,
        room=cfg.room,password_token=password_token,tls=cfg.tls,use_saved_password=cfg.remember_password and password_token==nil and credential_saved,
        remember_password=cfg.remember_password,auto_reconnect=cfg.auto_reconnect,reuse_password=has_private_password})
    password_token=nil
end
local function close_menu()
    menu_open=false
    overlay('splay-menu-close')
    mp.commandv('script-message-to','uosc','close-menu','splay')
end
local function request_input(open)
    input_generation=input_generation+1
    local generation=input_generation
    local session={generation=generation}
    local function dispatch(callback)
        -- The timer runs after mp.input's closed handler has unregistered the
        -- old callback. No delay assumption about the host event loop is needed.
        mp.add_timeout(0,function() if generation==input_generation then callback() end end)
    end
    local function begin()
        if generation~=input_generation then return end
        if active_input_session and not active_input_session.closed then
            active_input_session.replacement=begin
            input.terminate()
            return
        end
        active_input_session=session
        native_menu_page=nil;input_open=true;update_enter()
        local function closed()
            if session.closed then return end
            session.closed=true
            if active_input_session==session then active_input_session=nil;native_menu_page=nil;input_open=false;update_enter() end
            if session.pending then dispatch(session.pending) end
            if session.replacement then mp.add_timeout(0,session.replacement) end
        end
        local function submitted(callback)
            if session.submitted then return end
            session.submitted=true
            session.pending=callback
            if session.closed then dispatch(callback) end
        end
        open(closed,submitted,generation)
    end
    begin()
end
local function prompt(label,initial,callback,_,reopen)
    close_menu()
    local epoch=ui_epoch
    request_input(function(closed,submitted,generation)
        input.get({prompt=label..': ',
        default_text=tostring(initial or ''),
        id='splay-'..label,
        closed=closed,
        submit=function(value)
            submitted(function()
                if not enabled or epoch~=ui_epoch or generation~=input_generation then return end
                if type(value)=='string' and #value<=4096 and not value:find('[%c]') then callback(value) end
                if reopen~=false then mp.add_timeout(0,function() if enabled and epoch==ui_epoch then show(nil,page) end end) end
            end)
        end})
    end)
end
local function select(title,items,callback)
    close_menu()
    local epoch=ui_epoch
    request_input(function(closed,submitted,generation)
        input.select({prompt=title,items=items,submit=function(value)
            submitted(function()
                if enabled and epoch==ui_epoch and generation==input_generation then callback(value) end
            end)
        end,closed=closed})
    end)
end
local function secret_input(purpose,room)
    if not enabled then return end
    if purpose~='server' and state.connection~='connected' then report('请先连接',3);return end
    close_menu()
    input_generation=input_generation+1
    if input_open then input.terminate() end
    cancel_secret()
    if purpose=='server' then
        password_token=nil;credential_request=nil;credential_pending=nil;credential_connect_waiting=false
    end
    secret_serial=secret_serial+1
    secret_request={id=secret_serial,purpose=purpose,epoch=ui_epoch,host=endpoint_host(cfg.host),port=tonumber(cfg.port)}
    local titles={server='splay 服务器密码',operator='splay 操作员认证',create_room='splay 创建受控房间'}
    local prompts={server='服务器 '..plain(cfg.host,100)..':'..plain(cfg.port)..' 的密码',
        operator='输入操作员密码（例如 AB-123-456）',create_room='新房间 '..plain(room,100)..' 的操作员密码'}
    send({action='secret-input',request_id=secret_serial,purpose=purpose,host=cfg.host,port=tonumber(cfg.port),
        remember_password=cfg.remember_password,room=room,title=titles[purpose],prompt=prompts[purpose]})
    report('请在 Windows 密码框输入；不会写入 mpv 输入历史',3)
    update_enter()
end
local connection_labels={disconnected='未连接',connecting='连接中',connected='已连接',reconnecting='等待重连',error='错误'}
local warning_labels={
    ['Waiting for media; synchronization is suspended']='等待媒体；同步已暂停',
    ['Synchronization requires playback speed 1.0; synchronization is suspended']='同步需要 1x 播放速度；同步已暂停',
    ['Buffering or seeking; synchronization is suspended']='缓冲或跳转中；同步已暂停',
    ['Media is not seekable; position synchronization is unavailable']='媒体不可跳转；无法同步播放位置',
}
local function connection_label() return connection_labels[state.connection] or plain(state.connection) end
local function reconnect_label()
    local retry=state.reconnect
    if type(retry)=='table' and retry.pending then
        return '自动重连 '..plain(retry.remaining or 0)..' 秒 · 第 '..plain(retry.attempt or 0)..'/5 次'
    end
    if type(retry)=='table' and (tonumber(retry.attempt) or 0)>0 then
        return '自动重连 · 第 '..plain(retry.attempt)..'/5 次'
    end
    return '自动重连: '..(cfg.auto_reconnect and '开启' or '关闭')
end
local function warning_label() return plain(warning_labels[state.warning] or state.warning) end
local function password_label()
    if secret_request and secret_request.purpose=='server' then return 'Windows 输入中' end
    if credential_error then return '存储错误（请重新输入或检查密码设置）' end
    if not credential_initialized or not credential_ready or credential_pending or credential_request then return '读取 / 保存中' end
    if credential_saved then return cfg.remember_password and '已加密保存' or '已保存（当前不使用）' end
    return (has_private_password or password_token) and '仅本次' or '空（无密码）'
end
local function current_members()
    local members={}
    for _,member in ipairs(state.members or {}) do
        if type(member)=='table' and type(state.room)=='string' and member.room==state.room then members[#members+1]=member end
    end
    return members
end
local autostart_reasons={
    disabled='已关闭', ['waiting-ready']='等待全员准备', ['waiting-members']='至少需要两位同房成员',
    ['waiting-media']='等待媒体就绪（暂停、1x、可跳转且无缓冲）', ['no-permission']='需要本机已认证为房间操作员',
    ['waiting-reset']='等待重新准备或重新开启', countdown='全员已准备，正在倒计时',
    started='已自动开播', unsupported='服务器未支持准备状态', ['waiting-snapshot']='等待完整成员列表',
    disconnected='未连接房间',
}
local function autostart_state() return type(state.autostart)=='table' and state.autostart or {} end
local function autostart_countdown()
    local value=autostart_state()
    if value.enabled~=true or value.pending~=true or state.connection~='connected' then return nil end
    local seconds=value.remaining
    return type(seconds)=='number' and seconds==seconds and seconds>=0 and seconds<=30 and math.ceil(seconds) or nil
end
local function member_latency(member)
    if not cfg.latency_enabled then return '' end
    local own=member.username==state.username
    local value=own and state.latency or member.latency
    local label=own and '本机 RTT' or '上报 RTT'
    if type(value)=='table' and value.stale then return ' | '..label..': 过期' end
    if type(value)=='table' and type(value.rtt_ms)=='number' and value.rtt_ms>=0 and
        (own or value.reported==true) then return ' | '..label..': '..math.floor(value.rtt_ms+0.5)..' ms' end
    return ' | '..label..': '..(own and '测量中' or '未上报')
end
local function add_detail_rows(result,text)
    -- Both native console and uosc use a fixed height per menu item. Keep
    -- detail paragraphs in separate rows so no multiline title is clipped.
    for paragraph in (text..'\n'):gmatch('(.-)\n') do
        local row,units={},0
        for cp in paragraph:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            local advance=cp:byte()<128 and .55 or 1
            if units+advance>28 and #row>0 then
                result[#result+1]={title=table.concat(row),value='noop',selectable=false}
                row,units={},0
            end
            row[#row+1]=cp;units=units+advance
        end
        if #row>0 then result[#result+1]={title=table.concat(row),value='noop',selectable=false} end
    end
end
local function rows(which)
    which=which or page
    local toggle={title=enabled and '关闭 splay' or '启用 splay',value='toggle-enabled'}
    if not enabled then return {toggle} end
    if which=='connection' then
        local result={
        {title='‹ 返回',value='home'},
        {title='服务器: '..plain(cfg.host)..' : '..plain(cfg.port),value='endpoint'},
        {title='房间: '..(connection_intent=='create' and not create_name_confirmed and '请填写新房间名称' or room_valid(cfg.room) and plain(cfg.room) or '请先输入或选择'),value='room'},
        {title='服务器密码: '..password_label(),value='password'},
        {title='昵称: '..plain(cfg.username),value='username'},
        {title='已保存的连接组合: '..#(history.profiles or {}),value='profiles'},
        {title=connection_intent=='create' and '创建并进入' or '加入',value='connect'},
        }
        local reconnect_pending=state.reconnect and state.reconnect.pending
        if state.connection=='connected' or state.connection=='connecting' or reconnect_pending then
            result[#result+1]={title='取消重连 / 断开连接',value='disconnect'}
        end
        if reconnect_pending then result[#result+1]={title=reconnect_label(),value='noop',selectable=false} end
        return result
    end
    if which=='settings' then return {
        {title='‹ 返回',value=state.connection=='connected' and 'more' or 'home'},
        {title='TLS: '..plain(cfg.tls),value='tls'},
        {title='密码记忆与删除',value='password-settings'},
        {title='显示设置',value='display'},
        {title='连接历史管理: '..#(history.profiles or {}),value='history-management'},
        {title='高级房间操作',value='room-actions'},
        {title='自动重连: '..(cfg.auto_reconnect and '开启' or '关闭'),value='toggle-auto-reconnect'},
    } end
    if which=='endpoint' then return {
        {title='‹ 返回连接设置',value='connection'},
        {title='服务器: '..plain(cfg.host),value='host'},
        {title='端口: '..plain(cfg.port),value='port'},
    } end
    if which=='password-settings' then return {
        {title='‹ 返回设置',value='settings'},
        {title='密码: '..password_label(),value='password'},
        {title='记住并使用已保存密码: '..(cfg.remember_password and '是' or '否'),value='toggle-remember-password'},
        {title='清除本次输入并删除已保存密码',value='clear-password'},
    } end
    if which=='history-management' then return {
        {title='‹ 返回设置',value='settings'},
        {title='保存当前连接组合',value='save-profile'},
        {title='已保存的连接组合: '..#(history.profiles or {}),value='profiles'},
        {title='命名 / 重命名 / 删除组合',value='manage-profiles'},
        {title='清空指定字段建议',value='clear-history-field'},
        {title='清空全部非密码历史…',value='clear-history'},
    } end
    if which=='display' then return {
        {title='‹ 返回设置',value='settings'},
        {title='显示 / 隐藏状态文字',value='toggle-status'},
        {title='显示 / 隐藏鼠标按钮',value='toggle-buttons'},
        {title='延迟显示与共享: '..(cfg.latency_enabled and '开启' or '关闭'),value='toggle-latency'},
    } end
    if which=='autostart' then
        local auto=autostart_state()
        local result={
        {title='‹ 返回',value='more'},
        {title='全员准备后自动开播: '..(auto.enabled==true and '开启（5 秒）' or '关闭'),value='toggle-autostart'},
        {title='本机等待 5 秒；建议房内仅一人开启',value='noop',selectable=false},
        }
        if auto.enabled==true then
            result[#result+1]={title=autostart_reasons[auto.reason] or '等待准备状态',value='noop',selectable=false}
            if auto.reason=='waiting-reset' or auto.reason=='started' then
                result[#result+1]={title='重新开启自动开播（5 秒）',value='restart-autostart'}
            end
        end
        local countdown=autostart_countdown()
        if countdown then result[#result+1]={title='取消自动开播（'..countdown..' 秒）',value='autostart-cancel'} end
        return result
    end
    if which=='room-actions' then return {
        {title='‹ 返回',value='settings'},
        {title='认证房间操作员',value='authenticate'},
        {title='创建受控房间…',value='create-room'},
        {title='受控房间需要单独的操作员密码',value='noop',selectable=false},
    } end
    if which=='more' then return {
        {title='‹ 返回',value='home'},
        {title='房间成员: '..#current_members(),value='members'},
        {title='消息记录: '..#messages,popup_title='消息记录',subtitle='Shift+h · '..#messages..' 条',value='message-history'},
        {title='全员准备后自动开播: '..(autostart_state().enabled==true and '开启' or '关闭'),value='autostart'},
        {title='加入其他房间',value='join-form'},
        {title='创建房间',value='create-form'},
        {title='设置',value='settings'},
        toggle,
    } end
    if which=='member-details' then
        local result={{title='‹ 返回房间成员',value='members'}}
        local selected
        for _,member in ipairs(current_members()) do if member.username==detail_member_name then selected=member;break end end
        if not selected then result[#result+1]={title='该成员已离开当前房间',value='noop',selectable=false};return result end
        local media=selected.media or {}
        add_detail_rows(result,'成员：'..plain(selected.username)..' · '..plain(selected.room))
        add_detail_rows(result,'片名：'..(media.loaded and media.title or '未载入媒体'))
        add_detail_rows(result,'检查：'..(media.check_label or '无法比对'))
        if media.check=='self' then add_detail_rows(result,'本机时长：'..duration_label(media.duration)..(media.duration and '（'..seconds_label(media.duration)..' 秒）' or '')) end
        add_detail_rows(result,media.check_detail or '媒体信息未知。')
        return result
    end
    if which=='members' then
        local result={{title='‹ 返回',value='more'}}
        for _,member in ipairs(current_members()) do
            local media=member.media or {loaded=false,title='',check_label='无法比对',check_detail='媒体信息未知。'}
            result[#result+1]={title=plain(member.username)..' | '..plain(member.room)..' | '..
                (member.ready==true and '已准备' or (member.ready==false and '未准备' or '准备状态未知'))..
                (member.is_controller and ' | 操作员' or '')..member_latency(member)..' | '..duration_label(media.duration)..' · '..media.check_label,
                hint='查看媒体与检查详情',value='member-details:'..tostring(member.username or '')}
        end
        if #result==1 then result[2]={title='暂无成员',value='noop',selectable=false} end
        if cfg.latency_enabled then result[#result+1]={title='他人需开启 splay 分享；官方客户端未上报延迟',value='noop',selectable=false} end
        return result
    end
    if state.connection~='connected' then
        local result={{title='加入房间',value='join-form'},{title='创建房间',value='create-form'}}
        if state.connection=='connecting' or (state.reconnect and state.reconnect.pending) then
            result[#result+1]={title='取消连接 / 重连',subtitle=reconnect_label(),value='disconnect'}
        end
        result[#result+1]={title='设置',value='settings'}
        result[#result+1]=toggle
        return result
    end
    local endpoint=type(state.host)=='string' and state.host~='' and plain(state.host)..':'..plain(state.port) or '服务器未知'
    local room=room_valid(state.room) and plain(state.room) or '房间未知'
    local result={{title=endpoint..' · '..room,popup_title=endpoint,subtitle=room,value='connection'},
        {title=state.ready==true and '已准备' or '未准备',value='ready'}}
    local countdown=autostart_countdown()
    if countdown then result[#result+1]={title='取消自动开播（'..countdown..' 秒）',popup_title='取消自动开播',subtitle=countdown..' 秒后开播',value='autostart-cancel'} end
    result[#result+1]={title='共享播放列表',value='playlist'}
    result[#result+1]={title='更多',value='more'}
    result[#result+1]={title='断开连接',value='disconnect'}
    return result
end
local page_titles={home='splay',connection='加入房间',endpoint='服务器与端口',settings='设置',display='显示设置',members='房间成员',more='更多',autostart='自动开播',['member-details']='成员媒体详情',['room-actions']='高级房间操作',['password-settings']='服务器密码',['history-management']='连接历史管理'}
local function title(which)
    return (which=='connection' and connection_intent=='create' and '创建房间' or page_titles[which] or 'splay')..' | '..(enabled and connection_label() or '已关闭')
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
    enrich_media()
    overlay('splay-state',utils.format_json(state))
    mp.commandv('script-message-to','splay_playlist','splay-state',utils.format_json(state))
    overlay('splay-menu-model',utils.format_json({title=title('home'),items=rows('home'),enabled=enabled}))
    mp.set_property_native('user-data/splay',{enabled=enabled,connection=state.connection,room=state.room})
    if menu_open then mp.commandv('script-message-to','uosc','update-menu',utils.format_json(menu())) end
    if input_open and native_menu_page=='connection' and state.reconnect and state.reconnect.pending then
        mp.osd_message(reconnect_label()..'\n选择「取消重连 / 断开连接」可停止',1.2)
    end
    update_enter()
end
show=function(mode,which)
    current_ui=mode or current_ui
    page=which or 'home'
    if not enabled then page='home' end
    if enabled then send({action='status'}) end
    close_menu()
    if current_ui=='uosc' then
        if input_open then input_generation=input_generation+1;input.terminate() end
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
        local epoch=ui_epoch
        request_input(function(closed,submitted,generation)
            native_menu_page=page
            input.select({prompt=menu().title,items=labels,closed=closed,submit=function(i)
                submitted(function()
                    if generation~=input_generation or epoch~=ui_epoch then return end
                    if entries[i] and entries[i].selectable~=false then
                        act(entries[i].value)
                        if entries[i].value=='toggle-enabled' then show('native') end
                    end
                end)
            end})
        end)
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
    return secret_request~=nil or input_open or menu_open or mp.get_property_native('user-data/mpv/console/open')==true or
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
local function profile_settings(profile)
    local result={}
    for _,key in ipairs(fields) do result[key]=profile[key] end
    return result
end
local function profile_label(profile)
    return (type(profile.name)=='string' and profile.name~='' and (plain(profile.name)..' · ') or '')..
        plain(profile.host)..':'..plain(profile.port)..' | '..plain(profile.username)..' | '..plain(profile.room)..' | '..plain(profile.tls)
end
local function fill_profile(profile)
    cancel_secret();password_token=nil;has_private_password=false
    credential_reset()
    connection_intent,create_name_confirmed='join',false
    for _,key in ipairs(fields) do cfg[key]=profile[key];touched[key]=true end
    credential_status()
    save(false);page='connection';publish();report('连接组合已填入；点击「加入」才连接',4)
    mp.add_timeout(0,function() if enabled then show(nil,'connection') end end)
end
local function choose_profile(title,callback)
    local snapshot,labels={},{}
    for _,profile in ipairs(history.profiles or {}) do
        local item=profile_settings(profile);item.name=profile.name
        snapshot[#snapshot+1]=item;labels[#labels+1]=profile_label(item)
    end
    if #snapshot==0 then report('尚无历史连接组合',3);return end
    select(title,labels,function(i) if snapshot[i] then callback(snapshot[i]) end end)
end
local function manage_profile(profile)
    select(profile_label(profile),{'填入连接信息','命名 / 重命名','删除此组合…'},function(i)
        if i==1 then fill_profile(profile)
        elseif i==2 then
            prompt('组合名称',profile.name or '',function(name)
                if not name:find('%S') or #name>1024 then report('名称须为 1–1024 字节非空文本',3,'error');return end
                history_send({action='history-rename',settings=profile_settings(profile),name=name},'组合名称已保存')
            end)
        elseif i==3 then
            select('删除此组合及匹配的上次填写；字段建议、当前连接和密码保留（同服务器端口的其他组合仍可使用密码）',{'取消','确认删除: '..profile_label(profile)},function(choice)
                if choice==2 then history_send({action='history-delete',settings=profile_settings(profile)},'连接组合已删除') end
            end)
        end
    end)
end
act=function(action)
    if type(action)=='string' and action:sub(1,15)=='member-details:' then
        detail_member_name=action:sub(16);show(nil,'member-details');return
    end
    if action=='toggle-enabled' then
        enabled=not enabled
        ui_epoch=ui_epoch+1
        chat_generation=chat_generation+1
        if enabled then send({action='latency',enabled=cfg.latency_enabled});send({action='status'})
        else
            connection_intent,create_name_confirmed='join',false
            input_generation=input_generation+1
            cancel_secret();password_token=nil;pending_saves={}
            credential_connect_waiting=false
            send({action='latency',enabled=false})
            send({action='disconnect'})
            state={schema=1,connection='disconnected',members={},ready=false}
            if input_open then input.terminate();input_open=false end
        end
        page='home';publish();return
    end
    if action=='home' or action=='connection' or action=='endpoint' or action=='members' or action=='settings' or action=='display' or action=='room-actions' or action=='more' or action=='autostart' or action=='password-settings' or action=='history-management' then
        show(nil,action);return
    end
    if not enabled then return end
    overlay('splay-menu-close')
    if action=='refresh' then show(nil,page)
    elseif action=='join-form' then connection_intent,create_name_confirmed='join',false;show(nil,'connection');return
    elseif action=='create-form' then
        connection_intent,create_name_confirmed='create',false;page='connection'
        prompt('新普通房间名称','',function(value) create_name_confirmed=room_valid(value);edit('room',value) end)
    elseif action=='room' and connection_intent=='create' and page=='connection' then
        prompt('新普通房间名称',create_name_confirmed and cfg.room or '',function(value) create_name_confirmed=room_valid(value);edit('room',value) end)
    elseif action=='connect' then connect()
    elseif action=='disconnect' then cancel_secret();credential_connect_waiting=false;chat_generation=chat_generation+1;send({action='disconnect'})
    elseif action=='toggle-auto-reconnect' then
        cfg.auto_reconnect=not cfg.auto_reconnect
        send({action=cfg.auto_reconnect and 'reconnect-enable' or 'reconnect-disable'})
    elseif action=='toggle-latency' then
        cfg.latency_enabled=not cfg.latency_enabled
        send({action='latency',enabled=cfg.latency_enabled})
    elseif action=='join-room' then
        if state.connection~='connected' then report('请先连接',3)
        elseif not room_valid(cfg.room) then report('请先输入或选择房间',3)
        else chat_generation=chat_generation+1;send({action='room',room=cfg.room});save(true) end
    elseif action=='ready' then if state.connection=='connected' then send({action='ready',ready=not state.ready}) end
    elseif action=='toggle-autostart' or action=='restart-autostart' then
        local wanted=action=='restart-autostart' or autostart_state().enabled~=true
        if wanted and state.connection~='connected' then report('连接房间后才能开启自动开播',3);return end
        send({action='autostart',enabled=wanted,delay=5})
    elseif action=='autostart-cancel' then
        if autostart_countdown() then send({action='autostart-cancel'}) end
    elseif action=='clear-password' then
        cancel_secret();send({action='password-clear'});credential_change('credential-delete')
    elseif action=='toggle-remember-password' then
        cfg.remember_password=not cfg.remember_password
        credential_connect_waiting=false
        cancel_secret()
        if cfg.remember_password and has_private_password and not credential_saved then
            report('如需加密保存本次密码，请重新打开 Windows 密码框输入',4)
        end
    elseif action=='playlist' then
        close_menu();mp.commandv('script-message-to','splay_playlist','splay-playlist-open',current_ui)
    elseif action=='save-profile' then save_profile()
    elseif action=='profiles' then
        choose_profile('已保存的连接组合',manage_profile)
    elseif action=='manage-profiles' then
        choose_profile('管理连接组合',manage_profile)
    elseif action=='clear-history-field' then
        local labels={}
        for _,key in ipairs(fields) do labels[#labels+1]=field_labels[key]..'建议: '..#((history.values or {})[key] or {}) end
        select('选择要清空的字段建议；组合、上次填写、密码保留',labels,function(i)
            local key=fields[i];if not key then return end
            select('只清空'..field_labels[key]..'建议；保留组合、上次填写、密码',{'取消','确认清空'..field_labels[key]..'建议'},function(choice)
                if choice==2 then history_send({action='history-clear-values',field=key},field_labels[key]..'建议已清空') end
            end)
        end)
    elseif action=='clear-history' then
        select('清空上次填写、全部组合及五字段建议；当前连接、当前表单和单独保存的密码保留',{'取消','确认清空全部非密码历史'},function(i)
            if i==2 then history_send({action='history-clear'},'全部非密码历史已清空；单独保存的密码保留') end
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
    elseif action=='authenticate' then secret_input('operator')
    elseif action=='create-room' then
        prompt('新受控房间','',function(room)
            if not room_valid(room) then report('请先输入或选择房间',3);return end
            edit('room',room)
            local epoch=ui_epoch
            mp.add_timeout(0.01,function() if enabled and epoch==ui_epoch then secret_input('create_room',room) end end)
        end,false,false)
    elseif action=='password' then secret_input('server')
    elseif field_labels[action] then field_edit(action) end
    publish()
end
mp.register_script_message('splay-history',function(json)
    if type(json)~='string' or #json>16777216 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 or type(value.profiles)~='table' or type(value.values)~='table' then return end
    local id=value.request_id
    local request=history_requests[id]
    if not request or id<history_applied then return end
    history_applied=id
    for key in pairs(history_requests) do if key<=id then history_requests[key]=nil end end
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
            cancel_secret();password_token=nil;has_private_password=false;credential_reset()
        end
        credential_status()
        local queued=pending_saves;pending_saves={}
        for _,pending in ipairs(queued) do
            if not pending.freeze then
                for _,key in ipairs(fields) do
                    if not pending.edited[key] then pending.command.settings[key]=cfg[key] end
                end
            end
            history_send(pending.command)
        end
    end
    if enabled and request.epoch==ui_epoch then
        if value.error then report('splay 历史: '..plain(value.error),5,'error')
        elseif request.message then report(request.message,3) end
    end
    publish()
end)
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=utils.parse_json(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    if value.connection=='connected' and state.connection~='connected' then connection_intent,create_name_confirmed='join',false end
    if state.connection~=value.connection or state.room~=value.room or state.username~=value.username then chat_generation=chat_generation+1 end
    if enabled then
        if value.warning and value.warning~='' and value.warning~=state.warning then notice(warning_labels[value.warning] or value.warning,'warning') end
        -- Record the detailed failure once; the native connection:error event is
        -- deliberately omitted below to avoid a second generic failure message.
        if value.error and value.error~='' and (value.error~=state.error or value.connection~=state.connection) then
            notice((value.connection=='error' and '连接失败: ' or '')..value.error,'error')
        end
    end
    state=value;publish()
end)
mp.register_script_message('splay-secret',function(json)
    if type(json)~='string' or #json>16384 then return end
    local value=utils.parse_json(json)
    local request=secret_request
    if type(value)~='table' or not request or value.request_id~=request.id or value.purpose~=request.purpose then return end
    secret_request=nil
    local connect_waiting=credential_connect_waiting
    credential_connect_waiting=false
    if not enabled or request.epoch~=ui_epoch then update_enter();return end
    if request.purpose=='server' and (request.host~=endpoint_host(cfg.host) or request.port~=tonumber(cfg.port)) then update_enter();return end
    if value.error then
        if request.purpose=='server' then credential_error=value.error;credential_ready=false end
        report('Windows 密码输入: '..plain(value.error),5,'error')
    elseif not value.cancelled then
        if request.purpose=='server' then
            if type(value.token)=='string' and value.token~='' then
                password_token=value.token
                credential_saved=value.saved==true;credential_ready=true;credential_error=nil
                notice(value.saved and '服务器密码已加密保存' or '服务器密码仅保留于本次进程','credential')
            end
        else notice('操作员请求已发送','credential') end
    end
    publish()
    if connect_waiting and not value.error and not value.cancelled and request.purpose=='server' then connect() end
end)
local function event_text(value)
    local user=plain(value.username or value.user)
    if value.type=='chat' and type(value.text)=='string' then return user..': '..value.text end
    if value.type=='playback' then
        local position=tonumber(value.position)
        return user..(value.seek and ' 跳转' or (value.paused and ' 暂停' or ' 播放'))..(position and (' · '..math.floor(position)..' 秒') or '')
    end
    if value.type=='connection' then
        if value.connection=='error' then return nil end
        return '连接: '..(connection_labels[value.connection] or plain(value.connection))
    end
    if value.type=='room' then return '切换房间: '..plain(value.room) end
    if value.type=='ready' then return user..(value.ready==true and ' 已准备' or (value.ready==false and ' 未准备' or ' 准备状态未知')) end
    if value.type=='autostart' then
        if value.action=='started' then return '全员准备倒计时结束，已自动开播' end
        if value.action=='cancelled' then
            local reason=autostart_reasons[value.reason]
            return '自动开播已取消'..(reason and '：'..reason or '')
        end
    end
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
            notice('已清除服务器密码','credential')
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
        send({action='latency',enabled=cfg.latency_enabled})
        credential_reset()
        cancel_secret();password_token=nil;has_private_password=false
        for _,key in ipairs(fields) do if value[key]~=nil then cfg[key]=value[key];touched[key]=true end end
        -- Preserve explicit IPC automation commands. Interactive passwords use
        -- only the native dialog and never enter mp.input or display state.
        if value.auto_reconnect==nil then value.auto_reconnect=cfg.auto_reconnect end
        credential_status()
        save(true,true)
    elseif not enabled and value.action~='status' and value.action~='history-load' and value.action~='history-save' then return
    elseif value.action=='latency' and type(value.enabled)=='boolean' then cfg.latency_enabled=value.enabled
    elseif value.action=='room' and type(value.room)=='string' then
        if not room_valid(value.room) then report('请先输入或选择房间',3);return end
        chat_generation=chat_generation+1
        cfg.room=value.room;touched.room=true;save(true)
    elseif value.action=='create-room' and not room_valid(value.room) then report('请先输入或选择房间',3);return
    end
    send(value);publish()
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
        if history_load_request then send({action='history-load',path=history_path,request_id=history_load_request})
        else history_load_request=history_send({action='history-load',path=history_path}) end
    end
end
load_history()
init_credentials()
for _,delay in ipairs({0.2,0.5,1,2}) do mp.add_timeout(delay,function() load_history();init_credentials() end) end
-- Media observations publish only locally. User-data observations below only
-- update shortcut eligibility, preventing an overlay/property feedback loop.
mp.register_event('start-file',function() media_loading=true;publish() end)
mp.register_event('file-loaded',function() media_path=mp.get_property_native('path');media_loading=false;publish() end)
mp.register_event('end-file',function() media_loading=true;publish() end)
for _,property in ipairs({'path','media-title','filename','duration','idle-active','seekable'}) do
    mp.observe_property(property,'native',function(name)
        if name=='path' then
            local path=mp.get_property_native('path')
            if path~=media_path then media_path=path;media_loading=true end
        end
        publish()
    end)
end
for _,property in ipairs({'user-data/mpv/console/open','user-data/mpv/context-menu/open','user-data/uosc/menu/type','user-data/splay-overlay'}) do
    mp.observe_property(property,'native',function() update_enter() end)
end
publish()
mp.register_event('shutdown',function() cancel_secret();password_token=nil;messages={};seen_events={} end)
