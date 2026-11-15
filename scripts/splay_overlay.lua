-- Optional presentation only. Protocol state and commands belong to splay.lua.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local msg = require 'mp.msg'
local cfg = {status_osd=true, button_enabled=true, button_bottom=48, button_right=22,
    overlay_font_size=22, danmaku_font_scale=1.15, overlay_chat_ttl=5, overlay_chat_lines=4,
    overlay_message_ttl=5, room_panel=true, room_idle_timeout=3, chat_mode='room',danmaku_smooth=false}
local state = {enabled=false, connection='disconnected', members={}}
-- Round-trip times arrive in their own splay-latency message, not in the state.
local latency = {enabled=false, members={}}
local chats, playback, notices, seen, seen_order = {}, nil, {}, {}, {}
local status = mp.create_osd_overlay('ass-events')
local buttons = mp.create_osd_overlay('ass-events')
local scrolling = mp.create_osd_overlay('ass-events')
local measuring = mp.create_osd_overlay('ass-events')
measuring.hidden,measuring.compute_bounds=true,true
status.z, scrolling.z, buttons.z = 25, 24, 40
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
local danmaku, console_open = {}, false
local RTT_GOOD_MS, RTT_FAIR_MS, RTT_MAX_MS = 100, 250, 10000
local CHAT_NICK_COLORS = {'7CC8FF','97DC9A','E4B2FF','82DAD9','A9C5FF','A4D7FA',
    'FFB8CB','B5E7FF','BAF0CF','F6B5EA','FFD09D','DCF0A3','F1D2FF','B5FFE2',
    'A3E8F4','FFABC0','D2B0FF','8EF0BC','FFDEA6','C5CFFF','EBA8D4','A7F0EA','D6E89B','ECC4B4'}
local DANMAKU_MAX_LANES = 6
local animation_timer, schedule_animation
local animation_epoch, animation_period, animation_frame = nil, 1/60, -1
local scrolling_data
local measured_widths,measured_order,fitted_titles,fitted_order={},{},{},{}
local measurement_view,measurement_supported=nil,true
local smooth_owned,smooth_fps,smooth_requested,smooth_blocked=nil,nil,false,false
local smooth_loading,smooth_stopping=false,false
local SMOOTH_LABEL='splay-chat-fps'
local danmaku_width, danmaku_height = 0, 0
local chat_tokens, chat_token_time = 6, mp.get_time()
local function normalize_chat_mode(value)
    return value=='danmaku' and 'danmaku' or 'room'
end
local function chat_available()
    return cfg.button_enabled and state.enabled==true and state.connection=='connected' and state.chat_supported==true
end
-- mpv exposes cursor-autohide and mouse-pos, but no cursor-hidden property
-- (checked against the target player and upstream input.rst). Follow its
-- configured idle policy without changing cursor options or input ownership.
local function room_visible()
    if console_open or not cfg.status_osd or not cfg.room_panel or state.enabled~=true or state.connection~='connected' then return false end
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
-- Approximate font advance in ems, rather than treating ASCII like Han text.
-- Keep the same grapheme boundaries for measuring, clipping and wrapping.
local function text_units(text)
    local total=0
    for _,cp in ipairs(graphemes(text)) do
        local a=cp:byte()
        if a and a<128 then
            total=total+(cp:match('[ ilI.,:;!|\'`]') and .32 or cp:match('[MW@%%]') and .9 or .6)
        elseif a==194 or a==195 then total=total+.65
        else total=total+1 end
    end
    return total
