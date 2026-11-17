-- Optional room playlist presentation. The server list never replaces mpv's queue.
-- Project-authored code: GPL-3.0-only.
local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'
local state = {enabled=false,connection='disconnected',playlist={files={}}}
local received, follow, generation, loaded_epoch = false, false, 0, 0
local known, ambiguous, bindings, approved_urls = {}, {}, {}, {}
local pending, pending_timer, selected, confirmation, eof_token
local share_preview
local media_titles={}
local loaded_path=mp.get_property_native('path')
local current_ui, page, menu_open, menu_epoch = 'native', 'home', false, 0
local native_input=false
local show, action
-- Interface text, gettext style: the Chinese source text is the key. The main
-- script sends the resolved language in state.settings.
local EN={
    ['网络媒体']='Network media',
    ['此网络项目尚未获准打开；请在列表中选择并确认该地址']='This network item is not approved yet; select it in the list and confirm the address',
    ['此项目不是可安全查找的文件名；请先绑定本机文件']='This item is not a filename that can be looked up safely; bind a local file first',
    ['未找到此项目；请先绑定本机文件']='Item not found; bind a local file first',
    ['只有房间操作员可以更改共享列表或选择房间播放项']='Only the room operator can change the shared playlist or select the room item',
    ['房间尚未确认播放项；当前媒体保持原样']='The room has not confirmed the item; current media is unchanged',
    ['房间或列表已变化，请重新操作']='The room or list changed; try again',
    ['列表超出服务器限制（250 项、10000 字符或 16 KiB）']='The list exceeds server limits (250 items, 10000 characters or 16 KiB)',
    ['此项目已在共享列表中']='This item is already in the shared playlist',
    ['所选项目已在共享列表中']='The selected items are already in the shared playlist',
    ['没有可共享的文件或 HTTP(S) 媒体']='No files or HTTP(S) media to share',
    ['共享播放列表当前不可用']='The shared playlist is not available now',
    ['只有房间操作员可以选择房间播放项']='Only the room operator can select the room item',
    ['‹ 返回']='‹ Back',['将添加 %s 项']='Items to add: %s',
    ['%s 个网络项目将共享完整地址']='Network items shared with their full address: %s',
    ['地址中的访问参数也会发送；不附带请求头或 Cookie']='Access parameters in addresses are sent too; no headers or cookies',
    ['跳过 %s 项；去重 %s 项']='Skipped: %s; duplicates removed: %s',['另有 %s 项']='%s more',
    ['确认共享到房间']='Confirm sharing to the room',['‹ 取消']='‹ Cancel',
    ['确认打开此网络地址（仅本次进程允许此项）']='Confirm opening this network address (allowed for this process only)',
    ['‹ 返回共享播放列表']='‹ Back to shared playlist',['列表为空']='The list is empty',['‹ 返回列表']='‹ Back to list',
    ['播放此项（同步到房间）']='Play this item (sync to room)',['在本机播放房间当前项']='Play the room\'s current item here',
    ['绑定到本机文件…']='Bind to a local file…',['删除此项']='Remove this item',['上移']='Move up',['下移']='Move down',
    ['导入 mpv 播放队列…']='Import mpv playlist…',['手动添加文件名…']='Add a filename…',['添加网络地址…']='Add a network address…',
    ['清空共享列表…']='Clear shared playlist…',['确认清空房间共享列表']='Confirm clearing the room\'s shared playlist',
    ['‹ 返回 splay']='‹ Back to splay',['播放列表 · %s 项']='Playlist · items: %s',['当前第 %s 项']='current %s',
    ['跟随房间 / 播完下一项: %s']='Follow room / next at end: %s',['开启']='On',['关闭']='Off',
    ['播放房间当前项']='Play the room\'s current item',['共享当前网络媒体…']='Share current network media…',
    ['添加当前文件']='Add current file',['导入 / 手动添加 / 清空']='Import / add / clear',
    ['受控房间：只有操作员可以编辑和选项']='Controlled room: only the operator can edit and select',
    ['请连接支持共享列表的服务器']='Connect to a server that supports shared playlists',['请先开启 splay']='Enable splay first',
    ['共享播放列表']='Shared playlist',['uosc 无响应，打开原生播放列表']='uosc did not respond; opening the native playlist',
    ['共享播放列表需要启用 mpv console 脚本']='The shared playlist needs the mpv console script',
    ['房间或列表已变化，请重新打开列表']='The room or list changed; reopen the list',
    ['列表已变化，请重新选择']='The list changed; select again',['列表已变化，请重新确认地址']='The list changed; confirm the address again',
    ['已开启本机跟随；安全可用的房间播放项将切换本机媒体']='Local following on; safe, available room items will switch local media',
    ['已关闭本机跟随']='Local following off',['房间尚未选择播放项']='The room has not selected an item',
    ['输入该项目对应的本机文件完整路径（仅保存在本进程）']='Full local path for this item (kept in this process only)',
    ['本机文件不存在或路径不可用']='Local file not found or path unusable',
    ['已绑定本机文件；尚未切换播放']='Local file bound; playback not switched',
    ['房间或列表已变化，请重新选择要共享的项目']='The room or list changed; choose the items to share again',
    ['当前没有可添加的本机文件']='No local file to add',
    ['添加共享文件名（本机路径请通过“绑定”设置）']='Add a shared filename (set local paths with "Bind")',
    ['请输入单个文件名；网络地址请使用公开地址入口']='Enter a single filename; use the network address entry for URLs',
    ['添加公开 HTTP(S) 地址（完整地址将发给房间所有人）']='Add a public HTTP(S) address (the full address is sent to everyone in the room)',
    ['仅支持有效的公开 HTTP(S) 地址']='Only valid public HTTP(S) addresses are supported',
}
local language
local function T(text)
    if language=='en' then return EN[text] or text end
    return text
