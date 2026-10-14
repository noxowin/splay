-- Offline test double: records JSON commands, never opens a socket.
local utils=require 'mp.utils'
mp.register_script_message('splay-command',function(json)
    local value=utils.parse_json(json)
    if type(value)=='table' and value.action=='ready' then
        assert(value.ready==true,'ready action must carry a boolean true')
        print('UI_READY_COMMAND '..utils.format_json(value))
    end
end)