end
local function fit_text(value,units,keep_tail)
    local text=plain(value,2048)
    if text_units(text)<=units then return text,false end
    if units<1 then return '',true end
    local groups=graphemes(text)
    local head,tail={},{}
    local available=math.max(0,units-1)
    if keep_tail then
        local used=0
        for i=#groups,1,-1 do
            local advance=text_units(groups[i])
            if used+advance>available*.35 then break end
            table.insert(tail,1,groups[i]);used=used+advance
        end
        available=available-used
    end
    local used=0
    for _,cp in ipairs(groups) do
        local advance=text_units(cp)
        if used+advance>available then break end
        head[#head+1]=cp;used=used+advance
    end
    return table.concat(head)..'…'..table.concat(tail),true
end
local function wrap_text(value,units,max_rows,keep_tail)
    local remaining=plain(value,2048)
    local result={}
    for i=1,max_rows do
        if i==max_rows or text_units(remaining)<=units then
            local final,clipped=fit_text(remaining,units,keep_tail)
            result[#result+1]=final
            return result,clipped
        end
        local row,used,consumed={},0,0
        for _,cp in ipairs(graphemes(remaining)) do
            local advance=text_units(cp)
            if used+advance>units and #row>0 then break end
            row[#row+1]=cp;used=used+advance;consumed=consumed+#cp
        end
        result[#result+1]=table.concat(row)
        remaining=remaining:sub(consumed+1)
    end
    return result,false
end
local function playlist_label(value)
    local text=tostring(value or ''):gsub('[%c]',' ')
    if text:match('^%s*$') or text:lower():match('^%s*%**hidden filename%**%s*$') then return '名称未提供' end
    local scheme=text:match('([%a][%w+.-]*)://')
    if scheme then
        -- Never display an authority, credentials or parameters, even for
        -- non-HTTP schemes. The original source stays intact in state.
        return '网络媒体（名称未提供）'
    end
    if text:match('^%s*[%a][%w+.-]*:') and not text:match('^%a:[/\\]') then return '网络媒体（名称未提供）' end
    local basename=text:match('([^/\\]+)[/\\]*$')
    if not basename or basename:lower():match('^%s*%**hidden filename%**%s*$') then return '名称未提供' end
    return basename
end
local function positive_duration(value)
    return type(value)=='number' and value==value and value>0 and value<math.huge and value or nil
end
local function autostart_countdown()
    local value=type(state.autostart)=='table' and state.autostart or {}
    local remaining=value.remaining
    if state.connection~='connected' or value.enabled~=true or value.pending~=true or
        type(remaining)~='number' or remaining~=remaining or remaining<0 or remaining>30 then return nil end
    return math.ceil(remaining)
end
local function duration_difference(value)
    if type(value)~='number' or value~=value or value<=-math.huge or value>=math.huge then return nil end
    if value==0 then return nil end
    local amount=math.abs(value)
    local text=amount>=1e6 and string.format('%.3g',amount) or
        (string.format('%.6f',amount):gsub('0+$',''):gsub('%.$',''))
    if text=='0' then text='<0.000001' end
    return '对方'..(value>0 and '长' or '短')..text..'秒'
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
local function smooth_notice(text)
    msg.warn(text)
    if not smooth_stopping then
        send('splay-notice',utils.format_json({schema=1,text=text,category='warning'}))
    end
end
local function smooth_filter()
    local filters=mp.get_property_native('vf')
    if type(filters)~='table' then return nil,-1 end
    local found,count=nil,0
    for _,filter in ipairs(filters) do
        if type(filter)=='table' and filter.label==SMOOTH_LABEL then found=filter;count=count+1 end
    end
    return found,count
end
-- Compare our recorded node, including parameters, instead of claiming a tag
-- that another script or the user has since replaced. Native vf nodes are
-- shallow data; bound recursion even if an unexpected property is supplied.
local function same_filter(a,b,depth)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    if (depth or 0)>=5 then return false end
    for key,value in pairs(a) do if not same_filter(value,b[key],(depth or 0)+1) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function remove_smooth_filter()
    if not smooth_owned then return true end
    local current,count=smooth_filter()
    if count==0 then smooth_owned,smooth_fps=nil,nil;return true end
    if count~=1 or not same_filter(smooth_owned,current) then
        smooth_owned,smooth_fps=nil,nil;smooth_blocked=true
        smooth_notice('平滑弹幕滤镜已被外部修改，未改动现有滤镜；可关闭后重新开启重试。')
        return false
    end
    local ok,result=pcall(mp.commandv,'vf','remove','@'..SMOOTH_LABEL)
    local _,remaining=smooth_filter()
    if ok and result and remaining==0 then smooth_owned,smooth_fps=nil,nil;return true end
    smooth_blocked=true
    smooth_notice('未能撤销平滑弹幕滤镜；现有其他滤镜未改动，请关闭后重新开启重试。')
    return false
end
local function update_smooth_filter()
    local video=mp.get_property_native('video-params')
    local vid=tonumber(mp.get_property_native('vid'))
    local wanted=not smooth_stopping and not smooth_loading and cfg.danmaku_smooth==true and
        state.enabled==true and state.connection=='connected' and normalize_chat_mode(cfg.chat_mode)=='danmaku' and
        not mp.get_property_native('idle-active',false) and vid and vid>0 and
        type(video)=='table' and type(video.w)=='number' and video.w>0
    wanted=not not wanted
    if wanted~=smooth_requested then smooth_requested=wanted;smooth_blocked=false end
    if not wanted then
        if smooth_owned and not smooth_blocked then remove_smooth_filter() end
        return
    end
    local current,count=smooth_filter()
    if smooth_owned then
        if count~=1 or not same_filter(smooth_owned,current) then
            smooth_owned,smooth_fps=nil,nil;smooth_blocked=true
            smooth_notice('平滑弹幕滤镜已失效，已回到普通弹幕；关闭后重新开启可重试。')
        end
        return
    end
    if smooth_blocked then return end
    if count~=0 then
        smooth_blocked=true
        smooth_notice(count<0 and '无法读取视频滤镜，使用普通弹幕；关闭后重新开启可重试。' or
            '平滑弹幕标签已被占用，使用普通弹幕；未改动现有滤镜。')
        return
    end
    local fps=tonumber(mp.get_property_native('display-fps'))
    if not fps or fps~=fps or fps<20 or fps>1000 then fps=60 end
    fps=math.min(60,fps)
    local source_fps=tonumber(mp.get_property_native('estimated-vf-fps')) or
        tonumber(mp.get_property_native('container-fps'))
    -- Wait for usable video timing rather than guessing and accidentally
    -- reducing an already high-frame-rate source. Timing observers retry.
    if not source_fps or source_fps~=source_fps or source_fps<=0 or source_fps==math.huge then return end
    if source_fps>=fps-.5 then return end
    -- Normal playback composites OSD at video-output cadence. The optional
    -- fps filter provides output frames for smoother OSD, as upstream
    -- uosc_danmaku does. It duplicates frames; it is not interpolation.
    -- Only append/remove this owned label; never replace vf or change sync.
    local ok,result=pcall(mp.commandv,'vf','append',string.format('@%s:fps=fps=%.3f',SMOOTH_LABEL,fps))
    current,count=smooth_filter()
    if ok and result and count==1 then
        smooth_owned,smooth_fps=current,fps
    else
        -- A failed backend/hwdec initialization may leave our appended node.
        -- Its tag was absent before our command, so remove just that node.
        if count==1 then smooth_owned=current;remove_smooth_filter() end
        smooth_blocked=true
        smooth_notice('当前播放器或硬件解码无法启用平滑弹幕，使用普通弹幕；关闭后重新开启可重试。')
    end
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
    return console_open or mp.get_property_native('user-data/mpv/console/open') == true
        or mp.get_property_native('user-data/mpv/context-menu/open') == true
        or mp.get_property_native('user-data/uosc/menu/type') ~= nil
end
local function time_string(value)
    local seconds = math.floor(safe_number(value, 0, 0, 359999))
    return string.format('%02d:%02d:%02d', math.floor(seconds/3600), math.floor(seconds/60)%60, seconds%60)
end
local function line(text, color, x, y, size, alignment)
    return string.format('{\\an%d\\q2\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\bord1.2\\shad1\\1c&H%s&\\3c&H171717&}%s',
        alignment or 7,x,y,'sans-serif',size,color,escape(text))
end
-- Bounds render and flush libass caches, so never measure from animation
-- frames. Only room/title layout calls this; bounded caches reuse the result
-- until the title, font size or viewport changes. Hidden means no visible
-- measuring text, while its style and coordinate system match the real row.
local function measurement_key(text,size)
    local view=string.format('%d:%d',math.floor(width),math.floor(height))
    if view~=measurement_view then
        measured_widths,measured_order,fitted_titles,fitted_order={},{},{},{}
        measurement_view=view
    end
    return string.format('%.1f:',size)..text
end
local function cache_value(cache,order,key,value,limit)
    if cache[key]==nil then order[#order+1]=key end
    cache[key]=value
    while #order>limit do cache[table.remove(order,1)]=nil end
    return value
end
local function measured_width(text,size)
    local key=measurement_key(text,size)
    if measured_widths[key]~=nil then return measured_widths[key] end
    if text=='' then return 0 end
    local pixels
    if measurement_supported and width>0 and height>0 then
        measuring.res_x,measuring.res_y=width,height
        measuring.data=line(text,'FFFFFF',8,8,size)
        local ok,bounds=pcall(function() return measuring:update() end)
        if ok and type(bounds)=='table' and type(bounds.x1)=='number' then
            -- x1 includes the right bearing, outline and shadow relative to
            -- the text anchor, rather than guessing advances from character
            -- categories. A clipped long result still exceeds panel width.
            pixels=math.max(0,bounds.x1-8)
        elseif not ok or bounds==nil then measurement_supported=false end
    end
    return cache_value(measured_widths,measured_order,key,pixels or text_units(text)*size,512)
end
local function fit_title_pixels(value,pixels,size)
    local text=plain(value,2048)
    local key=measurement_key(text,size)..string.format(':%.1f',pixels)
    if fitted_titles[key]~=nil then return fitted_titles[key] end
    local result=text
    if measured_width(text,size)>pixels then
        local groups=graphemes(text)
        local low,high=0,#groups
        while low<high do
            local middle=math.floor((low+high+1)/2)
            local candidate=table.concat(groups,'',1,middle)..'…'
            if measured_width(candidate,size)<=pixels then low=middle else high=middle-1 end
        end
        result=measured_width('…',size)<=pixels and table.concat(groups,'',1,low)..'…' or ''
    end
    return cache_value(fitted_titles,fitted_order,key,result,128)
end
local function chat_prefix(item, units)
    return fit_text(item.username,math.max(1,math.min(12,units*.35)))
end
local function take_text(text, units)
    local out,used,bytes={},0,0
    for _,cp in ipairs(graphemes(text)) do
        local advance=text_units(cp)
        if used+advance>units then break end
        out[#out+1]=cp;used=used+advance;bytes=bytes+#cp
    end
    return table.concat(out),text:sub(bytes+1)
end
local function nickname_color(username)
    local hash=0
    for i=1,#username do hash=(hash*33+username:byte(i))%65521 end
    return CHAT_NICK_COLORS[hash%#CHAT_NICK_COLORS+1]
end
local function colored_chat(prefix, body, x, y, size, color)
    return line(prefix,color,x,y,size)..'{\\1c&HFFFFFF&}: '..escape(body)
end
local function clear_danmaku()
    danmaku={}
    if scrolling_data~=nil then scrolling:remove();scrolling_data=nil end
    animation_epoch,animation_frame=nil,-1
    if animation_timer then animation_timer:kill() end
end
local function trim_danmaku(now)
    local changed=false
    for lane,item in pairs(danmaku) do
        if item.expires<=now then danmaku[lane]=nil;changed=true end
    end
    return changed
end
-- Reference: uosc_danmaku/modules/render.lua explicitly computes each current
-- position. mpv's ass-events overlay has no running ASS animation clock; using
-- \move here would not animate it. Keep these cheap frames independent of the
-- room layout and user-data publication (whose observers can be expensive).
local function draw_danmaku(now)
    if console_open or not cfg.status_osd or state.enabled~=true or
            state.connection~='connected' or normalize_chat_mode(cfg.chat_mode)~='danmaku' then
        clear_danmaku();return
    end
    local rows={}
    for lane=1,DANMAKU_MAX_LANES do
        local item=danmaku[lane]
        if item then
            local x=item.start_x-(now-item.started)*item.speed
            local y=height*.16+(lane-1)*item.size*1.65
            if x<width and x+item.width>0 then
                rows[#rows+1]=string.format('{\\an7\\q2\\pos(%.1f,%.1f)%s}%s',x,y,item.style,item.text)
            end
        end
    end
    if #rows>0 then
        local data=table.concat(rows,'\n')
        if data~=scrolling_data then
            scrolling.res_x,scrolling.res_y=width,height
            scrolling.data=data;scrolling:update();scrolling_data=data
        end
    elseif scrolling_data~=nil then scrolling:remove();scrolling_data=nil end
    if not next(danmaku) then clear_danmaku() end
end
local function queue_danmaku(item)
    if console_open or not cfg.status_osd or not width or not height or width<1 or height<1 then return false end
    local size=safe_number(cfg.overlay_font_size,22,12,40)*scale*safe_number(cfg.danmaku_font_scale,1.15,1,1.6)
    local lanes=math.min(DANMAKU_MAX_LANES,math.max(0,math.floor(height*.38/(size*1.65))))
    trim_danmaku(mp.get_time())
    for lane=1,lanes do
        -- One active message per lane: bursts are dropped rather than queued,
        -- so a later message can never catch up with or cover an earlier one.
        if not danmaku[lane] then
            local units=math.max(2,width*.85/size)
            local prefix=chat_prefix(item,units)
            local body=fit_text(item.text,math.max(1,units-text_units(prefix..': ')))
            local now=mp.get_time()
            -- At least ten seconds for one screen width, even in a small
            -- window. Wall time keeps live chat usable during pause/idle too.
            local speed=math.min(110*scale,width/10)
            -- A conservative width bounds the lifetime; it never determines
            -- lane reuse while another message is still present.
            local length=(text_units(prefix..': '..body)*1.25+2)*size
            local style=string.format('\\fnsans-serif\\fs%.1f\\b1\\bord%.1f\\shad0\\1c&H%s&\\3c&H101010&\\clip(0,0,%.1f,%.1f)',
                size,math.max(1.5,size*.09),item.color,width,height)
            danmaku[lane]={text=escape(prefix)..'{\\1c&HFFFFFF&}: '..escape(body),style=style,started=now,start_x=width+12*scale,
                width=length,speed=speed,size=size,expires=now+(width+length+24*scale)/speed}
            if not animation_epoch then
                animation_epoch,animation_frame=now,-1
                if schedule_animation then schedule_animation(now) end
            end
            return true
        end
    end
    return false
end
local function latency_signal(member, own)
    if latency.enabled~=true then return nil end
    local value=own and latency.self or latency.members[member.username]
    if type(value)~='table' or value.reported~=true or value.stale==true then return nil end
    local rtt=value.rtt_ms
    if type(rtt)~='number' or rtt~=rtt or rtt<0 or rtt>RTT_MAX_MS then return nil end
    return {text=string.format('%.0f ms',rtt),bars=rtt<=RTT_GOOD_MS and 4 or rtt<=RTT_FAIR_MS and 3 or 1,
        color=rtt<=RTT_GOOD_MS and '80E692' or rtt<=RTT_FAIR_MS and '75DAFF' or '7777FF'}
end
local function member_media(member)
    local own=member.username==state.username
    local media=type(member.media)=='table' and member.media or nil
    if own and type(state.local_media)=='table' then media=state.local_media end
    local fallback=type(member.file)=='table' and member.file or {}
    local file=media and media.title or fallback.name
    if not media and own and type(state.local_file)=='string' and state.local_file~='' then file=state.local_file end
    local loaded=media and media.loaded==true or not media and type(file)=='string' and file~=''
    return {member=member,own=own,loaded=loaded,label=loaded and playlist_label(file) or '尚未载入文件',
        duration=loaded and (media and positive_duration(media.duration) or not media and positive_duration(fallback.duration)) or nil,
        signal=latency_signal(member,own)}
end
local function draw_signal(rows, signal, x, y, size)
    for bar=1,4 do
        local bar_height=(.18+bar*.14)*size
        local bx=x+(bar-1)*size*.22
        rows[#rows+1]=string.format('{\\an7\\pos(%.1f,%.1f)\\bord0\\shad0\\1c&H%s&\\p1}m 0 0 l %.1f 0 %.1f %.1f 0 %.1f{\\p0}',
            bx,y+size*.88-bar_height,bar<=signal.bars and signal.color or '666666',size*.15,size*.15,bar_height,bar_height)
    end
    rows[#rows+1]=line(signal.text,signal.color,x+size*1.05,y,size)
end
local function clear_events()
    chats, playback, notices, seen, seen_order = {}, nil, {}, {}, {}
    clear_danmaku()
end
local function trim_events()
    local now, changed = mp.get_time(), false
    while chats[1] and chats[1].expires <= now do table.remove(chats,1); changed=true end
    while notices[1] and notices[1].expires <= now do table.remove(notices,1); changed=true end
    if playback and playback.expires <= now then playback=nil; changed=true end
    changed=trim_danmaku(now) or changed
    return changed
end
local function publish_geometry()
    -- Public geometry allows other UI scripts to avoid these small hit regions.
    local chat_count=#chats
    for _ in pairs(danmaku) do chat_count=chat_count+1 end
    mp.set_property_native('user-data/splay-overlay', {visible=visible,
        width=width,height=height,buttons=visible and rectangles or {},
        integrated=integrated,popup_open=popup_open,popup=popup_open and popup or nil,
        rows=popup_open and menu_rows or {},enabled=state.enabled==true,
        chat_count=chat_count,playback_active=playback ~= nil,status_enabled=cfg.status_osd,
        buttons_enabled=cfg.button_enabled,room_enabled=cfg.room_panel,chat_mode=normalize_chat_mode(cfg.chat_mode),
        console_open=console_open,
        notification_count=notification_count,room_panel_visible=panel_visible,
        autostart_remaining=autostart_countdown(),
        room_panel=panel_visible and panel_geometry or nil,room_rows=panel_visible and panel_rows or {},
        chat_available=chat_available(),chat_button=visible and rectangles[2] or nil,
        status_shown=not console_open and state.enabled==true and cfg.status_osd and (panel_visible or notification_count>0 or autostart_countdown()~=nil)})
end
redraw = function()
    width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then
        clear_danmaku();panel_visible=false;panel_geometry=nil;panel_rows={};notification_count=0
        status:remove();publish_geometry();return
    end
    if width~=danmaku_width or height~=danmaku_height then
        clear_danmaku();danmaku_width=width;danmaku_height=height
    end
    scale = math.max(0.65, math.min(1.6, height/720))
    status.res_x, status.res_y = width, height
    local size = safe_number(cfg.overlay_font_size,22,12,40)*scale
    local margin, y, rows = 22*scale, 22*scale, {}
    -- Soft wrapping and bounded rows keep long names/chat within the viewport.
    local panel_limit=math.min(400*scale,width*.48)
    -- Font size depends only on the viewport, so changing filenames cannot
    -- make the whole panel's text jump in size. Width follows content instead.
    local panel_size=math.min(size*.83,panel_limit/18.5)
    local member_layouts={}
    local latency_units=1.5+text_units('1000 ms')
    local duration_units=math.max(text_units(time_string(0)),text_units('时长未知'))+.3
    for _,member in ipairs(state.members or {}) do
        if type(member)=='table' and (member.room==nil or member.room==state.room) then
            local layout=member_media(member)
            member_layouts[#member_layouts+1]=layout
            if layout.signal then latency_units=math.max(latency_units,1.5+text_units(layout.signal.text)) end
        end
    end
    local preferred_units=14
    local show_panel=room_visible()
    for _,layout in ipairs(member_layouts) do
        local name_units=math.min(12,text_units(plain(layout.member.username,40)))+text_units('● ')
        local file_units=show_panel and measured_width(plain(layout.label,2048),panel_size)/panel_size or text_units(layout.label)
        preferred_units=math.max(preferred_units,file_units+1.4,
            name_units+.35+latency_units+.4+duration_units+.2)
    end
    local panel_width=math.min(panel_limit,preferred_units*panel_size)
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
    panel_visible=show_panel; panel_rows={}; panel_geometry=nil
    local danmaku_count=0
    for _ in pairs(danmaku) do danmaku_count=danmaku_count+1 end
    notification_count=#chats+#notices+danmaku_count+(playback and 1 or 0)
    if not console_open and cfg.status_osd and state.enabled==true then
        local countdown=autostart_countdown()
        if countdown and not panel_visible then add('自动开播 · '..countdown..' 秒（菜单可取消）','FFFF75',2) end
        if playback then add(playback.text,'FFFF75',2) end
        for _,item in ipairs(notices) do
            if y+size*2.7>height*.62 then break end
            add(item.text,'BBBBBB',2)
        end
        if normalize_chat_mode(cfg.chat_mode)=='room' then
            local units=math.max(3,(width-panel_width-3*margin)/size)
            for _,item in ipairs(chats) do
                if y+size*2.7>height*.62 then break end
                local prefix=chat_prefix(item,units)
                local first,rest=take_text(item.text,math.max(1,units-text_units(prefix..': ')))
                rows[#rows+1]=colored_chat(prefix,first,margin,y,size,item.color);y=y+size*1.35
                if rest~='' then
                    rows[#rows+1]=line(fit_text(rest,units),'FFFFFF',margin,y,size);y=y+size*1.35
                end
            end
        end
        if panel_visible then
            local px,py=width-margin-panel_width,margin
            local psize=panel_size
            local max_units=math.max(2,panel_width/psize-.2)
            local max_y=height*.56
            -- All durations share the filename area's right edge. ASS an9
            -- aligns actual glyph advances; no estimated width or spaces are
            -- used to right-align a duration. Reserve latency even if absent.
            local duration_x=px+panel_width-psize*.2
            local file_x=px+psize*.64
            local duration_left=duration_x-duration_units*psize
            local name_units=math.max(1,(duration_left-px)/psize-latency_units-.75)
            local function member_line(text,tint,kind,username,latency,duration,duration_color)
                if py+psize*1.4>max_y then return false end
                local is_file=kind=='file' or kind=='playlist-file'
                text=is_file and fit_title_pixels(text,duration_x-file_x,psize) or
                    fit_text(text,kind=='member' and name_units or max_units)
                local latency_x=px+(text_units(text)+.35)*psize
                local name_clip=kind=='member' and string.format('{\\clip(%.1f,0,%.1f,%.1f)}',px-psize*.2,latency_x-psize*.3,height) or ''
                rows[#rows+1]=name_clip..line(text,tint,is_file and file_x or px,py,psize)
                if latency then draw_signal(rows,latency,latency_x,py,psize) end
                if duration then rows[#rows+1]=line(duration,duration_color or 'AAAAAA',duration_x,py,psize,9) end
                panel_rows[#panel_rows+1]={text=text,color=tint,kind=kind,username=username,
                    latency=latency and latency.text or nil,latency_color=latency and latency.color or nil,
                    duration=duration,duration_color=duration and (duration_color or 'AAAAAA') or nil,
                    name_x=px,latency_x=latency_x,duration_x=duration_x,
                    file_x=is_file and file_x or nil,file_right=is_file and duration_x or nil,y=py}
                py=py+psize*1.4
                return true
            end
            member_line(state.room,'FFFFFF','room')
            if countdown then member_line('自动开播 · '..countdown..' 秒','FFFF75','autostart') end
            local members=member_layouts
            local playlist=type(state.playlist)=='table' and state.playlist or nil
            local reserve=playlist and type(playlist.files)=='table' and #playlist.files>0 and psize*2.8 or 0
            local shown=0
            local displayed_files={}
            for _,layout in ipairs(members) do
                local member,own,loaded,label=layout.member,layout.own,layout.loaded,layout.label
                local file_lines={label}
                local duration=layout.duration
                local comparison=type(member.media)=='table' and member.media or {}
                local duration_colors={duration_match='80E692',duration_mismatch='7777FF'}
                local duration_color=not own and duration_colors[comparison.check] or 'AAAAAA'
                local difference=loaded and comparison.check=='duration_mismatch' and duration_difference(comparison.duration_delta) or nil
                local summary=not own and comparison.check=='duration_mismatch' and
                    ('时长不同'..(difference and ' · '..difference or '')) or nil
                local needed=(#file_lines+1+(summary and 1 or 0))*psize*1.4
                local more_reserve=shown+1<#members and psize*1.4 or 0
                if py+needed+reserve+more_reserve>max_y then break end
                local tint=member.ready==true and '80E692' or member.ready==false and '7777FF' or '999999'
                local signal=layout.signal
                local marker=(type(member.ready)=='boolean' and '● ' or '○ ')
                local name=fit_text(member.username,math.max(0,name_units-text_units(marker)))
                member_line(marker..name,tint,'member',member.username,signal,duration and time_string(duration) or '时长未知',duration_color)
                for _,file_line in ipairs(file_lines) do member_line(file_line,'BBBBBB','file',member.username) end
                if summary then member_line('  '..summary,'AAAAAA','media-summary',member.username) end
                if loaded then displayed_files[label]=true end
                shown=shown+1
            end
            if shown<#members then member_line('… 另有 '..(#members-shown)..' 位成员','999999','more') end
            if #members==0 then member_line('等待房间成员','999999','empty') end
            if playlist and type(playlist.files)=='table' and #playlist.files>0 then
                local index=tonumber(playlist.index)
                local current=index and index>=0 and index<#playlist.files and math.floor(index)+1 or nil
                member_line('共享列表 · '..(current and current..' / ' or '')..#playlist.files..' 项','BBBBBB','playlist')
                if current then
                    local label=playlist_label(playlist.files[current])
                    if not displayed_files[label] then
                        member_line(label,'BBBBBB','playlist-file')
                    end
                end
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
    local data={icon='sync',active=state.enabled==true,hide=console_open or not cfg.button_enabled,
        command={'script-message-to','splay_overlay','splay-popup'}}
    if not popup_open then data.tooltip='同步播放' end
    mp.commandv('script-message-to','uosc','set-button','splay',utils.format_json(data))
    mp.commandv('script-message-to','uosc','set-button','splay-chat',utils.format_json({
        icon='chat',hide=console_open or not chat_available(),tooltip='发送聊天',
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
    if not width or not height or width<=0 or height<=0 then
        visible=false;rectangles={};popup_open=false;popup=nil;menu_rows={}
        buttons:remove();mp.disable_key_bindings(section);mp.disable_key_bindings(escape_section)
        publish_geometry();return
    end
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
        local padding=12*scale
        local font=16*scale
        local subtitle_font=14*scale
        local items=type(menu_model.items)=='table' and menu_model.items or {}
        local preferred=292*scale
        for _,item in ipairs(items) do
            if type(item)=='table' then
                preferred=math.max(preferred,text_units(plain(item.popup_title or item.title,2048))*font+2*padding)
                if item.subtitle then preferred=math.max(preferred,text_units(plain(item.subtitle,2048))*subtitle_font+2*padding) end
            end
        end
        local pw=math.max(1,math.min(preferred,560*scale,width-16))
        local available_units=math.max(1,(pw-2*padding)/font)
        local layouts,needs_full={},false
        for _,item in ipairs(items) do
            if type(item)~='table' then item={title=plain(item),selectable=false} end
            local title_lines,clipped=wrap_text(item.popup_title or item.title,available_units,2)
            local subtitle_lines,subtitle_clipped={},false
            if item.subtitle~=nil then
                subtitle_lines,subtitle_clipped=wrap_text(item.subtitle,math.max(1,(pw-2*padding)/subtitle_font),2)
            end
            layouts[#layouts+1]={item=item,title_lines=title_lines,subtitle_lines=subtitle_lines,
                height=14*scale+#title_lines*font*1.3+#subtitle_lines*subtitle_font*1.3}
            needs_full=needs_full or clipped or subtitle_clipped
        end
        local ax=anchor and anchor.x or width/2
        local ay=anchor and anchor.y or height-80*scale
        -- Keyboard/programmatic opens may leave the pointer on the timeline.
        -- The popup always ends above the controls, regardless of pointer y.
        local bottom_limit=math.max(8,math.min(height-8,controls_top()-8*scale))
        if rectangles[1] then bottom_limit=math.min(bottom_limit,rectangles[1].y1-8*scale) end
        local max_height=math.max(0,bottom_limit-8)
        local header_lines,header_clipped=wrap_text(menu_model.title or '同步播放',math.max(1,(pw-2*padding)/subtitle_font),2)
        local header_height=16*scale+#header_lines*subtitle_font*1.3
        local footer_lines=wrap_text('展开完整菜单',available_units,2)
        local footer_height=14*scale+#footer_lines*font*1.3
        local total=header_height+4*scale
        for _,layout in ipairs(layouts) do total=total+layout.height end
        needs_full=needs_full or header_clipped or total>max_height
        local shown_layouts={}
        local ph=header_height+4*scale
        for _,layout in ipairs(layouts) do
            if ph+layout.height+(needs_full and footer_height or 0)>max_height then break end
            shown_layouts[#shown_layouts+1]=layout;ph=ph+layout.height
        end
        if needs_full then
            shown_layouts[#shown_layouts+1]={item={value='home'},title_lines=footer_lines,subtitle_lines={},height=footer_height,expand=true}
            ph=ph+footer_height
        end
        -- A tiny viewport cannot hold even the explicit expansion action.
        -- Delegate to the existing complete center menu instead of clipping it.
        if ph>max_height or pw<2*padding+font*5 then
            popup_open=false;popup=nil;menu_rows={}
            mp.disable_key_bindings(escape_section)
            set_uosc_button()
            send('splay-action','home')
            update_buttons()
            return
        end
        local left=math.max(8,math.min(width-pw-8,ax-pw/2))
        local top=math.max(8,math.min(bottom_limit-ph,ay-ph-12*scale))
        popup={x1=left,y1=top,x2=left+pw,y2=top+ph}
        rect(drawing,popup,'222222','08')
        for i,text in ipairs(header_lines) do
            drawing[#drawing+1]=line(text,'AAAAAA',left+padding,top+8*scale+(i-1)*subtitle_font*1.3,subtitle_font)
        end
        menu_rows={}
        local row_y=top+header_height
        for _,layout in ipairs(shown_layouts) do
            local item=layout.item
            local r={x1=left+4*scale,y1=row_y,x2=left+pw-4*scale,y2=row_y+layout.height,
                value=tostring(item.value or ''),selectable=item.selectable~=false and type(item.value)=='string',
                title=table.concat(layout.title_lines,'\n'),subtitle=table.concat(layout.subtitle_lines,'\n'),expand=layout.expand or false}
            menu_rows[#menu_rows+1]=r
            if mouse.hover and point_in(x,y,r) and r.selectable then rect(drawing,r,'514332') end
            local text_y=row_y+7*scale
            for _,text in ipairs(layout.title_lines) do
                drawing[#drawing+1]=line(text,r.selectable and 'FFFFFF' or '888888',left+padding,text_y,font)
                text_y=text_y+font*1.3
            end
            for _,text in ipairs(layout.subtitle_lines) do
                drawing[#drawing+1]=line(text,'AAAAAA',left+padding,text_y,subtitle_font)
                text_y=text_y+subtitle_font*1.3
            end
            row_y=r.y2
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
options.read_options(cfg,'splay',function()
    cfg.chat_mode=normalize_chat_mode(cfg.chat_mode)
    update_smooth_filter()
    chats={};clear_danmaku();integrate_uosc();redraw();update_buttons()
end)
cfg.chat_mode=normalize_chat_mode(cfg.chat_mode)
mp.register_script_message('splay-state',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=parse(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    local smooth_changed=value.enabled~=state.enabled or value.connection~=state.connection
    local previous_mode,previous_smooth=cfg.chat_mode,cfg.danmaku_smooth
    if value.room~=state.room or (value.connection~='connected' and state.connection=='connected') then clear_events() end
    if value.enabled~=true then clear_events() end
    if type(value.settings)=='table' then
        local settings=value.settings
        for _,key in ipairs({'status_osd','button_enabled','room_panel','danmaku_smooth'}) do
            if type(settings[key])=='boolean' then cfg[key]=settings[key] end
        end
        if type(settings.chat_mode)=='string' then
            local mode=normalize_chat_mode(settings.chat_mode)
            if mode~=cfg.chat_mode then chats={};clear_danmaku() end
            cfg.chat_mode=mode
        end
    end
    if not cfg.status_osd then chats={};clear_danmaku() end
    state=value
    if smooth_changed or previous_mode~=cfg.chat_mode or previous_smooth~=cfg.danmaku_smooth then update_smooth_filter() end
    trim_events(); integrate_uosc(); set_uosc_button(); redraw(); update_buttons()
end)
mp.register_script_message('splay-latency',function(json)
    if type(json)~='string' or #json>262144 then return end
    local value=parse(json)
    if type(value)~='table' or value.schema~=1 or type(value.members)~='table' then return end
    latency=value
    -- Only the room panel shows it; a hidden panel reads the value when drawn.
    if panel_visible then redraw() end
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
        -- History belongs to the main script. Hidden overlays do not retain a
        -- backlog that would reappear after closing the console or settings.
        if console_open or not cfg.status_osd then return end
        local now=mp.get_time()
        chat_tokens=math.min(6,chat_tokens+math.max(0,now-chat_token_time)*3)
        chat_token_time=now
        if chat_tokens<1 then return end
        chat_tokens=chat_tokens-1
        local color=type(value.chat_color)=='string' and value.chat_color:match('^%x%x%x%x%x%x$') and value.chat_color or nickname_color(user)
        local item={username=user,color=color,text=plain(value.text,200),
            expires=mp.get_time()+safe_number(cfg.overlay_chat_ttl,5,1,120)}
        if normalize_chat_mode(cfg.chat_mode)=='danmaku' then
            if not queue_danmaku(item) then return end
        else
            chats[#chats+1]=item
            while #chats>safe_number(cfg.overlay_chat_lines,4,1,10) do table.remove(chats,1) end
        end
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
mp.register_script_message('overlay-toggle-status',function()
    cfg.status_osd=not cfg.status_osd
    if not cfg.status_osd then clear_events() end
    redraw()
end)
mp.register_script_message('overlay-toggle-buttons',function() cfg.button_enabled=not cfg.button_enabled; integrate_uosc(); update_buttons() end)
mp.register_script_message('overlay-toggle-room',function() cfg.room_panel=not cfg.room_panel;redraw() end)
mp.register_script_message('overlay-set-chat-mode',function(mode)
    if mode~='room' and mode~='chatroom' and mode~='danmaku' then return end
    cfg.chat_mode=normalize_chat_mode(mode);update_smooth_filter();chats={};clear_danmaku();redraw()
end)
local function set_console_open(value)
    local opened=value==true or value=='yes' or value=='true' or value=='1'
    if console_open==opened then return end
    console_open=opened;clear_events()
    if opened then close_popup() end
    set_uosc_button();redraw();update_buttons()
end
mp.observe_property('user-data/splay-console-open','bool',function(_,value) set_console_open(value) end)
mp.register_script_message('overlay-console-open',set_console_open)
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
-- Filter ownership is checked only on relevant state/property transitions,
-- never in the animation timer or ordinary room status refreshes.
for _,property in ipairs({'vf','vid','video-params','idle-active','estimated-vf-fps','container-fps'}) do
    mp.observe_property(property,'native',function() update_smooth_filter() end)
end
mp.register_event('start-file',function()
    smooth_loading=true;smooth_blocked=false
    update_smooth_filter()
end)
mp.register_event('end-file',function()
    smooth_loading=true
    update_smooth_filter()
end)
mp.register_event('file-loaded',function()
    smooth_loading=false;smooth_blocked=false
    update_smooth_filter()
end)
local event_timer=mp.add_periodic_timer(0.25,function()
    if trim_events() or panel_visible~=room_visible() then redraw() end
    if visible then update_buttons() end
end)
-- mpv's periodic timers schedule the next callback as now + timeout, which
-- shifts every later deadline after a late wakeup. Use one-shot deadlines on
-- one fixed clock instead, skipping missed slots rather than catching up.
-- Normal UI redraws never submit another animation frame between these slots.
schedule_animation=function(now)
    if not animation_epoch or not next(danmaku) or not animation_timer then return end
    animation_frame=math.max(animation_frame+1,math.floor((now-animation_epoch)/animation_period)+1)
    local deadline=animation_epoch+animation_frame*animation_period
    animation_timer:kill()
    animation_timer.timeout=math.max(.002,deadline-now)
    animation_timer:resume()
end
animation_timer=mp.add_timeout(1/60,function()
    if not animation_epoch then return end
    local now=mp.get_time()
    if trim_danmaku(now) then redraw() end
    draw_danmaku(now)
    schedule_animation(mp.get_time())
end,true)
mp.observe_property('display-fps','number',function(_,value)
    local fps=tonumber(value)
    if not fps or fps~=fps or fps<20 or fps>1000 then fps=60 end
    -- Prefer an integer number of display refreshes per update: 75 -> 75,
    -- 120 -> 120, 144 -> 72, 165 -> 82.5. A hard 60 cap creates uneven holds
    -- on these screens. This is clock alignment, not a claim of vsync access.
    local period=math.ceil(fps/120)/fps
    if math.abs(period-animation_period)<.000001 then return end
    animation_period=period
    if next(danmaku) then
        animation_epoch,animation_frame=mp.get_time(),-1
        schedule_animation(animation_epoch)
    end
end)
mp.register_event('shutdown',function()
    smooth_stopping=true
    remove_smooth_filter()
    event_timer:kill();animation_timer:kill()
    clear_events()
    restore_controls(); status:remove(); scrolling:remove(); measuring:remove(); buttons:remove()
    mp.disable_key_bindings(section); mp.disable_key_bindings(escape_section)
    mp.set_property_native('user-data/splay-overlay',nil)
end)
mp.add_timeout(0,function() integrate_uosc(); redraw(); update_buttons(); send('splay-overlay-ready') end)
