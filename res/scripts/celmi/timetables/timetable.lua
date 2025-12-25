local timetableHelper = require "celmi/timetables/timetable_helper"
local guard = require "celmi/timetables/guard"
local delayTracker = require "celmi/timetables/delay_tracker"
local persistenceManager = require "celmi/timetables/persistence_manager"

-- CommonAPI2 persistence for timetable data
local commonapi2_available = false
local commonapi2_persistence_api = nil
local TIMETABLE_DATA_VERSION = 1

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

-- Use cached entity exists function from timetableHelper (always available)
local cachedEntityExists = function(entity)
    return timetableHelper.entityExists(entity, timetableHelper.getTime())
end

--[[
timetable = {
    line = {
        stations = { stationinfo }
        hasTimetable = true
        frequency = 1 :: int
    }
}

stationInfo = {
    conditions = {condition :: Condition},
    vehiclesWaiting = {
        vehicleNumber = {
            slot = {}
            departureTime = 1 :: int
        }
    },
    -- Train assignments: bind specific vehicles to specific timetable slots
    trainAssignments = {
        vehicleNumber = {
            slotIndex = 1 :: int,  -- Index of the assigned slot
            slot = {}              -- The assigned slot content
        }
    },
    -- Platform assignments: assign vehicles to specific platforms at stations
    platformAssignments = {
        vehicleNumber = platformNumber :: int  -- Platform number (1-based)
    }
}

conditions = {
    type = "None"| "ArrDep" | "debounce" | "moreFancey"
    ArrDep = {}
    debounce  = {}
    moreFancey = {}
}

ArrDep = {
    [1] = 12 -- arrival minute
    [2] = 30 -- arrival second
    [3] = 15 -- departure minute
    [4] = 00 -- departure second
}
--]]

local timetable = { }
local timetableObject = { }

-- Delay recovery mode constants
local DELAY_RECOVERY_MODE = {
    CATCH_UP = "catch_up",           -- Try to return to schedule (current behavior)
    SKIP_TO_NEXT = "skip_to_next",   -- Abandon current slot, use next available
    HOLD_AT_TERMINUS = "hold_at_terminus", -- Wait longer at end stations to realign
    GRADUAL_RECOVERY = "gradual_recovery",   -- Slowly return to schedule over multiple stops
    SKIP_STOPS = "skip_stops",        -- Skip intermediate stops to catch up
    RESET_AT_TERMINUS = "reset_at_terminus" -- Reset schedule at terminus
}

-- Cache for lines with timetables enabled
local timetableLinesCache = {}

-- Cache for sorted slots per line/station
-- Format: sortedSlotsCache[line][station] = {sortedSlots = {...}, hash = "..."}
local sortedSlotsCache = {}

-- Cache for active time period per line/station (for time-based timetables)
-- Format: activeTimePeriodCache[line][station] = {periodIndex = n, lastUpdate = timestamp}
local activeTimePeriodCache = {}

-- Cache for slot hash sets (for O(1) slot lookups)
-- Format: slotHashSetCache[line][station] = {hashSet = {...}, slotHash = "..."}
local slotHashSetCache = {}

-- Cache for vehicle state during update cycle
-- Format: vehicleStateCache[vehicle] = {state = {...}, lastUpdate = timestamp}
local vehicleStateCache = {}
local vehicleStateCacheTime = 0
local VEHICLE_STATE_CACHE_DURATION = 1 -- Cache for 1 second (same update cycle)

-- Clipboard for copy/paste operations
-- Format: {type = "condition" | "line", data = {...}}
local clipboard = nil

-- Export cache for external access (e.g., GUI)
timetable.getCachedTimetableLines = function()
    return timetableLinesCache
end

-- Initialize cache of lines with timetables enabled
timetable.initializeTimetableLinesCache = function()
    timetableLinesCache = {}
    for line, lineInfo in pairs(timetableObject) do
        if timetable.hasTimetable(line) then
            timetableLinesCache[line] = true
        end
    end
end

-- Add a line to the timetable cache
timetable.addLineToTimetableCache = function(line)
    timetableLinesCache[line] = true
end

-- Remove a line from the timetable cache
timetable.removeLineFromTimetableCache = function(line)
    timetableLinesCache[line] = nil
end

-- Invalidate sorted slots cache for a specific line/station
timetable.invalidateSortedSlotsCache = function(line, station)
    if not sortedSlotsCache[line] then
        sortedSlotsCache[line] = {}
    end
    sortedSlotsCache[line][station] = nil
    -- Also invalidate active time period cache when slots change
    if activeTimePeriodCache[line] then
        activeTimePeriodCache[line][station] = nil
    end
    -- Invalidate slot hash set cache when slots change
    if slotHashSetCache[line] then
        slotHashSetCache[line][station] = nil
    end
end

-- Get or cache vehicle state (avoids redundant API calls during same update cycle)
function timetable.getCachedVehicleState(vehicle, currentTime)
    -- Clear cache if new update cycle
    if currentTime ~= vehicleStateCacheTime then
        vehicleStateCache = {}
        vehicleStateCacheTime = currentTime
    end
    
    -- Return cached state if available
    if vehicleStateCache[vehicle] then
        return vehicleStateCache[vehicle].state
    end
    
    -- Get fresh state and cache it
    local state = timetableHelper.getVehicleInfo(vehicle)
    if state then
        vehicleStateCache[vehicle] = {
            state = state,
            lastUpdate = currentTime
        }
    end
    return state
end

-- Get sorted slots from cache or compute and cache them
timetable.getSortedSlots = function(line, station, slots)
    if not slots or #slots == 0 then
        return {}
    end
    
    -- Initialize cache structure if needed
    if not sortedSlotsCache[line] then
        sortedSlotsCache[line] = {}
    end
    
    -- Check if cache exists
    local cached = sortedSlotsCache[line][station]
    if cached and cached.sortedSlots then
        -- Verify cache is still valid by comparing slot count
        if #cached.sortedSlots == #slots then
            return cached.sortedSlots
        end
    end
    
    -- Cache miss or invalid - sort and cache
    local sortedSlots = {}
    for i = 1, #slots do
        sortedSlots[i] = slots[i]
    end
    
    table.sort(sortedSlots, function(slot1, slot2)
        local arrivalSlot1 = timetable.slotToArrivalSlot(slot1)
        local arrivalSlot2 = timetable.slotToArrivalSlot(slot2)
        return arrivalSlot1 < arrivalSlot2
    end)
    
    -- Store in cache
    sortedSlotsCache[line][station] = {
        sortedSlots = sortedSlots
    }
    
    return sortedSlots
end

function timetable.getTimetableObject(includeSettings)
    -- If includeSettings is true, return new format with settings
    -- Otherwise return old format for backward compatibility
    if includeSettings then
        local settings = require "celmi/timetables/settings"
        return {
            timetableData = timetableObject,
            settings = settings.getAll()
        }
    end
    -- Return old format for backward compatibility
    return timetableObject
end

function timetable.setTimetableObject(t)
    if not t then return end
    
    -- Handle both old format (just timetable data) and new format (with settings)
    local timetableData = t
    if t.timetableData then
        -- New format with settings
        timetableData = t.timetableData
        if t.settings then
            local settings = require "celmi/timetables/settings"
            settings.setAll(t.settings)
        end
    end
    
    -- make sure the line is a number
    local keysToPatch = { }
    for lineID, lineInfo in pairs(timetableData) do
        if type(lineID) == "string" then
            table.insert(keysToPatch, lineID)
        end
    end

    for _, lineID in pairs(keysToPatch) do
        print("timetable: patching lineID: " .. lineID .. " to be a number")
        local lineInfo = timetableData[lineID]
        timetableData[lineID] = nil
        timetableData[tonumber(lineID)] = lineInfo
    end

    timetableObject = timetableData
    -- Invalidate caches when timetable object is set (loaded/changed)
    timetable.invalidateConstraintsByStationCache()
    timetable.invalidateStationLinesMapCache()
    -- Clear slot hash set cache when timetable changes
    slotHashSetCache = {}
    --print("timetable after loading and processing:")
    --print(dump(timetableObject))
end

function timetable.setConditionType(line, stationNumber, type)
    local stationID = timetableHelper.getStationID(line, stationNumber)
    if not(line and stationNumber) then return -1 end

    if not timetableObject[line] then
        timetableObject[line] = { hasTimetable = false, stations = {} }
    end
    if not timetableObject[line].stations[stationNumber] then
        timetableObject[line].stations[stationNumber] = { stationID = stationID, conditions = {} }
    end

    local stopInfo = timetableObject[line].stations[stationNumber]
    stopInfo.conditions.type = type

    if not stopInfo.conditions[type] then 
        stopInfo.conditions[type] = {}
    end
    
    if type == "ArrDep" then
        if not stopInfo.vehiclesWaiting then
            stopInfo.vehiclesWaiting = {}
        end
    else
        stopInfo.vehiclesWaiting = nil
    end
    
    -- Invalidate caches when condition type changes
    timetable.invalidateSortedSlotsCache(line, stationNumber)
    timetable.invalidateConstraintsByStationCache()
    timetable.invalidateStationLinesMapCache()
end

function timetable.getConditionType(line, stationNumber)
    if not(line and stationNumber) then return "ERROR" end
    if timetableObject[line] and timetableObject[line].stations[stationNumber] then
        if timetableObject[line].stations[stationNumber].conditions.type then
            return timetableObject[line].stations[stationNumber].conditions.type
        else
            timetableObject[line].stations[stationNumber].conditions.type = "None"
            return "None"
        end
    else
        return "None"
    end
end

-- reorders the constraints into the structure res[stationID][lineID][stopNr] = 
-- only returns stations that have constraints
function timetable.getConstraintsByStation()
    -- Return cached result if available and valid
    if constraintsByStationCache and not constraintsByStationCacheDirty then
        return constraintsByStationCache
    end
    
    local res = { }
    for lineID, lineInfo in pairs(timetableObject) do
        for stopNr, stopInfo in pairs(lineInfo.stations) do
            if stopInfo.stationID and stopInfo.conditions and  stopInfo.conditions.type and not (stopInfo.conditions.type == "None")  then
                if not res[stopInfo.stationID] then res[stopInfo.stationID] = {} end
                if not res[stopInfo.stationID][lineID] then res[stopInfo.stationID][lineID] = {} end
                res[stopInfo.stationID][lineID][stopNr] = stopInfo
            end
        end
    end

    -- Cache the result
    constraintsByStationCache = res
    constraintsByStationCacheDirty = false
    return res
end

-- Invalidate constraints by station cache
timetable.invalidateConstraintsByStationCache = function()
    constraintsByStationCacheDirty = true
end

