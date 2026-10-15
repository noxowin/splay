-- Optional presentation only. Protocol state and commands belong to splay.lua.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local cfg = {status_osd=true, button_enabled=true, button_bottom=48, button_right=22,
    overlay_font_size=22, overlay_chat_ttl=5, overlay_chat_lines=4,
    overlay_message_ttl=5, room_panel=true, room_idle_timeout=3}
local state = {enabled=false, connection='disconnected', members={}}
local chats, playback, notices, seen, seen_order = {}, nil, {}, {}, {}
local status = mp.create_osd_overlay('ass-events')
local buttons = mp.create_osd_overlay('ass-events')
status.z, buttons.z = 25, 40
local width, height, scale, rectangles = 0, 0, 1, {}
local visible, hovering, last_near, uosc = false, false, -100, false
local section = 'splay-overlay-buttons'
local redraw, update_buttons, close_popup, integrate_uosc
local popup_open, popup, menu_rows, anchor = false, nil, {}, nil
local menu_model = {title='同步播放',items={{title='启用同步播放',value='toggle-enabled'}}}
local integrated, installed_controls, original_controls_override = false, nil, nil
local base_controls
local had_controls_override = false
local uosc_defaults = {controls='',timeline_size=40,controls_size=32,controls_margin=8,window_border_size=1,scale=1,scale_fullscreen=1}
local uosc_cfg = {}
local escape_section = section..'-escape'
local last_activity, last_mouse, panel_visible, panel_geometry = mp.get_time(), {}, false, nil
local notification_count, panel_rows = 0, {}
local function chat_available()
    return cfg.button_enabled and state.enabled==true and state.connection=='connected' and state.chat_supported==true
end
-- mpv exposes cursor-autohide and mouse-pos, but no cursor-hidden property
-- (checked against the target player and upstream input.rst). Follow its
-- configured idle policy without changing cursor options or input ownership.
local function room_visible()
    if not cfg.status_osd or not cfg.room_panel or state.enabled~=true or state.connection~='connected' then return false end
    if mp.get_property_native('pause',false) or mp.get_property_native('idle-active',false) then return true end
    local cursor=mp.get_property('cursor-autohide','1000')
    if cursor=='no' or (mp.get_property_native('cursor-autohide-fs-only',false) and not mp.get_property_native('fullscreen',false)) then return true end
    local timeout
    local milliseconds=tonumber(cursor)
    timeout=milliseconds and math.max(.1,math.min(30,milliseconds/1000)) or math.max(.1,math.min(30,tonumber(cfg.room_idle_timeout) or 3))
    if cursor=='always' then timeout=0 end
    return mp.get_time()-last_activity<timeout
end

