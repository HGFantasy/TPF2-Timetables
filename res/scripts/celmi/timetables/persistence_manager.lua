-- Persistence Manager Module
-- Unified persistence coordination for all mod data
-- Ensures data consistency and provides transaction-like behavior

local persistenceManager = {}

-- CommonAPI2 persistence API
local commonapi2_available = false
local commonapi2_persistence_api = nil

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

-- Registered persistence modules
local persistenceModules = {}

-- Register a persistence module
function persistenceManager.registerModule(moduleName, saveFunc, loadFunc, version)
    persistenceModules[moduleName] = {
        save = saveFunc,
        load = loadFunc,
        version = version or 1,
        lastSaveTime = 0
    }
end

-- Unregister a persistence module
function persistenceManager.unregisterModule(moduleName)
    persistenceModules[moduleName] = nil
end

-- Save all registered modules
function persistenceManager.saveAll()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local results = {}
    local allSuccess = true
    
    for moduleName, module in pairs(persistenceModules) do
        if module.save then
            local success, data = pcall(module.save)
            if success and data then
                results[moduleName] = {
                    success = true,
                    data = data,
                    version = module.version
                }
            else
                results[moduleName] = {
                    success = false,
                    error = tostring(data)
                }
                allSuccess = false
            end
        end
    end
    
    -- Save all data atomically if possible
    local success, err = pcall(function()
        local dataToSave = {
            timestamp = require("celmi/timetables/timetable_helper").getTime(),
            modules = results
        }
        
        if commonapi2_persistence_api.set then
            commonapi2_persistence_api.set("timetables_unified_data", dataToSave)
        elseif commonapi2_persistence_api.save then
            commonapi2_persistence_api.save("timetables_unified_data", dataToSave)
        elseif commonapi2_persistence_api.write then
            commonapi2_persistence_api.write("timetables_unified_data", dataToSave)
        else
            error("CommonAPI2 persistence API not found")
        end
    end)
    
    if success then
        -- Update last save time for all modules
        local currentTime = require("celmi/timetables/timetable_helper").getTime()
        for moduleName, module in pairs(persistenceModules) do
            if results[moduleName] and results[moduleName].success then
                module.lastSaveTime = currentTime
            end
        end
        return true, nil
    else
        return false, tostring(err)
    end
end

-- Load all registered modules
function persistenceManager.loadAll()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, loadedData = pcall(function()
        if commonapi2_persistence_api.get then
            return commonapi2_persistence_api.get("timetables_unified_data")
        elseif commonapi2_persistence_api.load then
            return commonapi2_persistence_api.load("timetables_unified_data")
        elseif commonapi2_persistence_api.read then
            return commonapi2_persistence_api.read("timetables_unified_data")
        end
        return nil
    end)
    
    if success and loadedData and type(loadedData) == "table" and loadedData.modules then
        local allSuccess = true
        for moduleName, moduleData in pairs(loadedData.modules) do
            local module = persistenceModules[moduleName]
            if module and module.load and moduleData.success then
                local loadSuccess, loadErr = pcall(function()
                    return module.load(moduleData.data)
                end)
                if not loadSuccess then
                    print("Timetables: Failed to load module " .. moduleName .. ": " .. tostring(loadErr))
                    allSuccess = false
                end
            end
        end
        return allSuccess, nil
    else
        return false, success and "No saved unified data found" or tostring(loadedData)
    end
end

-- Save a specific module
function persistenceManager.saveModule(moduleName)
    local module = persistenceModules[moduleName]
    if not module or not module.save then
        return false, "Module not registered or no save function"
    end
    
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, data = pcall(module.save)
    if success and data then
        local saveSuccess, err = pcall(function()
            local dataToSave = {
                timestamp = require("celmi/timetables/timetable_helper").getTime(),
                version = module.version,
                data = data
            }
            
            if commonapi2_persistence_api.set then
                commonapi2_persistence_api.set("timetables_" .. moduleName, dataToSave)
            elseif commonapi2_persistence_api.save then
                commonapi2_persistence_api.save("timetables_" .. moduleName, dataToSave)
            elseif commonapi2_persistence_api.write then
                commonapi2_persistence_api.write("timetables_" .. moduleName, dataToSave)
            end
        end)
        
        if saveSuccess then
            module.lastSaveTime = require("celmi/timetables/timetable_helper").getTime()
            return true, nil
        else
            return false, tostring(err)
        end
    else
        return false, tostring(data)
    end
end

-- Re-check CommonAPI2 persistence API at runtime
function persistenceManager.recheckPersistenceAPI()
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
                print("Timetables: Re-initialized persistence_manager API at runtime")
            end
        end
        return commonapi2_available and commonapi2_persistence_api ~= nil
    end
    return false
end

-- Check if persistence is available
function persistenceManager.isAvailable()
    -- Try to re-check if not already available (for runtime initialization)
    if not commonapi2_available or not commonapi2_persistence_api then
        persistenceManager.recheckPersistenceAPI()
    end
    return commonapi2_available and commonapi2_persistence_api ~= nil
end

-- Get last save time for a module
function persistenceManager.getLastSaveTime(moduleName)
    local module = persistenceModules[moduleName]
    if module then
        return module.lastSaveTime
    end
    return 0
end

-- Auto-save all modules (call periodically)
local lastAutoSaveTime = 0
local AUTO_SAVE_INTERVAL = 30 -- Save every 30 seconds

function persistenceManager.autoSaveIfNeeded(currentTime)
    if not persistenceManager.isAvailable() then
        return false
    end
    
    currentTime = currentTime or require("celmi/timetables/timetable_helper").getTime()
    
    if currentTime - lastAutoSaveTime >= AUTO_SAVE_INTERVAL then
        local success, err = persistenceManager.saveAll()
        if success then
            lastAutoSaveTime = currentTime
            return true
        else
            print("Timetables: Unified auto-save failed: " .. tostring(err))
            return false
        end
    end
    
    return false
end

return persistenceManager
