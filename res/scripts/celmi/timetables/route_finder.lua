-- Route Finder Module
-- Infrastructure for feature #16 Part B (Auto-Generate Complete Routes & Lines)
-- Provides network analysis, pathfinding, and route generation for trains, buses, trams

local routeFinder = {}
local networkGraphCache = require "celmi/timetables/network_graph_cache"
local timetableHelper = require "celmi/timetables/timetable_helper"

-- Use cached entity exists function from timetableHelper (always available)
local cachedEntityExists = function(entity)
    return timetableHelper.entityExists(entity, timetableHelper.getTime())
end

-- Register route finder caches with centralized cache invalidation
if timetableHelper.registerCacheInvalidation then
    -- Register distance cache invalidation
    timetableHelper.registerCacheInvalidation("networkGraph", function()
        routeFinder.clearDistanceCache()
    end)
    
    -- Register station position cache invalidation
    timetableHelper.registerCacheInvalidation("entity", function(entity)
        if entity then
            timetableHelper.invalidateStationPositionCache(entity)
        end
    end)
end

-- Carrier type mapping
local CARRIER_TYPES = {
    RAIL = api.type.enum.Carrier.RAIL,
    ROAD = api.type.enum.Carrier.ROAD,
    TRAM = api.type.enum.Carrier.TRAM,
    WATER = api.type.enum.Carrier.WATER,
    AIR = api.type.enum.Carrier.AIR
}