-- Keep emoji joiners, modifiers and common combining sequences together when
-- wrapping/truncating. No bytes or joiners are inserted into user text.
local function graphemes(text)
    local groups, previous, regional = {}, nil, 0
    for cp in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local a,b,c,d=cp:byte(1,4)
        local n=a
        if d then n=(a-240)*262144+(b-128)*4096+(c-128)*64+d-128
        elseif c then n=(a-224)*4096+(b-128)*64+c-128
        elseif b then n=(a-192)*64+b-128 end
        local ri=n>=0x1F1E6 and n<=0x1F1FF
        local extending=n==0x200D or (n>=0x300 and n<=0x36F)
            or (n>=0x1AB0 and n<=0x1AFF) or (n>=0x1DC0 and n<=0x1DFF)
            or (n>=0x20D0 and n<=0x20FF) or (n>=0xFE00 and n<=0xFE0F)
            or (n>=0xFE20 and n<=0xFE2F) or (n>=0x1F3FB and n<=0x1F3FF)
            or (n>=0xE0100 and n<=0xE01EF)
        if #groups>0 and (extending or previous==0x200D or (ri and regional%2==1)) then
            groups[#groups]=groups[#groups]..cp
        else groups[#groups+1]=cp end
        regional=ri and regional+1 or 0
        previous=n
    end
    return groups
end
-- Newlines and controls are data, not ASS directives. ASS escaping below uses
-- a zero-width separator after a backslash to prevent \N interpretation.
local function plain(value, limit)
    local text, out, count = tostring(value or ''):gsub('[%c]', ' '), {}, 0
    for _,cp in ipairs(graphemes(text)) do
        if count >= (limit or 100) then out[#out+1]='…'; break end
        out[#out+1], count = cp, count+1
    end
    return table.concat(out)
end
local function playlist_label(value)
    local text=tostring(value or '')
    local scheme,rest=text:match('^%s*([%a][%w+.-]*)://(.*)$')
    if not scheme or (scheme:lower()~='http' and scheme:lower()~='https') then return text end
    -- This is presentation only: the original playlist URL stays intact in
    -- state. Strip secrets before truncation/escaping, including userinfo in
    -- the authority and all query/fragment parameters.
    rest=rest:match('^[^?#]*') or ''
    local authority,path=rest:match('^([^/]*)(.*)$')
    authority=(authority or ''):gsub('^.*@','')
    return authority~='' and authority..(path or '') or '网络媒体'
end
local function escape(text)
    return text:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}')
end
local function parse(json)
    -- mp.utils JSON decoding uses C strings. Make a genuine escaped NUL visible
    -- before decoding so it cannot silently truncate the rest of a message.
    -- An even run of backslashes represents literal text, e.g. "\\u0000".
    json=json:gsub('(\\+)u0000',function(slashes)
        if #slashes%2==1 then return slashes:sub(1,-2)..'␀' end
        return slashes..'u0000'
    end)
    return utils.parse_json(json)
end
local function safe_number(value, fallback, low, high)
    value = tonumber(value)
    if not value or value ~= value then value = fallback end
    return math.max(low, math.min(high, value))
end
local function send(name, ...)
    mp.commandv('script-message-to', 'splay', name, ...)
end
local function is_uosc()
    if uosc or mp.get_property_native('user-data/uosc/menu/type') then return true end
    for _, path in ipairs(mp.get_property_native('options/scripts', {}) or {}) do
        path=tostring(path)
        if path:match('[/\\]uosc[/\\]?$') or path:match('[/\\]uosc[/\\]main%.lua$')
                or path:match('[/\\]uosc%.lua$') then return true end
    end
    return false
end
local function menu_open()
    return mp.get_property_native('user-data/mpv/console/open') == true
        or mp.get_property_native('user-data/mpv/context-menu/open') == true
        or mp.get_property_native('user-data/uosc/menu/type') ~= nil
end
local function time_string(value)
    local seconds = math.floor(safe_number(value, 0, 0, 359999))
    return string.format('%02d:%02d:%02d', math.floor(seconds/3600), math.floor(seconds/60)%60, seconds%60)
end
local function line(text, color, x, y, size)
    return string.format('{\\an7\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\bord1.2\\shad1\\1c&H%s&\\3c&H171717&}%s',
        x,y,'sans-serif',size,color,escape(text))
end
local function clear_events()
    chats, playback, notices, seen, seen_order = {}, nil, {}, {}, {}
end
local function trim_events()
    local now, changed = mp.get_time(), false
    while chats[1] and chats[1].expires <= now do table.remove(chats,1); changed=true end
    while notices[1] and notices[1].expires <= now do table.remove(notices,1); changed=true end
    if playback and playback.expires <= now then playback=nil; changed=true end
    return changed
end
local function publish_geometry()
    -- Public geometry allows other UI scripts to avoid these small hit regions.
    mp.set_property_native('user-data/splay-overlay', {visible=visible,
        width=width,height=height,buttons=visible and rectangles or {},
        integrated=integrated,popup_open=popup_open,popup=popup_open and popup or nil,
        rows=popup_open and menu_rows or {},enabled=state.enabled==true,
        chat_count=#chats,playback_active=playback ~= nil,status_enabled=cfg.status_osd,
        notification_count=notification_count,room_panel_visible=panel_visible,
        room_panel=panel_visible and panel_geometry or nil,room_rows=panel_visible and panel_rows or {},
        chat_available=chat_available(),chat_button=visible and rectangles[2] or nil,
        status_shown=state.enabled==true and cfg.status_osd and (panel_visible or notification_count>0)})
end
redraw = function()
    width, height = mp.get_osd_size()
    if not width or width <= 0 or height <= 0 then status:remove(); return end
    scale = math.max(0.65, math.min(1.6, height/720))
    status.res_x, status.res_y = width, height
    local size = safe_number(cfg.overlay_font_size,22,12,40)*scale
    local margin, y, rows = 22*scale, 22*scale, {}
    -- Soft wrapping and bounded rows keep long names/chat within the viewport.
    local panel_width=math.min(360*scale,width*.44)
    local columns = math.max(4, math.floor((width-panel_width-3*margin)/size))
    local function add(value, tint, max_rows)
        local row, n, count = {}, 0, 0
        for _,cp in ipairs(graphemes(value)) do
            row[#row+1], n = cp, n+1
            if n >= columns then
                count=count+1
                rows[#rows+1]=line(table.concat(row)..(count>=max_rows and '…' or ''),tint,margin,y,size)
                y=y+size*1.35; row={}; n=0
                if count>=max_rows then return end
            end
        end
        if #row>0 then rows[#rows+1]=line(table.concat(row),tint,margin,y,size); y=y+size*1.35 end
    end
    panel_visible=room_visible(); panel_rows={}; panel_geometry=nil
    notification_count=#chats+#notices+(playback and 1 or 0)
    if cfg.status_osd and state.enabled==true then
        if playback then add(playback.text,'FFFF75',2) end
        for _,item in ipairs(notices) do
            if y+size*2.7>height*.62 then break end
            add(item.text,'BBBBBB',2)
        end
        for _, item in ipairs(chats) do
            if y+size*2.7 > height*0.62 then break end
            add(item.text,'FFFFFF',2)
        end
        if panel_visible then
            local px,py=width-margin-panel_width,margin
            local psize=size*.83
            local max_chars=math.max(4,math.floor(panel_width/psize)-1)
            local max_y=height*.56
            local function member_line(text,tint,kind,username)
                if py+psize*1.4>max_y then return false end
                text=plain(text,max_chars)
                rows[#rows+1]=line(text,tint,px,py,psize)
                panel_rows[#panel_rows+1]={text=text,color=tint,kind=kind,username=username}
                py=py+psize*1.4
                return true
            end
            member_line('房间 · '..plain(state.room,64),'FFFFFF','room')
            local members={}
            for _,member in ipairs(state.members or {}) do
                if type(member)=='table' and (member.room==nil or member.room==state.room) then members[#members+1]=member end
            end
            local playlist=type(state.playlist)=='table' and state.playlist or nil
            local reserve=playlist and type(playlist.files)=='table' and #playlist.files>0 and psize*2.8 or 0
            local shown=0
            for _,member in ipairs(members) do
                if py+psize*4.2+reserve>max_y then break end
                local tint=member.ready==true and '80E692' or member.ready==false and '7777FF' or '999999'
                member_line((member.ready==true and '● ' or member.ready==false and '● ' or '○ ')..plain(member.username,40),tint,'member',member.username)
                local file=type(member.file)=='table' and member.file.name or nil
                if member.username==state.username and type(state.local_file)=='string' and state.local_file~='' then file=state.local_file end
                member_line('  '..(type(file)=='string' and file~='' and file or '尚未载入文件'),'BBBBBB','file',member.username)
                shown=shown+1
            end
            if shown<#members then member_line('… 另有 '..(#members-shown)..' 位成员','999999','more') end
            if #members==0 then member_line('等待房间成员','999999','empty') end
            if playlist and type(playlist.files)=='table' and #playlist.files>0 then
                local index=tonumber(playlist.index)
                local current=index and index>=0 and index<#playlist.files and math.floor(index)+1 or nil
                member_line('共享列表 · '..(current and current..' / ' or '')..#playlist.files..' 项','BBBBBB','playlist')
                if current then member_line('  '..playlist_label(playlist.files[current]),'BBBBBB','playlist-file') end
            end
            panel_geometry={x1=px,y1=margin,x2=width-margin,y2=py}
        end
        if #rows>0 then status.data=table.concat(rows,'\n'); status:update() else status:remove() end
    else status:remove() end
    publish_geometry()
end
local function uosc_scale()
    return safe_number(mp.get_property_native('display-hidpi-scale',1),1,.5,4)
        *safe_number(mp.get_property_native('fullscreen',false) and uosc_cfg.scale_fullscreen or uosc_cfg.scale,1,.5,3)
end
local function controls_top()
    if is_uosc() then
        return height-(safe_number(uosc_cfg.timeline_size,40,0,200)
            +safe_number(uosc_cfg.controls_size,32,8,100)
            +safe_number(uosc_cfg.controls_margin,8,0,100)
            +safe_number(uosc_cfg.window_border_size,1,0,30))*uosc_scale()
    end
    local margins=mp.get_property_native('user-data/osc/margins',{})
    local top=height-safe_number(cfg.button_bottom,48,0,500)*scale-28*scale
    if type(margins)=='table' then top=math.min(top,height-safe_number(margins.b,0,0,.8)*height) end
    return top
end
local function point_in(x,y,r)
    return r and x>=r.x1 and x<r.x2 and y>=r.y1 and y<r.y2
end
local function rect(drawing,r,fill,alpha)
    drawing[#drawing+1]=string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f{\\p0}',
        fill,alpha or '00',r.x1,r.y1,r.x2,r.y1,r.x2,r.y2,r.x1,r.y2)
end
local function set_uosc_button()
    if not is_uosc() then return end
    local data={icon='sync',active=state.enabled==true,hide=not cfg.button_enabled,
        command={'script-message-to','splay_overlay','splay-popup'}}
    if not popup_open then data.tooltip='同步播放' end
    mp.commandv('script-message-to','uosc','set-button','splay',utils.format_json(data))
    mp.commandv('script-message-to','uosc','set-button','splay-chat',utils.format_json({
        icon='chat',hide=not chat_available(),tooltip='发送聊天',
        command={'script-message-to','splay','splay-action','chat'}}))
end
-- Read only the keys we need without mp.options warning about every unrelated
-- uosc option. find_config_file honors mpv's selected config directory; runtime
-- script-opts override the file, as they do in uosc. Unknown/empty layouts use
-- our independent icon. The bounded read never executes config text.
local function read_uosc_options()
    for key,value in pairs(uosc_defaults) do uosc_cfg[key]=value end
    local path=mp.find_config_file('script-opts/uosc.conf')
    local file=path and io.open(path,'rb')
    if file then
        local data=file:read(262145); file:close()
        if data and #data<=262144 then
            data=data:gsub('^\239\187\191','')
            for line in data:gmatch('[^\r\n]+') do
                local key,value=line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
                if key and uosc_defaults[key]~=nil then
                    uosc_cfg[key]=type(uosc_defaults[key])=='number' and tonumber(value) or value
                end
            end
        end
    end
    local opts=mp.get_property_native('options/script-opts',{})
    if type(opts)=='table' then
        for key,default in pairs(uosc_defaults) do
            local value=opts['uosc-'..key]
            if value~=nil then uosc_cfg[key]=type(default)=='number' and tonumber(value) or value end
        end
    end
end
-- Only a known, nonempty controls declaration is safe to extend. No config file
-- is edited, and the native option map preserves unrelated scripts' options.
local function restore_controls()
    if installed_controls then
        local opts=mp.get_property_native('options/script-opts',{})
        if type(opts)=='table' and opts['uosc-controls']==installed_controls then
            opts['uosc-controls']=had_controls_override and original_controls_override or nil
            mp.set_property_native('options/script-opts',opts)
        end
    end
    installed_controls=nil; integrated=false
end
local function insert_control(controls)
    -- Commas in <dispositions> are not control separators.
    local tokens, token, depth={},'',0
    for c in controls:gmatch('.') do
        if c=='<' then depth=depth+1 elseif c=='>' then depth=math.max(0,depth-1) end
        if c==',' and depth==0 then tokens[#tokens+1]=token; token='' else token=token..c end
    end
    tokens[#tokens+1]=token
    local clean={}
    for _,t in ipairs(tokens) do
        local name=t:gsub('^%s*<[^>]*>',''):match('^%s*button:([^?#%s]+)')
        if name~='splay' and name~='splay-chat' then clean[#clean+1]=t end
    end
    tokens=clean
    local speed, insertion
    for i,t in ipairs(tokens) do
        local kind=t:gsub('^%s*<[^>]*>',''):match('^%s*([^:?#]+)')
        if kind=='speed' then speed=i end
        if speed and i>speed and kind=='space' then insertion=i+1; break end
    end
    local at=insertion or (#tokens+1)
    table.insert(tokens,at,'button:splay')
    if chat_available() then table.insert(tokens,at+1,'button:splay-chat') end
    return table.concat(tokens,',')
end
integrate_uosc=function()
    read_uosc_options()
    if not is_uosc() or not cfg.button_enabled then restore_controls(); set_uosc_button(); return end
    local controls=uosc_cfg.controls
    if installed_controls and controls==installed_controls then controls=base_controls end
    if type(controls)~='string' or controls=='' or controls=='never' then
        integrated=false; return
    end
    local opts=mp.get_property_native('options/script-opts',{})
    if type(opts)~='table' then integrated=false; return end
    local next_controls=insert_control(controls)
    if opts['uosc-controls']~=next_controls then
        if not installed_controls or opts['uosc-controls']~=installed_controls then
            original_controls_override=opts['uosc-controls']
            had_controls_override=original_controls_override~=nil
            base_controls=controls
        end
        installed_controls=next_controls
        opts['uosc-controls']=next_controls
        mp.set_property_native('options/script-opts',opts)
    end
    integrated=true
    set_uosc_button()
end
close_popup=function()
    popup_open=false; popup=nil; menu_rows={}
    set_uosc_button()
    mp.disable_key_bindings(escape_section)
    if update_buttons then update_buttons() end
end
local function toggle_popup()
    if not cfg.button_enabled or menu_open() then return end
    if popup_open then close_popup(); return end
    local mouse=mp.get_property_native('mouse-pos',{})
    local r=rectangles[1]
    anchor={x=mouse.hover and mouse.x or (r and (r.x1+r.x2)/2) or width/2,
        y=mouse.hover and mouse.y or (r and r.y1) or height-80*scale}
    popup_open=true
    set_uosc_button()
    mp.enable_key_bindings(escape_section)
    update_buttons()
end
-- Route one dismissed outside click to the currently active original binding.
-- Script owners receive ordinary mouse down/up notifications; input.conf
-- commands run once. Reinjecting a physical key would synthesize double-clicks
-- and lose the drag/down event expected by native OSC and uosc timelines.
local function forward_click()
    local active
    for _,binding in ipairs(mp.get_property_native('input-bindings',{}) or {}) do
        if tostring(binding.key):upper()=='MBTN_LEFT' and binding.owner~='splay_overlay'
                and type(binding.priority)=='number' and binding.priority>=0
                and (not active or binding.priority>active.priority) then active=binding end
    end
    if not active or type(active.cmd)~='string' then return end
    local name=active.cmd:match('^script%-binding%s+[^/]+/(.+)$')
    if active.owner and name then
        mp.commandv('script-message-to',active.owner,'key-binding',name,'dm','MBTN_LEFT')
        mp.commandv('script-message-to',active.owner,'key-binding',name,'um','MBTN_LEFT')
    else mp.command(active.cmd) end
end
local function click()
    local mouse=mp.get_property_native('mouse-pos',{})
    local x,y=mouse.x or -1,mouse.y or -1
    if menu_open() then close_popup(); return end
    if visible and chat_available() and point_in(x,y,rectangles[2]) then send('splay-action','chat'); return end
    if popup_open then
        for _,r in ipairs(menu_rows) do
            if point_in(x,y,r) then
                if r.selectable then
                    -- Main closes this popup before showing a submenu. The
                    -- enable toggle keeps it open and replaces its live model.
                    send('splay-action',r.value)
                end
                return
            end
        end
        if point_in(x,y,popup) then return end
        close_popup()
        -- Outside clicks dismiss and are routed once through the normal mpv
        -- bindings. Disable our section first to avoid recursive interception.
        mp.disable_key_bindings(section)
        forward_click()
        return
    end
    if visible then
        if point_in(x,y,rectangles[2]) and chat_available() then send('splay-action','chat')
        elseif point_in(x,y,rectangles[1]) then toggle_popup() end
    end
end
mp.set_key_bindings({{'MBTN_LEFT',click}},section,'force')
mp.set_key_bindings({{'ESC',close_popup}},escape_section,'force')
mp.disable_key_bindings(section)
mp.disable_key_bindings(escape_section)
update_buttons=function()
    width,height=mp.get_osd_size()
    if not width or width<=0 or height<=0 then return end
    scale=math.max(0.65,math.min(1.6,height/720))
    local mouse=mp.get_property_native('mouse-pos',{})
    local x,y=mouse.x or -1,mouse.y or -1
    local now=mp.get_time()
    if menu_open() or not cfg.button_enabled then
        popup_open=false; popup=nil; menu_rows={}
        mp.disable_key_bindings(escape_section)
    end
    rectangles={}
    local drawing={}
    visible=false
    if cfg.button_enabled and not menu_open() and not integrated then
        local margins=mp.get_property_native('user-data/osc/margins',{})
        local bottom=safe_number(cfg.button_bottom,48,0,500)*scale
        if type(margins)=='table' then
            bottom=math.max(bottom,safe_number(margins.b,0,0,0.8)*height+8*scale)
        end
        if is_uosc() then
            local ui_scale=uosc_scale()
            bottom=math.max(bottom,(safe_number(uosc_cfg.timeline_size,40,0,200)
                +safe_number(uosc_cfg.controls_size,32,8,100)+safe_number(uosc_cfg.controls_margin,8,0,100)+8)*ui_scale)
        end
        local size=28*scale
        local y2=math.max(size+8,math.min(height-8,height-bottom))
        local x2=math.max(size+8,math.min(width-8,width-safe_number(cfg.button_right,22,8,1000)*scale))
        local r={x1=x2-size,y1=y2-size,x2=x2,y2=y2,action='popup'}
        rectangles[1]=r
        if chat_available() then rectangles[2]={x1=r.x1-size-6*scale,y1=r.y1,x2=r.x1-6*scale,y2=r.y2,action='chat'} end
        hovering=mouse.hover and (point_in(x,y,r) or point_in(x,y,rectangles[2]))
        if mouse.hover and y>=r.y1-24*scale then last_near=now end
        visible=popup_open or (mouse.hover and (hovering or now-last_near<=1.25))
        if visible then
            rect(drawing,r,hovering and '504232' or '262626','28')
            drawing[#drawing+1]=string.format('{\\an5\\pos(%.1f,%.1f)\\fnsans-serif\\fs%.1f\\bord0\\shad0\\1c&H%s&}⇄',
                (r.x1+r.x2)/2,(r.y1+r.y2)/2,21*scale,state.enabled==true and '92E6B0' or 'AAAAAA')
            if rectangles[2] then
                local c=rectangles[2]
                rect(drawing,c,point_in(x,y,c) and '504232' or '262626','28')
                -- Draw a small speech bubble in ASS vectors, without relying on
                -- optional icon fonts in the independent mpv interface.
                local cx,cy=(c.x1+c.x2)/2,(c.y1+c.y2)/2
                drawing[#drawing+1]=string.format('{\\an7\\pos(%.1f,%.1f)\\bord0\\shad0\\1c&HBBBBBB&\\p1}m 0 0 l %.1f 0 %.1f %.1f %.1f %.1f 0 %.1f{\\p0}',cx-8*scale,cy-6*scale,16*scale,16*scale,10*scale,5*scale,15*scale,10*scale)
            end
        end
    end
    if popup_open then
        local count=math.min(6,#(menu_model.items or {}))
        local row_height=34*scale
        local pw=math.min(292*scale,width-16)
        local ph=(count*34+38)*scale
        ph=math.min(ph,height-16)
        local ax=anchor and anchor.x or width/2
        local ay=anchor and anchor.y or height-80*scale
        -- Keyboard/programmatic opens may leave the pointer on the timeline.
        -- The popup always ends above the controls, regardless of pointer y.
        local bottom_limit=math.max(16,controls_top()-8*scale)
        if rectangles[1] then bottom_limit=math.min(bottom_limit,rectangles[1].y1-8*scale) end
        ay=math.min(ay,bottom_limit+12*scale)
        ph=math.min(ph,math.max(8,bottom_limit-8))
        local left=math.max(8,math.min(width-pw-8,ax-pw/2))
        local top=math.max(8,math.min(height-ph-8,ay-ph-12*scale))
        popup={x1=left,y1=top,x2=left+pw,y2=top+ph}
        rect(drawing,popup,'222222','08')
        local chars=math.max(6,math.floor((pw-24*scale)/(15*scale)))
        drawing[#drawing+1]=line(plain(menu_model.title or '同步播放',chars),'AAAAAA',left+12*scale,top+9*scale,14*scale)
        menu_rows={}
        for i=1,count do
            local item=menu_model.items[i]
            if type(item)~='table' then item={title=plain(item),selectable=false} end
            local r={x1=left+4*scale,y1=top+34*scale+(i-1)*row_height,
                x2=left+pw-4*scale,y2=math.min(top+34*scale+i*row_height,popup.y2-4*scale),
                value=tostring(item.value or ''),selectable=item.selectable~=false and type(item.value)=='string'}
            if r.y2>r.y1 then
                menu_rows[#menu_rows+1]=r
                if mouse.hover and point_in(x,y,r) and r.selectable then rect(drawing,r,'514332') end
                drawing[#drawing+1]=line(plain(item.title,chars),r.selectable and 'FFFFFF' or '888888',left+12*scale,r.y1+7*scale,16*scale)
            end
        end
        -- Popup owns Escape and clicks only while it is open. Outside clicks
        -- close it and are forwarded once after removing this binding.
        mp.set_mouse_area(0,0,width,height,section)
        mp.enable_key_bindings(section,'allow-hide-cursor')
    elseif visible and hovering then
        local r=point_in(x,y,rectangles[2]) and rectangles[2] or rectangles[1]
        mp.set_mouse_area(r.x1,r.y1,r.x2,r.y2,section)
        mp.enable_key_bindings(section,'allow-hide-cursor')
    else
        mp.disable_key_bindings(section)
        mp.set_mouse_area(0,0,0,0,section)
    end
    if #drawing>0 then
        buttons.res_x,buttons.res_y=width,height
        buttons.data=table.concat(drawing,'\n'); buttons:update()
    else buttons:remove() end
    publish_geometry()
end
mp.observe_property('options/script-opts','native',function() integrate_uosc(); update_buttons() end)
options.read_options(cfg,'splay',function() integrate_uosc(); redraw(); update_buttons() end)
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=parse(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    if value.room~=state.room or (value.connection~='connected' and state.connection=='connected') then clear_events() end
    if value.enabled~=true then clear_events() end
    state=value; trim_events(); integrate_uosc(); set_uosc_button(); redraw(); update_buttons()
end)
mp.register_script_message('splay-event',function(json)
    if type(json)~='string' or #json>16384 or state.enabled~=true then return end
    local value=parse(json)
    if type(value)~='table' or value.schema~=1 or (value.type~='chat' and value.type~='playback' and value.type~='notice') then return end
    if value.type~='notice' and state.connection~='connected' then return end
    if type(value.id)~='string' and type(value.id)~='number' then return end
    if (value.type=='chat' or value.type=='notice') and type(value.text)~='string' then return end
    local id=tostring(value.id)
    if #id>256 or seen[id] then return end
    seen[id]=true; seen_order[#seen_order+1]=id
    if #seen_order>128 then seen[table.remove(seen_order,1)]=nil end
    local user=plain(value.username,40)
    if value.type=='chat' then
        chats[#chats+1]={text='<'..user..'> '..plain(value.text,200),expires=mp.get_time()+safe_number(cfg.overlay_chat_ttl,5,1,120)}
        while #chats>safe_number(cfg.overlay_chat_lines,4,1,10) do table.remove(chats,1) end
    elseif value.type=='notice' then
        local text=plain(value.text,200)
        local now=mp.get_time()
        -- Repeated identical status bursts occupy one bounded slot; all status
        -- messages expire even while the room panel remains visible on pause.
        if notices[#notices] and notices[#notices].text==text and now-notices[#notices].created<.5 then return end
        notices[#notices+1]={text=text,created=now,expires=now+safe_number(cfg.overlay_message_ttl,5,1,120)}
        while #notices>4 do table.remove(notices,1) end
    else
        local action=value.seek==true and '跳转到' or value.paused==true and '暂停于' or value.paused==false and '恢复播放于' or nil
        if not action then return end
        playback={text=user..' '..action..' '..time_string(value.position),expires=mp.get_time()+safe_number(cfg.overlay_message_ttl,5,1,120)}
    end
    redraw()
end)
mp.register_script_message('overlay-toggle-status',function() cfg.status_osd=not cfg.status_osd; redraw() end)
mp.register_script_message('overlay-toggle-buttons',function() cfg.button_enabled=not cfg.button_enabled; integrate_uosc(); update_buttons() end)
mp.register_script_message('uosc-version',function() uosc=true; integrate_uosc(); update_buttons() end)
mp.register_script_message('splay-popup',toggle_popup)
mp.register_script_message('splay-menu-close',close_popup)
mp.register_script_message('splay-menu-model',function(json)
    if type(json)~='string' or #json>32768 then return end
    local value=parse(json)
    if type(value)~='table' or type(value.items)~='table' then return end
    menu_model=value; update_buttons()
end)
for _,property in ipairs({'mouse-pos','osd-dimensions','user-data/osc/margins','user-data/uosc/menu/type',
        'user-data/mpv/console/open','user-data/mpv/context-menu/open'}) do
    mp.observe_property(property,'native',function()
        if property=='mouse-pos' then
            local mouse=mp.get_property_native('mouse-pos',{})
            if mouse.x~=last_mouse.x or mouse.y~=last_mouse.y or mouse.hover~=last_mouse.hover then last_activity=mp.get_time() end
            last_mouse={x=mouse.x,y=mouse.y,hover=mouse.hover}
        end
        if property=='osd-dimensions' and popup_open then close_popup() end
        redraw(); update_buttons()
    end)
end
mp.observe_property('pause','bool',function(_,paused)
    if paused==false then last_activity=mp.get_time() end
    redraw()
end)
for _,property in ipairs({'cursor-autohide','cursor-autohide-fs-only','fullscreen','idle-active'}) do
    mp.observe_property(property,'native',function() redraw() end)
end
mp.add_periodic_timer(0.25,function()
    if trim_events() or panel_visible~=room_visible() then redraw() end
    if visible then update_buttons() end
end)
mp.register_event('shutdown',function()
    restore_controls(); status:remove(); buttons:remove()
    mp.disable_key_bindings(section); mp.disable_key_bindings(escape_section)
    mp.set_property_native('user-data/splay-overlay',nil)
end)
mp.add_timeout(0,function() integrate_uosc(); redraw(); update_buttons(); send('splay-overlay-ready') end)