end

local function network(value)
    return type(value)=='string' and value:lower():match('^https?://[^/%s?#]+')~=nil and not value:find('[%c%s]')
end
local function plain(value)
    local text=tostring(value or '')
    if text:lower():match('^https?://') then
        local title=media_titles[text]
        local host=text:match('^%a+://([^/%?#]+)') or ''
        host=host:gsub('^.*@','')
        text=title or (T('网络媒体')..(host~='' and ' · '..host or ''))
    end
    text=text:gsub('[%c{}\\]', ' ')
    if #text>240 then
        local finish=240
        while finish>0 and text:byte(finish+1)>=128 and text:byte(finish+1)<=191 do finish=finish-1 end
        text=text:sub(1,finish)..'…'
    end
    return text
end
local function notice(text)
    mp.osd_message(text,4)
    mp.commandv('script-message-to','splay','splay-notice',utils.format_json({text=text,category='playlist'}))
end
local function files() return type(state.playlist)=='table' and state.playlist.files or {} end
local function index()
    local i=tonumber((state.playlist or {}).index)
    if i and i==math.floor(i) and i>=0 and i<#files() then return i end
end
local function available()
    return state.enabled==true and state.connection=='connected' and state.playlist_supported==true
end
local function can_control() return available() and (not state.controlled or state.is_controller==true) end
local function publish()
    mp.set_property_native('user-data/splay-playlist',{follow=follow,count=#files(),index=index(),
        pending=pending~=nil,can_control=can_control(),generation=generation,menu_epoch=menu_epoch,menu=menu_open and page or ''})
end
local function clear_pending()
    pending=nil
    if pending_timer then pending_timer:kill();pending_timer=nil end
end
local function basename(path) return path:match('([^/\\]+)$') end
local function safe_name(value)
    return type(value)=='string' and value~='' and value~='.' and value~='..'
        and not value:find('[/\\:%c]') and not value:find('..',1,true)
end
local function local_path(value)
    if type(value)~='string' or value=='' or value:find('[%c]') or network(value) then return nil end
    if value:match('^%a[%w+.-]*:') and not value:match('^%a:[/\\]') then return nil end
    if not value:match('^%a:[/\\]') and not value:match('^[/\\]') then
        value=utils.join_path(mp.get_property_native('working-directory') or '.',value)
    end
    return value
