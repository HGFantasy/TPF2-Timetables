-- Timetable Templates Module
-- Allows users to save and reuse common timetable patterns

local timetableTemplates = {}
local timetableHelper = require "celmi/timetables/timetable_helper"
local persistenceManager = require "celmi/timetables/persistence_manager"

-- CommonAPI2 persistence for templates
local commonapi2_available = false
local commonapi2_persistence_api = nil
local TEMPLATE_DATA_VERSION = 1

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

-- Template storage
local templates = {}

-- Template structure:
-- {
--     name = "Template Name",
--     description = "Description",
--     type = "frequency" | "arrdep" | "unbunch",
--     parameters = {
--         frequency = 900, -- seconds
--         startTime = {hour = 6, minute = 0},
--         endTime = {hour = 22, minute = 0},
--         dwellTime = 30, -- seconds
--         -- For ArrDep templates:
--         slots = {{arrival, departure}, ...}
--         -- For Unbunch templates:
--         interval = 300 -- seconds
--     }
-- }

-- Create a new template
function timetableTemplates.createTemplate(name, description, templateType, parameters)
    if not name or name == "" then
        return false, "Template name is required"
    end
    
    if templates[name] then
        return false, "Template with this name already exists"
    end
    
    if not templateType or (templateType ~= "frequency" and templateType ~= "arrdep" and templateType ~= "unbunch") then
        return false, "Invalid template type"
    end
    
    templates[name] = {
        name = name,
        description = description or "",
        type = templateType,
        parameters = parameters or {},
        created = timetableHelper.getTime(),
        modified = timetableHelper.getTime()
    }
    
    timetableTemplates.saveTemplates()
    return true, "Template created"
end

-- Update an existing template
function timetableTemplates.updateTemplate(name, description, parameters)
    if not templates[name] then
        return false, "Template not found"
    end
    
    if description ~= nil then
        templates[name].description = description
    end
    
    if parameters then
        templates[name].parameters = parameters
    end
    
    templates[name].modified = timetableHelper.getTime()
    timetableTemplates.saveTemplates()
    return true, "Template updated"
end

-- Delete a template
function timetableTemplates.deleteTemplate(name)
    if not templates[name] then
        return false, "Template not found"
    end
    
    templates[name] = nil
    timetableTemplates.saveTemplates()
    return true, "Template deleted"
end

-- Get a template by name
function timetableTemplates.getTemplate(name)
    return templates[name]
end

-- Get all templates
function timetableTemplates.getAllTemplates()
    local result = {}
    for name, template in pairs(templates) do
        table.insert(result, template)
    end
    return result
end

-- Get templates by type
function timetableTemplates.getTemplatesByType(templateType)
    local result = {}
    for name, template in pairs(templates) do
        if template.type == templateType then
            table.insert(result, template)
        end
    end
    return result
end

-- Apply a template to a line/station
function timetableTemplates.applyTemplate(templateName, line, station, options)
    options = options or {}
    local template = templates[templateName]
    if not template then
        return false, "Template not found"
    end
    
    local timetable = require "celmi/timetables/timetable"
    
    if template.type == "frequency" then
        -- Generate frequency-based timetable
        local frequency = options.frequency or template.parameters.frequency or 900
        local startTime = options.startTime or template.parameters.startTime or {hour = 6, minute = 0}
        local endTime = options.endTime or template.parameters.endTime or {hour = 22, minute = 0}
        local dwellTime = options.dwellTime or template.parameters.dwellTime or 30
        
        -- Calculate number of slots needed
        local startSeconds = startTime.hour * 3600 + startTime.minute * 60
        local endSeconds = endTime.hour * 3600 + endTime.minute * 60
        local duration = endSeconds - startSeconds
        if duration < 0 then duration = duration + 86400 end -- Wrap around midnight
        
        local numSlots = math.floor(duration / frequency)
        
        -- Generate slots
        local slots = {}
        for i = 0, numSlots - 1 do
            local arrivalSeconds = (startSeconds + i * frequency) % 86400
            local departureSeconds = (arrivalSeconds + dwellTime) % 86400
            
            local arrivalHour = math.floor(arrivalSeconds / 3600) % 24
            local arrivalMin = math.floor((arrivalSeconds % 3600) / 60)
            local departureHour = math.floor(departureSeconds / 3600) % 24
            local departureMin = math.floor((departureSeconds % 3600) / 60)
            
            table.insert(slots, {arrivalMin, arrivalMin % 60, departureMin, departureMin % 60})
        end
        
        -- Apply slots to station
        timetable.setConditionType(line, station, "ArrDep")
        for _, slot in ipairs(slots) do
            timetable.addCondition(line, station, {type = "ArrDep", ArrDep = slot})
        end
        
        return true, "Frequency template applied"
        
    elseif template.type == "arrdep" then
        -- Apply ArrDep slots directly
        if template.parameters.slots and #template.parameters.slots > 0 then
            timetable.setConditionType(line, station, "ArrDep")
            for _, slot in ipairs(template.parameters.slots) do
                timetable.addCondition(line, station, {type = "ArrDep", ArrDep = slot})
            end
            return true, "ArrDep template applied"
        else
            return false, "Template has no slots defined"
        end
        
    elseif template.type == "unbunch" then
        -- Apply unbunch constraint
        local interval = options.interval or template.parameters.interval or 300
        timetable.setConditionType(line, station, "debounce")
        timetable.addCondition(line, station, {type = "debounce", debounce = interval})
        return true, "Unbunch template applied"
    end
    
    return false, "Unknown template type"
