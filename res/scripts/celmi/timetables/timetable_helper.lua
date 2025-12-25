local timetableHelper = {}

-- CommonAPI2 feature detection and initialization
local commonapi2_available = false
local commonapi2_events = nil
local commonapi2_cmd = nil
local commonapi2_logging_api = nil
local commonapi2_localization_api = nil
local commonapi2_error_api = nil

-- Initialize CommonAPI2 detection with debug logging
print("Timetables: Checking for CommonAPI2...")
print("Timetables: commonapi type: " .. type(commonapi))
if commonapi ~= nil then
    print("Timetables: commonapi exists, checking if table...")
    if type(commonapi) == "table" then
        print("Timetables: commonapi is a table, CommonAPI2 detected!")
        commonapi2_available = true
        -- Access events if available
        if commonapi._events ~= nil then
            commonapi2_events = commonapi._events
        end
        -- Access command API if available
        if commonapi.cmd ~= nil then
            commonapi2_cmd = commonapi.cmd
        elseif commonapi.commands ~= nil then
            commonapi2_cmd = commonapi.commands
        end
        
        -- Access logging API if available
        if commonapi.log then
            commonapi2_logging_api = commonapi.log
        elseif commonapi.logging then
            commonapi2_logging_api = commonapi.logging
        elseif commonapi.logger then
            commonapi2_logging_api = commonapi.logger
        end
        
        -- Access localization API if available
        if commonapi.localization then
            commonapi2_localization_api = commonapi.localization
        elseif commonapi.locale then
            commonapi2_localization_api = commonapi.locale
        elseif commonapi.i18n then
            commonapi2_localization_api = commonapi.i18n
        end
        
        -- Access error reporting API if available
        if commonapi.error then
            commonapi2_error_api = commonapi.error
        elseif commonapi.exception then
            commonapi2_error_api = commonapi.exception
        elseif commonapi.errors then
            commonapi2_error_api = commonapi.errors
        end
        
        -- Log feature detection (only once at startup)
        local features = {}
        if commonapi2_events then table.insert(features, "events") end
        if commonapi2_cmd then table.insert(features, "commands") end
        if commonapi.entityExists then table.insert(features, "entityExists") end
        if commonapi.getComponent then table.insert(features, "getComponent") end
        if commonapi.getComponents then table.insert(features, "getComponents (batch)") end
        if commonapi.system then table.insert(features, "system") end
        if commonapi.getWorld then table.insert(features, "getWorld") end
        if commonapi.getEntity then table.insert(features, "getEntity") end
        if commonapi.getLines then table.insert(features, "getLines") end
        if commonapi2_logging_api then table.insert(features, "logging") end
        if commonapi2_localization_api then table.insert(features, "localization") end
        if commonapi2_error_api then table.insert(features, "errorReporting") end
        if commonapi2_performance_api then table.insert(features, "performance") end
        
        if #features > 0 then
            -- Use print for initial startup message (logging not initialized yet)
            print("Timetables: CommonAPI2 available with features: " .. table.concat(features, ", "))
        else
            print("Timetables: CommonAPI2 detected but no known features found")
        end
    else
        print("Timetables: commonapi exists but is not a table (type: " .. type(commonapi) .. "), using native API fallback")
    end
else
    print("Timetables: CommonAPI2 not available (commonapi is nil), using native API fallback")
end

local UIStrings = {
    arr = _("arr_i18n"),
    dep = _("dep_i18n"),
    unbunchTime = _("unbunch_time_i18n")
}

-- Entity existence cache to reduce redundant API calls
local entityExistsCache = {}
local entityExistsCacheTime = {}
local ENTITY_CACHE_DURATION = 5 -- Cache for 5 seconds
local lastCacheCleanTime = 0

-- Component access cache for frequently accessed components
local componentCache = {}
local componentCacheTime = {}
local COMPONENT_CACHE_DURATION = 1 -- Cache for 1 second (same update cycle)

-- System query caches
local linesCache = nil
local linesCacheTime = 0
local LINES_CACHE_DURATION = 5 -- Cache for 5 seconds

local lineVehiclesMapCache = nil
local lineVehiclesMapCacheTime = 0
local LINE_VEHICLES_MAP_CACHE_DURATION = 1 -- Cache for 1 second (matches update cycle)

local vehiclesWithStateCache = nil
local vehiclesWithStateCacheState = nil
local vehiclesWithStateCacheTime = 0
local VEHICLES_WITH_STATE_CACHE_DURATION = 1 -- Cache for 1 second

-- CommonAPI2 resource management integration
local commonapi2_resource_api = nil
local commonapi2_performance_api = nil
if commonapi2_available and commonapi then
    if commonapi.resources then
        commonapi2_resource_api = commonapi.resources
    elseif commonapi.memory then
        commonapi2_resource_api = commonapi.memory
    elseif commonapi.resourceManager then
        commonapi2_resource_api = commonapi.resourceManager
    end
    
    -- Access performance monitoring API if available
    if commonapi.performance then
        commonapi2_performance_api = commonapi.performance
    elseif commonapi.metrics then
        commonapi2_performance_api = commonapi.metrics
    elseif commonapi.profiler then
        commonapi2_performance_api = commonapi.profiler
    end
end

-- Get memory pressure level from CommonAPI2 if available
local function getMemoryPressure()
    if commonapi2_available and commonapi2_resource_api then
        if commonapi2_resource_api.getMemoryPressure then
            local success, pressure = pcall(function()
                return commonapi2_resource_api.getMemoryPressure()
            end)
            if success and pressure then
                return pressure
            end
        elseif commonapi2_resource_api.getMemoryUsage then
            local success, usage = pcall(function()
                return commonapi2_resource_api.getMemoryUsage()
            end)
            if success and usage then
                -- Convert usage to pressure level (0-1)
                return usage.used / (usage.total or 1)
            end
        end
    end
    return nil -- Unknown pressure
end

-- Cache cleanup function - call periodically to prevent memory leaks
-- Optimized to only iterate expired entries and batch deletions
-- Uses CommonAPI2 memory pressure if available for adaptive cleanup
local function cleanCaches(currentTime)
    -- Check memory pressure and adjust cleanup frequency
    local memoryPressure = getMemoryPressure()
    local cleanupInterval = 10 -- Default: clean every 10 seconds
    
    if memoryPressure then
        -- More aggressive cleanup under memory pressure
        if memoryPressure > 0.8 then
            cleanupInterval = 2 -- Clean every 2 seconds under high pressure
        elseif memoryPressure > 0.6 then
            cleanupInterval = 5 -- Clean every 5 seconds under medium pressure
        end
    end
    
    if currentTime - lastCacheCleanTime < cleanupInterval then
        return -- Only clean at configured interval
    end
    lastCacheCleanTime = currentTime
    
    -- Clean entity cache - collect expired keys first, then delete in batch
    local expiredEntities = {}
    for entity, cachedTime in pairs(entityExistsCacheTime) do
        if currentTime - cachedTime > ENTITY_CACHE_DURATION then
            table.insert(expiredEntities, entity)
        end
    end
    for _, entity in ipairs(expiredEntities) do
        entityExistsCache[entity] = nil
        entityExistsCacheTime[entity] = nil
    end
    
    -- Clean component cache - collect expired keys first, then delete in batch
    local expiredComponents = {}
    for key, cachedTime in pairs(componentCacheTime) do
        if currentTime - cachedTime > COMPONENT_CACHE_DURATION then
            table.insert(expiredComponents, key)
        end
    end
    for _, key in ipairs(expiredComponents) do
        componentCache[key] = nil
        componentCacheTime[key] = nil
    end
    
    -- Clean system query caches (they auto-expire on next access, but clean old ones)
    if currentTime - linesCacheTime > LINES_CACHE_DURATION then
        linesCache = nil
        linesCacheTime = 0
    end
    if currentTime - lineVehiclesMapCacheTime > LINE_VEHICLES_MAP_CACHE_DURATION then
        lineVehiclesMapCache = nil
        lineVehiclesMapCacheTime = 0
    end
    if currentTime - vehiclesWithStateCacheTime > VEHICLES_WITH_STATE_CACHE_DURATION then
        vehiclesWithStateCache = nil
        vehiclesWithStateCacheState = nil
        vehiclesWithStateCacheTime = 0
    end
    
    -- Aggressive cleanup under memory pressure
    if memoryPressure and memoryPressure > 0.7 then
        -- Reduce cache durations under memory pressure
        local pressureReduction = 0.5 -- Reduce cache time by 50%
        
        -- Clean entity cache more aggressively
        for entity, cachedTime in pairs(entityExistsCacheTime) do
            if currentTime - cachedTime > (ENTITY_CACHE_DURATION * pressureReduction) then
                entityExistsCache[entity] = nil
                entityExistsCacheTime[entity] = nil
            end
        end
        
        -- Clean component cache more aggressively
        for key, cachedTime in pairs(componentCacheTime) do
            if currentTime - cachedTime > (COMPONENT_CACHE_DURATION * pressureReduction) then
                componentCache[key] = nil
                componentCacheTime[key] = nil
            end
        end
    end
    
    -- Notify CommonAPI2 resource manager about cache cleanup if available
    if commonapi2_available and commonapi2_resource_api and commonapi2_resource_api.notifyCleanup then
        pcall(function()
            commonapi2_resource_api.notifyCleanup("timetables_cache")
        end)
    end
