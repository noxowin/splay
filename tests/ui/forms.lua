-- Production main UI with an in-process mpv double; no network or config writes.
local real_mp=require 'mp'
real_mp.add_timeout(10,function() real_mp.commandv('quit',2) end)
local utils=require 'mp.utils'
local options=require 'mp.options'
local opt={source=''};options.read_options(opt,'forms')
local handlers,commands,selected,prompted,bindings,notices,properties,observers,active_request,registered_events
local terminated,console_layer
local overrides={}
local fixture={host='history.example',port=9001,username='历史昵称',room='历史房间',tls='require'}
local history={schema=1,last=fixture,profiles={fixture},values={host={'history.example'},port={9001},username={'历史昵称'},room={'历史房间'},tls={'require'}}}
local fake={}
fake.commandv=function(...) commands[#commands+1]={...} end
fake.command_native=function(value) assert(value[1]=='expand-path');return value[2]:gsub('~~/','isolated/') end
fake.get_property_native=function(name) return properties[name] end
fake.set_property_native=function(name,value) properties[name]=value end
fake.observe_property=function(name,_,fn) observers[name]=fn;fn(name,properties[name]) end
fake.register_script_message=function(name,fn) handlers[name]=fn end
fake.register_event=function(name,fn) registered_events[name]=fn end
fake.add_timeout=function(delay,fn)
    local timer={kill=function() end}
    if delay==0 or delay==0.01 then fn() end
    return timer
end
fake.get_time=function() return 100 end
fake.get_osd_size=function() return 1100,800 end
fake.create_osd_overlay=function()
    console_layer={data='',update=function(self) self.updates=(self.updates or 0)+1 end,
        remove=function(self) self.data='';self.removed=true end}
    return console_layer
end
fake.add_key_binding=function(key,name,fn,flags) bindings[name]={key=key,fn=fn,flags=flags};handlers[name]=fn end
fake.add_forced_key_binding=function(key,name,fn) bindings[name]={key=key,fn=fn,forced=true} end
fake.remove_key_binding=function(name) bindings[name]=nil end
fake.osd_message=function(text) notices[#notices+1]=text end
package.loaded.mp=fake
package.loaded['mp.options']={read_options=function(cfg) for key,value in pairs(overrides) do cfg[key]=value end end}
package.loaded['mp.input']={select=function(value) selected=value;active_request=value end,get=function(value) prompted=value;active_request=value;if value.opened then value.opened() end end,
    terminate=function()
        terminated=terminated+1;local request=active_request;active_request=nil
        if request and request.closed then request.closed() end
    end}
local function start(config)
    handlers,commands,selected,prompted,bindings,notices,observers={},{},nil,nil,{},{},{}
    registered_events={}
    terminated=0;active_request=nil
    properties={['options/load-console']=true,path='https://private.example/SECRET_URL',filename='本机影片.mp4',['idle-active']=false}
    overrides=config or {}
    -- Chinese assertions must not depend on the machine's UI language.
    if overrides.language==nil then overrides.language='zh-CN' end
    assert(loadfile(opt.source))()
end
local function core()
    local found={}
    for _,item in ipairs(commands) do if item[2]=='splay_core' then found[#found+1]=utils.parse_json(item[4]) end end
    return found
end
local function last(action)
    local all=core();for i=#all,1,-1 do if all[i].action==action then return all[i] end end
end
local function count(action)
    local n=0;for _,item in ipairs(core()) do if item.action==action then n=n+1 end end;return n
end
local function credential_reply(request,saved,error)
    assert(request and request.request_id,'credential requests must carry correlation ids')
    local reply={schema=1,request_id=request.request_id,saved=saved==true,error=error}
    if request.action~='credential-init' then reply.host=request.host;reply.port=request.port end
    handlers['splay-credential'](utils.format_json(reply))
end
local function credential_init(saved)
    credential_reply(last('credential-init'),false)
    credential_reply(last('credential-status'),saved)
end
local function history_reply(value,request)
    local reply=utils.parse_json(utils.format_json(value))
    reply.request_id=(request or last('history-load')).request_id
    handlers['splay-history'](utils.format_json(reply))
end
local function secret_reply(request,token,saved,cancelled,error)
    handlers['splay-secret'](utils.format_json({request_id=request.request_id,purpose=request.purpose,
        token=token,saved=saved==true,cancelled=cancelled==true,error=error}))
end
-- Type into the open password prompt the way mpv delivers it: submit, then
-- closed. Returns the one command that carries the password to the core.
local function secret_submit(value)
    local request=prompted
    assert(request and request.id:find('splay-secret-',1,true),'a password prompt is open')
    local before=count('secret-submit')
    if active_request==request then active_request=nil end
    request.submit(value);if request.closed then request.closed() end
    assert(count('secret-submit')==before+1,'one command per submitted password')
    return last('secret-submit')
end
-- Typed passwords contain TYPED_PW. They may reach the core only in
-- secret-submit; nothing the script displays, publishes or saves holds them.
local function assert_private()
    for _,item in ipairs(commands) do
        local value=item[2]=='splay_core' and utils.parse_json(item[4]) or nil
        if not (value and value.action=='secret-submit') then
            for _,arg in ipairs(item) do assert(not tostring(arg):find('TYPED_PW',1,true),'password published in '..tostring(item[3])) end
        end
    end
    for name,value in pairs(properties) do
        assert(not utils.format_json(value):find('TYPED_PW',1,true),'password left in property '..name)
    end
    for _,text in ipairs(notices) do assert(not text:find('TYPED_PW',1,true),'password shown in a notice') end
end
local function act(action) handlers['splay-action'](action) end
local function finish(value,kind)
    local request=kind=='select' and selected or prompted
    if active_request==request then active_request=nil end
    if request.closed then request.closed() end
    request.submit(value)
end
local function dismiss()
    local request=active_request;active_request=nil
    if request and request.closed then request.closed() end
end
local function prop(name,value)
    properties[name]=value;if observers[name] then observers[name](name,value) end
end
local function state(extra)
    local value={schema=1,connection='connected',host='history.example',port=9001,members={},room='active-room',chat_supported=true,chat_max_length=3,ready=false}
    for key,item in pairs(extra or {}) do value[key]=item end
    handlers['splay-state'](utils.format_json(value))
end
local function model()
    for i=#commands,1,-1 do if commands[i][3]=='splay-menu-model' then return utils.parse_json(commands[i][4]) end end
end
local function console_text()
    return console_layer.data:gsub('{[^}]*}','')
end
local function label(fragment)
    if properties['user-data/splay-console-open'] then return console_text():find(fragment,1,true)~=nil end
    for _,text in ipairs(selected.items) do if text:find(fragment,1,true) then return true end end
    return false
end
local function history_label()
    act('settings')
    local result
    for _,text in ipairs(selected.items) do if text:find('消息记录:',1,true) then result=text end end
    dismiss();return result
end
start()
assert(bindings['splay-panel'].key=='Shift+s' and bindings['splay-panel'].flags==nil)
assert(not bindings['splay-message-history'],'default off must preserve the host history key')
assert(last('history-load').path=='isolated/splay-history.json' and count('connect')==0 and count('status')==0)
assert(last('credential-init').path=='isolated/splay-credentials.json')
credential_init(false)
assert(properties['user-data/splay'].enabled==false and not bindings['splay-chat-enter'])
assert(#model().items<=2 and model().items[1].value=='toggle-enabled')
handlers['splay-command'](utils.format_json({action='connect',room='  '}))
assert(count('connect')==0 and properties['user-data/splay'].enabled==false,'empty external connect must not enable')
act('toggle-enabled');assert(properties['user-data/splay'].enabled and count('connect')==0)
assert(bindings['splay-message-history'].key=='Shift+h' and not bindings['splay-message-history'].forced)
act('connect');assert(count('connect')==0,'first-run room must be blank')
act('connection');assert(label('请先输入或选择') and label('服务器密码:') and label('已保存的连接组合') and label('加入'));dismiss()
act('room');finish('');history_reply(history)
credential_reply(last('credential-status'),false)
assert(last('history-save').settings.room=='' and not last('history-save').remember_profile,'blank room draft survives restore')
act('connect');assert(count('connect')==0)
act('profiles');finish(2,'select');finish(3,'select');dismiss();credential_reply(last('credential-status'),false);act('connect')
assert(last('connect').room=='历史房间' and last('connect').password==nil and last('connect').auto_reconnect==true)
assert(last('history-save').settings.password==nil)
state();assert(bindings['splay-chat-enter'] and bindings['splay-chat-enter'].forced,'eligible Enter overrides user fullscreen binding only while available')
assert(#model().items==6 and model().items[3].value=='playlist' and model().items[4].value=='room-actions' and model().items[5].value=='settings')
assert(model().items[1].title:find('history.example:9001',1,true) and model().items[1].title:find('active-room',1,true) and not model().items[1].title:find('历史房间',1,true))
for _,item in ipairs(model().items) do assert(item.value~='chat' and item.value~='members') end
act('connection');assert(label('history.example : 9001') and label('服务器密码: 空（无密码）'));dismiss()
act('endpoint');assert(label('服务器: history.example') and label('端口: 9001'));dismiss()
act('room-actions');assert(label('房间成员: 0') and #selected.items<=8);dismiss()
for _,name in ipairs({'user-data/mpv/console/open','user-data/mpv/context-menu/open'}) do
    prop(name,true);assert(not bindings['splay-chat-enter']);prop(name,false);assert(bindings['splay-chat-enter'])
end
prop('user-data/uosc/menu/type','other');assert(not bindings['splay-chat-enter']);prop('user-data/uosc/menu/type',nil)
prop('user-data/splay-overlay',{popup_open=true});assert(not bindings['splay-chat-enter']);prop('user-data/splay-overlay',{popup_open=false})
prop('path',nil);assert(not bindings['splay-chat-enter']);prop('path','fixture.mp4');registered_events['file-loaded']()
prop('idle-active',true);assert(not bindings['splay-chat-enter']);prop('idle-active',false)
bindings['splay-chat-enter'].fn();assert(prompted.prompt:find('Esc',1,true) and not bindings['splay-chat-enter'])
finish('四个字符');assert(count('chat')==0)
bindings['splay-chat-enter'].fn();finish('中文');assert(last('chat').text=='中文')
bindings['splay-chat-enter'].fn();dismiss();assert(count('chat')==1,'Escape/closed sends nothing')
bindings['splay-chat-enter'].fn();state({room='changed-while-typing'});finish('旧稿')
assert(count('chat')==1,'a prompt opened in another room must not send to the new room')
state({chat_supported=false});assert(not bindings['splay-chat-enter'])
local previous=prompted;handlers['splay-chat']();assert(prompted==previous)
state({chat_supported=true})
local previous_prompt=prompted
act('password');local password_prompt=prompted
assert(password_prompt~=previous_prompt and password_prompt.default_text=='' and password_prompt.history_path==nil)
assert(password_prompt.prompt=='服务器 history.example:9001 的密码（输入时可见）: ','the prompt warns that the password is visible')
assert(notices[#notices]:find('明文显示',1,true) and not bindings['splay-chat-enter'] and count('secret-submit')==0)
act('connection');assert(label('输入中'),'the form shows a password being entered');dismiss()
act('password');local native_password=secret_submit('TYPED_PW_server_1')
assert(native_password.purpose=='server' and native_password.host=='history.example' and native_password.port==9001)
assert(native_password.remember_password==true and native_password.password=='TYPED_PW_server_1' and not bindings['splay-chat-enter'])
secret_reply(native_password,'opaque-server-1',true)
act('connection');assert(label('已加密保存'));dismiss()
act('connect');assert(last('connect').password==nil and last('connect').password_token=='opaque-server-1')
act('room');finish(1,'select');finish('same-server-room');dismiss()
act('connect');assert(last('connect').use_saved_password==true,'room edits retain endpoint credentials')
act('username');finish(1,'select');finish('new-nickname');dismiss()
act('connect');assert(last('connect').use_saved_password==true,'nickname edits retain endpoint credentials')
act('host');finish(1,'select');finish('other.example');dismiss()
assert(last('credential-status').host=='other.example')
handlers['splay-credential'](utils.format_json({schema=1,host='history.example',port=9001,saved=true}))
local pending_connects=count('connect');act('connect');assert(count('connect')==pending_connects,'connect waits for current endpoint status')
credential_reply(last('credential-status'),false)
assert(last('connect').use_saved_password==false,'late reply for another endpoint is ignored')
handlers['splay-credential'](utils.format_json({schema=1,host='other.example',port=9001,saved=true}))
act('clear-password');assert(last('credential-delete').host=='other.example')
credential_reply(last('credential-delete'),false)
act('connection');assert(label('密码: 空'));dismiss()
act('toggle-remember-password');act('password');local memory_password=secret_submit('TYPED_PW_memory')
assert(memory_password.remember_password==false)
secret_reply(memory_password,'opaque-memory-only',false)
act('connect');assert(last('connect').password_token=='opaque-memory-only' and last('connect').remember_password==false)
act('connect');assert(last('connect').reuse_password==true and last('connect').password_token==nil,'opt-out reuses only the native endpoint-bound hash')
act('toggle-remember-password');assert(count('credential-save')==0,'saving requires typing the password again')
act('profiles');finish(2,'select');finish(3,'select');credential_reply(last('credential-status'),true);act('connect');assert(last('connect').password==nil)
act('room');finish(1,'select');finish('new-room');dismiss();assert(count('room')==0)
act('join-room');assert(last('room').room=='new-room')
handlers['splay-command'](utils.format_json({action='connect',host='external.example',port=8999,username='external',room='external-room',tls='off',password='EXTERNAL_SECRET',custom='preserved'}))
assert(last('connect').custom=='preserved' and last('connect').password=='EXTERNAL_SECRET')
assert(last('history-save').settings.host=='external.example' and last('history-save').settings.password==nil)
handlers['splay-event']('{"schema":1,"type":"chat","username":"user","text":"before\\u0000after"}')
act('chat-history');assert(label('before␀after'));dismiss()
handlers['splay-event']('{"schema":1,"type":"chat","username":"user","text":"literal\\\\u0000after"}')
act('chat-history');assert(label('u0000after'),'escaped backslashes remain literal');dismiss()
for index=1,305 do handlers['splay-event'](utils.format_json({schema=1,id=index,type='chat',username='user',text='message'..index})) end
act('message-history');assert(label('300 / 300'),'history must retain its bounded 300 events')
for _=1,40 do bindings['splay-console-page-up'].fn() end
assert(label('user: message6') and not label('user: message5'),'oldest retained event must be message6');dismiss()
handlers['splay-event'](utils.format_json({schema=1,id=305,type='chat',username='user',text='duplicate'}))
act('message-history');assert(label('300 / 300') and not label('duplicate'));dismiss()
state({room='different-room'});act('message-history');assert(label('300 / 300'));dismiss()
handlers['splay-event'](utils.format_json({schema=1,type='chat',username='user',text='current-room'}))
state({connection='disconnected',room='different-room'});act('message-history');assert(label('current-room'));dismiss()
local events={
    {type='connection',connection='connecting'}, {type='room',room='another-room'},
    {type='user',action='joined',username='joiner',room='different-room'},
    {type='ready',username='joiner',ready=true},
    {type='playlist',action='files',user='joiner',files={'one','two'}},
    {type='playback',username='joiner',paused=false,position=65,seek=true},
    {type='catchup',action='slow',username='joiner'},{type='catchup',action='normal'},
}
for index,event in ipairs(events) do event.schema=1;event.id=400+index;handlers['splay-event'](utils.format_json(event)) end
handlers['splay-notice'](utils.format_json({text='列表操作已发送',category='playlist'}))
state({warning='Waiting for media; synchronization is suspended',error='Example server error'})
state({warning='Waiting for media; synchronization is suspended',error='Example server error'})
act('message-history');assert(label('连接: 连接中') and label('切换房间: another-room') and label('joiner 加入房间'))
assert(label('joiner 已准备') and label('更新共享播放列表: 2 项') and label('跳转 · 65 秒') and label('列表操作已发送'))
assert(label('与 joiner 有时间差，暂时减速追赶') and label('已追上房间进度，恢复正常速度'),'catch-up events are recorded')
local _,warning_count=console_text():gsub('等待媒体','')
assert(warning_count==1,'state warning transitions append once');dismiss()
act('playlist');local playlist_open=false
for _,command in ipairs(commands) do if command[2]=='splay_playlist' and command[3]=='splay-playlist-open' then playlist_open=true end end
assert(playlist_open)
local large_files={};for i=1,300 do large_files[i]=string.rep('episode-',12)..i..'.mkv' end
handlers['splay-command'](utils.format_json({action='playlist',files=large_files}))
assert(#last('playlist').files==300,'full shared playlist commands may exceed the old 16 KiB UI cap')
act('toggle-status');act('toggle-buttons')
local toggled_state
for _,item in ipairs(commands) do if item[2]=='splay_overlay' and item[3]=='splay-state' then toggled_state=utils.parse_json(item[4]) end end
assert(toggled_state.settings.status_osd==false and toggled_state.settings.button_enabled==false)
act('toggle-enabled');assert(not bindings['splay-chat-enter'] and not bindings['splay-message-history'] and count('disconnect')==1 and not model().enabled)
local playlist_count=count('playlist');handlers['splay-command'](utils.format_json({action='playlist',files={'ignored'}}))
assert(count('playlist')==playlist_count,'disabled splay must gate shared playlist actions')
handlers['splay-event'](utils.format_json({schema=1,type='chat',username='user',text='ignored'}))
assert(properties['user-data/splay'].enabled==false)
for _,item in ipairs(commands) do
    assert(item[1]~='set' and item[1]~='seek' and item[1]~='loadfile','UI toggles must preserve playback')
    if item[3]=='splay-state' then
        assert(type(utils.parse_json(item[4]).enabled)=='boolean')
        assert(not item[4]:find('SECRET',1,true) and not item[4]:find('MEMORY_ONLY',1,true) and not item[4]:find('private.example',1,true),'published display state must not contain passwords or private paths')
    end
    if item[2]=='splay_core' then
        local value=utils.parse_json(item[4])
        if value.action=='history-save' then assert(not item[4]:find('SECRET',1,true) and not item[4]:find('MEMORY_ONLY',1,true)) end
    end
end
assert_private()
commands={};handlers['splay-overlay-ready']();assert(commands[1][3]=='splay-state' and commands[2][2]=='splay_playlist' and commands[3][3]=='splay-menu-model')
assert(utils.parse_json(commands[2][4]).local_file=='fixture.mp4')
commands={};handlers['splay-playlist-ready']();assert(commands[2][2]=='splay_playlist')
-- Automatic migration blanks only the legacy placeholder; explicit profile selection retains it.
start();local legacy=utils.parse_json(utils.format_json(history));legacy.last.room='DeFaUlT';legacy.profiles[1].room='Default'
history_reply(legacy);act('toggle-enabled');act('connect');assert(count('connect')==0)
credential_init(false)
act('profiles');finish(2,'select');finish(3,'select');credential_reply(last('credential-status'),false);act('connect');assert(last('connect').room=='Default')
-- A late history reply preserves edited fields and restores the remaining draft fields.
start();act('toggle-enabled');act('host');finish('typed-first.example');dismiss()
history_reply(history)
assert(last('history-save').settings.host=='typed-first.example' and last('history-save').settings.room=='历史房间')
start({history_enabled=false});assert(count('history-load')==0 and count('connect')==0 and count('credential-init')>0)
act('toggle-enabled');act('host');finish('fresh.example');assert(count('history-save')==0)
-- A fast user connect waits through init/status/save, and only the latest
-- request can change saved state or release that connection.
start({host='race.example',port=8999,username='race',room='room',tls='off',history_enabled=false})
act('toggle-enabled');act('connect');assert(count('connect')==0)
credential_reply(last('credential-init'),false);assert(count('connect')==0)
local first_status=last('credential-status')
handlers['splay-credential'](utils.format_json({schema=1,host='race.example',port=8999,saved=true}))
assert(count('connect')==0,'uncorrelated legacy response cannot release a pending connect')
credential_reply(first_status,true);assert(last('connect').use_saved_password==true)
act('password')
pending_connects=count('connect');act('connect');assert(count('connect')==pending_connects,'connect waits for the open password prompt')
credential_reply(first_status,false);assert(count('connect')==pending_connects,'old same-endpoint status cannot overwrite pending save')
local saving=secret_submit('TYPED_PW_race');assert(count('connect')==pending_connects,'connect waits for the core to take the password')
secret_reply(saving,'opaque-race',true)
assert(count('connect')==pending_connects+1 and last('connect').password_token=='opaque-race' and last('connect').password==nil)
act('clear-password');local deleting=last('credential-delete');pending_connects=count('connect');act('connect')
secret_reply(saving,'old-token',true);assert(count('connect')==pending_connects,'old native input cannot resurrect a deleted credential')
credential_reply(deleting,false);assert(last('connect').password==nil and last('connect').use_saved_password==false)
act('password');pending_connects=count('connect');act('connect')
secret_reply(secret_submit('TYPED_PW_save_failure'),nil,false,false,'fixture save failure');act('connect')
assert(count('connect')==pending_connects,'save failure must never fall back to an empty-password connection')
assert(notices[#notices]:find('fixture save failure',1,true))
act('toggle-remember-password');act('password');secret_reply(secret_submit('TYPED_PW_retry'),'retry-memory',false)
act('connect');assert(last('connect').remember_password==false and last('connect').password_token=='retry-memory')
-- Closing the prompt without submitting is a cancel: nothing reaches the
-- core, a connect that waited for it does not run, and Enter is free again.
state({connection='disconnected'});act('password');pending_connects=count('connect');act('connect')
local submits=count('secret-submit');dismiss()
assert(count('secret-submit')==submits and count('connect')==pending_connects and not active_request)
act('connection');assert(not label('输入中'));dismiss()
act('connect');assert(count('connect')==pending_connects+1 and last('connect').password_token==nil,'a cancelled prompt leaves no pending password')
assert_private()
start({host='race.example',port=8999,username='race',room='room',tls='off',history_enabled=false})
credential_init(true);act('toggle-enabled');act('toggle-remember-password');act('connection')
assert(label('当前不使用'));dismiss();act('connect');assert(last('connect').use_saved_password==false and last('connect').password==nil)
start({host='race.example',port=8999,username='race',room='room',tls='off',history_enabled=false})
credential_init(false);act('toggle-enabled');state()
act('username');local replaced_prompt=prompted;act('room');local current_prompt=prompted
assert(current_prompt~=replaced_prompt and not bindings['splay-chat-enter'])
replaced_prompt.closed();assert(not bindings['splay-chat-enter'],'a stale close must not release the current input modal')
act('toggle-enabled');assert(terminated>=1 and not active_request and not bindings['splay-message-history'],'disable must close the current input and restore the host history key')
start({host='rooms.example',port=8999,username='race',room='local-room',tls='off',history_enabled=false})
credential_init(false);act('toggle-enabled')
state({room='local-room',members={{username='inside',room='local-room',ready=true},
    {username='outsider',room='foreign-room',ready=false},{username='unknown',room='local-room'}}})
act('room-actions');assert(label('房间成员: 2'));dismiss()
act('members');assert(label('inside') and label('unknown') and label('准备状态未知') and not label('outsider'));dismiss()
local history_title=history_label()
for index,event in ipairs({
    {action='joined',username='outsider',room='foreign-room'},
    {action='file',username='outsider',room='foreign-room',file={name='unrelated.mkv'}},
    {action='room',username='outsider',room='foreign-room',previous_room='another-foreign-room'},
}) do event.schema=1;event.type='user';event.id=800+index;handlers['splay-event'](utils.format_json(event)) end
assert(history_label()==history_title,'unrelated room events must not enter message history')
for index,event in ipairs({
    {type='user',action='room',username='moving-out',room='foreign-room',previous_room='local-room'},
    {type='user',action='room',username='moving-in',room='local-room',previous_room='foreign-room'},
    {type='user',action='left',username='race',room='local-room'},
    {type='ready',username='not-ready',ready=false},
}) do event.schema=1;event.id=810+index;handlers['splay-event'](utils.format_json(event)) end
handlers['splay-event']('{"schema":1,"id":820,"type":"ready","username":"unknown","ready":null}')
act('message-history')
assert(not label('outsider') and label('moving-out 切换房间: foreign-room') and label('moving-in 切换房间: local-room'))
assert(label('race 离开房间: local-room') and label('not-ready 未准备') and label('unknown 准备状态未知') and not label('unknown 未准备'));dismiss()
-- Connection-page saving gives explicit feedback and never snapshots a pending
-- password operation. These fixtures use isolated history and opaque tokens.
start();credential_init(false);history_reply(history);credential_reply(last('credential-status'),false);act('toggle-enabled')
act('connection');assert(#selected.items==7 and label('已保存的连接组合: 1') and label('服务器密码: 空（无密码）') and label('加入') and not label('断开连接'));dismiss()
state();act('connection');assert(#selected.items==8 and label('断开连接') and not label('自动重连:'));dismiss()
state({connection='disconnected'})
local save_before=count('history-save')
act('room');finish(1,'select');finish('');act('save-profile')
assert(count('history-save')==save_before+1 and notices[#notices]:find('请先输入或选择房间',1,true))
act('room');finish(1,'select') -- choose the manual room entry from suggestions.
finish('新房间')
act('password');local saving_profile_secret=secret_submit('TYPED_PW_profile_failure');save_before=count('history-save')
act('save-profile');assert(count('history-save')==save_before and notices[#notices]:find('请先完成或取消密码输入',1,true))
secret_reply(saving_profile_secret,nil,false,false,'fixture credential failure')
act('save-profile');assert(count('history-save')==save_before and notices[#notices]:find('密码存储错误',1,true))
act('toggle-remember-password');act('save-profile')
assert(count('history-save')==save_before+1,'password opt-out must allow saving non-secret settings despite a credential failure')
history_reply(history,last('history-save'));assert(notices[#notices]:find('密码不随组合保存',1,true))
act('toggle-remember-password')
act('password');secret_reply(secret_submit('TYPED_PW_profile'),'opaque-profile-secret',true)
act('save-profile');local saved_profile=last('history-save')
assert(saved_profile.remember_profile and saved_profile.settings.room=='新房间' and saved_profile.settings.password==nil and saved_profile.password_token==nil)
assert(notices[#notices]:find('正在保存连接组合',1,true))
history_reply(history,saved_profile);assert(notices[#notices]:find('连接组合已保存',1,true))
act('toggle-remember-password');act('save-profile');history_reply(history,last('history-save'))
assert(notices[#notices]:find('已有加密密码当前不使用',1,true));act('toggle-remember-password')
act('profiles');finish(2,'select');assert(label('修改连接信息') and label('删除此组合'));finish(4,'select')
assert(selected.prompt:find('同服务器端口的其他组合仍可使用密码',1,true));finish(1,'select')
assert(count('history-delete')==0 and count('credential-delete')==0,'cancel must keep the combination and endpoint password')
start({host='waiting.example',port=8999,username='draft',room='room',history_enabled=true})
act('toggle-enabled');save_before=count('history-save');act('save-profile')
assert(count('history-save')==save_before and notices[#notices]:find('正在读取或保存服务器密码',1,true))
credential_init(false);act('save-profile')
assert(count('history-save')==save_before and notices[#notices]:find('连接记忆正在读取',1,true))
start({remember_password=false});history_reply(history);act('toggle-enabled');save_before=count('history-save')
act('save-profile');assert(count('history-save')==save_before+1,'password opt-out must not wait for credential initialization')
credential_reply(last('credential-init'),false,'fixture DPAPI init failure');act('save-profile')
assert(count('history-save')==save_before+2,'password opt-out must not depend on DPAPI availability')
start({history_enabled=false});credential_init(false);act('toggle-enabled');act('save-profile')
assert(count('history-save')==0 and notices[#notices]:find('连接记忆已关闭',1,true))
-- Profile management keeps a full settings identity across live reordering.
start();credential_init(true);history_reply(history);credential_reply(last('credential-status'),true);act('toggle-enabled')
act('settings');assert(#selected.items<=20 and label('连接历史管理') and label('自动重连') and label('成员加入时暂停房间'));dismiss()
act('history-management');assert(#selected.items<=7 and label('已保存的连接组合'));dismiss()
act('manage-profiles');finish(2,'select');finish(5,'select')
finish('家庭影院')
local rename=last('history-rename')
assert(rename.name=='家庭影院' and rename.settings.host=='history.example' and rename.settings.room=='历史房间' and rename.index==nil)
local named=utils.parse_json(utils.format_json(history));named.profiles[1].name='家庭影院'
history_reply(named,rename)
act('profiles');assert(label('家庭影院'));dismiss()
act('manage-profiles');local old_selection=selected
local fresh=utils.parse_json(utils.format_json(named));fresh.profiles={{host='another.example',port=8999,username='other',room='other',tls='off'},fresh.profiles[1]}
act('save-profile');history_reply(fresh,last('history-save'))
assert(selected==old_selection);finish(2,'select');finish(4,'select');assert(selected.prompt:find('字段建议、当前连接和密码保留',1,true));finish(2,'select')
local deleting=last('history-delete')
assert(deleting.settings.host=='history.example' and deleting.settings.room=='历史房间' and deleting.index==nil,'management must use the originally selected settings identity')
history_reply(fresh,deleting)
act('clear-history-field');finish(4,'select');assert(label('确认清空房间建议'));finish(2,'select')
local clearing_field=last('history-clear-values');assert(clearing_field.field=='room' and clearing_field.request_id)
act('clear-history');assert(label('确认清空全部非密码历史'));finish(1,'select');assert(count('history-clear')==0)
act('clear-history');finish(2,'select');local clearing_all=last('history-clear')
assert(clearing_all.request_id>clearing_field.request_id and count('credential-delete')==0 and count('password-clear')==0)
local empty={schema=1,last={},profiles={},values={host={},port={},username={},room={},tls={}}}
history_reply(empty,clearing_all)
history_reply(named,clearing_field) -- late field-only result must not resurrect combinations.
act('history-management');assert(label('已保存的连接组合: 0'));dismiss()
act('connect');assert(last('connect').room=='历史房间' and last('connect').use_saved_password==true,'clear keeps current form and credentials')
-- Closing/reopening splay invalidates outstanding text/selection callbacks.
act('clear-history');local stale_clear=selected
act('toggle-enabled');act('toggle-enabled');local clears=count('history-clear')
stale_clear.submit(2);assert(count('history-clear')==clears)
act('username');local stale_name=prompted
act('toggle-enabled');act('toggle-enabled');local saves=count('history-save')
stale_name.submit('stale-edit');assert(count('history-save')==saves)
-- Password prompts and replies are correlated to purpose, endpoint and UI lifetime.
state();act('password');local old_prompt=prompted;local closes=terminated
act('password');local new_prompt=prompted
assert(new_prompt~=old_prompt and terminated==closes+1,'asking again closes the earlier prompt')
assert(new_prompt.id~=old_prompt.id,'each password prompt has an input history of its own')
submits=count('secret-submit');old_prompt.submit('TYPED_PW_replaced');assert(count('secret-submit')==submits,'a replaced prompt cannot submit')
local old_secret=secret_submit('TYPED_PW_current')
act('password');local new_secret=secret_submit('TYPED_PW_newer')
assert(new_secret.request_id>old_secret.request_id)
secret_reply(old_secret,'obsolete-token',true);assert(not bindings['splay-chat-enter'],'a stale reply is ignored')
secret_reply(new_secret,nil,false,true);assert(bindings['splay-chat-enter'])
local get_before=prompted
act('authenticate');assert(prompted~=get_before and prompted.prompt=='操作员密码，例如 AB-123-456（输入时可见）: ')
local operator=secret_submit('TYPED_PW_operator')
assert(operator.purpose=='operator' and operator.room=='active-room' and operator.password=='TYPED_PW_operator')
secret_reply(operator,nil,false,true)
act('authenticate');state({room='moved-room'});submits=count('secret-submit')
prompted.submit('TYPED_PW_moved');assert(count('secret-submit')==submits,'an operator password typed for another room is dropped')
prompted.closed();state()
act('create-room');finish('new-controlled-room')
assert(prompted.prompt:find('new-controlled-room',1,true) and prompted.prompt:find('输入时可见',1,true))
local creating=secret_submit('TYPED_PW_create')
assert(creating.purpose=='create_room' and creating.room=='new-controlled-room')
secret_reply(creating,nil,false,false,'Use operator password AA-123-456')
assert(notices[#notices]:find('Use operator password AA-123-456',1,true))
assert(count('authenticate')==0 and count('create-room')==0 and count('credential-save')==0,'all interactive secret consumption stays in native code')
act('password');local closed_prompt=prompted;act('toggle-enabled');act('toggle-enabled')
submits=count('secret-submit');closed_prompt.submit('TYPED_PW_disabled');assert(count('secret-submit')==submits)
act('password');old_secret=secret_submit('TYPED_PW_closing');act('toggle-enabled');act('toggle-enabled')
secret_reply(old_secret,'closed-token',true);act('connect');assert(last('connect').password_token~='closed-token')
assert_private()
state({connection='error',error='retry failure',reconnect={enabled=true,pending=true,attempt=2,remaining=4}})
act('connection');assert(label('4 秒 · 第 2/5 次') and label('取消重连'));dismiss()
act('toggle-auto-reconnect');assert(last('reconnect-disable'))
act('toggle-auto-reconnect');assert(last('reconnect-enable'))
act('disconnect');assert(last('disconnect'))
handlers['splay-event'](utils.format_json({schema=1,id=990,type='connection',connection='error'}))
state({connection='error',error='retry failure',reconnect={enabled=true,pending=true,attempt=2,remaining=3}})
act('message-history');local failures=0
local _,found_failures=console_text():gsub('retry failure','');failures=found_failures
assert(failures==1 and not label('连接: 错误'),'countdown refresh and generic error events must not duplicate failure messages')
dismiss()
-- Latency display/sharing defaults on; show valid fresh values only.
start();assert(count('latency')==0,'fresh disabled UI must not enable latency sharing')
act('toggle-enabled');assert(last('latency').enabled==true)
assert(last('catchup').enabled==true,'enabling splay applies the smooth catch-up default')
act('settings');assert(label('延迟显示与共享: 开启') and label('平滑追赶: 开启'));dismiss()
act('toggle-catchup');assert(last('catchup').enabled==false)
act('settings');assert(label('平滑追赶: 关闭'));dismiss()
act('toggle-catchup');assert(last('catchup').enabled==true)
start({smooth_catchup=false});act('toggle-enabled')
assert(last('catchup').enabled==false,'splay.conf smooth_catchup=no reaches the core on enable')
handlers['splay-command'](utils.format_json({action='catchup',enabled=true}))
act('settings');assert(label('平滑追赶: 开启'),'automation keeps the menu in step');dismiss()
start();act('toggle-enabled')
state({username='self',members={
    {username='self',room='active-room',ready=false},
    {username='peer',room='active-room'},
    {username='official',room='active-room'},
    {username='old',room='active-room'},
}})
act('members');assert(not label(' ms'),'no latency message yet, nothing to show');dismiss()
-- Latency arrives in its own message: it goes on to the overlay as received
-- and neither rebuilds the state nor reaches the playlist script.
local function sent(target,name)
    local n,payload=0,nil
    for _,item in ipairs(commands) do if item[2]==target and item[3]==name then n=n+1;payload=item[4] end end
    return n,payload
end
local overlay_states,playlist_states=sent('splay_overlay','splay-state'),sent('splay_playlist','splay-state')
local reports='{"schema":1,"enabled":true,"self":{"rtt_ms":12.4,"reported":true,"stale":false,"self_reported":false},"members":{'..
    '"peer":{"rtt_ms":84.6,"reported":true,"stale":false,"self_reported":true},'..
    '"old":{"rtt_ms":99,"reported":true,"stale":true,"self_reported":true}}}'
handlers['splay-latency'](reports)
local forwarded,payload=sent('splay_overlay','splay-latency')
assert(forwarded==1 and payload==reports,'overlay receives the latency message unchanged')
assert(sent('splay_overlay','splay-state')==overlay_states and sent('splay_playlist','splay-state')==playlist_states and
    sent('splay_playlist','splay-latency')==0,'a latency update must not resend the state')
act('members');assert(label('12 ms') and label('85 ms') and not label('99 ms'),'only valid fresh measurements appear')
for _,text in ipairs(selected.items) do
    assert(not ((text:find('official',1,true) or text:find('old',1,true)) and text:find(' ms',1,true)),'unreported and stale members show no value')
end
dismiss()
for _,bad in ipairs({'','{','[]','{"schema":2,"enabled":true,"members":{}}','{"schema":1,"enabled":true}'}) do handlers['splay-latency'](bad) end
assert(sent('splay_overlay','splay-latency')==1,'malformed latency messages are dropped')
act('members');assert(label('12 ms') and label('85 ms'),'a malformed message keeps the last valid values');dismiss()
handlers['splay-overlay-ready']()
assert(sent('splay_overlay','splay-latency')==2,'an overlay that starts late receives the current latency')
act('toggle-enabled');assert(last('latency').enabled==false)
act('toggle-enabled');assert(last('latency').enabled==true,'explicit UI re-enable reapplies the local setting')
act('toggle-latency');assert(last('latency').enabled==false)
act('members');assert(not label('RTT:'));dismiss()
for _,command in ipairs(core()) do
    if command.action=='latency' then
        assert(type(command.enabled)=='boolean' and command.host==nil and command.ip==nil and command.text==nil)
    end
end
start({history_enabled=false});credential_init(false);act('toggle-enabled')
act('username');local ordered=prompted;local before=count('history-save')
ordered.submit('after-close')
assert(prompted==ordered and count('history-save')==before and not ordered.closed_seen,'submit must queue work until closed')
ordered.closed()
act('connection');assert(label('after-close'));dismiss()
act('username');assert(prompted.default_text=='after-close','closed dispatches exactly the submitted field edit')
dismiss()
-- Media enrichment: lifecycle, metadata comparisons and local-only privacy.
local function display_state()
    for i=#commands,1,-1 do
        if commands[i][2]=='splay_overlay' and commands[i][3]=='splay-state' then return utils.parse_json(commands[i][4]) end
    end
end
start();act('toggle-enabled')
assert(#model().items==4 and model().items[1].value=='join-form' and model().items[2].value=='create-form' and model().items[4].title=='关闭 splay')
assert(display_state().local_media.title=='网络媒体','network filename alone is not a reliable title')
registered_events['start-file']()
prop('path','D:/PRIVATE_LOCAL_DIRECTORY/Film.mkv')
prop('filename','stale-index.m3u8');prop('media-title','影片名称: 导演剪辑版');prop('duration',500)
assert(not display_state().local_media.loaded and display_state().local_media.title=='' and display_state().local_media.duration==nil)
registered_events['file-loaded']()
assert(display_state().local_media.loaded and display_state().local_media.title=='影片名称: 导演剪辑版' and display_state().local_media.duration==500)
local media_members={
    {username='self',room='active-room',file={name='**Hidden filename**',duration=10}},
    {username='same',room='active-room',file={name='Film.mkv',duration=502.5}},
    {username='longer',room='active-room',file={name='Film.mkv',duration=502.5001}},
    {username='named',room='active-room',file={name='Other.mkv',duration=500}},
    {username='hidden',room='active-room',file={name='**Hidden filename**',duration=500}},
    {username='unknown',room='active-room',file={name='Film.mkv',duration=0}},
    {username='empty',room='active-room',file={}},
    {username='foreign',room='other-room',file={name='Film.mkv',duration=500}},
    {username='shorter',room='active-room',file={name='Film.mkv',duration=487.7}},
}
state({username='self',members=media_members})
local media=display_state().members
assert(media[1].media.check=='self' and media[1].media.title=='影片名称: 导演剪辑版' and media[1].media.duration==500)
assert(media[2].media.check=='duration_mismatch' and media[2].media.check_label=='时长不同')
assert(media[3].media.check=='duration_mismatch')
assert(math.abs(media[3].media.duration_delta-2.5001)<0.000001)
assert(media[3].media.check_detail:find('对方长 2.5001 秒',1,true) and not media[3].media.check_detail:find('阈值',1,true))
assert(media[4].media.check=='duration_match' and media[4].media.check_label=='时长相同')
assert(media[4].media.name_basis=='different' and media[4].media.check_detail:find('原始秒值相同',1,true))
assert(media[5].media.check=='duration_match' and media[5].media.check_detail:find('原始秒值相同',1,true))
assert(media[5].media.duration_delta==0 and media[5].media.name_basis=='unavailable')
assert(media[6].media.check=='unknown' and media[7].media.check=='unknown' and not media[7].media.loaded)
assert(media[8].media.check=='unknown','foreign rooms must not receive a local-media comparison')
assert(media[8].media.duration_delta==nil and media[9].media.duration_delta_label=='对方短 12.3 秒')
assert(media[2].media.name_basis=='same' and media[2].media.check_detail:find('本机文件名「Film.mkv」',1,true))
assert(media[2].media.check_detail:find('本机时长：8:20（500 秒）',1,true))
act('members');assert(label('8:20') and label('时长不同'));dismiss()
act('member-details:self');assert(label('影片名称: 导演剪辑版') and label('本机时长：8:20'));dismiss()
act('member-details:same');assert(label('2.5 秒') and label('本机文件名'));dismiss()
act('member-details:shorter');assert(label('对方短 12.3 秒'));dismiss()
act('member-details:absent');assert(label('已离开当前房间'));dismiss()
prop('seekable',false);assert(display_state().members[2].media.check=='unknown' and display_state().members[2].media.duration_delta==nil);prop('seekable',true)
for _,value in ipairs({0,-1,math.huge,0/0,'500'}) do
    prop('duration',value);assert(display_state().local_media.duration==nil and display_state().members[2].media.check=='unknown' and display_state().members[2].media.duration_delta==nil)
end
prop('duration',500)
registered_events['start-file']()
assert(display_state().local_media.title=='' and display_state().local_media.duration==nil)
prop('path','https://PRIVATE_REMOTE_HOST/manifest.m3u8?token=PRIVATE_TOKEN')
prop('filename','index.m3u8')
prop('media-title','https://PRIVATE_REMOTE_HOST/manifest.m3u8?token=PRIVATE_TOKEN')
registered_events['file-loaded']()
assert(display_state().local_media.title=='网络媒体')
for _,value in ipairs({'index.m3u8','token','D:\\PRIVATE_LOCAL_DIRECTORY\\Film.mkv','Film?token=PRIVATE_TOKEN','https%3A%2F%2FPRIVATE_REMOTE_HOST%2Ftoken'}) do
    prop('media-title',value);assert(display_state().local_media.title=='网络媒体')
end
local full_title='影片名称: '..string.rep('完整标题',90)
prop('media-title',full_title);assert(display_state().local_media.title==full_title,'UI state retains the full safe title for responsive overlay truncation')
prop('idle-active',true);assert(not display_state().local_media.loaded and display_state().local_media.duration==nil)
prop('idle-active',false);registered_events['end-file']()
prop('media-title','stale-title');assert(not display_state().local_media.loaded and display_state().local_media.title=='')
local after_media=#commands
prop('user-data/splay-overlay',{popup_open=true})
assert(#commands==after_media,'overlay observations must not republish state in a loop')
for _,command in ipairs(commands) do
    if command[3]=='splay-state' then
        assert(not command[4]:find('PRIVATE_',1,true),'display state must not expose raw paths or URL/authentication data')
    elseif command[2]=='splay_core' then
        assert(not command[4]:find('影片名称',1,true) and not command[4]:find('Film.mkv',1,true) and
            not command[4]:find('PRIVATE_',1,true) and not command[4]:find('metadata_match',1,true),
            'local title/duration comparisons must not create network commands')
    end
end
-- Auto-start is an explicit local-only policy. Countdown snapshots are state,
-- while a single started/cancelled event may enter history.
start();assert(count('autostart')==0 and count('autostart-cancel')==0)
act('toggle-enabled');act('toggle-autostart');assert(count('autostart')==0,'disconnected UI cannot enable auto-start')
state({autostart={enabled=false,delay=5,pending=false,remaining=0,reason='disabled',participants=2}})
act('autostart');assert(label('全员准备后自动开播: 关闭') and label('建议房内仅一人开启'));dismiss()
act('toggle-autostart');assert(last('autostart').enabled==true and last('autostart').delay==5)
state({autostart={enabled=true,delay=5,pending=true,remaining=5,reason='countdown',participants=2}})
local function home_item(value)
    for _,item in ipairs(model().items) do if item.value==value then return item end end
end
assert(home_item('autostart-cancel').subtitle=='5 秒后开播')
local autostart_history_title=history_label()
for remaining=4,1,-1 do
    state({autostart={enabled=true,delay=5,pending=true,remaining=remaining,reason='countdown',participants=2}})
    assert(home_item('autostart-cancel').subtitle==remaining..' 秒后开播')
    assert(history_label()==autostart_history_title,'countdown ticks must not enter history')
end
act('autostart-cancel');assert(count('autostart-cancel')==1)
state({autostart={enabled=true,delay=5,pending=false,remaining=0,reason='waiting-reset',participants=2}})
assert(not home_item('autostart-cancel'))
act('autostart');assert(label('重新开启自动开播') and label('等待重新准备或重新开启'));dismiss()
act('restart-autostart');assert(last('autostart').enabled==true and last('autostart').delay==5)
act('toggle-autostart');assert(last('autostart').enabled==false)
handlers['splay-event']('{"schema":1,"id":1601,"type":"autostart","action":"cancelled","reason":"waiting-ready"}')
handlers['splay-event']('{"schema":1,"id":1601,"type":"autostart","action":"cancelled","reason":"waiting-ready"}')
handlers['splay-event']('{"schema":1,"id":1602,"type":"autostart","action":"started"}')
act('message-history');assert(label('自动开播已取消：等待全员准备') and label('倒计时结束，已自动开播'));dismiss()
state({connection='disconnected',autostart={enabled=false,pending=false,reason='disconnected'}})
assert(not home_item('autostart-cancel'))
local autostart_commands=count('autostart');act('toggle-enabled');act('toggle-enabled')
assert(count('autostart')==autostart_commands,'re-enabling splay must not persist or restore auto-start')
for _,command in ipairs(core()) do
    if command.action=='history-save' then assert(command.settings.autostart==nil and command.settings.autostart_enabled==nil) end
end
-- Joining and ordinary creation share one draft form and always need an
-- explicit final click. Ordinary creation never invokes controlled-room auth.
start({room='old-room',history_enabled=false});credential_init(false);act('toggle-enabled')
assert(#model().items==4 and model().items[1].title=='加入房间' and model().items[2].title=='创建房间')
act('join-form');assert(selected.prompt:find('加入房间',1,true) and label('房间: old-room') and count('connect')==0);dismiss()
act('create-form');assert(prompted.prompt:find('新普通房间名称',1,true) and prompted.default_text=='' and count('connect')==0)
finish('fresh-room')
assert(selected.prompt:find('创建房间',1,true) and label('创建并进入') and label('房间: fresh-room') and count('connect')==0)
act('connect');assert(last('connect').room=='fresh-room' and count('create-room')==0 and count('secret-submit')==0)
act('create-form');dismiss()
local explicit_connects=count('connect')
act('connect');assert(count('connect')==explicit_connects and prompted.default_text=='','cancelled creation cannot reuse an old room silently')
finish('   ');act('connect');assert(count('connect')==explicit_connects)
dismiss();act('join-form');assert(label('加入') and not label('创建并进入'));dismiss()
state({host='active.example',port=8999,room='actual-room'})
act('room');finish('draft-room');dismiss()
assert(model().items[1].popup_title=='active.example:8999' and model().items[1].subtitle=='actual-room','connected home describes the active session instead of edited draft fields')
act('settings');assert(not label('房间成员:') and label('消息记录:') and label('全员准备后自动开播') and label('关闭 splay'));dismiss()
act('room-actions');assert(label('认证房间操作员') and label('创建受控房间') and not label('全员准备后自动开播'));dismiss()

-- Preferences are restored independently from connection fields. A late load
-- must not overwrite controls touched in this process, and writes contain only
-- the changed local preference rather than connection/password data.
local preferences=utils.parse_json(utils.format_json(history))
preferences.preferences={chat_mode='danmaku',pause_on_leave=false,pause_on_join=false}
start();act('toggle-enabled')
assert(display_state().settings.latency_enabled and display_state().settings.autostart_enabled and display_state().settings.auto_reconnect and
    display_state().settings.pause_on_leave and display_state().settings.pause_on_join,'fresh defaults enable all documented room policies')
history_reply(preferences)
assert(display_state().settings.chat_mode=='danmaku' and not display_state().settings.pause_on_join and not display_state().settings.pause_on_leave)
assert(last('room-policy').pause_on_join==false and last('room-policy').pause_on_leave==false)
act('toggle-chat-mode');assert(last('history-preferences').preferences.chat_mode=='room')
act('toggle-pause-on-join');assert(last('history-preferences').preferences.pause_on_join==true and last('room-policy').pause_on_join)
act('settings');assert(label('成员加入时暂停房间: 开启') and label('聊天显示模式: 聊天室') and not label('密码设置') and not label('清除密码'));dismiss()
start();act('toggle-enabled');act('toggle-chat-mode');act('toggle-pause-on-join')
assert(count('history-preferences')==0,'defer preference writes until the current file is loaded')
local late=utils.parse_json(utils.format_json(preferences));late.preferences.chat_mode='room';late.preferences.pause_on_join=true
history_reply(late)
assert(display_state().settings.chat_mode=='danmaku' and not display_state().settings.pause_on_join and not display_state().settings.pause_on_leave)
local preference_write=last('history-preferences')
assert(preference_write.preferences.chat_mode=='danmaku' and preference_write.preferences.pause_on_join==false and preference_write.preferences.pause_on_leave==nil)
start({history_enabled=false});act('toggle-enabled');act('toggle-chat-mode');act('toggle-pause-on-leave')
assert(count('history-preferences')==0 and last('room-policy').pause_on_leave==false)
start();local invalid=utils.parse_json(utils.format_json(history));invalid.preferences={chat_mode='invalid',pause_on_join='false',pause_on_leave=4}
history_reply(invalid);assert(display_state().settings.chat_mode=='room' and display_state().settings.pause_on_join and display_state().settings.pause_on_leave)

-- History is a transparent ASS layer plus a persistent real console input:
-- repeat sends keep input ownership, Esc restores the host keys, and a room
-- or connection identity transition permanently invalidates the old callback.
start({history_enabled=false});act('toggle-enabled');state({chat_max_length=20})
handlers['splay-event'](utils.format_json({schema=1,id=2001,type='chat',username='同伴',text='普通白字'}))
local function chat_event()
    for i=#commands,1,-1 do
        if commands[i][2]=='splay_overlay' and commands[i][3]=='splay-event' then
            local event=utils.parse_json(commands[i][4]);if event.type=='chat' then return event end
        end
    end
end
local nick_color=chat_event().chat_color
handlers['splay-event'](utils.format_json({schema=1,id=2002,type='chat',username='another',text='other'}))
handlers['splay-event'](utils.format_json({schema=1,id=2003,type='chat',username='同伴',text='再次白字'}))
assert(chat_event().chat_color==nick_color and nick_color~='FFFFFF','full nickname has a stable distinct colour')
act('message-history');local persistent=prompted
assert(persistent.keep_open and properties['user-data/splay-console-open'] and not bindings['splay-chat-enter'])
assert(console_layer.data:find('\\1c&H'..nick_color..'&',1,true) and console_layer.data:find('\\1c&HFFFFFF&',1,true))
assert(not console_layer.data:find('\\p1',1,true),'history renders transparent text without an opaque background drawing')
persistent.submit('第一条');persistent.submit('第二条')
assert(count('chat')==2 and last('chat').text=='第二条' and active_request==persistent and properties['user-data/splay-console-open'])
persistent.submit('');persistent.submit('bad\ntext');persistent.submit(string.rep('字',21))
assert(count('chat')==2,'persistent console applies nonempty/control/UTF-8 character limits')
for i=1,40 do handlers['splay-event'](utils.format_json({schema=1,id=2100+i,type='chat',username='同伴',text='scroll-'..i})) end
bindings['splay-console-page-up'].fn()
assert(label('正在浏览较早消息'))
handlers['splay-event'](utils.format_json({schema=1,id=2200,type='chat',username='同伴',text='new-message'}))
assert(label('1 条新消息'))
bindings['splay-console-page-down'].fn();bindings['splay-console-page-down'].fn();bindings['splay-console-page-down'].fn()
assert(label('new-message'))
bindings['splay-console-escape'].fn()
assert(not properties['user-data/splay-console-open'] and not active_request and bindings['splay-chat-enter'] and console_layer.data=='')
persistent.submit('Esc后的旧稿');assert(count('chat')==2)
act('message-history');persistent=prompted
state({room='changed',chat_max_length=20});persistent.submit('旧房间稿')
assert(count('chat')==2 and not properties['user-data/splay-console-open'])
state({warning='Buffering or seeking; synchronization is suspended'})
act('message-history');assert(not label('Buffering') and not label('缓冲'));dismiss()

-- The saved-combination chooser has a real back row. Join is explicit, editing
-- merely fills the draft, and deletion tracks settings identity across reorder.
start();credential_init(false);history_reply(history);credential_reply(last('credential-status'),false);act('toggle-enabled')
act('settings');dismiss();act('profiles');finish(1,'select');assert(selected.prompt:find('设置',1,true));dismiss()
act('profiles');finish(2,'select');assert(label('‹ 返回连接组合') and label('加入') and label('修改连接信息'))
finish(1,'select');assert(label('历史房间'));finish(2,'select');finish(3,'select')
assert(count('connect')==0 and label('历史房间'));dismiss();credential_reply(last('credential-status'),false)
act('profiles');finish(2,'select');finish(2,'select');credential_reply(last('credential-status'),false)
assert(count('connect')==1 and last('connect').room=='历史房间')

-- Fixed local offsets require explicit decimal input. Duration differences are
-- editable candidates, never summed with the current offset or sent on select.
local peers={{username='self',room='active-room',file={name='self.mkv',duration=500}},
    {username='peer',room='active-room',file={name='peer.mkv',duration=487.7}}}
local function offset_fixture()
    start({history_enabled=false});act('toggle-enabled')
    prop('path','D:/fixture/self.mkv');prop('duration',500);prop('seekable',true);registered_events['file-loaded']()
    state({username='self',time_offset=5,members=peers})
end
offset_fixture();act('time-offset');assert(label('+5 秒') and label('更换媒体后清零'));dismiss()
act('offset-plus');assert(last('set-offset').seconds==6)
state({username='self',time_offset=6,members=peers});act('offset-minus');assert(last('set-offset').seconds==5)
act('offset-reset');assert(last('set-offset').seconds==0)
act('offset-input');finish(' -12.25 ');assert(last('set-offset').seconds==-12.25);dismiss()
local offset_count=count('set-offset')
for _,invalid_seconds in ipairs({'nan','1e3','86401','-86400.1','0x10','--1',''}) do
    act('offset-input');finish(invalid_seconds);dismiss();assert(count('set-offset')==offset_count)
end
act('offset-duration-list');assert(label('peer · +12.3 秒') and not label('self ·'));dismiss()
act('offset-duration:peer');assert(prompted.default_text=='+12.3' and count('set-offset')==offset_count)
finish('+11.75');assert(last('set-offset').seconds==11.75,'candidate is editable and replaces the current offset');dismiss()
for _,transition in ipairs({'member-file','member-left','member-unseekable','own-duration','own-path','media-reload','room','disconnect-reconnect','temporarily-changed'}) do
    offset_fixture();act('offset-duration:peer');local candidate=prompted;local before_offset=count('set-offset')
    local changed=utils.parse_json(utils.format_json(peers))
    if transition=='member-file' then changed[2].file.name='replacement.mkv';state({username='self',time_offset=5,members=changed})
    elseif transition=='member-left' then state({username='self',time_offset=5,members={peers[1]}})
    elseif transition=='member-unseekable' then changed[2].seekable=false;state({username='self',time_offset=5,members=changed})
    elseif transition=='own-duration' then prop('duration',501)
    elseif transition=='own-path' then prop('path','D:/fixture/replacement.mkv')
    elseif transition=='media-reload' then registered_events['start-file']();registered_events['file-loaded']()
    elseif transition=='room' then state({room='new-room',username='self',time_offset=5,members=peers})
    elseif transition=='disconnect-reconnect' then state({connection='disconnected',username='self',time_offset=5,members=peers});state({username='self',time_offset=5,members=peers})
    else prop('duration',501);prop('duration',500) end
    if candidate.closed then candidate.closed() end;candidate.submit('+12.3')
    assert(count('set-offset')==before_offset,'stale duration candidate must fail after '..transition)
end
offset_fixture();act('offset-duration:peer');dismiss();assert(count('set-offset')==0,'cancel preserves offset')
state({username='self',members=peers});act('offset-input');assert(count('set-offset')==0,'old core without offset capability cannot apply')
-- Any unequal raw duration is a mismatch, including a fraction below one ms.
-- Supply the tiny difference as literal JSON so serializer rounding cannot hide it.
offset_fixture();local exact=utils.parse_json(utils.format_json(peers))
handlers['splay-state']('{"schema":1,"connection":"connected","host":"history.example","port":9001,"room":"active-room","username":"self","time_offset":5,"members":[{"username":"peer","room":"active-room","file":{"name":"peer.mkv","duration":500.0000001}}]}')
assert(display_state().members[1].media.check=='duration_mismatch')
exact[2].file.duration=500;state({username='self',time_offset=5,members=exact});assert(display_state().members[2].media.check=='duration_match')
for _,command in ipairs(core()) do
    if command.action=='set-offset' then assert(command.settings==nil and command.path==nil and command.filename==nil) end
end

-- Interface language: representative English text, a runtime switch without
-- reloading, auto following the adapter's system language, persistence only
-- with an adapter that knows the preference, and the resolved value for the
-- overlay and playlist scripts.
local function sent_state(target)
    for i=#commands,1,-1 do
        if commands[i][2]==target and commands[i][3]=='splay-state' then return utils.parse_json(commands[i][4]) end
    end
end
local function settings_row(fragment)
    for index,text in ipairs(selected.items) do if text:find(fragment,1,true) then return index end end
end
start({language='en',history_enabled=false});credential_init(false)
assert(model().items[1].title=='Enable splay' and model().title=='splay | Off')
act('toggle-enabled')
assert(model().items[1].title=='Join room' and model().items[2].title=='Create room' and
    model().items[3].title=='Settings' and model().items[4].title=='Disable splay')
assert(display_state().settings.language=='en' and sent_state('splay_playlist').settings.language=='en','resolved language reaches the other scripts')
act('settings');assert(selected.prompt=='Settings | Disconnected')
assert(label('语言 / Language: English') and label('Message history: 0') and label('Show status: On') and label('Chat mode: Room chat'))
assert(label('All-ready autostart: On (5 s)') and label('Auto reconnect: On') and label('Pause room when a member joins: On'))
assert(label('Connection history: 0') and label('Disable splay') and label('Smooth catch-up: On'));dismiss()
act('join-form');assert(selected.prompt=='Join room | Disconnected')
assert(label('‹ Back') and label('Server: syncplay.pl : 8999') and label('Room: Enter or choose one') and
    label('Server password: None') and label('Nickname: splayuser') and label('Connection profiles: 0') and label('Join'));dismiss()
act('connect');assert(notices[#notices]=='Enter or choose a room, then choose "Join"' and prompted.prompt=='Room: ');dismiss()
act('create-form');assert(prompted.prompt=='New room name: ');finish('english-room')
assert(selected.prompt=='Create room | Disconnected' and label('Create and join') and label('Room: english-room'));dismiss()
state({username='self',time_offset=5,members={{username='self',room='active-room',ready=true,is_controller=true},
    {username='peer',room='active-room',ready=false}}})
assert(model().items[2].title=='Not ready' and model().items[3].title=='Shared playlist' and model().items[4].title=='Room functions' and
    model().items[6].title=='Disconnect')
act('room-actions');assert(selected.prompt=='Room functions | Connected')
assert(label('Room members: 2') and label('Local time offset: +5 s') and label('Authenticate as operator') and
    label('Create controlled room…') and label('Controlled rooms need a separate operator password'));dismiss()
act('time-offset');assert(label('Enter offset in seconds…') and label('+1 s (this player 1 s ahead)') and label('Reset to zero') and
    label('Local time = room time + offset.'));dismiss()
act('members');assert(label('self | active-room | Ready | Operator') and label('peer | active-room | Not ready'));dismiss()
act('authenticate');assert(prompted.prompt=='Operator password, e.g. AB-123-456 (visible while typing): ')
assert(notices[#notices]=='The password is shown in clear text in the mpv input box; Enter submits, Esc cancels')
local english_secret=secret_submit('TYPED_PW_english')
secret_reply(english_secret,nil,false,false,'fixture english failure')
assert(notices[#notices]=='Password entry: fixture english failure')
state({username='self',time_offset=5,warning='Waiting for media; synchronization is suspended',members={}})
handlers['splay-open']('uosc')
local function uosc_menu(name)
    for i=#commands,1,-1 do if commands[i][2]=='uosc' and commands[i][3]==name then return utils.parse_json(commands[i][4]) end end
end
assert(uosc_menu('open-menu').footnote=='Waiting for media; synchronization is suspended','English shows the core warning as it is')
for index,event in ipairs({{type='connection',connection='connecting'},{type='ready',username='joiner',ready=true},
    {type='user',action='joined',username='joiner',room='active-room'},{type='playback',username='joiner',paused=true,position=65},
    {type='autostart',action='cancelled',reason='waiting-ready'}}) do
    event.schema=1;event.id=3000+index;handlers['splay-event'](utils.format_json(event))
end
state({connection='error',error='Example server error',members={}})
act('message-history')
assert(label('Message history · ') and label('Connection: Connecting') and label('joiner is ready') and label('joiner joined: active-room'))
assert(label('joiner paused · 65 s') and label('Autostart cancelled: Waiting for everyone to be ready'))
assert(label('Waiting for media; synchronization is suspended') and label('Connection failed: Example server error'))
assert(not label('等待媒体') and not label('连接失败'));dismiss()
-- Runtime switch: auto (Chinese system) -> 简体中文 -> English -> auto, without
-- reloading; an open uosc menu is replaced and the native menu reopens.
start({language='auto'});credential_init(false);history_reply(history);act('toggle-enabled')
state({system_language='zh-CN'})
assert(model().items[5].title=='设置' and display_state().settings.language=='zh-CN')
act('settings');assert(label('语言 / Language: 自动（简体中文）'))
finish(settings_row('语言 / Language'),'select')
assert(last('history-preferences').preferences.language=='zh-CN')
assert(selected.prompt=='设置 | 已连接' and label('语言 / Language: 简体中文'),'native settings reopen after a language step')
finish(settings_row('语言 / Language'),'select')
assert(last('history-preferences').preferences.language=='en' and display_state().settings.language=='en')
assert(selected.prompt=='Settings | Connected' and label('语言 / Language: English') and label('Show status: On'))
assert(model().items[5].title=='Settings' and model().items[2].title=='Not ready')
dismiss();handlers['splay-open']('uosc');act('toggle-language')
assert(uosc_menu('update-menu').title=='splay | 已连接' and display_state().settings.language=='zh-CN','open uosc menu follows the switch')
assert(last('history-preferences').preferences.language=='auto' and model().items[5].title=='设置')
-- auto follows the adapter's system language and keeps it while disabled; an
-- older adapter without the field keeps Chinese and gets no saved preference.
start({language='auto',history_enabled=false});act('toggle-enabled')
assert(model().items[1].title=='加入房间','auto without an adapter report stays Chinese')
state({connection='disconnected',system_language='en'})
assert(model().items[1].title=='Join room' and display_state().settings.language=='en')
state({connection='disconnected'});assert(model().items[1].title=='Join room','a state without the field keeps the reported language')
act('toggle-enabled');assert(model().items[1].title=='Enable splay')
start({language='auto'});history_reply(history);act('toggle-enabled');state()
assert(model().items[5].title=='设置')
act('toggle-language');act('toggle-language')
assert(model().items[5].title=='Settings' and count('history-preferences')==0,'an older adapter rejects the language preference')
start({language='auto'});act('toggle-enabled');state({system_language='zh-CN'})
local saved_language=utils.parse_json(utils.format_json(history));saved_language.preferences={language='en'}
history_reply(saved_language)
assert(model().items[5].title=='Settings' and display_state().settings.language=='en','saved language preference is restored')

print('UI_FORMS_PASSED default off, Settings and room actions, endpoint editing, encrypted credential commands, password prompts with submit/cancel/stale reply isolation, playlist handoff, 300-event transparent persistent history, stable nickname colours and white body, continuous chat and Esc/stale-room guards, conditional shortcuts, modal generations, saved-profile navigation, preference restore/touch/save, strict durations, editable local offsets and stale candidates, media privacy and lifecycle, overlay replay, English labels, runtime language switch, auto system language and fallback')
real_mp.commandv('quit')
