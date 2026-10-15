-- Execute the production playlist adapter with real JSON and an mpv double.
local real_mp=require 'mp'
local utils=require 'mp.utils'
local options=require 'mp.options'
local opt={source=''};options.read_options(opt,'playlist_forms')
local commands,handlers,events,properties,selected,prompted,timers,incoming
local file_paths={['D:/fixtures/a.mp4']=true,['D:/fixtures/b.mp4']=true,['D:/fixtures/c.mp4']=true}
local fake={}
fake.commandv=function(...) commands[#commands+1]={...} end
fake.command=function() error('Playlist must never construct command strings') end
fake.get_property_native=function(name) return properties[name] end
fake.set_property_native=function(name,value) properties[name]=value end
fake.register_script_message=function(name,fn) handlers[name]=fn end
fake.register_event=function(name,fn) events[name]=fn end
fake.osd_message=function() end
local function timer(delay,fn)
    local result={delay=delay,fn=fn,killed=false,kill=function(self) self.killed=true end}
    timers[#timers+1]=result;if delay==0 then fn() end;return result
end
fake.add_timeout=timer;fake.add_periodic_timer=timer
local fake_utils={}
for key,value in pairs(utils) do fake_utils[key]=value end
fake_utils.file_info=function(path) return file_paths[path:gsub('\\','/')] and {is_file=true} or nil end
package.loaded.mp=fake
package.loaded['mp.utils']=fake_utils
package.loaded['mp.input']={select=function(value) selected=value end,get=function(value) prompted=value end,
    terminate=function() if selected and selected.closed then selected.closed() end;if prompted and prompted.closed then prompted.closed() end end}
local function start(props)
    commands,handlers,events,selected,prompted,timers={},{},{},nil,nil,{}
    properties={path='D:/fixtures/a.mp4',['working-directory']='D:/fixtures',['options/load-console']=true,
        playlist={{filename='D:/fixtures/a.mp4'},{filename='D:/fixtures/b.mp4'}}}
    for key,value in pairs(props or {}) do properties[key]=value end
    incoming={schema=1,enabled=true,connection='connected',host='localhost',port=8999,room='room',username='tester',
        controlled=false,is_controller=false,playlist_supported=true,playlist={files={'a.mp4','b.mp4'},index=0,user='other'}}
    assert(loadfile(opt.source))()
end
local function state(extra)
    for key,value in pairs(extra or {}) do incoming[key]=value end
    handlers['splay-state'](utils.format_json(incoming))
end
local function action(value) handlers['splay-playlist-action'](value) end
local function item(i) action('item:'..properties['user-data/splay-playlist'].generation..':'..i) end
local function loads()
    local result={};for _,value in ipairs(commands) do if value[1]=='loadfile' then result[#result+1]=value end end;return result
end
local function core()
    local result={}
    for _,value in ipairs(commands) do
        if value[1]=='script-message-to' and value[2]=='splay' and value[3]=='splay-command' then
            result[#result+1]=utils.parse_json(value[4])
        end
    end
    return result
end
local function finish(value) local request=prompted;prompted=nil;request.submit(value) end
local function count(action_name)
    local n=0;for _,value in ipairs(core()) do if value.action==action_name then n=n+1 end end;return n
end
local function no_private_text()
    for _,value in ipairs(commands) do
        if value[3]=='splay-notice' or value[3]=='splay-command' then assert(not value[4]:find('PRIVATE_TOKEN',1,true),value[4]) end
    end
end

start({path='https://private.example/a?token=PRIVATE_TOKEN',playlist={{filename='D:/fixtures/a.mp4'},
    {filename='D:/fixtures/b.mp4'},{filename='https://private.example/a?token=PRIVATE_TOKEN'}}})
assert(#core()==0 and #loads()==0)
state({playlist={files={'b.mp4','a.mp4'},index=0}})
assert(#loads()==0 and not properties['user-data/splay-playlist'].follow,'first authoritative list must preserve caller media')
action('import-preview');assert(#core()==0,'import requires explicit confirmation')
action('import')
assert(core()[1].action=='playlist-set' and #core()[1].files==4)
assert(core()[1].files[3]=='a.mp4' and core()[1].files[4]=='b.mp4','native queue import shares basenames only')
no_private_text()
action('add-current');assert(#core()==1,'current private URL must not be auto-shared')
item(2);action('select')
assert(count('playlist-index')==1 and #loads()==0,'explicit room selection waits for authoritative echo')
state({playlist={files={'b.mp4','a.mp4'},index=1}})
assert(#loads()==1 and loads()[1][2]=='D:/fixtures/a.mp4' and loads()[1][3]=='replace')
item(1);action('select');assert(count('playlist-index')==2)
state({playlist={files={'c.mp4','b.mp4'},index=1}})
state({playlist={files={'c.mp4','b.mp4'},index=0}})
assert(#loads()==1,'list replacement must invalidate a pending load even if a late echo has the requested index')
item(2);action('select');assert(properties['user-data/splay-playlist'].pending)
state({room='new-room',playlist={files={'c.mp4','b.mp4'},index=1}})
assert(#loads()==1 and not properties['user-data/splay-playlist'].pending,'room transition invalidates pending selection')

start();state({controlled=true,is_controller=false,playlist={files={'b.mp4','a.mp4'},index=0}})
action('add-current');action('import');item(2);action('select')
assert(#core()==0 and #loads()==0,'ordinary members cannot alter room list or index')
action('play-current');assert(#loads()==1 and loads()[1][2]=='D:/fixtures/b.mp4','ordinary members may locally play current room item')
action('follow');assert(count('playlist-index')==0,'enabling ordinary local follow cannot select the room')
state({playlist={files={'b.mp4','a.mp4'},index=1}})
assert(count('playlist-index')==0,'following a remote change must not echo an index command')
events['end-file']({reason='eof'});assert(#core()==0,'ordinary members never auto-advance room on EOF')
state({enabled=false,playlist={files={'b.mp4','a.mp4'},index=0}});action('play-current')
assert(#core()==0 and not properties['user-data/splay-playlist'].follow)

for _,reference in ipairs({'D:/fixtures/b.mp4','../b.mp4','file:///D:/fixtures/b.mp4','av://camera','folder/b.mp4','\\\\host\\b.mp4'}) do
    start();state({playlist={files={reference},index=0}});action('play-current')
    assert(#loads()==0,'untrusted local/protocol references may not load: '..reference)
end
start();state({playlist={files={'D:/foreign/reference.mp4'},index=0}})
item(1);action('bind');finish('D:/fixtures/b.mp4')
assert(#loads()==0,'binding alone preserves media')
action('play-current');assert(loads()[1][2]=='D:/fixtures/b.mp4')

start();state({playlist={files={'https://user:secret@example.invalid/video.mp4?token=PRIVATE_TOKEN#secret'},index=0}})
action('follow');assert(#loads()==0,'following must not open an unapproved incoming URL')
action('play-current');assert(#loads()==0 and properties['user-data/splay-playlist'].menu=='url')
for _,label in ipairs(selected.items) do assert(not label:find('PRIVATE_TOKEN',1,true) and not label:find('user:secret',1,true)) end
no_private_text()
action('approve-url');assert(#loads()==1 and loads()[1][2]==incoming.playlist.files[1] and loads()[1][3]=='replace')
start({playlist={{filename='https://known.invalid/media?private=local'}}})
state({playlist={files={'https://known.invalid/media?private=local'},index=0}});action('play-current')
assert(#loads()==1 and loads()[1][2]=='https://known.invalid/media?private=local','caller queue URLs are already known local associations')

start();state();action('add-url');finish('https://public.invalid/movie?share=yes')
assert(core()[1].files[3]=='https://public.invalid/movie?share=yes' and #loads()==0,'manual URL sharing is explicit but does not start playback')
start();state();item(2);action('bind');state({playlist={files={'a.mp4','c.mp4'},index=0}});finish('D:/fixtures/b.mp4')
action('play-current');assert(#loads()==0,'stale binding input cannot affect another generation')

start();state();action('follow');assert(#loads()==0,'already loaded current item needs no reload')
properties.path=nil -- end-file may be delivered after mpv unloads path.
events['end-file']({reason='eof'});events['end-file']({reason='eof'})
assert(count('playlist-index')==1 and core()[1].index==1 and #loads()==0,'duplicate EOF sends one next request and waits for echo')
state({playlist={files={'a.mp4','b.mp4'},index=1}})
assert(#loads()==1 and loads()[1][2]=='D:/fixtures/b.mp4' and count('playlist-index')==1)
properties.path='D:/fixtures/b.mp4';events['file-loaded']();events['end-file']({reason='eof'})
assert(count('playlist-index')==1,'no EOF wrap or remote echo loop')
start();state({playlist={files={'a.mp4','missing.mp4'},index=0}});action('follow');events['end-file']({reason='eof'})
assert(#core()==0 and #loads()==0,'missing next media leaves room index and current media unchanged')
start({playlist={{filename='D:/fixtures/a.mp4'}}});state();action('follow');properties.path=nil
events['end-file']({reason='eof'})
assert(count('playlist-index')==1,'EOF can resolve a direct next file beside the last loaded local media')
start();state();item(2);action('select');file_paths['D:/fixtures/b.mp4']=nil
state({playlist={files={'a.mp4','b.mp4'},index=1}})
assert(#loads()==0,'a file removed while waiting for an echo must not replace caller media')
file_paths['D:/fixtures/b.mp4']=true

start();state();handlers['splay-playlist-open']('uosc')
local menu
for _,value in ipairs(commands) do if value[2]=='uosc' and value[3]=='open-menu' then menu=utils.parse_json(value[4]) end end
assert(menu.type=='splay-playlist' and #menu.items<=7 and menu.callback[1]=='splay_playlist')
local old_epoch=menu.on_close[4]
handlers['splay-playlist-menu-event'](menu.callback[3],menu.callback[4],utils.format_json({type='activate',value='list'}))
assert(properties['user-data/splay-playlist'].menu=='list')
handlers['splay-playlist-menu-closed'](old_epoch)
assert(properties['user-data/splay-playlist'].menu=='list','closing an old uosc page must not close the next page')
for _,row in ipairs({4,5}) do
    for _,transition in ipairs({'room','reconnect'}) do
        start();state();handlers['splay-playlist-open']('native')
        selected.submit(row)
        local queued=timers[#timers];assert(queued.delay==.03)
        if transition=='reconnect' then state({enabled=false,connection='disconnected'}) end
        state({enabled=true,connection='connected',room='new-room',playlist={files={'b.mp4','a.mp4'},index=0}})
        queued.fn()
        assert(#loads()==0 and not properties['user-data/splay-playlist'].follow,
            'a delayed old-room native play/follow action must not affect the new room')
        assert(properties['user-data/splay-playlist'].menu=='','identity transition closes the old native menu')
    end
end
for _,value in ipairs({'play-current','follow'}) do
    start();state();handlers['splay-playlist-open']('uosc')
    local original
    for _,command in ipairs(commands) do if command[2]=='uosc' and command[3]=='open-menu' then original=utils.parse_json(command[4]) end end
    state({enabled=false,connection='disconnected'})
    state({enabled=true,connection='connected',room='new-room',playlist={files={'b.mp4','a.mp4'},index=0}})
    handlers['splay-playlist-menu-event'](original.callback[3],original.callback[4],utils.format_json({type='activate',value=value}))
    assert(#loads()==0 and not properties['user-data/splay-playlist'].follow,
        'old uosc page actions cannot load or enable follow after reconnect')
    assert(properties['user-data/splay-playlist'].menu=='','identity transition closes the old uosc menu')
end
print('PLAYLIST_FORMS_PASSED first-state preservation, explicit basename import, URL privacy and single-address consent, ACL, known and bound local resolution, generation-safe echo, follow and single EOF advance, native/uosc menu contracts')
real_mp.commandv('quit',0)
