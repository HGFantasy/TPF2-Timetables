-- Line Coordinator Module
-- Coordinates timetables across multiple lines for synchronized transfers

local lineCoordinator = {}
local timetableHelper = require "celmi/timetables/timetable_helper"
local persistenceManager = require "celmi/timetables/persistence_manager"

-- CommonAPI2 persistence for coordination data
local commonapi2_available = false
local commonapi2_persistence_api = nil
local COORDINATION_DATA_VERSION = 1

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

-- Coordination data structure
-- {
--     transferPoints = {
--         [stationID] = {
--             connections = {
--                 {
--                     fromLine = line1,
--                     toLine = line2,
--                     connectionTime = 120, -- seconds
--                     enabled = true
--                 }
--             }
--         }
--     }
-- }
local coordinationData = {
    transferPoints = {}
}

-- Define a transfer point between two lines
-- @param stationID integer The station ID where transfer occurs
-- @param fromLine integer The line vehicles arrive on
-- @param toLine integer The line vehicles depart on
-- @param connectionTime integer Minimum connection time in seconds (default: 120)
-- @return boolean success, string message
function lineCoordinator.addTransferPoint(stationID, fromLine, toLine, connectionTime)
    if not stationID or not fromLine or not toLine then
        return false, "Invalid parameters"
    end
    
    connectionTime = connectionTime or 120 -- Default 2 minutes
    
    if not coordinationData.transferPoints[stationID] then
        coordinationData.transferPoints[stationID] = {
            connections = {}
        }
    end
    
    -- Check if connection already exists
    for _, conn in ipairs(coordinationData.transferPoints[stationID].connections) do
        if conn.fromLine == fromLine and conn.toLine == toLine then
            conn.connectionTime = connectionTime
            conn.enabled = true
            lineCoordinator.saveCoordinationData()
            return true, "Transfer point updated"
        end
    end
    
    -- Add new connection
    table.insert(coordinationData.transferPoints[stationID].connections, {
        fromLine = fromLine,
        toLine = toLine,
        connectionTime = connectionTime,
        enabled = true
    })
    
    lineCoordinator.saveCoordinationData()
    return true, "Transfer point added"
end

-- Remove a transfer point
-- @param stationID integer The station ID
-- @param fromLine integer The line vehicles arrive on
-- @param toLine integer The line vehicles depart on
-- @return boolean success
function lineCoordinator.removeTransferPoint(stationID, fromLine, toLine)
    if not stationID or not coordinationData.transferPoints[stationID] then
        return false
    end
    
    local connections = coordinationData.transferPoints[stationID].connections
    for i, conn in ipairs(connections) do
        if conn.fromLine == fromLine and conn.toLine == toLine then
            table.remove(connections, i)
            lineCoordinator.saveCoordinationData()
            return true
        end
    end
    
    return false
end

-- Get transfer points for a station
-- @param stationID integer The station ID
-- @return table Array of transfer connections
function lineCoordinator.getTransferPoints(stationID)
    if not stationID or not coordinationData.transferPoints[stationID] then
        return {}
    end
    
    local result = {}
    for _, conn in ipairs(coordinationData.transferPoints[stationID].connections) do
        if conn.enabled then
            table.insert(result, conn)
        end
    end
    
    return result
end

