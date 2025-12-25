-- Timetable Visualizer Module
-- Provides data for visualizing timetables, vehicle positions, and conflicts

local timetableVisualizer = {}
local timetableHelper = require "celmi/timetables/timetable_helper"

-- Get timeline data for a line (vehicle positions over time)
-- @param line integer The line ID
-- @param timeWindow integer Time window in seconds (default: 3600 = 1 hour)
-- @return table Timeline data {vehicles = {{vehicle, station, time, status}, ...}, conflicts = {...}}
function timetableVisualizer.getTimelineData(line, timeWindow)
    timeWindow = timeWindow or 3600
    local currentTime = timetableHelper.getTime()
    local startTime = currentTime - timeWindow
    
    local timetable = require "celmi/timetables/timetable"
    local timetableObject = timetable.getTimetableObject()
    
    local timeline = {
        vehicles = {},
        conflicts = {},
        stations = {}
    }
    
    if not timetableObject[line] then
        return timeline
    end
    
    -- Get all stations on line
    local stations = timetableHelper.getAllStations(line)
    local stationNumbers = {}
    for stop, _ in pairs(stations) do
        table.insert(stationNumbers, stop)
    end
    table.sort(stationNumbers)
    timeline.stations = stationNumbers
    
    -- Get vehicles on line
    local vehicles = timetableHelper.getLineVehicles(line, currentTime)
    
    -- For each vehicle, get its schedule
    for _, vehicle in pairs(vehicles) do
        local vehicleTimeline = {}
        
        -- Get vehicle's timetable assignments
        for _, stop in ipairs(stationNumbers) do
            local assignment = timetable.getTrainAssignment(line, stop, vehicle)
            if assignment and assignment.slot then
                local arrivalSlot = timetable.slotToArrivalSlot(assignment.slot)
                local departureSlot = timetable.slotToDepartureSlot(assignment.slot)
                
                table.insert(vehicleTimeline, {
                    vehicle = vehicle,
                    station = stop,
                    arrivalTime = arrivalSlot,
                    departureTime = departureSlot,
                    status = "scheduled"
                })
            end
        end
        
        if #vehicleTimeline > 0 then
            table.insert(timeline.vehicles, vehicleTimeline)
        end
    end
    
    -- Detect conflicts (overlapping schedules)
    for i = 1, #timeline.vehicles - 1 do
        for j = i + 1, #timeline.vehicles do
            local v1 = timeline.vehicles[i]
            local v2 = timeline.vehicles[j]
            
            for _, event1 in ipairs(v1) do
                for _, event2 in ipairs(v2) do
                    if event1.station == event2.station then
                        -- Check for time overlap
                        if (event1.arrivalTime <= event2.departureTime and event2.arrivalTime <= event1.departureTime) then
                            table.insert(timeline.conflicts, {
                                type = "schedule_conflict",
                                station = event1.station,
                                vehicle1 = event1.vehicle,
                                vehicle2 = event2.vehicle,
                                time1 = {event1.arrivalTime, event1.departureTime},
                                time2 = {event2.arrivalTime, event2.departureTime}
                            })
                        end
                    end
                end
            end
        end
    end
    
    return timeline
end

