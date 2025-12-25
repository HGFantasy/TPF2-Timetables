-- Delay Tracker Module
-- Unified delay tracking system for features #14 (Departure Display), #15 (Statistics), #22 (Departure Board)
-- Batch delay calculations, cache results, incremental updates

local delayTracker = {}

-- CommonAPI2 persistence for delay data
local commonapi2_available = false
local commonapi2_persistence_api = nil
local DELAY_DATA_VERSION = 1

-- Check for CommonAPI2 and persistence API
if commonapi ~= nil and type(commonapi) == "table" then
    commonapi2_available = true
    -- Check for various possible CommonAPI2 persistence APIs
    if commonapi.persistence then
        commonapi2_persistence_api = commonapi.persistence
    elseif commonapi.data then
        commonapi2_persistence_api = commonapi.data
    elseif commonapi.storage then
        commonapi2_persistence_api = commonapi.storage
    elseif commonapi.settings then
        -- Reuse settings API if persistence not available separately
        commonapi2_persistence_api = commonapi.settings
    end
end

-- Delay cache: lineID -> stationID -> vehicleID -> {delay = seconds, lastUpdate = timestamp}
local delayCache = {}

-- Statistics cache: lineID -> stationID -> {onTimeCount = n, totalCount = n, avgDelay = seconds}
local statisticsCache = {}

-- Circular buffer for delay history (last N departures)
local DELAY_HISTORY_SIZE = 100
local delayHistory = {}

-- Arrival delay cache (tracks arrival delays separately from departure delays)
-- Format: arrivalDelayCache[line][station][vehicle] = {delay = seconds, arrivalTime = timestamp, scheduledArrival = timestamp}
local arrivalDelayCache = {}

-- Delay history by time of day (for pattern analysis)
-- Format: timeBasedDelayHistory[line][station][timeOfDayBucket] = {delays = {...}, count = n}
local timeBasedDelayHistory = {}
local TIME_BUCKET_SIZE = 300 -- 5 minute buckets

-- Pattern detection cache
-- Format: delayPatternCache[line][station] = {pattern = {...}, lastUpdate = timestamp}
local delayPatternCache = {}

-- Initialize delay tracker
function delayTracker.initialize()
    delayCache = {}
    statisticsCache = {}
    delayHistory = {}
    arrivalDelayCache = {}
    timeBasedDelayHistory = {}
    delayPatternCache = {}
end

-- Calculate delay for a vehicle at a station
-- delay = actualTime - scheduledTime (positive = late, negative = early)
function delayTracker.calculateDelay(vehicle, line, station, scheduledTime, currentTime)
    if not scheduledTime or not currentTime then return nil end
    return currentTime - scheduledTime
end

-- Delay alert system
local delayAlerts = {}
local alertHistory = {}
local MAX_ALERT_HISTORY = 100

-- Check and trigger delay alerts
local function checkDelayAlerts(line, station, vehicle, delay, currentTime)
    if not delay or delay <= 0 then return end -- Only alert on delays, not early arrivals
    
    local settings = require "celmi/timetables/settings"
    if not settings.get("delayAlertEnabled") then return end
    
    -- Get threshold (per-line or global)
    local threshold = settings.get("delayAlertPerLineThreshold")[line] or settings.get("delayAlertThreshold")
    if not threshold or delay < threshold then return end
    
    -- Check if we've already alerted for this delay (avoid spam)
    local alertKey = tostring(line) .. "_" .. tostring(station) .. "_" .. tostring(vehicle)
    local lastAlert = delayAlerts[alertKey]
    if lastAlert and currentTime - lastAlert.time < 60 then
        -- Already alerted within last minute, skip
        return
    end
    
    -- Record alert
    delayAlerts[alertKey] = {
        line = line,
        station = station,
        vehicle = vehicle,
        delay = delay,
        time = currentTime
    }
    
    -- Add to alert history
    table.insert(alertHistory, {
        line = line,
        station = station,
        vehicle = vehicle,
        delay = delay,
        threshold = threshold,
        time = currentTime
    })
    
    -- Keep only last N entries
    if #alertHistory > MAX_ALERT_HISTORY then
        table.remove(alertHistory, 1)
    end
    
    -- Trigger visual/sound alerts if enabled
    local timetableHelper = require "celmi/timetables/timetable_helper"
    if settings.get("delayAlertVisualEnabled") then
        timetableHelper.logWarn("Delay Alert: Line %s, Station %s, Vehicle %s: %d seconds delay (threshold: %d)", 
            tostring(line), tostring(station), tostring(vehicle), delay, threshold)
    end
    
    if settings.get("delayAlertSoundEnabled") then
        -- Sound alerts would require game API support
        -- For now, just log
        timetableHelper.logWarn("Delay Alert Sound: Line %s delayed by %d seconds", tostring(line), delay)
    end
