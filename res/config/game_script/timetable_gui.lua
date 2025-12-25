local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"

local gui = require "gui"

local clockstate = nil
local vehicleDepartureDisplay = nil -- Display for vehicle departure info

local menu = {window = nil, lineTableItems = {}, popUp = nil}

local timetableGUI = {}

local UIState = {
    currentlySelectedLineTableIndex = nil ,
    currentlySelectedStationIndex = nil,
    currentlySelectedConstraintType = nil,
    currentlySelectedStationTabStation = nil,
    currentlySelectedDepartureBoardStation = nil,
    currentlySelectedStatisticsLine = nil,
    currentlyEditingTimePeriod = nil
}
local co = nil
local state = nil

local timetableChanged = false
local newTimetableState = {}
local clearConstraintWindowLaterHACK = nil

-- Cache for line frequencies to avoid recalculating every frame
local lineFrequencyCache = {} -- lineID -> {frequency = value, lastUpdate = timestamp}
local cachedLinesList = {} -- Set of line IDs from last update
local lastFrequencyUpdateTime = 0
local FREQUENCY_UPDATE_INTERVAL = 5 -- Update frequencies every 5 seconds

local stationTableScrollOffset
local lineTableScrollOffset
local constraintTableScrollOffset


local UIStrings = {
        arr	= _("arr_i18n"),
		arrival	= _("arrival_i18n"),
		dep	= _("dep_i18n"),
		departure = _("departure_i18n"),
		unbunch_time = _("unbunch_time_i18n"),
		unbunch	= _("unbunch_i18n"),
        auto_unbunch = _("auto_unbunch_i18n"),
		timetable = _("timetable_i18n"),
		timetables = _("timetables_i18n"),
		line = _("line_i18n"),
		lines = _("lines_i18n"),
		min	= _("time_min_i18n"),
		sec	= _("time_sec_i18n"),
		stations = _("stations_i18n"),
		frequency = _("frequency_i18n"),
		journey_time = _("journey_time_i18n"),
		arr_dep	= _("arr_dep_i18n"),
		no_timetable = _("no_timetable_i18n"),
		all	= _("all_i18n"),
		add	= _("add_i18n"),
		none = _("none_i18n"),
		tooltip	= _("tooltip_i18n")
}

local local_styles = {
    zh_CN = "timetable-mono-sc",
    zh_TW = "timetable-mono-tc",
    ja = "timetable-mono-ja",
    kr = "timetable-mono-kr"
}

-------------------------------------------------------------
---------------------- Departure Board Tab -----------------
-------------------------------------------------------------
-- abbreviated prefix: db

function timetableGUI.initDepartureBoardTab()
    -- Station selector on the left
    local stationSelectorScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('StationSelector'), "timetable.departureBoardStationSelector")
    menu.dbStationTable = api.gui.comp.Table.new(1, 'SINGLE')
    stationSelectorScrollArea:setMinimumSize(api.gui.util.Size.new(320, 720))
    stationSelectorScrollArea:setMaximumSize(api.gui.util.Size.new(320, 720))
    stationSelectorScrollArea:setContent(menu.dbStationTable)
    
    menu.dbStationTable:onSelect(function(index)
        if index ~= -1 then
            UIState.currentlySelectedDepartureBoardStation = index
            timetableGUI.dbUpdateDepartures()
            timetableGUI.dbStartPeriodicUpdate()
        end
    end)
    
    UIState.floatingLayoutDepartureBoard:addItem(stationSelectorScrollArea, 0, 0)

    -- Departure board on the right
    local departureBoardScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('DepartureBoard'), "timetable.departureBoard")
    menu.dbDepartureTable = api.gui.comp.Table.new(5, 'NONE')
    menu.dbDepartureTable:setColWidth(0, 30)  -- Line color
    menu.dbDepartureTable:setColWidth(1, 200) -- Line name
    menu.dbDepartureTable:setColWidth(2, 150) -- Destination
    menu.dbDepartureTable:setColWidth(3, 100) -- Scheduled time
    menu.dbDepartureTable:setColWidth(4, 150) -- Status/Delay
    
    -- Header row
    local headerTable = api.gui.comp.Table.new(5, 'NONE')
    headerTable:setColWidth(0, 30)
    headerTable:setColWidth(1, 200)
    headerTable:setColWidth(2, 150)
    headerTable:setColWidth(3, 100)
    headerTable:setColWidth(4, 150)
    headerTable:addRow({
        api.gui.comp.TextView.new(""),
        api.gui.comp.TextView.new("Line"),
        api.gui.comp.TextView.new("Destination"),
        api.gui.comp.TextView.new("Scheduled"),
        api.gui.comp.TextView.new("Status")
    })
    
    local contentWrapper = api.gui.comp.Table.new(1, 'NONE')
    contentWrapper:addRow({headerTable})
    contentWrapper:addRow({menu.dbDepartureTable})
    
    departureBoardScrollArea:setMinimumSize(api.gui.util.Size.new(880, 720))
    departureBoardScrollArea:setMaximumSize(api.gui.util.Size.new(880, 720))
    departureBoardScrollArea:setContent(contentWrapper)
    
    UIState.floatingLayoutDepartureBoard:addItem(departureBoardScrollArea, 1, 0)
    
    -- Initialize station list
    timetableGUI.dbFillStations()
end

-- Fill station selector for departure board
function timetableGUI.dbFillStations()
    if not menu.dbStationTable then return end
    
    menu.dbStationTable:deleteAll()
    local stationNameOrder = {}
    
    -- Get all stations that have timetables
    local stationLinesMap = timetable.getStationLinesMap()
    for stationID, _ in pairs(stationLinesMap) do
        local stationName = timetableHelper.getStationName(stationID)
        if stationName and stationName ~= -1 then
            menu.dbStationTable:addRow({api.gui.comp.TextView.new(tostring(stationName))})
            stationNameOrder[#stationNameOrder + 1] = stationName
        end
    end
    
    local order = timetableHelper.getOrderOfArray(stationNameOrder)
    menu.dbStationTable:setOrder(order)
    
    -- Select first station if available
    if #stationNameOrder > 0 and UIState.currentlySelectedDepartureBoardStation == nil then
        menu.dbStationTable:select(0, true)
        UIState.currentlySelectedDepartureBoardStation = 0
    end
end

-- Start periodic updates for departure board
local dbUpdateComponent = nil
function timetableGUI.dbStartPeriodicUpdate()
    timetableGUI.dbStopPeriodicUpdate() -- Stop any existing update
    
    dbUpdateComponent = api.gui.comp.Component.new("dbUpdateTimer")
    local lastUpdate = 0
    dbUpdateComponent:onStep(function()
        local currentTime = timetableHelper.getTime()
        local settings = require "celmi/timetables/settings"
        local updateInterval = settings.get("departureBoardUpdateInterval")
        if currentTime - lastUpdate >= updateInterval then
            lastUpdate = currentTime
            if UIState.currentlySelectedDepartureBoardStation ~= nil then
                timetableGUI.dbUpdateDepartures()
            end
        end
    end)
    
    -- Add to the departure board layout
    if UIState.floatingLayoutDepartureBoard then
        UIState.floatingLayoutDepartureBoard:addItem(dbUpdateComponent, 0, 0)
    end
end

-- Stop periodic updates for departure board
function timetableGUI.dbStopPeriodicUpdate()
    if dbUpdateComponent and UIState.floatingLayoutDepartureBoard then
        UIState.floatingLayoutDepartureBoard:removeItem(dbUpdateComponent)
        dbUpdateComponent = nil
    end
end

-- Update departure board with current departures
function timetableGUI.dbUpdateDepartures()
    if not menu.dbDepartureTable then return end
    if UIState.currentlySelectedDepartureBoardStation == nil then return end
    
    menu.dbDepartureTable:deleteAll()
    
    -- Get selected station ID
    local stationLinesMap = timetable.getStationLinesMap()
    local stationIndex = 0
    local selectedStationID = nil
    
    for stationID, _ in pairs(stationLinesMap) do
        if stationIndex == UIState.currentlySelectedDepartureBoardStation then
            selectedStationID = stationID
            break
        end
        stationIndex = stationIndex + 1
    end
    
    if not selectedStationID then return end
    
    -- Get next departures
    local currentTime = timetableHelper.getTime()
    local departures = timetable.getNextDepartures(selectedStationID, 10, currentTime)
    
    -- Display departures
    for _, dep in ipairs(departures) do
        -- Line color indicator
        local lineColourTV = api.gui.comp.TextView.new("●")
        lineColourTV:setName("timetable-linecolour-" .. timetableHelper.getLineColour(dep.lineID))
        lineColourTV:setStyleClassList({"timetable-linecolour"})
        
        -- Line name
        local lineName = timetableHelper.getLineName(dep.lineID)
        local lineNameTV = api.gui.comp.TextView.new(lineName)
        
        -- Destination
        local destination = timetable.getDestinationForLineAtStation(dep.lineID, dep.stopNr)
        local destinationTV = api.gui.comp.TextView.new(destination)
        
        -- Scheduled time
        local depMin, depSec = timetable.secToMin(dep.departureTime % 3600)
        local scheduledTimeStr = string.format("%02d:%02d", depMin, depSec)
        local scheduledTimeTV = api.gui.comp.TextView.new(scheduledTimeStr)
        
        -- Status and delay
        local statusStr = ""
        if dep.status == "on_time" then
            statusStr = "On time"
        elseif dep.status == "delayed" then
            local delayMin = math.floor(dep.delay / 60)
            statusStr = string.format("+%d min delay", delayMin)
        elseif dep.status == "early" then
            local earlyMin = math.floor(math.abs(dep.delay) / 60)
            statusStr = string.format("-%d min early", earlyMin)
        end
        local statusTV = api.gui.comp.TextView.new(statusStr)
        
        -- Color-code status (basic implementation - could be enhanced with styles)
        if dep.status == "delayed" then
            -- Could set text color to red if API supports it
        elseif dep.status == "early" then
            -- Could set text color to blue/green if API supports it
        end
        
        menu.dbDepartureTable:addRow({
            lineColourTV,
            lineNameTV,
            destinationTV,
            scheduledTimeTV,
            statusTV
        })
    end
end

-------------------------------------------------------------
---------------------- Statistics Tab -----------------------
-------------------------------------------------------------
-- abbreviated prefix: stats

function timetableGUI.initStatisticsTab()
    -- Line selector on the left
    local lineSelectorScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('StatisticsLineSelector'), "timetable.statisticsLineSelector")
    menu.statsLineTable = api.gui.comp.Table.new(1, 'SINGLE')
    lineSelectorScrollArea:setMinimumSize(api.gui.util.Size.new(320, 720))
    lineSelectorScrollArea:setMaximumSize(api.gui.util.Size.new(320, 720))
    lineSelectorScrollArea:setContent(menu.statsLineTable)
    
    menu.statsLineTable:onSelect(function(index)
        if index ~= -1 then
            UIState.currentlySelectedStatisticsLine = index
            timetableGUI.statsUpdateStatistics()
        end
    end)
    
    UIState.floatingLayoutStatistics:addItem(lineSelectorScrollArea, 0, 0)

    -- Statistics display on the right
    local statisticsScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('StatisticsDisplay'), "timetable.statisticsDisplay")
    menu.statsTable = api.gui.comp.Table.new(1, 'NONE')
    
    statisticsScrollArea:setMinimumSize(api.gui.util.Size.new(880, 720))
    statisticsScrollArea:setMaximumSize(api.gui.util.Size.new(880, 720))
    statisticsScrollArea:setContent(menu.statsTable)
    
    UIState.floatingLayoutStatistics:addItem(statisticsScrollArea, 1, 0)
    
    -- Initialize line list
    timetableGUI.statsFillLines()
end

-- Fill line selector for statistics tab
function timetableGUI.statsFillLines()
    if not menu.statsLineTable then return end
    
    menu.statsLineTable:deleteAll()
    local lineNameOrder = {}
    
    -- Get all lines with timetables enabled
    for line, _ in pairs(timetable.getCachedTimetableLines()) do
        if api.engine.entityExists(line) then
            local lineName = timetableHelper.getLineName(line)
            if lineName and lineName ~= "ERROR" then
                menu.statsLineTable:addRow({api.gui.comp.TextView.new(tostring(lineName))})
                lineNameOrder[#lineNameOrder + 1] = lineName
            end
        end
    end
    
    local order = timetableHelper.getOrderOfArray(lineNameOrder)
    menu.statsLineTable:setOrder(order)
    
    -- Select first line if available
    if #lineNameOrder > 0 and UIState.currentlySelectedStatisticsLine == nil then
        menu.statsLineTable:select(0, true)
        UIState.currentlySelectedStatisticsLine = 0
    end
end

-- Start periodic updates for statistics tab
local statsUpdateComponent = nil
function timetableGUI.statsStartPeriodicUpdate()
    timetableGUI.statsStopPeriodicUpdate() -- Stop any existing update
    
    statsUpdateComponent = api.gui.comp.Component.new("statsUpdateTimer")
    local lastUpdate = 0
    statsUpdateComponent:onStep(function()
        local currentTime = timetableHelper.getTime()
        local settings = require "celmi/timetables/settings"
        local updateInterval = settings.get("statisticsUpdateInterval")
        if currentTime - lastUpdate >= updateInterval then
            lastUpdate = currentTime
            if UIState.currentlySelectedStatisticsLine ~= nil then
                timetableGUI.statsUpdateStatistics()
            end
        end
    end)
    
    -- Add to the statistics layout
    if UIState.floatingLayoutStatistics then
        UIState.floatingLayoutStatistics:addItem(statsUpdateComponent, 0, 0)
    end
end

-- Stop periodic updates for statistics tab
function timetableGUI.statsStopPeriodicUpdate()
    if statsUpdateComponent and UIState.floatingLayoutStatistics then
        UIState.floatingLayoutStatistics:removeItem(statsUpdateComponent)
        statsUpdateComponent = nil
    end
end

-- Update statistics display
function timetableGUI.statsUpdateStatistics()
    if not menu.statsTable then return end
    if UIState.currentlySelectedStatisticsLine == nil then return end
    
    menu.statsTable:deleteAll()
    
    -- Get selected line ID
    local lineIndex = 0
    local selectedLineID = nil
    
    for line, _ in pairs(timetable.getCachedTimetableLines()) do
        if api.engine.entityExists(line) then
            if lineIndex == UIState.currentlySelectedStatisticsLine then
                selectedLineID = line
                break
            end
            lineIndex = lineIndex + 1
        end
    end
    
    if not selectedLineID then return end
    
    local delayTracker = require "celmi/timetables/delay_tracker"
    local timetableObject = timetable.getTimetableObject()
    local lineInfo = timetableObject[selectedLineID]
    
    if not lineInfo or not lineInfo.stations then return end
    
    -- Header
    local headerTable = api.gui.comp.Table.new(5, 'NONE')
    headerTable:setColWidth(0, 40)
    headerTable:setColWidth(1, 200)
    headerTable:setColWidth(2, 150)
    headerTable:setColWidth(3, 150)
    headerTable:setColWidth(4, 200)
    headerTable:addRow({
        api.gui.comp.TextView.new("#"),
        api.gui.comp.TextView.new("Station"),
        api.gui.comp.TextView.new("On-Time %"),
        api.gui.comp.TextView.new("Avg Delay"),
        api.gui.comp.TextView.new("Status")
    })
    menu.statsTable:addRow({headerTable})
    menu.statsTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
    
    -- Get all stations for this line
    local stations = timetableHelper.getAllStations(selectedLineID)
    local stationNumbers = {}
    for k, _ in pairs(stations) do
        table.insert(stationNumbers, k)
    end
    table.sort(stationNumbers)
    
    -- Display statistics for each station
    for _, stationNumber in ipairs(stationNumbers) do
        local stats = delayTracker.getStatistics(selectedLineID, stationNumber)
        
        -- Station number
        local stationNumTV = api.gui.comp.TextView.new(tostring(stationNumber))
        stationNumTV:setName("timetable-stationcolour-" .. timetableHelper.getLineColour(selectedLineID))
        stationNumTV:setStyleClassList({"timetable-stationcolour"})
        
        -- Station name
        local stationID = timetableHelper.getStationID(selectedLineID, stationNumber)
        local stationName = stationID ~= -1 and timetableHelper.getStationName(stationID) or "Unknown"
        local stationNameTV = api.gui.comp.TextView.new(stationName)
        
        -- On-time percentage
        local onTimePercent = string.format("%.1f%%", stats.onTimePercentage)
        local onTimeTV = api.gui.comp.TextView.new(onTimePercent)
        
        -- Average delay
        local avgDelayStr = ""
        if stats.totalCount > 0 then
            local avgDelayMin = math.floor(stats.avgDelay / 60)
            local avgDelaySec = math.floor(stats.avgDelay % 60)
            if stats.avgDelay >= 0 then
                avgDelayStr = string.format("+%02d:%02d", avgDelayMin, avgDelaySec)
            else
                avgDelayStr = string.format("-%02d:%02d", math.abs(avgDelayMin), math.abs(avgDelaySec))
            end
        else
            avgDelayStr = "N/A"
        end
        local avgDelayTV = api.gui.comp.TextView.new(avgDelayStr)
        
        -- Status indicator (color-coded)
        local statusStr = ""
        local statusColor = "green"
        if stats.totalCount == 0 then
            statusStr = "No data"
            statusColor = "gray"
        elseif stats.onTimePercentage >= 90 then
            statusStr = "Excellent"
            statusColor = "green"
        elseif stats.onTimePercentage >= 75 then
            statusStr = "Good"
            statusColor = "yellow"
        elseif stats.onTimePercentage >= 50 then
            statusStr = "Fair"
            statusColor = "orange"
        else
            statusStr = "Poor"
            statusColor = "red"
        end
        local statusTV = api.gui.comp.TextView.new(statusStr)
        -- Note: Actual color styling would need to be done via stylesheet
        
        -- Add row
        local rowTable = api.gui.comp.Table.new(5, 'NONE')
        rowTable:setColWidth(0, 40)
        rowTable:setColWidth(1, 200)
        rowTable:setColWidth(2, 150)
        rowTable:setColWidth(3, 150)
        rowTable:setColWidth(4, 200)
        rowTable:addRow({
            stationNumTV,
            stationNameTV,
            onTimeTV,
            avgDelayTV,
            statusTV
        })
        menu.statsTable:addRow({rowTable})
    end
    
    -- Add summary section
    menu.statsTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
    
    -- Line-level summary
    local lineStats = timetable.getLineStatistics(selectedLineID)
    if lineStats then
        local summaryTable = api.gui.comp.Table.new(2, 'NONE')
        summaryTable:setColWidth(0, 200)
        summaryTable:setColWidth(1, 300)
        
        summaryTable:addRow({
            api.gui.comp.TextView.new("Line On-Time %:"),
            api.gui.comp.TextView.new(string.format("%.1f%%", lineStats.onTimePercentage))
        })
        summaryTable:addRow({
            api.gui.comp.TextView.new("Line Avg Delay:"),
            api.gui.comp.TextView.new(string.format("%.1f min", lineStats.avgDelay / 60))
        })
        summaryTable:addRow({
            api.gui.comp.TextView.new("Total Departures:"),
            api.gui.comp.TextView.new(tostring(lineStats.totalCount))
        })
        
        menu.statsTable:addRow({summaryTable})
    end
    
    -- Delay history section
    menu.statsTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
    local historyHeader = api.gui.comp.TextView.new("Recent Delay History (Last 10)")
    menu.statsTable:addRow({historyHeader})
    
    local historyTable = api.gui.comp.Table.new(4, 'NONE')
    historyTable:setColWidth(0, 40)
    historyTable:setColWidth(1, 200)
    historyTable:setColWidth(2, 150)
    historyTable:setColWidth(3, 200)
    historyTable:addRow({
        api.gui.comp.TextView.new("Station"),
        api.gui.comp.TextView.new("Delay"),
        api.gui.comp.TextView.new("Time"),
        api.gui.comp.TextView.new("Status")
    })
    
    local history = delayTracker.getDelayHistory(10)
    for _, entry in ipairs(history) do
        if entry.line == selectedLineID then
            local stationID = timetableHelper.getStationID(entry.line, entry.station)
            local stationName = stationID ~= -1 and timetableHelper.getStationName(stationID) or "Unknown"
            
            local delayMin = math.floor(entry.delay / 60)
            local delaySec = math.floor(entry.delay % 60)
            local delayStr = ""
            if entry.delay >= 0 then
                delayStr = string.format("+%02d:%02d", delayMin, delaySec)
            else
                delayStr = string.format("-%02d:%02d", math.abs(delayMin), math.abs(delaySec))
            end
            
            local timeStr = timetable.secToStr(entry.time % 3600)
            
            local statusStr = ""
            if math.abs(entry.delay) <= 30 then
                statusStr = "On time"
            elseif entry.delay > 0 then
                statusStr = "Delayed"
            else
                statusStr = "Early"
            end
            
            historyTable:addRow({
                api.gui.comp.TextView.new(stationName),
                api.gui.comp.TextView.new(delayStr),
                api.gui.comp.TextView.new(timeStr),
                api.gui.comp.TextView.new(statusStr)
            })
        end
    end
    
    menu.statsTable:addRow({historyTable})
end

-------------------------------------------------------------
---------------------- stationTab ---------------------------
-------------------------------------------------------------
-- abbreviated prefix: st

function timetableGUI.initStationTab()
    if menu.stationTabScrollArea then UIState.floatingLayoutStationTab:removeItem(menu.scrollArea) end

    --left table
    local stationOverview = api.gui.comp.TextView.new('StationOverview')
    menu.stationTabScrollArea = api.gui.comp.ScrollArea.new(stationOverview, "timetable.stationTabStationOverviewScrollArea")
    menu.stStations = api.gui.comp.Table.new(1, 'SINGLE')
    menu.stationTabScrollArea:setMinimumSize(api.gui.util.Size.new(320, 720))
    menu.stationTabScrollArea:setMaximumSize(api.gui.util.Size.new(320, 720))
    menu.stationTabScrollArea:setContent(menu.stStations)
    timetableGUI.stFillStations()
    UIState.floatingLayoutStationTab:addItem(menu.stationTabScrollArea,0,0)

    menu.stationTabLinesScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('LineOverview'), "timetable.stationTabLinesScrollArea")
    menu.stationTabLinesTable = api.gui.comp.Table.new(1, 'NONE')
    menu.stationTabLinesScrollArea:setMinimumSize(api.gui.util.Size.new(880, 720))
    menu.stationTabLinesScrollArea:setMaximumSize(api.gui.util.Size.new(880, 720))
    -- menu.stationTabLinesTable:setColWidth(0,23)
    -- menu.stationTabLinesTable:setColWidth(1,150)

    menu.stationTabLinesScrollArea:setContent(menu.stationTabLinesTable)
    UIState.floatingLayoutStationTab:addItem(menu.stationTabLinesScrollArea,1,0)