end
local function existing(path)
    local info=path and utils.file_info(path)
    return info and info.is_file==true
end
local function remember(path)
    if network(path) then known[path]=path;return end
    path=local_path(path)
    if not path then return end
    local name=basename(path)
    if not safe_name(name) then return end
    if known[name] and known[name]~=path then ambiguous[name]=true end
    known[name]=path
end
local function collect()
    for _,entry in ipairs(mp.get_property_native('playlist') or {}) do
        remember(entry.filename)
        if network(entry.filename) and type(entry.title)=='string' and entry.title~='' and #entry.title<=1024 and
            not entry.title:find('[/\\:?=#%%]') and not entry.title:find('[%c]') then media_titles[entry.filename]=entry.title end
    end
    remember(mp.get_property_native('path'))
end
local function resolve(ref)
    local bound=bindings[ref]
    if bound and existing(bound) then return bound end
    if network(ref) then
        if known[ref] or approved_urls[ref] then return ref end
        return nil,'approval'
    end
    if not safe_name(ref) then return nil,'reference' end
    if known[ref] and not ambiguous[ref] and existing(known[ref]) then return known[ref] end
    local current=local_path(mp.get_property_native('path') or loaded_path)
    local directory=current and current:match('^(.*[/\\])[^/\\]+$')
    local candidate=directory and utils.join_path(directory,ref)
    if existing(candidate) then return candidate end
    return nil,'missing'
end
local function missing(reason)
    if reason=='approval' then notice(T('此网络项目尚未获准打开；请在列表中选择并确认该地址'))
    elseif reason=='reference' then notice(T('此项目不是可安全查找的文件名；请先绑定本机文件'))
    else notice(T('未找到此项目；请先绑定本机文件')) end
end
local function load_target(target)
    local path=mp.get_property_native('path')
    if path==target or (not network(target) and local_path(path)==target) then return end
    mp.commandv('loadfile',target,'replace')
end
local function command(value)
    mp.commandv('script-message-to','splay','splay-command',utils.format_json(value))
end
local function select_item(i,target)
    if not can_control() then notice(T('只有房间操作员可以更改共享列表或选择房间播放项'));return end
    if index()==i then load_target(target);return end
    clear_pending()
    pending={generation=generation,index=i,file=files()[i+1],target=target}
    local request=pending
    pending_timer=mp.add_timeout(8,function()
        if pending==request then clear_pending();notice(T('房间尚未确认播放项；当前媒体保持原样'));publish() end
    end)
    command({action='playlist-index',index=i});publish()
end
local function close()
    menu_open=false;menu_epoch=menu_epoch+1
    mp.commandv('script-message-to','uosc','close-menu','splay-playlist')
    publish()
end
local function prompt(label,callback)
    close()
    local captured,input_epoch=generation,menu_epoch
    native_input=true
    input.get({id='splay-playlist-input',prompt=label..': ',default_text='',closed=function()
        if input_epoch==menu_epoch then native_input=false end
    end,submit=function(value)
        if captured~=generation then notice(T('房间或列表已变化，请重新操作'));return end
        if type(value)=='string' and #value<=40000 and not value:find('[%c]') then callback(value) end
    end})
end
local function playlist_valid(list)
    if #list>250 then return false end
    local count=0
    for _,value in ipairs(list) do
        if type(value)~='string' or value=='' or value:find('[%c]') then return false end
        local _,continuations=value:gsub('[\128-\191]','')
        count=count+#value-continuations
    end
    -- Syncplay 1.7.6 limits the complete encoded client line to 16 KiB.
    return count<=10000 and #(utils.format_json({Set={playlistChange={files=list}}})..'\r\n')<=16384
end
local function set_files(list)
    if not can_control() then notice(T('只有房间操作员可以更改共享列表或选择房间播放项'));return end
    if not playlist_valid(list) then notice(T('列表超出服务器限制（250 项、10000 字符或 16 KiB）'));return end
    command({action='playlist-set',files=list})
end
local function copy_files()
    local result={};for i,value in ipairs(files()) do result[i]=value end;return result