end

-- Performance metrics collection (optional, can be enabled via settings)
local performanceMetricsEnabled = false
local performanceMetrics = {
    apiCallCounts = {},
    apiCallTimes = {},
    totalCalls = 0,
    totalTime = 0
}

-- Enable/disable performance metrics
function timetableHelper.setPerformanceMetricsEnabled(enabled)
    performanceMetricsEnabled = enabled
    if not enabled then
        -- Clear metrics when disabled
        performanceMetrics = {
            apiCallCounts = {},
            apiCallTimes = {},
            totalCalls = 0,
            totalTime = 0
        }
    end
end

-- Get performance metrics
function timetableHelper.getPerformanceMetrics()
    if not performanceMetricsEnabled then
        return nil
    end
    return {
        apiCallCounts = performanceMetrics.apiCallCounts,
        apiCallTimes = performanceMetrics.apiCallTimes,
        totalCalls = performanceMetrics.totalCalls,
        totalTime = performanceMetrics.totalTime,
        averageTime = performanceMetrics.totalCalls > 0 and (performanceMetrics.totalTime / performanceMetrics.totalCalls) or 0
    }
end

-- Reset performance metrics
function timetableHelper.resetPerformanceMetrics()
    performanceMetrics = {
        apiCallCounts = {},
        apiCallTimes = {},
        totalCalls = 0,
        totalTime = 0
    }
end

-- Standardized CommonAPI2 call wrapper with error handling and optional performance tracking
local function safeCommonAPI2Call(apiFunc, fallbackFunc, ...)
    local startTime = nil
    local apiName = "unknown"
    
    if performanceMetricsEnabled then
        startTime = os.clock()
        -- Try to identify API name for metrics
        if apiFunc then
            apiName = "commonapi2"
        elseif fallbackFunc then
            apiName = "native"
        end
    end
    
    if commonapi2_available and apiFunc then
        local success, result = pcall(apiFunc, ...)
        if success then
            if performanceMetricsEnabled and startTime then
                local elapsed = os.clock() - startTime
                performanceMetrics.apiCallCounts[apiName] = (performanceMetrics.apiCallCounts[apiName] or 0) + 1
                performanceMetrics.apiCallTimes[apiName] = (performanceMetrics.apiCallTimes[apiName] or 0) + elapsed
                performanceMetrics.totalCalls = performanceMetrics.totalCalls + 1
                performanceMetrics.totalTime = performanceMetrics.totalTime + elapsed
                
                -- Report to CommonAPI2 if available (periodically, not every call)
                if performanceMetrics.totalCalls % 100 == 0 then
                    reportPerformanceMetrics()
                end
            end
            return result
        else
            -- Log error but continue with fallback
            timetableHelper.logWarn("CommonAPI2 call failed, using fallback: %s", tostring(result))
        end
    end
    
    -- Use fallback function
    if fallbackFunc then
        local success, result = pcall(fallbackFunc, ...)
        if success then
            if performanceMetricsEnabled and startTime then
                local elapsed = os.clock() - startTime
                apiName = "native_fallback"
                performanceMetrics.apiCallCounts[apiName] = (performanceMetrics.apiCallCounts[apiName] or 0) + 1
                performanceMetrics.apiCallTimes[apiName] = (performanceMetrics.apiCallTimes[apiName] or 0) + elapsed
                performanceMetrics.totalCalls = performanceMetrics.totalCalls + 1
                performanceMetrics.totalTime = performanceMetrics.totalTime + elapsed
                
                -- Report to CommonAPI2 if available (periodically, not every call)
                if performanceMetrics.totalCalls % 100 == 0 then
                    reportPerformanceMetrics()
                end
            end
            return result
        else
            timetableHelper.logError("Fallback API call failed: %s", tostring(result))
            return nil
        end
    end
    
    return nil
end

-- Optimized entityExists check with caching
local function cachedEntityExists(entity, currentTime)
    if not entity then return false end
    
    -- Check cache first
    if entityExistsCache[entity] ~= nil then
        local cachedTime = entityExistsCacheTime[entity]
        if cachedTime and currentTime - cachedTime < ENTITY_CACHE_DURATION then
            return entityExistsCache[entity]
        end
    end
    
    -- Not in cache or expired, check API (use CommonAPI2 if available)
    local exists = safeCommonAPI2Call(
        commonapi2_available and commonapi.entityExists or nil,
        api.engine.entityExists,
        entity
    )
    
    if exists == nil then
        exists = false -- Default to false if both calls fail
    end
    
    entityExistsCache[entity] = exists
    entityExistsCacheTime[entity] = currentTime or timetableHelper.getTime()
    
    return exists
end

-- Optimized component access with caching
local function cachedGetComponent(entity, componentType, currentTime)
    if not entity or not componentType then return nil end
    
    -- Cache key: string concatenation is efficient for this use case
    local cacheKey = tostring(entity) .. "_" .. tostring(componentType)
    
    -- Check cache first
    if componentCache[cacheKey] ~= nil then
        local cachedTime = componentCacheTime[cacheKey]
        if cachedTime and currentTime - cachedTime < COMPONENT_CACHE_DURATION then
            return componentCache[cacheKey]
        end
    end
    
    -- Not in cache or expired, get from API (use CommonAPI2 if available)
    local component = safeCommonAPI2Call(
        commonapi2_available and commonapi.getComponent or nil,
        api.engine.getComponent,
        entity,
        componentType
    )
    
    componentCache[cacheKey] = component
    componentCacheTime[cacheKey] = currentTime or timetableHelper.getTime()
    
    return component
end

-- Centralized cache invalidation coordinator
local cacheInvalidationCallbacks = {
    entity = {},
    component = {},
    system = {},
    delay = {},
    networkGraph = {},
    timetable = {}
}

-- Register a cache invalidation callback
function timetableHelper.registerCacheInvalidation(cacheType, callback)
    if cacheInvalidationCallbacks[cacheType] then
        table.insert(cacheInvalidationCallbacks[cacheType], callback)
    end
end

-- Invalidate all caches of a specific type
function timetableHelper.invalidateCacheType(cacheType, ...)
    if cacheInvalidationCallbacks[cacheType] then
        for _, callback in ipairs(cacheInvalidationCallbacks[cacheType]) do
            pcall(callback, ...)
        end
    end
end

-- Invalidate all caches (useful for major events like game load)
function timetableHelper.invalidateAllCaches()
    for cacheType, _ in pairs(cacheInvalidationCallbacks) do
        timetableHelper.invalidateCacheType(cacheType)
    end
end

-- Export cache cleanup function for external use
function timetableHelper.cleanCaches(currentTime)
    cleanCaches(currentTime or timetableHelper.getTime())
end

-- Export cached entity exists for external use
function timetableHelper.entityExists(entity, currentTime)
    return cachedEntityExists(entity, currentTime)
end

-- Export cached component getter for external use
function timetableHelper.getComponent(entity, componentType, currentTime)
    return cachedGetComponent(entity, componentType, currentTime)
end

-- Station position cache for route finding optimization
local stationPositionCache = {}
local stationPositionCacheTime = {}
local STATION_POSITION_CACHE_DURATION = 30 -- Cache for 30 seconds

-- Get station position (cached)
function timetableHelper.getStationPosition(stationID, currentTime)
    if not stationID then return nil end
    
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Check cache first
    if stationPositionCache[stationID] then
        local cachedTime = stationPositionCacheTime[stationID]
        if cachedTime and currentTime - cachedTime < STATION_POSITION_CACHE_DURATION then
            return stationPositionCache[stationID]
        end
    end
    
    -- Not in cache or expired, get from component
    local stationComponent = cachedGetComponent(stationID, api.type.ComponentType.STATION_GROUP, currentTime)
    if stationComponent and stationComponent.position then
        local position = {
            x = stationComponent.position.x,
            y = stationComponent.position.y,
            z = stationComponent.position.z
        }
        stationPositionCache[stationID] = position
        stationPositionCacheTime[stationID] = currentTime
        return position
    end
    
    return nil
end

