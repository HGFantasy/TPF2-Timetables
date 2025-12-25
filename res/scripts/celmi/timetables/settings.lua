-- Settings Module
-- Centralized configuration for the Timetables mod
-- Stores global settings that apply across the mod

local settings = {}

-- Default settings
local defaultSettings = {
    -- Delay Recovery Settings
    defaultDelayRecoveryMode = "catch_up", -- catch_up, skip_to_next, hold_at_terminus, gradual_recovery
    defaultMaxDelayTolerance = 300, -- 5 minutes in seconds
    defaultMaxDelayToleranceEnabled = false,
    
    -- Auto-Generate Timetable Settings
    autoGenDefaultStartHour = 6,
    autoGenDefaultStartMin = 0,
    autoGenDefaultEndHour = 22,
    autoGenDefaultEndMin = 0,
    autoGenDefaultDwellTime = 30, -- seconds
    
    -- Route Finder Settings
    routeFinderCongestionWeight = 0.5, -- 0.0 to 1.0
    routeFinderMaxRoutes = 3,
    routeFinderTrafficUpdateInterval = 30, -- seconds
    
    -- Hub Identification Settings
    hubIdentificationMaxHubs = 10,
    hubIdentificationMinScore = 20,
    
    -- Network Analysis Settings
    networkAnalysisUpdateInterval = 60, -- seconds
    
    -- Display Settings
    departureBoardUpdateInterval = 5, -- seconds
    statisticsUpdateInterval = 5, -- seconds
    vehicleDepartureDisplayUpdateInterval = 5, -- seconds
    
    -- Performance Settings
    cleanTimetableInterval = 30, -- seconds
    cacheInvalidationEnabled = true,
    
    -- Validation Settings
    validationWarningsEnabled = true,
    validationCheckOnEdit = true,
    
    -- Export/Import Settings
    exportIncludeDelayTolerance = true,
    exportIncludeRecoveryMode = true,
    exportIncludeTimePeriods = true,
}

-- Current settings (initialized from defaults)
local currentSettings = {}

-- Initialize settings (load from save or use defaults)
function settings.initialize()
    -- For now, use defaults. In future, could load from save file
    for key, value in pairs(defaultSettings) do
        currentSettings[key] = value
    end
end

-- Get a setting value
function settings.get(key)
    if currentSettings[key] ~= nil then
        return currentSettings[key]
    end
    return defaultSettings[key]
end

-- Set a setting value
function settings.set(key, value)
    if defaultSettings[key] ~= nil then
        currentSettings[key] = value
        return true
    end
    return false
end

-- Reset a setting to default
function settings.reset(key)
    if defaultSettings[key] ~= nil then
        currentSettings[key] = defaultSettings[key]
        return true
    end
    return false
end

-- Reset all settings to defaults
function settings.resetAll()
    for key, value in pairs(defaultSettings) do
        currentSettings[key] = value
    end
end

-- Get all settings (for export/save)
function settings.getAll()
    local allSettings = {}
    for key, value in pairs(currentSettings) do
        allSettings[key] = value
    end
    return allSettings
end

-- Set all settings (for import/load)
function settings.setAll(newSettings)
    for key, value in pairs(newSettings) do
        if defaultSettings[key] ~= nil then
            currentSettings[key] = value
        end
    end
end

-- Get default value for a setting
function settings.getDefault(key)
    return defaultSettings[key]
end

-- Validate setting value
function settings.validate(key, value)
    if defaultSettings[key] == nil then
        return false, "Unknown setting: " .. tostring(key)
    end
    
    -- Type checking
    local defaultType = type(defaultSettings[key])
    if type(value) ~= defaultType then
        return false, "Invalid type for " .. key .. ": expected " .. defaultType
    end
    
    -- Range checking for numeric values
    if defaultType == "number" then
        if key == "routeFinderCongestionWeight" then
            if value < 0 or value > 1 then
                return false, "Congestion weight must be between 0 and 1"
            end
        elseif key:find("Interval") or key:find("Time") then
            if value < 1 then
                return false, "Interval/time must be at least 1 second"
            end
        elseif key:find("Max") or key:find("Min") then
            if value < 1 then
                return false, "Max/Min values must be at least 1"
            end
        end
    end
    
    -- Enum checking for string values
    if defaultType == "string" then
        if key == "defaultDelayRecoveryMode" then
            local validModes = {
                catch_up = true,
                skip_to_next = true,
                hold_at_terminus = true,
                gradual_recovery = true
            }
            if not validModes[value] then
                return false, "Invalid delay recovery mode"
            end
        end
    end
    
    return true, nil
end

-- Initialize on load
settings.initialize()

return settings
