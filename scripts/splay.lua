-- splay: optional in-process Syncplay UI. No media or configuration writes.
local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'
local options = require 'mp.options'
local cfg = {host='localhost', port=8999, username='mpv', room='default', tls='prefer', ui='native'}
options.read_options(cfg, 'splay')
local state = {connection='disconnected', members={}, ready=false}
local password = ''
local menu_open = false
local nonce = 0
local previous_connection = 'disconnected'
local show, act
-- Strip formatting/control characters; command arguments always remain data.
local function plain(v)
    return tostring(v or ''):gsub('[%c{}\\]', ' '):sub(1, 256)
end
local function send(t)
    mp.commandv('script-message-to', 'splay_core', 'splay-command', utils.format_json(t))
end
local function connect()
    send({action='connect', host=cfg.host, port=tonumber(cfg.port), username=cfg.username,
          room=cfg.room, password=password, tls=cfg.tls})
end
local function prompt(label, initial, callback, secret)
    menu_open = false
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'splay')
    nonce = nonce + 1
    input.get({prompt=label .. (secret and '（本机可见，仅内存；可能留在本进程输入历史）: ' or ': '),
        default_text=secret and '' or tostring(initial or ''),
        id=secret and ('splay-secret-' .. nonce) or ('splay-' .. label),
        submit=function(value)
            if type(value)=='string' and #value<=1024 and not value:find('[%c]') then callback(value) end
            if label~='新受控房间' then mp.add_timeout(0, function() show() end) end
        end})
end
local connection_labels = {disconnected='未连接',connecting='连接中',connected='已连接',error='错误'}
local warning_labels = {
    ['Waiting for media; synchronization is suspended']='等待媒体；同步已暂停',
    ['Synchronization requires playback speed 1.0; synchronization is suspended']='同步需要 1x 播放速度；同步已暂停',
    ['Buffering or seeking; synchronization is suspended']='缓冲或跳转中；同步已暂停',
    ['Media is not seekable; position synchronization is unavailable']='媒体不可跳转；无法同步播放位置',
}
local function connection_label() return connection_labels[state.connection] or plain(state.connection) end
local function warning_label() return plain(warning_labels[state.warning] or state.warning) end
local function rows()
    local r = {
        {title='服务器: '..plain(cfg.host), value='host'},
        {title='端口: '..plain(cfg.port), value='port'},
        {title='昵称: '..plain(cfg.username), value='username'},
        {title='房间: '..plain(cfg.room), value='room'},
        {title='服务器密码: '..(password=='' and '空' or '已存于内存'), value='password'},
        {title='TLS: '..plain(cfg.tls), value='tls'},
        {title='连接 / 手动重连', value='connect'},
        {title='断开连接', value='disconnect'},
        {title='准备: '..(state.ready==true and '是' or '否'), value='ready'},
        {title='认证房间操作员', value='authenticate'},
        {title='创建受控房间', value='create-room'},
        {title='清除内存中的服务器密码', value='clear-password'},
        {title='刷新状态与成员列表', value='refresh'},
        {title='当前昵称: '..plain(state.username)..' | 当前房间: '..plain(state.room), value='noop',selectable=false},
    }
    if type(state.error)=='string' and state.error~='' then
        table.insert(r,1,{title='错误: '..plain(state.error),value='noop',selectable=false})
    end
    for _, member in ipairs(state.members or {}) do
        r[#r+1] = {title=plain(member.username)..' | '..plain(member.room)..
            ' | '..(member.ready==true and '已准备' or (member.ready==false and '未准备' or '准备状态未知'))..(member.is_controller and ' | 操作员' or ''),
            value='noop', selectable=false}
    end
    if type(state.warning)=='string' and state.warning~='' then
        table.insert(r,1,{title='同步提示: '..warning_label(),value='noop',selectable=false})
    end
    return r
end
local function menu()
    return {type='splay', title='splay | '..connection_label()..
        (state.encrypted and ' | TLS' or ' | 明文 / 未连接'),
        footnote=warning_label(),
        items=rows(), callback={'splay','splay-menu-event'},
        on_close={'script-message-to','splay','splay-menu-closed'}}
