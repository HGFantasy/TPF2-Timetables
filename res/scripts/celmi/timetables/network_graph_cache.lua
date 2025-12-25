-- Network Graph Cache Module
-- Infrastructure for feature #16 (Auto-Generate Routes & Timetables)
-- Caches network topology for route finding, traffic analysis, and hub identification

local networkGraphCache = {}
local timetableHelper = nil -- Lazy load to avoid circular dependency

-- Network graph cache: carrierType -> {graph = {...}, lastUpdate = timestamp, dirty = bool}
local graphCache = {}

-- Initialize network graph cache
function networkGraphCache.initialize()
    graphCache = {}
end

-- Mark network graph as dirty (needs rebuild) for a carrier type
function networkGraphCache.markDirty(carrierType)
    if not carrierType then
        -- Mark all as dirty
        for ct, _ in pairs(graphCache) do
            graphCache[ct].dirty = true
        end
        -- Clear distance cache when network changes
        local routeFinder = require "celmi/timetables/route_finder"
        if routeFinder and routeFinder.clearDistanceCache then
            routeFinder.clearDistanceCache()
        end
    else
        if not graphCache[carrierType] then
            graphCache[carrierType] = {}
        end
        graphCache[carrierType].dirty = true
    end
end

-- Initialize event subscriptions for automatic cache invalidation
function networkGraphCache.initializeEvents()
    -- Lazy load timetableHelper to avoid circular dependency
    if not timetableHelper then
        timetableHelper = require "celmi/timetables/timetable_helper"
    end
    
    if timetableHelper and timetableHelper.isCommonAPI2Available() then
        -- Subscribe to line modification events
        timetableHelper.addEventListener("onLineModified", function(line)
            -- Mark all graphs as dirty when any line changes
            networkGraphCache.markDirty(nil)
        end)
        
        -- Subscribe to station modification events
        timetableHelper.addEventListener("onStationModified", function(station)
            -- Mark all graphs as dirty when any station changes
            networkGraphCache.markDirty(nil)
        end)
    end
end

-- Store network graph for a carrier type
function networkGraphCache.store(carrierType, graph, timestamp)
    if not carrierType or not graph then return end
    
    if not graphCache[carrierType] then
        graphCache[carrierType] = {}
    end
    
    graphCache[carrierType].graph = graph
    graphCache[carrierType].lastUpdate = timestamp or 0
    graphCache[carrierType].dirty = false
end

-- Get cached network graph for a carrier type
-- Returns nil if cache is dirty or doesn't exist
function networkGraphCache.get(carrierType)
    if not carrierType or not graphCache[carrierType] then
        return nil
    end
    
    if graphCache[carrierType].dirty then
        return nil
    end
    
    return graphCache[carrierType].graph
end

-- Check if cache is dirty for a carrier type
function networkGraphCache.isDirty(carrierType)
    if not carrierType or not graphCache[carrierType] then
        return true
    end
    return graphCache[carrierType].dirty == true
end

-- Clear cache for a carrier type (or all if carrierType is nil)
function networkGraphCache.clear(carrierType)
    if not carrierType then
        graphCache = {}
    else
        graphCache[carrierType] = nil
    end
end

-- Initialize events on module load (will be called after timetable_helper is loaded)
-- This is a delayed initialization to avoid circular dependencies
pcall(function()
    networkGraphCache.initializeEvents()
end)

return networkGraphCache
