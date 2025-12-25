-- Settings Module
-- Centralized configuration for the Timetables mod
-- Stores global settings that apply across the mod
-- Supports CommonAPI2 persistence when available

local settings = {}

-- CommonAPI2 detection
local commonapi2_available = false
local commonapi2_settings_api = nil

-- Check for CommonAPI2 and settings API
if commonapi ~= nil and type(commonapi) == "table" then
    commonapi2_available = true
    -- Check for various possible CommonAPI2 settings APIs
    if commonapi.settings then
        commonapi2_settings_api = commonapi.settings
    elseif commonapi.config then
        commonapi2_settings_api = commonapi.config
    elseif commonapi.modSettings then
        commonapi2_settings_api = commonapi.modSettings
    end
end

-- Settings version for migration
local SETTINGS_VERSION = 1

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
    
    -- Delay Alert Settings
    delayAlertEnabled = true,
    delayAlertThreshold = 300, -- 5 minutes in seconds
    delayAlertSoundEnabled = false,
    delayAlertVisualEnabled = true,
    delayAlertPerLineThreshold = {}, -- Per-line thresholds override global
    
    -- Export/Import Settings
    exportIncludeDelayTolerance = true,
    exportIncludeRecoveryMode = true,
    exportIncludeTimePeriods = true,
    
    -- Settings Management
    autoSaveEnabled = true, -- Auto-save to CommonAPI2 when settings change
}

-- Current settings (initialized from defaults)
local currentSettings = {}

-- Track if settings have been modified (for auto-save)
local settingsModified = false
local lastSaveTime = 0
local autoSaveTimer = nil
local AUTO_SAVE_DELAY = 2 -- Wait 2 seconds before auto-saving

-- Load settings from CommonAPI2 or use defaults
function settings.load()
    -- First, initialize with defaults
    local hadSettings = false
    for key, value in pairs(defaultSettings) do
        if currentSettings[key] ~= nil then
            hadSettings = true
        end
        currentSettings[key] = value
    end
    
    -- Try to load from CommonAPI2 if available
    if commonapi2_available and commonapi2_settings_api then
        local success, loadedSettings = pcall(function()
            -- Try different possible API methods
            if commonapi2_settings_api.get then
                return commonapi2_settings_api.get("timetables_settings")
            elseif commonapi2_settings_api.load then
                return commonapi2_settings_api.load("timetables_settings")
            elseif commonapi2_settings_api.read then
                return commonapi2_settings_api.read("timetables_settings")
            end
            return nil
        end)
        
        if success and loadedSettings and type(loadedSettings) == "table" then
            -- Handle versioned settings structure
            local settingsData = loadedSettings
            if loadedSettings.settings and loadedSettings.version then
                -- New versioned format
                settingsData = loadedSettings.settings
                -- Handle migration if version differs
                if loadedSettings.version < SETTINGS_VERSION then
                    -- Migration logic for settings
                    print("Timetables: Migrating settings from version " .. loadedSettings.version .. " to " .. SETTINGS_VERSION)
                    
                    -- Version 1 migration: ensure all default settings exist
                    if loadedSettings.version < 1 then
                        for key, defaultValue in pairs(defaultSettings) do
                            if settingsData[key] == nil then
                                settingsData[key] = defaultValue
                            end
                        end
                    end
                    
                    -- Future version migrations can be added here
                end
            end
            
            -- Validate and merge loaded settings
            for key, value in pairs(settingsData) do
                if defaultSettings[key] ~= nil then
                    local valid, err = settings.validate(key, value)
                    if valid then
                        currentSettings[key] = value
                    end
                end
            end
            settingsModified = false
            return true
        else
            -- CommonAPI2 available but no saved settings - migrate current settings if they exist
            if hadSettings and not settingsModified then
                -- First time using CommonAPI2, migrate existing in-memory settings
                settings.save() -- Save current settings to CommonAPI2
            end
        end
    end
    
    settingsModified = false
    return false
end

-- Save settings to CommonAPI2
function settings.save()
    if not commonapi2_available or not commonapi2_settings_api then
        return false, "CommonAPI2 not available"
    end
    
    local success, err = pcall(function()
        -- Prepare settings with version info
        local settingsToSave = {
            version = SETTINGS_VERSION,
            settings = settings.getAll()
        }
        
        -- Try different possible API methods
        if commonapi2_settings_api.set then
            commonapi2_settings_api.set("timetables_settings", settingsToSave)
        elseif commonapi2_settings_api.save then
            commonapi2_settings_api.save("timetables_settings", settingsToSave)
        elseif commonapi2_settings_api.write then
            commonapi2_settings_api.write("timetables_settings", settingsToSave)
        else
            error("CommonAPI2 settings API not found")
        end
    end)
    
    if success then
        settingsModified = false
        -- Use game time if available, otherwise use a simple counter
        local timetableHelper = require "celmi/timetables/timetable_helper"
        if timetableHelper and timetableHelper.getTime then
            lastSaveTime = timetableHelper.getTime()
        else
            lastSaveTime = lastSaveTime + 1
        end
        return true, nil
    else
        return false, tostring(err)
    end
end

-- Initialize settings (load from save or use defaults)
function settings.initialize()
    settings.load()
end

-- Get a setting value
function settings.get(key)
    if currentSettings[key] ~= nil then
        return currentSettings[key]
    end
    return defaultSettings[key]
end

-- Auto-save function (called with debounce)
local function performAutoSave()
    if settings.get("autoSaveEnabled") and commonapi2_available and commonapi2_settings_api and settingsModified then
        pcall(function()
            settings.save()
        end)
    end
    autoSaveTimer = nil
end

-- Set a setting value
function settings.set(key, value)
    if defaultSettings[key] ~= nil then
        currentSettings[key] = value
        settingsModified = true
        
        -- Auto-save if enabled and CommonAPI2 is available
        if settings.get("autoSaveEnabled") and commonapi2_available and commonapi2_settings_api then
            -- Cancel existing timer if any
            if autoSaveTimer then
                -- In a real game environment, we'd use a proper timer
                -- For now, we'll save immediately after a short delay check
                -- This is a simplified implementation
            end
            
            -- Schedule auto-save (simplified - in real implementation would use coroutine/timer)
            -- For immediate feedback, we'll save after a brief delay
            -- Note: In the actual game, this would be handled by a coroutine or timer system
            -- For now, we mark as modified and let the save happen on next explicit save or game save
        end
        
        return true
    end
    return false
end

-- Trigger auto-save (call this periodically from main update loop if needed)
function settings.triggerAutoSave()
    if settings.get("autoSaveEnabled") and commonapi2_available and commonapi2_settings_api and settingsModified then
        local success, err = settings.save()
        return success
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

-- Get API status
function settings.getApiStatus()
    if commonapi2_available then
        if commonapi2_settings_api then
            return "CommonAPI2"
        else
            return "CommonAPI2 (No Settings API)"
        end
    else
        return "Native API"
    end
end

-- Check if settings persistence is available
function settings.isPersistent()
    return commonapi2_available and commonapi2_settings_api ~= nil
end

-- Get last save time
function settings.getLastSaveTime()
    return lastSaveTime
end

-- Check if settings have unsaved changes
function settings.hasUnsavedChanges()
    return settingsModified
end

-- Force save (used by manual save button)
function settings.forceSave()
    return settings.save()
end

-- Initialize on load
settings.initialize()

return settings