-- Coordinate timetables for a transfer point
-- Adjusts departure times on toLine to match arrival times on fromLine
-- @param stationID integer The station ID
-- @param fromLine integer The line vehicles arrive on
-- @param toLine integer The line vehicles depart on
-- @return boolean success, string message
function lineCoordinator.coordinateTransfer(stationID, fromLine, toLine)
    if not stationID or not fromLine or not toLine then
        return false, "Invalid parameters"
    end
    
    local transferPoints = lineCoordinator.getTransferPoints(stationID)
    local connection = nil
    
    for _, conn in ipairs(transferPoints) do
        if conn.fromLine == fromLine and conn.toLine == toLine then
            connection = conn
            break
        end
    end
    
    if not connection then
        return false, "Transfer point not defined"
    end
    
    local timetable = require "celmi/timetables/timetable"
    local timetableObject = timetable.getTimetableObject()
    
    -- Find station index on both lines
    local fromStop = nil
    local toStop = nil
    
    if timetableObject[fromLine] and timetableObject[fromLine].stations then
        for stop, stationInfo in pairs(timetableObject[fromLine].stations) do
            if stationInfo.stationID == stationID then
                fromStop = stop
                break
            end
        end
    end
    
    if timetableObject[toLine] and timetableObject[toLine].stations then
        for stop, stationInfo in pairs(timetableObject[toLine].stations) do
            if stationInfo.stationID == stationID then
                toStop = stop
                break
            end
        end
    end
    
    if not fromStop or not toStop then
        return false, "Station not found on one or both lines"
    end
    
    -- Get arrival slots from fromLine
    local fromStation = timetableObject[fromLine].stations[fromStop]
    if not fromStation or not fromStation.conditions or fromStation.conditions.type ~= "ArrDep" then
        return false, "From line does not have ArrDep timetable at this station"
    end
    
    local arrivalSlots = fromStation.conditions.ArrDep
    if not arrivalSlots or #arrivalSlots == 0 then
        return false, "No arrival slots defined on from line"
    end
    
    -- Get or create departure slots on toLine
    if not timetableObject[toLine].stations[toStop] then
        timetable.setConditionType(toLine, toStop, "ArrDep")
    end
    
    local toStation = timetableObject[toLine].stations[toStop]
    if not toStation.conditions or toStation.conditions.type ~= "ArrDep" then
        timetable.setConditionType(toLine, toStop, "ArrDep")
        toStation = timetableObject[toLine].stations[toStop]
    end
    
    if not toStation.conditions.ArrDep then
        toStation.conditions.ArrDep = {}
    end
    
    -- Generate departure slots based on arrival slots + connection time
    local departureSlots = {}
    for _, arrivalSlot in ipairs(arrivalSlots) do
        if type(arrivalSlot) == "table" and #arrivalSlot >= 4 then
            -- Calculate departure time: arrival time + connection time
            local arrivalSeconds = arrivalSlot[3] * 60 + arrivalSlot[4] -- Use departure time from arrival slot
            local departureSeconds = (arrivalSeconds + connection.connectionTime) % 86400
            
            local depHour = math.floor(departureSeconds / 3600) % 24
            local depMin = math.floor((departureSeconds % 3600) / 60)
            local depSec = departureSeconds % 60
            
            -- Use same arrival time as departure (simplified)
            local arrHour = math.floor(arrivalSeconds / 3600) % 24
            local arrMin = math.floor((arrivalSeconds % 3600) / 60)
            local arrSec = arrivalSeconds % 60
            
            table.insert(departureSlots, {
                arrMin,
                arrSec,
                depMin,
                depSec
            })
        end
    end
    
    -- Replace or merge departure slots
    toStation.conditions.ArrDep = departureSlots
    
    return true, "Timetables coordinated: " .. #departureSlots .. " slots created"
end

-- Get all coordinated lines for a station
-- @param stationID integer The station ID
-- @return table Map of line pairs that are coordinated
function lineCoordinator.getCoordinatedLines(stationID)
    local result = {}
    local transferPoints = lineCoordinator.getTransferPoints(stationID)
    
    for _, conn in ipairs(transferPoints) do
        local key = tostring(conn.fromLine) .. "_" .. tostring(conn.toLine)
        result[key] = {
            fromLine = conn.fromLine,
            toLine = conn.toLine,
            connectionTime = conn.connectionTime
        }
    end
    
    return result
end

-- Save coordination data to persistence
function lineCoordinator.saveCoordinationData()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, err = pcall(function()
        local dataToSave = {
            version = COORDINATION_DATA_VERSION,
            transferPoints = coordinationData.transferPoints
        }
        
        if commonapi2_persistence_api.set then
            commonapi2_persistence_api.set("timetables_coordination", dataToSave)
        elseif commonapi2_persistence_api.save then
            commonapi2_persistence_api.save("timetables_coordination", dataToSave)
        elseif commonapi2_persistence_api.write then
            commonapi2_persistence_api.write("timetables_coordination", dataToSave)
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

-- Load coordination data from persistence
function lineCoordinator.loadCoordinationData()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, loadedData = pcall(function()
        if commonapi2_persistence_api.get then
            return commonapi2_persistence_api.get("timetables_coordination")
        elseif commonapi2_persistence_api.load then
            return commonapi2_persistence_api.load("timetables_coordination")
        elseif commonapi2_persistence_api.read then
            return commonapi2_persistence_api.read("timetables_coordination")
        end
        return nil
    end)
    
    if success and loadedData and type(loadedData) == "table" then
        if loadedData.transferPoints then
            coordinationData.transferPoints = loadedData.transferPoints
            return true, nil
        end
    end
    
    return false, "No saved coordination data found"
end

-- Check if persistence is available
function lineCoordinator.isPersistenceAvailable()
    return commonapi2_available and commonapi2_persistence_api ~= nil
end

-- Register with persistence manager
pcall(function()
    if persistenceManager and persistenceManager.isAvailable() then
        persistenceManager.registerModule("line_coordination",
            function()
                return {
                    version = COORDINATION_DATA_VERSION,
                    transferPoints = coordinationData.transferPoints
                }
            end,
            function(data)
                if data and data.transferPoints then
                    coordinationData.transferPoints = data.transferPoints
                    return true
                end
                return false
            end,
            COORDINATION_DATA_VERSION
        )
    end
end)

-- Load coordination data on module initialization
pcall(function()
    lineCoordinator.loadCoordinationData()
end)

return lineCoordinator
