-- Timetable Scheduler Module
-- Handles seasonal/event-based timetable variations

local timetableScheduler = {}
local timetableHelper = require "celmi/timetables/timetable_helper"
local persistenceManager = require "celmi/timetables/persistence_manager"

-- CommonAPI2 persistence for scheduler data
local commonapi2_available = false
local commonapi2_persistence_api = nil
local SCHEDULER_DATA_VERSION = 1

-- Check for CommonAPI2 and persistence API
if commonapi ~= nil and type(commonapi) == "table" then
    commonapi2_available = true
    if commonapi.persistence then
        commonapi2_persistence_api = commonapi.persistence
    elseif commonapi.data then
        commonapi2_persistence_api = commonapi.data
    elseif commonapi.storage then
        commonapi2_persistence_api = commonapi.storage
    elseif commonapi.settings then
        commonapi2_persistence_api = commonapi.settings
    end
end

-- Scheduler data structure
-- {
--     schedules = {
--         [lineID] = {
--             [stationNumber] = {
--                 schedules = {
--                     {
--                         name = "Peak Hours",
--                         type = "time_based" | "day_based" | "seasonal" | "event",
--                         enabled = true,
--                         conditions = {
--                             startTime = {hour = 7, minute = 0},
--                             endTime = {hour = 9, minute = 0},
--                             daysOfWeek = {1, 2, 3, 4, 5}, -- Monday-Friday
--                             season = "summer" | "winter" | "spring" | "autumn",
--                             eventName = "Special Event"
--                         },
--                         timetable = {conditions = {...}}
--                     }
--                 },
--                 activeSchedule = nil -- Currently active schedule name
--             }
--         }
--     }
-- }
local schedulerData = {
    schedules = {}
}

-- Create a scheduled timetable variation
-- @param line integer The line ID
-- @param station integer The station number
-- @param scheduleName string Name of the schedule
-- @param scheduleType string Type: "time_based", "day_based", "seasonal", "event"
-- @param conditions table Schedule conditions
-- @param timetableData table Timetable data for this schedule
-- @return boolean success, string message
function timetableScheduler.createSchedule(line, station, scheduleName, scheduleType, conditions, timetableData)
    if not line or not station or not scheduleName or not scheduleType then
        return false, "Invalid parameters"
    end
    
    if not schedulerData.schedules[line] then
        schedulerData.schedules[line] = {}
    end
    if not schedulerData.schedules[line][station] then
        schedulerData.schedules[line][station] = {
            schedules = {},
            activeSchedule = nil
        }
    end
    
    local stationSchedules = schedulerData.schedules[line][station]
    
    -- Check if schedule already exists
    for _, schedule in ipairs(stationSchedules.schedules) do
        if schedule.name == scheduleName then
            return false, "Schedule with this name already exists"
        end
    end
    
    -- Add schedule
    table.insert(stationSchedules.schedules, {
        name = scheduleName,
        type = scheduleType,
        enabled = true,
        conditions = conditions or {},
        timetable = timetableData or {}
    })
    
    timetableScheduler.saveSchedulerData()
    return true, "Schedule created"
end

-- Delete a scheduled timetable variation
-- @param line integer The line ID
-- @param station integer The station number
-- @param scheduleName string Name of the schedule
-- @return boolean success
function timetableScheduler.deleteSchedule(line, station, scheduleName)
    if not schedulerData.schedules[line] or not schedulerData.schedules[line][station] then
        return false
    end
    
    local stationSchedules = schedulerData.schedules[line][station]
    for i, schedule in ipairs(stationSchedules.schedules) do
        if schedule.name == scheduleName then
            table.remove(stationSchedules.schedules, i)
            if stationSchedules.activeSchedule == scheduleName then
                stationSchedules.activeSchedule = nil
            end
            timetableScheduler.saveSchedulerData()
            return true
        end
    end
    
    return false
end

-- Get all schedules for a line/station
-- @param line integer The line ID
-- @param station integer The station number
-- @return table Array of schedules
function timetableScheduler.getSchedules(line, station)
    if not schedulerData.schedules[line] or not schedulerData.schedules[line][station] then
        return {}
    end
    
    return schedulerData.schedules[line][station].schedules
end

-- Check if a schedule should be active based on current conditions
-- @param schedule table The schedule to check
-- @param currentTime integer Current game time
-- @return boolean True if schedule should be active
function timetableScheduler.shouldScheduleBeActive(schedule, currentTime)
    if not schedule or not schedule.enabled then
        return false
    end
    
    local conditions = schedule.conditions
    if not conditions then
        return false
    end
    
    -- Get current time components
    local timeOfDay = currentTime % 86400
    local dayOfWeek = math.floor(currentTime / 86400) % 7 -- 0 = Sunday, 1 = Monday, etc.
    
    -- Time-based check
    if schedule.type == "time_based" then
        if conditions.startTime and conditions.endTime then
            local startSeconds = conditions.startTime.hour * 3600 + conditions.startTime.minute * 60
            local endSeconds = conditions.endTime.hour * 3600 + conditions.endTime.minute * 60
            
            if startSeconds <= endSeconds then
                -- Same day range
                return timeOfDay >= startSeconds and timeOfDay <= endSeconds
            else
                -- Overnight range
                return timeOfDay >= startSeconds or timeOfDay <= endSeconds
            end
        end
    end
    
    -- Day-based check
    if schedule.type == "day_based" then
        if conditions.daysOfWeek then
            for _, day in ipairs(conditions.daysOfWeek) do
                if day == dayOfWeek then
                    return true
                end
            end
        end
    end
    
    -- Combined time and day check
    if schedule.type == "time_based" or schedule.type == "day_based" then
        local timeMatch = true
        local dayMatch = true
        
        if conditions.startTime and conditions.endTime then
            local startSeconds = conditions.startTime.hour * 3600 + conditions.startTime.minute * 60
            local endSeconds = conditions.endTime.hour * 3600 + conditions.endTime.minute * 60
            
            if startSeconds <= endSeconds then
                timeMatch = timeOfDay >= startSeconds and timeOfDay <= endSeconds
            else
                timeMatch = timeOfDay >= startSeconds or timeOfDay <= endSeconds
            end
        end
        
        if conditions.daysOfWeek then
            dayMatch = false
            for _, day in ipairs(conditions.daysOfWeek) do
                if day == dayOfWeek then
                    dayMatch = true
                    break
                end
            end
        end
        
        return timeMatch and dayMatch
    end
    
    -- Seasonal check (would need game API for season)
    if schedule.type == "seasonal" then
        -- Placeholder - would need season API
        return false
    end
    
    -- Event-based check (manual activation)
    if schedule.type == "event" then
        -- Events are manually activated
        return false
    end
    
    return false