-- Get station occupancy graph data
-- @param line integer The line ID
-- @param station integer The station number
-- @param timeWindow integer Time window in seconds
-- @return table Occupancy data {timeSlots = {{time, vehicleCount}, ...}, maxOccupancy = number}
function timetableVisualizer.getStationOccupancyGraph(line, station, timeWindow)
    timeWindow = timeWindow or 3600
    local currentTime = timetableHelper.getTime()
    local startTime = currentTime - timeWindow
    
    local timetable = require "celmi/timetables/timetable"
    local timetableObject = timetable.getTimetableObject()
    
    local occupancy = {
        timeSlots = {},
        maxOccupancy = 0
    }
    
    if not timetableObject[line] or not timetableObject[line].stations or not timetableObject[line].stations[station] then
        return occupancy
    end
    
    -- Get slots for this station
    local slots = timetable.getActiveSlots(line, station, currentTime)
    if not slots then
        return occupancy
    end
    
    -- Count vehicles per time slot
    local slotOccupancy = {}
    for i, slot in ipairs(slots) do
        local arrivalSlot = timetable.slotToArrivalSlot(slot)
        local departureSlot = timetable.slotToDepartureSlot(slot)
        
        -- Count how many vehicles are assigned to this slot
        local vehicleCount = 0
        local stationInfo = timetableObject[line].stations[station]
        if stationInfo.trainAssignments then
            for _, assignment in pairs(stationInfo.trainAssignments) do
                if assignment.slotIndex == i then
                    vehicleCount = vehicleCount + 1
                end
            end
        end
        
        -- Also check vehiclesWaiting
        if stationInfo.vehiclesWaiting then
            for _, waitingInfo in pairs(stationInfo.vehiclesWaiting) do
                if waitingInfo.slot and timetable.slotsEqual(slot, waitingInfo.slot) then
                    vehicleCount = vehicleCount + 1
                end
            end
        end
        
        table.insert(occupancy.timeSlots, {
            time = arrivalSlot,
            vehicleCount = vehicleCount,
            slotIndex = i
        })
        
        if vehicleCount > occupancy.maxOccupancy then
            occupancy.maxOccupancy = vehicleCount
        end
    end
    
    -- Sort by time
    table.sort(occupancy.timeSlots, function(a, b) return a.time < b.time end)
    
    return occupancy
end

-- Get conflict visualization data
-- @param line integer The line ID (optional, nil for all lines)
-- @return table Conflict data
function timetableVisualizer.getConflictVisualization(line)
    local timetable = require "celmi/timetables/timetable"
    local timetableValidator = require "celmi/timetables/timetable_validator"
    local timetableObject = timetable.getTimetableObject()
    
    local conflicts = {
        slotConflicts = {},
        platformConflicts = {},
        scheduleConflicts = {}
    }
    
    local linesToCheck = {}
    if line then
        table.insert(linesToCheck, line)
    else
        for l, _ in pairs(timetableObject) do
            table.insert(linesToCheck, l)
        end
    end
    
    for _, l in ipairs(linesToCheck) do
        local validationResult = timetableValidator.validateLine(l, timetableObject)
        
        for _, conflict in ipairs(validationResult.conflicts) do
            if conflict.type == "overlap" or conflict.type == "slot_conflict" then
                table.insert(conflicts.slotConflicts, {
                    line = l,
                    conflict = conflict
                })
            elseif conflict.type == "platform_conflict" then
                table.insert(conflicts.platformConflicts, {
                    line = l,
                    conflict = conflict
                })
            end
        end
    end
    
    return conflicts
end

-- Export timeline data as text (for debugging/display)
-- @param line integer The line ID
-- @return string Formatted timeline text
function timetableVisualizer.exportTimelineAsText(line)
    local timeline = timetableVisualizer.getTimelineData(line)
    local result = {}
    
    table.insert(result, "Timeline for Line " .. tostring(line) .. "\n")
    table.insert(result, "=" .. string.rep("=", 50) .. "\n\n")
    
    for _, vehicleTimeline in ipairs(timeline.vehicles) do
        if #vehicleTimeline > 0 then
            table.insert(result, "Vehicle " .. tostring(vehicleTimeline[1].vehicle) .. ":\n")
            for _, event in ipairs(vehicleTimeline) do
                local arrTime = string.format("%02d:%02d", math.floor(event.arrivalTime / 60), event.arrivalTime % 60)
                local depTime = string.format("%02d:%02d", math.floor(event.departureTime / 60), event.departureTime % 60)
                table.insert(result, string.format("  Station %d: Arrive %s, Depart %s\n", event.station, arrTime, depTime))
            end
            table.insert(result, "\n")
        end
    end
    
    if #timeline.conflicts > 0 then
        table.insert(result, "Conflicts:\n")
        for _, conflict in ipairs(timeline.conflicts) do
            table.insert(result, string.format("  Station %d: Vehicles %d and %d overlap\n", 
                conflict.station, conflict.vehicle1, conflict.vehicle2))
        end
    end
    
    return table.concat(result)
end

return timetableVisualizer
