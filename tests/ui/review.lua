local options=require 'mp.options'
local utils=require 'mp.utils'
local opt={mode='native',output=''}
options.read_options(opt,'review')
mp.add_timeout(1,function()
    mp.commandv('script-message-to','splay','splay-state',utils.format_json({schema=1,
        connection='connected',encrypted=true,username='本机用户',room='中文房间',ready=false,
        warning='Synchronization requires playback speed 1.0; synchronization is suspended',members={{username='另一位成员',room='中文房间',ready=true}}}))
    mp.commandv('script-message-to','splay','splay-open',opt.mode)
end)
mp.add_timeout(2,function()
    mp.commandv('screenshot-to-file',opt.output,'window')
    print('REVIEW_CAPTURE '..opt.mode)
end)
mp.add_timeout(2.15,function()
    if opt.mode=='uosc' then
        mp.commandv('script-message-to','uosc','select-menu-item','splay','10')
    else
        for n=1,9 do mp.add_timeout(n*0.06,function() mp.commandv('keypress','DOWN') end) end
    end
    mp.add_timeout(0.7,function() mp.commandv('keypress','ENTER') end)
end)
mp.add_timeout(3.4,function() mp.commandv('quit') end)
