-- Optional presentation only. Protocol state and commands belong to splay.lua.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local cfg = {status_osd=true, button_enabled=true, button_bottom=85,
    overlay_font_size=22, overlay_chat_ttl=12, overlay_chat_lines=4}
local state = {connection='disconnected', members={}}
local chats, playback, seen, seen_order = {}, nil, {}, {}
local status = mp.create_osd_overlay('ass-events')
local buttons = mp.create_osd_overlay('ass-events')
status.z, buttons.z = 25, 40
local width, height, scale, rectangles = 0, 0, 1, {}
local visible, hovering, last_near, uosc = false, false, -100, false
local section = 'splay-overlay-buttons'
local redraw, update_buttons

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
        if tostring(path):match('[/\\]uosc[/\\]?') then return true end
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
local function readiness()
    if state.connection ~= 'connected' then
        if state.connection=='error' then return 'splay · 连接错误：'..plain(state.error,120), '7777FF' end
        return ({connecting='splay · 连接中…',error='splay · 连接错误',disconnected='splay · 未连接'})[state.connection] or 'splay · 未连接', '7777FF'
    end
    local names, total = {}, 0
    for _, member in ipairs(state.members or {}) do
        if type(member)=='table' and (member.room == state.room or member.room == nil) then
            total=total+1
            if member.ready ~= true then
                names[#names+1]=plain(member.username, 28)..(member.ready == nil and '（状态未知）' or '')
            end
        end
    end
    if #names > 0 then return '未准备：'..table.concat(names, '、'), '7777FF' end
    if total == 0 then return '准备状态未知 · 等待房间成员', '7777FF' end
    return '全部 '..total..' 人已准备', '80E692'
end
local function line(text, color, x, y, size)
    return string.format('{\\an7\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\bord1.2\\shad1\\1c&H%s&\\3c&H171717&}%s',
        x,y,'sans-serif',size,color,escape(text))
end
local function clear_events()
    chats, playback, seen, seen_order = {}, nil, {}, {}
end
local function trim_events()
    local now, changed = mp.get_time(), false
    while chats[1] and chats[1].expires <= now do table.remove(chats,1); changed=true end
    if playback and playback.expires <= now then playback=nil; changed=true end
    return changed
end
local function publish_geometry()
    -- Public geometry allows other UI scripts to avoid these small hit regions.
    mp.set_property_native('user-data/splay-overlay', {visible=visible,
        width=width,height=height,buttons=visible and rectangles or {},
        chat_count=#chats,playback_active=playback ~= nil,status_enabled=cfg.status_osd})
end
redraw = function()
    width, height = mp.get_osd_size()
    if not width or width <= 0 or height <= 0 then status:remove(); return end
    scale = math.max(0.65, math.min(1.6, height/720))
    status.res_x, status.res_y = width, height
    local text, color = readiness()
    local size = safe_number(cfg.overlay_font_size,22,12,40)*scale
    local margin, y, rows = 22*scale, 22*scale, {}
    -- Soft wrapping and bounded rows keep long names/chat within the viewport.
    local columns = math.max(12, math.floor((width-2*margin)/(size*0.82)))
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
    if cfg.status_osd then
        add(text,color,2)
        if playback then add(playback.text,'FFFF75',2) end
        for _, item in ipairs(chats) do
            if y+size*2.7 > height*0.62 then break end
            add(item.text,'FFFFFF',2)
        end
        status.data=table.concat(rows,'\n'); status:update()
    else status:remove() end
    publish_geometry()
end
local function disable_buttons()
    visible=false; hovering=false
    mp.disable_key_bindings(section)
    mp.set_mouse_area(0,0,0,0,section)
    buttons:remove()
    publish_geometry()
end
local function point_in(x,y,r)
    return x>=r.x1 and x<r.x2 and y>=r.y1 and y<r.y2
end
local function click()
    if not visible or menu_open() then return end
    local mouse=mp.get_property_native('mouse-pos',{})
    for _, r in ipairs(rectangles) do
        if mouse.hover and point_in(mouse.x or -1,mouse.y or -1,r) then
            if r.action=='panel' then send('splay-open',is_uosc() and 'uosc' or 'native')
            elseif r.action=='ready' and state.connection=='connected' then
                send('splay-command',utils.format_json({action='ready',ready=state.ready ~= true}))
            elseif r.action=='chat' and state.connection=='connected' and state.chat_supported ~= false then send('splay-chat') end
            return
        end
    end
end
-- The section is enabled only inside the visible row, and its mouse area never
-- includes the timeline. No global forced MBTN_LEFT binding is installed.
mp.set_key_bindings({{'MBTN_LEFT',click}},section,'force')
mp.disable_key_bindings(section)
update_buttons = function()
    width,height=mp.get_osd_size()
    if not width or width <= 0 or height <= 0 or not cfg.button_enabled or menu_open() then disable_buttons(); return end
    scale=math.max(0.65,math.min(1.6,height/720))
    local mouse=mp.get_property_native('mouse-pos',{})
    local now=mp.get_time()
    local bottom=safe_number(cfg.button_bottom,85,0,500)*scale
    if is_uosc() then bottom=math.max(bottom,110*scale) end
    -- uosc/OSC standard geometry is normalized to the real window dimensions.
    local margins=mp.get_property_native('user-data/osc/margins',{})
    if type(margins)=='table' then bottom=math.max(bottom,safe_number(margins.b,0,0,0.8)*height+12*scale) end
    local row_height=36*scale
    bottom=math.min(bottom, math.max(0,height-row_height-8*scale))
    local y2=height-bottom
    local widths={132*scale,112*scale,100*scale}
    local gap=6*scale
    local total=widths[1]+widths[2]+widths[3]+2*gap
    if total > width-16 then
        local shrink=math.max(0.1,(width-16)/total)
        for i=1,3 do widths[i]=widths[i]*shrink end
        gap=gap*shrink; total=width-16
    end
    local x=(width-total)/2
    local connected=state.connection=='connected'
    local entries={{'同步 · '..(connected and '已连接' or state.connection=='connecting' and '连接中' or '未连接'),'panel'},
        {state.ready==true and '✓ 已准备' or '○ 准备','ready'}, {'聊天','chat'}}
    rectangles={}
    for i,item in ipairs(entries) do
        rectangles[i]={x1=x,y1=y2-row_height,x2=x+widths[i],y2=y2,action=item[2]}
        x=x+widths[i]+gap
    end
    hovering=false
    if mouse.hover then
        for _,r in ipairs(rectangles) do if point_in(mouse.x or -1,mouse.y or -1,r) then hovering=true end end
        if (mouse.y or -1)>=y2-row_height-24*scale then last_near=now end
    end
    if not mouse.hover or (not hovering and now-last_near>1.25) then disable_buttons(); return end
    visible=true
    buttons.res_x,buttons.res_y=width,height
    local drawing={}
    for i,r in ipairs(rectangles) do
        local enabled=i==1 or (connected and (i~=3 or state.chat_supported~=false))
        local over=mouse.hover and point_in(mouse.x or -1,mouse.y or -1,r)
        local fill=over and enabled and '604D32' or '292929'
        drawing[#drawing+1]=string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H20&\\p1}m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f{\\p0}',fill,r.x1,r.y1,r.x2,r.y1,r.x2,r.y2,r.x1,r.y2)
        drawing[#drawing+1]=string.format('{\\an5\\pos(%.1f,%.1f)\\fnsans-serif\\fs%.1f\\bord0\\shad0\\1c&H%s&}%s',
            (r.x1+r.x2)/2,(r.y1+r.y2)/2,16*scale,enabled and 'FFFFFF' or '888888',escape(entries[i][1]))
    end
    buttons.data=table.concat(drawing,'\n'); buttons:update()
    -- Re-enable on entering the row so it takes precedence over uosc only there.
    mp.set_mouse_area(rectangles[1].x1,rectangles[1].y1,rectangles[3].x2,y2,section)
    if hovering then mp.enable_key_bindings(section,'allow-hide-cursor') else mp.disable_key_bindings(section) end
    publish_geometry()
end
options.read_options(cfg,'splay',function() redraw(); update_buttons() end)
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=parse(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    if value.room~=state.room or (value.connection~='connected' and state.connection=='connected') then clear_events() end
    state=value; trim_events(); redraw(); update_buttons()
end)
mp.register_script_message('splay-event',function(json)
    if type(json)~='string' or #json>16384 or state.connection~='connected' then return end
    local value=parse(json)
    if type(value)~='table' or value.schema~=1 or (value.type~='chat' and value.type~='playback') then return end
    if type(value.id)~='string' and type(value.id)~='number' then return end
    if value.type=='chat' and type(value.text)~='string' then return end
    local id=tostring(value.id)
    if #id>256 or seen[id] then return end
    seen[id]=true; seen_order[#seen_order+1]=id
    if #seen_order>128 then seen[table.remove(seen_order,1)]=nil end
    local user=plain(value.username,40)
    if value.type=='chat' then
        chats[#chats+1]={text='<'..user..'> '..plain(value.text,200),expires=mp.get_time()+safe_number(cfg.overlay_chat_ttl,12,1,120)}
        while #chats>safe_number(cfg.overlay_chat_lines,4,1,10) do table.remove(chats,1) end
    else
        local action=value.seek==true and '跳转到' or value.paused==true and '暂停于' or value.paused==false and '恢复播放于' or nil
        if not action then return end
        playback={text=user..' '..action..' '..time_string(value.position),expires=mp.get_time()+5}
    end
    redraw()
end)
mp.register_script_message('overlay-toggle-status',function() cfg.status_osd=not cfg.status_osd; redraw() end)
mp.register_script_message('overlay-toggle-buttons',function() cfg.button_enabled=not cfg.button_enabled; update_buttons() end)
mp.register_script_message('uosc-version',function() uosc=true; update_buttons() end)
for _,property in ipairs({'mouse-pos','osd-dimensions','user-data/osc/margins','user-data/uosc/menu/type',
        'user-data/mpv/console/open','user-data/mpv/context-menu/open'}) do
    mp.observe_property(property,'native',function() redraw(); update_buttons() end)
end
mp.add_periodic_timer(0.25,function() if trim_events() then redraw() end; if visible then update_buttons() end end)
mp.register_event('shutdown',function() status:remove(); disable_buttons(); mp.set_property_native('user-data/splay-overlay',nil) end)
mp.add_timeout(0,function() redraw(); send('splay-overlay-ready') end)
