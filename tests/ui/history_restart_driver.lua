local utils=require 'mp.utils'
mp.add_timeout(1.5,function()
    -- Saving the currently displayed form proves auto-loaded history restored it.
    -- This action does not connect and does not change any active room.
    mp.commandv('script-message-to','splay','splay-menu-event',utils.format_json({type='activate',value='save-profile'}))
end)
mp.add_timeout(2.3,function() print('HISTORY_RESTART_SAVED');mp.commandv('quit') end)