end

-- Record delay for a vehicle departure/arrival
function delayTracker.recordDelay(line, station, vehicle, delay, currentTime)
    if not line or not station or not vehicle or not delay then return end
    
    if not delayCache[line] then delayCache[line] = {} end
    if not delayCache[line][station] then delayCache[line][station] = {} end
    
    delayCache[line][station][vehicle] = {
        delay = delay,
        lastUpdate = currentTime
    }
    
    -- Check for delay alerts
    checkDelayAlerts(line, station, vehicle, delay, currentTime)
    
    -- Update statistics
    if not statisticsCache[line] then statisticsCache[line] = {} end
    if not statisticsCache[line][station] then
        statisticsCache[line][station] = {
            onTimeCount = 0,
            totalCount = 0,
            avgDelay = 0,
            sumDelay = 0
        }
    end
    
    local stats = statisticsCache[line][station]
    stats.totalCount = stats.totalCount + 1
    stats.sumDelay = stats.sumDelay + delay
    
    -- Consider on-time if delay is within ±30 seconds
    if math.abs(delay) <= 30 then
        stats.onTimeCount = stats.onTimeCount + 1
    end
    
    -- Update average delay
    stats.avgDelay = stats.sumDelay / stats.totalCount
    
    -- Add to history (circular buffer)
    table.insert(delayHistory, {
        line = line,
        station = station,
        vehicle = vehicle,
        delay = delay,
        time = currentTime
    })
    
    -- Keep only last N entries
    if #delayHistory > DELAY_HISTORY_SIZE then
        table.remove(delayHistory, 1)
    end
end

-- Get delay for a vehicle
function delayTracker.getDelay(line, station, vehicle)
    if not delayCache[line] or not delayCache[line][station] or not delayCache[line][station][vehicle] then
        return nil
    end
    return delayCache[line][station][vehicle].delay
end

-- Get statistics for a line/station
function delayTracker.getStatistics(line, station)
    if not statisticsCache[line] or not statisticsCache[line][station] then
        return {
            onTimeCount = 0,
            totalCount = 0,
            avgDelay = 0,
            onTimePercentage = 0
        }
    end
    
    local stats = statisticsCache[line][station]
    local onTimePercentage = stats.totalCount > 0 and (stats.onTimeCount / stats.totalCount * 100) or 0
    
    return {
        onTimeCount = stats.onTimeCount,
        totalCount = stats.totalCount,
        avgDelay = stats.avgDelay,
        onTimePercentage = onTimePercentage
    }
end