-- Find all stations of a specific carrier type
-- Uses existing lines to find stations (more reliable than direct station enumeration)
function routeFinder.findStations(carrierType)
    if not carrierType or not CARRIER_TYPES[carrierType] then
        return {}
    end
    
    local carrierEnum = CARRIER_TYPES[carrierType]
    local stations = {}
    local stationMap = {} -- Use map to avoid duplicates
    
    -- Get all lines and find stations on lines of the correct carrier type
    local currentTime = timetableHelper.getTime()
    local lines = timetableHelper.getLines(currentTime)
    
    -- Batch collect all first vehicles from all lines for carrier type checking
    local vehicleIds = {}
    local lineToVehicleMap = {}
    for _, lineID in pairs(lines) do
        local vehicles = timetableHelper.getLineVehicles(lineID, currentTime)
        if vehicles and vehicles[1] then
            vehicleIds[#vehicleIds + 1] = vehicles[1]
            lineToVehicleMap[vehicles[1]] = lineID
        end
    end
    
    -- Batch get vehicle components
    local vehicleComponents = timetableHelper.batchGetVehicleComponents(vehicleIds, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
    
    -- Collect station IDs that need names
    local stationIdsForNames = {}
    local stationIdSet = {}
    
    for vehicleId, vehicleComponent in pairs(vehicleComponents) do
        if vehicleComponent and vehicleComponent.carrier == carrierEnum then
            local lineID = lineToVehicleMap[vehicleId]
            if lineID then
                -- Get all stations on this line
                local lineStations = timetableHelper.getAllStations(lineID)
                for _, stationID in pairs(lineStations) do
                    if not stationMap[stationID] then
                        stationMap[stationID] = true
                        if not stationIdSet[stationID] then
                            stationIdSet[stationID] = true
                            stationIdsForNames[#stationIdsForNames + 1] = stationID
                        end
                    end
                end
            end
        end
    end
    
    -- Batch get station name components if we have stations to process
    if #stationIdsForNames > 0 then
        local stationNameComponents = timetableHelper.batchGetLineComponents(stationIdsForNames, api.type.ComponentType.NAME, currentTime)
        for _, stationID in ipairs(stationIdsForNames) do
            local nameComponent = stationNameComponents[stationID]
            local stationName = "ERROR"
            if nameComponent and nameComponent.name then
                stationName = nameComponent.name
            else
                -- Fallback to individual lookup
                stationName = timetableHelper.getStationName(stationID)
            end
            if stationName and stationName ~= "ERROR" then
                table.insert(stations, {
                    id = stationID,
                    name = stationName
                })
            end
        end
    end
    
    -- Sort by name
    table.sort(stations, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)
    
    return stations
end

-- Build network graph for a carrier type
-- Graph format: {[stationID] = {neighbors = {stationID1 = distance, stationID2 = distance, ...}}}
function routeFinder.buildNetworkGraph(carrierType)
    if not carrierType or not CARRIER_TYPES[carrierType] then
        return nil
    end
    
    -- Check cache first
    local cachedGraph = networkGraphCache.get(carrierType)
    if cachedGraph then
        return cachedGraph
    end
    
    local graph = {}
    local stations = routeFinder.findStations(carrierType)
    
    -- Pre-fetch all station positions for distance calculations
    local allStationIDs = {}
    for _, station in ipairs(stations) do
        table.insert(allStationIDs, station.id)
        if not graph[station.id] then
            graph[station.id] = {neighbors = {}}
        end
    end
    local stationPositions = timetableHelper.batchGetStationPositions(allStationIDs, timetableHelper.getTime())
    
    -- Collect all station pairs that need distance calculation
    local distancePairs = {}
    local pairToGraph = {} -- Map pairs to graph entries
    
    -- Build connectivity by checking existing lines
    -- For each station, find which other stations are reachable via existing lines
    local currentTime = timetableHelper.getTime()
    local lines = timetableHelper.getLines(currentTime)
    
    -- Batch collect all first vehicles from all lines for carrier type checking
    local vehicleIds = {}
    local lineToVehicleMap = {}
    for _, lineID in pairs(lines) do
        local vehicles = timetableHelper.getLineVehicles(lineID, currentTime)
        if vehicles and vehicles[1] then
            vehicleIds[#vehicleIds + 1] = vehicles[1]
            lineToVehicleMap[vehicles[1]] = lineID
        end
    end
    
    -- Batch get vehicle components
    local vehicleComponents = timetableHelper.batchGetVehicleComponents(vehicleIds, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
    
    -- Collect all station pairs that need distances
    for vehicleId, vehicleComponent in pairs(vehicleComponents) do
        if vehicleComponent and vehicleComponent.carrier == CARRIER_TYPES[carrierType] then
            local lineID = lineToVehicleMap[vehicleId]
            if lineID then
                -- Get all stations on this line
                local lineStations = timetableHelper.getAllStations(lineID)
                local stationList = {}
                for k, v in pairs(lineStations) do
                    table.insert(stationList, {index = k, stationID = v})
                end
                table.sort(stationList, function(a, b) return a.index < b.index end)
                
                -- Collect pairs for batch distance calculation
                for i = 1, #stationList - 1 do
                    local currentStation = stationList[i].stationID
                    local nextStation = stationList[i + 1].stationID
                    
                    -- Check if we need this distance
                    local needsDistance = false
                    for _, station in ipairs(stations) do
                        if station.id == currentStation or station.id == nextStation then
                            needsDistance = true
                            break
                        end
                    end
                    
                    if needsDistance then
                        local pairKey = tostring(currentStation) .. "_" .. tostring(nextStation)
                        if not distancePairs[pairKey] then
                            table.insert(distancePairs, {currentStation, nextStation})
                            distancePairs[pairKey] = true
                        end
                    end
                end
            end
        end
    end
    
    -- Batch calculate all distances
    local batchDistances = routeFinder.batchCalculateDistances(distancePairs)
    
    -- Now build graph using pre-calculated distances
    for vehicleId, vehicleComponent in pairs(vehicleComponents) do
        if vehicleComponent and vehicleComponent.carrier == CARRIER_TYPES[carrierType] then
            local lineID = lineToVehicleMap[vehicleId]
            if lineID then
                local lineStations = timetableHelper.getAllStations(lineID)
                local stationList = {}
                for k, v in pairs(lineStations) do
                    table.insert(stationList, {index = k, stationID = v})
                end
                table.sort(stationList, function(a, b) return a.index < b.index end)
                
                -- Add connections using pre-calculated distances
                for i = 1, #stationList - 1 do
                    local currentStation = stationList[i].stationID
                    local nextStation = stationList[i + 1].stationID
                    
                    local pairKey1 = tostring(currentStation) .. "_" .. tostring(nextStation)
                    local pairKey2 = tostring(nextStation) .. "_" .. tostring(currentStation)
                    local distance = batchDistances[pairKey1] or batchDistances[pairKey2] or routeFinder.calculateStationDistance(currentStation, nextStation)
                    
                    -- Add to graph for both stations (bidirectional)
                    if graph[currentStation] then
                        if not graph[currentStation].neighbors[nextStation] or graph[currentStation].neighbors[nextStation] > distance then
                            graph[currentStation].neighbors[nextStation] = distance
                        end
                    end
                    if graph[nextStation] then
                        if not graph[nextStation].neighbors[currentStation] or graph[nextStation].neighbors[currentStation] > distance then
                            graph[nextStation].neighbors[currentStation] = distance
                        end
                    end
                end
            end
        end
    end
    
    -- Cache the graph
    networkGraphCache.store(carrierType, graph, timetableHelper.getTime())
    
    return graph
end

-- Distance cache for station pairs
local distanceCache = {}
local distanceCacheTime = {}
local DISTANCE_CACHE_DURATION = 60 -- Cache for 60 seconds

-- Calculate distance between two stations (Euclidean distance)
-- Returns distance in game units, or default large value if positions unavailable
-- Uses cached positions and distance cache for performance
function routeFinder.calculateStationDistance(station1ID, station2ID)
    if not station1ID or not station2ID then
        return 1000 -- Default large distance for invalid inputs
    end
    
    -- Check distance cache first
    local cacheKey1 = tostring(station1ID) .. "_" .. tostring(station2ID)
    local cacheKey2 = tostring(station2ID) .. "_" .. tostring(station1ID)
    local cachedDistance = distanceCache[cacheKey1] or distanceCache[cacheKey2]
    if cachedDistance and distanceCacheTime[cacheKey1 or cacheKey2] then
        local cachedTime = distanceCacheTime[cacheKey1] or distanceCacheTime[cacheKey2]
        local currentTime = timetableHelper.getTime()
        if currentTime - cachedTime < DISTANCE_CACHE_DURATION then
            return cachedDistance
        end
    end
    
    -- Try CommonAPI2 distance API if available
    if commonapi and commonapi.calculateDistance then
        local success, distance = pcall(function()
            return commonapi.calculateDistance(station1ID, station2ID)
        end)
        if success and distance and distance > 0 then
            -- Cache the result
            distanceCache[cacheKey1] = distance
            distanceCacheTime[cacheKey1] = timetableHelper.getTime()
            return distance
        end
    elseif commonapi and commonapi.getDistance then
        local success, distance = pcall(function()
            return commonapi.getDistance(station1ID, station2ID)
        end)
        if success and distance and distance > 0 then
            distanceCache[cacheKey1] = distance
            distanceCacheTime[cacheKey1] = timetableHelper.getTime()
            return distance
        end
    end
    
    -- Fallback to manual calculation using cached positions
    local currentTime = timetableHelper.getTime()
    local pos1 = timetableHelper.getStationPosition(station1ID, currentTime)
    local pos2 = timetableHelper.getStationPosition(station2ID, currentTime)
    
    if not pos1 or not pos2 then
        return 1000 -- Default large distance if positions unavailable
    end
    
    local dx = pos2.x - pos1.x
    local dy = pos2.y - pos1.y
    local dz = pos2.z - pos1.z
    
    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    -- Safety check: ensure distance is valid (not NaN or infinite)
    if not distance or distance ~= distance or distance == math.huge then
        return 1000
    end
    
    -- Cache the calculated distance
    distanceCache[cacheKey1] = distance
    distanceCacheTime[cacheKey1] = currentTime
    
    return distance
end

-- Clear distance cache (call when stations are modified)
function routeFinder.clearDistanceCache()
    distanceCache = {}
    distanceCacheTime = {}
end

-- Batch calculate distances for multiple station pairs
function routeFinder.batchCalculateDistances(stationPairs)
    if not stationPairs or #stationPairs == 0 then
        return {}
    end
    
    local results = {}
    local stationIDs = {}
    local stationIDSet = {}
    
    -- Collect all unique station IDs
    for _, pair in ipairs(stationPairs) do
        if not stationIDSet[pair[1]] then
            stationIDSet[pair[1]] = true
            table.insert(stationIDs, pair[1])
        end
        if not stationIDSet[pair[2]] then
            stationIDSet[pair[2]] = true
            table.insert(stationIDs, pair[2])
        end
    end
    
    -- Batch fetch all station positions
    local positions = timetableHelper.batchGetStationPositions(stationIDs, timetableHelper.getTime())
    
    -- Calculate distances for all pairs
    for _, pair in ipairs(stationPairs) do
        local station1ID = pair[1]
        local station2ID = pair[2]
        local key = tostring(station1ID) .. "_" .. tostring(station2ID)
        
        local pos1 = positions[station1ID]
        local pos2 = positions[station2ID]
        
        if pos1 and pos2 then
            local dx = pos2.x - pos1.x
            local dy = pos2.y - pos1.y
            local dz = pos2.z - pos1.z
            local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
            
            if distance and distance == distance and distance ~= math.huge then
                results[key] = distance
                -- Cache the result
                distanceCache[key] = distance
                distanceCacheTime[key] = timetableHelper.getTime()
            else
                results[key] = 1000
            end
        else
            results[key] = 1000
        end
    end
    
    return results
end

-- A* pathfinding algorithm for finding shortest path
-- Returns path as array of station IDs, or nil if no path found
function routeFinder.findPath(startStationID, endStationID, carrierType, networkGraph)
    -- Input validation
    if not startStationID or not endStationID then
        return nil
    end
    
    if startStationID == endStationID then
        return {startStationID} -- Same station, return single-station path
    end
    
    -- Validate station IDs exist
    if not cachedEntityExists(startStationID) or not cachedEntityExists(endStationID) then
        return nil
    end
    
    if not networkGraph then
        networkGraph = routeFinder.buildNetworkGraph(carrierType)
    end
    
    if not networkGraph or not networkGraph[startStationID] or not networkGraph[endStationID] then
        return nil
    end
    
    -- A* algorithm with distance-based costs
    local openSet = {} -- Priority queue: {station, path, cost, heuristic}
    local closedSet = {}
    local gScore = {} -- Distance from start
    local fScore = {} -- Estimated total cost (g + h)
    
    -- Initialize
    gScore[startStationID] = 0
    -- Use cached distance calculation (already optimized with caching)
    local initialHeuristic = routeFinder.calculateStationDistance(startStationID, endStationID)
    fScore[startStationID] = initialHeuristic
    
    -- Safety check: if heuristic is invalid, return nil
    if not initialHeuristic or initialHeuristic ~= initialHeuristic or initialHeuristic == math.huge then
        return nil
    end
    
    -- Insert start node
    table.insert(openSet, {
        station = startStationID,
        path = {startStationID},
        cost = 0,
        heuristic = initialHeuristic
    })
    
    -- Limit search iterations to prevent infinite loops
    local maxIterations = 10000
    local iterations = 0
    
    while #openSet > 0 and iterations < maxIterations do
        iterations = iterations + 1
        
        -- Find node with lowest fScore
        local bestIndex = 1
        local bestF = openSet[1].cost + openSet[1].heuristic
        for i = 2, #openSet do
            local f = openSet[i].cost + openSet[i].heuristic
            if f < bestF then
                bestF = f
                bestIndex = i
            end
        end
        
        local current = table.remove(openSet, bestIndex)
        if not current or not current.station then
            break -- Safety check
        end
        
        closedSet[current.station] = true
        
        -- Check if we reached the goal
        if current.station == endStationID then
            return current.path
        end
        
        -- Explore neighbors
        local neighbors = networkGraph[current.station] and networkGraph[current.station].neighbors
        if neighbors then
            for neighborID, distance in pairs(neighbors) do
                if not closedSet[neighborID] and distance and distance > 0 then
                    -- Validate neighbor exists
                    if cachedEntityExists(neighborID) then
                        local tentativeG = gScore[current.station] + distance
                        
                        -- Check if this path to neighbor is better
                        if not gScore[neighborID] or tentativeG < gScore[neighborID] then
                            gScore[neighborID] = tentativeG
                            local heuristic = routeFinder.calculateStationDistance(neighborID, endStationID)
                            
                            -- Validate heuristic
                            if heuristic and heuristic == heuristic and heuristic ~= math.huge then
                                fScore[neighborID] = tentativeG + heuristic
                                
                                -- Add to open set
                                local newPath = {}
                                for _, stationID in ipairs(current.path) do
                                    table.insert(newPath, stationID)
                                end
                                table.insert(newPath, neighborID)
                                
                                table.insert(openSet, {
                                    station = neighborID,
                                    path = newPath,
                                    cost = tentativeG,
                                    heuristic = heuristic
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    return nil -- No path found
end

-- Find multiple route options (shortest, fewest stops, etc.)
-- Returns array of route alternatives with different optimization criteria
function routeFinder.findRouteOptions(startStationID, endStationID, carrierType, maxOptions)
    -- Input validation
    if not startStationID or not endStationID then
        return {}
    end
    
    if startStationID == endStationID then
        return {} -- Same station
    end
    
    -- Validate stations exist
    if not cachedEntityExists(startStationID) or not cachedEntityExists(endStationID) then
        return {}
    end
    
    maxOptions = math.max(1, math.min(10, maxOptions or 3))
    
    local networkGraph = routeFinder.buildNetworkGraph(carrierType)
    if not networkGraph then
        return {}
    end
    
    local options = {}
    
    -- Option 1: Shortest path (distance-based)
    local shortestPath = routeFinder.findPath(startStationID, endStationID, carrierType, networkGraph)
    if shortestPath then
        local totalDistance = 0
        for i = 1, #shortestPath - 1 do
            totalDistance = totalDistance + (networkGraph[shortestPath[i]] and networkGraph[shortestPath[i]].neighbors[shortestPath[i + 1]] or 1000)
        end
        table.insert(options, {
            type = "shortest",
            path = shortestPath,
            distance = totalDistance,
            numStops = #shortestPath - 1
        })
    end
    
    -- Option 2: Fewest stops (BFS)
    if maxOptions > 1 then
        local bfsPath = routeFinder.findPathBFS(startStationID, endStationID, carrierType, networkGraph)
        if bfsPath and (#options == 0 or bfsPath ~= shortestPath) then
            table.insert(options, {
                type = "fewest_stops",
                path = bfsPath,
                numStops = #bfsPath - 1
            })
        end
    end
    
    return options
end

-- BFS pathfinding (for finding fewest stops)
-- Returns path with minimum number of stops, or nil if no path found
function routeFinder.findPathBFS(startStationID, endStationID, carrierType, networkGraph)
    -- Input validation
    if not startStationID or not endStationID then
        return nil
    end
    
    if startStationID == endStationID then
        return {startStationID} -- Same station
    end
    
    -- Validate stations exist
    if not cachedEntityExists(startStationID) or not cachedEntityExists(endStationID) then
        return nil
    end
    
    if not networkGraph then
        networkGraph = routeFinder.buildNetworkGraph(carrierType)
    end
    
    if not networkGraph or not networkGraph[startStationID] or not networkGraph[endStationID] then
        return nil
    end
    
    -- BFS to find path with fewest stops
    local queue = {{station = startStationID, path = {startStationID}}}
    local visited = {[startStationID] = true}
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        
        if current.station == endStationID then
            return current.path
        end
        
        local neighbors = networkGraph[current.station] and networkGraph[current.station].neighbors
        if neighbors then
            for neighborID, _ in pairs(neighbors) do
                if not visited[neighborID] then
                    visited[neighborID] = true
                    local newPath = {}
                    for _, stationID in ipairs(current.path) do
                        table.insert(newPath, stationID)
                    end
                    table.insert(newPath, neighborID)
                    table.insert(queue, {station = neighborID, path = newPath})
                end
            end
        end
    end
    
    return nil -- No path found
end

-- Find depots of a specific carrier type near a position
-- Note: TPF2 API may not expose depot enumeration directly
-- This is a placeholder that can be enhanced when depot API is available
function routeFinder.findDepots(carrierType, nearPosition, maxDistance)
    maxDistance = maxDistance or 1000 -- Default 1km
    
    if not carrierType or not CARRIER_TYPES[carrierType] then
        return {}
    end
    
    -- For now, return empty (depot finding would require API support)
    -- In a full implementation, this would scan for depots using game API
    -- The route wizard will warn users to check for depots manually
    
    return {}
end

-- Validate if a route is feasible for a carrier type
function routeFinder.validateRoute(route, carrierType)
    if not route or #route < 2 then
        return false, "Route must have at least 2 stations"
    end
    
    -- Check if all stations support the carrier type
    for _, stationID in ipairs(route) do
        if not cachedEntityExists(stationID) then
            return false, "Station does not exist: " .. tostring(stationID)
        end
        
        local currentTime = timetableHelper.getTime()
        local stationComponent = timetableHelper.getComponent(stationID, api.type.ComponentType.STATION_GROUP, currentTime)
        if not stationComponent then
            return false, "Invalid station: " .. tostring(stationID)
        end
        
        -- Check carrier support
        if stationComponent.carriers then
            local supportsCarrier = false
            local carrierEnum = CARRIER_TYPES[carrierType]
            for _, carrier in ipairs(stationComponent.carriers) do
                if carrier == carrierEnum then
                    supportsCarrier = true
                    break
                end
            end
            if not supportsCarrier then
                return false, "Station does not support " .. carrierType .. " transport"
            end
        end
    end
    
    -- Check if path exists between stations
    local networkGraph = routeFinder.buildNetworkGraph(carrierType)
    for i = 1, #route - 1 do
        local path = routeFinder.findPath(route[i], route[i + 1], carrierType, networkGraph)
        if not path or #path == 0 then
            return false, "No path found between stations " .. i .. " and " .. (i + 1)
        end
    end
    
    return true, "Route is valid"
end

-- Get route preview information (journey time, distance estimate, etc.)
function routeFinder.getRoutePreview(route, carrierType)
    if not route or #route < 2 then
        return nil
    end
    
    local preview = {
        numStations = #route,
        stationNames = {},
        estimatedJourneyTime = 0,
        hasDepots = false
    }
    
    -- Get station names
    for _, stationID in ipairs(route) do
        local stationName = timetableHelper.getStationName(stationID)
        table.insert(preview.stationNames, stationName or "Unknown")
    end
    
    -- Estimate journey time (using average speeds if available)
    -- This is a simplified estimate - could be improved with actual pathfinding distances
    local avgSpeed = 50 -- km/h default (adjust based on carrier type)
    if carrierType == "RAIL" then
        avgSpeed = 80
    elseif carrierType == "ROAD" then
        avgSpeed = 40
    elseif carrierType == "TRAM" then
        avgSpeed = 30
    end
    
    -- Calculate actual distance using route finder function
    local totalDistance = 0
    for i = 1, #route - 1 do
        totalDistance = totalDistance + routeFinder.calculateStationDistance(route[i], route[i + 1])
    end
    
    -- Convert distance to time (distance in game units, speed in km/h)
    -- Simplified conversion (would need actual game unit to km conversion)
    preview.estimatedJourneyTime = math.ceil(totalDistance / (avgSpeed / 3.6)) -- Rough estimate
    
    -- Check for depots near route endpoints
    if route[1] and route[#route] then
        local currentTime = timetableHelper.getTime()
        local station1 = timetableHelper.getComponent(route[1], api.type.ComponentType.STATION_GROUP, currentTime)
        local station2 = timetableHelper.getComponent(route[#route], api.type.ComponentType.STATION_GROUP, currentTime)
        if station1 and station1.position then
            local depots1 = routeFinder.findDepots(carrierType, station1.position, 500)
            if #depots1 > 0 then
                preview.hasDepots = true
            end
        end
        if station2 and station2.position then
            local depots2 = routeFinder.findDepots(carrierType, station2.position, 500)
            if #depots2 > 0 then
                preview.hasDepots = true
            end
        end
    end
    
    return preview
end

-- Traffic flow analysis cache
-- Format: trafficCache[carrierType] = {segments = {[segmentKey] = {vehicleCount, congestionScore, lastUpdate}}, lastUpdate = timestamp}
local trafficCache = {}

-- Get segment key for a connection between two stations
local function getSegmentKey(station1ID, station2ID)
    if station1ID < station2ID then
        return station1ID .. "_" .. station2ID
    else
        return station2ID .. "_" .. station1ID
    end
end

-- Analyze traffic flow for a carrier type
-- Returns congestion scores for each segment
function routeFinder.analyzeTrafficFlow(carrierType, updateInterval)
    -- Get default from settings if not provided
    local settings = require "celmi/timetables/settings"
    updateInterval = updateInterval or settings.get("routeFinderTrafficUpdateInterval")
    
    -- Input validation
    if not carrierType or not CARRIER_TYPES[carrierType] then
        return {}
    end
    
    -- Ensure update interval is positive
    updateInterval = math.max(1, updateInterval)
    
    -- Check cache
    if trafficCache[carrierType] then
        local lastUpdate = trafficCache[carrierType].lastUpdate or 0
        local currentTime = timetableHelper.getTime()
        if currentTime - lastUpdate < updateInterval then
            return trafficCache[carrierType].segments
        end
    end
    
    local carrierEnum = CARRIER_TYPES[carrierType]
    local segments = {}
    
    -- Count vehicles on each line segment
    local currentTime = timetableHelper.getTime()
    local lines = timetableHelper.getLines(currentTime)
    
    -- Batch collect all vehicles and their components
    local allVehicleIds = {}
    local vehicleToLineMap = {}
    for _, lineID in pairs(lines) do
        local vehicles = timetableHelper.getLineVehicles(lineID, currentTime)
        if vehicles then
            for _, vehicleID in pairs(vehicles) do
                table.insert(allVehicleIds, vehicleID)
                vehicleToLineMap[vehicleID] = lineID
            end
        end
    end
    
    -- Batch get vehicle components
    local vehicleComponents = timetableHelper.batchGetVehicleComponents(allVehicleIds, api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
    
    -- Collect all station pairs for distance calculation
    local stationPairs = {}
    local segmentKeys = {}
    
    for vehicleID, vehicleComponent in pairs(vehicleComponents) do
        if vehicleComponent and vehicleComponent.carrier == carrierEnum then
            local lineID = vehicleToLineMap[vehicleID]
            if lineID then
                -- Get stations on this line
                local lineStations = timetableHelper.getAllStations(lineID)
                local stationList = {}
                for k, v in pairs(lineStations) do
                    table.insert(stationList, {index = k, stationID = v})
                end
                table.sort(stationList, function(a, b) return a.index < b.index end)
                
                -- Collect station pairs for batch distance calculation
                for i = 1, #stationList - 1 do
                    local station1ID = stationList[i].stationID
                    local station2ID = stationList[i + 1].stationID
                    local segmentKey = getSegmentKey(station1ID, station2ID)
                    
                    if not segments[segmentKey] then
                        segments[segmentKey] = {
                            station1 = station1ID,
                            station2 = station2ID,
                            vehicleCount = 0,
                            distance = nil -- Will be calculated in batch
                        }
                        table.insert(stationPairs, {station1ID, station2ID})
                        segmentKeys[#stationPairs] = segmentKey
                    end
                end
            end
        end
    end
    
    -- Batch calculate all distances
    local batchDistances = routeFinder.batchCalculateDistances(stationPairs)
    
    -- Assign distances to segments
    for i, pair in ipairs(stationPairs) do
        local segmentKey = segmentKeys[i]
        if segmentKey and segments[segmentKey] then
            local key = tostring(pair[1]) .. "_" .. tostring(pair[2])
            segments[segmentKey].distance = batchDistances[key] or routeFinder.calculateStationDistance(pair[1], pair[2])
        end
    end
    
    -- Count vehicles per segment (second pass)
    for vehicleID, vehicleComponent in pairs(vehicleComponents) do
        if vehicleComponent and vehicleComponent.carrier == carrierEnum then
            local lineID = vehicleToLineMap[vehicleID]
            if lineID then
                local lineStations = timetableHelper.getAllStations(lineID)
                local stationList = {}
                for k, v in pairs(lineStations) do
                    table.insert(stationList, {index = k, stationID = v})
                end
                table.sort(stationList, function(a, b) return a.index < b.index end)
                
                -- Count vehicles between consecutive stations
                for i = 1, #stationList - 1 do
                    local station1ID = stationList[i].stationID
                    local station2ID = stationList[i + 1].stationID
                    local segmentKey = getSegmentKey(station1ID, station2ID)
                    
                    if segments[segmentKey] then
                        segments[segmentKey].vehicleCount = segments[segmentKey].vehicleCount + 1
                    end
                end
            end
        end
    end
    
    -- Calculate congestion scores (0-100)
    for segmentKey, segment in pairs(segments) do
        if segment and segment.vehicleCount and segment.distance then
            -- Simple congestion score: vehicle count normalized by distance
            -- Higher vehicle count per km = higher congestion
            local distanceKm = math.max(segment.distance / 1000, 0.1) -- Avoid division by zero
            local vehiclesPerKm = segment.vehicleCount / distanceKm
            -- Normalize to 0-100 scale (arbitrary threshold: 10 vehicles/km = 100 congestion)
            segment.congestionScore = math.min(100, math.max(0, (vehiclesPerKm / 10) * 100))
        else
            -- Default to no congestion if data is invalid
            segment.congestionScore = 0
        end
    end
    
    -- Cache results
    trafficCache[carrierType] = {
        segments = segments,
        lastUpdate = timetableHelper.getTime()
    }
    
    return segments
end

-- Find path with traffic consideration (weighted A*)
function routeFinder.findPathWithTraffic(startStationID, endStationID, carrierType, networkGraph, congestionWeight)
    congestionWeight = congestionWeight or 0.5 -- Default: 50% weight on congestion
    
    -- Input validation
    if not startStationID or not endStationID then
        return nil
    end
    
    if startStationID == endStationID then
        return {startStationID} -- Same station
    end
    
    -- Validate station IDs exist
    if not cachedEntityExists(startStationID) or not cachedEntityExists(endStationID) then
        return nil
    end
    
    if not networkGraph then
        networkGraph = routeFinder.buildNetworkGraph(carrierType)
    end
    
    if not networkGraph or not networkGraph[startStationID] or not networkGraph[endStationID] then
        return nil
    end
    
    -- Validate congestion weight is in valid range
    congestionWeight = math.max(0, math.min(1, congestionWeight))
    
    -- Get traffic flow data
    local trafficData = routeFinder.analyzeTrafficFlow(carrierType)
    
    -- A* with congestion-weighted costs
    local openSet = {}
    local closedSet = {}
    local gScore = {}
    local fScore = {}
    
    gScore[startStationID] = 0
    fScore[startStationID] = routeFinder.calculateStationDistance(startStationID, endStationID)
    
    table.insert(openSet, {
        station = startStationID,
        path = {startStationID},
        cost = 0,
        heuristic = fScore[startStationID]
    })
    
    while #openSet > 0 do
        -- Find node with lowest fScore
        local bestIndex = 1
        local bestF = openSet[1].cost + openSet[1].heuristic
        for i = 2, #openSet do
            local f = openSet[i].cost + openSet[i].heuristic
            if f < bestF then
                bestF = f
                bestIndex = i
            end
        end
        
        local current = table.remove(openSet, bestIndex)
        closedSet[current.station] = true
        
        if current.station == endStationID then
            return current.path
        end
        
        -- Explore neighbors
        local neighbors = networkGraph[current.station] and networkGraph[current.station].neighbors
        if neighbors then
            for neighborID, distance in pairs(neighbors) do
                if not closedSet[neighborID] then
                    -- Calculate base cost (distance)
                    local baseCost = distance
                    
                    -- Add congestion penalty
                    local segmentKey = getSegmentKey(current.station, neighborID)
                    local congestionPenalty = 0
                    if trafficData[segmentKey] then
                        local congestionScore = trafficData[segmentKey].congestionScore or 0
                        -- Convert congestion score (0-100) to distance penalty
                        -- High congestion adds extra "virtual distance"
                        congestionPenalty = (congestionScore / 100) * distance * congestionWeight
                    end
                    
                    local totalCost = baseCost + congestionPenalty
                    local tentativeG = gScore[current.station] + totalCost
                    
                    if not gScore[neighborID] or tentativeG < gScore[neighborID] then
                        gScore[neighborID] = tentativeG
                        fScore[neighborID] = tentativeG + routeFinder.calculateStationDistance(neighborID, endStationID)
                        
                        local newPath = {}
                        for _, stationID in ipairs(current.path) do
                            table.insert(newPath, stationID)
                        end
                        table.insert(newPath, neighborID)
                        
                        table.insert(openSet, {
                            station = neighborID,
                            path = newPath,
                            cost = tentativeG,
                            heuristic = fScore[neighborID] - tentativeG
                        })
                    end
                end
            end
        end
    end
    
    return nil
end

-- Find multiple route alternatives with traffic analysis
-- Returns array of route options with different congestion avoidance levels
function routeFinder.findRoutesWithTraffic(startStationID, endStationID, carrierType, maxRoutes, congestionWeight)
    -- Input validation
    if not startStationID or not endStationID then
        return {}
    end
    
    if startStationID == endStationID then
        return {} -- Same station, no route needed
    end
    
    -- Validate stations exist
    if not cachedEntityExists(startStationID) or not cachedEntityExists(endStationID) then
        return {}
    end
    
    -- Get defaults from settings if not provided
    local settings = require "celmi/timetables/settings"
    maxRoutes = maxRoutes or settings.get("routeFinderMaxRoutes")
    congestionWeight = congestionWeight or settings.get("routeFinderCongestionWeight")
    
    -- Validate parameters are in reasonable ranges
    maxRoutes = math.max(1, math.min(10, maxRoutes))
    congestionWeight = math.max(0, math.min(1, congestionWeight))
    
    local routes = {}
    
    -- Get traffic data
    local trafficData = routeFinder.analyzeTrafficFlow(carrierType)
    local networkGraph = routeFinder.buildNetworkGraph(carrierType)
    
    -- Find routes with different congestion weights
    local weights = {0.0, congestionWeight, 1.0} -- No congestion, balanced, high congestion avoidance
    
    for i, weight in ipairs(weights) do
        if #routes < maxRoutes then
            local path = routeFinder.findPathWithTraffic(startStationID, endStationID, carrierType, networkGraph, weight)
            if path and #path > 0 then
                -- Calculate route metrics
                local totalDistance = 0
                local totalCongestion = 0
                local congestionSegments = 0
                
                for j = 1, #path - 1 do
                    local segmentKey = getSegmentKey(path[j], path[j + 1])
                    local distance = routeFinder.calculateStationDistance(path[j], path[j + 1])
                    totalDistance = totalDistance + distance
                    
                    if trafficData[segmentKey] then
                        totalCongestion = totalCongestion + (trafficData[segmentKey].congestionScore or 0)
                        congestionSegments = congestionSegments + 1
                    end
                end
                
                local avgCongestion = congestionSegments > 0 and (totalCongestion / congestionSegments) or 0
                
                table.insert(routes, {
                    path = path,
                    distance = totalDistance,
                    congestionScore = avgCongestion,
                    congestionWeight = weight,
                    type = i == 1 and "shortest" or (i == 2 and "balanced" or "low_congestion")
                })
            end
        end
    end
    
    -- Sort by balanced score (distance + congestion)
    table.sort(routes, function(a, b)
        local scoreA = a.distance + (a.congestionScore * 10)
        local scoreB = b.distance + (b.congestionScore * 10)
        return scoreA < scoreB
    end)
    
    return routes
end

-------------------------------------------------------------
---------------------- Automatic Timetable Generation ----------------------
-------------------------------------------------------------

-- Generate timetable from demand patterns (if passenger data available)
-- @param line integer The line ID
-- @param station integer The station number
-- @param frequency integer Desired frequency in seconds
-- @param startTime table {hour, minute} Start time
-- @param endTime table {hour, minute} End time
-- @return boolean success, string message
function routeFinder.generateTimetableFromDemand(line, station, frequency, startTime, endTime)
    if not line or not station or not frequency then
        return false, "Invalid parameters"
    end
    
    frequency = math.max(60, frequency) -- Minimum 1 minute frequency
    startTime = startTime or {hour = 6, minute = 0}
    endTime = endTime or {hour = 22, minute = 0}
    
    local timetable = require "celmi/timetables/timetable"
    
    -- Calculate number of slots
    local startSeconds = startTime.hour * 3600 + startTime.minute * 60
    local endSeconds = endTime.hour * 3600 + endTime.minute * 60
    local duration = endSeconds - startSeconds
    if duration < 0 then duration = duration + 86400 end
    
    local numSlots = math.floor(duration / frequency)
    
    if numSlots == 0 then
        return false, "Invalid time range"
    end
    
    -- Generate slots
    local slots = {}
    for i = 0, numSlots - 1 do
        local arrivalSeconds = (startSeconds + i * frequency) % 86400
        local departureSeconds = (arrivalSeconds + 30) % 86400 -- 30 second dwell time
        
        local arrHour = math.floor(arrivalSeconds / 3600) % 24
        local arrMin = math.floor((arrivalSeconds % 3600) / 60)
        local arrSec = arrivalSeconds % 60
        local depHour = math.floor(departureSeconds / 3600) % 24
        local depMin = math.floor((departureSeconds % 3600) / 60)
        local depSec = departureSeconds % 60
        
        table.insert(slots, {arrMin, arrSec, depMin, depSec})
    end
    
    -- Apply to timetable
    timetable.setConditionType(line, station, "ArrDep")
    for _, slot in ipairs(slots) do
        timetable.addCondition(line, station, {type = "ArrDep", ArrDep = slot})
    end
    
    return true, "Generated " .. numSlots .. " timetable slots"
end

-- Suggest optimal frequency based on line characteristics
-- @param line integer The line ID
-- @return integer Suggested frequency in seconds, or nil if cannot determine
function routeFinder.suggestOptimalFrequency(line)
    if not line then return nil end
    
    local timetableHelper = require "celmi/timetables/timetable_helper"
    local currentTime = timetableHelper.getTime()
    
    -- Get line vehicles
    local vehicles = timetableHelper.getLineVehicles(line, currentTime)
    local vehicleCount = 0
    if vehicles then
        for _ in pairs(vehicles) do
            vehicleCount = vehicleCount + 1
        end
    end
    
    -- Get line stations
    local stations = timetableHelper.getAllStations(line)
    local stationCount = 0
    if stations then
        for _ in pairs(stations) do
            stationCount = stationCount + 1
        end
    end
    
    -- Simple heuristic: more vehicles = higher frequency
    -- Base frequency: 15 minutes (900 seconds)
    -- Adjust based on vehicle count
    if vehicleCount == 0 then
        return 900 -- Default 15 minutes
    elseif vehicleCount == 1 then
        return 1800 -- 30 minutes for single vehicle
    elseif vehicleCount <= 3 then
        return 900 -- 15 minutes
    elseif vehicleCount <= 6 then
        return 600 -- 10 minutes
    else
        return 300 -- 5 minutes for high frequency
    end
end

-- Optimize timetable slot placement based on demand peaks
-- This is a placeholder - would need passenger flow data from API
-- @param line integer The line ID
-- @param station integer The station number
-- @return boolean success, string message
function routeFinder.optimizeTimetableForDemand(line, station)
    -- This would require access to passenger flow data
    -- For now, return a message indicating feature is not fully implemented
    return false, "Demand optimization requires passenger flow data API (not yet available)"
end

-- Clear traffic cache (call when network changes significantly)
function routeFinder.clearTrafficCache(carrierType)
    if carrierType then
        trafficCache[carrierType] = nil
    else
        trafficCache = {}
    end
end

-- Hub identification cache
local hubCache = {}

-- Identify major hubs for a carrier type
-- Returns array of {stationID, hubScore, reasons} sorted by score
function routeFinder.identifyHubs(carrierType, maxHubs)
    maxHubs = maxHubs or 10
    
    -- Input validation
    if not carrierType or not CARRIER_TYPES[carrierType] then
        return {}
    end
    
    -- Ensure maxHubs is positive
    maxHubs = math.max(1, math.min(50, maxHubs)) -- Limit to reasonable range
    
    -- Check cache
    local cacheKey = carrierType .. "_" .. maxHubs
    if hubCache[cacheKey] then
        return hubCache[cacheKey]
    end
    
    local stations = routeFinder.findStations(carrierType)
    local hubs = {}
    local networkGraph = routeFinder.buildNetworkGraph(carrierType)
    
    -- Batch collect all station IDs for component fetching
    local allStationIDs = {}
    for _, station in ipairs(stations) do
        table.insert(allStationIDs, station.id)
    end
    
    -- Batch fetch all station components at once
    local currentTime = timetableHelper.getTime()
    local stationComponents = timetableHelper.batchGetLineComponents(allStationIDs, api.type.ComponentType.STATION_GROUP, currentTime)
    
    -- Pre-calculate distances for all station pairs using batch operation
    local stationPairs = {}
    for i = 1, #stations do
        for j = i + 1, #stations do
            table.insert(stationPairs, {stations[i].id, stations[j].id})
        end
    end
    local batchDistances = routeFinder.batchCalculateDistances(stationPairs)
    
    -- Calculate hub scores for each station
    for _, station in ipairs(stations) do
        local stationID = station.id
        local hubScore = 0
        local reasons = {}
        
        -- Factor 1: Number of existing lines serving station (30% weight)
        local linesServingStation = 0
        local lines = timetableHelper.getLines(currentTime)
        for _, lineID in pairs(lines) do
            local vehicles = timetableHelper.getLineVehicles(lineID, currentTime)
            if vehicles and vehicles[1] then
                local vehicleComponent = timetableHelper.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
                if vehicleComponent and vehicleComponent.carrier == CARRIER_TYPES[carrierType] then
                    local lineStations = timetableHelper.getAllStations(lineID)
                    for _, lineStationID in pairs(lineStations) do
                        if lineStationID == stationID then
                            linesServingStation = linesServingStation + 1
                            break
                        end
                    end
                end
            end
        end
        local linesFactor = math.min(100, linesServingStation * 10) -- Max 10 lines = 100
        hubScore = hubScore + (linesFactor * 0.3)
        if linesServingStation > 0 then
            table.insert(reasons, linesServingStation .. " lines")
        end
        
        -- Factor 2: Geographic centrality (20% weight)
        -- Calculate average distance to all other stations using cached distances
        local totalDistance = 0
        local stationCount = 0
        for _, otherStation in ipairs(stations) do
            if otherStation.id ~= stationID then
                local key1 = tostring(stationID) .. "_" .. tostring(otherStation.id)
                local key2 = tostring(otherStation.id) .. "_" .. tostring(stationID)
                local distance = batchDistances[key1] or batchDistances[key2] or routeFinder.calculateStationDistance(stationID, otherStation.id)
                totalDistance = totalDistance + distance
                stationCount = stationCount + 1
            end
        end
        local avgDistance = stationCount > 0 and (totalDistance / stationCount) or 0
        -- Lower average distance = more central (better hub)
        -- Normalize: assume 5000 units is "far", so closer = higher score
        local centralityFactor = math.max(0, 100 - (avgDistance / 50))
        hubScore = hubScore + (centralityFactor * 0.2)
        if centralityFactor > 50 then
            table.insert(reasons, "central location")
        end
        
        -- Factor 3: Station size/capacity (30% weight)
        -- Use batch-fetched station component
        local stationComponent = stationComponents[stationID]
        local sizeFactor = 50 -- Default medium size
        if stationComponent then
            -- Estimate size based on number of platforms or carriers (if available)
            if stationComponent.carriers then
                sizeFactor = math.min(100, #stationComponent.carriers * 25) -- More carriers = larger station
            end
        end
        hubScore = hubScore + (sizeFactor * 0.3)
        if sizeFactor > 60 then
            table.insert(reasons, "large station")
        end
        
        -- Factor 4: Station type (20% weight)
        -- Check if station is a terminus (first or last stop on multiple lines)
        local isTerminus = false
        local terminusCount = 0
        for _, lineID in pairs(lines) do
            local vehicles = timetableHelper.getLineVehicles(lineID, currentTime)
            if vehicles and vehicles[1] then
                local vehicleComponent = timetableHelper.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
                if vehicleComponent and vehicleComponent.carrier == CARRIER_TYPES[carrierType] then
                    local lineStations = timetableHelper.getAllStations(lineID)
                    local stationList = {}
                    for k, v in pairs(lineStations) do
                        table.insert(stationList, {index = k, stationID = v})
                    end
                    table.sort(stationList, function(a, b) return a.index < b.index end)
                    
                    if #stationList > 0 then
                        local firstStation = stationList[1].stationID
                        local lastStation = stationList[#stationList].stationID
                        if firstStation == stationID or lastStation == stationID then
                            terminusCount = terminusCount + 1
                        end
                    end
                end
            end
        end
        local terminusFactor = math.min(100, terminusCount * 20) -- More terminus lines = better hub
        hubScore = hubScore + (terminusFactor * 0.2)
        if terminusCount > 0 then
            table.insert(reasons, terminusCount .. " terminus lines")
        end
        
        if hubScore > 20 then -- Only include stations with meaningful hub score
            table.insert(hubs, {
                stationID = stationID,
                stationName = station.name,
                hubScore = hubScore,
                reasons = reasons,
                linesServing = linesServingStation
            })
        end
    end
    
    -- Sort by hub score (descending)
    table.sort(hubs, function(a, b)
        return a.hubScore > b.hubScore
    end)
    
    -- Return top N hubs
    local topHubs = {}
    for i = 1, math.min(maxHubs, #hubs) do
        table.insert(topHubs, hubs[i])
    end
    
    -- Cache results
    hubCache[cacheKey] = topHubs
    
    return topHubs
end

-- Analyze network efficiency
-- Returns analysis object with redundancy, gaps, and optimization suggestions
function routeFinder.analyzeNetworkEfficiency(carrierType)
    -- Input validation
    if not carrierType or not CARRIER_TYPES[carrierType] then
        return nil
    end
    
    local analysis = {
        routeRedundancy = 0,
        coverageGaps = {},
        hubUtilization = {},
        commonDestinations = {},
        overlapSegments = {}
    }
    
    local currentTime = timetableHelper.getTime()
    local lines = timetableHelper.getLines(currentTime)
    local segmentUsage = {} -- Track how many routes use each segment
    local destinationCounts = {} -- Track common destinations
    local stationCoverage = {} -- Track which stations are served

    -- Analyze all lines
    for _, lineID in pairs(lines) do
        local vehicles = timetableHelper.getLineVehicles(lineID, currentTime)
        if vehicles and vehicles[1] then
            local vehicleComponent = timetableHelper.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE, currentTime)
            if vehicleComponent and vehicleComponent.carrier == CARRIER_TYPES[carrierType] then
                local lineStations = timetableHelper.getAllStations(lineID)
                local stationList = {}
                for k, v in pairs(lineStations) do
                    table.insert(stationList, {index = k, stationID = v})
                    stationCoverage[v] = (stationCoverage[v] or 0) + 1
                end
                table.sort(stationList, function(a, b) return a.index < b.index end)
                
                -- Track destination (last station)
                if #stationList > 0 then
                    local destination = stationList[#stationList].stationID
                    destinationCounts[destination] = (destinationCounts[destination] or 0) + 1
                end
                
                -- Track segment usage
                for i = 1, #stationList - 1 do
                    local segmentKey = getSegmentKey(stationList[i].stationID, stationList[i + 1].stationID)
                    segmentUsage[segmentKey] = (segmentUsage[segmentKey] or 0) + 1
                end
            end
        end
    end
    
    -- Calculate route redundancy (segments used by multiple routes)
    local redundantSegments = 0
    for segmentKey, count in pairs(segmentUsage) do
        if count > 1 then
            redundantSegments = redundantSegments + 1
            table.insert(analysis.overlapSegments, {
                segment = segmentKey,
                routeCount = count
            })
        end
    end
    analysis.routeRedundancy = redundantSegments
    
    -- Find common destinations (many routes ending at same station)
    for destinationID, count in pairs(destinationCounts) do
        if count > 2 then
            local stationName = timetableHelper.getStationName(destinationID)
            table.insert(analysis.commonDestinations, {
                stationID = destinationID,
                stationName = stationName,
                routeCount = count
            })
        end
    end
    table.sort(analysis.commonDestinations, function(a, b) return a.routeCount > b.routeCount end)
    
    -- Find coverage gaps (stations with few/no routes)
    local allStations = routeFinder.findStations(carrierType)
    for _, station in ipairs(allStations) do
        local coverage = stationCoverage[station.id] or 0
        if coverage < 2 then
            table.insert(analysis.coverageGaps, {
                stationID = station.id,
                stationName = station.name,
                routeCount = coverage
            })
        end
    end
    
    -- Analyze hub utilization
    local hubs = routeFinder.identifyHubs(carrierType, 10)
    for _, hub in ipairs(hubs) do
        local utilization = stationCoverage[hub.stationID] or 0
        table.insert(analysis.hubUtilization, {
            stationID = hub.stationID,
            stationName = hub.stationName,
            hubScore = hub.hubScore,
            routeCount = utilization,
            utilization = utilization / math.max(hub.linesServing, 1)
        })
    end
    
    return analysis
end

-- Suggest hub-based route (A → Hub → B)
-- Returns route information or nil if no hub route found
function routeFinder.suggestHubRoute(origin, destination, carrierType, hubs)
    -- Input validation
    if not origin or not destination or not carrierType then
        return nil
    end
    
    -- Validate stations exist
    if not cachedEntityExists(origin) or not cachedEntityExists(destination) then
        return nil
    end
    
    if origin == destination then
        return nil -- No need for hub route for same station
    end
    
    if not hubs or #hubs == 0 then
        hubs = routeFinder.identifyHubs(carrierType, 5)
    end
    
    if not hubs or #hubs == 0 then
        return nil
    end
    
    local networkGraph = routeFinder.buildNetworkGraph(carrierType)
    
    -- Find nearest hub to origin
    local nearestHub = nil
    local minDistance = math.huge
    
    for _, hub in ipairs(hubs) do
        local pathToHub = routeFinder.findPath(origin, hub.stationID, carrierType, networkGraph)
        if pathToHub and #pathToHub > 0 then
            local distance = 0
            for i = 1, #pathToHub - 1 do
                distance = distance + routeFinder.calculateStationDistance(pathToHub[i], pathToHub[i + 1])
            end
            if distance < minDistance then
                minDistance = distance
                nearestHub = hub
            end
        end
    end
    
    if not nearestHub then
        return nil
    end
    
    -- Find route from hub to destination
    local pathFromHub = routeFinder.findPath(nearestHub.stationID, destination, carrierType, networkGraph)
    if not pathFromHub or #pathFromHub == 0 then
        return nil
    end
    
    -- Combine routes (origin → hub → destination)
    local combinedPath = {}
    local pathToHub = routeFinder.findPath(origin, nearestHub.stationID, carrierType, networkGraph)
    
    -- Add origin → hub path (excluding hub at end to avoid duplicate)
    for i = 1, #pathToHub - 1 do
        table.insert(combinedPath, pathToHub[i])
    end
    
    -- Add hub → destination path
    for _, stationID in ipairs(pathFromHub) do
        table.insert(combinedPath, stationID)
    end
    
    return {
        path = combinedPath,
        hub = nearestHub,
        pathToHub = pathToHub,
        pathFromHub = pathFromHub,
        type = "hub_based"
    }
end

-- Generate feeder routes to a hub
-- Returns array of feeder route suggestions
function routeFinder.generateFeederRoutes(hubStationID, carrierType, maxFeederRoutes)
    maxFeederRoutes = maxFeederRoutes or 5
    
    -- Input validation
    if not hubStationID or not carrierType then
        return {}
    end
    
    -- Validate hub station exists
    if not cachedEntityExists(hubStationID) then
        return {}
    end
    
    -- Ensure maxFeederRoutes is in reasonable range
    maxFeederRoutes = math.max(1, math.min(20, maxFeederRoutes))
    
    local stations = routeFinder.findStations(carrierType)
    local networkGraph = routeFinder.buildNetworkGraph(carrierType)
    local feederRoutes = {}
    
    -- Find stations that are not well connected to the hub
    for _, station in ipairs(stations) do
        if station.id ~= hubStationID then
            local path = routeFinder.findPath(station.id, hubStationID, carrierType, networkGraph)
            if path and #path > 0 and #path <= 5 then -- Only short routes (feeder routes should be short)
                table.insert(feederRoutes, {
                    origin = station.id,
                    originName = station.name,
                    hub = hubStationID,
                    path = path,
                    distance = 0 -- Could calculate total distance
                })
            end
        end
    end
    
    -- Sort by distance (shortest first)
    for _, route in ipairs(feederRoutes) do
        local totalDistance = 0
        for i = 1, #route.path - 1 do
            totalDistance = totalDistance + routeFinder.calculateStationDistance(route.path[i], route.path[i + 1])
        end
        route.distance = totalDistance
    end
    
    table.sort(feederRoutes, function(a, b) return a.distance < b.distance end)
    
    -- Return top N
    local topFeeders = {}
    for i = 1, math.min(maxFeederRoutes, #feederRoutes) do
        table.insert(topFeeders, feederRoutes[i])
    end
    
    return topFeeders
end

-- Clear hub cache (call when network changes)
function routeFinder.clearHubCache()
    hubCache = {}
end

return routeFinder
