-- Observation only: does not implement protocol behavior or alter playback.
local observations={}
for _,name in ipairs({'file-loaded','end-file'}) do
    mp.register_event(name,function(event)
        observations[#observations+1]={event=name,reason=event.reason,
            path=mp.get_property_native('path'),pause=mp.get_property_native('pause'),
            playlist=mp.get_property_native('user-data/splay-playlist')}
        if #observations>20 then table.remove(observations,1) end
        mp.set_property_native('user-data/splay-playlist-observations',observations)
    end)
end
