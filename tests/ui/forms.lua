-- Production main UI with an in-process mpv double; no network or config writes.
local real_mp=require 'mp'
local utils=require 'mp.utils'
local options=require 'mp.options'
local opt={source=''};options.read_options(opt,'forms')
local handlers,commands,selected,prompted,bindings,notices,properties,observers
local overrides={}
local fixture={host='history.example',port=9001,username='历史昵称',room='历史房间',tls='require'}
local history={schema=1,last=fixture,profiles={fixture},values={host={'history.example'},port={9001},username={'历史昵称'},room={'历史房间'},tls={'require'}}}
local fake={}
fake.commandv=function(...) commands[#commands+1]={...} end
fake.command_native=function(value) assert(value[1]=='expand-path');return 'isolated/splay-history.json' end
fake.get_property_native=function(name) return properties[name] end
fake.set_property_native=function(name,value) properties[name]=value end
fake.observe_property=function(name,_,fn) observers[name]=fn;fn(name,properties[name]) end
fake.register_script_message=function(name,fn) handlers[name]=fn end
fake.register_event=function() end
fake.add_timeout=function(_,fn) fn() end
fake.add_key_binding=function(key,name,fn,flags) bindings[name]={key=key,fn=fn,flags=flags} end
fake.add_forced_key_binding=function(key,name,fn) bindings[name]={key=key,fn=fn,forced=true} end
fake.remove_key_binding=function(name) bindings[name]=nil end
fake.osd_message=function(text) notices[#notices+1]=text end
package.loaded.mp=fake
package.loaded['mp.options']={read_options=function(cfg) for key,value in pairs(overrides) do cfg[key]=value end end}
package.loaded['mp.input']={select=function(value) selected=value end,get=function(value) prompted=value end,
    terminate=function() if prompted and prompted.closed then prompted.closed() end end}
local function start(config)
    handlers,commands,selected,prompted,bindings,notices,observers={},{},nil,nil,{},{},{}
    properties={['options/load-console']=true,path='fixture.mp4',['idle-active']=false}
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
local function act(action) handlers['splay-action'](action) end
local function finish(value,kind)
    local request=kind=='select' and selected or prompted
    if request.closed then request.closed() end
    request.submit(value)
end
local function dismiss()
    local request=prompted or selected
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
assert(last('history-load').path=='isolated/splay-history.json' and count('connect')==0 and count('status')==0)
assert(properties['user-data/splay'].enabled==false and not bindings['splay-chat-enter'])
assert(#model().items<=2 and model().items[1].value=='toggle-enabled')
handlers['splay-command'](utils.format_json({action='connect',room='  '}))
assert(count('connect')==0 and properties['user-data/splay'].enabled==false,'empty external connect must not enable')
act('toggle-enabled');assert(properties['user-data/splay'].enabled and count('connect')==0)
act('connect');assert(count('connect')==0,'first-run room must be blank')
act('connection');assert(#selected.items<=7 and label('请先输入或选择'));dismiss()
act('room');finish('');handlers['splay-history'](utils.format_json(history))
assert(last('history-save').settings.room=='' and not last('history-save').remember_profile,'blank room draft survives restore')
act('connect');assert(count('connect')==0)
act('profiles');finish(1,'select');act('connect')
assert(last('connect').room=='历史房间' and last('connect').password=='')
assert(last('history-save').settings.password==nil)
state();assert(bindings['splay-chat-enter'] and bindings['splay-chat-enter'].forced,'eligible Enter overrides user fullscreen binding only while available')
assert(#model().items==6 and model().items[4].value=='chat','compact connected home retains mouse chat')
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
act('profiles');finish(1,'select');act('connect');assert(last('connect').password=='')
act('room');finish(1,'select');finish('new-room');dismiss();assert(count('room')==0)
act('join-room');assert(last('room').room=='new-room')
handlers['splay-command'](utils.format_json({action='connect',host='external.example',port=8999,username='external',room='external-room',tls='off',password='EXTERNAL_SECRET',custom='preserved'}))
assert(last('connect').custom=='preserved' and last('connect').password=='EXTERNAL_SECRET')
assert(last('history-save').settings.host=='external.example' and last('history-save').settings.password==nil)
handlers['splay-event']('{"schema":1,"type":"chat","username":"user","text":"before\\u0000after"}')
act('chat-history');assert(selected.items[1]:find('before␀after',1,true));dismiss()
handlers['splay-event']('{"schema":1,"type":"chat","username":"user","text":"literal\\\\u0000after"}')
act('chat-history');assert(selected.items[2]:find('u0000after',1,true),'escaped backslashes remain literal');dismiss()
for index=1,105 do handlers['splay-event'](utils.format_json({schema=1,type='chat',username='user',text='message'..index})) end
act('chat-history');assert(#selected.items==100 and selected.items[1]:find('message6',1,true));dismiss()
state({room='different-room'});act('room-actions');assert(label('本连接聊天记录: 0') and #selected.items<=7);dismiss()
handlers['splay-event'](utils.format_json({schema=1,type='chat',username='user',text='current-room'}))
state({connection='disconnected',room='different-room'});act('room-actions');assert(label('本连接聊天记录: 0'));dismiss()
act('toggle-status');act('toggle-buttons')
local overlay_commands={}
for _,item in ipairs(commands) do if item[2]=='splay_overlay' then overlay_commands[item[3]]=true end end
assert(overlay_commands['overlay-toggle-status'] and overlay_commands['overlay-toggle-buttons'])
act('toggle-enabled');assert(not bindings['splay-chat-enter'] and count('disconnect')==1 and not model().enabled)
handlers['splay-event'](utils.format_json({schema=1,type='chat',username='user',text='ignored'}))
assert(properties['user-data/splay'].enabled==false)
for _,item in ipairs(commands) do
    assert(item[1]~='set' and item[1]~='seek' and item[1]~='loadfile','UI toggles must preserve playback')
    if item[3]=='splay-state' then assert(type(utils.parse_json(item[4]).enabled)=='boolean') end
end
commands={};handlers['splay-overlay-ready']();assert(commands[1][3]=='splay-state' and commands[2][3]=='splay-menu-model')
-- Automatic migration blanks only the legacy placeholder; explicit profile selection retains it.
start();local legacy=utils.parse_json(utils.format_json(history));legacy.last.room='DeFaUlT';legacy.profiles[1].room='Default'
handlers['splay-history'](utils.format_json(legacy));act('toggle-enabled');act('connect');assert(count('connect')==0)
act('profiles');finish(1,'select');act('connect');assert(last('connect').room=='Default')
-- A late history reply preserves edited fields and restores the remaining draft fields.
start();act('toggle-enabled');act('host');finish('typed-first.example');dismiss()
handlers['splay-history'](utils.format_json(history))
assert(last('history-save').settings.host=='typed-first.example' and last('history-save').settings.room=='历史房间')
start({history_enabled=false});assert(count('history-load')==0 and count('connect')==0)
act('toggle-enabled');act('host');finish('fresh.example');assert(count('history-save')==0)
print('UI_FORMS_PASSED default off, compact pages, blank drafts, history migration, explicit connect, conditional Enter, modal suppression, cancellation, password isolation, overlay replay')
real_mp.commandv('quit')