-- Batch get station positions
function timetableHelper.batchGetStationPositions(stationIDs, currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    local results = {}
    local uncachedStations = {}
    
    -- Check cache first
    for _, stationID in ipairs(stationIDs) do
        if stationPositionCache[stationID] then
            local cachedTime = stationPositionCacheTime[stationID]
            if cachedTime and currentTime - cachedTime < STATION_POSITION_CACHE_DURATION then
                results[stationID] = stationPositionCache[stationID]
            else
                table.insert(uncachedStations, stationID)
            end
        else
            table.insert(uncachedStations, stationID)
        end
    end
    
    -- Batch fetch uncached stations
    if #uncachedStations > 0 then
        local stationComponents = timetableHelper.batchGetLineComponents(uncachedStations, api.type.ComponentType.STATION_GROUP, currentTime)
        for _, stationID in ipairs(uncachedStations) do
            local component = stationComponents[stationID]
            if component and component.position then
                local position = {
                    x = component.position.x,
                    y = component.position.y,
                    z = component.position.z
                }
                results[stationID] = position
                stationPositionCache[stationID] = position
                stationPositionCacheTime[stationID] = currentTime
            end
        end
    end
    
    return results
end

-- Invalidate station position cache
function timetableHelper.invalidateStationPositionCache(stationID)
    if stationID then
        stationPositionCache[stationID] = nil
        stationPositionCacheTime[stationID] = nil
    else
        -- Clear all if no station specified
        stationPositionCache = {}
        stationPositionCacheTime = {}
    end
end

-- Re-check CommonAPI2 availability at runtime (callable from game_script context)
function timetableHelper.recheckCommonAPI2()
    if commonapi ~= nil and type(commonapi) == "table" then
        print("Timetables: Re-checking CommonAPI2 at runtime - detected!")
        if not commonapi2_available then
            commonapi2_available = true
            -- Re-initialize API references
            if commonapi._events ~= nil then
                commonapi2_events = commonapi._events
            end
            if commonapi.cmd ~= nil then
                commonapi2_cmd = commonapi.cmd
            elseif commonapi.commands ~= nil then
                commonapi2_cmd = commonapi.commands
            end
            if commonapi.log then
                commonapi2_logging_api = commonapi.log
            elseif commonapi.logging then
                commonapi2_logging_api = commonapi.logging
            elseif commonapi.logger then
                commonapi2_logging_api = commonapi.logger
            end
            if commonapi.localization then
                commonapi2_localization_api = commonapi.localization
            elseif commonapi.locale then
                commonapi2_localization_api = commonapi.locale
            elseif commonapi.i18n then
                commonapi2_localization_api = commonapi.i18n
            end
            if commonapi.error then
                commonapi2_error_api = commonapi.error
            elseif commonapi.exception then
                commonapi2_error_api = commonapi.exception
            elseif commonapi.errors then
                commonapi2_error_api = commonapi.errors
            end
            print("Timetables: CommonAPI2 re-initialized successfully at runtime")
        end
        return true
    end
    return false
end

-- Check if CommonAPI2 is available
function timetableHelper.isCommonAPI2Available()
    -- Try to re-check if not already available (for runtime initialization)
    if not commonapi2_available then
        timetableHelper.recheckCommonAPI2()
    end
    return commonapi2_available
end

-------------------------------------------------------------
---------------------- System Query Caching -----------------
-------------------------------------------------------------

-- Cached wrapper for line system queries (uses CommonAPI2 if available)
function timetableHelper.getLines(currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    
    if linesCache and (currentTime - linesCacheTime < LINES_CACHE_DURATION) then
        return linesCache
    end
    
    -- Use CommonAPI2 if available, otherwise fall back to native API
    linesCache = safeCommonAPI2Call(
        commonapi2_available and commonapi.system and commonapi.system.getLines or nil,
        api.engine.system.lineSystem.getLines
    ) or {}
    linesCacheTime = currentTime
    return linesCache
end

-- Cached wrapper for transport vehicle system queries (uses CommonAPI2 if available)
function timetableHelper.getLine2VehicleMap(currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    
    if lineVehiclesMapCache and (currentTime - lineVehiclesMapCacheTime < LINE_VEHICLES_MAP_CACHE_DURATION) then
        return lineVehiclesMapCache
    end
    
    -- Use CommonAPI2 if available, otherwise fall back to native API
    lineVehiclesMapCache = safeCommonAPI2Call(
        commonapi2_available and commonapi.system and commonapi.system.getLine2VehicleMap or nil,
        api.engine.system.transportVehicleSystem.getLine2VehicleMap
    ) or {}
    lineVehiclesMapCacheTime = currentTime
    return lineVehiclesMapCache
end

-- Cached wrapper for api.engine.system.transportVehicleSystem.getLineVehicles()
function timetableHelper.getLineVehicles(line, currentTime)
    -- For individual line queries, we can't cache as efficiently, but we can use the map cache
    currentTime = currentTime or timetableHelper.getTime()
    local map = timetableHelper.getLine2VehicleMap(currentTime)
    return map[line] or {}
end

-- Cached wrapper for transport vehicle system queries (uses CommonAPI2 if available)
function timetableHelper.getVehiclesWithState(state, currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Check if we have a cached result for this state
    if vehiclesWithStateCache and vehiclesWithStateCacheState == state and 
       (currentTime - vehiclesWithStateCacheTime < VEHICLES_WITH_STATE_CACHE_DURATION) then
        return vehiclesWithStateCache
    end
    
    -- Use CommonAPI2 if available, otherwise fall back to native API
    vehiclesWithStateCache = safeCommonAPI2Call(
        commonapi2_available and commonapi.system and commonapi.system.getVehiclesWithState or nil,
        function(s) return api.engine.system.transportVehicleSystem.getVehiclesWithState(s) end,
        state
    ) or {}
    vehiclesWithStateCacheState = state
    vehiclesWithStateCacheTime = currentTime
    return vehiclesWithStateCache
end

-- Wrapper for transport vehicle system queries (uses CommonAPI2 if available)
-- This is less frequently used, so no caching for now (can be added if needed)
function timetableHelper.getLineStopVehicles(line, stop)
    -- Use CommonAPI2 if available, otherwise fall back to native API
    return safeCommonAPI2Call(
        commonapi2_available and commonapi.system and commonapi.system.getLineStopVehicles or nil,
        function(l, s) return api.engine.system.transportVehicleSystem.getLineStopVehicles(l, s) end,
        line,
        stop
    ) or {}
end

-- Batch system query operations (if CommonAPI2 supports them)
function timetableHelper.batchGetLines(lineIds, currentTime)
    if not lineIds or #lineIds == 0 then
        return {}
    end
    
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Try CommonAPI2 batch system query if available
    if commonapi2_available and commonapi.system then
        if commonapi.system.batchGetLines then
            local success, results = pcall(function()
                return commonapi.system.batchGetLines(lineIds)
            end)
            if success and results then
                return results
            end
        end
    end
    
    -- Fallback to individual queries
    local results = {}
    for _, lineId in ipairs(lineIds) do
        -- Check if line exists in cached lines list
        local lines = timetableHelper.getLines(currentTime)
        if lines[lineId] then
            results[lineId] = lines[lineId]
        end
    end
    return results
end

-- Batch get vehicles (if CommonAPI2 supports it)
function timetableHelper.batchGetVehicles(vehicleIds, currentTime)
    if not vehicleIds or #vehicleIds == 0 then
        return {}
    end
    
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Try CommonAPI2 batch system query if available
    if commonapi2_available and commonapi.system then
        if commonapi.system.batchGetVehicles then
            local success, results = pcall(function()
                return commonapi.system.batchGetVehicles(vehicleIds)
            end)
            if success and results then
                return results
            end
        end
    end
    
    -- Fallback to individual component queries (already batched via getComponents)
    return timetableHelper.batchGetVehicleComponents(vehicleIds, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
end

-- Batch get stations (if CommonAPI2 supports it)
function timetableHelper.batchGetStations(stationIds, currentTime)
    if not stationIds or #stationIds == 0 then
        return {}
    end
    
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Try CommonAPI2 batch system query if available
    if commonapi2_available and commonapi.system then
        if commonapi.system.batchGetStations then
            local success, results = pcall(function()
                return commonapi.system.batchGetStations(stationIds)
            end)
            if success and results then
                return results
            end
        end
    end
    
    -- Fallback to individual component queries (already batched via getComponents)
    return timetableHelper.batchGetLineComponents(stationIds, api.type.ComponentType.STATION_GROUP, currentTime)
end

-- Wrapper for game.interface.getEntity() - uses cached component access when possible
function timetableHelper.getEntity(entityId)
    -- Try CommonAPI2 interface API if available
    if commonapi2_available then
        if commonapi.getEntity then
            local success, entity = pcall(function()
                return commonapi.getEntity(entityId)
            end)
            if success and entity then
                return entity
            end
        elseif commonapi.interface and commonapi.interface.getEntity then
            local success, entity = pcall(function()
                return commonapi.interface.getEntity(entityId)
            end)
            if success and entity then
                return entity
            end
        end
    end
    
    -- Fallback to native game.interface API
    if game and game.interface and game.interface.getEntity then
        return game.interface.getEntity(entityId)
    end
    return nil
end

-- Wrapper for game.interface.getLines()
function timetableHelper.getInterfaceLines()
    -- Try CommonAPI2 interface API if available
    if commonapi2_available then
        if commonapi.getLines then
            local success, lines = pcall(function()
                return commonapi.getLines()
            end)
            if success and lines then
                return lines
            end
        elseif commonapi.interface and commonapi.interface.getLines then
            local success, lines = pcall(function()
                return commonapi.interface.getLines()
            end)
            if success and lines then
                return lines
            end
        end
    end
    
    -- Fallback to native game.interface API
    if game and game.interface and game.interface.getLines then
        return game.interface.getLines()
    end
    return {}
end

-- GUI utility function wrappers with CommonAPI2 support
local guiElementCache = {}

-- Wrapper for api.gui.util.getById() with caching
function timetableHelper.getGUIElementById(elementId)
    if not elementId then return nil end
    
    -- Check cache first
    if guiElementCache[elementId] then
        return guiElementCache[elementId]
    end
    
    -- Try CommonAPI2 GUI API if available
    if commonapi2_available then
        if commonapi.gui and commonapi.gui.getElementById then
            local success, element = pcall(function()
                return commonapi.gui.getElementById(elementId)
            end)
            if success and element then
                guiElementCache[elementId] = element
                return element
            end
        elseif commonapi.getGUIElement then
            local success, element = pcall(function()
                return commonapi.getGUIElement(elementId)
            end)
            if success and element then
                guiElementCache[elementId] = element
                return element
            end
        end
    end
    
    -- Fallback to native API
    if api and api.gui and api.gui.util and api.gui.util.getById then
        local element = api.gui.util.getById(elementId)
        if element then
            guiElementCache[elementId] = element
        end
        return element
    end
    
    return nil
end

-- Wrapper for api.gui.util.getMouseScreenPos() with CommonAPI2 support
function timetableHelper.getMouseScreenPos()
    -- Try CommonAPI2 GUI API if available
    if commonapi2_available then
        if commonapi.gui and commonapi.gui.getMousePosition then
            local success, pos = pcall(function()
                return commonapi.gui.getMousePosition()
            end)
            if success and pos then
                return pos
            end
        elseif commonapi.getMousePos then
            local success, pos = pcall(function()
                return commonapi.getMousePos()
            end)
            if success and pos then
                return pos
            end
        end
    end
    
    -- Fallback to native API
    if api and api.gui and api.gui.util and api.gui.util.getMouseScreenPos then
        return api.gui.util.getMouseScreenPos()
    end
    
    return {x = 0, y = 0}
end

-- Wrapper for api.util.getLanguage() with CommonAPI2 support and caching
local languageCache = nil
function timetableHelper.getLanguage()
    -- Check cache first
    if languageCache then
        return languageCache
    end
    
    -- Try CommonAPI2 localization API if available
    if commonapi2_available then
        if commonapi.localization and commonapi.localization.getLanguage then
            local success, lang = pcall(function()
                return commonapi.localization.getLanguage()
            end)
            if success and lang then
                languageCache = lang
                return lang
            end
        elseif commonapi.getLanguage then
            local success, lang = pcall(function()
                return commonapi.getLanguage()
            end)
            if success and lang then
                languageCache = lang
                return lang
            end
        elseif commonapi.locale and commonapi.locale.getLanguage then
            local success, lang = pcall(function()
                return commonapi.locale.getLanguage()
            end)
            if success and lang then
                languageCache = lang
                return lang
            end
        end
    end
    
    -- Fallback to native API
    if api and api.util and api.util.getLanguage then
        languageCache = api.util.getLanguage()
        return languageCache
    end
    
    return "en" -- Default to English
end

-- Invalidate GUI element cache
function timetableHelper.invalidateGUIElementCache(elementId)
    if elementId then
        guiElementCache[elementId] = nil
    else
        guiElementCache = {}
    end
end

-------------------------------------------------------------
---------------------- Logging ----------------------
-------------------------------------------------------------

-- Structured logging with CommonAPI2 support
-- Levels: "debug", "info", "warn", "error"
function timetableHelper.log(level, message, ...)
    if not level or not message then return end
    
    -- Format message with arguments if provided
    local formattedMessage = message
    if select('#', ...) > 0 then
        formattedMessage = string.format(message, ...)
    end
    
    -- Try CommonAPI2 logging API if available
    if commonapi2_available and commonapi2_logging_api then
        local success = pcall(function()
            if commonapi2_logging_api[level] then
                commonapi2_logging_api[level](formattedMessage)
                return
            elseif commonapi2_logging_api.log then
                commonapi2_logging_api.log(level, formattedMessage)
                return
            elseif commonapi2_logging_api.write then
                commonapi2_logging_api.write(level, formattedMessage)
                return
            end
        end)
        if success then
            return
        end
    end
    
    -- Fallback to print with level prefix
    local levelPrefix = string.upper(level or "INFO")
    print(string.format("[Timetables %s] %s", levelPrefix, formattedMessage))
end

-- Convenience functions for each log level
function timetableHelper.logDebug(message, ...)
    timetableHelper.log("debug", message, ...)
end

function timetableHelper.logInfo(message, ...)
    timetableHelper.log("info", message, ...)
end

function timetableHelper.logWarn(message, ...)
    timetableHelper.log("warn", message, ...)
end

function timetableHelper.logError(message, ...)
    timetableHelper.log("error", message, ...)
end

-------------------------------------------------------------
---------------------- Localization ----------------------
-------------------------------------------------------------

-- Format localized string with CommonAPI2 support
function timetableHelper.formatLocalizedString(key, ...)
    if not key then return "" end
    
    -- Capture varargs into a table
    local args = {...}
    local arg_count = select('#', ...)
    
    -- Try CommonAPI2 localization API if available
    if commonapi2_available and commonapi2_localization_api then
        if commonapi2_localization_api.format then
            local success, result = pcall(function()
                return commonapi2_localization_api.format(key, unpack(args))
            end)
            if success and result then
                return result
            end
        elseif commonapi2_localization_api.translate then
            local success, result = pcall(function()
                local translated = commonapi2_localization_api.translate(key)
                if arg_count > 0 then
                    return string.format(translated, unpack(args))
                end
                return translated
            end)
            if success and result then
                return result
            end
        end
    end
    
    -- Fallback to manual formatting
    if arg_count > 0 then
        return string.format(key, unpack(args))
    end
    return key
end

-- Format number according to locale
function timetableHelper.formatLocalizedNumber(number)
    if not number then return "0" end
    
    -- Try CommonAPI2 localization API if available
    if commonapi2_available and commonapi2_localization_api then
        if commonapi2_localization_api.formatNumber then
            local success, result = pcall(function()
                return commonapi2_localization_api.formatNumber(number)
            end)
            if success and result then
                return result
            end
        end
    end
    
    -- Fallback to manual formatting
    return tostring(number)
end

-- Format time according to locale
function timetableHelper.formatLocalizedTime(timeInSeconds)
    if not timeInSeconds then return "00:00" end
    
    -- Try CommonAPI2 localization API if available
    if commonapi2_available and commonapi2_localization_api then
        if commonapi2_localization_api.formatTime then
            local success, result = pcall(function()
                return commonapi2_localization_api.formatTime(timeInSeconds)
            end)
            if success and result then
                return result
            end
        end
    end
    
    -- Fallback to manual formatting (HH:MM:SS)
    local hours = math.floor(timeInSeconds / 3600)
    local minutes = math.floor((timeInSeconds % 3600) / 60)
    local seconds = math.floor(timeInSeconds % 60)
    
    if hours > 0 then
        return string.format("%02d:%02d:%02d", hours, minutes, seconds)
    else
        return string.format("%02d:%02d", minutes, seconds)
    end
end

-------------------------------------------------------------
---------------------- Error Reporting ----------------------
-------------------------------------------------------------

-- Report error to CommonAPI2 error system if available
function timetableHelper.reportError(error, context)
    if not error then return end
    
    local errorMessage = tostring(error)
    local contextInfo = context or {}
    
    -- Build error context with stack trace
    local errorContext = {
        message = errorMessage,
        context = contextInfo,
        stackTrace = debug.traceback()
    }
    
    -- Try CommonAPI2 error reporting API if available
    if commonapi2_available and commonapi2_error_api then
        if commonapi2_error_api.report then
            local success = pcall(function()
                commonapi2_error_api.report(errorContext)
            end)
            if success then
                return
            end
        elseif commonapi2_error_api.log then
            local success = pcall(function()
                commonapi2_error_api.log(errorContext)
            end)
            if success then
                return
            end
        elseif commonapi2_error_api.record then
            local success = pcall(function()
                commonapi2_error_api.record(errorContext)
            end)
            if success then
                return
            end
        end
    end
    
    -- Fallback to logging
    timetableHelper.logError("Error: %s\nContext: %s\nStack: %s", 
        errorMessage, 
        type(contextInfo) == "table" and table.concat(contextInfo, ", ") or tostring(contextInfo),
        errorContext.stackTrace)
end

-- Batch get line components (for performance optimization)
function timetableHelper.batchGetLineComponents(lineIds, componentType, currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    local results = {}
    
    -- Try CommonAPI2 batch API if available
    if commonapi2_available and commonapi.getComponents then
        local success, batchResults = pcall(function()
            return commonapi.getComponents(lineIds, componentType)
        end)
        if success and batchResults then
            -- Merge batch results with individual lookups for missing entries
            for _, lineId in ipairs(lineIds) do
                if batchResults[lineId] then
                    results[lineId] = batchResults[lineId]
                    -- Update cache
                    local cacheKey = tostring(lineId) .. "_" .. tostring(componentType)
                    componentCache[cacheKey] = batchResults[lineId]
                    componentCacheTime[cacheKey] = currentTime
                else
                    -- Fallback to individual lookup
                    results[lineId] = cachedGetComponent(lineId, componentType, currentTime)
                end
            end
            return results
        end
    end
    
    -- Fallback to individual cached calls
    for _, lineId in ipairs(lineIds) do
        results[lineId] = cachedGetComponent(lineId, componentType, currentTime)
    end
    
    return results
end

-- Batch get vehicle components (for performance optimization)
function timetableHelper.batchGetVehicleComponents(vehicleIds, componentType, currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    local results = {}
    
    -- Try CommonAPI2 batch API if available
    if commonapi2_available and commonapi.getComponents then
        local success, batchResults = pcall(function()
            return commonapi.getComponents(vehicleIds, componentType)
        end)
        if success and batchResults then
            -- Merge batch results with individual lookups for missing entries
            for _, vehicleId in ipairs(vehicleIds) do
                if batchResults[vehicleId] then
                    results[vehicleId] = batchResults[vehicleId]
                    -- Update cache
                    local cacheKey = tostring(vehicleId) .. "_" .. tostring(componentType)
                    componentCache[cacheKey] = batchResults[vehicleId]
                    componentCacheTime[cacheKey] = currentTime
                else
                    -- Fallback to individual lookup
                    results[vehicleId] = cachedGetComponent(vehicleId, componentType, currentTime)
                end
            end
            return results
        end
    end
    
    -- Fallback to individual cached calls
    for _, vehicleId in ipairs(vehicleIds) do
        results[vehicleId] = cachedGetComponent(vehicleId, componentType, currentTime)
    end
    
    return results
end

-- Invalidate system query caches (call when lines/vehicles change)
function timetableHelper.invalidateSystemCaches()
    linesCache = nil
    linesCacheTime = 0
    lineVehiclesMapCache = nil
    lineVehiclesMapCacheTime = 0
    vehiclesWithStateCache = nil
    vehiclesWithStateCacheState = nil
    vehiclesWithStateCacheTime = 0
end

-- Invalidate entity and component caches for a specific entity
function timetableHelper.invalidateEntityCache(entity)
    if entity then
        entityExistsCache[entity] = nil
        entityExistsCacheTime[entity] = nil
        -- Invalidate all component caches for this entity
        local entityStr = tostring(entity) .. "_"
        for key, _ in pairs(componentCache) do
            if string.sub(key, 1, #entityStr) == entityStr then
                componentCache[key] = nil
                componentCacheTime[key] = nil
            end
        end
    end
end

-- Event forwarding system for GUI and other listeners
local eventListeners = {
    onVehicleStateChanged = {},
    onVehicleArrived = {},
    onVehicleDeparted = {},
    onVehicleDestroyed = {},
    onLineModified = {},
    onLineCreated = {},
    onLineDestroyed = {},
    onStationModified = {},
    onStationCreated = {},
    onStationDestroyed = {}
}

-- Register an event listener
function timetableHelper.addEventListener(eventType, callback)
    if eventListeners[eventType] then
        table.insert(eventListeners[eventType], callback)
    end
end

-- Unregister an event listener
function timetableHelper.removeEventListener(eventType, callback)
    if eventListeners[eventType] then
        for i, listener in ipairs(eventListeners[eventType]) do
            if listener == callback then
                table.remove(eventListeners[eventType], i)
                break
            end
        end
    end
end

-- Notify all listeners of an event
local function notifyListeners(eventType, ...)
    if eventListeners[eventType] then
        for _, listener in ipairs(eventListeners[eventType]) do
            pcall(listener, ...)
        end
    end
end

-- Initialize CommonAPI2 event subscriptions for cache invalidation
local function initializeCommonAPI2Events()
    if not commonapi2_events then
        return
    end
    
    -- Subscribe to entity deletion events
    if commonapi2_events.onEntityDeleted then
        commonapi2_events.onEntityDeleted:subscribe(function(entity)
            timetableHelper.invalidateEntityCache(entity)
            timetableHelper.invalidateCacheType("entity", entity)
        end)
    end
    
    -- Subscribe to line creation/deletion events
    if commonapi2_events.onLineCreated then
        commonapi2_events.onLineCreated:subscribe(function(line)
            timetableHelper.invalidateSystemCaches()
            timetableHelper.invalidateCacheType("system")
            timetableHelper.invalidateCacheType("networkGraph")
            timetableHelper.invalidateCacheType("timetable", line)
            notifyListeners("onLineCreated", line)
            notifyListeners("onLineModified", line)
        end)
    end
    
    if commonapi2_events.onLineDeleted or commonapi2_events.onLineDestroyed then
        local onLineDestroyed = commonapi2_events.onLineDeleted or commonapi2_events.onLineDestroyed
        onLineDestroyed:subscribe(function(line)
            timetableHelper.invalidateSystemCaches()
            timetableHelper.invalidateEntityCache(line)
            timetableHelper.invalidateCacheType("system")
            timetableHelper.invalidateCacheType("networkGraph")
            timetableHelper.invalidateCacheType("timetable", line)
            notifyListeners("onLineDestroyed", line)
            notifyListeners("onLineModified", line)
        end)
    end
    
    -- Subscribe to line modification events (if available)
    if commonapi2_events.onLineModified then
        commonapi2_events.onLineModified:subscribe(function(line)
            timetableHelper.invalidateSystemCaches()
            timetableHelper.invalidateEntityCache(line)
            timetableHelper.invalidateCacheType("system")
            timetableHelper.invalidateCacheType("networkGraph")
            timetableHelper.invalidateCacheType("timetable", line)
            notifyListeners("onLineModified", line)
        end)
    end
    
    -- Subscribe to vehicle creation events (if available)
    if commonapi2_events.onVehicleCreated then
        commonapi2_events.onVehicleCreated:subscribe(function(vehicle)
            -- Invalidate vehicle state cache when new vehicles are created
            vehiclesWithStateCache = nil
            vehiclesWithStateCacheState = nil
            vehiclesWithStateCacheTime = 0
        end)
    end
    
    -- Subscribe to vehicle destruction events (if available)
    if commonapi2_events.onVehicleDestroyed then
        commonapi2_events.onVehicleDestroyed:subscribe(function(vehicle)
            -- Clean up caches when vehicles are destroyed
            timetableHelper.invalidateEntityCache(vehicle)
            vehiclesWithStateCache = nil
            vehiclesWithStateCacheState = nil
            vehiclesWithStateCacheTime = 0
            notifyListeners("onVehicleDestroyed", vehicle)
        end)
    end
    
    -- Subscribe to vehicle state change events (if available)
    if commonapi2_events.onVehicleStateChanged then
        commonapi2_events.onVehicleStateChanged:subscribe(function(vehicle)
            -- Invalidate vehicle-specific caches
            timetableHelper.invalidateEntityCache(vehicle)
            timetableHelper.invalidateCacheType("entity", vehicle)
            timetableHelper.invalidateCacheType("component", vehicle)
            -- Invalidate vehicle state cache
            vehiclesWithStateCache = nil
            vehiclesWithStateCacheState = nil
            vehiclesWithStateCacheTime = 0
            -- Notify listeners
            notifyListeners("onVehicleStateChanged", vehicle)
        end)
    end
    
    -- Subscribe to vehicle arrival events (if available)
    if commonapi2_events.onVehicleArrived then
        commonapi2_events.onVehicleArrived:subscribe(function(vehicle, station, line)
            notifyListeners("onVehicleArrived", vehicle, station, line)
        end)
    end
    
    -- Subscribe to vehicle departure events (if available)
    if commonapi2_events.onVehicleDeparted then
        commonapi2_events.onVehicleDeparted:subscribe(function(vehicle, station, line)
            notifyListeners("onVehicleDeparted", vehicle, station, line)
        end)
    end
    
    -- Subscribe to station creation events (if available)
    if commonapi2_events.onStationCreated then
        commonapi2_events.onStationCreated:subscribe(function(station)
            timetableHelper.invalidateCacheType("networkGraph")
            timetableHelper.invalidateSystemCaches()
            notifyListeners("onStationCreated", station)
        end)
    end
    
    -- Subscribe to station destruction events (if available)
    if commonapi2_events.onStationDestroyed then
        commonapi2_events.onStationDestroyed:subscribe(function(station)
            timetableHelper.invalidateEntityCache(station)
            timetableHelper.invalidateStationPositionCache(station)
            timetableHelper.invalidateCacheType("entity", station)
            timetableHelper.invalidateCacheType("networkGraph")
            notifyListeners("onStationDestroyed", station)
        end)
    end
    
    -- Subscribe to station modification events (if available)
    if commonapi2_events.onStationModified then
        commonapi2_events.onStationModified:subscribe(function(station)
            timetableHelper.invalidateEntityCache(station)
            timetableHelper.invalidateCacheType("entity", station)
            timetableHelper.invalidateCacheType("networkGraph")
            timetableHelper.invalidateStationPositionCache(station)
            notifyListeners("onStationModified", station)
        end)
    end
    
    -- Subscribe to component change events (if available)
    if commonapi2_events.onComponentChanged then
        commonapi2_events.onComponentChanged:subscribe(function(entity, componentType)
            -- Invalidate component cache for this entity
            timetableHelper.invalidateEntityCache(entity)
            timetableHelper.invalidateCacheType("component", entity, componentType)
        end)
    end
end

-- Initialize events on module load
if commonapi2_available then
    initializeCommonAPI2Events()
    
    -- Initialize network graph cache events after a short delay to avoid circular dependency
    pcall(function()
        -- Use a coroutine or delayed call to initialize network graph events
        -- This ensures timetable_helper is fully loaded first
        local networkGraphCache = require "celmi/timetables/network_graph_cache"
        if networkGraphCache and networkGraphCache.initializeEvents then
            networkGraphCache.initializeEvents()
        end
    end)
end

-- flatten a table into a string for printing
-- from https://stackoverflow.com/a/27028488
-- TF2 also uses debugPrint(object) function where object is a table, string, or other lua element to print
function timetableHelper.dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            s = s .. '['..k..'] = ' .. timetableHelper.dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

-------------------------------------------------------------
---------------------- Vehicle related ----------------------
-------------------------------------------------------------

function timetableHelper.getVehicleInfo(vehicle, currentTime)
    -- Use cached component access for better performance
    return cachedGetComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
end


function timetableHelper.isVehicleAtTerminal(vehicleInfo)
    return vehicleInfo.state == api.type.enum.TransportVehicleState.AT_TERMINAL
end

-- returns [lineID] indext by VehicleID : String
function timetableHelper.getAllVehicles(currentTime)
    local res = {}
    local lineVehiclesMap = timetableHelper.getLine2VehicleMap(currentTime)
    for line,vehicles in pairs(lineVehiclesMap) do
        for _,vehicle in pairs(vehicles) do
            res[vehicle] = line
        end
    end
    return res
end

---@param line number
-- returns [{stopIndex: Number, vehicle: Number, atTerminal: Bool, countStr: "SINGLE"| "MANY" }]
--         indext by StopIndes : string
function timetableHelper.getTrainLocations(line, currentTime)
    local res = {}
    currentTime = currentTime or timetableHelper.getTime()
    local vehicles = timetableHelper.getLineVehicles(line, currentTime)
    for _,v in pairs(vehicles) do
        local vehicle = cachedGetComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
        if vehicle then
            local atTerminal = vehicle.state == api.type.enum.TransportVehicleState.AT_TERMINAL
        if res[vehicle.stopIndex] then
            local prevAtTerminal = res[vehicle.stopIndex].atTerminal
            res[vehicle.stopIndex] = {
                stopIndex = vehicle.stopIndex,
                vehicle = v,
                atTerminal = (atTerminal or prevAtTerminal),
                countStr = "MANY"
            }
        else
            res[vehicle.stopIndex] = {
                stopIndex = vehicle.stopIndex,
                vehicle = v,
                atTerminal = atTerminal,
                countStr = "SINGLE"
            }
        end
        end
    end
    return res
end

---@param line number
-- returns [ vehicle:Number ]
function timetableHelper.getVehiclesOnLine(line, currentTime)
    return timetableHelper.getLineVehicles(line, currentTime)
end

---@param vehicle number | string
-- returns stationIndex : Number
function timetableHelper.getCurrentStation(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end
    if not vehicle then return -1 end
    local res = cachedGetComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE, timetableHelper.getTime())
    if res then
        return res.stopIndex + 1
    end
    return -1
end

---@param vehicle number | string
-- returns lineID : Number
function timetableHelper.getCurrentLine(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end
    if not vehicle then return -1 end

    local res = cachedGetComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE, timetableHelper.getTime())
    if res and res.line then return res.line else return -1 end
end


---@param vehicle number | string
-- returns Bool
function timetableHelper.isInStation(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local v = cachedGetComponent(tonumber(vehicle), api.type.ComponentType.TRANSPORT_VEHICLE, timetableHelper.getTime())
    return v and v.state == api.type.enum.TransportVehicleState.AT_TERMINAL
end

-- CommonAPI2 command creation helper
local function makeCommand(commandType, ...)
    -- Try CommonAPI2 command creation API if available
    if commonapi2_available and commonapi2_cmd then
        if commonapi2_cmd.make then
            local makeFunc = commonapi2_cmd.make[commandType]
            if makeFunc then
                local success, cmd = pcall(makeFunc, ...)
                if success and cmd then
                    return cmd
                end
            end
        elseif commonapi2_cmd.create then
            local createFunc = commonapi2_cmd.create[commandType]
            if createFunc then
                local success, cmd = pcall(createFunc, ...)
                if success and cmd then
                    return cmd
                end
            end
        end
    end
    -- Fallback to native API
    if api.cmd.make and api.cmd.make[commandType] then
        return api.cmd.make[commandType](...)
    end
    return nil
end

-- Command batch queue for batching multiple commands
local commandBatch = {}
local commandBatchTimer = 0
local COMMAND_BATCH_DELAY = 0.1 -- Batch commands within 100ms

-- CommonAPI2 command wrapper helper
local function sendCommand(command)
    if commonapi2_available and commonapi2_cmd then
        -- Try CommonAPI2 command API
        if commonapi2_cmd.sendCommand then
            return commonapi2_cmd.sendCommand(command)
        elseif commonapi2_cmd.send then
            return commonapi2_cmd.send(command)
        elseif commonapi2_cmd.execute then
            return commonapi2_cmd.execute(command)
        end
    end
    -- Fallback to native API
    return api.cmd.sendCommand(command)
end

-- Send batch of commands (if CommonAPI2 supports it)
local function sendCommandBatch(commands)
    if not commands or #commands == 0 then
        return false
    end
    
    -- Try CommonAPI2 batch command API
    if commonapi2_available and commonapi2_cmd then
        if commonapi2_cmd.sendBatch then
            local success = pcall(function()
                return commonapi2_cmd.sendBatch(commands)
            end)
            if success then
                return true
            end
        elseif commonapi2_cmd.sendCommands then
            local success = pcall(function()
                return commonapi2_cmd.sendCommands(commands)
            end)
            if success then
                return true
            end
        elseif commonapi2_cmd.executeBatch then
            local success = pcall(function()
                return commonapi2_cmd.executeBatch(commands)
            end)
            if success then
                return true
            end
        end
    end
    
    -- Fallback to individual commands
    for _, cmd in ipairs(commands) do
        sendCommand(cmd)
    end
    return true
end

-- Queue command for batch sending
local function queueCommandForBatch(command)
    table.insert(commandBatch, command)
    commandBatchTimer = os.clock()
end

-- Flush command batch (call periodically)
function timetableHelper.flushCommandBatch()
    if #commandBatch > 0 then
        sendCommandBatch(commandBatch)
        commandBatch = {}
        commandBatchTimer = 0
    end
end

-- Send command immediately or queue for batch
local function sendCommandOrQueue(command, immediate)
    if immediate then
        return sendCommand(command)
    else
        -- Check if we should flush existing batch
        local currentTime = os.clock()
        if #commandBatch > 0 and (currentTime - commandBatchTimer > COMMAND_BATCH_DELAY) then
            timetableHelper.flushCommandBatch()
        end
        queueCommandForBatch(command)
        return true
    end
end

---@param vehicle number | string
-- returns Null
function timetableHelper.stopAutoVehicleDeparture(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local success, err = pcall(function()
        local cmd = makeCommand("setVehicleManualDeparture", vehicle, true)
        if cmd then
            sendCommandOrQueue(cmd, true) -- Send immediately for vehicle control
        else
            error("Failed to create command")
        end
    end)
    if not success then
        print("Timetables: Error stopping auto vehicle departure: " .. tostring(err))
    end
end

---@param vehicle number | string
-- returns Null
function timetableHelper.restartAutoVehicleDeparture(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local success, err = pcall(function()
        local cmd = makeCommand("setVehicleManualDeparture", vehicle, false)
        if cmd then
            sendCommandOrQueue(cmd, true) -- Send immediately for vehicle control
        else
            error("Failed to create command")
        end
    end)
    if not success then
        print("Timetables: Error restarting auto vehicle departure: " .. tostring(err))
    end
end

---@param vehicle number | string
-- returns Null
function timetableHelper.departVehicle(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local success, err = pcall(function()
        local cmd = makeCommand("setVehicleShouldDepart", vehicle)
        if cmd then
            sendCommandOrQueue(cmd, true) -- Send immediately for vehicle control
        else
            error("Failed to create command")
        end
    end)
    if not success then
        print("Timetables: Error departing vehicle: " .. tostring(err))
    end
end

function timetableHelper.getVehiclesAtStop(line, stop)
    return timetableHelper.getLineStopVehicles(line, stop)
end

---@param vehicle number | string
-- returns departure time of previous vehicle
function timetableHelper.getPreviousDepartureTime(stop, vehicles, vehiclesWaiting)
    if type(stop) == "string" then stop = tonumber(stop) end
    if not(type(stop) == "number") then print("Expected String or Number") return false end

    local departureTimes = {}
    local currentTime = timetableHelper.getTime()
    for _,v in pairs(vehicles) do
        -- append to a list using a[#a + 1] = new_item
        local lineVehicle = cachedGetComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
        if lineVehicle and lineVehicle.lineStopDepartures and lineVehicle.lineStopDepartures[stop] then
            departureTimes[#departureTimes + 1] = lineVehicle.lineStopDepartures[stop]/1000
        end
    end

    for _, vehicleWaiting in pairs(vehiclesWaiting) do
        departureTimes[#departureTimes + 1] = vehicleWaiting.departureTime
    end

    return (timetableHelper.maximumArray(departureTimes))
end

---@param vehicle number | string
-- returns Time in seconds and -1 in case of an error
function timetableHelper.getTimeUntilDepartureReady(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end

    local v = cachedGetComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE, timetableHelper.getTime())
    if v and v.timeUntilCloseDoors then return v.timeUntilCloseDoors else return -1 end
end

-------------------------------------------------------------
---------------------- Line related -------------------------
-------------------------------------------------------------

---@param lineType string, eg "RAIL", "ROAD", "TRAM", "WATER", "AIR"
-- returns Bool
function timetableHelper.isLineOfType(lineType, currentTime)
    local lines = timetableHelper.getLines(currentTime)
    local res = {}
    for k,l in pairs(lines) do
        res[k] = timetableHelper.lineHasType(l, lineType, currentTime)
    end
    return res
end

---@param line  number | string
---@param lineType string, eg "RAIL", "ROAD", "TRAM", "WATER", "AIR"
-- returns Bool
function timetableHelper.lineHasType(line, lineType, currentTime)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then print("Expected String or Number") return -1 end

    local vehicles = timetableHelper.getLineVehicles(line, currentTime)
    if vehicles and vehicles[1] then
        local component = cachedGetComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
        if component and component.carrier then
            return component.carrier  == api.type.enum.Carrier[lineType]
        end
    end
    return false
end

-- similar function in timetable_colors.lua stylesheet, import is not possible
-- if you change it here, also change it there!
local function getColorString(r, g, b)
    local x = string.format("%03.0f", (r * 100))
    local y = string.format("%03.0f", (g * 100))
    local z = string.format("%03.0f", (b * 100))
    return x .. y .. z
end

---@param line number | string
-- returns String, RGB value string eg: "204060" with Red 20, Green 40, Blue 60
function timetableHelper.getLineColour(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "default" end
    local colour = cachedGetComponent(line, api.type.ComponentType.COLOR, timetableHelper.getTime())
    if (colour and  colour.color) then
        return getColorString(colour.color.x, colour.color.y, colour.color.z)
    else
        return "default"
    end
end

---@param line number | string
-- returns lineName : String
function timetableHelper.getLineName(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end

    -- CommonAPI2 is always available, no need for pcall wrapper
    local component = cachedGetComponent(line, api.type.ComponentType.NAME, timetableHelper.getTime())
    if component and component.name then
        return component.name
    else
        return "ERROR"
    end
end

---@param line number | string
-- returns lineFrequency : String, formatted '%M:%S'
function timetableHelper.getFrequencyString(line)
    local frequency = timetableHelper.getFrequencyMinSec(line)
    if frequency == -1 then return "ERROR" end
    if frequency == -2 then return "--" end

    return frequency.min .. ":" .. string.format("%02d", frequency.sec)
end

function timetableHelper.getFrequencyMinSec(line)
    local frequency = timetableHelper.getFrequency(line)
    if frequency <= 0 then return frequency end
    return { min = math.floor(frequency / 60), sec = math.floor(frequency % 60) }
end

---@param line number | string
-- returns lineFrequency in seconds
function timetableHelper.getFrequency(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return -1 end

    local lineEntity = timetableHelper.getEntity(line)

    if lineEntity and lineEntity.frequency then
        if lineEntity.frequency == 0 then return -2 end
        return 1 / lineEntity.frequency
        
    else
        return -2
    end
end

-- returns [{id : number, name : String}]
function timetableHelper.getAllLines(currentTime)
    local res = {}
    local ls = timetableHelper.getLines(currentTime)
    currentTime = currentTime or timetableHelper.getTime()

    for k,l in pairs(ls) do
        local lineName = cachedGetComponent(l, api.type.ComponentType.NAME, currentTime)
        if lineName and lineName.name then
            res[k] = {id = l, name = lineName.name}
        else
            res[k] = {id = l, name = "ERROR"}
        end
    end

    return res
end

-- returns [lineID]
function timetableHelper.lineExists(lineID, currentTime)
    local apiLines = timetableHelper.getLines(currentTime)

    for apiLineNr, apiLineID in pairs(apiLines) do
        if tonumber(lineID) == tonumber(apiLineID) then return true end
    end

    return false
end

---@param line number | string
-- returns [time: Number] Array indexed by station index in sec starting with index 1
function timetableHelper.getLegTimes(line, currentTime)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end
    currentTime = currentTime or timetableHelper.getTime()
    local vehicleLineMap = timetableHelper.getLine2VehicleMap(currentTime)
    if vehicleLineMap[line] == nil or vehicleLineMap[line][1] == nil then return {}end
    local vehicle = vehicleLineMap[line][1]
    local vehicleObject = cachedGetComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
    if vehicleObject and vehicleObject.sectionTimes then
        return vehicleObject.sectionTimes
    else
        return {}
    end
end

-- Predict arrival time for a vehicle at a target station
-- Uses current position, historical section times, and current delay status
---@param vehicle number The vehicle ID
---@param targetStation number The target station index on the line
---@return number|nil Predicted arrival time in seconds, or nil if prediction unavailable
function timetableHelper.predictArrivalTime(vehicle, targetStation)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then return nil end
    if not targetStation then return nil end
    
    local vehicleInfo = timetableHelper.getVehicleInfo(vehicle)
    if not vehicleInfo then return nil end
    
    local currentStop = vehicleInfo.stopIndex + 1
    if currentStop >= targetStation then
        -- Vehicle already past or at target station
        return timetableHelper.getTime() -- Return current time
    end
    
    -- Get section times (time between stations)
    local sectionTimes = vehicleInfo.sectionTimes
    if not sectionTimes then return nil end
    
    -- Calculate remaining journey time
    local remainingTime = 0
    for i = currentStop, targetStation - 1 do
        if sectionTimes[i] then
            remainingTime = remainingTime + (sectionTimes[i] / 1000) -- Convert ms to seconds
        else
            -- If no section time data, use average or estimate
            remainingTime = remainingTime + 60 -- Default 1 minute estimate
        end
    end
    
    -- Factor in current delay (if vehicle is at a station and delayed)
    local currentTime = timetableHelper.getTime()
    local currentDelay = 0
    
    if vehicleInfo.state == api.type.enum.TransportVehicleState.AT_TERMINAL then
        -- Vehicle is at a station, check if it's delayed
        local delayTracker = require "celmi/timetables/delay_tracker"
        if vehicleInfo.line then
            local delay = delayTracker.getArrivalDelay(vehicleInfo.line, currentStop, vehicle)
            if delay then
                currentDelay = delay
            end
        end
    end
    
    -- Add delay to prediction (assumes delay will persist)
    local predictedArrival = currentTime + remainingTime + (currentDelay * 0.5) -- Use 50% of current delay
    
    return predictedArrival
end

-------------------------------------------------------------
---------------------- Station related ----------------------
-------------------------------------------------------------

---@param station number | string
-- returns {name : String}
function timetableHelper.getStation(station)
    if type(station) == "string" then station = tonumber(station) end
    if not(type(station) == "number") then return "ERROR" end

    local stationObject = cachedGetComponent(station, api.type.ComponentType.NAME, timetableHelper.getTime())
    if stationObject and stationObject.name then
        return { name = stationObject.name }
    else
        return {name = "ERROR"}
    end
end

function timetableHelper.getLineInfo(line)
    return cachedGetComponent(line, api.type.ComponentType.LINE, timetableHelper.getTime())
end

---@param line number | string
-- returns [id : Number] Array of stationIds
function timetableHelper.getAllStations(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end

    local lineObject = cachedGetComponent(line, api.type.ComponentType.LINE, timetableHelper.getTime())
    if lineObject and lineObject.stops then
        local res = {}
        for k, v in pairs(lineObject.stops) do
            res[k] = v.stationGroup
        end
        return res
    else
        return {}
    end
end

---@param station number | string
-- returns stationName : String
function timetableHelper.getStationName(station)
    if type(station) == "string" then station = tonumber(station) end
    if not(type(station) == "number") then return "ERROR" end

    -- CommonAPI2 is always available, no need for pcall wrapper
    local component = cachedGetComponent(station, api.type.ComponentType.NAME, timetableHelper.getTime())
    if component and component.name then
        return component.name
    else
        return "ERROR"
    end
end


---@param line number | string
---@param stationNumber number
-- returns stationID : Number and -1 in Error Case
function timetableHelper.getStationID(line, stationNumber)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return -1 end

    local lineObject = cachedGetComponent(line, api.type.ComponentType.LINE, timetableHelper.getTime())
    if lineObject and lineObject.stops and lineObject.stops[stationNumber] then
        return lineObject.stops[stationNumber].stationGroup
    else
        return -1
    end
end

-------------------------------------------------------------
---------------------- Array Functions ----------------------
-------------------------------------------------------------

---@param arr table
-- returns [Number], an Array where the index it the source element and the number is the target position
function timetableHelper.getOrderOfArray(arr)
    local toSort = {}
    for k,v in pairs(arr) do
        toSort[k] = {key =  k, value = v}
    end
    table.sort(toSort, function(a,b)
        return string.lower(a.value) < string.lower(b.value)
    end)
    local res = {}
    for k,v in pairs(toSort) do
        res[k-1] = v.key-1
    end
    return res
end

---@param a table
---@param b table
-- returns Array, the merged arrays a,b
function timetableHelper.mergeArray(a,b)
    if a == nil then return b end
    if b == nil then return a end
    local ab = {}
    for _, v in pairs(a) do
        table.insert(ab, v)
    end
    for _, v in pairs(b) do
        table.insert(ab, v)
    end
    return ab
end


-- returns [{vehicleID: lineID}]
function timetableHelper.getAllVehiclesAtTerminal(currentTime)
    return timetableHelper.getVehiclesWithState(api.type.enum.TransportVehicleState.AT_TERMINAL, currentTime)
end


-- Cache for game time to reduce redundant API calls
local gameTimeCache = nil
local gameTimeCacheTime = 0
local GAME_TIME_CACHE_DURATION = 0.1 -- Cache for 100ms (very short, but reduces calls)

-- Cache for world entity reference
local worldEntityCache = nil

-- Get world entity (cached)
local function getWorldEntity()
    if worldEntityCache then
        return worldEntityCache
    end
    
    -- Try CommonAPI2 world access if available
    if commonapi2_available then
        if commonapi.getWorld then
            local success, world = pcall(function()
                return commonapi.getWorld()
            end)
            if success and world then
                worldEntityCache = world
                return world
            end
        elseif commonapi.world then
            worldEntityCache = commonapi.world
            return commonapi.world
        end
    end
    
    -- Fallback to native API using safe wrapper
    worldEntityCache = safeCommonAPI2Call(
        nil, -- No CommonAPI2 alternative for getWorld (already checked above)
        api.engine.util.getWorld
    )
    return worldEntityCache
end

-- returns Number, current GameTime in seconds
function timetableHelper.getTime()
    local currentTime = os.clock() -- Use os.clock() for cache timing
    if gameTimeCache and (currentTime - gameTimeCacheTime < GAME_TIME_CACHE_DURATION) then
        return gameTimeCache
    end
    
    -- Use CommonAPI2 if available, otherwise fall back to native API
    local timeComponent
    local world = getWorldEntity()
    
    if commonapi2_available and commonapi.getComponent then
        local success, component = pcall(function()
            return commonapi.getComponent(world, api.type.ComponentType.GAME_TIME)
        end)
        if success and component then
            timeComponent = component
        else
            -- Fallback to native API
            timeComponent = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)
        end
    else
        timeComponent = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)
    end
    
    local time = 0
    if timeComponent and timeComponent.gameTime then
        time = math.floor(timeComponent.gameTime / 1000)
    end
    
    gameTimeCache = time
    gameTimeCacheTime = currentTime
    return time
end

---@param tab table
---@param val any
-- returns Bool,
function timetableHelper.hasValue(tab, val)
    for _, v in pairs(tab) do
        if v == val then
            return true
        end
    end

    return false
end

---@param arr table
-- returns a, the maximum element of the array
function timetableHelper.maximumArray(arr)
    local max = arr[1]
    for k,_ in pairs(arr) do
        if max < arr[k] then
            max = arr[k]
        end
    end
    return max
end


-------------------------------------------------------------
---------------------- Other --------------------------------
-------------------------------------------------------------

---@param cond table : TimetableCondition,
---@param type string, "ArrDep" |"debounce"
-- returns String, ready to display in the UI
function timetableHelper.conditionToString(cond, lineID, type)
    if (not cond) or (not type) then return "" end
    if type =="ArrDep" then
        local arr = UIStrings.arr
        local dep = UIStrings.dep
        for _,v in pairs(cond) do
            arr = arr .. string.format("%02d", v[1]) .. ":" .. string.format("%02d", v[2])  .. "|"
            dep = dep .. string.format("%02d", v[3]) .. ":" .. string.format("%02d", v[4])  .. "|"
        end
        local res = arr .. "\n"  .. dep
        return res
    elseif type == "debounce" then
        if not cond[1] then cond[1] = 0 end
        if not cond[2] then cond[2] = 0 end
        return UIStrings.unbunchTime .. ": " .. string.format("%02d", cond[1]) .. ":" .. string.format("%02d", cond[2])
    elseif type == "auto_debounce" then
        if not cond[1] then cond[1] = 0 end
        if not cond[2] then cond[2] = 0 end
        local margin = "Margin Time:  " .. string.format("%02d", cond[1]) .. ":" .. string.format("%02d", cond[2])
        local unbunch = timetableHelper.getAutoUnbunchFor(lineID, cond)
        return margin .. "\n" .. unbunch
    else
        return type
    end
end

function timetableHelper.getAutoUnbunchFor(lineID, cond)
    local frequency = timetableHelper.getFrequencyMinSec(lineID)
    if type(frequency) == "table" then
        local unbunchTime = (frequency.min - cond[1]) * 60 + frequency.sec - cond[2]
        if unbunchTime >= 0 then
            return UIStrings.unbunchTime .. ": " .. string.format("%02d", math.floor(unbunchTime / 60)) .. ":" .. string.format("%02d", math.floor(unbunchTime % 60))
        end
    end
    return UIStrings.unbunchTime .. ": --:--"
end

---@param i number Index of Combobox,
-- returns String, ready to display in the UI
function timetableHelper.constraintIntToString(i)
    if i == 0 then return "None"
    elseif i == 1 then return "ArrDep"
    --elseif i == 2 then return "minWait"
    elseif i == 2 then return "debounce"
    elseif i == 3 then return "auto_debounce"
    --elseif i == 4 then return "moreFancey"
    else return "ERROR"
    end
end

---@param i string, "ArrDep" |"debounce"
-- returns Number, index of combobox
function timetableHelper.constraintStringToInt(i)
    if i == "None" then return 0
    elseif i == "ArrDep" then return 1
    --elseif i == "minWait" then return 2
    elseif i == "debounce" then return 2
    elseif i == "auto_debounce" then return 3
    --elseif i == "moreFancey" then return 4
    else return 0
    end

end


return timetableHelper