end

-- fills the station table on the left side with all stations that have constraints
function timetableGUI.stFillStations()
    -- list all stations that are part of a timetable 
    timetable.cleanTimetable() -- remove old lines no longer in the game
    timetableChanged = true

    menu.stStations:deleteAll()
    local stationNameOrder = {} -- used to sort the lines by name

    -- add stations from timetable data
    for stationID, stationInfo in pairs(timetable.getConstraintsByStation()) do
        local stationName = timetableHelper.getStationName(stationID)
        if not (stationName == -1) then
            menu.stStations:addRow({api.gui.comp.TextView.new(tostring(stationName))})
            stationNameOrder[#stationNameOrder + 1] = stationName
        end
    end

    local order = timetableHelper.getOrderOfArray(stationNameOrder)
    menu.stStations:setOrder(order)

    menu.stStations:onSelect(timetableGUI.stFillLines)
  
    -- select last station again
    if UIState.currentlySelectedStationTabStation
       and menu.stStations:getNumRows() > UIState.currentlySelectedStationTabStation  then
        menu.stStations:select(UIState.currentlySelectedStationTabStation, true)
    end

end

-- fills the line table on the right side with all lines that stop at the selected station
function timetableGUI.stFillLines(tabIndex)
    -- setting up internationalization
    local lang = api.util.getLanguage()
    local local_style = {local_styles[lang.code]}

    -- resetting line info
    if tabIndex == - 1 then return end
    UIState.currentlySelectedStationTabStation = tabIndex
    menu.stationTabLinesTable:deleteAll()

    -- get station data for tab
    -- since the order is the same, we can use the index to get the data
    local stationData
    local stationIndex = 0
    for stationID, data in pairs(timetable.getConstraintsByStation()) do
        if stationIndex == tabIndex then
            stationData = data
            break
        end
        stationIndex = stationIndex + 1
    end

    -- add stops and lines to table
    local lineNameOrder = {}
    for lineID, lineData in pairs(stationData) do
        for stopNr, stopData in pairs(lineData) do

            -- create container to hold line info
            -- local lineInfoBox =  api.gui.comp.List.new(false, api.gui.util.Orientation.VERTICAL, false)
            local lineInfoBox = api.gui.comp.Table.new(1, 'NONE')

            -- add line name
            local lineColourTV = api.gui.comp.TextView.new("●")
            ---@diagnostic disable-next-line: param-type-mismatch
            lineColourTV:setName("timetable-linecolour-" .. timetableHelper.getLineColour(tonumber(lineID)))
            lineColourTV:setStyleClassList({"timetable-linecolour"})

            local lineName = timetableHelper.getLineName(lineID) .. " - Stop " .. stopNr
            local lineNameTV = api.gui.comp.TextView.new(lineName)

            local lineNameBox = api.gui.comp.Table.new(2, 'NONE')
            lineNameBox:setColWidth(0, 25)
            lineNameBox:addRow({lineColourTV, lineNameTV})

            lineInfoBox:addRow({lineNameBox})


            -- add constraint info
            local type = timetableHelper.conditionToString(stopData.conditions[stopData.conditions.type], lineID, stopData.conditions.type)
            local stConditionString = api.gui.comp.TextView.new(type)
            stConditionString:setName("conditionString")
            stConditionString:setStyleClassList(local_style)

            lineInfoBox:addRow({stConditionString})

             -- add line table
            menu.stationTabLinesTable:addRow({lineInfoBox})
            lineNameOrder[#lineNameOrder + 1] = lineName
        end
    end
    local order = timetableHelper.getOrderOfArray(lineNameOrder)
    menu.stationTabLinesTable:setOrder(order)

end

-------------------------------------------------------------
---------------------- SETUP --------------------------------
-------------------------------------------------------------

function timetableGUI.initLineTable()
    if menu.scrollArea then
        local tmp = menu.scrollArea:getScrollOffset()
        lineTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        UIState.boxlayout2:removeItem(menu.scrollArea)
    else
        lineTableScrollOffset = api.type.Vec2i.new()
    end
    if menu.lineHeader then UIState.boxlayout2:removeItem(menu.lineHeader) end


    menu.scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('LineOverview'), "timetable.LineOverview")
    menu.lineTable = api.gui.comp.Table.new(3, 'SINGLE')
    menu.lineTable:setColWidth(0,28)

    menu.lineTable:onSelect(function(index)
        if not index == -1 then UIState.currentlySelectedLineTableIndex = index end
        UIState.currentlySelectedStationIndex = 0
        timetableGUI.fillStationTable(index, true)
    end)

    menu.lineTable:setColWidth(1,240)

    menu.scrollArea:setMinimumSize(api.gui.util.Size.new(320, 690))
    menu.scrollArea:setMaximumSize(api.gui.util.Size.new(320, 690))
    menu.scrollArea:setContent(menu.lineTable)

    timetableGUI.fillLineTable()

    UIState.boxlayout2:addItem(menu.scrollArea,0,1)
end

function timetableGUI.initStationTable()
    if menu.stationScrollArea then
        local tmp = menu.stationScrollArea:getScrollOffset()
        stationTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
    else
        stationTableScrollOffset = api.type.Vec2i.new()
        menu.stationScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('stationScrollArea'), "timetable.stationScrollArea")
        menu.stationScrollArea:setMinimumSize(api.gui.util.Size.new(560, 730))
        menu.stationScrollArea:setMaximumSize(api.gui.util.Size.new(560, 730))
        UIState.boxlayout2:addItem(menu.stationScrollArea,0.5,0)
    end

    menu.stationTableHeader = api.gui.comp.Table.new(1, 'NONE')
    menu.stationTable = api.gui.comp.Table.new(4, 'SINGLE')
    menu.stationTable:setColWidth(0,40)
    menu.stationTable:setColWidth(1,120)
    menu.stationTableHeader:addRow({menu.stationTable})
    menu.stationScrollArea:setContent(menu.stationTableHeader)
end

function timetableGUI.initConstraintTable()
    if menu.scrollAreaConstraint then
        local tmp = menu.scrollAreaConstraint:getScrollOffset()
        constraintTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
    else
        constraintTableScrollOffset = api.type.Vec2i.new()
        menu.scrollAreaConstraint = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('scrollAreaConstraint'), "timetable.scrollAreaConstraint")
        menu.scrollAreaConstraint:setMinimumSize(api.gui.util.Size.new(320, 730))
        menu.scrollAreaConstraint:setMaximumSize(api.gui.util.Size.new(320, 730))
        UIState.boxlayout2:addItem(menu.scrollAreaConstraint,1,0)
    end

    menu.constraintTable = api.gui.comp.Table.new(1, 'NONE')
    menu.constraintHeaderTable = api.gui.comp.Table.new(1, 'NONE')
    menu.constraintContentTable = api.gui.comp.Table.new(1, 'NONE')
    menu.constraintTable:addRow({menu.constraintHeaderTable})
    menu.constraintTable:addRow({menu.constraintContentTable})
    menu.scrollAreaConstraint:setContent(menu.constraintTable)
end
function timetableGUI.showLineMenu()
    if menu.window ~= nil then
        timetableGUI.initLineTable()
        return menu.window:setVisible(true, true)
    end
    if not api.gui.util.getById('timetable.floatingLayout') then
        local floatingLayout = api.gui.layout.FloatingLayout.new(0,1)
        floatingLayout:setId("timetable.floatingLayout")
    end
    -- new folting layout to arrange all members

    UIState.boxlayout2 = api.gui.util.getById('timetable.floatingLayout')
    UIState.boxlayout2:setGravity(-1,-1)

    timetableGUI.initLineTable()
    timetableGUI.initStationTable()
    timetableGUI.initConstraintTable()
    
    -- Add export/import all buttons to line table header
    timetableGUI.addExportImportButtons()

    -- Setting up Line Tab
    menu.tabWidget = api.gui.comp.TabWidget.new("NORTH")
    local wrapper = api.gui.comp.Component.new("wrapper")
    wrapper:setLayout(UIState.boxlayout2 )
    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.lines), wrapper)


    if not api.gui.util.getById('timetable.floatingLayoutStationTab') then
        local floatingLayout = api.gui.layout.FloatingLayout.new(0,1)
        floatingLayout:setId("timetable.floatingLayoutStationTab")
    end

    UIState.floatingLayoutStationTab = api.gui.util.getById('timetable.floatingLayoutStationTab')
    UIState.floatingLayoutStationTab:setGravity(-1,-1)

    timetableGUI.initStationTab()
    local wrapper2 = api.gui.comp.Component.new("wrapper2")
    wrapper2:setLayout(UIState.floatingLayoutStationTab)
    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.stations),wrapper2)

    -- Add Departure Board tab
    if not api.gui.util.getById('timetable.floatingLayoutDepartureBoard') then
        local floatingLayout = api.gui.layout.FloatingLayout.new(0,1)
        floatingLayout:setId("timetable.floatingLayoutDepartureBoard")
    end
    UIState.floatingLayoutDepartureBoard = api.gui.util.getById('timetable.floatingLayoutDepartureBoard')
    UIState.floatingLayoutDepartureBoard:setGravity(-1,-1)
    
    timetableGUI.initDepartureBoardTab()
    local wrapper3 = api.gui.comp.Component.new("wrapper3")
    wrapper3:setLayout(UIState.floatingLayoutDepartureBoard)
    menu.tabWidget:addTab(api.gui.comp.TextView.new("Departure Board"), wrapper3)

    -- Add Statistics tab
    if not api.gui.util.getById('timetable.floatingLayoutStatistics') then
        local floatingLayout = api.gui.layout.FloatingLayout.new(0,1)
        floatingLayout:setId("timetable.floatingLayoutStatistics")
    end
    UIState.floatingLayoutStatistics = api.gui.util.getById('timetable.floatingLayoutStatistics')
    UIState.floatingLayoutStatistics:setGravity(-1,-1)
    
    timetableGUI.initStatisticsTab()
    local wrapper4 = api.gui.comp.Component.new("wrapper4")
    wrapper4:setLayout(UIState.floatingLayoutStatistics)
    menu.tabWidget:addTab(api.gui.comp.TextView.new("Statistics"), wrapper4)
    
    -- Settings tab
    if not api.gui.util.getById('timetable.floatingLayoutSettings') then
        local floatingLayout = api.gui.layout.FloatingLayout.new(0,1)
        floatingLayout:setId("timetable.floatingLayoutSettings")
    end
    UIState.floatingLayoutSettings = api.gui.util.getById('timetable.floatingLayoutSettings')
    UIState.floatingLayoutSettings:setGravity(-1,-1)
    
    timetableGUI.initSettingsTab()
    
    local wrapper5 = api.gui.comp.Component.new("SettingsWrapper")
    wrapper5:setLayout(UIState.floatingLayoutSettings)
    menu.tabWidget:addTab(api.gui.comp.TextView.new("Settings"), wrapper5)
    
    menu.tabWidget:onCurrentChanged(function(i)
        if i == 1 then
            timetableGUI.stFillStations()
        elseif i == 2 then
            timetableGUI.dbFillStations()
            if UIState.currentlySelectedDepartureBoardStation ~= nil then
                timetableGUI.dbUpdateDepartures()
                -- Set up periodic updates for departure board
                timetableGUI.dbStartPeriodicUpdate()
            end
        elseif i == 3 then
            timetableGUI.statsFillLines()
            timetableGUI.statsStartPeriodicUpdate()
        elseif i == 4 then
            -- Settings tab - no periodic updates needed
        else
            -- Stop periodic updates when not on departure board or statistics tab
            timetableGUI.dbStopPeriodicUpdate()
            timetableGUI.statsStopPeriodicUpdate()
        end
    end)

    -- create final window
    menu.window = api.gui.comp.Window.new(UIStrings.timetables, menu.tabWidget)
    menu.window:addHideOnCloseHandler()
    menu.window:setMovable(true)
    menu.window:setPinButtonVisible(true)
    menu.window:setResizable(false)
    menu.window:setSize(api.gui.util.Size.new(1202, 802))
    menu.window:setPosition(200,200)
    menu.window:onClose(function()
        menu.lineTableItems = {}
    end)