-- Get delay history (last N entries)
function delayTracker.getDelayHistory(count)
    count = count or 10
    local startIndex = math.max(1, #delayHistory - count + 1)
    local result = {}
    for i = startIndex, #delayHistory do
        table.insert(result, delayHistory[i])
    end
    return result
end

-- Record arrival delay (when vehicle arrives vs scheduled arrival)
function delayTracker.recordArrivalDelay(line, station, vehicle, delay, arrivalTime, scheduledArrivalTime)
    if not line or not station or not vehicle or not delay then return end
    
    if not arrivalDelayCache[line] then arrivalDelayCache[line] = {} end
    if not arrivalDelayCache[line][station] then arrivalDelayCache[line][station] = {} end
    
    arrivalDelayCache[line][station][vehicle] = {
        delay = delay,
        arrivalTime = arrivalTime,
        scheduledArrival = scheduledArrivalTime
    }
    
    -- Add to time-based history for pattern analysis
    local timeBucket = math.floor((arrivalTime % 3600) / TIME_BUCKET_SIZE) * TIME_BUCKET_SIZE
    if not timeBasedDelayHistory[line] then timeBasedDelayHistory[line] = {} end
    if not timeBasedDelayHistory[line][station] then timeBasedDelayHistory[line][station] = {} end
    if not timeBasedDelayHistory[line][station][timeBucket] then
        timeBasedDelayHistory[line][station][timeBucket] = {delays = {}, count = 0}
    end
    
    local bucket = timeBasedDelayHistory[line][station][timeBucket]
    table.insert(bucket.delays, delay)
    bucket.count = bucket.count + 1
    
    -- Keep only last 50 delays per bucket
    if #bucket.delays > 50 then
        table.remove(bucket.delays, 1)
    end
end

-- Get arrival delay for a vehicle
function delayTracker.getArrivalDelay(line, station, vehicle)
    if not arrivalDelayCache[line] or not arrivalDelayCache[line][station] or not arrivalDelayCache[line][station][vehicle] then
        return nil
    end
    return arrivalDelayCache[line][station][vehicle].delay
end

-- Get historical delay for a time of day (average delay for similar time periods)
function delayTracker.getHistoricalDelay(line, station, timeOfDay)
    if not line or not station or not timeOfDay then return nil end
    
    local timeBucket = math.floor((timeOfDay % 3600) / TIME_BUCKET_SIZE) * TIME_BUCKET_SIZE
    
    if not timeBasedDelayHistory[line] or not timeBasedDelayHistory[line][station] or 
       not timeBasedDelayHistory[line][station][timeBucket] then
        return nil
    end
    
    local bucket = timeBasedDelayHistory[line][station][timeBucket]
    if bucket.count == 0 then return nil end
    
    -- Calculate average delay for this time bucket
    local sum = 0
    for _, delay in ipairs(bucket.delays) do
        sum = sum + delay
    end
    
    return sum / bucket.count
end

-- Detect delay patterns for a line/station
function delayTracker.detectPatterns(line, station)
    if not line or not station then return nil end
    
    -- Check cache first
    if delayPatternCache[line] and delayPatternCache[line][station] then
        local cached = delayPatternCache[line][station]
        -- Cache valid for 5 minutes
        local currentTime = require("celmi/timetables/timetable_helper").getTime()
        if currentTime - cached.lastUpdate < 300 then
            return cached.pattern
        end
    end
    
    local pattern = {
        consistentlyLate = false,
        consistentlyEarly = false,
        averageDelay = 0,
        delayVariance = 0,
        timeOfDayPeaks = {}
    }
    
    if not timeBasedDelayHistory[line] or not timeBasedDelayHistory[line][station] then
        return pattern
    end
    
    local allDelays = {}
    local buckets = timeBasedDelayHistory[line][station]
    
    -- Collect all delays
    for timeBucket, bucket in pairs(buckets) do
        for _, delay in ipairs(bucket.delays) do
            table.insert(allDelays, delay)
        end
        
        -- Find time-of-day peaks (buckets with high average delays)
        if bucket.count > 5 then
            local sum = 0
            for _, d in ipairs(bucket.delays) do
                sum = sum + d
            end
            local avg = sum / bucket.count
            if avg > 60 then -- More than 1 minute average delay
                table.insert(pattern.timeOfDayPeaks, {
                    timeBucket = timeBucket,
                    averageDelay = avg
                })
            end
        end
    end
    
    if #allDelays > 0 then
        -- Calculate average
        local sum = 0
        for _, delay in ipairs(allDelays) do
            sum = sum + delay
        end
        pattern.averageDelay = sum / #allDelays
        
        -- Calculate variance
        local varianceSum = 0
        for _, delay in ipairs(allDelays) do
            varianceSum = varianceSum + (delay - pattern.averageDelay) * (delay - pattern.averageDelay)
        end
        pattern.delayVariance = varianceSum / #allDelays
        
        -- Check for consistent patterns
        local lateCount = 0
        local earlyCount = 0
        for _, delay in ipairs(allDelays) do
            if delay > 30 then lateCount = lateCount + 1 end
            if delay < -30 then earlyCount = earlyCount + 1 end
        end
        
        pattern.consistentlyLate = (lateCount / #allDelays) > 0.7
        pattern.consistentlyEarly = (earlyCount / #allDelays) > 0.7
    end
    
    -- Cache the pattern
    if not delayPatternCache[line] then delayPatternCache[line] = {} end
    delayPatternCache[line][station] = {
        pattern = pattern,
        lastUpdate = require("celmi/timetables/timetable_helper").getTime()
    }
    
    return pattern
end

-- Get statistics with time-based filtering
function delayTracker.getStatisticsWithTimeFilter(line, station, startTimeOfDay, endTimeOfDay)
    if not line or not station then
        return delayTracker.getStatistics(line, station)
    end
    
    -- Collect delays within time range
    local relevantDelays = {}
    local buckets = timeBasedDelayHistory[line] and timeBasedDelayHistory[line][station]
    
    if buckets then
        for timeBucket, bucket in pairs(buckets) do
            if timeBucket >= startTimeOfDay and timeBucket <= endTimeOfDay then
                for _, delay in ipairs(bucket.delays) do
                    table.insert(relevantDelays, delay)
                end
            end
        end
    end
    
    if #relevantDelays == 0 then
        return {
            onTimeCount = 0,
            totalCount = 0,
            avgDelay = 0,
            onTimePercentage = 0
        }
    end
    
    -- Calculate statistics
    local onTimeCount = 0
    local sum = 0
    local minDelay = math.huge
    local maxDelay = -math.huge
    
    for _, delay in ipairs(relevantDelays) do
        if math.abs(delay) <= 30 then
            onTimeCount = onTimeCount + 1
        end
        sum = sum + delay
        if delay < minDelay then minDelay = delay end
        if delay > maxDelay then maxDelay = delay end
    end
    
    return {
        onTimeCount = onTimeCount,
        totalCount = #relevantDelays,
        avgDelay = sum / #relevantDelays,
        onTimePercentage = (onTimeCount / #relevantDelays) * 100,
        minDelay = minDelay,
        maxDelay = maxDelay,
        medianDelay = delayTracker.calculateMedian(relevantDelays)
    }
end

-- Calculate median of a sorted array
function delayTracker.calculateMedian(sortedArray)
    if #sortedArray == 0 then return 0 end
    
    local sorted = {}
    for _, v in ipairs(sortedArray) do
        table.insert(sorted, v)
    end
    table.sort(sorted)
    
    local mid = math.floor(#sorted / 2)
    if #sorted % 2 == 0 then
        return (sorted[mid] + sorted[mid + 1]) / 2
    else
        return sorted[mid + 1]
    end
end

-- Enhanced statistics with distribution data
function delayTracker.getEnhancedStatistics(line, station)
    local baseStats = delayTracker.getStatistics(line, station)
    
    -- Add delay distribution if we have history
    local allDelays = {}
    if delayHistory then
        for _, entry in ipairs(delayHistory) do
            if entry.line == line and entry.station == station then
                table.insert(allDelays, entry.delay)
            end
        end
    end
    
    if #allDelays > 0 then
        table.sort(allDelays)
        baseStats.minDelay = allDelays[1]
        baseStats.maxDelay = allDelays[#allDelays]
        baseStats.medianDelay = delayTracker.calculateMedian(allDelays)
        
        -- Calculate percentiles
        local p25Index = math.floor(#allDelays * 0.25)
        local p75Index = math.floor(#allDelays * 0.75)
        baseStats.p25Delay = allDelays[p25Index + 1] or 0
        baseStats.p75Delay = allDelays[p75Index + 1] or 0
    end
    
    return baseStats
end

-- Clean up old cache entries (called periodically)
function delayTracker.cleanup(currentTime, maxAge)
    maxAge = maxAge or 3600 -- Default: 1 hour
    
    for line, lineData in pairs(delayCache) do
        for station, stationData in pairs(lineData) do
            for vehicle, delayData in pairs(stationData) do
                if currentTime - delayData.lastUpdate > maxAge then
                    stationData[vehicle] = nil
                end
            end
        end
    end
    
    -- Clean up arrival delay cache
    for line, lineData in pairs(arrivalDelayCache) do
        for station, stationData in pairs(lineData) do
            for vehicle, delayData in pairs(stationData) do
                if currentTime - delayData.arrivalTime > maxAge then
                    stationData[vehicle] = nil
                end
            end
        end
    end
end

-- Save delay statistics to CommonAPI2 persistence
function delayTracker.saveToPersistence()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, err = pcall(function()
        -- Prepare delay data with version info
        local dataToSave = {
            version = DELAY_DATA_VERSION,
            statisticsCache = statisticsCache,
            delayHistory = delayHistory,
            timeBasedDelayHistory = timeBasedDelayHistory,
            delayPatternCache = delayPatternCache,
            timestamp = require("celmi/timetables/timetable_helper").getTime()
        }
        
        -- Try different possible API methods
        if commonapi2_persistence_api.set then
            commonapi2_persistence_api.set("timetables_delay_data", dataToSave)
        elseif commonapi2_persistence_api.save then
            commonapi2_persistence_api.save("timetables_delay_data", dataToSave)
        elseif commonapi2_persistence_api.write then
            commonapi2_persistence_api.write("timetables_delay_data", dataToSave)
        elseif commonapi2_persistence_api.store then
            commonapi2_persistence_api.store("timetables_delay_data", dataToSave)
        else
            error("CommonAPI2 persistence API not found")
        end
    end)
    
    if success then
        return true, nil
    else
        return false, tostring(err)
    end
end

-- Load delay statistics from CommonAPI2 persistence
function delayTracker.loadFromPersistence()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, loadedData = pcall(function()
        -- Try different possible API methods
        if commonapi2_persistence_api.get then
            return commonapi2_persistence_api.get("timetables_delay_data")
        elseif commonapi2_persistence_api.load then
            return commonapi2_persistence_api.load("timetables_delay_data")
        elseif commonapi2_persistence_api.read then
            return commonapi2_persistence_api.read("timetables_delay_data")
        elseif commonapi2_persistence_api.retrieve then
            return commonapi2_persistence_api.retrieve("timetables_delay_data")
        end
        return nil
    end)
    
    if success and loadedData and type(loadedData) == "table" then
        -- Handle versioned data structure
        if loadedData.version and loadedData.version < DELAY_DATA_VERSION then
            -- Future: implement migration logic here
            print("Timetables: Migrating delay data from version " .. loadedData.version .. " to " .. DELAY_DATA_VERSION)
        end
        
        -- Restore data
        if loadedData.statisticsCache then
            statisticsCache = loadedData.statisticsCache
        end
        if loadedData.delayHistory then
            delayHistory = loadedData.delayHistory
            -- Ensure history doesn't exceed size limit
            while #delayHistory > DELAY_HISTORY_SIZE do
                table.remove(delayHistory, 1)
            end
        end
        if loadedData.timeBasedDelayHistory then
            timeBasedDelayHistory = loadedData.timeBasedDelayHistory
        end
        if loadedData.delayPatternCache then
            delayPatternCache = loadedData.delayPatternCache
        end
        
        return true, nil
    else
        return false, success and "No saved delay data found" or tostring(loadedData)
    end
end

-- Check if delay persistence is available
function delayTracker.isPersistenceAvailable()
    return commonapi2_available and commonapi2_persistence_api ~= nil
end

-- Auto-save delay data (call periodically from update loop)
local lastDelayAutoSaveTime = 0
local DELAY_AUTO_SAVE_INTERVAL = 60 -- Save every 60 seconds

function delayTracker.autoSaveIfNeeded(currentTime)
    if not delayTracker.isPersistenceAvailable() then
        return false
    end
    
    currentTime = currentTime or require("celmi/timetables/timetable_helper").getTime()
    
    -- Only auto-save periodically
    if currentTime - lastDelayAutoSaveTime >= DELAY_AUTO_SAVE_INTERVAL then
        local success, err = delayTracker.saveToPersistence()
        if success then
            lastDelayAutoSaveTime = currentTime
            return true
        else
            print("Timetables: Delay auto-save failed: " .. tostring(err))
            return false
        end
    end
    
    return false
end

-- Register with persistence manager on module load
pcall(function()
    local persistenceManager = require "celmi/timetables/persistence_manager"
    if persistenceManager and persistenceManager.isAvailable() then
        persistenceManager.registerModule("delay", 
            function()
                return {
                    statisticsCache = statisticsCache,
                    delayHistory = delayHistory,
                    timeBasedDelayHistory = timeBasedDelayHistory,
                    delayPatternCache = delayPatternCache
                }
            end,
            function(data)
                if data then
                    if data.statisticsCache then statisticsCache = data.statisticsCache end
                    if data.delayHistory then
                        delayHistory = data.delayHistory
                        while #delayHistory > DELAY_HISTORY_SIZE do
                            table.remove(delayHistory, 1)
                        end
                    end
                    if data.timeBasedDelayHistory then timeBasedDelayHistory = data.timeBasedDelayHistory end
                    if data.delayPatternCache then delayPatternCache = data.delayPatternCache end
                    return true
                end
                return false
            end,
            DELAY_DATA_VERSION
        )
    end
end)

return delayTracker