-- Get station→lines mapping cache (used by features #22 and #16 Part D)
timetable.getStationLinesMap = function()
    if stationLinesMapCache and not stationLinesMapCacheDirty then
        return stationLinesMapCache
    end
    
    local map = {}
    for lineID, lineInfo in pairs(timetableObject) do
        if lineInfo.stations then
            for stopNr, stopInfo in pairs(lineInfo.stations) do
                if stopInfo.stationID then
                    if not map[stopInfo.stationID] then
                        map[stopInfo.stationID] = {}
                    end
                    map[stopInfo.stationID][lineID] = true
                end
            end
        end
    end
    
    stationLinesMapCache = map
    stationLinesMapCacheDirty = false
    return map
end

-- Invalidate station→lines mapping cache
timetable.invalidateStationLinesMapCache = function()
    stationLinesMapCacheDirty = true
end

function timetable.getAllConditionsOfAllStations()
    local res = { }
    for k,v in pairs(timetableObject) do
        for _,v2 in pairs(v.stations) do
            if v2.stationID and v2.conditions and  v2.conditions.type and not (v2.conditions.type == "None")  then
                if not res[v2.stationID] then res[v2.stationID] = {} end
                res[v2.stationID][k] = {
                    conditions = v2.conditions
                }
            end
        end
    end
    return res
end

function timetable.getConditions(line, stationNumber, type)
    if not(line and stationNumber) then return -1 end
    if timetableObject[line]
       and timetableObject[line].stations[stationNumber]
       and timetableObject[line].stations[stationNumber].conditions[type] then
        return timetableObject[line].stations[stationNumber].conditions[type]
    else
        return -1
    end
end

function timetable.addFrequency(line, frequency)
    if not timetableObject[line] then return end
    timetableObject[line].frequency = frequency
end


-- TEST: timetable.addCondition(1,1,{type = "ArrDep", ArrDep = {{12,14,14,14}}})
function timetable.addCondition(line, stationNumber, condition)
    local stationID = timetableHelper.getStationID(line, stationNumber)
    if not(line and stationNumber and condition) then return -1 end

    if timetableObject[line] and timetableObject[line].stations[stationNumber] then
        if condition.type == "ArrDep" then
            timetable.setConditionType(line, stationNumber, condition.type)
            local arrDepCond = timetableObject[line].stations[stationNumber].conditions.ArrDep
            
            -- Check if using time periods structure
            if arrDepCond.timePeriods then
                -- Time periods mode: add to active period or first period
                if condition.ArrDep and condition.ArrDep.timePeriods then
                    -- New condition also has time periods: merge them
                    for _, newPeriod in ipairs(condition.ArrDep.timePeriods) do
                        table.insert(arrDepCond.timePeriods, newPeriod)
                    end
                elseif condition.ArrDep and #condition.ArrDep > 0 then
                    -- New condition has legacy slots: add to first period or create default period
                    if #arrDepCond.timePeriods == 0 then
                        table.insert(arrDepCond.timePeriods, {
                            startTime = 0,
                            endTime = 3600,
                            slots = {}
                        })
                    end
                    local mergedArrays = timetableHelper.mergeArray(arrDepCond.timePeriods[1].slots, condition.ArrDep)
                    arrDepCond.timePeriods[1].slots = mergedArrays
                end
            else
                -- Legacy mode: merge arrays directly
                local mergedArrays = timetableHelper.mergeArray(arrDepCond, condition.ArrDep)
                timetableObject[line].stations[stationNumber].conditions.ArrDep = mergedArrays
            end
            
            -- Invalidate caches after modifying ArrDep slots
            timetable.invalidateSortedSlotsCache(line, stationNumber)
            timetable.invalidateConstraintsByStationCache()
        elseif condition.type == "debounce" then
            timetableObject[line].stations[stationNumber].conditions.type = "debounce"
            timetableObject[line].stations[stationNumber].conditions.debounce = condition.debounce
            timetable.invalidateConstraintsByStationCache()
        elseif condition.type == "auto_debounce" then
            timetableObject[line].stations[stationNumber].conditions.type = "auto_debounce"
            timetableObject[line].stations[stationNumber].conditions.auto_debounce = condition.auto_debounce
            timetable.invalidateConstraintsByStationCache()
        elseif condition.type == "moreFancey" then
            timetableObject[line].stations[stationNumber].conditions.type = "moreFancey"
            timetableObject[line].stations[stationNumber].conditions.moreFancey = condition.moreFancey
            timetable.invalidateConstraintsByStationCache()
        end
        timetableObject[line].stations[stationNumber].stationID = stationID

    else
        if not timetableObject[line] then
            timetableObject[line] = {hasTimetable = false, stations = {}}
        end
        timetableObject[line].stations[stationNumber] = {
            stationID = stationID,
            conditions = condition
        }
        timetable.invalidateConstraintsByStationCache()
        timetable.invalidateStationLinesMapCache()
    end
end

function timetable.insertArrDepCondition(line, station, indexKey, condition)
    if not(line and station and indexKey and condition) then return -1 end
    if timetableObject[line] and
       timetableObject[line].stations[station] and
       timetableObject[line].stations[station].conditions and
       timetableObject[line].stations[station].conditions.ArrDep and
       timetableObject[line].stations[station].conditions.ArrDep[indexKey] then
        table.insert(timetableObject[line].stations[station].conditions.ArrDep, indexKey, condition)
        timetable.invalidateSortedSlotsCache(line, station)
        timetable.invalidateConstraintsByStationCache()
        return 0
    else
        return -2
    end
end

function timetable.updateArrDep(line, station, indexKey, indexValue, value)
    if not (line and station and indexKey and indexValue and value) then return -1 end
    if timetableObject[line] and
       timetableObject[line].stations[station] and
       timetableObject[line].stations[station].conditions and
       timetableObject[line].stations[station].conditions.ArrDep and
       timetableObject[line].stations[station].conditions.ArrDep[indexKey] and
       timetableObject[line].stations[station].conditions.ArrDep[indexKey][indexValue] then
       timetableObject[line].stations[station].conditions.ArrDep[indexKey][indexValue] = value
        timetable.invalidateSortedSlotsCache(line, station)
        timetable.invalidateConstraintsByStationCache()
        return 0
    else
		print("FAILED TO FIND DEPARTURE INDEX")
        return -2
    end
end

function timetable.updateDebounce(line, station, indexKey, value, debounceType)
    if not (line and station and indexKey and value) then return -1 end
    if timetableObject[line] and
       timetableObject[line].stations[station] and
       timetableObject[line].stations[station].conditions and
       timetableObject[line].stations[station].conditions[debounceType] then
       timetableObject[line].stations[station].conditions[debounceType][indexKey] = value
        return 0
    else
        return -2
    end
end

function timetable.removeAllConditions(line, station, type)
    if not(line and station) or (not (timetableObject[line]
       and timetableObject[line].stations[station])) then
        return -1
    end

    timetableObject[line].stations[station].conditions[type] = {}
    timetable.invalidateConstraintsByStationCache()
    if type == "ArrDep" then
        timetable.invalidateSortedSlotsCache(line, station)
    end
end

function timetable.removeCondition(line, station, type, index)
    if not(line and station and index) or (not (timetableObject[line]
       and timetableObject[line].stations[station])) then
        return -1
    end

    if type == "ArrDep" then
        local tmpTable = timetableObject[line].stations[station].conditions.ArrDep
        if tmpTable and tmpTable[index] then
            table.remove(tmpTable, index)
            timetable.invalidateSortedSlotsCache(line, station)
            timetable.invalidateConstraintsByStationCache()
            return tmpTable
        end
    else
        -- just remove the whole condition
        local tmpTable = timetableObject[line].stations[station].conditions[type]
        if tmpTable and tmpTable[index] then timetableObject[line].stations[station].conditions[type] = {} end
        timetable.invalidateConstraintsByStationCache()
        return 0
    end
    return -1
end

function timetable.hasTimetable(line)
    if timetableObject[line] then
        return timetableObject[line].hasTimetable
    else
        return false
    end
end

function timetable.updateForVehicle(vehicle, line, vehicles, vehicleState, currentTime)
    --if timetableHelper.isVehicleAtTerminal(timetableHelper.getVehicleInfo(vehicle)) then
        local stop = vehicleState.stopIndex + 1

        -- Check if this stop should be skipped
        if timetable.shouldSkipStop(vehicle, line, stop, currentTime) then
            -- Skip timetable logic for this stop - let vehicle continue
            if not vehicleState.autoDeparture then
                timetableHelper.restartAutoVehicleDeparture(vehicle)
            end
            return
        end

        if timetable.LineAndStationHasTimetable(line, stop) then
            timetable.departIfReady(vehicle, vehicles, line, stop, vehicleState, currentTime)
        elseif not vehicleState.autoDeparture then
            timetableHelper.restartAutoVehicleDeparture(vehicle)
        end

    --elseif not timetableHelper.getVehicleInfo(vehicle).autoDeparture then
    --    timetableHelper.restartAutoVehicleDeparture(vehicle)
    --end
end

function timetable.LineAndStationHasTimetable(line, stop)
    if not timetableObject[line].stations[stop] then return false end
    if not timetableObject[line].stations[stop].conditions then return false end
    if not timetableObject[line].stations[stop].conditions.type then return false end
    return not (timetableObject[line].stations[stop].conditions.type == "None")
end

function timetable.departIfReady(vehicle, vehicles, line, stop, vehicleState, currentTime)
    if vehicleState.autoDeparture then
        timetableHelper.stopAutoVehicleDeparture(vehicle)
    elseif vehicleState.doorsOpen then
        local arrivalTime = math.floor(vehicleState.doorsTime / 1000000)
        if timetable.readyToDepart(vehicle, arrivalTime, vehicles, line, stop, currentTime) then
            if timetableObject[line].stations[stop].conditions.type == "ArrDep" then
                -- Record delay before clearing vehicle from waiting list
                local waitingInfo = timetableObject[line].stations[stop].vehiclesWaiting and 
                                    timetableObject[line].stations[stop].vehiclesWaiting[vehicle]
                if waitingInfo and waitingInfo.departureTime then
                    local delay = currentTime - waitingInfo.departureTime
                    local delayTracker = require "celmi/timetables/delay_tracker"
                    delayTracker.recordDelay(line, stop, vehicle, delay, currentTime)
                end
                
                -- Clear the vehicle from the waiting list upon departure
                if timetableObject[line].stations[stop].vehiclesWaiting then
                    timetableObject[line].stations[stop].vehiclesWaiting[vehicle] = nil
                end
            end
            if timetable.getForceDepartureEnabled(line) then
                timetableHelper.departVehicle(vehicle)
            else
                timetableHelper.restartAutoVehicleDeparture(vehicle)
            end
        end
    end
end

function timetable.readyToDepart(vehicle, arrivalTime, vehicles, line, stop, currentTime)
    if not timetableObject[line] then return true end
    if not timetableObject[line].stations then return true end
    if not timetableObject[line].stations[stop] then return true end
    if not timetableObject[line].stations[stop].conditions then return true end
    if not timetableObject[line].stations[stop].conditions.type then return true end
    local conditionType = timetableObject[line].stations[stop].conditions.type

    if not timetableObject[line].stations[stop].vehiclesWaiting then
        timetableObject[line].stations[stop].vehiclesWaiting = {}
    end
    local vehiclesWaiting = timetableObject[line].stations[stop].vehiclesWaiting

    -- Use passed currentTime if available, otherwise fall back to getTime()
    local time = currentTime or timetableHelper.getTime()

    if conditionType == "ArrDep" then
        return timetable.readyToDepartArrDep(vehicle, arrivalTime, vehicles, time, line, stop, vehiclesWaiting)
    elseif conditionType == "debounce" or conditionType == "auto_debounce" then
        local debounceIsManual = conditionType == "debounce"
        return timetable.readyToDepartDebounce(vehicle, arrivalTime, vehicles, time, line, stop, vehiclesWaiting, debounceIsManual)
    end
end

---Gets the time a vehicle needs to wait for
---@param slot table in format like: {28, 45, 30, 00}
---@param arrivalTime integer for the time of arrival: 1740
---@return integer wait time: 60
function timetable.getWaitTime(slot, arrivalTime)
    local arrivalSlot = timetable.slotToArrivalSlot(slot)
    local departureSlot = timetable.slotToDepartureSlot(slot)
    if not timetable.afterArrivalSlot(arrivalSlot, arrivalTime) then
        local waitTime = (departureSlot - arrivalSlot) % 3600
        return waitTime + (arrivalSlot - arrivalTime) % 3600
    end
    if not timetable.afterDepartureSlot(arrivalSlot, departureSlot, arrivalTime) then
        return (departureSlot - arrivalTime) % 3600
    end
    return 0
end

---Gets the departure time for a vehicle
---Takes into account min and max wait times when enabled
---@param line integer the line the vehicle is only
---@param stop integer the stop on the line the vehicle is in
---@param arrivalTime integer the time the vehicle anotherVehicleArrivedEarlier
---@param waitTime integer the time the vehicle should wait for given its timetable slot
---@return integer time the vehicle should depart
function timetable.getDepartureTime(line, stop, arrivalTime, waitTime)
    local lineInfo = timetableHelper.getLineInfo(line)
    local stopInfo = lineInfo.stops[stop]
    if waitTime < 0 then waitTime = 0 end

    if timetable.getMinWaitEnabled(line) then
        if waitTime < stopInfo.minWaitingTime then
            waitTime = stopInfo.minWaitingTime
        end
    end
    if timetable.getMaxWaitEnabled(line) then
        if waitTime > stopInfo.maxWaitingTime then
            waitTime = stopInfo.maxWaitingTime
        end
    end

    return arrivalTime + waitTime
end

---Find the next valid timetable slot for given slots and arrival time
---@param vehicle integer The vehicle ID
---@param doorsTime integer The arrival time in seconds, calculated by the time the door opened.
---@param vehicles table Of vehicle IDs on this line. Currently unused.
---@param currentTime integer in seconds.
---@param line integer The line ID.
---@param stop integer The stop index (of the line).
---@param vehiclesWaiting table in format like: {[1]={arrivalTime=1800, slot={30,0,59,0}, departureTime=3540}, [2]={arrivalTime=540, slot={9,0,59,0}, departureTime=3540}}
---@return boolean readyToDepart True if ready. False if waiting.
function timetable.readyToDepartArrDep(vehicle, doorsTime, vehicles, currentTime, line, stop, vehiclesWaiting)
    -- Get active slots based on current time (supports time-based timetables)
    local slots = timetable.getActiveSlots(line, stop, currentTime)
    if not slots or slots == {} then
        -- If no active slots (no time period active or no slots defined), depart immediately
        return true
    end

    local slot = nil
    local departureTime = nil
    local validSlot = nil
    if  vehiclesWaiting[vehicle] then
        local arrivalTime = vehiclesWaiting[vehicle].arrivalTime
        slot = vehiclesWaiting[vehicle].slot
        departureTime = vehiclesWaiting[vehicle].departureTime

        -- Make sure the timetable slot for this vehicle isn't old. If it is old, remove it.
        if not arrivalTime or arrivalTime < doorsTime then
            vehiclesWaiting[vehicle] = nil
        elseif slot and departureTime then
            -- Use hash-based lookup for O(1) performance (with caching)
            validSlot = timetable.arrayContainsSlot(slot, slots, line, stop)
            
            -- Check maximum delay tolerance: if delay exceeds threshold, skip to next slot
            if validSlot and timetable.getMaxDelayToleranceEnabled(line, stop) then
                local maxDelayTolerance = timetable.getMaxDelayTolerance(line, stop)
                if maxDelayTolerance then
                    -- Calculate delay: how much later than scheduled departure time
                    local delay = currentTime - departureTime
                    if delay > maxDelayTolerance then
                        -- Delay exceeds tolerance: skip this slot and get next available slot
                        vehiclesWaiting[vehicle] = nil
                        validSlot = nil
                    end
                end
            end
            
            -- Apply delay recovery strategy if vehicle is delayed
            if validSlot and slot and departureTime then
                local delay = currentTime - departureTime
                if delay > 30 then -- Vehicle is delayed
                    local recoveryMode = timetable.getDelayRecoveryMode(line, stop)
                    if recoveryMode == DELAY_RECOVERY_MODE.CATCH_UP then
                        local lineMode = timetable.getLineDelayRecoveryMode(line)
                        if lineMode then recoveryMode = lineMode end
                    end
                    
                    if recoveryMode == DELAY_RECOVERY_MODE.SKIP_TO_NEXT then
                        -- Skip to next slot mode: clear current slot
                        vehiclesWaiting[vehicle] = nil
                        validSlot = nil
                    else
                        local adjustedDepartureTime = timetable.applyDelayRecovery(
                            line, stop, vehicle, delay, departureTime, currentTime, doorsTime
                        )
                        
                        if adjustedDepartureTime and adjustedDepartureTime ~= departureTime then
                            -- Update departure time based on recovery strategy
                            vehiclesWaiting[vehicle].departureTime = adjustedDepartureTime
                            departureTime = adjustedDepartureTime
                        end
                    end
                end
            end
        end
    end
    if not validSlot then
        -- Use historical delay data to predict arrival time if available
        local predictedArrivalTime = doorsTime
        local delayTracker = require "celmi/timetables/delay_tracker"
        local historicalDelay = delayTracker.getHistoricalDelay(line, stop, doorsTime)
        if historicalDelay and historicalDelay > 0 then
            -- Adjust arrival time prediction based on historical delays
            predictedArrivalTime = doorsTime + (historicalDelay * 0.5) -- Use 50% of historical delay as prediction
        end
        
        slot = timetable.getNextSlot(slots, predictedArrivalTime, vehiclesWaiting, line, stop, vehicle)
        -- getNextSlot returns nil when there are no slots. We should depart ASAP.
        if (slot == nil) then
            return true
        end
        local waitTime = timetable.getWaitTime(slot, doorsTime)
        departureTime = timetable.getDepartureTime(line, stop, doorsTime, waitTime)
        
        -- Record arrival delay (actual arrival vs scheduled arrival from slot)
        local scheduledArrival = timetable.slotToArrivalSlot(slot)
        local arrivalDelay = doorsTime - scheduledArrival
        delayTracker.recordArrivalDelay(line, stop, vehicle, arrivalDelay, doorsTime, scheduledArrival)
        
        -- Apply delay recovery if vehicle arrived late
        local scheduledArrival = timetable.slotToArrivalSlot(slot)
        local arrivalDelay = doorsTime - scheduledArrival
        if arrivalDelay > 30 then -- Vehicle arrived late
            local recoveryMode = timetable.getDelayRecoveryMode(line, stop)
            
            -- Advanced recovery strategies
            if recoveryMode == DELAY_RECOVERY_MODE.SKIP_STOPS then
                -- Skip stops strategy: reduce wait time at intermediate stops
                -- This is handled by reducing waitTime in getWaitTime calculation
                -- For now, just reduce wait time by 50% at non-terminal stops
                local stations = timetableHelper.getAllStations(line)
                local stationCount = 0
                for _ in pairs(stations) do
                    stationCount = stationCount + 1
                end
                
                -- Only apply at intermediate stops (not first or last)
                if stop > 1 and stop < stationCount then
                    waitTime = math.floor(waitTime * 0.5) -- Reduce wait time by 50%
                end
            elseif recoveryMode == DELAY_RECOVERY_MODE.RESET_AT_TERMINUS then
                -- Reset at terminus: at terminal stations, wait longer to reset schedule
                local stations = timetableHelper.getAllStations(line)
                local stationCount = 0
                for _ in pairs(stations) do
                    stationCount = stationCount + 1
                end
                
                -- At terminal stations, add extra wait time to reset
                if stop == 1 or stop == stationCount then
                    waitTime = waitTime + math.min(arrivalDelay, 300) -- Add up to 5 minutes
                end
            end
            if recoveryMode == DELAY_RECOVERY_MODE.CATCH_UP then
                local lineMode = timetable.getLineDelayRecoveryMode(line)
                if lineMode then recoveryMode = lineMode end
            end
            
            if recoveryMode == DELAY_RECOVERY_MODE.SKIP_TO_NEXT then
                -- Already getting next slot, which is correct
            elseif recoveryMode == DELAY_RECOVERY_MODE.GRADUAL_RECOVERY then
                -- Adjust departure time for gradual recovery
                local adjustedDelay = arrivalDelay * 0.1 -- Recover 10% per stop
                departureTime = departureTime + adjustedDelay
            elseif recoveryMode == DELAY_RECOVERY_MODE.HOLD_AT_TERMINUS then
                -- Check if terminus and apply extra wait
                local lineInfo = timetableHelper.getLineInfo(line)
                local allStops = {}
                for k, v in pairs(lineInfo.stops) do
                    allStops[k] = v
                end
                local maxStop = 0
                for k, _ in pairs(allStops) do
                    if k > maxStop then maxStop = k end
                end
                local isTerminus = (stop == 1 or stop == maxStop)
                if isTerminus then
                    local recoveryWait = arrivalDelay * 0.5
                    departureTime = math.max(departureTime, doorsTime + recoveryWait)
                end
            end
        end
        
        vehiclesWaiting[vehicle] = {
            arrivalTime = doorsTime,
            slot = slot,
            departureTime = departureTime
        }
    end

    if timetable.afterDepartureTime(departureTime, currentTime) then
        vehiclesWaiting[vehicle] = nil
        return true
    end

    return false
end

function timetable.setForceDepartureEnabled(line, value)
    if timetableObject[line] then
        timetableObject[line].forceDeparture = value
    end
end

function timetable.getForceDepartureEnabled(line)
    if timetableObject[line] then
        -- if true or nil
        if timetableObject[line].forceDeparture == nil then
			timetableObject[line].forceDeparture = false
        end
		return timetableObject[line].forceDeparture
    end

    return false
end

function timetable.setMinWaitEnabled(line, value)
    if timetableObject[line] then
        timetableObject[line].minWaitEnabled = value
    end
end

function timetable.getMinWaitEnabled(line)
    if timetableObject[line] then
        -- if true or nil
        if timetableObject[line].minWaitEnabled ~= false then
            return true
        end
    end

    return false
end

function timetable.setMaxWaitEnabled(line, value)
    if timetableObject[line] then
        timetableObject[line].maxWaitEnabled = value
    end
end

function timetable.getMaxWaitEnabled(line)
    if timetableObject[line] then
        -- if true
        if timetableObject[line].maxWaitEnabled then
            return true
        end
    end

    return false
end

-- Set maximum delay tolerance for a line/station (in seconds)
-- When delay exceeds this threshold, vehicle will skip to next available slot
function timetable.setMaxDelayTolerance(line, station, value)
    if not timetableObject[line] then
        timetableObject[line] = {hasTimetable = false, stations = {}}
    end
    if not timetableObject[line].stations[station] then
        timetableObject[line].stations[station] = {conditions = {}}
    end
    if not timetableObject[line].stations[station].maxDelayTolerance then
        timetableObject[line].stations[station].maxDelayTolerance = {}
    end
    timetableObject[line].stations[station].maxDelayTolerance = value
end

-- Get maximum delay tolerance for a line/station (in seconds)
-- Returns nil if not set (no delay tolerance limit)
function timetable.getMaxDelayTolerance(line, station)
    if timetableObject[line] and timetableObject[line].stations[station] then
        return timetableObject[line].stations[station].maxDelayTolerance
    end
    return nil
end

-- Enable/disable maximum delay tolerance for a line/station
function timetable.setMaxDelayToleranceEnabled(line, station, value)
    if not timetableObject[line] then
        timetableObject[line] = {hasTimetable = false, stations = {}}
    end
    if not timetableObject[line].stations[station] then
        timetableObject[line].stations[station] = {conditions = {}}
    end
    timetableObject[line].stations[station].maxDelayToleranceEnabled = value
end

-- Check if maximum delay tolerance is enabled for a line/station
function timetable.getMaxDelayToleranceEnabled(line, station)
    if timetableObject[line] and timetableObject[line].stations[station] then
        return timetableObject[line].stations[station].maxDelayToleranceEnabled == true
    end
    return false
end

-- Set delay recovery mode for a line/station
function timetable.setDelayRecoveryMode(line, station, mode)
    if not timetableObject[line] then
        timetableObject[line] = {hasTimetable = false, stations = {}}
    end
    if not timetableObject[line].stations[station] then
        local stationID = timetableHelper.getStationID(line, station)
        timetableObject[line].stations[station] = {stationID = stationID, conditions = {}}
    end
    
    timetableObject[line].stations[station].delayRecoveryMode = mode
end

-- Get delay recovery mode for a line/station (defaults to catch_up)
function timetable.getDelayRecoveryMode(line, station)
    if timetableObject[line] and timetableObject[line].stations[station] then
        return timetableObject[line].stations[station].delayRecoveryMode or DELAY_RECOVERY_MODE.CATCH_UP
    end
    return DELAY_RECOVERY_MODE.CATCH_UP
end

-- Set delay recovery mode for entire line (applies to all stations)
function timetable.setLineDelayRecoveryMode(line, mode)
    if not timetableObject[line] then return end
    
    timetableObject[line].delayRecoveryMode = mode
end

-- Get line-level delay recovery mode
function timetable.getLineDelayRecoveryMode(line)
    if timetableObject[line] and timetableObject[line].delayRecoveryMode then
        return timetableObject[line].delayRecoveryMode
    end
    return nil -- Use station-level or default
end

-- Apply delay recovery strategy
-- Returns adjusted departure time based on recovery mode
function timetable.applyDelayRecovery(line, stop, vehicle, currentDelay, scheduledDepartureTime, currentTime, arrivalTime)
    -- Get recovery mode (station-level takes precedence over line-level)
    local recoveryMode = timetable.getDelayRecoveryMode(line, stop)
    if recoveryMode == DELAY_RECOVERY_MODE.CATCH_UP then
        local lineMode = timetable.getLineDelayRecoveryMode(line)
        if lineMode then
            recoveryMode = lineMode
        end
    end
    
    -- No delay or small delay: use scheduled time
    if currentDelay <= 30 then
        return scheduledDepartureTime
    end
    
    -- Context-aware recovery: different strategies for different delay magnitudes
    local isLargeDelay = currentDelay > 300 -- More than 5 minutes
    local isMediumDelay = currentDelay > 120 -- More than 2 minutes
    
    if recoveryMode == DELAY_RECOVERY_MODE.CATCH_UP then
        -- For large delays, allow slightly more catch-up time
        if isLargeDelay then
            -- Allow catch-up with some buffer
            return math.max(scheduledDepartureTime, currentTime - 30) -- Allow 30s buffer
        else
            -- Current behavior: try to catch up (depart as soon as possible after scheduled time)
            return math.max(scheduledDepartureTime, currentTime)
        end
        
    elseif recoveryMode == DELAY_RECOVERY_MODE.SKIP_TO_NEXT then
        -- Skip to next slot: return nil to trigger getNextSlot
        return nil
        
    elseif recoveryMode == DELAY_RECOVERY_MODE.HOLD_AT_TERMINUS then
        -- Hold longer at terminus to realign (improved terminus detection)
        local lineInfo = timetableHelper.getLineInfo(line)
        if not lineInfo or not lineInfo.stops then
            -- Fallback: assume it's a terminus if we can't determine
            local recoveryWait = currentDelay * 0.5
            return math.max(scheduledDepartureTime, arrivalTime + recoveryWait)
        end
        
        local allStops = {}
        for k, v in pairs(lineInfo.stops) do
            allStops[k] = v
        end
        local maxStop = 0
        for k, _ in pairs(allStops) do
            if k > maxStop then maxStop = k end
        end
        
        -- Check if this is a terminus (first or last stop)
        local isTerminus = (stop == 1 or stop == maxStop)
        if isTerminus then
            -- Add extra wait time at terminus to recover delay
            -- Larger delays need more recovery time
            local recoveryFactor = isLargeDelay and 0.6 or (isMediumDelay and 0.5 or 0.4)
            local recoveryWait = currentDelay * recoveryFactor
            return math.max(scheduledDepartureTime, arrivalTime + recoveryWait)
        else
            -- Not a terminus: use catch up behavior
            return math.max(scheduledDepartureTime, currentTime)
        end
        
    elseif recoveryMode == DELAY_RECOVERY_MODE.GRADUAL_RECOVERY then
        -- Gradually recover over multiple stops
        -- Get configurable recovery rate (default 10% per stop)
        local recoveryRate = timetable.getRecoveryRate(line, stop) or 0.1
        local adjustedDelay = currentDelay * (1 - recoveryRate)
        return scheduledDepartureTime + adjustedDelay
    end
    
    -- Default: catch up
    return math.max(scheduledDepartureTime, currentTime)
end

-- Get recovery rate for a line/station (for gradual recovery mode)
function timetable.getRecoveryRate(line, station)
    if timetableObject[line] and timetableObject[line].stations[station] and
       timetableObject[line].stations[station].recoveryRate then
        return timetableObject[line].stations[station].recoveryRate
    end
    if timetableObject[line] and timetableObject[line].recoveryRate then
        return timetableObject[line].recoveryRate
    end
    return nil -- Use default (0.1)
end

-- Set recovery rate for a line/station
function timetable.setRecoveryRate(line, station, rate)
    if not timetableObject[line] then
        timetableObject[line] = {hasTimetable = false, stations = {}}
    end
    if station then
        if not timetableObject[line].stations[station] then
            local stationID = timetableHelper.getStationID(line, station)
            timetableObject[line].stations[station] = {stationID = stationID, conditions = {}}
        end
        timetableObject[line].stations[station].recoveryRate = rate
    else
        timetableObject[line].recoveryRate = rate
    end
end

-- Deep copy a table
local function deepCopy(original)
    if type(original) ~= "table" then
        return original
    end
    local copy = {}
    for key, value in pairs(original) do
        copy[key] = deepCopy(value)
    end
    return copy
end

-- Copy constraints from a source line/station to clipboard
function timetable.copyConstraints(sourceLine, sourceStation)
    if not timetableObject[sourceLine] or not timetableObject[sourceLine].stations[sourceStation] then
        return false
    end
    
    local sourceStopInfo = timetableObject[sourceLine].stations[sourceStation]
    local sourceConditions = sourceStopInfo.conditions
    
    if not sourceConditions or sourceConditions.type == "None" then
        return false
    end
    
    -- Copy the constraints data
    clipboard = {
        type = "condition",
        sourceLine = sourceLine,
        sourceStation = sourceStation,
        conditionType = sourceConditions.type,
        conditions = deepCopy(sourceConditions),
        maxDelayTolerance = sourceStopInfo.maxDelayTolerance,
        maxDelayToleranceEnabled = sourceStopInfo.maxDelayToleranceEnabled
    }
    
    return true
end

-- Paste constraints from clipboard to target line/station
function timetable.pasteConstraints(targetLine, targetStation)
    if not clipboard or clipboard.type ~= "condition" then
        return false
    end
    
    local conditionType = clipboard.conditionType
    if not conditionType or conditionType == "None" then
        return false
    end
    
    -- Ensure target line/station structure exists
    local stationID = timetableHelper.getStationID(targetLine, targetStation)
    if stationID == -1 then
        return false
    end
    
    -- Set the condition type first (this creates the structure if needed)
    timetable.setConditionType(targetLine, targetStation, conditionType)
    
    -- Copy the conditions data
    local targetStopInfo = timetableObject[targetLine].stations[targetStation]
    if targetStopInfo and targetStopInfo.conditions then
        -- Ensure stationID is set
        targetStopInfo.stationID = stationID
        
        -- Deep copy the conditions
        targetStopInfo.conditions = deepCopy(clipboard.conditions)
        targetStopInfo.conditions.type = conditionType
        
        -- Copy delay tolerance settings if they exist (only for ArrDep type)
        if conditionType == "ArrDep" then
            if clipboard.maxDelayTolerance ~= nil then
                targetStopInfo.maxDelayTolerance = clipboard.maxDelayTolerance
            end
            if clipboard.maxDelayToleranceEnabled ~= nil then
                targetStopInfo.maxDelayToleranceEnabled = clipboard.maxDelayToleranceEnabled
            end
        end
        
        -- Invalidate caches
        timetable.invalidateSortedSlotsCache(targetLine, targetStation)
        timetable.invalidateConstraintsByStationCache()
        timetable.invalidateStationLinesMapCache()
        
        return true
    end
    
    return false
end

-- Check if clipboard has data
function timetable.hasClipboard()
    return clipboard ~= nil
end

-- Get clipboard info (for display purposes)
function timetable.getClipboardInfo()
    if not clipboard then
        return nil
    end
    
    if clipboard.type == "condition" then
        return {
            type = "condition",
            conditionType = clipboard.conditionType,
            sourceLine = clipboard.sourceLine,
            sourceStation = clipboard.sourceStation
        }
    end
    
    return nil
end

-- Copy entire line timetable (all stations) to clipboard
function timetable.copyLineTimetable(sourceLine)
    if not timetableObject[sourceLine] or not timetableObject[sourceLine].stations then
        return false
    end
    
    -- Copy all station constraints
    local lineData = {
        stations = {}
    }
    
    for stationNumber, stationInfo in pairs(timetableObject[sourceLine].stations) do
        if stationInfo.conditions and stationInfo.conditions.type and stationInfo.conditions.type ~= "None" then
            lineData.stations[stationNumber] = {
                conditions = deepCopy(stationInfo.conditions),
                maxDelayTolerance = stationInfo.maxDelayTolerance,
                maxDelayToleranceEnabled = stationInfo.maxDelayToleranceEnabled
            }
        end
    end
    
    clipboard = {
        type = "line",
        sourceLine = sourceLine,
        lineData = lineData
    }
    
    return true
end

-- Paste entire line timetable from clipboard to target line
function timetable.pasteLineTimetable(targetLine)
    if not clipboard or clipboard.type ~= "line" then
        return false
    end
    
    if not clipboard.lineData or not clipboard.lineData.stations then
        return false
    end
    
    local pastedCount = 0
    for stationNumber, stationData in pairs(clipboard.lineData.stations) do
        if stationData.conditions and stationData.conditions.type then
            local stationID = timetableHelper.getStationID(targetLine, stationNumber)
            if stationID ~= -1 then
                timetable.setConditionType(targetLine, stationNumber, stationData.conditions.type)
                local targetStopInfo = timetableObject[targetLine].stations[stationNumber]
                if targetStopInfo and targetStopInfo.conditions then
                    -- Ensure stationID is set
                    targetStopInfo.stationID = stationID
                    
                    targetStopInfo.conditions = deepCopy(stationData.conditions)
                    targetStopInfo.conditions.type = stationData.conditions.type
                    
                    -- Copy delay tolerance settings (only for ArrDep type)
                    if stationData.conditions.type == "ArrDep" then
                        if stationData.maxDelayTolerance ~= nil then
                            targetStopInfo.maxDelayTolerance = stationData.maxDelayTolerance
                        end
                        if stationData.maxDelayToleranceEnabled ~= nil then
                            targetStopInfo.maxDelayToleranceEnabled = stationData.maxDelayToleranceEnabled
                        end
                    end
                    
                    timetable.invalidateSortedSlotsCache(targetLine, stationNumber)
                    pastedCount = pastedCount + 1
                end
            end
        end
    end
    
    if pastedCount > 0 then
        timetable.invalidateConstraintsByStationCache()
        timetable.invalidateStationLinesMapCache()
        return true
    end
    
    return false
end

-- Clear clipboard
function timetable.clearClipboard()
    clipboard = nil
end

-- Get departure time information for a vehicle at a station
-- Returns: {departureTime, slot, delay, status} or nil if vehicle not waiting
function timetable.getVehicleDepartureInfo(vehicle, line, stop, currentTime)
    if not timetableObject[line] or not timetableObject[line].stations[stop] then
        return nil
    end
    
    local stationInfo = timetableObject[line].stations[stop]
    if not stationInfo.vehiclesWaiting or not stationInfo.vehiclesWaiting[vehicle] then
        return nil
    end
    
    local waitingInfo = stationInfo.vehiclesWaiting[vehicle]
    local departureTime = waitingInfo.departureTime
    local slot = waitingInfo.slot
    local arrivalTime = waitingInfo.arrivalTime
    
    if not departureTime or not currentTime then
        return nil
    end
    
    -- Calculate delay (positive = late, negative = early)
    local delay = currentTime - departureTime
    
    -- Determine status
    local status = "on_time"
    if delay > 30 then
        status = "delayed"
    elseif delay < -30 then
        status = "early"
    end
    
    return {
        departureTime = departureTime,
        slot = slot,
        delay = delay,
        status = status,
        arrivalTime = arrivalTime
    }
end

-- Format departure time info as string for display
-- Returns formatted string like "Next departure: 12:30 (+2 min delay)"
function timetable.formatDepartureDisplay(departureInfo, currentTime)
    if not departureInfo or not currentTime then
        return nil
    end
    
    local depTime = departureInfo.departureTime
    local delay = departureInfo.delay
    
    -- Format departure time
    local depMin, depSec = timetable.secToMin(depTime % 3600)
    local depTimeStr = string.format("%02d:%02d", depMin, depSec)
    
    -- Format delay string
    local delayStr = ""
    if math.abs(delay) > 30 then
        if delay > 0 then
            delayStr = string.format(" (+%d min delay)", math.floor(delay / 60))
        else
            delayStr = string.format(" (%d min early)", math.floor(math.abs(delay) / 60))
        end
    else
        delayStr = " (On time)"
    end
    
    return "Next departure: " .. depTimeStr .. delayStr
end

-- Get slot information formatted as string
function timetable.formatSlotDisplay(slot)
    if not slot then return nil end
    
    local arrMin, arrSec = timetable.secToMin(timetable.slotToArrivalSlot(slot))
    local depMin, depSec = timetable.secToMin(timetable.slotToDepartureSlot(slot))
    
    return string.format("Arr: %02d:%02d | Dep: %02d:%02d", arrMin, arrSec, depMin, depSec)
end

-- Get next departures for a station (for departure board)
-- Returns array of {lineID, stopNr, departureTime, vehicle, slot, status, delay}
function timetable.getNextDepartures(stationID, count, currentTime)
    count = count or 10
    if not stationID or not currentTime then return {} end
    
    local departures = {}
    local stationLinesMap = timetable.getStationLinesMap()
    
    if not stationLinesMap[stationID] then
        return {}
    end
    
    -- Iterate through all lines serving this station
    for lineID, _ in pairs(stationLinesMap[stationID]) do
        if timetable.hasTimetable(lineID) and cachedEntityExists(lineID) then
            -- Find the stop number for this station on this line
            local lineInfo = timetableObject[lineID]
            if lineInfo and lineInfo.stations then
                for stopNr, stopInfo in pairs(lineInfo.stations) do
                    if stopInfo.stationID == stationID then
                        local conditionType = stopInfo.conditions and stopInfo.conditions.type
                        
                        -- Only process ArrDep constraints for departure board
                        if conditionType == "ArrDep" and stopInfo.conditions.ArrDep then
                            local slots = stopInfo.conditions.ArrDep
                            local vehiclesWaiting = stopInfo.vehiclesWaiting or {}
                            
                            -- Get vehicles currently at this stop
                            local vehicles = timetableHelper.getVehiclesOnLine(lineID)
                            for _, vehicle in pairs(vehicles) do
                                local vehicleState = timetableHelper.getVehicleInfo(vehicle)
                                if vehicleState and vehicleState.state == api.type.enum.TransportVehicleState.AT_TERMINAL then
                                    local vehicleStop = vehicleState.stopIndex + 1
                                    
                                    if vehicleStop == stopNr then
                                        local depInfo = timetable.getVehicleDepartureInfo(vehicle, lineID, stopNr, currentTime)
                                        if depInfo and depInfo.departureTime then
                                            table.insert(departures, {
                                                lineID = lineID,
                                                stopNr = stopNr,
                                                departureTime = depInfo.departureTime,
                                                vehicle = vehicle,
                                                slot = depInfo.slot,
                                                status = depInfo.status,
                                                delay = depInfo.delay,
                                                arrivalTime = depInfo.arrivalTime
                                            })
                                        end
                                    end
                                end
                            end
                            
                            -- Also get upcoming slots that don't have vehicles assigned yet
                            -- (This is a simplified version - in a full implementation, we'd calculate future slots)
                            -- For now, we'll focus on vehicles currently at the station
                        end
                    end
                end
            end
        end
    end
    
    -- Sort by departure time
    table.sort(departures, function(a, b)
        -- Handle wrap-around (times near 59:59 vs 00:00)
        local timeA = a.departureTime % 3600
        local timeB = b.departureTime % 3600
        local currentTimeMod = currentTime % 3600
        
        -- Calculate time until departure (handling wrap-around)
        local waitA = (timeA - currentTimeMod + 3600) % 3600
        local waitB = (timeB - currentTimeMod + 3600) % 3600
        
        return waitA < waitB
    end)
    
    -- Return only the requested count
    local result = {}
    for i = 1, math.min(count, #departures) do
        table.insert(result, departures[i])
    end
    
    return result
end

-- Check if ArrDep conditions use time periods (time-based timetables)
function timetable.hasTimePeriods(line, station)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return false
    end
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or not conditions.ArrDep then
        return false
    end
    -- Check if ArrDep has timePeriods structure
    return conditions.ArrDep.timePeriods ~= nil
end

-- Get active time period for a given time (returns index and period data)
-- Uses binary search for O(log n) lookup
function timetable.getActiveTimePeriod(line, station, currentTime)
    if not timetable.hasTimePeriods(line, station) then
        return nil
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    local timePeriods = conditions.ArrDep.timePeriods
    if not timePeriods or #timePeriods == 0 then
        return nil
    end
    
    -- Check cache first
    if not activeTimePeriodCache[line] then
        activeTimePeriodCache[line] = {}
    end
    local cached = activeTimePeriodCache[line][station]
    if cached and cached.periodIndex and cached.lastUpdate then
        -- Cache is valid for 60 seconds (time periods don't change that frequently)
        if currentTime - cached.lastUpdate < 60 then
            local period = timePeriods[cached.periodIndex]
            if period then
                local timeMod = currentTime % 3600
                local startMod = period.startTime % 3600
                local endMod = period.endTime % 3600
                
                -- Check if cached period is still active
                if startMod <= endMod then
                    -- Normal case: start < end (e.g., 07:00 - 09:00)
                    if timeMod >= startMod and timeMod < endMod then
                        return cached.periodIndex, period
                    end
                else
                    -- Wrap-around case: start > end (e.g., 22:00 - 06:00)
                    if timeMod >= startMod or timeMod < endMod then
                        return cached.periodIndex, period
                    end
                end
            end
        end
    end
    
    -- Binary search for active time period
    local timeMod = currentTime % 3600
    local left = 1
    local right = #timePeriods
    local bestMatch = nil
    local bestIndex = nil
    
    -- Sort periods by start time for binary search (if not already sorted)
    local sortedPeriods = {}
    for i = 1, #timePeriods do
        table.insert(sortedPeriods, {index = i, period = timePeriods[i]})
    end
    table.sort(sortedPeriods, function(a, b)
        return (a.period.startTime % 3600) < (b.period.startTime % 3600)
    end)
    
    -- Binary search
    while left <= right do
        local mid = math.floor((left + right) / 2)
        local period = sortedPeriods[mid].period
        local startMod = period.startTime % 3600
        local endMod = period.endTime % 3600
        
        if startMod <= endMod then
            -- Normal case: start < end
            if timeMod >= startMod and timeMod < endMod then
                bestMatch = period
                bestIndex = sortedPeriods[mid].index
                break
            elseif timeMod < startMod then
                right = mid - 1
            else
                left = mid + 1
            end
        else
            -- Wrap-around case: start > end
            if timeMod >= startMod or timeMod < endMod then
                bestMatch = period
                bestIndex = sortedPeriods[mid].index
                break
            elseif timeMod >= endMod and timeMod < startMod then
                -- Time is in the gap between periods
                right = mid - 1
            else
                left = mid + 1
            end
        end
    end
    
    -- If no match found, check all periods (in case of gaps)
    if not bestMatch then
        for i = 1, #timePeriods do
            local period = timePeriods[i]
            local startMod = period.startTime % 3600
            local endMod = period.endTime % 3600
            
            if startMod <= endMod then
                if timeMod >= startMod and timeMod < endMod then
                    bestMatch = period
                    bestIndex = i
                    break
                end
            else
                if timeMod >= startMod or timeMod < endMod then
                    bestMatch = period
                    bestIndex = i
                    break
                end
            end
        end
    end
    
    -- Update cache
    if bestIndex then
        activeTimePeriodCache[line][station] = {
            periodIndex = bestIndex,
            lastUpdate = currentTime
        }
        return bestIndex, bestMatch
    end
    
    return nil
end

-- Get slots for active time period (or all slots if no time periods)
function timetable.getActiveSlots(line, station, currentTime)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return nil
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or not conditions.ArrDep then
        return nil
    end
    
    -- If using time periods, get active period's slots
    if timetable.hasTimePeriods(line, station) then
        local periodIndex, period = timetable.getActiveTimePeriod(line, station, currentTime)
        if period and period.slots then
            return period.slots
        else
            -- No active period, return empty (vehicle should depart immediately)
            return {}
        end
    else
        -- Legacy format: ArrDep is directly the slots array
        return conditions.ArrDep
    end
end

-- Add a time period to ArrDep conditions
-- startTime and endTime are in seconds (0-3599 for hour, or absolute seconds)
function timetable.addTimePeriod(line, station, startTime, endTime, slots)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return false
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or conditions.type ~= "ArrDep" then
        return false
    end
    
    -- Initialize time periods structure if needed
    if not conditions.ArrDep.timePeriods then
        -- If ArrDep already has slots in legacy format, convert to time period
        local legacySlots = conditions.ArrDep
        conditions.ArrDep = {
            timePeriods = {}
        }
        -- Add a default time period covering the whole hour with legacy slots
        if legacySlots and #legacySlots > 0 then
            table.insert(conditions.ArrDep.timePeriods, {
                startTime = 0,
                endTime = 3600,
                slots = legacySlots
            })
        end
    end
    
    -- Add new time period
    table.insert(conditions.ArrDep.timePeriods, {
        startTime = startTime % 3600,  -- Normalize to 0-3599
        endTime = endTime % 3600,
        slots = slots or {}
    })
    
    -- Sort periods by start time
    table.sort(conditions.ArrDep.timePeriods, function(a, b)
        return (a.startTime % 3600) < (b.startTime % 3600)
    end)
    
    -- Invalidate caches
    timetable.invalidateSortedSlotsCache(line, station)
    timetable.invalidateConstraintsByStationCache()
    
    return true
end

-- Remove a time period by index
function timetable.removeTimePeriod(line, station, periodIndex)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return false
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or not conditions.ArrDep or not conditions.ArrDep.timePeriods then
        return false
    end
    
    if periodIndex < 1 or periodIndex > #conditions.ArrDep.timePeriods then
        return false
    end
    
    table.remove(conditions.ArrDep.timePeriods, periodIndex)
    
    -- If no periods left, convert back to legacy format or clear
    if #conditions.ArrDep.timePeriods == 0 then
        conditions.ArrDep.timePeriods = nil
        conditions.ArrDep = {}
    end
    
    -- Invalidate caches
    timetable.invalidateSortedSlotsCache(line, station)
    timetable.invalidateConstraintsByStationCache()
    if activeTimePeriodCache[line] then
        activeTimePeriodCache[line][station] = nil
    end
    
    return true
end

-- Update a time period
function timetable.updateTimePeriod(line, station, periodIndex, startTime, endTime, slots)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return false
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or not conditions.ArrDep or not conditions.ArrDep.timePeriods then
        return false
    end
    
    if periodIndex < 1 or periodIndex > #conditions.ArrDep.timePeriods then
        return false
    end
    
    local period = conditions.ArrDep.timePeriods[periodIndex]
    if startTime ~= nil then
        period.startTime = startTime % 3600
    end
    if endTime ~= nil then
        period.endTime = endTime % 3600
    end
    if slots ~= nil then
        period.slots = slots
    end
    
    -- Re-sort periods
    table.sort(conditions.ArrDep.timePeriods, function(a, b)
        return (a.startTime % 3600) < (b.startTime % 3600)
    end)
    
    -- Invalidate caches
    timetable.invalidateSortedSlotsCache(line, station)
    timetable.invalidateConstraintsByStationCache()
    if activeTimePeriodCache[line] then
        activeTimePeriodCache[line][station] = nil
    end
    
    return true
end

-- Get all time periods for a line/station
function timetable.getTimePeriods(line, station)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return nil
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or not conditions.ArrDep then
        return nil
    end
    
    if conditions.ArrDep.timePeriods then
        return conditions.ArrDep.timePeriods
    else
        -- Return legacy format as a single period covering whole hour
        if conditions.ArrDep and #conditions.ArrDep > 0 then
            return {{
                startTime = 0,
                endTime = 3600,
                slots = conditions.ArrDep
            }}
        end
    end
    
    return nil
end

-- Validation warning types
local VALIDATION_WARNING = {
    DEPARTURE_BEFORE_ARRIVAL = "departure_before_arrival",
    SLOTS_TOO_CLOSE = "slots_too_close",
    IMPOSSIBLE_JOURNEY_TIME = "impossible_journey_time",
    OVERLAPPING_TIME_PERIODS = "overlapping_time_periods",
    INVALID_TIME_PERIOD = "invalid_time_period",
    NO_SLOTS_IN_PERIOD = "no_slots_in_period",
    FREQUENCY_MISMATCH = "frequency_mismatch",
    INSUFFICIENT_BUFFER = "insufficient_buffer"
}

-- Validate a single ArrDep slot
-- Returns: {valid = bool, warnings = {warning1, warning2, ...}, suggestions = {suggestion1, ...}}
function timetable.validateSlot(slot, previousDepartureTime, journeyTime)
    local warnings = {}
    local suggestions = {}
    
    if not slot or #slot < 4 then
        return {valid = false, warnings = {"Invalid slot format"}, suggestions = {}}
    end
    
    local arrivalSlot = timetable.slotToArrivalSlot(slot)
    local departureSlot = timetable.slotToDepartureSlot(slot)
    
    -- Check: departure before arrival (within same slot)
    if departureSlot < arrivalSlot then
        -- Handle wrap-around case (e.g., arrive 59:00, depart 01:00)
        local timeDiff = (3600 - arrivalSlot) + departureSlot
        if timeDiff > 60 then -- More than 1 minute wrap-around is suspicious
            table.insert(warnings, {
                type = VALIDATION_WARNING.DEPARTURE_BEFORE_ARRIVAL,
                message = "Departure time is before arrival time (may be intentional if crossing midnight)",
                severity = "medium"
            })
        end
    elseif departureSlot == arrivalSlot then
        table.insert(warnings, {
            type = VALIDATION_WARNING.DEPARTURE_BEFORE_ARRIVAL,
            message = "Departure time equals arrival time (no dwell time)",
            severity = "low"
        })
        table.insert(suggestions, "Consider adding at least 30 seconds dwell time")
    end
    
    -- Check: slots too close together (if previous departure time provided)
    if previousDepartureTime then
        local timeBetweenSlots = (arrivalSlot - previousDepartureTime + 3600) % 3600
        if journeyTime and timeBetweenSlots < journeyTime then
            table.insert(warnings, {
                type = VALIDATION_WARNING.SLOTS_TOO_CLOSE,
                message = string.format("Only %d seconds between departure and next arrival (journey time: %d seconds)", 
                    timeBetweenSlots, journeyTime),
                severity = "high"
            })
            table.insert(suggestions, string.format("Increase gap to at least %d seconds", journeyTime))
        elseif timeBetweenSlots < 30 then
            table.insert(warnings, {
                type = VALIDATION_WARNING.SLOTS_TOO_CLOSE,
                message = string.format("Very short gap (%d seconds) between slots", timeBetweenSlots),
                severity = "medium"
            })
        end
    end
    
    -- Check: impossible journey time (if journey time provided)
    if journeyTime and previousDepartureTime then
        local timeAvailable = (arrivalSlot - previousDepartureTime + 3600) % 3600
        if timeAvailable < journeyTime * 0.8 then -- Allow 20% tolerance
            table.insert(warnings, {
                type = VALIDATION_WARNING.IMPOSSIBLE_JOURNEY_TIME,
                message = string.format("Insufficient time for journey (%d seconds available, %d seconds needed)", 
                    timeAvailable, journeyTime),
                severity = "high"
            })
            table.insert(suggestions, string.format("Schedule arrival at least %d seconds after previous departure", 
                math.ceil(journeyTime * 1.2)))
        end
    end
    
    return {
        valid = #warnings == 0 or (#warnings == 1 and warnings[1].severity == "low"),
        warnings = warnings,
        suggestions = suggestions
    }
end

-- Validate all slots for a line/station
-- Enhanced timetable validation with frequency checks and delay-based suggestions
function timetable.validateTimetable(line, station)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return {valid = true, warnings = {}, suggestions = {}}
    end
    
    local conditions = timetableObject[line].stations[station].conditions
    if not conditions or conditions.type ~= "ArrDep" then
        return {valid = true, warnings = {}, suggestions = {}}
    end
    
    local allWarnings = {}
    local allSuggestions = {}
    local legTimes = timetableHelper.getLegTimes(line)
    local journeyTime = legTimes[station] or nil -- Journey time from previous station
    local delayTracker = require "celmi/timetables/delay_tracker" -- Load once for efficiency
    
    -- Get slots (either from time periods or legacy format)
    local slots = nil
    if timetable.hasTimePeriods(line, station) then
        local periods = timetable.getTimePeriods(line, station)
        if periods then
            -- Validate each time period
            for periodIndex, period in ipairs(periods) do
                -- Check time period validity
                if period.startTime >= period.endTime and (period.endTime % 3600) ~= 0 then
                    table.insert(allWarnings, {
                        type = VALIDATION_WARNING.INVALID_TIME_PERIOD,
                        message = string.format("Time period %d: Invalid time range", periodIndex),
                        severity = "high",
                        periodIndex = periodIndex
                    })
                end
                
                -- Check for overlapping periods
                for otherIndex, otherPeriod in ipairs(periods) do
                    if otherIndex ~= periodIndex then
                        local start1 = period.startTime % 3600
                        local end1 = period.endTime % 3600
                        local start2 = otherPeriod.startTime % 3600
                        local end2 = otherPeriod.endTime % 3600
                        
                        -- Check for overlap (simplified check)
                        if start1 <= end1 and start2 <= end2 then
                            if (start1 < end2 and start2 < end1) then
                                table.insert(allWarnings, {
                                    type = VALIDATION_WARNING.OVERLAPPING_TIME_PERIODS,
                                    message = string.format("Time periods %d and %d overlap", periodIndex, otherIndex),
                                    severity = "high",
                                    periodIndex = periodIndex,
                                    otherPeriodIndex = otherIndex
                                })
                            end
                        end
                    end
                end
                
                -- Check if period has slots
                if not period.slots or #period.slots == 0 then
                    table.insert(allWarnings, {
                        type = VALIDATION_WARNING.NO_SLOTS_IN_PERIOD,
                        message = string.format("Time period %d has no slots", periodIndex),
                        severity = "medium",
                        periodIndex = periodIndex
                    })
                else
                    -- Validate slots in this period
                    local previousDeparture = nil
                    for slotIndex, slot in ipairs(period.slots) do
                        local validation = timetable.validateSlot(slot, previousDeparture, journeyTime)
                        for _, warning in ipairs(validation.warnings) do
                            warning.periodIndex = periodIndex
                            warning.slotIndex = slotIndex
                            table.insert(allWarnings, warning)
                        end
                        for _, suggestion in ipairs(validation.suggestions) do
                            table.insert(allSuggestions, suggestion)
                        end
                        
                        if validation.valid then
                            previousDeparture = timetable.slotToDepartureSlot(slot)
                        end
                    end
                    
                            -- Check frequency match for this period
                    local lineFrequency = timetableHelper.getFrequency(line)
                    if lineFrequency > 0 and #period.slots > 1 then
                        local firstSlot = period.slots[1]
                        local lastSlot = period.slots[#period.slots]
                        local firstDeparture = timetable.slotToDepartureSlot(firstSlot)
                        local lastDeparture = timetable.slotToDepartureSlot(lastSlot)
                        local slotSpan = (lastDeparture - firstDeparture + 3600) % 3600
                        local expectedSpan = lineFrequency * (#period.slots - 1)
                        local difference = math.abs(slotSpan - expectedSpan)
                        
                        if difference > lineFrequency * 0.2 then
                            table.insert(allWarnings, {
                                type = VALIDATION_WARNING.FREQUENCY_MISMATCH,
                                message = string.format("Time period %d: Slot spacing doesn't match line frequency", periodIndex),
                                severity = "medium",
                                periodIndex = periodIndex
                            })
                        end
                    end
                end
            end
        end
    else
        -- Legacy format: validate all slots
        slots = conditions.ArrDep
        if slots and #slots > 0 then
            local previousDeparture = nil
            for slotIndex, slot in ipairs(slots) do
                local validation = timetable.validateSlot(slot, previousDeparture, journeyTime)
                for _, warning in ipairs(validation.warnings) do
                    warning.slotIndex = slotIndex
                    table.insert(allWarnings, warning)
                end
                for _, suggestion in ipairs(validation.suggestions) do
                    table.insert(allSuggestions, suggestion)
                end
                
                if validation.valid then
                    previousDeparture = timetable.slotToDepartureSlot(slot)
                end
            end
            
            -- Check frequency match (if line has frequency set)
            local lineFrequency = timetableHelper.getFrequency(line)
            if lineFrequency > 0 and #slots > 1 then
                local firstSlot = slots[1]
                local lastSlot = slots[#slots]
                local firstDeparture = timetable.slotToDepartureSlot(firstSlot)
                local lastDeparture = timetable.slotToDepartureSlot(lastSlot)
                local slotSpan = (lastDeparture - firstDeparture + 3600) % 3600
                local expectedSpan = lineFrequency * (#slots - 1)
                local difference = math.abs(slotSpan - expectedSpan)
                
                if difference > lineFrequency * 0.2 then
                    table.insert(allWarnings, {
                        type = VALIDATION_WARNING.FREQUENCY_MISMATCH,
                        message = "Slot spacing doesn't match line frequency",
                        severity = "medium"
                    })
                end
            end
            
            -- Add delay-based buffer suggestions
            local suggestedBuffer = timetable.suggestBufferTime(line, station)
            if suggestedBuffer then
                table.insert(allSuggestions, string.format("Consider adding %d seconds buffer time based on historical delays", suggestedBuffer))
            end
        end
    end
    
    -- Check for insufficient buffer times based on historical delays
    local stats = delayTracker.getEnhancedStatistics(line, station)
    if stats and stats.totalCount > 10 and stats.avgDelay > 60 then
        local suggestedBuffer = timetable.suggestBufferTime(line, station)
        if suggestedBuffer and suggestedBuffer > stats.avgDelay * 1.5 then
            table.insert(allWarnings, {
                type = VALIDATION_WARNING.INSUFFICIENT_BUFFER,
                message = string.format("Average delay (%d seconds) suggests need for more buffer time", stats.avgDelay),
                severity = "low"
            })
        end
    end
    
    -- Check for high severity warnings
    local hasHighSeverityWarnings = false
    for _, warning in ipairs(allWarnings) do
        if warning.severity == "high" then
            hasHighSeverityWarnings = true
            break
        end
    end
    
    return {
        valid = #allWarnings == 0,
        warnings = allWarnings,
        suggestions = allSuggestions,
        hasHighSeverityWarnings = hasHighSeverityWarnings
    }
end

-- Get validation warnings for a line/station
function timetable.getValidationWarnings(line, station)
    return timetable.validateTimetable(line, station)
end

-- Skip pattern management functions

-- Check if a vehicle should skip a stop
function timetable.shouldSkipStop(vehicle, line, stop, currentTime)
    if not timetableObject[line] or not timetableObject[line].stations[stop] then
        return false
    end
    
    local stationInfo = timetableObject[line].stations[stop]
    if not stationInfo.skipPatterns then
        return false
    end
    
    local skipPatterns = stationInfo.skipPatterns
    
    -- Check slot-based skip patterns
    if skipPatterns.slotBased and skipPatterns.slotBased.enabled then
        local currentSlot = timetable.getCurrentSlotForVehicle(vehicle, line, stop, currentTime)
        if currentSlot then
            local slotKey = timetable.slotToKey(currentSlot)
            if slotKey and skipPatterns.slotBased.skipSlots and skipPatterns.slotBased.skipSlots[slotKey] then
                return true
            end
        end
    end
    
    -- Check vehicle-based skip patterns
    if skipPatterns.vehicleBased and skipPatterns.vehicleBased.enabled then
        if skipPatterns.vehicleBased.skipVehicles and skipPatterns.vehicleBased.skipVehicles[vehicle] then
            return true
        end
    end
    
    -- Check alternating pattern
    if skipPatterns.alternating and skipPatterns.alternating.enabled then
        local vehiclesOnLine = timetableHelper.getVehiclesOnLine(line)
        local vehicleIndex = nil
        for i, v in ipairs(vehiclesOnLine) do
            if v == vehicle then
                vehicleIndex = i
                break
            end
        end
        
        if vehicleIndex then
            local pattern = skipPatterns.alternating.pattern or "A-B" -- A-B means every other vehicle
            if pattern == "A-B" then
                -- Even index vehicles skip
                if vehicleIndex % 2 == 0 then
                    return true
                end
            elseif pattern == "B-A" then
                -- Odd index vehicles skip
                if vehicleIndex % 2 == 1 then
                    return true
                end
            end
        end
    end
    
    -- Check zone express pattern
    if skipPatterns.zoneExpress and skipPatterns.zoneExpress.enabled then
        local zones = skipPatterns.zoneExpress.zones
        if zones then
            -- Check if stop is in a zone that should be skipped
            for _, zone in ipairs(zones) do
                if zone.skipStops then
                    for _, skipStop in ipairs(zone.skipStops) do
                        if skipStop == stop then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    return false
end

-- Get current slot for a vehicle (for slot-based skip patterns)
function timetable.getCurrentSlotForVehicle(vehicle, line, stop, currentTime)
    if not timetableObject[line] or not timetableObject[line].stations[stop] then
        return nil
    end
    
    local stationInfo = timetableObject[line].stations[stop]
    if stationInfo.vehiclesWaiting and stationInfo.vehiclesWaiting[vehicle] then
        return stationInfo.vehiclesWaiting[vehicle].slot
    end
    
    return nil
end

-- Set skip pattern for a line/station
function timetable.setSkipPattern(line, station, patternType, patternData)
    if not timetableObject[line] then
        timetableObject[line] = {hasTimetable = false, stations = {}}
    end
    if not timetableObject[line].stations[station] then
        local stationID = timetableHelper.getStationID(line, station)
        timetableObject[line].stations[station] = {stationID = stationID, conditions = {}}
    end
    
    if not timetableObject[line].stations[station].skipPatterns then
        timetableObject[line].stations[station].skipPatterns = {}
    end
    
    local skipPatterns = timetableObject[line].stations[station].skipPatterns
    
    if patternType == "slotBased" then
        skipPatterns.slotBased = patternData or {enabled = false, skipSlots = {}}
    elseif patternType == "vehicleBased" then
        skipPatterns.vehicleBased = patternData or {enabled = false, skipVehicles = {}}
    elseif patternType == "alternating" then
        skipPatterns.alternating = patternData or {enabled = false, pattern = "A-B"}
    elseif patternType == "zoneExpress" then
        skipPatterns.zoneExpress = patternData or {enabled = false, zones = {}}
    end
    
    timetable.invalidateConstraintsByStationCache()
end

-- Get skip pattern for a line/station
function timetable.getSkipPattern(line, station, patternType)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return nil
    end
    
    local skipPatterns = timetableObject[line].stations[station].skipPatterns
    if not skipPatterns then
        return nil
    end
    
    return skipPatterns[patternType]
end

-- Add stop to slot-based skip list
function timetable.addSlotSkipStop(line, station, slot, stopIndex)
    local pattern = timetable.getSkipPattern(line, station, "slotBased")
    if not pattern then
        timetable.setSkipPattern(line, station, "slotBased", {enabled = true, skipSlots = {}})
        pattern = timetable.getSkipPattern(line, station, "slotBased")
    end
    
    if not pattern.skipSlots then
        pattern.skipSlots = {}
    end
    
    local slotKey = timetable.slotToKey(slot)
    if slotKey then
        if not pattern.skipSlots[slotKey] then
            pattern.skipSlots[slotKey] = {}
        end
        pattern.skipSlots[slotKey][stopIndex] = true
    end
end

-- Remove stop from slot-based skip list
function timetable.removeSlotSkipStop(line, station, slot, stopIndex)
    local pattern = timetable.getSkipPattern(line, station, "slotBased")
    if pattern and pattern.skipSlots then
        local slotKey = timetable.slotToKey(slot)
        if slotKey and pattern.skipSlots[slotKey] then
            pattern.skipSlots[slotKey][stopIndex] = nil
        end
    end
end

-- Get skip stops for a slot
function timetable.getSkipStopsForSlot(line, station, slot)
    local pattern = timetable.getSkipPattern(line, station, "slotBased")
    if not pattern or not pattern.enabled or not pattern.skipSlots then
        return {}
    end
    
    local slotKey = timetable.slotToKey(slot)
    if not slotKey or not pattern.skipSlots[slotKey] then
        return {}
    end
    
    local skipStops = {}
    for stopIndex, _ in pairs(pattern.skipSlots[slotKey]) do
        table.insert(skipStops, stopIndex)
    end
    
    return skipStops
end

-- Auto-generate timetable for a line
-- options: {startTime = seconds (0-3599), endTime = seconds (0-3599), dwellTime = seconds, frequency = seconds (optional, uses line frequency if not provided)}
function timetable.autoGenerateTimetable(lineID, options)
    options = options or {}
    
    if not cachedEntityExists(lineID) then
        return false, "Line does not exist"
    end
    
    -- Get line frequency
    local frequency = options.frequency
    if not frequency then
        frequency = timetableObject[lineID] and timetableObject[lineID].frequency
        if not frequency then
            frequency = timetableHelper.getFrequency(lineID)
        end
    end
    
    if not frequency or frequency <= 0 then
        return false, "Line frequency not available"
    end
    
    -- Get journey times between stations
    local legTimes = timetableHelper.getLegTimes(lineID)
    if not legTimes or #legTimes == 0 then
        return false, "Journey times not available (line may need vehicles)"
    end
    
    -- Get all stations on the line
    local stations = timetableHelper.getAllStations(lineID)
    if not stations or #stations == 0 then
        return false, "No stations found on line"
    end
    
    -- Default options
    local startTime = options.startTime or 0 -- Start of hour (00:00)
    local endTime = options.endTime or 3600 -- End of hour (60:00, wraps to 00:00)
    local dwellTime = options.dwellTime or 30 -- Default 30 seconds dwell time
    
    -- Normalize startTime to 0-3599 range
    startTime = startTime % 3600
    
    -- Handle endTime: if > 3600, it means it wraps to next hour
    -- Normalize to 0-3599 for within-hour, but keep > 3600 for wrap-around
    if endTime > 3600 then
        -- Already in wrap-around format (e.g., 79200 = 22:00 next day)
        -- Convert to seconds within 24-hour period
        endTime = endTime % 86400
        if endTime < startTime then
            endTime = endTime + 3600 -- Add one hour for wrap-around
        end
    else
        -- Normalize to 0-3599 range
        endTime = endTime % 3600
        -- Handle wrap-around within same hour
        if endTime <= startTime then
            endTime = endTime + 3600 -- Add one hour for wrap-around
        end
    end
    
    -- Calculate time range
    local timeRange = endTime - startTime
    if timeRange <= 0 then
        return false, "Invalid time range"
    end
    
    -- Calculate number of slots based on frequency
    local numSlots = math.floor(timeRange / frequency)
    if numSlots < 1 then
        numSlots = 1
    end
    
    -- Generate slots for each station
    local stationNumbers = {}
    for k, _ in pairs(stations) do
        table.insert(stationNumbers, k)
    end
    table.sort(stationNumbers)
    
    -- Calculate cumulative journey times from first station
    local cumulativeTimes = {}
    cumulativeTimes[stationNumbers[1]] = 0
    for i = 2, #stationNumbers do
        local prevStation = stationNumbers[i - 1]
        local journeyTime = legTimes[prevStation] or 60 -- Default 60 seconds if not available
        cumulativeTimes[stationNumbers[i]] = (cumulativeTimes[prevStation] or 0) + journeyTime
    end
    
    -- Generate slots for first station (reference station)
    local firstStationSlots = {}
    for i = 0, numSlots - 1 do
        local slotTime = (startTime + i * frequency) % 3600
        local slotMin, slotSec = timetable.secToMin(slotTime)
        local depTime = (slotTime + dwellTime) % 3600
        local depMin, depSec = timetable.secToMin(depTime)
        
        table.insert(firstStationSlots, {slotMin, slotSec, depMin, depSec})
    end
    
    -- Generate slots for all stations based on first station and journey times
    for _, stationNum in ipairs(stationNumbers) do
        -- Calculate offset from first station
        local timeOffset = cumulativeTimes[stationNum] or 0
        
        -- Generate slots for this station
        local stationSlots = {}
        for _, firstSlot in ipairs(firstStationSlots) do
            local arrTime = timetable.slotToArrivalSlot(firstSlot)
            local depTime = timetable.slotToDepartureSlot(firstSlot)
            
            -- Add journey time offset to arrival
            local newArrTime = (arrTime + timeOffset) % 3600
            local newDepTime = (depTime + timeOffset) % 3600
            
            -- Ensure departure is after arrival (add dwell time if needed)
            if newDepTime < newArrTime then
                newDepTime = (newArrTime + dwellTime) % 3600
            end
            
            local arrMin, arrSec = timetable.secToMin(newArrTime)
            local depMin, depSec = timetable.secToMin(newDepTime)
            
            table.insert(stationSlots, {arrMin, arrSec, depMin, depSec})
        end
        
        -- Set condition type to ArrDep if not already set
        if timetable.getConditionType(lineID, stationNum) == "None" then
            timetable.setConditionType(lineID, stationNum, "ArrDep")
        end
        
        -- Clear existing ArrDep slots and add new ones
        timetable.removeAllConditions(lineID, stationNum, "ArrDep")
        for _, slot in ipairs(stationSlots) do
            timetable.addCondition(lineID, stationNum, {
                type = "ArrDep",
                ArrDep = {slot}
            })
        end
    end
    
    -- Invalidate caches
    for _, stationNum in ipairs(stationNumbers) do
        timetable.invalidateSortedSlotsCache(lineID, stationNum)
    end
    timetable.invalidateConstraintsByStationCache()
    timetable.invalidateStationLinesMapCache()
    
    return true, string.format("Generated %d slots for %d stations", numSlots, #stationNumbers)
end

-- Get aggregated statistics for an entire line (across all stations)
-- Get enhanced statistics for a line (uses delay tracker enhanced statistics)
function timetable.getLineStatistics(lineID)
    if not timetableObject[lineID] or not timetableObject[lineID].stations then
        return nil
    end
    
    local delayTracker = require "celmi/timetables/delay_tracker"
    local totalOnTime = 0
    local totalCount = 0
    local totalDelay = 0
    local stationCount = 0
    local minDelay = math.huge
    local maxDelay = -math.huge
    local allDelays = {}
    
    for stationNumber, _ in pairs(timetableObject[lineID].stations) do
        -- Use enhanced statistics with distribution data
        local stats = delayTracker.getEnhancedStatistics(lineID, stationNumber)
        if stats.totalCount > 0 then
            totalOnTime = totalOnTime + stats.onTimeCount
            totalCount = totalCount + stats.totalCount
            totalDelay = totalDelay + (stats.avgDelay * stats.totalCount)
            stationCount = stationCount + 1
            
            -- Track min/max delays
            if stats.minDelay and stats.minDelay < minDelay then
                minDelay = stats.minDelay
            end
            if stats.maxDelay and stats.maxDelay > maxDelay then
                maxDelay = stats.maxDelay
            end
        end
    end
    
    if totalCount == 0 then
        return {
            onTimePercentage = 0,
            avgDelay = 0,
            totalCount = 0,
            minDelay = 0,
            maxDelay = 0,
            medianDelay = 0,
            stationCount = stationCount
        }
    end
    
    local avgDelay = totalDelay / totalCount
    local onTimePercentage = (totalOnTime / totalCount) * 100
    
    return {
        onTimePercentage = onTimePercentage,
        avgDelay = avgDelay,
        totalCount = totalCount,
        minDelay = minDelay ~= math.huge and minDelay or 0,
        maxDelay = maxDelay ~= -math.huge and maxDelay or 0,
        stationCount = stationCount
    }
end

-- Get vehicle delay status (on-time, slightly late, very late)
function timetable.getVehicleDelayStatus(vehicle, line, station, currentTime)
    local delayTracker = require "celmi/timetables/delay_tracker"
    local waitingInfo = timetableObject[line] and timetableObject[line].stations[station] and
                        timetableObject[line].stations[station].vehiclesWaiting and
                        timetableObject[line].stations[station].vehiclesWaiting[vehicle]
    
    if not waitingInfo or not waitingInfo.departureTime then
        return "unknown"
    end
    
    local delay = currentTime - waitingInfo.departureTime
    
    if math.abs(delay) <= 30 then
        return "on_time"
    elseif delay <= 120 then
        return "slightly_late"
    elseif delay <= 300 then
        return "late"
    else
        return "very_late"
    end
end

-- Get line health score (0-100, higher is better)
function timetable.getLineHealthScore(line)
    local stats = timetable.getLineStatistics(line)
    if not stats or stats.totalCount == 0 then
        return 50 -- Neutral score if no data
    end
    
    -- Calculate health score based on:
    -- - On-time percentage (70% weight)
    -- - Average delay (30% weight, normalized)
    local onTimeScore = stats.onTimePercentage
    local delayScore = math.max(0, 100 - (math.abs(stats.avgDelay) / 6)) -- 6 minutes = 0 score
    
    return (onTimeScore * 0.7) + (delayScore * 0.3)
end

-- Identify bottleneck stations (stations causing most delays)
function timetable.identifyBottleneckStations(line, topN)
    topN = topN or 5
    if not timetableObject[line] or not timetableObject[line].stations then
        return {}
    end
    
    local delayTracker = require "celmi/timetables/delay_tracker"
    local bottlenecks = {}
    
    for stationNumber, _ in pairs(timetableObject[line].stations) do
        local stats = delayTracker.getEnhancedStatistics(line, stationNumber)
        if stats.totalCount > 10 then -- Only consider stations with enough data
            local impactScore = stats.avgDelay * stats.totalCount -- Impact = avg delay * frequency
            table.insert(bottlenecks, {
                station = stationNumber,
                avgDelay = stats.avgDelay,
                totalCount = stats.totalCount,
                impactScore = impactScore,
                onTimePercentage = stats.onTimePercentage
            })
        end
    end
    
    -- Sort by impact score (descending)
    table.sort(bottlenecks, function(a, b) return a.impactScore > b.impactScore end)
    
    -- Return top N
    local result = {}
    for i = 1, math.min(topN, #bottlenecks) do
        table.insert(result, bottlenecks[i])
    end
    
    return result
end

-- Suggest buffer time based on historical delays
function timetable.suggestBufferTime(line, station)
    if not line or not station then return nil end
    
    local delayTracker = require "celmi/timetables/delay_tracker"
    local stats = delayTracker.getEnhancedStatistics(line, station)
    
    if not stats or stats.totalCount < 5 then
        return nil -- Not enough data
    end
    
    -- Suggest buffer time based on average delay and variance
    -- Buffer should cover most delays (use 75th percentile if available, otherwise average + variance)
    local suggestedBuffer = stats.avgDelay
    if stats.p75Delay then
        suggestedBuffer = stats.p75Delay
    elseif stats.avgDelay > 0 then
        -- Add variance to average for safety margin
        suggestedBuffer = stats.avgDelay + math.sqrt(stats.delayVariance or 0)
    end
    
    -- Round to nearest 15 seconds
    suggestedBuffer = math.ceil(suggestedBuffer / 15) * 15
    
    -- Cap at reasonable maximum (5 minutes)
    suggestedBuffer = math.min(suggestedBuffer, 300)
    
    -- Minimum buffer of 30 seconds
    suggestedBuffer = math.max(suggestedBuffer, 30)
    
    return suggestedBuffer
end

-- Get destination station name for a line at a specific stop
function timetable.getDestinationForLineAtStation(lineID, stopNr)
    local lineInfo = timetableHelper.getLineInfo(lineID)
    if not lineInfo or not lineInfo.stops then return "Unknown" end
    
    -- Get the last stop on the line (destination)
    local allStops = {}
    for k, v in pairs(lineInfo.stops) do
        allStops[k] = v
    end
    
    -- Find the maximum stop index
    local maxStop = 0
    for k, _ in pairs(allStops) do
        if k > maxStop then maxStop = k end
    end
    
    if maxStop > stopNr then
        -- Destination is further along the line
        local destStop = lineInfo.stops[maxStop]
        if destStop and destStop.stationGroup then
            return timetableHelper.getStationName(destStop.stationGroup)
        end
    else
        -- Already at or past the destination
        return timetableHelper.getStationName(lineInfo.stops[stopNr].stationGroup)
    end
    
    return "Unknown"
end

function timetable.readyToDepartDebounce(vehicle, arrivalTime, vehicles, time, line, stop, vehiclesWaiting, debounceIsManual)
    local departureTime = nil

    if vehiclesWaiting[vehicle] then
        departureTime = vehiclesWaiting[vehicle].departureTime
    end

    if departureTime == nil then
        if #vehicles == 1 then
            departureTime = time -- depart now if the vehicle is the only one on the line
        elseif timetable.anotherVehicleArrivedEarlier(vehicle, arrivalTime, line, stop) then
            return false -- Unknown depart time
        elseif debounceIsManual then
            departureTime = timetable.manualDebounceDepartureTime(arrivalTime, vehicles, time, line, stop, vehiclesWaiting)
        else
            departureTime = timetable.autoDebounceDepartureTime(arrivalTime, vehicles, time, line, stop, vehiclesWaiting)
        end
        vehiclesWaiting[vehicle] = { departureTime = departureTime }
    end

    if timetable.afterDepartureTime(departureTime, time) then
        vehiclesWaiting[vehicle] = nil
        return true
    end

    return false
end

function timetable.manualDebounceDepartureTime(arrivalTime, vehicles, time, line, stop, vehiclesWaiting)
    local previousDepartureTime = timetableHelper.getPreviousDepartureTime(stop, vehicles, vehiclesWaiting)
    local condition = timetable.getConditions(line, stop, "debounce")
    if condition == -1 then condition = {0, 0} end
    if not condition[1] then condition[1] = 0 end
    if not condition[2] then condition[2] = 0 end

    local unbunchTime = timetable.minToSec(condition[1], condition[2])
    local nextDepartureTime = previousDepartureTime + unbunchTime
    local waitTime = nextDepartureTime - arrivalTime
    return timetable.getDepartureTime(line, stop, arrivalTime, waitTime)
end

function timetable.autoDebounceDepartureTime(arrivalTime, vehicles, time, line, stop, vehiclesWaiting)
    local previousDepartureTime = timetableHelper.getPreviousDepartureTime(stop, vehicles, vehiclesWaiting)
    local frequency = timetableObject[line].frequency
    if not frequency then return end

    local condition = timetable.getConditions(line, stop, "auto_debounce")
    if condition == -1 then condition = {1, 0} end
    if not condition[1] then condition[1] = 1 end
    if not condition[2] then condition[2] = 0 end

    local marginTime = timetable.minToSec(condition[1], condition[2])
    local nextDepartureTime = previousDepartureTime + frequency - marginTime
    local waitTime = nextDepartureTime - arrivalTime
    return timetable.getDepartureTime(line, stop, arrivalTime, waitTime)
end

-- Account for vehicles currently waiting or departing
function timetable.anotherVehicleArrivedEarlier(vehicle, arrivalTime, line, stop)
    local vehiclesAtStop = timetableHelper.getVehiclesAtStop(line, stop)
    if #vehiclesAtStop <= 1 then return false end
    for _, otherVehicle in pairs(vehiclesAtStop) do
        if otherVehicle ~= vehicle then
            local otherVehicleInfo = timetableHelper.getVehicleInfo(otherVehicle)
            if otherVehicleInfo.doorsOpen then
                local otherArrivalTime = math.floor(otherVehicleInfo.doorsTime / 1000000)
                return otherArrivalTime < arrivalTime
            else
                return true
            end
        end
    end

    return false
end

function timetable.setHasTimetable(line, bool)
    if timetableObject[line] then
        timetableObject[line].hasTimetable = bool
        if bool == false and timetableObject[line].stations then
            for station, _ in pairs(timetableObject[line].stations) do
                timetableObject[line].stations[station].vehiclesWaiting = {}
            end
        end
    else
        timetableObject[line] = {stations = {} , hasTimetable = bool}
    end

    -- Directly update the timetable lines cache using the new API
    if bool then
        -- Add line to cache when timetable is enabled
        timetable.addLineToTimetableCache(line)
    else
        -- Remove line from cache when timetable is disabled
        timetable.removeLineFromTimetableCache(line)
    end

    return bool
end

--- Start all vehicles of given line.
---@param line number line id
function timetable.restartAutoDepartureForAllLineVehicles(line)
    for _, vehicle in pairs(timetableHelper.getVehiclesOnLine(line)) do
        timetableHelper.restartAutoVehicleDeparture(vehicle)
    end
end


-------------- UTILS FUNCTIONS ----------

function timetable.afterDepartureTime(departureTime, currentTime)
    return departureTime <= currentTime
end

function timetable.afterArrivalSlot(arrivalSlot, arrivalTime)
    local furthestFromArrivalSlot = (arrivalSlot + (30 * 60)) % 3600
    arrivalTime = arrivalTime % 3600
    if arrivalSlot < furthestFromArrivalSlot then
        return arrivalSlot <= arrivalTime and arrivalTime < furthestFromArrivalSlot
    else
        return not(furthestFromArrivalSlot <= arrivalTime and arrivalTime < arrivalSlot)
    end
end

function timetable.afterDepartureSlot(arrivalSlot, departureSlot, arrivalTime)
    arrivalTime = arrivalTime % 3600
    if arrivalSlot <= departureSlot then
        -- Eg. the arrival time is 10:00 and the departure is 12:00
        return arrivalTime < arrivalSlot or departureSlot <= arrivalTime
    else
        -- Eg. the arrival time is 59:00 and the departure is 01:00
        return arrivalTime < arrivalSlot and departureSlot <= arrivalTime
    end
end

---Find the next valid timetable slot for given slots and arrival time
---@param slots table in format like: {{30,0,59,0},{9,0,59,0}}
---@param arrivalTime number in seconds (can be predicted arrival time)
---@param vehiclesWaiting table in format like: {[1]={slot={30,0,59,0}, departureTime=3540}, [2]={slot={9,0,59,0}, departureTime=3540}}
---@param line integer The line ID (optional, for caching)
---@param stop integer The stop index (optional, for caching)
---@param vehicle integer The vehicle ID (optional, for priority/conflict resolution)
---@return table | nil closestSlot example: {30,0,59,0}
function timetable.getNextSlot(slots, arrivalTime, vehiclesWaiting, line, stop, vehicle)
    -- Add nil checks and early returns
    if not slots or #slots == 0 then return nil end
    if not vehiclesWaiting then vehiclesWaiting = {} end
    
    -- Check if vehicle has a train assignment to a specific slot
    if vehicle and line and stop and timetableObject[line] and timetableObject[line].stations and timetableObject[line].stations[stop] then
        local stationInfo = timetableObject[line].stations[stop]
        if stationInfo.trainAssignments and stationInfo.trainAssignments[vehicle] then
            local assignment = stationInfo.trainAssignments[vehicle]
            local assignedSlot = assignment.slot
            local slotIndex = assignment.slotIndex
            
            -- Validate that the assigned slot is still valid
            if assignedSlot and timetable.isValidSlot(assignedSlot, arrivalTime, slots, line, stop) then
                -- Check if slot is available (not occupied by another vehicle)
                local slotAvailable = true
                if vehiclesWaiting then
                    for otherVehicle, waitingInfo in pairs(vehiclesWaiting) do
                        if otherVehicle ~= vehicle and waitingInfo.slot and timetable.slotsEqual(assignedSlot, waitingInfo.slot) then
                            -- Slot is occupied by another vehicle
                            slotAvailable = false
                            break
                        end
                    end
                end
                
                if slotAvailable then
                    return assignedSlot
                end
            else
                -- Assignment is invalid, clear it
                timetable.removeTrainAssignment(line, stop, vehicle)
            end
        end
    end
    
    -- Use cached sorted slots if line and stop are provided, otherwise sort on the fly
    local sortedSlots
    if line and stop then
        sortedSlots = timetable.getSortedSlots(line, stop, slots)
    else
        -- Fallback: sort directly if line/stop not available
        sortedSlots = {}
        for i = 1, #slots do
            sortedSlots[i] = slots[i]
        end
        table.sort(sortedSlots, function(slot1, slot2)
            local arrivalSlot1 = timetable.slotToArrivalSlot(slot1)
            local arrivalSlot2 = timetable.slotToArrivalSlot(slot2)
            return arrivalSlot1 < arrivalSlot2
        end)
    end

    -- Find the distance from the arrival time
    local res = {diff = 3601, value = nil}
    for index, slot in pairs(sortedSlots) do
        local arrivalSlot = timetable.slotToArrivalSlot(slot)
        local diff = timetable.getTimeDifference(arrivalSlot, arrivalTime % 3600)

        if (diff < res.diff) then
            res = {diff = diff, index = index}
        end
    end

    -- Return nil when there are no contraints
    if not res.index then return nil end

    -- Split vehiclesWaiting by whether they have departed
    local waitingSlots = {}
    local departedSlots = {}
    if #slots == 1 then
        for vehicle, _ in pairs(vehiclesWaiting) do
            vehiclesWaiting[vehicle] = nil
        end
    else
        -- Note: getNextSlot doesn't have access to currentTime parameter yet
        -- This is called from readyToDepartArrDep which already has time parameter
        -- We can pass time through if needed, but for now use getTime() here
        local time = timetableHelper.getTime()
        for vehicle, waitingVehicle in pairs(vehiclesWaiting) do
            local departureTime = waitingVehicle.departureTime
            local slot = waitingVehicle.slot
            -- Remove waitingVehicle if it is in invalid format
            if not (departureTime and slot) then
                vehiclesWaiting[vehicle] = nil
		    elseif timetable.afterDepartureTime(departureTime, time) then
                vehiclesWaiting[vehicle] = nil
				-- Debug print removed for performance
				-- print("PRUNING OLD WAITING VEHICLE SLOT")
            elseif arrivalTime <= departureTime then
                waitingSlots[vehicle] = slot
            else
                departedSlots[vehicle] = slot
            end
        end
    end

    -- Find if the slot with the closest arrival time is currently being used
    -- If true, find the next consecutive available slot
    for i = res.index, #sortedSlots + res.index - 1 do
        -- Need to make sure that 2 mod 2 returns 2 rather than 0
        local normalisedIndex = ((i - 1) % #sortedSlots) + 1

        local slot = sortedSlots[normalisedIndex]
        local slotAvailable = true
		if timetable.getWaitTime(slot, arrivalTime) <= 0 then
            slotAvailable = false
        elseif timetable.arrayContainsSlot(slot, waitingSlots, line, stop) then
            -- Slot is occupied, check if we should resolve conflict
            if vehicle and line and stop then
                local conflictResolved = timetable.resolveSlotConflict(slot, vehicle, waitingSlots, line, stop)
                if conflictResolved then
                    slotAvailable = true
                else
                    slotAvailable = false
                end
            else
                slotAvailable = false
            end
            -- if the nearest slot is still waiting and not resolved, then all departedSlots can be removed
            if not slotAvailable then
                for vehicle, _ in pairs(departedSlots) do
                    vehiclesWaiting[vehicle] = nil
                    departedSlots[vehicle] = nil
                end
            end
        else
            -- if the nearest slot is a departed, all other departedSlots can be removed
            for vehicle, departedSlot in pairs(departedSlots) do
                if timetable.slotsEqual(slot, departedSlot) then
                    slotAvailable = false
                else
                    vehiclesWaiting[vehicle] = nil
                    departedSlots[vehicle] = nil
                end
            end
        end

        if slotAvailable then
            return slot
        end
    end

    -- If all slots are being used, still return the closest slot anyway.
    return sortedSlots[res.index]
end

-- Resolve slot conflict when multiple vehicles want same slot
-- Returns true if current vehicle should get the slot, false otherwise
function timetable.resolveSlotConflict(slot, vehicle, waitingSlots, line, stop)
    if not vehicle or not line or not stop then return false end
    
    -- Find which vehicle(s) are currently using this slot
    local conflictingVehicles = {}
    for v, s in pairs(waitingSlots) do
        if timetable.slotsEqual(s, slot) then
            table.insert(conflictingVehicles, v)
        end
    end
    
    if #conflictingVehicles == 0 then return true end -- No conflict
    
    -- Calculate priority for current vehicle
    local currentPriority = timetable.calculateVehiclePriority(vehicle, line, stop)
    
    -- Check if current vehicle has higher priority than conflicting vehicles
    for _, conflictingVehicle in ipairs(conflictingVehicles) do
        local conflictPriority = timetable.calculateVehiclePriority(conflictingVehicle, line, stop)
        if conflictPriority >= currentPriority then
            return false -- Conflicting vehicle has equal or higher priority
        end
    end
    
    -- Current vehicle has highest priority, remove conflicting vehicles from slot
    for _, conflictingVehicle in ipairs(conflictingVehicles) do
        if timetableObject[line] and timetableObject[line].stations[stop] and
           timetableObject[line].stations[stop].vehiclesWaiting then
            timetableObject[line].stations[stop].vehiclesWaiting[conflictingVehicle] = nil
        end
    end
    
    return true
end

-- Calculate vehicle priority for slot assignment (higher = more priority)
function timetable.calculateVehiclePriority(vehicle, line, stop)
    local priority = 50 -- Base priority
    
    -- Delay-aware: vehicles with more delay get higher priority
    local delayTracker = require "celmi/timetables/delay_tracker"
    local delay = delayTracker.getArrivalDelay(line, stop, vehicle)
    if delay then
        if delay > 120 then -- More than 2 minutes late
            priority = priority + 30
        elseif delay > 60 then -- More than 1 minute late
            priority = priority + 15
        end
    end
    
    -- Historical preference: vehicles that historically use this slot get priority
    -- (This is simplified - in a full implementation, track vehicle-slot history)
    
    -- Load-aware: full vehicles get priority (if vehicle info available)
    local vehicleInfo = timetableHelper.getVehicleInfo(vehicle)
    if vehicleInfo and vehicleInfo.passengerCount and vehicleInfo.capacity then
        local loadFactor = vehicleInfo.passengerCount / math.max(vehicleInfo.capacity, 1)
        if loadFactor > 0.8 then -- More than 80% full
            priority = priority + 20
        elseif loadFactor > 0.5 then
            priority = priority + 10
        end
    end
    
    return priority
end

-- Create a string key from a slot for O(1) hash lookup
function timetable.slotToKey(slot)
    if not slot or not slot[1] then return nil end
    return string.format("%d:%d:%d:%d", slot[1] or 0, slot[2] or 0, slot[3] or 0, slot[4] or 0)
end

-- Convert slot array to hash set for O(1) lookup
function timetable.slotArrayToHashSet(slotArray)
    local hashSet = {}
    for key, slotItem in pairs(slotArray) do
        local slotKey = timetable.slotToKey(slotItem)
        if slotKey then
            hashSet[slotKey] = true
        end
    end
    return hashSet
end

function timetable.arrayContainsSlot(slot, slotArray, line, station)
    -- Use hash-based lookup for O(1) performance
    local slotKey = timetable.slotToKey(slot)
    if not slotKey then return false end
    
    -- Use cached hash set if line and station are provided
    local hashSet = nil
    if line and station then
        if not slotHashSetCache[line] then
            slotHashSetCache[line] = {}
        end
        local cached = slotHashSetCache[line][station]
        
        -- Create a hash of the slot array to verify cache validity
        local slotArrayHash = timetable.getSlotArrayHash(slotArray)
        if cached and cached.hashSet and cached.slotHash == slotArrayHash then
            hashSet = cached.hashSet
        else
            hashSet = timetable.slotArrayToHashSet(slotArray)
            slotHashSetCache[line][station] = {
                hashSet = hashSet,
                slotHash = slotArrayHash
            }
        end
    else
        hashSet = timetable.slotArrayToHashSet(slotArray)
    end
    
    return hashSet[slotKey] == true
end

-- Generate a hash string from slot array for cache validation
function timetable.getSlotArrayHash(slotArray)
    if not slotArray or #slotArray == 0 then return "" end
    local hashParts = {}
    for i, slot in ipairs(slotArray) do
        if slot and slot[1] then
            table.insert(hashParts, string.format("%d:%d:%d:%d", slot[1] or 0, slot[2] or 0, slot[3] or 0, slot[4] or 0))
        end
    end
    return table.concat(hashParts, "|")
end

-- Keep slotsEqual for backwards compatibility, but prefer slotToKey for comparisons
function timetable.slotsEqual(slot1, slot2)
    if slot1 == slot2 then
        return true
    elseif (
        slot1[1] == slot2[1] and 
        slot1[2] == slot2[2] and
        slot1[3] == slot2[3] and
        slot1[4] == slot2[4]
    ) then
        return true
    end
    return false
end

function timetable.slotToArrivalSlot(slot)
    guard.againstNil(slot)
    return timetable.minToSec(slot[1], slot[2])
end

function timetable.slotToDepartureSlot(slot)
    guard.againstNil(slot)
    return timetable.minToSec(slot[3], slot[4])
end

function timetable.minToSec(min, sec)
    return min * 60 + sec
end

function timetable.secToMin(sec)
    local min = math.floor(sec / 60) % 60
    local sec = math.floor(sec % 60)
    return min, sec
end

function timetable.minToStr(min, sec)
    return string.format("%02d:%02d", min, sec)
end

function timetable.secToStr(sec)
    local min, sec = timetable.secToMin(sec)
    return timetable.minToStr(min, sec)
end

function timetable.deltaSecToStr(deltaSec)
    return math.floor(deltaSec / 6) / 10
end

---Calculates the time difference between two timestamps in seconds.
---Considers that 59 mins is close to 0 mins.
---@param a number in seconds between in range of 0-3599 (inclusive)
---@param b number in seconds between in range of 0-3599 (inclusive)
---@return number
function timetable.getTimeDifference(a, b)
    local absDiff = math.abs(a - b)
    if absDiff > 1800 then
        return 3600 - absDiff
    else
        return absDiff
    end
end

---Shifts a time in minutes and seconds by some offset
---Helper function for shiftSlot() 
---@param time table in format like: {28,45}
---@param offset number in seconds 
---@return table shifted time, example: {30,0}
function timetable.shiftTime(time, offset)
    local timeSeconds = (time + offset) % 3600
    return {math.floor(timeSeconds / 60), timeSeconds % 60}
end


---Shifts a slot by some offset
---@param slot table in format like: {30,0,59,0}
---@param offset number in seconds 
---@return table slot shifted time, example: {31,0,0,0}
function timetable.shiftSlot(slot, offset)
    local arrivalSlot = timetable.slotToArrivalSlot(slot)
    local shiftArr = timetable.shiftTime(arrivalSlot, offset)
    local departureSlot = timetable.slotToDepartureSlot(slot)
    local shiftDep = timetable.shiftTime(departureSlot, offset)
    return {shiftArr[1], shiftArr[2], shiftDep[1], shiftDep[2]}
end

-- Serialize timetable data to string (for export)
-- Returns a string representation of the timetable data
function timetable.exportTimetable(lineID)
    local exportData = {}
    
    if lineID then
        -- Export single line
        if timetableObject[lineID] then
            exportData[lineID] = timetableObject[lineID]
        else
            return nil
        end
    else
        -- Export all lines
        exportData = timetableObject
    end
    
    -- Convert to string using simple serialization
    return timetable.serializeTable(exportData)
end

-- Deserialize timetable data from string (for import)
-- Returns true on success, false on failure
function timetable.importTimetable(importString, lineID, mergeMode)
    mergeMode = mergeMode or "replace" -- "replace" or "merge"
    
    if not importString or importString == "" then
        return false, "Empty import string"
    end
    
    -- Parse the string back to table
    local success, importedData = pcall(function()
        -- Use loadstring to evaluate the serialized table
        local func = loadstring("return " .. importString)
        if not func then
            error("Invalid import format")
        end
        return func()
    end)
    
    if not success or not importedData then
        return false, "Failed to parse import data: " .. tostring(importedData)
    end
    
    -- Validate imported data structure
    if type(importedData) ~= "table" then
        return false, "Invalid data format: expected table"
    end
    
    -- Import data
    if lineID then
        -- Import to specific line
        if importedData[lineID] then
            if mergeMode == "merge" and timetableObject[lineID] then
                -- Merge stations
                if not timetableObject[lineID].stations then
                    timetableObject[lineID].stations = {}
                end
                for stationNum, stationData in pairs(importedData[lineID].stations or {}) do
                    timetableObject[lineID].stations[stationNum] = stationData
                end
                -- Merge other properties
                if importedData[lineID].hasTimetable ~= nil then
                    timetableObject[lineID].hasTimetable = importedData[lineID].hasTimetable
                end
                if importedData[lineID].frequency then
                    timetableObject[lineID].frequency = importedData[lineID].frequency
                end
            else
                -- Replace
                timetableObject[lineID] = importedData[lineID]
            end
        else
            -- Try to find first line in imported data
            for importedLineID, lineData in pairs(importedData) do
                timetableObject[lineID] = lineData
                break
            end
        end
    else
        -- Import all lines
        if mergeMode == "merge" then
            for importedLineID, lineData in pairs(importedData) do
                if timetableObject[importedLineID] then
                    -- Merge existing line
                    if not timetableObject[importedLineID].stations then
                        timetableObject[importedLineID].stations = {}
                    end
                    for stationNum, stationData in pairs(lineData.stations or {}) do
                        timetableObject[importedLineID].stations[stationNum] = stationData
                    end
                else
                    -- Add new line
                    timetableObject[importedLineID] = lineData
                end
            end
        else
            -- Replace all
            for importedLineID, lineData in pairs(importedData) do
                timetableObject[importedLineID] = lineData
            end
        end
    end
    
    -- Invalidate caches
    timetable.invalidateConstraintsByStationCache()
    timetable.invalidateStationLinesMapCache()
    timetable.initializeTimetableLinesCache()
    
    return true, "Import successful"
end

-- Serialize a table to a string (simple implementation)
function timetable.serializeTable(t, indent)
    indent = indent or 0
    local indentStr = string.rep("  ", indent)
    local result = {}
    
    if type(t) ~= "table" then
        if type(t) == "string" then
            return string.format("%q", t)
        else
            return tostring(t)
        end
    end
    
    table.insert(result, "{\n")
    
    local first = true
    for k, v in pairs(t) do
        if not first then
            table.insert(result, ",\n")
        end
        first = false
        
        table.insert(result, indentStr .. "  ")
        
        -- Handle key
        if type(k) == "number" then
            table.insert(result, "[" .. k .. "]")
        else
            table.insert(result, "[" .. string.format("%q", tostring(k)) .. "]")
        end
        
        table.insert(result, " = ")
        
        -- Handle value
        if type(v) == "table" then
            table.insert(result, timetable.serializeTable(v, indent + 1))
        elseif type(v) == "string" then
            table.insert(result, string.format("%q", v))
        else
            table.insert(result, tostring(v))
        end
    end
    
    table.insert(result, "\n" .. indentStr .. "}")
    
    return table.concat(result)
end

-- Export timetable to clipboard-friendly format (simplified)
function timetable.exportTimetableToClipboard(lineID)
    local exportString = timetable.exportTimetable(lineID)
    if not exportString then
        return false
    end
    
    -- Store in clipboard variable (for GUI to access)
    timetable.exportClipboard = exportString
    return true
end

-- Get exported data from clipboard
function timetable.getExportedClipboard()
    return timetable.exportClipboard
end

-- Clear export clipboard
function timetable.clearExportedClipboard()
    timetable.exportClipboard = nil
end

-------------------------------------------------------------
---------------------- Enhanced Export/Import ----------------------
-------------------------------------------------------------

-- Export timetable to file (via CommonAPI2 if available, otherwise returns string)
-- @param lineID integer The line ID
-- @param filePath string Optional file path (if CommonAPI2 file API available)
-- @return boolean success, string|nil data or error message
function timetable.exportTimetableToFile(lineID, filePath)
    local exportString = timetable.exportTimetable(lineID)
    if not exportString then
        return false, "Failed to export timetable"
    end
    
    -- Try to save to file if CommonAPI2 file API available
    if commonapi2_available and commonapi.file then
        if filePath then
            local success, err = pcall(function()
                if commonapi.file.write then
                    commonapi.file.write(filePath, exportString)
                elseif commonapi.file.save then
                    commonapi.file.save(filePath, exportString)
                else
                    error("File API not available")
                end
            end)
            if success then
                return true, nil
            else
                return false, tostring(err)
            end
        end
    end
    
    -- Return export string if file API not available
    return true, exportString
end

-- Import timetable from file (via CommonAPI2 if available, otherwise from string)
-- @param filePath string File path (if CommonAPI2 file API available)
-- @param importString string Optional import string (if file API not available)
-- @return boolean success, string error message
function timetable.importTimetableFromFile(filePath, importString)
    local data = importString
    
    -- Try to read from file if CommonAPI2 file API available
    if commonapi2_available and commonapi.file and filePath then
        local success, fileData = pcall(function()
            if commonapi.file.read then
                return commonapi.file.read(filePath)
            elseif commonapi.file.load then
                return commonapi.file.load(filePath)
            else
                error("File API not available")
            end
        end)
        if success and fileData then
            data = fileData
        elseif not success then
            return false, tostring(fileData)
        end
    end
    
    if not data then
        return false, "No import data provided"
    end
    
    -- Parse and import the data
    return timetable.importTimetable(data)
end

-- Get timetable library (list of saved timetables)
-- @return table Array of {name, lineID, description, ...}
function timetable.getTimetableLibrary()
    -- This would use CommonAPI2 persistence to store a library of timetables
    if commonapi2_available and commonapi2_persistence_api then
        local success, library = pcall(function()
            if commonapi2_persistence_api.get then
                return commonapi2_persistence_api.get("timetables_library")
            elseif commonapi2_persistence_api.load then
                return commonapi2_persistence_api.load("timetables_library")
            end
            return nil
        end)
        if success and library then
            return library
        end
    end
    
    return {}
end

-- Save timetable to library
-- @param name string Timetable name
-- @param lineID integer The line ID
-- @param description string Optional description
-- @return boolean success, string error message
function timetable.saveTimetableToLibrary(name, lineID, description)
    if not name or name == "" then
        return false, "Timetable name is required"
    end
    
    local exportString = timetable.exportTimetable(lineID)
    if not exportString then
        return false, "Failed to export timetable"
    end
    
    if commonapi2_available and commonapi2_persistence_api then
        local success, library = pcall(function()
            if commonapi2_persistence_api.get then
                return commonapi2_persistence_api.get("timetables_library")
            elseif commonapi2_persistence_api.load then
                return commonapi2_persistence_api.load("timetables_library")
            end
            return {}
        end)
        
        if not success then
            library = {}
        end
        
        if not library or type(library) ~= "table" then
            library = {}
        end
        
        -- Add or update timetable in library
        library[name] = {
            name = name,
            lineID = lineID,
            description = description or "",
            data = exportString,
            saved = timetableHelper.getTime()
        }
        
        local saveSuccess, err = pcall(function()
            if commonapi2_persistence_api.set then
                commonapi2_persistence_api.set("timetables_library", library)
            elseif commonapi2_persistence_api.save then
                commonapi2_persistence_api.save("timetables_library", library)
            elseif commonapi2_persistence_api.write then
                commonapi2_persistence_api.write("timetables_library", library)
            else
                error("Persistence API not available")
            end
        end)
        
        if saveSuccess then
            return true, nil
        else
            return false, tostring(err)
        end
    end
    
    return false, "Persistence not available"
end

-- Load timetable from library
-- @param name string Timetable name
-- @param targetLineID integer Target line ID to import to
-- @return boolean success, string error message
function timetable.loadTimetableFromLibrary(name, targetLineID)
    if not name or name == "" then
        return false, "Timetable name is required"
    end
    
    if commonapi2_available and commonapi2_persistence_api then
        local success, library = pcall(function()
            if commonapi2_persistence_api.get then
                return commonapi2_persistence_api.get("timetables_library")
            elseif commonapi2_persistence_api.load then
                return commonapi2_persistence_api.load("timetables_library")
            end
            return nil
        end)
        
        if success and library and library[name] then
            local timetableData = library[name].data
            if timetableData then
                return timetable.importTimetable(timetableData, targetLineID)
            else
                return false, "Timetable data not found in library"
            end
        else
            return false, "Timetable not found in library"
        end
    end
    
    return false, "Persistence not available"
end

-------------------------------------------------------------
---------------------- Train Assignment ----------------------
-------------------------------------------------------------

-- Assign a specific vehicle to a specific timetable slot
-- @param line integer The line ID
-- @param stop integer The stop index on the line
-- @param vehicle integer The vehicle ID
-- @param slotIndex integer The index of the slot in the slots array
-- @return boolean success, string error message
function timetable.assignTrainToSlot(line, stop, vehicle, slotIndex)
    if not line or not stop or not vehicle or not slotIndex then
        return false, "Invalid parameters"
    end
    
    -- Validate line and stop exist
    if not timetableObject[line] then
        return false, "Line not found"
    end
    if not timetableObject[line].stations then
        timetableObject[line].stations = {}
    end
    if not timetableObject[line].stations[stop] then
        return false, "Stop not found"
    end
    
    -- Get slots for this station
    local currentTime = timetableHelper.getTime()
    local slots = timetable.getActiveSlots(line, stop, currentTime)
    if not slots or #slots == 0 then
        return false, "No slots defined for this station"
    end
    
    -- Validate slot index
    if slotIndex < 1 or slotIndex > #slots then
        return false, "Invalid slot index"
    end
    
    local slot = slots[slotIndex]
    if not slot then
        return false, "Slot not found"
    end
    
    -- Initialize trainAssignments if needed
    if not timetableObject[line].stations[stop].trainAssignments then
        timetableObject[line].stations[stop].trainAssignments = {}
    end
    
    -- Check for conflicts: another vehicle already assigned to this slot
    local conflicts = {}
    for otherVehicle, assignment in pairs(timetableObject[line].stations[stop].trainAssignments) do
        if otherVehicle ~= vehicle and assignment.slotIndex == slotIndex then
            table.insert(conflicts, otherVehicle)
        end
    end
    
    -- Store assignment
    timetableObject[line].stations[stop].trainAssignments[vehicle] = {
        slotIndex = slotIndex,
        slot = slot
    }
    
    -- Clear any conflicts (remove assignments from other vehicles)
    for _, conflictVehicle in ipairs(conflicts) do
        timetableObject[line].stations[stop].trainAssignments[conflictVehicle] = nil
    end
    
    return true, conflicts and #conflicts > 0 and ("Assignment created, " .. #conflicts .. " conflict(s) resolved") or "Assignment created"
end

-- Remove train assignment for a vehicle
-- @param line integer The line ID
-- @param stop integer The stop index on the line
-- @param vehicle integer The vehicle ID
-- @return boolean success
function timetable.removeTrainAssignment(line, stop, vehicle)
    if not line or not stop or not vehicle then
        return false
    end
    
    if not timetableObject[line] or not timetableObject[line].stations or not timetableObject[line].stations[stop] then
        return false
    end
    
    if timetableObject[line].stations[stop].trainAssignments then
        timetableObject[line].stations[stop].trainAssignments[vehicle] = nil
    end
    
    return true
end

-- Get the assigned slot for a vehicle
-- @param line integer The line ID
-- @param stop integer The stop index on the line
-- @param vehicle integer The vehicle ID
-- @return table|nil The assigned slot, or nil if not assigned
function timetable.getAssignedSlot(line, stop, vehicle)
    if not line or not stop or not vehicle then
        return nil
    end
    
    if not timetableObject[line] or not timetableObject[line].stations or not timetableObject[line].stations[stop] then
        return nil
    end
    
    if timetableObject[line].stations[stop].trainAssignments and timetableObject[line].stations[stop].trainAssignments[vehicle] then
        return timetableObject[line].stations[stop].trainAssignments[vehicle].slot
    end
    
    return nil
end

-- Get train assignment information
-- @param line integer The line ID
-- @param stop integer The stop index on the line
-- @param vehicle integer The vehicle ID
-- @return table|nil Assignment info {slotIndex, slot}, or nil if not assigned
function timetable.getTrainAssignment(line, stop, vehicle)
    if not line or not stop or not vehicle then
        return nil
    end
    
    if not timetableObject[line] or not timetableObject[line].stations or not timetableObject[line].stations[stop] then
        return nil
    end
    
    if timetableObject[line].stations[stop].trainAssignments and timetableObject[line].stations[stop].trainAssignments[vehicle] then
        return timetableObject[line].stations[stop].trainAssignments[vehicle]
    end
    
    return nil
end

-- Check if a vehicle is assigned to a slot
-- @param line integer The line ID
-- @param stop integer The stop index on the line
-- @param vehicle integer The vehicle ID
-- @return boolean True if assigned, false otherwise
function timetable.isTrainAssigned(line, stop, vehicle)
    return timetable.getTrainAssignment(line, stop, vehicle) ~= nil
end

-- Validate if a slot is still valid for the current arrival time
-- @param slot table The slot to validate
-- @param arrivalTime integer The current arrival time
-- @param slots table The current slots array (optional, for validation)
-- @param line integer The line ID (optional)
-- @param stop integer The stop index (optional)
-- @return boolean True if slot is valid, false otherwise
function timetable.isValidSlot(slot, arrivalTime, slots, line, stop)
    if not slot then return false end
    
    -- Check if slot still exists in current slots array
    if slots then
        local slotExists = false
        for _, s in ipairs(slots) do
            if timetable.slotsEqual(slot, s) then
                slotExists = true
                break
            end
        end
        if not slotExists then
            return false
        end
    end
    
    -- Basic validation: slot should have valid structure
    if type(slot) ~= "table" or #slot < 4 then
        return false
    end
    
    -- Slot is valid if it exists and has proper structure
    return true
end

-- Clear invalid train assignments for a station
-- @param line integer The line ID
-- @param stop integer The stop index on the line
function timetable.clearInvalidAssignments(line, stop)
    if not line or not stop then return end
    
    if not timetableObject[line] or not timetableObject[line].stations or not timetableObject[line].stations[stop] then
        return
    end
    
    if not timetableObject[line].stations[stop].trainAssignments then
        return
    end
    
    local currentTime = timetableHelper.getTime()
    local slots = timetable.getActiveSlots(line, stop, currentTime)
    
    -- Remove assignments for slots that no longer exist
    local assignments = timetableObject[line].stations[stop].trainAssignments
    for vehicle, assignment in pairs(assignments) do
        if not timetable.isValidSlot(assignment.slot, currentTime, slots, line, stop) then
            assignments[vehicle] = nil
        end
    end
end

-- Get list of vehicles that can be assigned (vehicles on the line)
-- @param line integer The line ID
-- @param stop integer The stop index on the line (optional)
-- @return table Array of vehicle IDs
function timetable.getAssignableTrains(line, stop)
    if not line then return {} end
    
    local vehicles = {}
    local currentTime = timetableHelper.getTime()
    local lineVehicles = timetableHelper.getLineVehicles(line, currentTime)
    
    for _, vehicle in pairs(lineVehicles) do
        table.insert(vehicles, vehicle)
    end
    
    return vehicles
end

-- Get station slots information
-- @param line integer The line ID
-- @param stop integer The stop index on the line
-- @return table Array of slots with their indices
function timetable.getStationSlots(line, stop)
    if not line or not stop then return {} end
    
    local currentTime = timetableHelper.getTime()
    local slots = timetable.getActiveSlots(line, stop, currentTime)
    if not slots then return {} end
    
    local result = {}
    for i, slot in ipairs(slots) do
        table.insert(result, {
            index = i,
            slot = slot,
            arrivalSlot = timetable.slotToArrivalSlot(slot),
            departureSlot = timetable.slotToDepartureSlot(slot)
        })
    end
    
    return result
end

-- removes old lines from timetable
-- Optimized cleanTimetable that only processes changed lines
function timetable.cleanTimetable(currentTime)
    local delayTracker = require "celmi/timetables/delay_tracker"
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Clean caches periodically
    timetableHelper.cleanCaches(currentTime)
    
    for lineID, _ in pairs(timetableObject) do
        if not timetableHelper.lineExists(lineID, currentTime) then
            timetableObject[lineID] = nil
            -- Clean up sorted slots cache for removed line
            sortedSlotsCache[lineID] = nil
            slotHashSetCache[lineID] = nil
            print("removed line " .. lineID)
        else
            local stations = timetableHelper.getAllStations(lineID) -- Uses cached component access internally
            -- Clean up sorted slots cache for removed stations
            if sortedSlotsCache[lineID] then
                for stationID = #stations + 1, 1000 do
                    if sortedSlotsCache[lineID][stationID] then
                        sortedSlotsCache[lineID][stationID] = nil
                    end
                end
            end
            if slotHashSetCache[lineID] then
                for stationID = #stations + 1, 1000 do
                    if slotHashSetCache[lineID][stationID] then
                        slotHashSetCache[lineID][stationID] = nil
                    end
                end
            end
            for stationID = #stations + 1, #timetableObject[lineID].stations, 1 do
                timetableObject[lineID].stations[stationID] = nil
                print("removed station " .. stationID)
            end
            
            -- Clean up stale vehicle entries from vehiclesWaiting tables
            local currentVehicles = {}
            local lineVehicles = timetableHelper.getVehiclesOnLine(lineID, currentTime)
            for _, vehicle in pairs(lineVehicles) do
                currentVehicles[vehicle] = true
            end
            
            -- Remove vehiclesWaiting entries for vehicles that no longer exist
            if timetableObject[lineID] and timetableObject[lineID].stations then
                for stationNumber, stationInfo in pairs(timetableObject[lineID].stations) do
                    if stationInfo.vehiclesWaiting then
                        for vehicle, _ in pairs(stationInfo.vehiclesWaiting) do
                            if not currentVehicles[vehicle] then
                                stationInfo.vehiclesWaiting[vehicle] = nil
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Clean up delay tracker cache periodically
    delayTracker.cleanup(currentTime)
    
    -- Invalidate station lines map cache when cleaning timetable (lines/stations may have changed)
    timetable.invalidateStationLinesMapCache()
end

-- CommonAPI2 persistence functions for timetable data
-- Save timetable data to CommonAPI2 persistence
function timetable.saveToPersistence()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, err = pcall(function()
        -- Prepare timetable data with version info
        local dataToSave = {
            version = TIMETABLE_DATA_VERSION,
            timetableData = timetableObject,
            timestamp = timetableHelper.getTime()
        }
        
        -- Try different possible API methods
        if commonapi2_persistence_api.set then
            commonapi2_persistence_api.set("timetables_data", dataToSave)
        elseif commonapi2_persistence_api.save then
            commonapi2_persistence_api.save("timetables_data", dataToSave)
        elseif commonapi2_persistence_api.write then
            commonapi2_persistence_api.write("timetables_data", dataToSave)
        elseif commonapi2_persistence_api.store then
            commonapi2_persistence_api.store("timetables_data", dataToSave)
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

-- Load timetable data from CommonAPI2 persistence
function timetable.loadFromPersistence()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, loadedData = pcall(function()
        -- Try different possible API methods
        if commonapi2_persistence_api.get then
            return commonapi2_persistence_api.get("timetables_data")
        elseif commonapi2_persistence_api.load then
            return commonapi2_persistence_api.load("timetables_data")
        elseif commonapi2_persistence_api.read then
            return commonapi2_persistence_api.read("timetables_data")
        elseif commonapi2_persistence_api.retrieve then
            return commonapi2_persistence_api.retrieve("timetables_data")
        end
        return nil
    end)
    
    if success and loadedData and type(loadedData) == "table" then
        -- Handle versioned data structure
        local timetableData = loadedData
        if loadedData.timetableData and loadedData.version then
            -- New versioned format
            timetableData = loadedData.timetableData
            -- Handle migration if version differs
            if loadedData.version < TIMETABLE_DATA_VERSION then
                -- Future: implement migration logic here
                print("Timetables: Migrating timetable data from version " .. loadedData.version .. " to " .. TIMETABLE_DATA_VERSION)
            end
        end
        
        -- Set the loaded timetable data
        timetable.setTimetableObject(timetableData)
        return true, nil
    else
        return false, success and "No saved timetable data found" or tostring(loadedData)
    end
end

-- Re-check CommonAPI2 persistence API at runtime
function timetable.recheckPersistenceAPI()
    if commonapi ~= nil and type(commonapi) == "table" then
        if not commonapi2_available then
            commonapi2_available = true
        end
        if not commonapi2_persistence_api then
            if commonapi.persistence then
                commonapi2_persistence_api = commonapi.persistence
            elseif commonapi.data then
                commonapi2_persistence_api = commonapi.data
            elseif commonapi.storage then
                commonapi2_persistence_api = commonapi.storage
            elseif commonapi.settings then
                commonapi2_persistence_api = commonapi.settings
            end
            if commonapi2_persistence_api then
                print("Timetables: Re-initialized timetable persistence API at runtime")
            end
        end
        return commonapi2_available and commonapi2_persistence_api ~= nil
    end
    return false
end

-- Check if timetable persistence is available
function timetable.isPersistenceAvailable()
    -- Try to re-check if not already available (for runtime initialization)
    if not commonapi2_available or not commonapi2_persistence_api then
        timetable.recheckPersistenceAPI()
    end
    return commonapi2_available and commonapi2_persistence_api ~= nil
end

-- Auto-save timetable data (call periodically from update loop)
local lastAutoSaveTime = 0
local AUTO_SAVE_INTERVAL = 30 -- Save every 30 seconds

function timetable.autoSaveIfNeeded(currentTime)
    if not timetable.isPersistenceAvailable() then
        return false
    end
    
    currentTime = currentTime or timetableHelper.getTime()
    
    -- Only auto-save periodically
    if currentTime - lastAutoSaveTime >= AUTO_SAVE_INTERVAL then
        local success, err = timetable.saveToPersistence()
        if success then
            lastAutoSaveTime = currentTime
            return true
        else
            print("Timetables: Auto-save failed: " .. tostring(err))
            return false
        end
    end
    
    return false
end

-- Register with persistence manager on module load
pcall(function()
    if persistenceManager and persistenceManager.isAvailable() then
        persistenceManager.registerModule("timetable", 
            function()
                return timetable.getTimetableObject(true)
            end,
            function(data)
                if data and data.timetableData then
                    timetable.setTimetableObject(data.timetableData)
                    return true
                elseif data then
                    timetable.setTimetableObject(data)
                    return true
                end
                return false
            end,
            TIMETABLE_DATA_VERSION
        )
    end
end)

return timetable

