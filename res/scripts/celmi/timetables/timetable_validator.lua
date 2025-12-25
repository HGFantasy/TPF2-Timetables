-- Timetable Validator Module
-- Detects timetable conflicts, overlaps, and impossible schedules

local timetableValidator = {}
local timetableHelper = require "celmi/timetables/timetable_helper"

-- Validation result structure
-- {
--     valid = boolean,
--     warnings = {warning1, warning2, ...},
--     errors = {error1, error2, ...},
--     conflicts = {conflict1, conflict2, ...}
-- }

-- Validate a single line's timetable
function timetableValidator.validateLine(line, timetableObject)
    local timetable = require "celmi/timetables/timetable"
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    if not timetableObject[line] or not timetableObject[line].stations then
        return result
    end
    
    local lineInfo = timetableObject[line]
    local stations = lineInfo.stations
    
    -- Get all stations on the line
    local stationNumbers = {}
    for stop, _ in pairs(stations) do
        table.insert(stationNumbers, stop)
    end
    table.sort(stationNumbers)
    
    -- Validate each station
    for _, stop in ipairs(stationNumbers) do
        local stationResult = timetableValidator.validateStation(line, stop, timetableObject)
        
        if not stationResult.valid then
            result.valid = false
        end
        
        for _, warning in ipairs(stationResult.warnings) do
            table.insert(result.warnings, "Station " .. stop .. ": " .. warning)
        end
        
        for _, error in ipairs(stationResult.errors) do
            table.insert(result.errors, "Station " .. stop .. ": " .. error)
        end
        
        for _, conflict in ipairs(stationResult.conflicts) do
            table.insert(result.conflicts, {
                line = line,
                station = stop,
                conflict = conflict
            })
        end
    end
    
    -- Validate travel times between stations
    if #stationNumbers > 1 then
        local travelTimeResult = timetableValidator.validateTravelTimes(line, stationNumbers, timetableObject)
        if not travelTimeResult.valid then
            result.valid = false
        end
        for _, warning in ipairs(travelTimeResult.warnings) do
            table.insert(result.warnings, warning)
        end
        for _, error in ipairs(travelTimeResult.errors) do
            table.insert(result.errors, error)
        end
    end
    
    return result
end

-- Validate a single station's timetable
function timetableValidator.validateStation(line, stop, timetableObject)
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    if not timetableObject[line] or not timetableObject[line].stations or not timetableObject[line].stations[stop] then
        return result
    end
    
    local stationInfo = timetableObject[line].stations[stop]
    local conditions = stationInfo.conditions
    
    if not conditions or not conditions.type then
        return result
    end
    
    -- Validate ArrDep slots
    if conditions.type == "ArrDep" and conditions.ArrDep then
        local slotResult = timetableValidator.validateArrDepSlots(conditions.ArrDep, line, stop, stationInfo)
        if not slotResult.valid then
            result.valid = false
        end
        for _, warning in ipairs(slotResult.warnings) do
            table.insert(result.warnings, warning)
        end
        for _, error in ipairs(slotResult.errors) do
            table.insert(result.errors, error)
        end
        for _, conflict in ipairs(slotResult.conflicts) do
            table.insert(result.conflicts, conflict)
        end
    end
    
    -- Validate platform assignments
    if stationInfo.platformAssignments then
        local platformResult = timetableValidator.validatePlatformAssignments(stationInfo.platformAssignments)
        if not platformResult.valid then
            result.valid = false
        end
        for _, warning in ipairs(platformResult.warnings) do
            table.insert(result.warnings, warning)
        end
        for _, error in ipairs(platformResult.errors) do
            table.insert(result.errors, error)
        end
    end
    
    -- Validate train assignments
    if stationInfo.trainAssignments then
        local assignmentResult = timetableValidator.validateTrainAssignments(stationInfo.trainAssignments, conditions.ArrDep)
        if not assignmentResult.valid then
            result.valid = false
        end
        for _, warning in ipairs(assignmentResult.warnings) do
            table.insert(result.warnings, warning)
        end
        for _, error in ipairs(assignmentResult.errors) do
            table.insert(result.errors, error)
        end
    end
    
    return result
end

-- Validate ArrDep slots for conflicts and overlaps
function timetableValidator.validateArrDepSlots(slots, line, stop, stationInfo)
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    if not slots or #slots == 0 then
        return result
    end
    
    -- Check for duplicate slots
    local slotMap = {}
    for i, slot in ipairs(slots) do
        if type(slot) == "table" and #slot >= 4 then
            local slotKey = tostring(slot[1]) .. "_" .. tostring(slot[2]) .. "_" .. tostring(slot[3]) .. "_" .. tostring(slot[4])
            if slotMap[slotKey] then
                table.insert(result.warnings, "Duplicate slot at index " .. i .. " and " .. slotMap[slotKey])
                result.valid = false
            else
                slotMap[slotKey] = i
            end
            
            -- Validate slot structure
            if slot[1] < 0 or slot[1] >= 60 or slot[2] < 0 or slot[2] >= 60 or
               slot[3] < 0 or slot[3] >= 60 or slot[4] < 0 or slot[4] >= 60 then
                table.insert(result.errors, "Invalid slot at index " .. i .. ": values out of range")
                result.valid = false
            end
            
            -- Check if departure is after arrival
            local arrivalSeconds = slot[1] * 60 + slot[2]
            local departureSeconds = slot[3] * 60 + slot[4]
            if departureSeconds <= arrivalSeconds then
                table.insert(result.warnings, "Slot at index " .. i .. ": departure time is not after arrival time")
            end
        else
            table.insert(result.errors, "Invalid slot structure at index " .. i)
            result.valid = false
        end
    end
    
    -- Check for overlapping slots (same arrival/departure times)
    for i = 1, #slots - 1 do
        for j = i + 1, #slots do
            local slot1 = slots[i]
            local slot2 = slots[j]
            if type(slot1) == "table" and type(slot2) == "table" and #slot1 >= 4 and #slot2 >= 4 then
                local arr1 = slot1[1] * 60 + slot1[2]
                local dep1 = slot1[3] * 60 + slot1[4]
                local arr2 = slot2[1] * 60 + slot2[2]
                local dep2 = slot2[3] * 60 + slot2[4]
                
                -- Check for overlap
                if (arr1 <= arr2 and arr2 < dep1) or (arr2 <= arr1 and arr1 < dep2) then
                    table.insert(result.conflicts, {
                        type = "overlap",
                        slot1 = i,
                        slot2 = j,
                        message = "Slots " .. i .. " and " .. j .. " overlap in time"
                    })
                    result.valid = false
                end
            end
        end
    end
    
    return result