end
show = function(mode)
    send({action='status'})
    if (mode or cfg.ui)=='uosc' then
        menu_open=true
        mp.commandv('script-message-to','uosc','open-menu',utils.format_json(menu()))
        mp.add_timeout(0.4,function()
            if menu_open and mp.get_property_native('user-data/uosc/menu/type')~='splay' then
                menu_open=false; mp.osd_message('uosc 无响应，打开原生面板',3); show('native')
            end
        end)
    else
        menu_open=false
        local entries, labels = rows(), {}
        for i,item in ipairs(entries) do labels[i]=item.title end
        if mp.get_property_native('options/load-console')==false then
            mp.osd_message('splay 需要 mpv console 脚本；请启用 load-console',5); return
        end
        input.select({prompt=menu().title, items=labels,
            submit=function(i) if entries[i] then mp.add_timeout(0,function() act(entries[i].value) end) end end})
    end
end
act = function(action)
    if action=='refresh' then show()
    elseif action=='connect' then connect()
    elseif action=='disconnect' then send({action='disconnect'})
    elseif action=='ready' then send({action='ready',ready=not state.ready})
    elseif action=='clear-password' then password=''
    elseif action=='tls' then
        input.select({prompt='TLS 策略',items={'prefer（明确不支持时允许明文）','require（强制 TLS）','off（明文）'},
            submit=function(i) cfg.tls=({'prefer','require','off'})[i] or 'prefer' end})
    elseif action=='authenticate' then
        prompt('操作员密码 AB-123-456','',function(v) send({action='authenticate',password=v}) end,true)
    elseif action=='create-room' then
        prompt('新受控房间','',function(room)
            mp.add_timeout(0.01,function()
                prompt('新操作员密码 AB-123-456','',function(v) send({action='create-room',room=room,password=v}) end,true)
            end)
        end)
    elseif action=='password' then prompt('服务器密码','',function(v) password=v end,true)
    elseif action=='host' or action=='port' or action=='username' or action=='room' then
        prompt(({host='服务器',port='端口',username='昵称',room='房间'})[action],cfg[action],function(v)
            if action=='port' then
                local n=tonumber(v); if not n or n<1 or n>65535 or n%1~=0 then return end
                cfg.port=n
            else cfg[action]=v end
            if action=='room' and state.connection=='connected' then send({action='room',room=v}) end
        end)
    end
end
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local v=utils.parse_json(json)
    if type(v)~='table' or v.schema~=1 or type(v.members)~='table' then return end
    state=v
    if state.connection~=previous_connection then
        previous_connection=state.connection
        mp.osd_message('splay: '..connection_label()..' '..plain(state.error),3)
    end
    if menu_open then mp.commandv('script-message-to','uosc','update-menu',utils.format_json(menu())) end
    mp.commandv('script-message-to','uosc','set-button','splay',utils.format_json({icon='sync',
        tooltip='splay: '..connection_label(), active=state.connection=='connected',
        command={'script-message-to','splay','splay-open','uosc'}}))
end)
mp.register_script_message('splay-open',function(mode) show(mode=='uosc' and 'uosc' or 'native') end)
mp.register_script_message('splay-menu-closed',function() menu_open=false end)
mp.register_script_message('splay-menu-event',function(json)
    local e=utils.parse_json(json or '')
    if type(e)=='table' and e.type=='activate' and type(e.value)=='string' then act(e.value) end
end)
-- Automation entrypoint uses the exact core JSON schema. Never log its payload.
mp.register_script_message('splay-command',function(json)
    if type(json)=='string' and #json<=16384 then
        local v=utils.parse_json(json)
        if type(v)=='table' and type(v.action)=='string' then
            if v.action=='connect' then
                for _,k in ipairs({'host','port','username','room','tls'}) do if v[k]~=nil then cfg[k]=v[k] end end
                password=type(v.password)=='string' and v.password or ''
            end
            send(v)
        end
    end
end)
mp.add_key_binding('Ctrl+Shift+s','splay-panel',function() show() end)
mp.add_timeout(0.2,function() send({action='status'}) end)
mp.register_event('shutdown',function() password='' end)