end

-- Save templates to persistence
function timetableTemplates.saveTemplates()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, err = pcall(function()
        local dataToSave = {
            version = TEMPLATE_DATA_VERSION,
            templates = templates
        }
        
        if commonapi2_persistence_api.set then
            commonapi2_persistence_api.set("timetables_templates", dataToSave)
        elseif commonapi2_persistence_api.save then
            commonapi2_persistence_api.save("timetables_templates", dataToSave)
        elseif commonapi2_persistence_api.write then
            commonapi2_persistence_api.write("timetables_templates", dataToSave)
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

-- Load templates from persistence
function timetableTemplates.loadTemplates()
    if not commonapi2_available or not commonapi2_persistence_api then
        return false, "CommonAPI2 persistence not available"
    end
    
    local success, loadedData = pcall(function()
        if commonapi2_persistence_api.get then
            return commonapi2_persistence_api.get("timetables_templates")
        elseif commonapi2_persistence_api.load then
            return commonapi2_persistence_api.load("timetables_templates")
        elseif commonapi2_persistence_api.read then
            return commonapi2_persistence_api.read("timetables_templates")
        end
        return nil
    end)
    
    if success and loadedData and type(loadedData) == "table" then
        if loadedData.templates then
            templates = loadedData.templates
            return true, nil
        end
    end
    
    return false, "No saved templates found"
end

-- Check if persistence is available
function timetableTemplates.isPersistenceAvailable()
    return commonapi2_available and commonapi2_persistence_api ~= nil
end

-- Auto-save templates if needed
local lastTemplateSaveTime = 0
local TEMPLATE_AUTO_SAVE_INTERVAL = 60 -- Save every 60 seconds

function timetableTemplates.autoSaveIfNeeded(currentTime)
    if not timetableTemplates.isPersistenceAvailable() then
        return false
    end
    
    currentTime = currentTime or timetableHelper.getTime()
    
    if currentTime - lastTemplateSaveTime >= TEMPLATE_AUTO_SAVE_INTERVAL then
        local success, err = timetableTemplates.saveTemplates()
        if success then
            lastTemplateSaveTime = currentTime
            return true
        else
            timetableHelper.logWarn("Template auto-save failed: %s", tostring(err))
            return false
        end
    end
    
    return false
end

-- Register with persistence manager
pcall(function()
    if persistenceManager and persistenceManager.isAvailable() then
        persistenceManager.registerModule("timetable_templates",
            function()
                return {
                    version = TEMPLATE_DATA_VERSION,
                    templates = templates
                }
            end,
            function(data)
                if data and data.templates then
                    templates = data.templates
                    return true
                end
                return false
            end,
            TEMPLATE_DATA_VERSION
        )
    end
end)

-- Load templates on module initialization
pcall(function()
    timetableTemplates.loadTemplates()
end)

return timetableTemplates
