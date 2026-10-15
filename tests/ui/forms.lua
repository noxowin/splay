-- Production main UI with an in-process mpv double; no network or config writes.
local real_mp=require 'mp'
local utils=require 'mp.utils'
local options=require 'mp.options'
local opt={source=''};options.read_options(opt,'forms')
local handlers,commands,selected,prompted,bindings,notices,properties,observers,active_request
local terminated
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
fake.register_event=function() end
fake.add_timeout=function(_,fn) fn() end
fake.add_key_binding=function(key,name,fn,flags) bindings[name]={key=key,fn=fn,flags=flags};handlers[name]=fn end
fake.add_forced_key_binding=function(key,name,fn) bindings[name]={key=key,fn=fn,forced=true} end
fake.remove_key_binding=function(name) bindings[name]=nil end
fake.osd_message=function(text) notices[#notices+1]=text end
package.loaded.mp=fake
package.loaded['mp.options']={read_options=function(cfg) for key,value in pairs(overrides) do cfg[key]=value end end}
package.loaded['mp.input']={select=function(value) selected=value;active_request=value end,get=function(value) prompted=value;active_request=value end,
    terminate=function()
        terminated=terminated+1;local request=active_request;active_request=nil
        if request and request.closed then request.closed() end
    end}
local function start(config)
    handlers,commands,selected,prompted,bindings,notices,observers={},{},nil,nil,{},{},{}
    terminated=0;active_request=nil
    properties={['options/load-console']=true,path='https://private.example/SECRET_URL',filename='本机影片.mp4',['idle-active']=false}
    overrides=config or {}
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
    local value={schema=1,connection='connected',members={},room='active-room',chat_supported=true,chat_max_length=3,ready=false}
    for key,item in pairs(extra or {}) do value[key]=item end
    handlers['splay-state'](utils.format_json(value))
end
local function model()
    for i=#commands,1,-1 do if commands[i][3]=='splay-menu-model' then return utils.parse_json(commands[i][4]) end end
end
local function label(fragment)
    for _,text in ipairs(selected.items) do if text:find(fragment,1,true) then return true end end
    return false
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
act('connection');assert(#selected.items<=7 and label('请先输入或选择'));dismiss()
act('room');finish('');handlers['splay-history'](utils.format_json(history))
credential_reply(last('credential-status'),false)
assert(last('history-save').settings.room=='' and not last('history-save').remember_profile,'blank room draft survives restore')
act('connect');assert(count('connect')==0)
act('profiles');finish(1,'select');credential_reply(last('credential-status'),false);act('connect')
assert(last('connect').room=='历史房间' and last('connect').password=='')
assert(last('history-save').settings.password==nil)
state();assert(bindings['splay-chat-enter'] and bindings['splay-chat-enter'].forced,'eligible Enter overrides user fullscreen binding only while available')
assert(#model().items==6 and model().items[4].value=='playlist' and model().items[5].value=='message-history')
assert(model().items[2].title:find('history.example:9001',1,true) and model().items[2].title:find('历史房间',1,true))
for _,item in ipairs(model().items) do assert(item.value~='chat' and item.value~='members') end
act('connection');assert(#selected.items<=7 and label('history.example : 9001'));dismiss()
act('endpoint');assert(label('服务器: history.example') and label('端口: 9001'));dismiss()
act('room-actions');assert(label('房间成员: 0') and #selected.items<=7);dismiss()
for _,name in ipairs({'user-data/mpv/console/open','user-data/mpv/context-menu/open'}) do
    prop(name,true);assert(not bindings['splay-chat-enter']);prop(name,false);assert(bindings['splay-chat-enter'])
end
prop('user-data/uosc/menu/type','other');assert(not bindings['splay-chat-enter']);prop('user-data/uosc/menu/type',nil)
prop('user-data/splay-overlay',{popup_open=true});assert(not bindings['splay-chat-enter']);prop('user-data/splay-overlay',{popup_open=false})
prop('path',nil);assert(not bindings['splay-chat-enter']);prop('path','fixture.mp4')
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
act('password');finish('SECRET');dismiss()
assert(last('credential-save').password=='SECRET' and last('credential-save').host=='history.example')
credential_reply(last('credential-save'),true)
act('password-settings');assert(label('已加密保存'));dismiss()
act('connect');assert(last('connect').password=='' and last('connect').use_saved_password==true)
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
act('password-settings');assert(label('密码: 空'));dismiss()
act('toggle-remember-password');act('password');finish('MEMORY_ONLY');dismiss()
act('connect');assert(last('connect').password=='MEMORY_ONLY' and last('connect').remember_password==false)
act('connect');assert(last('connect').password=='MEMORY_ONLY','opt-out retains typed password in memory')
act('toggle-remember-password');assert(last('credential-save').password=='MEMORY_ONLY')
credential_reply(last('credential-save'),true)
act('profiles');finish(1,'select');credential_reply(last('credential-status'),true);act('connect');assert(last('connect').password=='')
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
act('message-history');assert(#selected.items==300 and selected.items[1]:find('message6',1,true));dismiss()
handlers['splay-event'](utils.format_json({schema=1,id=305,type='chat',username='user',text='duplicate'}))
act('message-history');assert(#selected.items==300 and not label('duplicate'));dismiss()
state({room='different-room'});act('message-history');assert(#selected.items==300);dismiss()
handlers['splay-event'](utils.format_json({schema=1,type='chat',username='user',text='current-room'}))
state({connection='disconnected',room='different-room'});act('message-history');assert(label('current-room'));dismiss()
local events={
    {type='connection',connection='connecting'}, {type='room',room='another-room'},
    {type='user',action='joined',username='joiner',room='different-room'},
    {type='ready',username='joiner',ready=true},
    {type='playlist',action='files',user='joiner',files={'one','two'}},
    {type='playback',username='joiner',paused=false,position=65,seek=true},
}
for index,event in ipairs(events) do event.schema=1;event.id=400+index;handlers['splay-event'](utils.format_json(event)) end
handlers['splay-notice'](utils.format_json({text='列表操作已发送',category='playlist'}))
state({warning='Waiting for media; synchronization is suspended',error='Example server error'})
state({warning='Waiting for media; synchronization is suspended',error='Example server error'})
act('message-history');assert(label('连接: 连接中') and label('切换房间: another-room') and label('joiner 加入房间'))
assert(label('joiner 已准备') and label('更新共享播放列表: 2 项') and label('跳转 · 65 秒') and label('列表操作已发送'))
local warning_count=0;for _,text in ipairs(selected.items) do if text:find('等待媒体',1,true) then warning_count=warning_count+1 end end
assert(warning_count==1,'state warning transitions append once');dismiss()
act('playlist');local playlist_open=false
for _,command in ipairs(commands) do if command[2]=='splay_playlist' and command[3]=='splay-playlist-open' then playlist_open=true end end
assert(playlist_open)
local large_files={};for i=1,300 do large_files[i]=string.rep('episode-',12)..i..'.mkv' end
handlers['splay-command'](utils.format_json({action='playlist',files=large_files}))
assert(#last('playlist').files==300,'full shared playlist commands may exceed the old 16 KiB UI cap')
act('toggle-status');act('toggle-buttons')
local overlay_commands={}
for _,item in ipairs(commands) do if item[2]=='splay_overlay' then overlay_commands[item[3]]=true end end
assert(overlay_commands['overlay-toggle-status'] and overlay_commands['overlay-toggle-buttons'])
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
commands={};handlers['splay-overlay-ready']();assert(commands[1][3]=='splay-state' and commands[2][2]=='splay_playlist' and commands[3][3]=='splay-menu-model')
assert(utils.parse_json(commands[2][4]).local_file=='本机影片.mp4')
commands={};handlers['splay-playlist-ready']();assert(commands[2][2]=='splay_playlist')
-- Automatic migration blanks only the legacy placeholder; explicit profile selection retains it.
start();local legacy=utils.parse_json(utils.format_json(history));legacy.last.room='DeFaUlT';legacy.profiles[1].room='Default'
handlers['splay-history'](utils.format_json(legacy));act('toggle-enabled');act('connect');assert(count('connect')==0)
credential_init(false)
act('profiles');finish(1,'select');credential_reply(last('credential-status'),false);act('connect');assert(last('connect').room=='Default')
-- A late history reply preserves edited fields and restores the remaining draft fields.
start();act('toggle-enabled');act('host');finish('typed-first.example');dismiss()
handlers['splay-history'](utils.format_json(history))
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
act('password');finish('RACE_SECRET');dismiss();local saving=last('credential-save')
pending_connects=count('connect');act('connect');assert(count('connect')==pending_connects)
credential_reply(first_status,false);assert(count('connect')==pending_connects,'old same-endpoint status cannot overwrite pending save')
credential_reply(saving,true);assert(count('connect')==pending_connects+1 and last('connect').use_saved_password==true and last('connect').password=='')
act('clear-password');local deleting=last('credential-delete');pending_connects=count('connect');act('connect')
credential_reply(saving,true);assert(count('connect')==pending_connects,'old save cannot resurrect a deleted credential')
credential_reply(deleting,false);assert(last('connect').password=='' and last('connect').use_saved_password==false)
act('password');finish('FAILED_SAVE');dismiss();pending_connects=count('connect');act('connect')
credential_reply(last('credential-save'),false,'fixture save failure');assert(count('connect')==pending_connects,'save failure must never fall back to an empty-password connection')
assert(notices[#notices]:find('fixture save failure',1,true))
act('toggle-remember-password');act('connect');assert(last('connect').remember_password==false and last('connect').password=='FAILED_SAVE')
start({host='race.example',port=8999,username='race',room='room',tls='off',history_enabled=false})
credential_init(true);act('toggle-enabled');act('toggle-remember-password');act('password-settings')
assert(label('当前不使用'));dismiss();act('connect');assert(last('connect').use_saved_password==false and last('connect').password=='')
start({host='race.example',port=8999,username='race',room='room',tls='off',history_enabled=false})
credential_init(false);act('toggle-enabled');state()
act('username');local replaced_prompt=prompted;act('room');local current_prompt=prompted
assert(current_prompt~=replaced_prompt and not bindings['splay-chat-enter'])
replaced_prompt.closed();assert(not bindings['splay-chat-enter'],'a stale close must not release the current input modal')
act('toggle-enabled');assert(terminated==1 and not bindings['splay-message-history'],'disable must close the current input and restore the host history key')
start({host='rooms.example',port=8999,username='race',room='local-room',tls='off',history_enabled=false})
credential_init(false);act('toggle-enabled')
state({room='local-room',members={{username='inside',room='local-room',ready=true},
    {username='outsider',room='foreign-room',ready=false},{username='unknown',room='local-room'}}})
act('room-actions');assert(label('房间成员: 2'));dismiss()
act('members');assert(label('inside') and label('unknown') and label('准备状态未知') and not label('outsider'));dismiss()
local history_title=model().items[5].title
for index,event in ipairs({
    {action='joined',username='outsider',room='foreign-room'},
    {action='file',username='outsider',room='foreign-room',file={name='unrelated.mkv'}},
    {action='room',username='outsider',room='foreign-room',previous_room='another-foreign-room'},
}) do event.schema=1;event.type='user';event.id=800+index;handlers['splay-event'](utils.format_json(event)) end
assert(model().items[5].title==history_title,'unrelated room events must not enter message history')
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
print('UI_FORMS_PASSED default off, compact pages, endpoint editing, encrypted credential commands and stale reply isolation, playlist state handoff, bounded all-event history and deduplication, conditional Enter/history shortcuts, modal generations, cancellation, overlay replay')
real_mp.commandv('quit')
