-- Exercise the production UI with an in-process mpv API double, without a socket.
local real_mp=require 'mp'
local utils=require 'mp.utils'
local options=require 'mp.options'
local opt={source=''};options.read_options(opt,'forms')
local handlers,commands,selected,prompted,bindings,notices={},{},nil,nil,{},{}
local fixture={host='history.example',port=9001,username='历史昵称',room='历史房间',tls='require'}
local history={schema=1,last=fixture,profiles={fixture},values={host={'history.example'},port={9001},username={'历史昵称'},room={'历史房间'},tls={'require'}}}
local overrides={host='localhost',username='old-user'}
local fake={}
fake.commandv=function(...) commands[#commands+1]={...} end
fake.command_native=function(value) assert(value[1]=='expand-path');return 'isolated/splay-history.json' end
fake.get_property_native=function(name) if name=='options/load-console' then return true end;return 'splay' end
fake.register_script_message=function(name,fn) handlers[name]=fn end
fake.register_event=function() end
fake.add_timeout=function(_,fn) fn() end
fake.add_key_binding=function(key,name,fn,flags) bindings[name]={key=key,flags=flags} end
fake.osd_message=function(text) notices[#notices+1]=text end
package.loaded.mp=fake
package.loaded['mp.options']={read_options=function(cfg) for key,value in pairs(overrides) do cfg[key]=value end end}
package.loaded['mp.input']={select=function(value) selected=value end,get=function(value) prompted=value end}
assert(loadfile(opt.source))()
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
local function act(action) handlers['splay-menu-event'](utils.format_json({type='activate',value=action})) end
local function label(fragment)
    for _,text in ipairs(selected.items) do if text:find(fragment,1,true) then return true end end
    return false
end
assert(bindings['splay-panel'].key=='Shift+s' and bindings['splay-panel'].flags==nil)
assert(last('history-load').path=='isolated/splay-history.json' and count('connect')==0)
handlers['splay-history'](utils.format_json(history))
handlers['splay-open']('native')
assert(label('history.example') and label('历史昵称'),'saved history must override first-run config values')
handlers['splay-state'](utils.format_json({schema=1,connection='connected',members={},room='active-room',chat_supported=true,chat_max_length=3,ready=false}))
act('password');prompted.submit('SECRET')
act('profiles');selected.submit(1)
assert(count('connect')==0 and count('room')==0,'profile selection must only fill form')
act('connect')
assert(last('connect').password=='' and last('connect').host=='history.example','profile selection clears password')
assert(last('history-save').settings.password==nil)
act('room');selected.submit(1);prompted.submit('new-room')
assert(count('room')==0,'manual room edit must not leave active room')
act('join-room');assert(last('room').room=='new-room')
handlers['splay-command'](utils.format_json({action='connect',host='external.example',port=8999,username='external',room='external-room',tls='off',password='EXTERNAL_SECRET',custom='preserved'}))
assert(last('connect').custom=='preserved' and last('connect').password=='EXTERNAL_SECRET')
assert(last('history-save').settings.host=='external.example' and last('history-save').settings.password==nil)
handlers['splay-chat']();prompted.submit('四个字符');assert(count('chat')==0)
handlers['splay-chat']();prompted.submit('中文');assert(last('chat').text=='中文')
local previous=prompted
handlers['splay-state'](utils.format_json({schema=1,connection='connected',members={},chat_supported=false,ready=false}))
handlers['splay-chat']();assert(prompted==previous,'unsupported chat must not open input')
handlers['splay-event']('{"schema":1,"type":"chat","id":0,"username":"user","text":"before\\u0000after"}')
act('chat-history');assert(selected.items[1]:find('before␀after',1,true),'NUL should not truncate later text')
handlers['splay-event']('{"schema":1,"type":"chat","id":1,"username":"user","text":"literal\\\\u0000after"}')
act('chat-history');assert(selected.items[2]:find('u0000after',1,true),'escaped backslashes remain literal')
for index=1,105 do handlers['splay-event'](utils.format_json({schema=1,type='chat',id=index+1,username='user',text='message'..index})) end
act('chat-history');assert(#selected.items==100 and selected.items[1]:find('message6',1,true))
handlers['splay-state'](utils.format_json({schema=1,connection='connected',members={},room='different-room'}))
handlers['splay-open']('native');assert(label('查看本连接房间聊天记录: 0'),'room change clears previous chat')
handlers['splay-event'](utils.format_json({schema=1,type='chat',id=200,username='user',text='current-room'}))
handlers['splay-state'](utils.format_json({schema=1,connection='disconnected',members={},room='different-room'}))
handlers['splay-open']('native');assert(label('查看本连接房间聊天记录: 0'),'disconnect clears previous chat')
act('toggle-status');act('toggle-buttons')
local found={}
for _,item in ipairs(commands) do if item[2]=='splay_overlay' then found[item[3]]=true end end
assert(found['splay-state'] and found['splay-event'] and found['overlay-toggle-status'] and found['overlay-toggle-buttons'])
commands={};handlers['splay-overlay-ready']();assert(commands[1][3]=='splay-state')
-- A user's edit before the first history reply must survive that late reply.
commands={};overrides={};assert(loadfile(opt.source))()
act('host');prompted.submit('typed-first.example')
handlers['splay-history'](utils.format_json(history))
handlers['splay-open']('native');assert(label('typed-first.example'))
assert(last('history-save').settings.host=='typed-first.example' and last('history-save').settings.room=='历史房间')
commands={};overrides={};assert(loadfile(opt.source))()
act('room');prompted.submit('typed-first-room')
assert(count('history-save')==0,'early edit must queue save until history loads')
handlers['splay-history'](utils.format_json(history))
assert(last('history-save').settings.room=='typed-first-room')
assert(last('history-save').settings.host=='history.example' and last('history-save').settings.username=='历史昵称','queued field edit preserves loaded non-edited fields')
-- Disabled history never reads or writes; normal connection is still explicit.
commands={};overrides={history_enabled=false};assert(loadfile(opt.source))()
assert(count('history-load')==0 and count('connect')==0)
act('host');prompted.submit('fresh.example');assert(count('history-save')==0)
print('UI_FORMS_PASSED defaults/history, complete profiles, password isolation, manual room, explicit connect, chat, overlay, late restore, opt-out')
real_mp.commandv('quit')