end
local function append(ref)
    local result=copy_files()
    for _,item in ipairs(result) do if item==ref then notice(T('此项目已在共享列表中'));return end end
    result[#result+1]=ref;set_files(result)
end
local function prepare_share(queue)
    collect()
    local candidates=queue and (mp.get_property_native('playlist') or {}) or {{filename=mp.get_property_native('path')}}
    local items,seen,network_count,skipped,duplicates={},{},0,0,0
    for _,ref in ipairs(files()) do seen[ref]=true end
    for _,entry in ipairs(candidates) do
        local ref,path
        if network(entry.filename) then ref=entry.filename
        else
            path=local_path(entry.filename)
            local name=path and basename(path)
            if name and safe_name(name) and existing(path) then ref=name end
        end
        if not ref then skipped=skipped+1
        elseif seen[ref] then duplicates=duplicates+1
        else
            seen[ref]=true;items[#items+1]=ref
            if network(ref) then network_count=network_count+1 end
        end
    end
    if #items==0 then notice(duplicates>0 and T('所选项目已在共享列表中') or T('没有可共享的文件或 HTTP(S) 媒体'));return end
    share_preview={generation=generation,items=items,network_count=network_count,skipped=skipped,duplicates=duplicates}
    show(nil,'share')
end
local function selected_valid()
    return selected and selected.generation==generation and files()[selected.index+1]==selected.file
end
local function play(i,change_room)
    if not available() or not files()[i+1] then notice(T('共享播放列表当前不可用'));return end
    if change_room and not can_control() then notice(T('只有房间操作员可以选择房间播放项'));return end
    collect()
    local ref=files()[i+1]
    local target,reason=resolve(ref)
    if not target and reason=='approval' then
        confirmation={generation=generation,index=i,file=ref,change_room=change_room}
        show(nil,'url');return
    elseif not target then missing(reason);return end
    if change_room then select_item(i,target) else load_target(target) end
end
local function entry(title,value,selectable) return {title=title,value=value,selectable=selectable~=false} end
local function rows()
    if page=='share' and share_preview then
        local preview=share_preview
        local result={entry(T('‹ 返回'),'home'),entry(T('将添加 %s 项'):format(#preview.items),'noop',false)}
        if preview.network_count>0 then
            result[#result+1]=entry(T('%s 个网络项目将共享完整地址'):format(preview.network_count),'noop',false)
            result[#result+1]=entry(T('地址中的访问参数也会发送；不附带请求头或 Cookie'),'noop',false)
        end
        if preview.skipped+preview.duplicates>0 then
            result[#result+1]=entry(T('跳过 %s 项；去重 %s 项'):format(preview.skipped,preview.duplicates),'noop',false)
        end
        for i=1,math.min(#preview.items,5) do result[#result+1]=entry(plain(preview.items[i]),'noop',false) end
        if #preview.items>5 then result[#result+1]=entry(T('另有 %s 项'):format(#preview.items-5),'noop',false) end
        result[#result+1]=entry(T('确认共享到房间'),'share-confirm')
        return result
    end
    if page=='url' and confirmation then return {
        entry(T('‹ 取消'),'home'),entry(plain(confirmation.file),'noop',false),
        entry(T('确认打开此网络地址（仅本次进程允许此项）'),'approve-url')}
    end
    if page=='list' then
        local result={entry(T('‹ 返回共享播放列表'),'home')}
        for i,ref in ipairs(files()) do
            result[#result+1]=entry((index()==i-1 and '▶ ' or '')..i..'. '..plain(ref),'item:'..generation..':'..i)
        end
        if #files()==0 then result[#result+1]=entry(T('列表为空'),'noop',false) end
        return result
    end
    if page=='item' and selected_valid() then
        local i=selected.index
        local result={entry(T('‹ 返回列表'),'list'),entry(plain(selected.file),'noop',false)}
        if can_control() then result[#result+1]=entry(T('播放此项（同步到房间）'),'select')
        elseif index()==i then result[#result+1]=entry(T('在本机播放房间当前项'),'play-current') end
        if not network(selected.file) then result[#result+1]=entry(T('绑定到本机文件…'),'bind') end
        if can_control() then
            result[#result+1]=entry(T('删除此项'),'remove')
            result[#result+1]=entry(T('上移'),'up',i>0)
            result[#result+1]=entry(T('下移'),'down',i<#files()-1)
        end
        return result
    end
    if page=='edit' then return {
        entry(T('‹ 返回共享播放列表'),'home'),entry(T('导入 mpv 播放队列…'),'import-preview'),
        entry(T('手动添加文件名…'),'add-manual'),entry(T('添加网络地址…'),'add-url'),entry(T('清空共享列表…'),'clear-preview')}
    end
    if page=='clear' then return {entry(T('‹ 取消'),'edit'),entry(T('确认清空房间共享列表'),'clear')} end
    local i=index()
    local result={entry(T('‹ 返回 splay'),'back'),
        entry(T('播放列表 · %s 项'):format(#files())..(i and ' · '..T('当前第 %s 项'):format(i+1) or ''),'list'),
        entry(T('跟随房间 / 播完下一项: %s'):format(follow and T('开启') or T('关闭')),'follow',available())}
    if i then result[#result+1]=entry(T('播放房间当前项'),'play-current') end
    if can_control() then
        result[#result+1]=entry(network(mp.get_property_native('path')) and T('共享当前网络媒体…') or T('添加当前文件'),'add-current')
        result[#result+1]=entry(T('导入 / 手动添加 / 清空'),'edit')
    elseif available() then result[#result+1]=entry(T('受控房间：只有操作员可以编辑和选项'),'noop',false) end
    if not available() then result[#result+1]=entry(state.enabled and T('请连接支持共享列表的服务器') or T('请先开启 splay'),'noop',false) end
    return result
end
local function model()
    return {type='splay-playlist',title=T('共享播放列表'),items=rows(),
        callback={'splay_playlist','splay-playlist-menu-event',tostring(generation),tostring(menu_epoch)},
        on_close={'script-message-to','splay_playlist','splay-playlist-menu-closed',tostring(menu_epoch)}}
end
show=function(mode,which)
    current_ui=mode or current_ui;page=which or 'home'
    if page=='item' and not selected_valid() then page='list' end
    close();menu_open=true;menu_epoch=menu_epoch+1;publish()
    local opened_epoch=menu_epoch
    if current_ui=='uosc' then
        mp.commandv('script-message-to','uosc','open-menu',utils.format_json(model()))
        local opened_page=page
        mp.add_timeout(.4,function()
            if menu_open and menu_epoch==opened_epoch and current_ui=='uosc' and mp.get_property_native('user-data/uosc/menu/type')~='splay-playlist' then
                notice(T('uosc 无响应，打开原生播放列表'));show('native',opened_page)
            end
        end)
    else
        if mp.get_property_native('options/load-console')==false then
            close();notice(T('共享播放列表需要启用 mpv console 脚本'));return
        end
        local entries,labels=rows(),{}
        for i,row in ipairs(entries) do labels[i]=row.title end
        local captured=generation
        native_input=true
        input.select({prompt=T('共享播放列表'),items=labels,opened=function()
            if menu_epoch==opened_epoch then native_input=true;menu_open=true;publish() end
        end,closed=function()
            if menu_epoch==opened_epoch then native_input=false;menu_open=false;publish() end
        end,submit=function(i)
            if captured~=generation then notice(T('房间或列表已变化，请重新打开列表'));return end
            -- Older mp.input versions share a single event callback; let the
            -- console's old closed event arrive before opening the next page.
            if entries[i] and entries[i].selectable then mp.add_timeout(.03,function()
                if captured==generation and opened_epoch==menu_epoch then action(entries[i].value) end
            end) end
        end})
    end
end
action=function(value)
    if value=='back' then close();mp.commandv('script-message-to','splay','splay-open',current_ui);return end
    if value=='noop' then return end
    if value=='home' or value=='list' then confirmation=nil;share_preview=nil;show(nil,value);return end
    if not state.enabled then notice(T('请先开启 splay'));return end
    local gen,item=value:match('^item:(%d+):(%d+)$')
    if gen then
        item=tonumber(item)-1
        if tonumber(gen)~=generation or not files()[item+1] then notice(T('列表已变化，请重新选择'));return end
        selected={generation=generation,index=item,file=files()[item+1]};show(nil,'item');return
    end
    if value=='approve-url' then
        local approved=confirmation;confirmation=nil
        if not approved or approved.generation~=generation or files()[approved.index+1]~=approved.file then
            notice(T('列表已变化，请重新确认地址'));return
        end
        approved_urls[approved.file]=true;close();play(approved.index,approved.change_room);return
    end
    if value=='follow' then
        if not available() then notice(T('共享播放列表当前不可用'));return end
        follow=not follow;clear_pending();publish()
        if follow then
            notice(T('已开启本机跟随；安全可用的房间播放项将切换本机媒体'))
            local i=index()
            if i then local target,reason=resolve(files()[i+1]);if target then load_target(target) else missing(reason) end end
        else notice(T('已关闭本机跟随')) end
        show(nil,'home');return
    end
    if value=='play-current' then
        local i=index();if i then close();play(i,false) else notice(T('房间尚未选择播放项')) end;return
    end
    if value=='select' then if selected_valid() then close();play(selected.index,true) end;return end
    if value=='bind' then
        if not selected_valid() then return end
        local ref=selected.file
        prompt(T('输入该项目对应的本机文件完整路径（仅保存在本进程）'),function(path)
            path=local_path(path)
            if not existing(path) then notice(T('本机文件不存在或路径不可用'));return end
            bindings[ref]=path;notice(T('已绑定本机文件；尚未切换播放'));show(nil,'item')
        end);return
    end
    if not can_control() then notice(T('只有房间操作员可以更改共享列表或选择房间播放项'));return end
    if value=='share-confirm' then
        local preview=share_preview;share_preview=nil
        if not preview or preview.generation~=generation then notice(T('房间或列表已变化，请重新选择要共享的项目'));show(nil,'home');return end
        local result=copy_files()
        for _,ref in ipairs(preview.items) do result[#result+1]=ref end
        set_files(result);show(nil,'home')
    elseif value=='edit' then show(nil,'edit')
    elseif value=='add-current' then
        local path=mp.get_property_native('path')
        if network(path) then prepare_share(false);return end
        path=local_path(path);local name=path and basename(path)
        if not name or not safe_name(name) or not existing(path) then notice(T('当前没有可添加的本机文件'));return end
        remember(path);append(name)
    elseif value=='import-preview' or value=='import' then prepare_share(true)
    elseif value=='add-manual' then
        prompt(T('添加共享文件名（本机路径请通过“绑定”设置）'),function(ref)
            if not safe_name(ref) then notice(T('请输入单个文件名；网络地址请使用公开地址入口'));return end
            append(ref)
        end)
    elseif value=='add-url' then
        prompt(T('添加公开 HTTP(S) 地址（完整地址将发给房间所有人）'),function(ref)
            if not network(ref) then notice(T('仅支持有效的公开 HTTP(S) 地址'));return end
            for _,item in ipairs(files()) do if item==ref then notice(T('此项目已在共享列表中'));return end end
            share_preview={generation=generation,items={ref},network_count=1,skipped=0,duplicates=0}
            local pending_share=share_preview
            mp.add_timeout(.03,function() if share_preview==pending_share and pending_share.generation==generation then show(nil,'share') end end)
        end)
    elseif value=='clear-preview' then show(nil,'clear')
    elseif value=='clear' then set_files({});show(nil,'home')
    elseif value=='remove' or value=='up' or value=='down' then
        if not selected_valid() then notice(T('列表已变化，请重新选择'));return end
        local result=copy_files();local i=selected.index+1
        if value=='remove' then table.remove(result,i)
        else
            local other=i+(value=='up' and -1 or 1)
            if other<1 or other>#result then return end
            result[i],result[other]=result[other],result[i]
        end
        set_files(result);show(nil,'list')
    end
end

mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local incoming=utils.parse_json(json)
    if type(incoming)~='table' or incoming.schema~=1 then return end
    if type(incoming.playlist)~='table' or type(incoming.playlist.files)~='table' then incoming.playlist={files={}} end
    local old_files,old_index=utils.format_json(files()),index()
    local identity_changed=not received or state.enabled~=incoming.enabled or state.connection~=incoming.connection
        or state.host~=incoming.host or state.port~=incoming.port or state.room~=incoming.room or state.username~=incoming.username
    local list_changed=old_files~=utils.format_json(incoming.playlist.files)
    if identity_changed or list_changed then generation=generation+1;clear_pending();selected=nil;confirmation=nil;share_preview=nil end
    if identity_changed then
        follow=false;eof_token=nil
        if menu_open or native_input then
            local terminate_native=native_input
            close();native_input=false
            if terminate_native then input.terminate() end
        end
    end
    state=incoming;received=true;collect()
    local settings=type(incoming.settings)=='table' and incoming.settings or {}
    local previous_language=language
    if settings.language=='zh-CN' or settings.language=='en' then language=settings.language end
    local i=index();local loaded=false
    if pending and (not can_control() or not available()) then clear_pending() end
    if pending and pending.generation==generation and i==pending.index and files()[i+1]==pending.file then
        local expected=pending.target
        local target,reason=resolve(pending.file)
        clear_pending()
        if target==expected then load_target(target);loaded=true else missing(reason) end
    end
    if follow and available() and not identity_changed and not loaded and i and (list_changed or old_index~=i) then
        local target,reason=resolve(files()[i+1]);if target then load_target(target) else missing(reason) end
    end
    publish()
    if menu_open then
        if page=='url' and not confirmation then page='home' end
        if page=='share' and not share_preview then page='home' end
        if page=='item' and not selected_valid() then page='list' end
        if current_ui=='uosc' then
            mp.commandv('script-message-to','uosc','update-menu',utils.format_json(model()))
        elseif (list_changed or language~=previous_language) and (page=='home' or page=='list') then
            local refreshed_page,refreshed_epoch=page,menu_epoch
            mp.add_timeout(0,function()
                if menu_open and current_ui=='native' and menu_epoch==refreshed_epoch then show(nil,refreshed_page) end
            end)
        end
    end
end)
mp.register_script_message('splay-playlist-open',function(mode) show(mode=='uosc' and 'uosc' or 'native','home') end)
mp.register_script_message('splay-playlist-action',function(value) if type(value)=='string' then action(value) end end)
mp.register_script_message('splay-playlist-menu-event',function(captured,epoch,json)
    if tonumber(captured)~=generation or tonumber(epoch)~=menu_epoch or not menu_open then return end
    local event=utils.parse_json(json or '')
    if type(event)=='table' and event.type=='activate' and type(event.value)=='string' then action(event.value) end
end)
mp.register_script_message('splay-playlist-menu-closed',function(epoch)
    if tonumber(epoch)==menu_epoch then menu_open=false;publish() end
end)
mp.register_event('file-loaded',function()
    loaded_epoch=loaded_epoch+1;loaded_path=mp.get_property_native('path');collect()
end)
mp.register_event('end-file',function(event)
    if event.reason~='eof' or not follow or not can_control() or pending then return end
    local i=index();if not i or not files()[i+2] then return end
    local token=generation..':'..i..':'..loaded_epoch
    if eof_token==token then return end
    -- mpv may unload properties before dispatching end-file. The last actual
    -- file-loaded event identifies the media which ended, including that case.
    local current=resolve(files()[i+1]);local actual=loaded_path
    if not current or (current~=actual and current~=local_path(actual)) then return end
    eof_token=token
    local target,reason=resolve(files()[i+2]);if not target then missing(reason);return end
    select_item(i+1,target)
end)
collect();publish()
local ready_timer
local function announce()
    if received then if ready_timer then ready_timer:kill() end;return end
    mp.commandv('script-message-to','splay','splay-playlist-ready')
end
ready_timer=mp.add_periodic_timer(.5,announce)
announce()
