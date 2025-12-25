-- Route Finder Module
-- Infrastructure for feature #16 Part B (Auto-Generate Complete Routes & Lines)
-- Provides network analysis, pathfinding, and route generation for trains, buses, trams

local routeFinder = {}
local networkGraphCache = require "celmi/timetables/network_graph_cache"
local timetableHelper = require "celmi/timetables/timetable_helper"

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
    local lines = api.engine.system.lineSystem.getLines()
    
    for _, lineID in pairs(lines) do
        -- Check if line uses this carrier type
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineID)
        if vehicles and vehicles[1] then
            local vehicleComponent = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
            if vehicleComponent and vehicleComponent.carrier == carrierEnum then
                -- Get all stations on this line
                local lineStations = timetableHelper.getAllStations(lineID)
                for _, stationID in pairs(lineStations) do
                    if not stationMap[stationID] then
                        stationMap[stationID] = true
                        local stationName = timetableHelper.getStationName(stationID)
                        if stationName and stationName ~= "ERROR" then
                            table.insert(stations, {
                                id = stationID,
                                name = stationName
                            })
                        end
                    end
                end
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
    
    -- Build connectivity by checking existing lines
    -- For each station, find which other stations are reachable via existing lines
    for _, station in ipairs(stations) do
        if not graph[station.id] then
            graph[station.id] = {neighbors = {}}
        end
        
        -- Find lines that serve this station
        local lines = api.engine.system.lineSystem.getLines()
        for _, lineID in pairs(lines) do
            -- Check if line uses this carrier type
            local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineID)
            if vehicles and vehicles[1] then
                local vehicleComponent = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
                if vehicleComponent and vehicleComponent.carrier == CARRIER_TYPES[carrierType] then
                    -- Get all stations on this line
                    local lineStations = timetableHelper.getAllStations(lineID)
                    local stationList = {}
                    for k, v in pairs(lineStations) do
                        table.insert(stationList, {index = k, stationID = v})
                    end
                    table.sort(stationList, function(a, b) return a.index < b.index end)
                    
                    -- Add connections between consecutive stations with distance calculation
                    for i = 1, #stationList - 1 do
                        local currentStation = stationList[i].stationID
                        local nextStation = stationList[i + 1].stationID
                        
                        -- Calculate actual distance between stations
                        local distance = routeFinder.calculateStationDistance(currentStation, nextStation)
                        
                        if currentStation == station.id then
                            -- Add next station as neighbor with distance
                            if not graph[station.id].neighbors[nextStation] or graph[station.id].neighbors[nextStation] > distance then
                                graph[station.id].neighbors[nextStation] = distance
                            end
                        elseif nextStation == station.id then
                            -- Add previous station as neighbor (bidirectional) with distance
                            if not graph[station.id].neighbors[currentStation] or graph[station.id].neighbors[currentStation] > distance then
                                graph[station.id].neighbors[currentStation] = distance
                            end
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

-- Calculate distance between two stations (Euclidean distance)
-- Returns distance in game units, or default large value if positions unavailable
function routeFinder.calculateStationDistance(station1ID, station2ID)
    if not station1ID or not station2ID then
        return 1000 -- Default large distance for invalid inputs
    end
    
    local station1 = api.engine.getComponent(station1ID, api.type.ComponentType.STATION_GROUP)
    local station2 = api.engine.getComponent(station2ID, api.type.ComponentType.STATION_GROUP)
    
    if not station1 or not station1.position or not station2 or not station2.position then
        return 1000 -- Default large distance if positions unavailable
    end
    
    local dx = station2.position.x - station1.position.x
    local dy = station2.position.y - station1.position.y
    local dz = station2.position.z - station1.position.z
    
    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    -- Safety check: ensure distance is valid (not NaN or infinite)
    if not distance or distance ~= distance or distance == math.huge then
        return 1000
    end
    
    return distance
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
    if not api.engine.entityExists(startStationID) or not api.engine.entityExists(endStationID) then
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
                    if api.engine.entityExists(neighborID) then
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
    if not api.engine.entityExists(startStationID) or not api.engine.entityExists(endStationID) then
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
    if not api.engine.entityExists(startStationID) or not api.engine.entityExists(endStationID) then
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
        if not api.engine.entityExists(stationID) then
            return false, "Station does not exist: " .. tostring(stationID)
        end
        
        local stationComponent = api.engine.getComponent(stationID, api.type.ComponentType.STATION_GROUP)
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
        local station1 = api.engine.getComponent(route[1], api.type.ComponentType.STATION_GROUP)
        local station2 = api.engine.getComponent(route[#route], api.type.ComponentType.STATION_GROUP)
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
    local lines = api.engine.system.lineSystem.getLines()
    for _, lineID in pairs(lines) do
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineID)
        if vehicles and vehicles[1] then
            local vehicleComponent = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
            if vehicleComponent and vehicleComponent.carrier == carrierEnum then
                -- Get stations on this line
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
                    
                    if not segments[segmentKey] then
                        segments[segmentKey] = {
                            station1 = station1ID,
                            station2 = station2ID,
                            vehicleCount = 0,
                            distance = routeFinder.calculateStationDistance(station1ID, station2ID)
                        }
                    end
                    
                    -- Count vehicles on this line (simplified: count all vehicles on line)
                    segments[segmentKey].vehicleCount = segments[segmentKey].vehicleCount + #vehicles
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
    if not api.engine.entityExists(startStationID) or not api.engine.entityExists(endStationID) then
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
    if not api.engine.entityExists(startStationID) or not api.engine.entityExists(endStationID) then
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
    
    -- Calculate hub scores for each station
    for _, station in ipairs(stations) do
        local stationID = station.id
        local hubScore = 0
        local reasons = {}
        
        -- Factor 1: Number of existing lines serving station (30% weight)
        local linesServingStation = 0
        local lines = api.engine.system.lineSystem.getLines()
        for _, lineID in pairs(lines) do
            local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineID)
            if vehicles and vehicles[1] then
                local vehicleComponent = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
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
        -- Calculate average distance to all other stations
        local totalDistance = 0
        local stationCount = 0
        for _, otherStation in ipairs(stations) do
            if otherStation.id ~= stationID then
                local distance = routeFinder.calculateStationDistance(stationID, otherStation.id)
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
        -- Try to get station size (may not be available in API)
        local stationComponent = api.engine.getComponent(stationID, api.type.ComponentType.STATION_GROUP)
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
            local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineID)
            if vehicles and vehicles[1] then
                local vehicleComponent = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
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
    
    local lines = api.engine.system.lineSystem.getLines()
    local segmentUsage = {} -- Track how many routes use each segment
    local destinationCounts = {} -- Track common destinations
    local stationCoverage = {} -- Track which stations are served
    
    -- Analyze all lines
    for _, lineID in pairs(lines) do
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineID)
        if vehicles and vehicles[1] then
            local vehicleComponent = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
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
    if not api.engine.entityExists(origin) or not api.engine.entityExists(destination) then
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
    if not api.engine.entityExists(hubStationID) then
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