end

-- Validate platform assignments for conflicts
function timetableValidator.validatePlatformAssignments(platformAssignments)
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    if not platformAssignments then
        return result
    end
    
    -- Check for multiple vehicles assigned to same platform
    local platformMap = {}
    for vehicle, platform in pairs(platformAssignments) do
        if platformMap[platform] then
            table.insert(result.conflicts, {
                type = "platform_conflict",
                platform = platform,
                vehicle1 = platformMap[platform],
                vehicle2 = vehicle,
                message = "Vehicles " .. tostring(platformMap[platform]) .. " and " .. tostring(vehicle) .. " both assigned to platform " .. platform
            })
            result.valid = false
        else
            platformMap[platform] = vehicle
        end
    end
    
    return result
end

-- Validate train assignments
function timetableValidator.validateTrainAssignments(trainAssignments, slots)
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    if not trainAssignments then
        return result
    end
    
    if not slots or #slots == 0 then
        table.insert(result.warnings, "Train assignments exist but no slots defined")
        return result
    end
    
    -- Check for multiple vehicles assigned to same slot
    local slotMap = {}
    for vehicle, assignment in pairs(trainAssignments) do
        if assignment.slotIndex then
            if slotMap[assignment.slotIndex] then
                table.insert(result.conflicts, {
                    type = "slot_conflict",
                    slotIndex = assignment.slotIndex,
                    vehicle1 = slotMap[assignment.slotIndex],
                    vehicle2 = vehicle,
                    message = "Vehicles " .. tostring(slotMap[assignment.slotIndex]) .. " and " .. tostring(vehicle) .. " both assigned to slot " .. assignment.slotIndex
                })
                result.valid = false
            else
                slotMap[assignment.slotIndex] = vehicle
            end
            
            -- Validate slot index is within range
            if assignment.slotIndex < 1 or assignment.slotIndex > #slots then
                table.insert(result.errors, "Vehicle " .. tostring(vehicle) .. " assigned to invalid slot index " .. assignment.slotIndex)
                result.valid = false
            end
        end
    end
    
    return result
end

-- Validate travel times between stations
function timetableValidator.validateTravelTimes(line, stationNumbers, timetableObject)
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    if #stationNumbers < 2 then
        return result
    end
    
    -- Get minimum travel time between stations (would need API access)
    -- For now, just check if slots are ordered correctly
    local lineInfo = timetableObject[line]
    
    for i = 1, #stationNumbers - 1 do
        local stop1 = stationNumbers[i]
        local stop2 = stationNumbers[i + 1]
        
        local station1 = lineInfo.stations[stop1]
        local station2 = lineInfo.stations[stop2]
        
        if station1 and station2 and station1.conditions and station1.conditions.type == "ArrDep" and
           station2.conditions and station2.conditions.type == "ArrDep" then
            local slots1 = station1.conditions.ArrDep
            local slots2 = station2.conditions.ArrDep
            
            if slots1 and #slots1 > 0 and slots2 and #slots2 > 0 then
                -- Check if departure from station1 is before arrival at station2
                -- This is a simplified check - actual travel time would need distance/API
                for _, slot1 in ipairs(slots1) do
                    local dep1 = slot1[3] * 60 + slot1[4]
                    for _, slot2 in ipairs(slots2) do
                        local arr2 = slot2[1] * 60 + slot2[2]
                        -- Allow some buffer (at least 30 seconds travel time)
                        if dep1 >= arr2 - 30 then
                            table.insert(result.warnings, "Possible impossible travel time: Station " .. stop1 .. " departure " .. 
                                string.format("%02d:%02d", math.floor(dep1/60), dep1%60) .. 
                                " to Station " .. stop2 .. " arrival " .. 
                                string.format("%02d:%02d", math.floor(arr2/60), arr2%60))
                        end
                    end
                end
            end
        end
    end
    
    return result
end

-- Validate entire timetable
function timetableValidator.validateAll(timetableObject)
    local result = {
        valid = true,
        warnings = {},
        errors = {},
        conflicts = {}
    }
    
    for line, _ in pairs(timetableObject) do
        local lineResult = timetableValidator.validateLine(line, timetableObject)
        if not lineResult.valid then
            result.valid = false
        end
        
        for _, warning in ipairs(lineResult.warnings) do
            table.insert(result.warnings, "Line " .. tostring(line) .. ": " .. warning)
        end
        
        for _, error in ipairs(lineResult.errors) do
            table.insert(result.errors, "Line " .. tostring(line) .. ": " .. error)
        end
        
        for _, conflict in ipairs(lineResult.conflicts) do
            table.insert(result.conflicts, conflict)
        end
    end
    
    return result
end

-- Quick validation check (returns boolean)
function timetableValidator.isValid(timetableObject)
    local result = timetableValidator.validateAll(timetableObject)
    return result.valid
end

return timetableValidator