end

-- Update active schedules based on current conditions
-- @param currentTime integer Current game time
function timetableScheduler.updateActiveSchedules(currentTime)
    currentTime = currentTime or timetableHelper.getTime()
    local timetable = require "celmi/timetables/timetable"
    
    for line, lineSchedules in pairs(schedulerData.schedules) do
        for station, stationSchedules in pairs(lineSchedules) do
            local activeSchedule = nil
            
            -- Find the first matching schedule
            for _, schedule in ipairs(stationSchedules.schedules) do
                if timetableScheduler.shouldScheduleBeActive(schedule, currentTime) then
                    activeSchedule = schedule.name
                    break
                end
            end
            
            -- Apply schedule if changed
            if activeSchedule ~= stationSchedules.activeSchedule then
                stationSchedules.activeSchedule = activeSchedule
                
                if activeSchedule then
                    -- Find and apply the schedule
                    for _, schedule in ipairs(stationSchedules.schedules) do
                        if schedule.name == activeSchedule and schedule.timetable then
                            -- Apply timetable from schedule
                            if schedule.timetable.conditions then
                                timetable.setConditionType(line, station, schedule.timetable.conditions.type or "ArrDep")
                                if schedule.timetable.conditions.ArrDep then
                                    for _, slot in ipairs(schedule.timetable.conditions.ArrDep) do
                                        timetable.addCondition(line, station, {type = "ArrDep", ArrDep = slot})
                                    end
                                end
                            end
                            break
                        end
                    end
                end
            end
        end
    end
end

-- Manually activate an event-based schedule
-- @param line integer The line ID
-- @param station integer The station number
-- @param scheduleName string Name of the event schedule
-- @return boolean success
function timetableScheduler.activateEventSchedule(line, station, scheduleName)
    if not schedulerData.schedules[line] or not schedulerData.schedules[line][station] then
        return false
    end
    
    local stationSchedules = schedulerData.schedules[line][station]
    for _, schedule in ipairs(stationSchedules.schedules) do
        if schedule.name == scheduleName and schedule.type == "event" then
            stationSchedules.activeSchedule = scheduleName
            
            -- Apply timetable
            local timetable = require "celmi/timetables/timetable"
            if schedule.timetable and schedule.timetable.conditions then
                timetable.setConditionType(line, station, schedule.timetable.conditions.type or "ArrDep")
                if schedule.timetable.conditions.ArrDep then
                    for _, slot in ipairs(schedule.timetable.conditions.ArrDep) do
                        timetable.addCondition(line, station, {type = "ArrDep", ArrDep = slot})
                    end
                end
            end
            
            timetableScheduler.saveSchedulerData()
            return true
        end
    end
    
    return false
end

-- Save scheduler data to persistence
function timetableScheduler.saveSchedulerData()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, err = pcall(function()
        local dataToSave = {
            version = SCHEDULER_DATA_VERSION,
            schedules = schedulerData.schedules
        }
        
        if commonapi2_persistence_api.set then
            commonapi2_persistence_api.set("timetables_scheduler", dataToSave)
        elseif commonapi2_persistence_api.save then
            commonapi2_persistence_api.save("timetables_scheduler", dataToSave)
        elseif commonapi2_persistence_api.write then
            commonapi2_persistence_api.write("timetables_scheduler", dataToSave)
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

-- Load scheduler data from persistence
function timetableScheduler.loadSchedulerData()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, loadedData = pcall(function()
        if commonapi2_persistence_api.get then
            return commonapi2_persistence_api.get("timetables_scheduler")
        elseif commonapi2_persistence_api.load then
            return commonapi2_persistence_api.load("timetables_scheduler")
        elseif commonapi2_persistence_api.read then
            return commonapi2_persistence_api.read("timetables_scheduler")
        end
        return nil
    end)
    
    if success and loadedData and type(loadedData) == "table" then
        if loadedData.schedules then
            schedulerData.schedules = loadedData.schedules
            return true, nil
        end
    end
    
    return false, "No saved scheduler data found"
end

-- Check if persistence is available
function timetableScheduler.isPersistenceAvailable()
    return commonapi2_available and commonapi2_persistence_api ~= nil
end

-- Register with persistence manager
pcall(function()
    if persistenceManager and persistenceManager.isAvailable() then
        persistenceManager.registerModule("timetable_scheduler",
            function()
                return {
                    version = SCHEDULER_DATA_VERSION,
                    schedules = schedulerData.schedules
                }
            end,
            function(data)
                if data and data.schedules then
                    schedulerData.schedules = data.schedules
                    return true
                end
                return false
            end,
            SCHEDULER_DATA_VERSION
        )
    end
end)

-- Load scheduler data on module initialization
pcall(function()
    timetableScheduler.loadSchedulerData()
end)

return timetableScheduler