end

-------------------------------------------------------------
---------------------- LEFT TABLE ---------------------------
-------------------------------------------------------------

function timetableGUI.fillLineTable()
    menu.lineTable:deleteRows(0,menu.lineTable:getNumRows())
    if not (menu.lineHeader == nil) then menu.lineHeader:deleteRows(0,menu.lineHeader:getNumRows()) end

    menu.lineHeader = api.gui.comp.Table.new(6, 'None')
    local sortAll   = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(UIStrings.all))
    local sortBus   = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_road_vehicles.tga"))
    local sortTram  = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/TimetableTramIcon.tga"))
    local sortRail  = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_trains.tga"))
    local sortWater = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_ships.tga"))
    local sortAir   = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_planes.tga"))

    menu.lineHeader:addRow({sortAll,sortBus,sortTram,sortRail,sortWater,sortAir})

    local lineNames = {}
    for k,v in pairs(timetableHelper.getAllLines()) do
        local lineColour = api.gui.comp.TextView.new("●")
        lineColour:setName("timetable-linecolour-" .. timetableHelper.getLineColour(v.id))
        lineColour:setStyleClassList({"timetable-linecolour"})
        local lineName = api.gui.comp.TextView.new(v.name)
        lineNames[k] = v.name
        lineName:setName("timetable-linename")
        local buttonImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
        if timetable.hasTimetable(v.id) then buttonImage:setImage("ui/checkbox1.tga", false) end
        local button = api.gui.comp.Button.new(buttonImage, true)
        button:setStyleClassList({"timetable-activateTimetableButton"})
        button:setGravity(1,0.5)
        button:onClick(function()
            local imageView = buttonImage
            local hasTimetable = timetable.hasTimetable(v.id)
            if  hasTimetable then
                timetable.setHasTimetable(v.id,false)
                timetableChanged = true
                imageView:setImage("ui/checkbox0.tga", false)
                -- start all stopped vehicles again if the timetable is disabled for this line
                timetable.restartAutoDepartureForAllLineVehicles(v.id)
            else
                timetable.setHasTimetable(v.id,true)
                timetableChanged = true
                imageView:setImage("ui/checkbox1.tga", false)
            end
        end)
        menu.lineTableItems[#menu.lineTableItems + 1] = {lineColour, lineName, button}
        menu.lineTable:addRow({lineColour,lineName, button})
    end

    local order = timetableHelper.getOrderOfArray(lineNames)
    menu.lineTable:setOrder(order)

    sortAll:onToggle(function()
        for _,v in pairs(menu.lineTableItems) do
                v[1]:setVisible(true,false)
                v[2]:setVisible(true,false)
                v[3]:setVisible(true,false)
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(true,false)
    end)

    sortBus:onToggle(function()
        local linesOfType = timetableHelper.isLineOfType("ROAD")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(true,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end)

    sortTram:onToggle(function()
        local linesOfType = timetableHelper.isLineOfType("TRAM")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(true,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end)

    sortRail:onToggle(function()
        local linesOfType = timetableHelper.isLineOfType("RAIL")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(true,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end)

    sortWater:onToggle(function()
        local linesOfType = timetableHelper.isLineOfType("WATER")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(true,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end)

    sortAir:onToggle(function()
        local linesOfType = timetableHelper.isLineOfType("AIR")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(true,false)
        sortAll:setSelected(false,false)
    end)

    UIState.boxlayout2:addItem(menu.lineHeader,0,0)
    menu.scrollArea:invokeLater( function () 
        menu.scrollArea:invokeLater(function () 
            menu.scrollArea:setScrollOffset(lineTableScrollOffset) 
        end) 
    end)
end

-- Add export/import all buttons
function timetableGUI.addExportImportButtons()
    if not menu.lineHeader then return end
    
    local exportAllButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Export All Timetables"), true)
    exportAllButton:setGravity(1,0)
    exportAllButton:onClick(function()
        if timetable.exportTimetableToClipboard(nil) then
            local exportData = timetable.getExportedClipboard()
            timetableGUI.showExportDialog(exportData, "All Timetables Export")
        else
            timetableGUI.popUpMessage("No timetables to export", function() end)
        end
    end)
    
    local importAllButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Import Timetables"), true)
    importAllButton:setGravity(1,0)
    importAllButton:onClick(function()
        timetableGUI.showImportDialog(nil, false)
    end)
    
    local exportImportRow = api.gui.comp.Table.new(2, 'NONE')
    exportImportRow:addRow({exportAllButton, importAllButton})
    menu.lineHeader:addRow({exportImportRow})
end

-- Show export dialog with data that can be copied
function timetableGUI.showExportDialog(exportData, title)
    if not exportData then return end
    
    -- Create a text view for the export data (read-only display)
    local textArea = api.gui.comp.TextView.new(exportData)
    textArea:setMinimumSize(api.gui.util.Size.new(600, 400))
    textArea:setMaximumSize(api.gui.util.Size.new(800, 500))
    textArea:setName("timetable.exportTextArea")
    -- Make it selectable for copying
    textArea:setSelectable(true)
    
    local okButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("OK"), true)
    okButton:onClick(function()
        if menu.exportWindow then
            menu.exportWindow:close()
            menu.exportWindow = nil
        end
    end)
    
    local infoLabel = api.gui.comp.TextView.new("Select all text (Ctrl+A) and copy (Ctrl+C) to export")
    infoLabel:setMinimumSize(api.gui.util.Size.new(600, 30))
    
    local buttonTable = api.gui.comp.Table.new(1, 'NONE')
    buttonTable:addRow({okButton})
    
    local contentTable = api.gui.comp.Table.new(1, 'NONE')
    contentTable:addRow({infoLabel})
    contentTable:addRow({textArea})
    contentTable:addRow({buttonTable})
    
    menu.exportWindow = api.gui.comp.Window.new(title or "Timetable Export", contentTable)
    menu.exportWindow:addHideOnCloseHandler()
    menu.exportWindow:setMovable(true)
    menu.exportWindow:setResizable(true)
    menu.exportWindow:setSize(api.gui.util.Size.new(800, 500))
    menu.exportWindow:setPosition(200, 200)
end

-- Route generation wizard state
local routeWizardState = {
    step = 1, -- 1=carrier, 2=origin, 3=destination, 4=options, 5=preview, 6=depot, 7=create
    carrierType = nil,
    originStation = nil,
    destinationStation = nil,
    route = nil,
    routeOptions = nil,
    options = {}
}

-- Show route generation wizard
function timetableGUI.showRouteGenerationWizard()
    routeWizardState = {
        step = 1,
        carrierType = nil,
        originStation = nil,
        destinationStation = nil,
        route = nil,
        routeOptions = nil,
        options = {}
    }
    
    timetableGUI.showRouteWizardStep()
end

-- Show current step of route wizard
function timetableGUI.showRouteWizardStep()
    if menu.routeWizardWindow then
        menu.routeWizardWindow:close()
        menu.routeWizardWindow = nil
    end
    
    local routeFinder = require "celmi/timetables/route_finder"
    local contentTable = api.gui.comp.Table.new(1, 'NONE')
    
    if routeWizardState.step == 1 then
        -- Step 1: Select carrier type
        local stepLabel = api.gui.comp.TextView.new("Step 1: Select Transport Type")
        contentTable:addRow({stepLabel})
        
        local carrierLabel = api.gui.comp.TextView.new("Transport Type:")
        carrierLabel:setGravity(1, 0.5)
        local carrierCombo = api.gui.comp.ComboBox.new()
        carrierCombo:addItem("Trains (RAIL)")
        carrierCombo:addItem("Buses (ROAD)")
        carrierCombo:addItem("Trams (TRAM)")
        carrierCombo:setSelected(0, false)
        
        carrierCombo:onIndexChanged(function(index)
            if index == 0 then
                routeWizardState.carrierType = "RAIL"
            elseif index == 1 then
                routeWizardState.carrierType = "ROAD"
            elseif index == 2 then
                routeWizardState.carrierType = "TRAM"
            end
        end)
        
        local carrierTable = api.gui.comp.Table.new(2, 'NONE')
        carrierTable:setColWidth(0, 150)
        carrierTable:addRow({carrierLabel, carrierCombo})
        contentTable:addRow({carrierTable})
        
        local nextButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Next"), true)
        nextButton:onClick(function()
            if routeWizardState.carrierType then
                routeWizardState.step = 2
                timetableGUI.showRouteWizardStep()
            else
                timetableGUI.popUpMessage("Please select a transport type", function() end)
            end
        end)
        contentTable:addRow({nextButton})
        
    elseif routeWizardState.step == 2 then
        -- Step 2: Select origin station
        local stepLabel = api.gui.comp.TextView.new("Step 2: Select Origin Station")
        contentTable:addRow({stepLabel})
        
        local stations = routeFinder.findStations(routeWizardState.carrierType)
        if #stations == 0 then
            local errorMsg = api.gui.comp.TextView.new("No stations found for " .. routeWizardState.carrierType .. " transport.\n\n")
            local errorMsg2 = api.gui.comp.TextView.new("Please create lines with " .. routeWizardState.carrierType .. " vehicles first.")
            contentTable:addRow({errorMsg})
            contentTable:addRow({errorMsg2})
            local backButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Back"), true)
            backButton:onClick(function()
                routeWizardState.step = 1
                timetableGUI.showRouteWizardStep()
            end)
            contentTable:addRow({backButton})
        else
            local originLabel = api.gui.comp.TextView.new("Origin:")
            originLabel:setGravity(1, 0.5)
            local originCombo = api.gui.comp.ComboBox.new()
            for _, station in ipairs(stations) do
                originCombo:addItem(station.name)
            end
            originCombo:setSelected(0, false)
            
            originCombo:onIndexChanged(function(index)
                if stations[index + 1] then
                    routeWizardState.originStation = stations[index + 1].id
                end
            end)
            if stations[1] then
                routeWizardState.originStation = stations[1].id
            end
            
            local originTable = api.gui.comp.Table.new(2, 'NONE')
            originTable:setColWidth(0, 150)
            originTable:addRow({originLabel, originCombo})
            contentTable:addRow({originTable})
            
            local buttonTable = api.gui.comp.Table.new(2, 'NONE')
            local backButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Back"), true)
            backButton:onClick(function()
                routeWizardState.step = 1
                timetableGUI.showRouteWizardStep()
            end)
            local nextButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Next"), true)
            nextButton:onClick(function()
                if routeWizardState.originStation then
                    routeWizardState.step = 3
                    timetableGUI.showRouteWizardStep()
                end
            end)
            buttonTable:addRow({backButton, nextButton})
            contentTable:addRow({buttonTable})
        end
        
    elseif routeWizardState.step == 3 then
        -- Step 3: Select destination station
        local stepLabel = api.gui.comp.TextView.new("Step 3: Select Destination Station")
        contentTable:addRow({stepLabel})
        
        local stations = routeFinder.findStations(routeWizardState.carrierType)
        local destLabel = api.gui.comp.TextView.new("Destination:")
        destLabel:setGravity(1, 0.5)
        local destCombo = api.gui.comp.ComboBox.new()
        for _, station in ipairs(stations) do
            if station.id ~= routeWizardState.originStation then
                destCombo:addItem(station.name)
            end
        end
        destCombo:setSelected(0, false)
        
        local destStations = {}
        for _, station in ipairs(stations) do
            if station.id ~= routeWizardState.originStation then
                table.insert(destStations, station)
            end
        end
        
        destCombo:onIndexChanged(function(index)
            if destStations[index + 1] then
                routeWizardState.destinationStation = destStations[index + 1].id
            end
        end)
        if destStations[1] then
            routeWizardState.destinationStation = destStations[1].id
        end
        
        local destTable = api.gui.comp.Table.new(2, 'NONE')
        destTable:setColWidth(0, 150)
        destTable:addRow({destLabel, destCombo})
        contentTable:addRow({destTable})
        
        local buttonTable = api.gui.comp.Table.new(2, 'NONE')
        local backButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Back"), true)
        backButton:onClick(function()
            routeWizardState.step = 2
            timetableGUI.showRouteWizardStep()
        end)
        local findRouteButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Find Route"), true)
        findRouteButton:onClick(function()
            if routeWizardState.originStation and routeWizardState.destinationStation then
                -- Find route options with traffic analysis
                local routeOptions = routeFinder.findRoutesWithTraffic(
                    routeWizardState.originStation,
                    routeWizardState.destinationStation,
                    routeWizardState.carrierType,
                    3, -- max 3 routes
                    0.5 -- congestion weight
                )
                
                -- Also check for hub-based route option
                local hubRoute = routeFinder.suggestHubRoute(
                    routeWizardState.originStation,
                    routeWizardState.destinationStation,
                    routeWizardState.carrierType
                )
                
                if hubRoute and hubRoute.path then
                    -- Add hub-based route as an option
                    local hubRouteOption = {
                        path = hubRoute.path,
                        type = "hub_based",
                        hub = hubRoute.hub,
                        distance = 0 -- Calculate if needed
                    }
                    -- Calculate distance
                    for i = 1, #hubRouteOption.path - 1 do
                        hubRouteOption.distance = hubRouteOption.distance + routeFinder.calculateStationDistance(
                            hubRouteOption.path[i],
                            hubRouteOption.path[i + 1]
                        )
                    end
                    table.insert(routeOptions, hubRouteOption)
                end
                
                if routeOptions and #routeOptions > 0 then
                    -- Use balanced route by default (or shortest if no balanced)
                    routeWizardState.route = routeOptions[1].path
                    routeWizardState.routeOptions = routeOptions
                    routeWizardState.step = 4
                    timetableGUI.showRouteWizardStep()
                else
                    -- Fallback to basic pathfinding
                    local basicPath = routeFinder.findPath(
                        routeWizardState.originStation,
                        routeWizardState.destinationStation,
                        routeWizardState.carrierType
                    )
                    if basicPath and #basicPath > 0 then
                        routeWizardState.route = basicPath
                        routeWizardState.routeOptions = {{path = basicPath, type = "shortest"}}
                        routeWizardState.step = 4
                        timetableGUI.showRouteWizardStep()
                    else
                        local errorMsg = "No route found between selected stations.\n\n"
                        errorMsg = errorMsg .. "Possible reasons:\n"
                        errorMsg = errorMsg .. "- Stations may not be connected by " .. routeWizardState.carrierType .. " infrastructure\n"
                        errorMsg = errorMsg .. "- No existing lines connect these stations\n"
                        errorMsg = errorMsg .. "- Try selecting different stations or check your network"
                        timetableGUI.popUpMessage(errorMsg, function() end)
                    end
                end
            end
        end)
        buttonTable:addRow({backButton, findRouteButton})
        contentTable:addRow({buttonTable})
        
    elseif routeWizardState.step == 4 then
        -- Step 4: Route preview and options
        local stepLabel = api.gui.comp.TextView.new("Step 4: Route Preview")
        contentTable:addRow({stepLabel})
        
        if routeWizardState.route then
            local preview = routeFinder.getRoutePreview(routeWizardState.route, routeWizardState.carrierType)
            
            -- Show route options if available
            if routeWizardState.routeOptions and #routeWizardState.routeOptions > 0 then
                local optionsLabel = api.gui.comp.TextView.new("Route Options:")
                contentTable:addRow({optionsLabel})
                
                for i, option in ipairs(routeWizardState.routeOptions) do
                    local optionText = ""
                    local numStops = option.path and (#option.path - 1) or 0
                    
                    if option.type == "shortest" then
                        optionText = "Shortest Path: " .. numStops .. " stops, ~" .. math.floor((option.distance or 0) / 100) .. " units"
                    elseif option.type == "balanced" then
                        local congestionStr = option.congestionScore and string.format(" (Congestion: %.0f%%)", option.congestionScore) or ""
                        optionText = "Balanced Route: " .. numStops .. " stops" .. congestionStr
                    elseif option.type == "low_congestion" then
                        local congestionStr = option.congestionScore and string.format(" (Low congestion: %.0f%%)", option.congestionScore) or ""
                        optionText = "Low Congestion: " .. numStops .. " stops" .. congestionStr
                    elseif option.type == "hub_based" then
                        local hubName = option.hub and option.hub.stationName or "Hub"
                        optionText = "Hub-Based Route: " .. numStops .. " stops via " .. hubName .. " (transfer)"
                    elseif option.type == "fewest_stops" then
                        optionText = "Fewest Stops: " .. numStops .. " stops"
                    else
                        optionText = "Route " .. i .. ": " .. numStops .. " stops"
                    end
                    
                    local optionButton = api.gui.comp.Button.new(api.gui.comp.TextView.new(optionText), true)
                    optionButton:setGravity(-1, 0)
                    optionButton:onClick(function()
                        routeWizardState.route = option.path
                        timetableGUI.showRouteWizardStep() -- Refresh to show new route
                    end)
                    contentTable:addRow({optionButton})
                end
            end
            
            local routeInfo = api.gui.comp.TextView.new("Selected Route: " .. (preview and preview.numStations or #routeWizardState.route) .. " stations")
            contentTable:addRow({routeInfo})
            
            -- Show station list
            local stationList = api.gui.comp.TextView.new("Stations:")
            contentTable:addRow({stationList})
            
            for i, stationID in ipairs(routeWizardState.route) do
                local stationName = timetableHelper.getStationName(stationID)
                local stationText = api.gui.comp.TextView.new(tostring(i) .. ". " .. (stationName or "Unknown"))
                contentTable:addRow({stationText})
            end
            
            -- Options
            local optionsLabel = api.gui.comp.TextView.new("Options:")
            contentTable:addRow({optionsLabel})
            
            local autoGenTimetableLabel = api.gui.comp.TextView.new("Auto-generate timetable:")
            autoGenTimetableLabel:setGravity(1, 0.5)
            local autoGenTimetableImage = api.gui.comp.ImageView.new("ui/checkbox1.tga")
            local autoGenTimetableButton = api.gui.comp.Button.new(autoGenTimetableImage, true)
            autoGenTimetableButton:setStyleClassList({"timetable-activateTimetableButton"})
            autoGenTimetableButton:setGravity(0, 0.5)
            routeWizardState.options.autoGenerateTimetable = true
            
            autoGenTimetableButton:onClick(function()
                routeWizardState.options.autoGenerateTimetable = not routeWizardState.options.autoGenerateTimetable
                autoGenTimetableImage:setImage(routeWizardState.options.autoGenerateTimetable and "ui/checkbox1.tga" or "ui/checkbox0.tga", false)
            end)
            
            local optionsTable = api.gui.comp.Table.new(2, 'NONE')
            optionsTable:setColWidth(0, 200)
            optionsTable:addRow({autoGenTimetableLabel, autoGenTimetableButton})
            contentTable:addRow({optionsTable})
            
            local buttonTable = api.gui.comp.Table.new(2, 'NONE')
            local backButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Back"), true)
            backButton:onClick(function()
                routeWizardState.step = 3
                timetableGUI.showRouteWizardStep()
            end)
            local createButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Create Line"), true)
            createButton:onClick(function()
                timetableGUI.createLineFromRoute()
            end)
            buttonTable:addRow({backButton, createButton})
            contentTable:addRow({buttonTable})
        end
    end
    
    menu.routeWizardWindow = api.gui.comp.Window.new("Route Generation Wizard", contentTable)
    menu.routeWizardWindow:addHideOnCloseHandler()
    menu.routeWizardWindow:setMovable(true)
    menu.routeWizardWindow:setResizable(true)
    menu.routeWizardWindow:setSize(api.gui.util.Size.new(600, 500))
    menu.routeWizardWindow:setPosition(300, 200)
end

-- Create line from route (if API supports it, otherwise show instructions)
function timetableGUI.createLineFromRoute()
    if not routeWizardState.route or #routeWizardState.route < 2 then
        timetableGUI.popUpMessage("Invalid route", function() end)
        return
    end
    
    -- Check if game API supports programmatic line creation
    -- For now, show instructions since TPF2 API may not support direct line creation
    local instructions = "Route found! To create the line:\n\n"
    instructions = instructions .. "1. Open the line creation menu in the game\n"
    instructions = instructions .. "2. Select " .. routeWizardState.carrierType .. " transport\n"
    instructions = instructions .. "3. Create line from:\n"
    
    for i, stationID in ipairs(routeWizardState.route) do
        local stationName = timetableHelper.getStationName(stationID)
        instructions = instructions .. "   " .. tostring(i) .. ". " .. (stationName or "Unknown") .. "\n"
    end
    
    instructions = instructions .. "\nAfter creating the line, you can use 'Auto-Generate Timetable' to set up timetables."
    
    timetableGUI.popUpMessage(instructions, function() end)
    
    -- If auto-generate timetable is enabled and line exists, try to find and generate
    if routeWizardState.options.autoGenerateTimetable then
        -- Note: This would require finding the newly created line, which may not be possible
        -- For now, user needs to manually select the line and use auto-generate
    end
    
    -- Close wizard
    if menu.routeWizardWindow then
        menu.routeWizardWindow:close()
        menu.routeWizardWindow = nil
    end
end

-- Show auto-generate timetable dialog
function timetableGUI.showAutoGenerateDialog(lineID)
    -- Create dialog window
    local dialogTable = api.gui.comp.Table.new(2, 'NONE')
    dialogTable:setColWidth(0, 200)
    dialogTable:setColWidth(1, 300)
    
    -- Start time
    local startTimeLabel = api.gui.comp.TextView.new("Start Time (HH:MM):")
    startTimeLabel:setGravity(1, 0.5)
    local startHourSpin = api.gui.comp.DoubleSpinBox.new()
    startHourSpin:setMinimum(0, false)
    startHourSpin:setMaximum(23, false)
    startHourSpin:setValue(6, false) -- Default 06:00
    local startMinSpin = api.gui.comp.DoubleSpinBox.new()
    startMinSpin:setMinimum(0, false)
    startMinSpin:setMaximum(59, false)
    startMinSpin:setValue(0, false)
    local startTimeTable = api.gui.comp.Table.new(3, 'NONE')
    startTimeTable:addRow({startHourSpin, api.gui.comp.TextView.new(":"), startMinSpin})
    
    -- End time
    local endTimeLabel = api.gui.comp.TextView.new("End Time (HH:MM):")
    endTimeLabel:setGravity(1, 0.5)
    local endHourSpin = api.gui.comp.DoubleSpinBox.new()
    endHourSpin:setMinimum(0, false)
    endHourSpin:setMaximum(23, false)
    endHourSpin:setValue(22, false) -- Default 22:00
    local endMinSpin = api.gui.comp.DoubleSpinBox.new()
    endMinSpin:setMinimum(0, false)
    endMinSpin:setMaximum(59, false)
    endMinSpin:setValue(0, false)
    local endTimeTable = api.gui.comp.Table.new(3, 'NONE')
    endTimeTable:addRow({endHourSpin, api.gui.comp.TextView.new(":"), endMinSpin})
    
    -- Dwell time
    local dwellTimeLabel = api.gui.comp.TextView.new("Dwell Time (seconds):")
    dwellTimeLabel:setGravity(1, 0.5)
    local dwellTimeSpin = api.gui.comp.DoubleSpinBox.new()
    dwellTimeSpin:setMinimum(10, false)
    dwellTimeSpin:setMaximum(300, false)
    dwellTimeSpin:setValue(30, false) -- Default 30 seconds
    
    dialogTable:addRow({startTimeLabel, startTimeTable})
    dialogTable:addRow({endTimeLabel, endTimeTable})
    dialogTable:addRow({dwellTimeLabel, dwellTimeSpin})
    
    -- Get default values from settings
    local settings = require "celmi/timetables/settings"
    local genOptions = {
        startHour = settings.get("autoGenDefaultStartHour"),
        startMin = settings.get("autoGenDefaultStartMin"),
        endHour = settings.get("autoGenDefaultEndHour"),
        endMin = settings.get("autoGenDefaultEndMin"),
        dwellTime = settings.get("autoGenDefaultDwellTime")
    }
    
    startHourSpin:onChange(function(value)
        genOptions.startHour = value or 6
    end)
    startMinSpin:onChange(function(value)
        genOptions.startMin = value or 0
    end)
    endHourSpin:onChange(function(value)
        genOptions.endHour = value or 22
    end)
    endMinSpin:onChange(function(value)
        genOptions.endMin = value or 0
    end)
    dwellTimeSpin:onChange(function(value)
        genOptions.dwellTime = value or 30
    end)
    
    -- Buttons
    local generateButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Generate"), true)
    generateButton:onClick(function()
        -- Convert to seconds (within hour: 0-3599)
        local startTime = (genOptions.startHour * 3600 + genOptions.startMin * 60) % 3600
        local endTime = (genOptions.endHour * 3600 + genOptions.endMin * 60) % 3600
        
        -- Handle wrap-around (e.g., 22:00 to 06:00)
        if endTime <= startTime then
            endTime = endTime + 3600 -- Add 24 hours for wrap-around
        end
        
        local success, message = timetable.autoGenerateTimetable(lineID, {
            startTime = startTime,
            endTime = endTime,
            dwellTime = dwellTime
        })
        
        if success then
            timetableChanged = true
            timetableGUI.popUpMessage(message or "Timetable generated successfully", function() end)
            if menu.autoGenWindow then
                menu.autoGenWindow:close()
                menu.autoGenWindow = nil
            end
            -- Refresh UI
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            end
        else
            timetableGUI.popUpMessage("Generation failed: " .. tostring(message), function() end)
        end
    end)
    
    local cancelButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Cancel"), true)
    cancelButton:onClick(function()
        if menu.autoGenWindow then
            menu.autoGenWindow:close()
            menu.autoGenWindow = nil
        end
    end)
    
    local buttonTable = api.gui.comp.Table.new(2, 'NONE')
    buttonTable:addRow({generateButton, cancelButton})
    
    local contentTable = api.gui.comp.Table.new(1, 'NONE')
    contentTable:addRow({dialogTable})
    contentTable:addRow({buttonTable})
    
    menu.autoGenWindow = api.gui.comp.Window.new("Auto-Generate Timetable", contentTable)
    menu.autoGenWindow:addHideOnCloseHandler()
    menu.autoGenWindow:setMovable(true)
    menu.autoGenWindow:setResizable(false)
    menu.autoGenWindow:setSize(api.gui.util.Size.new(550, 250))
    menu.autoGenWindow:setPosition(300, 300)
end

-- Show import dialog
function timetableGUI.showImportDialog(lineID, mergeMode)
    -- Store import data in a variable that can be accessed
    local importDataVar = {text = ""}
    
    -- Create a text view for displaying instructions
    local infoLabel = api.gui.comp.TextView.new("Paste timetable export data below, then click Import")
    infoLabel:setMinimumSize(api.gui.util.Size.new(600, 30))
    
    -- Create a text view for pasting import data (we'll use a workaround)
    -- Since TextView doesn't support editable text directly, we'll use a popup with instructions
    local importButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Import from Clipboard"), true)
    importButton:onClick(function()
        -- Get data from export clipboard if available
        local importText = timetable.getExportedClipboard()
        if not importText or importText == "" then
            timetableGUI.popUpMessage("No data in clipboard. Please export a timetable first, then import it.", function() end)
            return
        end
        
        local success, message = timetable.importTimetable(importText, lineID, mergeMode and "merge" or "replace")
        if success then
            timetableChanged = true
            timetableGUI.popUpMessage(message or "Import successful", function() end)
            if menu.importWindow then
                menu.importWindow:close()
                menu.importWindow = nil
            end
            -- Refresh UI
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initLineTable()
                timetableGUI.initStationTable()
                if UIState.currentlySelectedLineTableIndex then
                    timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                end
            end
        else
            timetableGUI.popUpMessage("Import failed: " .. tostring(message), function() end)
        end
    end)
    
    local cancelButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Cancel"), true)
    cancelButton:onClick(function()
        if menu.importWindow then
            menu.importWindow:close()
            menu.importWindow = nil
        end
    end)
    
    local buttonTable = api.gui.comp.Table.new(2, 'NONE')
    buttonTable:addRow({importButton, cancelButton})
    
    local contentTable = api.gui.comp.Table.new(1, 'NONE')
    contentTable:addRow({infoLabel})
    contentTable:addRow({buttonTable})
    
    local title = lineID and "Import Line Timetable" or "Import All Timetables"
    menu.importWindow = api.gui.comp.Window.new(title, contentTable)
    menu.importWindow:addHideOnCloseHandler()
    menu.importWindow:setMovable(true)
    menu.importWindow:setResizable(false)
    menu.importWindow:setSize(api.gui.util.Size.new(600, 200))
    menu.importWindow:setPosition(200, 200)
end

-------------------------------------------------------------
---------------------- Middle TABLE -------------------------
-------------------------------------------------------------

-- params
-- index: index of currently selected line
-- bool: emit select signal when building table
function timetableGUI.fillStationTable(index, bool)
    local lang = api.util.getLanguage()
    local local_style = {local_styles[lang.code]}

    --initial checks
    if not index then return end
    if not(timetableHelper.getAllLines()[index+1]) or (not menu.stationTable)then return end

    -- initial cleanup
    menu.stationTable:deleteAll()

    UIState.currentlySelectedLineTableIndex = index
    local lineID = timetableHelper.getAllLines()[index+1].id
    local headerTable = timetableGUI.stationTableHeader(lineID)
    menu.stationTableHeader:setHeader({headerTable})

    local stationLegTime = timetableHelper.getLegTimes(lineID)
    --iterate over all stations to display them
    for k, v in pairs(timetableHelper.getAllStations(lineID)) do
        menu.lineImage = {}
        local vehiclePositions = timetableHelper.getTrainLocations(lineID)
        if vehiclePositions[k-1] then
            if vehiclePositions[k-1].atTerminal then
                if vehiclePositions[k-1].countStr == "MANY" then
                    menu.lineImage[k] = api.gui.comp.ImageView.new("ui/timetable_line_train_in_station_many.tga")
                else
                    menu.lineImage[k] = api.gui.comp.ImageView.new("ui/timetable_line_train_in_station.tga")
                end
            else
                if vehiclePositions[k-1].countStr == "MANY" then
                    menu.lineImage[k] = api.gui.comp.ImageView.new("ui/timetable_line_train_en_route_many.tga")
                else
                    menu.lineImage[k] = api.gui.comp.ImageView.new("ui/timetable_line_train_en_route.tga")
                end
            end
        else
            menu.lineImage[k] = api.gui.comp.ImageView.new("ui/timetable_line.tga")
        end
        local x = menu.lineImage[k]
        menu.lineImage[k]:onStep(function()
            if not x then 
                timetableGUI.popUpMessage("Error: Invalid input", function() end)
                return 
            end
            local vehiclePositions2 = timetableHelper.getTrainLocations(lineID)
            if vehiclePositions2[k-1] then
                if vehiclePositions2[k-1].atTerminal then
                    if vehiclePositions2[k-1].countStr == "MANY" then
                        x:setImage("ui/timetable_line_train_in_station_many.tga", false)
                    else
                        x:setImage("ui/timetable_line_train_in_station.tga", false)
                    end
                else
                    if vehiclePositions2[k-1].countStr == "MANY" then
                        x:setImage("ui/timetable_line_train_en_route_many.tga", false)
                    else
                        x:setImage("ui/timetable_line_train_en_route.tga", false)
                    end
                end
            else
                x:setImage("ui/timetable_line.tga", false)
            end
        end)

        local station = timetableHelper.getStation(v)


        local stationNumber = api.gui.comp.TextView.new(tostring(k))

        stationNumber:setStyleClassList({"timetable-stationcolour"})
        stationNumber:setName("timetable-stationcolour-" .. timetableHelper.getLineColour(lineID))
        stationNumber:setMinimumSize(api.gui.util.Size.new(30, 30))


        local stationName = api.gui.comp.TextView.new(station.name)
        stationName:setName("stationName")

        local jurneyTime
        if (stationLegTime and stationLegTime[k]) then
            jurneyTime = api.gui.comp.TextView.new(UIStrings.journey_time .. ": " .. os.date('%M:%S', stationLegTime[k]))
        else
            jurneyTime = api.gui.comp.TextView.new("")
        end
        jurneyTime:setName("conditionString")
        jurneyTime:setStyleClassList(local_style)

        local stationNameTable = api.gui.comp.Table.new(1, 'NONE')
        stationNameTable:addRow({stationName})
        stationNameTable:addRow({jurneyTime})
        stationNameTable:setColWidth(0,120)


        local conditionType = timetable.getConditionType(lineID, k)
        local condStr = timetableHelper.conditionToString(timetable.getConditions(lineID, k, conditionType), lineID, conditionType)
        local conditionString = api.gui.comp.TextView.new(condStr)
        conditionString:setName("conditionString")
        conditionString:setStyleClassList(local_style)

        conditionString:setMinimumSize(api.gui.util.Size.new(360,50))
        conditionString:setMaximumSize(api.gui.util.Size.new(360,50))
        
        -- Add validation warning indicator
        local validation = timetable.getValidationWarnings(lineID, k)
        local warningIndicator = nil
        if validation and not validation.valid then
            local warningIcon = api.gui.comp.ImageView.new("ui/warning_small.tga")
            if not warningIcon then
                -- Fallback to text if icon not available
                warningIcon = api.gui.comp.TextView.new("⚠")
            end
            warningIcon:setTooltip(timetableGUI.formatValidationTooltip(validation))
            warningIndicator = warningIcon
        end
        
        -- Add skip pattern indicator
        local skipIndicator = nil
        local alternatingPattern = timetable.getSkipPattern(lineID, k, "alternating")
        local slotBasedPattern = timetable.getSkipPattern(lineID, k, "slotBased")
        if (alternatingPattern and alternatingPattern.enabled) or (slotBasedPattern and slotBasedPattern.enabled) then
            local skipIcon = api.gui.comp.TextView.new("⏭")
            skipIcon:setTooltip("This stop has skip patterns enabled (express/local service)")
            skipIndicator = skipIcon
        end
        
        -- Create condition row with optional warning and skip indicator
        local conditionRow = api.gui.comp.Table.new(3, 'NONE')
        conditionRow:setColWidth(0, 360)
        conditionRow:setColWidth(1, 30)
        conditionRow:setColWidth(2, 30)
        local rowItems = {conditionString}
        if warningIndicator then
            table.insert(rowItems, warningIndicator)
        else
            table.insert(rowItems, api.gui.comp.TextView.new(""))
        end
        if skipIndicator then
            table.insert(rowItems, skipIndicator)
        else
            table.insert(rowItems, api.gui.comp.TextView.new(""))
        end
        conditionRow:addRow(rowItems)

        menu.stationTable:addRow({stationNumber,stationNameTable, menu.lineImage[k], conditionRow})
    end

    menu.stationTable:onSelect(function (tableIndex)
        if not (tableIndex == -1) then
            UIState.currentlySelectedStationIndex = tableIndex
            timetableGUI.initConstraintTable()
            timetableGUI.fillConstraintTable(tableIndex,lineID)
        end
    end)

    -- keep track of currently selected station and resets if nessesarry
    if UIState.currentlySelectedStationIndex then
        if menu.stationTable:getNumRows() > UIState.currentlySelectedStationIndex and not(menu.stationTable:getNumRows() == 0) then
            menu.stationTable:select(UIState.currentlySelectedStationIndex, bool)
        else
            timetableGUI.initConstraintTable()
        end
    end
    menu.stationScrollArea:invokeLater(function () 
        menu.stationScrollArea:invokeLater(function () 
            menu.stationScrollArea:setScrollOffset(stationTableScrollOffset) 
        end) 
    end)
end

function timetableGUI.stationTableHeader(lineID)
    -- force departure setting
    local forceDepLabel = api.gui.comp.TextView.new("Force departure")
    forceDepLabel:setGravity(1,0.5)
    local forceDepImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
    if timetable.getForceDepartureEnabled(lineID) then forceDepImage:setImage("ui/checkbox1.tga", false) end
    local forceDepButton = api.gui.comp.Button.new(forceDepImage, true)
    forceDepButton:setStyleClassList({"timetable-activateTimetableButton"})
    forceDepButton:setGravity(0,0.5)
    forceDepButton:onClick(function()
        local forceDepEnabled = timetable.getForceDepartureEnabled(lineID)
        if forceDepEnabled then
            timetable.setForceDepartureEnabled(lineID, false)
            forceDepImage:setImage("ui/checkbox0.tga", false)
        else
            timetable.setForceDepartureEnabled(lineID, true)
            forceDepImage:setImage("ui/checkbox1.tga", false)
        end
        timetableChanged = true
    end)

    -- minimum wait setting
    local minButtonLabel = api.gui.comp.TextView.new("Min. wait enabled")
    minButtonLabel:setGravity(1,0.5)
    local minButtonImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
    if timetable.getMinWaitEnabled(lineID) then minButtonImage:setImage("ui/checkbox1.tga", false) end
    local minButton = api.gui.comp.Button.new(minButtonImage, true)
    minButton:setStyleClassList({"timetable-activateTimetableButton"})
    minButton:setGravity(0,0.5)
    minButton:onClick(function()
        local minEnabled = timetable.getMinWaitEnabled(lineID)
        if minEnabled then
            timetable.setMinWaitEnabled(lineID, false)
            minButtonImage:setImage("ui/checkbox0.tga", false)
        else
            timetable.setMinWaitEnabled(lineID, true)
            minButtonImage:setImage("ui/checkbox1.tga", false)
        end
        timetableChanged = true
    end)

    -- maximum wait setting
    local maxButtonLabel = api.gui.comp.TextView.new("Max. wait enabled")
    maxButtonLabel:setGravity(1,0.5)
    local maxButtonImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
    if timetable.getMaxWaitEnabled(lineID) then maxButtonImage:setImage("ui/checkbox1.tga", false) end
    local maxButton = api.gui.comp.Button.new(maxButtonImage, true)
    maxButton:setStyleClassList({"timetable-activateTimetableButton"})
    maxButton:setGravity(0,0.5)
    maxButton:onClick(function()
        local maxEnabled = timetable.getMaxWaitEnabled(lineID)
        if maxEnabled then
            timetable.setMaxWaitEnabled(lineID, false)
            maxButtonImage:setImage("ui/checkbox0.tga", false)
        else
            timetable.setMaxWaitEnabled(lineID, true)
            maxButtonImage:setImage("ui/checkbox1.tga", false)
        end
        timetableChanged = true
    end)

    -- Copy/Paste line timetable buttons
    local copyLineButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Copy Line"), true)
    copyLineButton:setGravity(-1,0)
    copyLineButton:onClick(function()
        if timetable.copyLineTimetable(lineID) then
            timetableGUI.popUpMessage("Line timetable copied to clipboard", function() end)
        else
            timetableGUI.popUpMessage("No timetable to copy", function() end)
        end
    end)
    
    local pasteLineButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Paste Line"), true)
    pasteLineButton:setGravity(-1,0)
    pasteLineButton:setEnabled(timetable.hasClipboard())
    pasteLineButton:onClick(function()
        if timetable.pasteLineTimetable(lineID) then
            timetableChanged = true
            timetableGUI.popUpMessage("Line timetable pasted", function() end)
            -- Refresh station table to show changes
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            end
        else
            timetableGUI.popUpMessage("Nothing to paste", function() end)
        end
    end)
    
    -- Export/Import line timetable buttons
    local exportLineButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Export Line"), true)
    exportLineButton:setGravity(-1,0)
    exportLineButton:onClick(function()
        if timetable.exportTimetableToClipboard(lineID) then
            local exportData = timetable.getExportedClipboard()
            -- Show export data in a popup (user can copy it)
            timetableGUI.showExportDialog(exportData, "Line Timetable Export")
        else
            timetableGUI.popUpMessage("No timetable to export", function() end)
        end
    end)
    
    local importLineButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Import Line"), true)
    importLineButton:setGravity(-1,0)
    importLineButton:onClick(function()
        timetableGUI.showImportDialog(lineID, false)
    end)

    local headerTable = api.gui.comp.Table.new(7, 'None')
    headerTable:addRow({
        api.gui.comp.TextView.new(UIStrings.frequency .. " " .. timetableHelper.getFrequencyString(lineID)),
        forceDepLabel, forceDepButton, minButtonLabel, minButton, maxButtonLabel, maxButton
    })
    
    -- Add copy/paste and export/import line buttons on second row
    local copyPasteRow = api.gui.comp.Table.new(4, 'None')
    copyPasteRow:addRow({copyLineButton, pasteLineButton, exportLineButton, importLineButton})
    headerTable:addRow({copyPasteRow})
    
    -- Add auto-generate timetable button
    local autoGenButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Auto-Generate Timetable"), true)
    autoGenButton:setGravity(-1,0)
    autoGenButton:onClick(function()
        timetableGUI.showAutoGenerateDialog(lineID)
    end)
    
    -- Add route generation button (for creating new lines)
    local routeGenButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Generate Route & Line"), true)
    routeGenButton:setGravity(-1,0)
    routeGenButton:onClick(function()
        timetableGUI.showRouteGenerationWizard()
    end)
    
    local autoGenRow = api.gui.comp.Table.new(2, 'None')
    autoGenRow:addRow({autoGenButton, routeGenButton})
    headerTable:addRow({autoGenRow})

    return headerTable
end

-- Format validation warnings as tooltip text
function timetableGUI.formatValidationTooltip(validation)
    if not validation or validation.valid then
        return ""
    end
    
    local tooltipLines = {"Validation Warnings:"}
    for _, warning in ipairs(validation.warnings) do
        local severityIcon = warning.severity == "high" and "🔴" or (warning.severity == "medium" and "🟡" or "🟢")
        table.insert(tooltipLines, severityIcon .. " " .. warning.message)
    end
    
    if #validation.suggestions > 0 then
        table.insert(tooltipLines, "")
        table.insert(tooltipLines, "Suggestions:")
        for _, suggestion in ipairs(validation.suggestions) do
            table.insert(tooltipLines, "• " .. suggestion)
        end
    end
    
    return table.concat(tooltipLines, "\n")
end

-- Add validation warnings display to constraint window
function timetableGUI.addValidationWarnings(lineID, stationID, validation, constraintHeaderTable)
    if not constraintHeaderTable or not validation or validation.valid then
        return
    end
    
    -- Count warnings by severity
    local highCount = 0
    local mediumCount = 0
    local lowCount = 0
    for _, warning in ipairs(validation.warnings) do
        if warning.severity == "high" then
            highCount = highCount + 1
        elseif warning.severity == "medium" then
            mediumCount = mediumCount + 1
        else
            lowCount = lowCount + 1
        end
    end
    
    -- Warning header
    local warningHeader = api.gui.comp.TextView.new("⚠ Timetable Validation Warnings")
    warningHeader:setMinimumSize(api.gui.util.Size.new(400, 30))
    
    -- Warning summary
    local summaryText = string.format("High: %d, Medium: %d, Low: %d", highCount, mediumCount, lowCount)
    local warningSummary = api.gui.comp.TextView.new(summaryText)
    
    -- Warning details (show first few)
    local warningsTable = api.gui.comp.Table.new(1, 'NONE')
    local maxWarningsToShow = 5
    for i = 1, math.min(maxWarningsToShow, #validation.warnings) do
        local warning = validation.warnings[i]
        local severityIcon = warning.severity == "high" and "🔴" or (warning.severity == "medium" and "🟡" or "🟢")
        local warningText = severityIcon .. " " .. warning.message
        if warning.slotIndex then
            warningText = warningText .. " (Slot " .. warning.slotIndex .. ")"
        end
        if warning.periodIndex then
            warningText = warningText .. " (Period " .. warning.periodIndex .. ")"
        end
        local warningTV = api.gui.comp.TextView.new(warningText)
        warningTV:setMinimumSize(api.gui.util.Size.new(500, 25))
        warningsTable:addRow({warningTV})
    end
    
    if #validation.warnings > maxWarningsToShow then
        local moreWarnings = api.gui.comp.TextView.new("... and " .. (#validation.warnings - maxWarningsToShow) .. " more")
        warningsTable:addRow({moreWarnings})
    end
    
    -- Suggestions
    if #validation.suggestions > 0 then
        warningsTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
        local suggestionsHeader = api.gui.comp.TextView.new("Suggestions:")
        warningsTable:addRow({suggestionsHeader})
        for _, suggestion in ipairs(validation.suggestions) do
            local suggestionTV = api.gui.comp.TextView.new("• " .. suggestion)
            suggestionTV:setMinimumSize(api.gui.util.Size.new(500, 20))
            warningsTable:addRow({suggestionTV})
        end
    end
    
    local warningsContainer = api.gui.comp.Table.new(1, 'NONE')
    warningsContainer:addRow({warningHeader})
    warningsContainer:addRow({warningSummary})
    warningsContainer:addRow({warningsTable})
    
    constraintHeaderTable:addRow({warningsContainer})
    constraintHeaderTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
end

-- Add skip pattern controls to constraint window
function timetableGUI.addSkipPatternControls(lineID, stationID, constraintHeaderTable)
    if not constraintHeaderTable then return end
    
    -- Skip pattern toggle
    local skipPatternLabel = api.gui.comp.TextView.new("Express/Local Patterns:")
    skipPatternLabel:setGravity(1, 0.5)
    local skipPatternImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
    local slotBasedPattern = timetable.getSkipPattern(lineID, stationID, "slotBased")
    local alternatingPattern = timetable.getSkipPattern(lineID, stationID, "alternating")
    local hasSkipPatterns = (slotBasedPattern and slotBasedPattern.enabled) or 
                            (alternatingPattern and alternatingPattern.enabled)
    if hasSkipPatterns then
        skipPatternImage:setImage("ui/checkbox1.tga", false)
    end
    local skipPatternToggle = api.gui.comp.Button.new(skipPatternImage, true)
    skipPatternToggle:setStyleClassList({"timetable-activateTimetableButton"})
    skipPatternToggle:setGravity(0, 0.5)
    skipPatternToggle:onClick(function()
        local currentState = hasSkipPatterns
        if currentState then
            -- Disable skip patterns
            if slotBasedPattern then
                slotBasedPattern.enabled = false
            end
            if alternatingPattern then
                alternatingPattern.enabled = false
            end
        else
            -- Enable skip patterns (default: alternating pattern)
            timetable.setSkipPattern(lineID, stationID, "alternating", {
                enabled = true,
                pattern = "A-B"
            })
        end
        timetableChanged = true
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
        end
    end)
    
    local skipPatternToggleTable = api.gui.comp.Table.new(2, 'NONE')
    skipPatternToggleTable:setColWidth(0, 200)
    skipPatternToggleTable:addRow({skipPatternLabel, skipPatternToggle})
    constraintHeaderTable:addRow({skipPatternToggleTable})
    
    -- Show skip pattern options if enabled
    if hasSkipPatterns then
        -- Alternating pattern selector
        local altPatternLabel = api.gui.comp.TextView.new("Alternating Pattern:")
        altPatternLabel:setGravity(1, 0.5)
        local altPatternCombo = api.gui.comp.ComboBox.new()
        altPatternCombo:addItem("Every other vehicle (A-B)")
        altPatternCombo:addItem("Reverse (B-A)")
        
        if alternatingPattern and alternatingPattern.pattern == "B-A" then
            altPatternCombo:setSelected(1, false)
        else
            altPatternCombo:setSelected(0, false)
        end
        
        altPatternCombo:onIndexChanged(function(index)
            if index == 0 then
                timetable.setSkipPattern(lineID, stationID, "alternating", {
                    enabled = true,
                    pattern = "A-B"
                })
            else
                timetable.setSkipPattern(lineID, stationID, "alternating", {
                    enabled = true,
                    pattern = "B-A"
                })
            end
            timetableChanged = true
        end)
        
        local altPatternTable = api.gui.comp.Table.new(2, 'NONE')
        altPatternTable:setColWidth(0, 200)
        altPatternTable:addRow({altPatternLabel, altPatternCombo})
        constraintHeaderTable:addRow({altPatternTable})
        
        -- Info text
        local infoText = api.gui.comp.TextView.new("Note: Skip patterns allow vehicles to bypass stops. Alternating pattern makes every other vehicle skip this stop.")
        infoText:setMinimumSize(api.gui.util.Size.new(500, 40))
        constraintHeaderTable:addRow({infoText})
    end
    
    constraintHeaderTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
end

-- Add delay tolerance controls to constraint window header
function timetableGUI.addDelayToleranceControls(lineID, stationID, constraintHeaderTable)
    if not constraintHeaderTable then return end
    
    -- Delay tolerance enabled checkbox
    local delayTolLabel = api.gui.comp.TextView.new("Max delay tolerance enabled")
    delayTolLabel:setGravity(1, 0.5)
    local delayTolImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
    if timetable.getMaxDelayToleranceEnabled(lineID, stationID) then
        delayTolImage:setImage("ui/checkbox1.tga", false)
    end
    local delayTolButton = api.gui.comp.Button.new(delayTolImage, true)
    delayTolButton:setStyleClassList({"timetable-activateTimetableButton"})
    delayTolButton:setGravity(0, 0.5)
    delayTolButton:onClick(function()
        local delayTolEnabled = timetable.getMaxDelayToleranceEnabled(lineID, stationID)
        local newValue = not delayTolEnabled
        timetable.setMaxDelayToleranceEnabled(lineID, stationID, newValue)
        delayTolImage:setImage(newValue and "ui/checkbox1.tga" or "ui/checkbox0.tga", false)
        
        -- Set default tolerance if enabling and not already set (5 minutes = 300 seconds)
        if newValue and not timetable.getMaxDelayTolerance(lineID, stationID) then
            timetable.setMaxDelayTolerance(lineID, stationID, 300)
        end
        
        timetableChanged = true
        
        -- Update visibility of tolerance value inputs
        delayTolValueLabel:setVisible(newValue, false)
        delayTolMinSpin:setVisible(newValue, false)
        delayTolSeparator:setVisible(newValue, false)
        delayTolSecSpin:setVisible(newValue, false)
        
        -- Refresh constraint window to update values
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
        end
    end)
    
    -- Delay tolerance value input (in minutes, displayed as min:sec)
    local delayTolValueLabel = api.gui.comp.TextView.new("Tolerance (min:sec):")
    delayTolValueLabel:setGravity(1, 0.5)
    delayTolValueLabel:setVisible(timetable.getMaxDelayToleranceEnabled(lineID, stationID), false)
    
    local delayTolValue = timetable.getMaxDelayTolerance(lineID, stationID) or 300 -- Default: 5 minutes
    local delayTolMin = math.floor(delayTolValue / 60)
    local delayTolSec = delayTolValue % 60
    
    local delayTolMinSpin = api.gui.comp.DoubleSpinBox.new()
    delayTolMinSpin:setMinimum(0, false)
    delayTolMinSpin:setMaximum(59, false)
    delayTolMinSpin:setValue(delayTolMin, false)
    delayTolMinSpin:setVisible(timetable.getMaxDelayToleranceEnabled(lineID, stationID), false)
    delayTolMinSpin:onChange(function(value)
        local currentValue = timetable.getMaxDelayTolerance(lineID, stationID) or 300
        local currentSec = currentValue % 60
        timetable.setMaxDelayTolerance(lineID, stationID, value * 60 + currentSec)
        timetableChanged = true
    end)
    
    local delayTolSeparator = api.gui.comp.TextView.new(":")
    delayTolSeparator:setVisible(timetable.getMaxDelayToleranceEnabled(lineID, stationID), false)
    
    local delayTolSecSpin = api.gui.comp.DoubleSpinBox.new()
    delayTolSecSpin:setMinimum(0, false)
    delayTolSecSpin:setMaximum(59, false)
    delayTolSecSpin:setValue(delayTolSec, false)
    delayTolSecSpin:setVisible(timetable.getMaxDelayToleranceEnabled(lineID, stationID), false)
    delayTolSecSpin:onChange(function(value)
        local currentValue = timetable.getMaxDelayTolerance(lineID, stationID) or 300
        local currentMin = math.floor(currentValue / 60)
        timetable.setMaxDelayTolerance(lineID, stationID, currentMin * 60 + value)
        timetableChanged = true
    end)
    
    local delayTolTable = api.gui.comp.Table.new(5, 'NONE')
    delayTolTable:setColWidth(0, 150)
    delayTolTable:setColWidth(1, 60)
    delayTolTable:setColWidth(2, 25)
    delayTolTable:setColWidth(3, 60)
    delayTolTable:addRow({delayTolLabel, delayTolButton})
    delayTolTable:addRow({delayTolValueLabel, delayTolMinSpin, delayTolSeparator, delayTolSecSpin})
    
    constraintHeaderTable:addRow({delayTolTable})
end

-- Add delay recovery strategy controls to constraint window header
function timetableGUI.addDelayRecoveryControls(lineID, stationID, constraintHeaderTable)
    if not constraintHeaderTable then return end
    
    -- Delay recovery mode selector
    local recoveryLabel = api.gui.comp.TextView.new("Delay Recovery Mode:")
    recoveryLabel:setGravity(1, 0.5)
    
    local recoveryCombo = api.gui.comp.ComboBox.new()
    recoveryCombo:addItem("Catch Up (try to return to schedule)")
    recoveryCombo:addItem("Skip to Next (abandon current slot)")
    recoveryCombo:addItem("Hold at Terminus (wait longer at end stations)")
    recoveryCombo:addItem("Gradual Recovery (slowly return over multiple stops)")
    
    -- Get current recovery mode
    local currentMode = timetable.getDelayRecoveryMode(lineID, stationID)
    local modeIndex = 0
    if currentMode == "skip_to_next" then
        modeIndex = 1
    elseif currentMode == "hold_at_terminus" then
        modeIndex = 2
    elseif currentMode == "gradual_recovery" then
        modeIndex = 3
    end
    recoveryCombo:setSelected(modeIndex, false)
    
    recoveryCombo:onIndexChanged(function(index)
        local mode = "catch_up"
        if index == 1 then
            mode = "skip_to_next"
        elseif index == 2 then
            mode = "hold_at_terminus"
        elseif index == 3 then
            mode = "gradual_recovery"
        end
        timetable.setDelayRecoveryMode(lineID, stationID, mode)
        timetableChanged = true
    end)
    
    local recoveryTable = api.gui.comp.Table.new(2, 'NONE')
    recoveryTable:setColWidth(0, 200)
    recoveryTable:addRow({recoveryLabel, recoveryCombo})
    constraintHeaderTable:addRow({recoveryTable})
    
    -- Line-level recovery mode (optional override)
    local lineRecoveryLabel = api.gui.comp.TextView.new("Line-Level Recovery Mode (optional):")
    lineRecoveryLabel:setGravity(1, 0.5)
    
    local lineRecoveryCombo = api.gui.comp.ComboBox.new()
    lineRecoveryCombo:addItem("Use Station Setting")
    lineRecoveryCombo:addItem("Catch Up")
    lineRecoveryCombo:addItem("Skip to Next")
    lineRecoveryCombo:addItem("Hold at Terminus")
    lineRecoveryCombo:addItem("Gradual Recovery")
    
    local lineMode = timetable.getLineDelayRecoveryMode(lineID)
    local lineModeIndex = 0
    if lineMode == "skip_to_next" then
        lineModeIndex = 2
    elseif lineMode == "hold_at_terminus" then
        lineModeIndex = 3
    elseif lineMode == "gradual_recovery" then
        lineModeIndex = 4
    elseif lineMode then
        lineModeIndex = 1 -- Catch Up
    end
    lineRecoveryCombo:setSelected(lineModeIndex, false)
    
    lineRecoveryCombo:onIndexChanged(function(index)
        local mode = nil
        if index == 1 then
            mode = "catch_up"
        elseif index == 2 then
            mode = "skip_to_next"
        elseif index == 3 then
            mode = "hold_at_terminus"
        elseif index == 4 then
            mode = "gradual_recovery"
        end
        timetable.setLineDelayRecoveryMode(lineID, mode)
        timetableChanged = true
    end)
    
    local lineRecoveryTable = api.gui.comp.Table.new(2, 'NONE')
    lineRecoveryTable:setColWidth(0, 200)
    lineRecoveryTable:addRow({lineRecoveryLabel, lineRecoveryCombo})
    constraintHeaderTable:addRow({lineRecoveryTable})
end

-------------------------------------------------------------
---------------------- Right TABLE --------------------------
-------------------------------------------------------------

function timetableGUI.clearConstraintWindow()
    -- initial cleanup
    menu.constraintHeaderTable:deleteRows(1, menu.constraintHeaderTable:getNumRows())
end

function timetableGUI.fillConstraintTable(index,lineID)
    --initial cleanup
    if index == -1 then
        menu.constraintHeaderTable:deleteAll()
        return
    end
    index = index + 1
    menu.constraintHeaderTable:deleteAll()
    
    -- Add validation warnings display
    local conditionType = timetable.getConditionType(lineID, index)
    if conditionType == "ArrDep" then
        local validation = timetable.getValidationWarnings(lineID, index)
        if validation and not validation.valid then
            timetableGUI.addValidationWarnings(lineID, index, validation, menu.constraintHeaderTable)
        end
    end
    
    -- Add delay tolerance controls for ArrDep mode
    if conditionType == "ArrDep" then
        timetableGUI.addDelayToleranceControls(lineID, index, menu.constraintHeaderTable)
        timetableGUI.addDelayRecoveryControls(lineID, index, menu.constraintHeaderTable)
    end


    -- combobox setup
    local comboBox = api.gui.comp.ComboBox.new()
    comboBox:addItem(UIStrings.no_timetable)
    comboBox:addItem(UIStrings.arr_dep)
    --comboBox:addItem("Minimum Wait")
    comboBox:addItem(UIStrings.unbunch)
    comboBox:addItem(UIStrings.auto_unbunch)
    --comboBox:addItem("Every X minutes")
    comboBox:setGravity(1,0)

    UIState.currentlySelectedConstraintType = timetableHelper.constraintStringToInt(timetable.getConditionType(lineID, index))


    comboBox:onIndexChanged(function (i)
        if not api.engine.entityExists(lineID) then 
            return
        end
        if i == -1 then return end
        local constraintType = timetableHelper.constraintIntToString(i)
        timetable.setConditionType(lineID, index, constraintType)
        conditions = timetable.getConditions(lineID, index, constraintType)
        if conditions == -1 then return end
        if constraintType == "debounce" then
            if not conditions[1] then conditions[1] = 0 end
            if not conditions[2] then conditions[2] = 0 end
        elseif constraintType == "auto_debounce" then
            if not conditions[1] then conditions[1] = 1 end
            if not conditions[2] then conditions[2] = 0 end
        end

        if i ~= UIState.currentlySelectedConstraintType then
            timetableChanged = true
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            UIState.currentlySelectedConstraintType = i
        end

        timetableGUI.clearConstraintWindow()
        menu.constraintContentTable:deleteAll()
        if i == 1 then
            timetableGUI.makeArrDepWindow(lineID, index)
        elseif i == 2 then
            timetableGUI.makeDebounceWindow(lineID, index, "debounce")
        elseif i == 3 then
            timetableGUI.makeDebounceWindow(lineID, index, "auto_debounce")
        end
        
        -- Update paste button enabled state when constraint type changes
        -- (This is handled within each window function, but we could add a refresh here if needed)
    end)


    local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
    infoImage:setTooltip(UIStrings.tooltip)
    infoImage:setName("timetable-info-icon")

    local table = api.gui.comp.Table.new(2, 'NONE')
    table:addRow({infoImage,comboBox})
    menu.constraintHeaderTable:addRow({table})
    comboBox:setSelected(UIState.currentlySelectedConstraintType, true)
    menu.scrollAreaConstraint:invokeLater(function ()
        menu.scrollAreaConstraint:invokeLater(function () 
            menu.scrollAreaConstraint:setScrollOffset(constraintTableScrollOffset) 
        end) 
    end)
end

function timetableGUI.makeArrDepWindow(lineID, stationID)
    if not menu.constraintTable then return end
    if not menu.constraintHeaderTable then return end

    -- Skip pattern management (for express/local patterns)
    timetableGUI.addSkipPatternControls(lineID, stationID, menu.constraintHeaderTable)
    
    -- Time period management (for time-based conditional timetables)
    local hasTimePeriods = timetable.hasTimePeriods(lineID, stationID)
    
    -- Toggle time periods button
    local timePeriodToggleLabel = api.gui.comp.TextView.new("Time-Based Timetables:")
    timePeriodToggleLabel:setGravity(1, 0.5)
    local timePeriodToggleImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
    if hasTimePeriods then
        timePeriodToggleImage:setImage("ui/checkbox1.tga", false)
    end
    local timePeriodToggleButton = api.gui.comp.Button.new(timePeriodToggleImage, true)
    timePeriodToggleButton:setStyleClassList({"timetable-activateTimetableButton"})
    timePeriodToggleButton:setGravity(0, 0.5)
    timePeriodToggleButton:onClick(function()
        local currentState = timetable.hasTimePeriods(lineID, stationID)
        if currentState then
            -- Disable time periods: convert to legacy format
            local periods = timetable.getTimePeriods(lineID, stationID)
            if periods and #periods > 0 then
                -- Use first period's slots as default
                local conditions = timetable.getConditions(lineID, stationID, "ArrDep")
                if conditions ~= -1 then
                    timetable.removeAllConditions(lineID, stationID, "ArrDep")
                    if periods[1].slots and #periods[1].slots > 0 then
                        timetable.addCondition(lineID, stationID, {
                            type = "ArrDep",
                            ArrDep = periods[1].slots
                        })
                    end
                end
            end
        else
            -- Enable time periods: convert current slots to a time period
            local conditions = timetable.getConditions(lineID, stationID, "ArrDep")
            if conditions ~= -1 and #conditions > 0 then
                timetable.removeAllConditions(lineID, stationID, "ArrDep")
                timetable.addCondition(lineID, stationID, {
                    type = "ArrDep",
                    ArrDep = {timePeriods = {}}
                })
                -- Add default time period covering whole hour
                timetable.addTimePeriod(lineID, stationID, 0, 3600, conditions)
            end
        end
        timetableChanged = true
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
        end
    end)
    
    local timePeriodToggleTable = api.gui.comp.Table.new(2, 'NONE')
    timePeriodToggleTable:setColWidth(0, 200)
    timePeriodToggleTable:addRow({timePeriodToggleLabel, timePeriodToggleButton})
    menu.constraintHeaderTable:addRow({timePeriodToggleTable})
    
    -- Time period list (if time periods are enabled)
    if hasTimePeriods then
        timetableGUI.makeTimePeriodEditor(lineID, stationID)
    end

    -- setup separation selector
    local separationList = {30, 20, 15, 12, 10, 7.5, 6, 5, 4, 3, 2.5, 2, 1.5, 1.2, 1}
    local separationCombo = api.gui.comp.ComboBox.new()
    for k,v in ipairs(separationList) do 
        separationCombo:addItem(v .. " min (" .. 60 / v .. "/h)")
    end
    separationCombo:setGravity(1,0)
    
    -- setup generate button
    local generate = function(separationIndex, templateArrDep)
        if separationIndex  == -1 then return end
        if templateArrDep  == -1 then return end

        -- generate recurring conditions
        local separation = separationList[separationIndex + 1]
        for i = 1, 60 / separation - 1 do
            timetable.addCondition(lineID,stationID, {type = "ArrDep", ArrDep = {timetable.shiftSlot(templateArrDep, i * separation * 60)}})
        end

        -- cleanup
        timetableChanged = true
		clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
		end
    end
    local generateButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Generate"), true)
    generateButton:setGravity(1, 0)
    generateButton:onClick(function()
        -- preparation
        local conditions = timetable.getConditions(lineID,stationID, "ArrDep")
        if conditions == -1 or #conditions < 1 then
            timetableGUI.popUpMessage("You must have one initial arrival / departure time", function() end)
            return
        end

        local separationIndex = separationCombo:getCurrentIndex()
        if separationIndex == -1 then -- no separation selected
            timetableGUI.popUpMessage("You must select a separation", function() end)
            return
        end

        if #conditions > 1 then
            generateButton:setEnabled(false)

            local condition1 = conditions[1]
            timetable.removeAllConditions(lineID, stationID, "ArrDep")
            timetable.addCondition(lineID, stationID, {type = "ArrDep", ArrDep = {condition1}})
            generate(separationIndex, condition1)
            generateButton:setEnabled(true)

        else
            generate(separationIndex, conditions[1])
        end
    end)

    -- setup recurring departure generator
    local recurringTable = api.gui.comp.Table.new(3, 'NONE')
    recurringTable:addRow({api.gui.comp.TextView.new("Separation"),separationCombo,generateButton})
    menu.constraintHeaderTable:addRow({recurringTable})


    -- setup add button
    local addButton = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.add), true)
    addButton:setGravity(-1,0)
    addButton:onClick(function()
        local periodIndex = UIState.currentlyEditingTimePeriod
        if periodIndex then
            local periods = timetable.getTimePeriods(lineID, stationID)
            if periods and periods[periodIndex] then
                local slots = periods[periodIndex].slots
                table.insert(slots, {0,0,0,0})
                timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
            end
        else
            timetable.addCondition(lineID,stationID, {type = "ArrDep", ArrDep = {{0,0,0,0}}})
        end
		timetableChanged = true
		clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
		end
    end)

    -- setup deleteButton button
    local deleteButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("X All"), true)
    deleteButton:setGravity(-1,0)
    deleteButton:onClick(function()
        local periodIndex = UIState.currentlyEditingTimePeriod
        if periodIndex then
            local periods = timetable.getTimePeriods(lineID, stationID)
            if periods and periods[periodIndex] then
                periods[periodIndex].slots = {}
                timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, {})
            end
        else
            timetable.removeAllConditions(lineID, stationID, "ArrDep")
        end
        timetableChanged = true
		clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
        end          
    end)

    -- Copy/Paste buttons
    local copyButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Copy"), true)
    copyButton:setGravity(-1,0)
    copyButton:onClick(function()
        if timetable.copyConstraints(lineID, stationID) then
            timetableGUI.popUpMessage("Constraints copied to clipboard", function() end)
        else
            timetableGUI.popUpMessage("Nothing to copy", function() end)
        end
    end)
    
    local pasteButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Paste"), true)
    pasteButton:setGravity(-1,0)
    pasteButton:setEnabled(timetable.hasClipboard())
    pasteButton:onClick(function()
        if timetable.pasteConstraints(lineID, stationID) then
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        else
            timetableGUI.popUpMessage("Nothing to paste", function() end)
        end
    end)

    --setup header
    local headerTable = api.gui.comp.Table.new(6, 'NONE')
    headerTable:setColWidth(1,85)
    headerTable:setColWidth(2,60)
    headerTable:setColWidth(3,60)
    headerTable:setColWidth(4,60)
    headerTable:setColWidth(5,60)
    headerTable:addRow({addButton,api.gui.comp.TextView.new(UIStrings.min),api.gui.comp.TextView.new(UIStrings.sec),deleteButton,copyButton,pasteButton})
    menu.constraintHeaderTable:addRow({headerTable})

    timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
end

-- Create time period editor UI
function timetableGUI.makeTimePeriodEditor(lineID, stationID)
    local periods = timetable.getTimePeriods(lineID, stationID)
    if not periods then return end
    
    -- Time periods header
    local periodsHeaderTable = api.gui.comp.Table.new(5, 'NONE')
    periodsHeaderTable:setColWidth(0, 150)
    periodsHeaderTable:setColWidth(1, 100)
    periodsHeaderTable:setColWidth(2, 100)
    periodsHeaderTable:setColWidth(3, 50)
    periodsHeaderTable:setColWidth(4, 100)
    periodsHeaderTable:addRow({
        api.gui.comp.TextView.new("Time Period"),
        api.gui.comp.TextView.new("Start"),
        api.gui.comp.TextView.new("End"),
        api.gui.comp.TextView.new(""),
        api.gui.comp.TextView.new("Actions")
    })
    menu.constraintHeaderTable:addRow({periodsHeaderTable})
    
    -- Display each time period
    for periodIndex, period in ipairs(periods) do
        local startMin, startSec = timetable.secToMin(period.startTime % 3600)
        local endMin, endSec = timetable.secToMin(period.endTime % 3600)
        
        -- Period label
        local periodLabel = api.gui.comp.TextView.new("Period " .. periodIndex)
        
        -- Start time
        local startMinSpin = api.gui.comp.DoubleSpinBox.new()
        startMinSpin:setMinimum(0, false)
        startMinSpin:setMaximum(59, false)
        startMinSpin:setValue(startMin, false)
        startMinSpin:onChange(function(value)
            local currentStart = period.startTime % 3600
            local currentSec = currentStart % 60
            timetable.updateTimePeriod(lineID, stationID, periodIndex, value * 60 + currentSec, nil, nil)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        end)
        
        local startSecSpin = api.gui.comp.DoubleSpinBox.new()
        startSecSpin:setMinimum(0, false)
        startSecSpin:setMaximum(59, false)
        startSecSpin:setValue(startSec, false)
        startSecSpin:onChange(function(value)
            local currentStart = period.startTime % 3600
            local currentMin = math.floor(currentStart / 60)
            timetable.updateTimePeriod(lineID, stationID, periodIndex, currentMin * 60 + value, nil, nil)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        end)
        
        -- End time
        local endMinSpin = api.gui.comp.DoubleSpinBox.new()
        endMinSpin:setMinimum(0, false)
        endMinSpin:setMaximum(59, false)
        endMinSpin:setValue(endMin, false)
        endMinSpin:onChange(function(value)
            local currentEnd = period.endTime % 3600
            local currentSec = currentEnd % 60
            timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, value * 60 + currentSec, nil)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        end)
        
        local endSecSpin = api.gui.comp.DoubleSpinBox.new()
        endSecSpin:setMinimum(0, false)
        endSecSpin:setMaximum(59, false)
        endSecSpin:setValue(endSec, false)
        endSecSpin:onChange(function(value)
            local currentEnd = period.endTime % 3600
            local currentMin = math.floor(currentEnd / 60)
            timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, currentMin * 60 + value, nil)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        end)
        
        -- Edit slots button
        local editSlotsButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Edit Slots"), true)
        editSlotsButton:onClick(function()
            -- Store current period index for slot editing
            UIState.currentlyEditingTimePeriod = periodIndex
            -- Refresh constraint table to show slots for this period
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        end)
        
        -- Delete period button
        local deletePeriodButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Delete"), true)
        deletePeriodButton:onClick(function()
            timetable.removeTimePeriod(lineID, stationID, periodIndex)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        end)
        
        local periodRowTable = api.gui.comp.Table.new(8, 'NONE')
        periodRowTable:setColWidth(0, 150)
        periodRowTable:setColWidth(1, 50)
        periodRowTable:setColWidth(2, 10)
        periodRowTable:setColWidth(3, 50)
        periodRowTable:setColWidth(4, 50)
        periodRowTable:setColWidth(5, 10)
        periodRowTable:setColWidth(6, 50)
        periodRowTable:setColWidth(7, 100)
        periodRowTable:addRow({
            periodLabel,
            startMinSpin,
            api.gui.comp.TextView.new(":"),
            startSecSpin,
            endMinSpin,
            api.gui.comp.TextView.new(":"),
            endSecSpin,
            editSlotsButton,
            deletePeriodButton
        })
        menu.constraintHeaderTable:addRow({periodRowTable})
    end
    
    -- Add new period button
    local addPeriodButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Add Time Period"), true)
    addPeriodButton:onClick(function()
        -- Add a new period (default: next hour slot)
        local newStart = 0
        local newEnd = 3600
        if #periods > 0 then
            -- Start after last period ends
            local lastPeriod = periods[#periods]
            newStart = (lastPeriod.endTime % 3600)
            newEnd = (newStart + 3600) % 3600
            if newEnd == 0 then newEnd = 3600 end
        end
        timetable.addTimePeriod(lineID, stationID, newStart, newEnd, {})
        timetableChanged = true
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
        end
    end)
    menu.constraintHeaderTable:addRow({addPeriodButton})
    menu.constraintHeaderTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
end

function timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
    -- Check if editing a specific time period
    local periodIndex = UIState.currentlyEditingTimePeriod
    local conditions = nil
    
    if periodIndex and timetable.hasTimePeriods(lineID, stationID) then
        local periods = timetable.getTimePeriods(lineID, stationID)
        if periods and periods[periodIndex] then
            conditions = periods[periodIndex].slots
        end
    else
        conditions = timetable.getConditions(lineID, stationID, "ArrDep")
    end
    
    if conditions == -1 or not conditions then return end

    menu.constraintContentTable:deleteAll()
    
    -- Show period indicator if editing a time period
    if periodIndex then
        local periodLabel = api.gui.comp.TextView.new("Editing slots for Period " .. periodIndex)
        menu.constraintContentTable:addRow({periodLabel})
        menu.constraintContentTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
    end

    -- setup arrival and departure content
    for k,v in pairs(conditions) do
        menu.constraintContentTable:addRow({api.gui.comp.Component.new("HorizontalLine")})

        local arivalLabel =  api.gui.comp.TextView.new(UIStrings.arrival .. ":  ")
        arivalLabel:setMinimumSize(api.gui.util.Size.new(75, 30))

        local arrivalMin = api.gui.comp.DoubleSpinBox.new()
        arrivalMin:setMinimum(0,false)
        arrivalMin:setMaximum(59,false)
        arrivalMin:setValue(v[1],false)
        arrivalMin:onChange(function(value)
            if periodIndex then
                -- Update slot in time period
                local periods = timetable.getTimePeriods(lineID, stationID)
                if periods and periods[periodIndex] then
                    local slots = periods[periodIndex].slots
                    if slots[k] then
                        slots[k][1] = value
                        timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
                    end
                end
            else
                timetable.updateArrDep(lineID, stationID, k, 1, value)
            end
            timetableChanged = true
			clearConstraintWindowLaterHACK = function()
				timetableGUI.initStationTable()
				timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
			end 
        end)

        local minSecSeparator = api.gui.comp.TextView.new(":")

        local arrivalSec = api.gui.comp.DoubleSpinBox.new()
        arrivalSec:setMinimum(0,false)
        arrivalSec:setMaximum(59,false)
        arrivalSec:setValue(v[2],false)
        arrivalSec:onChange(function(value)
            if periodIndex then
                local periods = timetable.getTimePeriods(lineID, stationID)
                if periods and periods[periodIndex] then
                    local slots = periods[periodIndex].slots
                    if slots[k] then
                        slots[k][2] = value
                        timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
                    end
                end
            else
                timetable.updateArrDep(lineID, stationID, k, 2, value)
            end
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
				timetableGUI.initStationTable()
				timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
			end 
        end)

        local deleteLabel = api.gui.comp.TextView.new("     X")
        deleteLabel:setMinimumSize(api.gui.util.Size.new(60, 10))
        local deleteButton = api.gui.comp.Button.new(deleteLabel, true)
        deleteButton:onClick(function()
            deleteButton:setEnabled(false)
            
            if periodIndex then
                local periods = timetable.getTimePeriods(lineID, stationID)
                if periods and periods[periodIndex] then
                    local slots = periods[periodIndex].slots
                    table.remove(slots, k)
                    timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
                end
            else
                timetable.removeCondition(lineID, stationID, "ArrDep", k)
            end
            timetableChanged = true
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            menu.constraintTable:invokeLater( function ()
                timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
            end)

            deleteButton:setEnabled(true)
        end)

        local linetable = api.gui.comp.Table.new(5, 'NONE')
        linetable:addRow({
            arivalLabel,
            arrivalMin,
            minSecSeparator,
            arrivalSec,
            deleteButton
        })
        linetable:setColWidth(1, 60)
        linetable:setColWidth(2, 25)
        linetable:setColWidth(3, 60)
        linetable:setColWidth(4, 60)
        menu.constraintContentTable:addRow({linetable})

        local departureLabel =  api.gui.comp.TextView.new(UIStrings.departure .. ":  ")
        departureLabel:setMinimumSize(api.gui.util.Size.new(75, 30))

        local departureMin = api.gui.comp.DoubleSpinBox.new()
        departureMin:setMinimum(0,false)
        departureMin:setMaximum(59,false)
        departureMin:setValue(v[3],false)
        departureMin:onChange(function(value)
            if periodIndex then
                local periods = timetable.getTimePeriods(lineID, stationID)
                if periods and periods[periodIndex] then
                    local slots = periods[periodIndex].slots
                    if slots[k] then
                        slots[k][3] = value
                        timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
                    end
                end
            else
                timetable.updateArrDep(lineID, stationID, k, 3, value)
            end
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
				timetableGUI.initStationTable()
				timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
			end 
        end)

        local minSecSeparator = api.gui.comp.TextView.new(":")

        local departureSec = api.gui.comp.DoubleSpinBox.new()
        departureSec:setMinimum(0,false)
        departureSec:setMaximum(59,false)
        departureSec:setValue(v[4],false)
        departureSec:onChange(function(value)
            if periodIndex then
                local periods = timetable.getTimePeriods(lineID, stationID)
                if periods and periods[periodIndex] then
                    local slots = periods[periodIndex].slots
                    if slots[k] then
                        slots[k][4] = value
                        timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
                    end
                end
            else
                timetable.updateArrDep(lineID, stationID, k, 4, value)
            end
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
				timetableGUI.initStationTable()
				timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
			end 
        end)

        local insertLabel = api.gui.comp.TextView.new("     +")
        insertLabel:setMinimumSize(api.gui.util.Size.new(60, 10))
        local insertButton = api.gui.comp.Button.new(insertLabel, true)
        insertButton:onClick(function()
            if periodIndex then
                local periods = timetable.getTimePeriods(lineID, stationID)
                if periods and periods[periodIndex] then
                    local slots = periods[periodIndex].slots
                    table.insert(slots, k, {0,0,0,0})
                    timetable.updateTimePeriod(lineID, stationID, periodIndex, nil, nil, slots)
                end
            else
                timetable.insertArrDepCondition(lineID, stationID, k, {0,0,0,0})
            end
            timetableChanged = true
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            menu.constraintTable:invokeLater( function ()
                timetableGUI.makeArrDepConstraintsTable(lineID, stationID)
            end)
        end)

        local linetable2 = api.gui.comp.Table.new(5, 'NONE')
        linetable2:addRow({
            departureLabel,
            departureMin,
            minSecSeparator,
            departureSec,
            insertButton
        })
        linetable2:setColWidth(1, 60)
        linetable2:setColWidth(2, 25)
        linetable2:setColWidth(3, 60)
        linetable2:setColWidth(4, 60)
        menu.constraintContentTable:addRow({linetable2})


        menu.constraintContentTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
    end
end

function timetableGUI.makeDebounceWindow(lineID, stationID, debounceType)
    if not menu.constraintHeaderTable then return end
    local frequency = timetableHelper.getFrequencyMinSec(lineID)
    local condition = timetable.getConditions(lineID,stationID, debounceType)
    if condition == -1 then return end
    local autoDebounceMin = nil
    local autoDebounceSec = nil

    local updateAutoDebounce = function()
        if debounceType == "auto_debounce" then
            condition = timetable.getConditions(lineID, stationID, debounceType)
            if condition == -1 then return end
            if type(frequency) == "table" and autoDebounceMin and autoDebounceSec and condition and condition[1] and condition[2] then
                local unbunchTime = (frequency.min - condition[1]) * 60 + frequency.sec - condition[2]
                if unbunchTime >= 0 then
                    autoDebounceMin:setText(tostring(math.floor(unbunchTime / 60)))
                    autoDebounceSec:setText(tostring(math.floor(unbunchTime % 60)))
                else
                    autoDebounceMin:setText("--")
                    autoDebounceSec:setText("--")
                end
            end
        end
    end

    --setup header
    local headerTable = api.gui.comp.Table.new(3, 'NONE')
    headerTable:setColWidth(0,175)
    headerTable:setColWidth(1,85)
    headerTable:setColWidth(2,60)
    headerTable:addRow({
        api.gui.comp.TextView.new(""),
        api.gui.comp.TextView.new(UIStrings.min),
        api.gui.comp.TextView.new(UIStrings.sec)})
    menu.constraintHeaderTable:addRow({headerTable})

    local debounceTable = api.gui.comp.Table.new(4, 'NONE')
    debounceTable:setColWidth(0,175)
    debounceTable:setColWidth(1,60)
    debounceTable:setColWidth(2,25)
    debounceTable:setColWidth(3,60)

    local debounceMin = api.gui.comp.DoubleSpinBox.new()
    debounceMin:setMinimum(0,false)
    debounceMin:setMaximum(59,false)
    if debounceType == "auto_debounce" and type(frequency) == "table" then
        debounceMin:setMaximum(frequency.min,false)
    end

    debounceMin:onChange(function(value)
        timetable.updateDebounce(lineID, stationID,  1, value, debounceType)
        timetableChanged = true
		updateAutoDebounce()
		clearConstraintWindowLaterHACK = function()
			timetableGUI.initStationTable()
			timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
		end
    end)

    if condition and condition[1] then
        debounceMin:setValue(condition[1],false)
    end


    local debounceSec = api.gui.comp.DoubleSpinBox.new()
    debounceSec:setMinimum(0,false)
    debounceSec:setMaximum(59,false)

    debounceSec:onChange(function(value)
        timetable.updateDebounce(lineID, stationID, 2, value, debounceType)
        timetableChanged = true
		updateAutoDebounce()
        clearConstraintWindowLaterHACK = function()
			timetableGUI.initStationTable()
			timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
		end
    end)

    if condition and condition[2] then
        debounceSec:setValue(condition[2],false)
    end

    local unbunchTimeHeader = api.gui.comp.TextView.new(UIStrings.unbunch_time .. ":")
    debounceHeader = unbunchTimeHeader
    if debounceType == "auto_debounce" then debounceHeader = api.gui.comp.TextView.new("Margin Time:") end
    debounceTable:addRow({debounceHeader, debounceMin, api.gui.comp.TextView.new(":"), debounceSec})

    if debounceType == "auto_debounce" then
        autoDebounceMin = api.gui.comp.TextView.new("--")
        autoDebounceSec = api.gui.comp.TextView.new("--")
        updateAutoDebounce()
        debounceTable:addRow({unbunchTimeHeader, autoDebounceMin, api.gui.comp.TextView.new(":"), autoDebounceSec})
    end

    menu.constraintHeaderTable:addRow({debounceTable})
    
    -- Add Copy/Paste buttons for debounce constraints
    local copyButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Copy"), true)
    copyButton:setGravity(-1,0)
    copyButton:onClick(function()
        if timetable.copyConstraints(lineID, stationID) then
            timetableGUI.popUpMessage("Constraints copied to clipboard", function() end)
        else
            timetableGUI.popUpMessage("Nothing to copy", function() end)
        end
    end)
    
    local pasteButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Paste"), true)
    pasteButton:setGravity(-1,0)
    pasteButton:setEnabled(timetable.hasClipboard())
    pasteButton:onClick(function()
        if timetable.pasteConstraints(lineID, stationID) then
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex, lineID)
            end
        else
            timetableGUI.popUpMessage("Nothing to paste", function() end)
        end
    end)
    
    local copyPasteTable = api.gui.comp.Table.new(2, 'NONE')
    copyPasteTable:addRow({copyButton, pasteButton})
    menu.constraintHeaderTable:addRow({copyPasteTable})
end

-------------------------------------------------------------
--------------------- Settings Tab ------------

-- Initialize settings tab
function timetableGUI.initSettingsTab()
    local settings = require "celmi/timetables/settings"
    
    local scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('SettingsContent'), "timetable.settingsContent")
    local contentTable = api.gui.comp.Table.new(1, 'NONE')
    
    -- Settings sections
    local sections = {
        {
            title = "Delay Recovery Settings",
            settings = {
                {key = "defaultDelayRecoveryMode", label = "Default Delay Recovery Mode", type = "combo", 
                 options = {"catch_up", "skip_to_next", "hold_at_terminus", "gradual_recovery"},
                 labels = {"Catch Up", "Skip to Next", "Hold at Terminus", "Gradual Recovery"}},
                {key = "defaultMaxDelayTolerance", label = "Default Max Delay Tolerance (seconds)", type = "spin", min = 0, max = 3600},
                {key = "defaultMaxDelayToleranceEnabled", label = "Enable Max Delay Tolerance by Default", type = "checkbox"}
            }
        },
        {
            title = "Auto-Generate Timetable Settings",
            settings = {
                {key = "autoGenDefaultStartHour", label = "Default Start Hour", type = "spin", min = 0, max = 23},
                {key = "autoGenDefaultStartMin", label = "Default Start Minute", type = "spin", min = 0, max = 59},
                {key = "autoGenDefaultEndHour", label = "Default End Hour", type = "spin", min = 0, max = 23},
                {key = "autoGenDefaultEndMin", label = "Default End Minute", type = "spin", min = 0, max = 59},
                {key = "autoGenDefaultDwellTime", label = "Default Dwell Time (seconds)", type = "spin", min = 0, max = 300}
            }
        },
        {
            title = "Route Finder Settings",
            settings = {
                {key = "routeFinderCongestionWeight", label = "Default Congestion Weight (0.0-1.0)", type = "double", min = 0.0, max = 1.0, step = 0.1},
                {key = "routeFinderMaxRoutes", label = "Max Route Options", type = "spin", min = 1, max = 10},
                {key = "routeFinderTrafficUpdateInterval", label = "Traffic Update Interval (seconds)", type = "spin", min = 10, max = 300}
            }
        },
        {
            title = "Hub Identification Settings",
            settings = {
                {key = "hubIdentificationMaxHubs", label = "Max Hubs to Identify", type = "spin", min = 1, max = 50},
                {key = "hubIdentificationMinScore", label = "Minimum Hub Score", type = "spin", min = 0, max = 100}
            }
        },
        {
            title = "Display Settings",
            settings = {
                {key = "departureBoardUpdateInterval", label = "Departure Board Update (seconds)", type = "spin", min = 1, max = 60},
                {key = "statisticsUpdateInterval", label = "Statistics Update (seconds)", type = "spin", min = 1, max = 60},
                {key = "vehicleDepartureDisplayUpdateInterval", label = "Vehicle Display Update (seconds)", type = "spin", min = 1, max = 60}
            }
        },
        {
            title = "Performance Settings",
            settings = {
                {key = "cleanTimetableInterval", label = "Cleanup Interval (seconds)", type = "spin", min = 10, max = 300},
                {key = "cacheInvalidationEnabled", label = "Enable Cache Invalidation", type = "checkbox"}
            }
        },
        {
            title = "Validation Settings",
            settings = {
                {key = "validationWarningsEnabled", label = "Show Validation Warnings", type = "checkbox"},
                {key = "validationCheckOnEdit", label = "Check Validation on Edit", type = "checkbox"}
            }
        }
    }
    
    -- Create UI for each section
    for _, section in ipairs(sections) do
        local sectionHeader = api.gui.comp.TextView.new(section.title)
        sectionHeader:setStyleClassList({"timetable-section-header"})
        contentTable:addRow({sectionHeader})
        
        for _, setting in ipairs(section.settings) do
            local settingRow = api.gui.comp.Table.new(2, 'NONE')
            settingRow:setColWidth(0, 300)
            
            local label = api.gui.comp.TextView.new(setting.label .. ":")
            label:setGravity(1, 0.5)
            
            local control = nil
            local currentValue = settings.get(setting.key)
            
            if setting.type == "checkbox" then
                local checkboxImage = api.gui.comp.ImageView.new(currentValue and "ui/checkbox1.tga" or "ui/checkbox0.tga")
                control = api.gui.comp.Button.new(checkboxImage, true)
                control:setStyleClassList({"timetable-activateTimetableButton"})
                control:onClick(function()
                    local newValue = not settings.get(setting.key)
                    local valid, err = settings.validate(setting.key, newValue)
                    if valid then
                        settings.set(setting.key, newValue)
                        checkboxImage:setImage(newValue and "ui/checkbox1.tga" or "ui/checkbox0.tga", false)
                    end
                end)
            elseif setting.type == "spin" then
                control = api.gui.comp.SpinBox.new()
                control:setValue(currentValue or 0)
                control:setMin(setting.min or 0)
                control:setMax(setting.max or 1000)
                control:onChange(function(value)
                    local valid, err = settings.validate(setting.key, value)
                    if valid then
                        settings.set(setting.key, value)
                    end
                end)
            elseif setting.type == "double" then
                control = api.gui.comp.DoubleSpinBox.new()
                control:setValue(currentValue or 0.0)
                control:setMin(setting.min or 0.0)
                control:setMax(setting.max or 1.0)
                control:setStep(setting.step or 0.1)
                control:onChange(function(value)
                    local valid, err = settings.validate(setting.key, value)
                    if valid then
                        settings.set(setting.key, value)
                    end
                end)
            elseif setting.type == "combo" then
                control = api.gui.comp.ComboBox.new()
                for i, option in ipairs(setting.options) do
                    control:addItem(setting.labels[i] or option)
                end
                -- Find current selection
                for i, option in ipairs(setting.options) do
                    if option == currentValue then
                        control:setSelected(i - 1, false)
                        break
                    end
                end
                control:onIndexChanged(function(index)
                    if setting.options[index + 1] then
                        local newValue = setting.options[index + 1]
                        local valid, err = settings.validate(setting.key, newValue)
                        if valid then
                            settings.set(setting.key, newValue)
                        end
                    end
                end)
            end
            
            if control then
                settingRow:addRow({label, control})
                contentTable:addRow({settingRow})
            end
        end
        
        -- Add spacing between sections
        contentTable:addRow({api.gui.comp.Component.new("Spacer")})
    end
    
    -- Reset to defaults button
    local buttonRow = api.gui.comp.Table.new(2, 'NONE')
    local resetButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Reset to Defaults"), true)
    resetButton:onClick(function()
        timetableGUI.popUpYesNo("Reset all settings to defaults?", function()
            settings.resetAll()
            timetableGUI.initSettingsTab() -- Refresh UI
            timetableGUI.popUpMessage("Settings reset to defaults", function() end)
        end, function() end)
    end)
    buttonRow:addRow({resetButton})
    contentTable:addRow({buttonRow})
    
    scrollArea:setContent(contentTable)
    scrollArea:setMinimumSize(api.gui.util.Size.new(600, 500))
    scrollArea:setMaximumSize(api.gui.util.Size.new(800, 700))
    
    UIState.floatingLayoutSettings:addItem(scrollArea, 0, 0)
end

--------------------- Vehicle Departure Display ------------
-------------------------------------------------------------

-- Initialize vehicle departure display component
function timetableGUI.initVehicleDepartureDisplay()
    if vehicleDepartureDisplay then return end
    
    -- Create a text view for departure info
    vehicleDepartureDisplay = api.gui.comp.TextView.new("")
    vehicleDepartureDisplay:setName("timetable.vehicleDepartureDisplay")
    vehicleDepartureDisplay:setVisible(false, false) -- Hidden by default
    vehicleDepartureDisplay:setMinimumSize(api.gui.util.Size.new(250, 30))
    vehicleDepartureDisplay:setMaximumSize(api.gui.util.Size.new(400, 50))
    
    -- Update display periodically
    vehicleDepartureDisplay:onStep(function()
        timetableGUI.updateVehicleDepartureDisplay()
    end)
    
    -- Add to game info layout
    local gameInfoLayout = api.gui.util.getById("gameInfo"):getLayout()
    if gameInfoLayout then
        gameInfoLayout:addItem(vehicleDepartureDisplay)
    end
end

-- Update vehicle departure display with current vehicle info
function timetableGUI.updateVehicleDepartureDisplay()
    if not vehicleDepartureDisplay then return end
    
    -- Update less frequently (use setting)
    local settings = require "celmi/timetables/settings"
    local updateInterval = settings.get("vehicleDepartureDisplayUpdateInterval")
    local lastUpdate = vehicleDepartureDisplay.lastUpdate or 0
    local currentTime = timetableHelper.getTime()
    
    if currentTime - lastUpdate < updateInterval then
        return
    end
    
    vehicleDepartureDisplay.lastUpdate = currentTime
    
    -- Find vehicles at stations with timetables
    -- Show count of vehicles waiting and sample info for one vehicle
    local vehiclesWaitingCount = 0
    local sampleDisplayText = ""
    local delayTracker = require "celmi/timetables/delay_tracker"
    
    for line, _ in pairs(timetable.getCachedTimetableLines()) do
        if api.engine.entityExists(line) then
            local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(line)
            for _, vehicle in pairs(vehicles) do
                local vehicleState = timetableHelper.getVehicleInfo(vehicle)
                if vehicleState and vehicleState.state == api.type.enum.TransportVehicleState.AT_TERMINAL then
                    local stop = vehicleState.stopIndex + 1
                    
                    if timetable.LineAndStationHasTimetable(line, stop) then
                        local depInfo = timetable.getVehicleDepartureInfo(vehicle, line, stop, currentTime)
                        if depInfo then
                            vehiclesWaitingCount = vehiclesWaitingCount + 1
                            
                            -- Record delay for statistics
                            if depInfo.delay then
                                delayTracker.recordDelay(line, stop, vehicle, depInfo.delay, currentTime)
                            end
                            
                            -- Use first vehicle found as sample for display
                            if sampleDisplayText == "" then
                                local formattedText = timetable.formatDepartureDisplay(depInfo, currentTime)
                                if formattedText then
                                    local lineName = timetableHelper.getLineName(line)
                                    sampleDisplayText = lineName .. ": " .. formattedText
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Update display visibility and text
    if vehiclesWaitingCount > 0 and sampleDisplayText ~= "" then
        if vehiclesWaitingCount > 1 then
            vehicleDepartureDisplay:setText(sampleDisplayText .. " (" .. vehiclesWaitingCount .. " vehicles waiting)")
        else
            vehicleDepartureDisplay:setText(sampleDisplayText)
        end
        vehicleDepartureDisplay:setVisible(true, false)
    else
        vehicleDepartureDisplay:setVisible(false, false)
    end
end

-------------------------------------------------------------
--------------------- OTHER ---------------------------------
-------------------------------------------------------------

function timetableGUI.popUpMessage(message, onOK)
    debugPrint("popUpMessage")
    if menu.popUp then
        menu.popUp:close()
    end

    local okButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("OK"), true)
    menu.popUp = api.gui.comp.Window.new(message, okButton)
    local position = api.gui.util.getMouseScreenPos()
    menu.popUp:setPosition(position.x, position.y)
    menu.popUp:addHideOnCloseHandler()

    menu.popUp:onClose(function()
        onOK()
    end)

    okButton:onClick(function()
        menu.popUp:close()
    end)
end

function timetableGUI.popUpYesNo(title, onYes, onNo)
    if menu.popUp then
        menu.popUp:close()
    end
    local popUpTable = api.gui.comp.Table.new(2, 'NONE')
    local yesButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("Yes"), true)
    local noButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("No"), true)
    popUpTable:addRow({yesButton, noButton})

    menu.popUp = api.gui.comp.Window.new(title, popUpTable)
    local position = api.gui.util.getMouseScreenPos()
    menu.popUp:setPosition(position.x, position.y)
    menu.popUp:addHideOnCloseHandler()

    local yesPressed = false
    menu.popUp:onClose(function()
        if yesPressed then
            onYes()
        else
            onNo()
        end
        menu.popUp = nil
    end)

    yesButton:onClick(function()
        yesPressed = true
        menu.popUp:close()
    end)
    noButton:onClick(function()
        menu.popUp:close()
    end)
end

function timetableGUI.timetableCoroutine()
    local lastUpdate = -1
	local currentProcessingTime = 0
    local lastCleanTime = -1

    while true do
		currentProcessingTime = timetableHelper.getTime()
        -- only run once a second to avoid unnecessary cpu usage
        while currentProcessingTime - lastUpdate < 1 do
            coroutine.yield()
			currentProcessingTime = timetableHelper.getTime()
        end

        lastUpdate = currentProcessingTime
        -- Cache current time to avoid redundant getTime() calls
		-- Debug prints removed for performance (can be re-enabled with a debug flag if needed)
		-- print("Timetable ping " .. os.date('%M:%S', lastUpdate))
		-- print("Lua is using " .. tostring(math.floor(api.util.getLuaUsedMemory()/(1024*1024))).."MB of memory")

        -- Only process lines that have timetables enabled
        -- Pass cached current time to avoid redundant getTime() calls
        for line, _ in pairs(timetable.getCachedTimetableLines()) do
            if api.engine.entityExists(line) then
                local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(line)
                for _, vehicle in pairs(vehicles) do
                    local vehicleState = timetableHelper.getVehicleInfo(vehicle)
                    if vehicleState.state == api.type.enum.TransportVehicleState.AT_TERMINAL then
                        timetable.updateForVehicle(vehicle, line, vehicles, vehicleState, currentProcessingTime)
                    end
                end
            end
        end

        -- Run cleanTimetable() at configured interval
        local settings = require "celmi/timetables/settings"
        local cleanInterval = settings.get("cleanTimetableInterval")
        if lastCleanTime < 0 or currentProcessingTime - lastCleanTime >= cleanInterval then
            timetable.cleanTimetable()
            lastCleanTime = currentProcessingTime
        end
        coroutine.yield()
    end
end

function data()
    return {
        --engine Thread

        handleEvent = function (_, id, _, param)
            if id == "timetableUpdate" then
                if state == nil then state = {timetable = {}} end
                state.timetable = param
                timetable.setTimetableObject(state.timetable)
                timetableChanged = true
            end
        end,

        save = function()
            -- save happens once for both threads to verify loading and saving works
            -- then the engine thread repeatedly saves its state for the gui thread to load
            state = {}
            state.timetable = timetable.getTimetableObject(true) -- Include settings
            
            return state
        end,

        load = function(loadedState)
            -- load happens once for engine thread and repeatedly for gui thread
            state = loadedState or {timetable = {}}

            timetable.setTimetableObject(state.timetable)
            -- Initialize cache on first load
            timetable.initializeTimetableLinesCache()
        end,

        update = function()
            if state == nil then state = {timetable = {}} end
            if co == nil or coroutine.status(co) == "dead" then
                co = coroutine.create(timetableGUI.timetableCoroutine)
                print("Created new timetable coroutine")
            end

            -- Resume the coroutine once per update call
            local coroutineStatus = coroutine.status(co)
            if coroutineStatus == "suspended" then
                local success, errorMsg = coroutine.resume(co)
                if not success then
                    print("Timetables coroutine error: " .. tostring(errorMsg))
                    -- Recreate the coroutine if there was an error
                    co = coroutine.create(timetableGUI.timetableCoroutine)
                    print("Recreated timetable coroutine after error")
                end
            else
                print("Timetables coroutine status: " .. coroutineStatus)
                if coroutineStatus ~= "running" then
                    -- Recreate the coroutine if it's in an unexpected state
                    co = coroutine.create(timetableGUI.timetableCoroutine)
                    print("Recreated timetable coroutine due to unexpected status")
                end
            end

            -- TODO: check if needed
            -- state.timetable = timetable.getTimetableObject()

            local currentTime = timetableHelper.getTime()
            local lines = game.interface.getLines()
            local currentLinesSet = {}
            
            -- Build set of current lines
            for _, line in pairs(lines) do
                currentLinesSet[line] = true
            end
            
            -- Check if line list has changed or if it's time for periodic update
            local linesChanged = false
            if not cachedLinesList or not next(cachedLinesList) then
                linesChanged = true
                cachedLinesList = {}
            else
                -- Check for new or removed lines
                for line, _ in pairs(currentLinesSet) do
                    if not cachedLinesList[line] then
                        linesChanged = true
                        break
                    end
                end
                if not linesChanged then
                    for line, _ in pairs(cachedLinesList) do
                        if not currentLinesSet[line] then
                            linesChanged = true
                            break
                        end
                    end
                end
            end
            
            local shouldUpdateFrequencies = linesChanged or (currentTime - lastFrequencyUpdateTime >= FREQUENCY_UPDATE_INTERVAL)
            
            if shouldUpdateFrequencies then
                for _, line in pairs(lines) do
                    -- Only update if line is new, line list changed, or periodic update
                    local cacheEntry = lineFrequencyCache[line]
                    local shouldUpdateLine = linesChanged or not cacheEntry or (currentTime - cacheEntry.lastUpdate >= FREQUENCY_UPDATE_INTERVAL)
                    
                    if shouldUpdateLine then
                        local frequency = timetableHelper.getFrequency(line)
                        timetable.addFrequency(line, frequency)
                        lineFrequencyCache[line] = {frequency = frequency, lastUpdate = currentTime}
                    else
                        -- Use cached frequency
                        if cacheEntry then
                            timetable.addFrequency(line, cacheEntry.frequency)
                        end
                    end
                end
                
                -- Clean up cache for removed lines and update cached line list
                if linesChanged then
                    for line, _ in pairs(lineFrequencyCache) do
                        if not currentLinesSet[line] then
                            lineFrequencyCache[line] = nil
                        end
                    end
                    -- Create a copy of currentLinesSet for cachedLinesList
                    cachedLinesList = {}
                    for line, _ in pairs(currentLinesSet) do
                        cachedLinesList[line] = true
                    end
                end
                
                lastFrequencyUpdateTime = currentTime
            end
        end,

        guiUpdate = function()
            if timetableChanged then
                game.interface.sendScriptEvent("timetableUpdate", "", timetable.getTimetableObject(true)) -- Include settings
                timetableChanged = false
            end
			
			if clearConstraintWindowLaterHACK then
                clearConstraintWindowLaterHACK()
                clearConstraintWindowLaterHACK = nil
            end

            if not clockstate then
				-- element for the divider
				local line = api.gui.comp.Component.new("VerticalLine")
				-- element for the icon
                local icon = api.gui.comp.ImageView.new("ui/clock_small.tga")
                -- element for the time
				clockstate = api.gui.comp.TextView.new("gameInfo.time.label")

                local buttonLabel = gui.textView_create("gameInfo.timetables.label", UIStrings.timetable)

                local button = gui.button_create("gameInfo.timetables.button", buttonLabel)
                button:onClick(function ()
                    local err, msg = pcall(timetableGUI.showLineMenu)
                    if not err then
                        menu.window = nil
                        print(msg)
                    end
                end)
                game.gui.boxLayout_addItem("gameInfo.layout", button.id)
				-- add elements to ui
				local gameInfoLayout = api.gui.util.getById("gameInfo"):getLayout()
				gameInfoLayout:addItem(line)
				gameInfoLayout:addItem(icon)
				gameInfoLayout:addItem(clockstate)
				clockstate:setTooltip("Current Time")
				clockstate:onStep(function ()
					clockstate:setText(os.date('%M:%S', timetableHelper.getTime()))
				end)
            end

            -- Initialize vehicle departure display
            if not vehicleDepartureDisplay then
                timetableGUI.initVehicleDepartureDisplay()
            end

			--local currentTime = os.date('%M:%S', timetableHelper.getTime())
			--clockstate:setText(os.date('%M:%S', timetableHelper.getTime()))
			--local currentTime = timetableHelper.getTime()
			--if clockstate and currentTime and currentTime - clockGUIUpdate > 0 then
				
			--	print("Clock update")
			--	clockGUIUpdate = currentTime
			--end

			--
            --if clockstate and currentTime then
            --    
            --end
			collectgarbage()
        end
    }
end

