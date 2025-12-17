# 第一阶段：核心逻辑扩展 - 实现细节

## 概述

本文档详细说明了如何在现有时刻表系统基础上实现列车与时间槽绑定功能的核心逻辑扩展。

## 数据结构扩展

### StationInfo 结构更新

在现有的 `stationInfo` 结构中增加 `trainAssignments` 字段：

```lua
stationInfo = {
    conditions = {condition :: Condition},
    vehiclesWaiting = {
        vehicleNumber = {
            slot = {},
            departureTime = 1 :: int
        }
    },
    -- 新增：列车与时间槽的绑定关系
    trainAssignments = {
        vehicleNumber = {
            slotIndex = 1 :: int,  -- 绑定的时间槽索引
            slot = {}              -- 绑定的时间槽内容
        }
    }
}
```

## 核心函数实现

### 1. assignTrainToSlot(line, station, vehicle, slotIndex)

将列车绑定到特定时间槽：

```lua
--- 将列车绑定到特定时间槽
---@param line integer 线路ID
---@param station integer 车站编号
---@param vehicle integer 列车ID
---@param slotIndex integer 时间槽索引
function timetable.assignTrainToSlot(line, station, vehicle, slotIndex)
    -- 参数验证
    if not line or not station or not vehicle or not slotIndex then
        print("assignTrainToSlot: Invalid parameters")
        return false
    end
    
    -- 确保线路和车站存在
    if not timetableObject[line] then
        timetableObject[line] = { hasTimetable = false, stations = {} }
    end
    
    if not timetableObject[line].stations[station] then
        local stationID = timetableHelper.getStationID(line, station)
        timetableObject[line].stations[station] = { 
            stationID = stationID, 
            conditions = { type = "None" },
            vehiclesWaiting = {},
            trainAssignments = {}
        }
    end
    
    -- 获取时间槽内容
    local slots = timetable.getConditions(line, station, "ArrDep")
    if slots == -1 or not slots[slotIndex] then
        print("assignTrainToSlot: Slot not found")
        return false
    end
    
    -- 初始化trainAssignments表
    if not timetableObject[line].stations[station].trainAssignments then
        timetableObject[line].stations[station].trainAssignments = {}
    end
    
    -- 设置绑定关系
    timetableObject[line].stations[station].trainAssignments[vehicle] = {
        slotIndex = slotIndex,
        slot = slots[slotIndex]
    }
    
    return true
end
```

### 2. removeTrainAssignment(line, station, vehicle)

解除列车绑定：

```lua
--- 解除列车绑定
---@param line integer 线路ID
---@param station integer 车站编号
---@param vehicle integer 列车ID
function timetable.removeTrainAssignment(line, station, vehicle)
    -- 参数验证
    if not line or not station or not vehicle then
        print("removeTrainAssignment: Invalid parameters")
        return false
    end
    
    -- 检查是否存在绑定关系
    if timetableObject[line] and 
       timetableObject[line].stations[station] and 
       timetableObject[line].stations[station].trainAssignments and
       timetableObject[line].stations[station].trainAssignments[vehicle] then
        -- 移除绑定关系
        timetableObject[line].stations[station].trainAssignments[vehicle] = nil
        return true
    end
    
    return false
end
```

### 3. getAssignedSlot(line, station, vehicle)

获取列车的绑定时间槽：

```lua
--- 获取列车的绑定时间槽
---@param line integer 线路ID
---@param station integer 车站编号
---@param vehicle integer 列车ID
---@return table|nil 绑定的时间槽，如果未绑定则返回nil
function timetable.getAssignedSlot(line, station, vehicle)
    if timetableObject[line] and 
       timetableObject[line].stations[station] and 
       timetableObject[line].stations[station].trainAssignments and
       timetableObject[line].stations[station].trainAssignments[vehicle] then
        return timetableObject[line].stations[station].trainAssignments[vehicle].slot
    end
    
    return nil
end
```

### 4. isTrainAssigned(line, station, vehicle)

检查列车是否已绑定：

```lua
--- 检查列车是否已绑定到时间槽
---@param line integer 线路ID
---@param station integer 车站编号
---@param vehicle integer 列车ID
---@return boolean 是否已绑定
function timetable.isTrainAssigned(line, station, vehicle)
    if timetableObject[line] and 
       timetableObject[line].stations[station] and 
       timetableObject[line].stations[station].trainAssignments and
       timetableObject[line].stations[station].trainAssignments[vehicle] then
        return true
    end
    
    return false
end
```

### 5. isValidSlot(slot, arrivalTime)

验证时间槽对当前到达时间是否有效：

```lua
--- 验证时间槽对当前到达时间是否有效
---@param slot table 时间槽 {arrHour, arrMin, depHour, depMin}
---@param arrivalTime integer 到达时间（秒）
---@return boolean 是否有效
function timetable.isValidSlot(slot, arrivalTime)
    if not slot or not arrivalTime then return false end
    
    local arrivalSlot = timetable.slotToArrivalSlot(slot)
    -- 检查到达时间是否在合理范围内
    return timetable.afterArrivalSlot(arrivalSlot, arrivalTime)
end
```

### 6. clearInvalidAssignments(line, station)

清理无效的绑定关系：

```lua
--- 清理无效的绑定关系
---@param line integer 线路ID
---@param station integer 车站编号
function timetable.clearInvalidAssignments(line, station)
    if not timetableObject[line] or not timetableObject[line].stations[station] then
        return
    end
    
    local time = timetableHelper.getTime()
    local assignments = timetableObject[line].stations[station].trainAssignments
    
    if not assignments then return end
    
    for vehicle, assignment in pairs(assignments) do
        -- 如果时间槽无效或者已经过期，则移除绑定
        if not timetable.isValidSlot(assignment.slot, time) then
            assignments[vehicle] = nil
        end
    end
end
```

## 修改现有函数

### 修改 getNextSlot 函数

在 `getNextSlot` 函数中增加检查列车绑定的逻辑：

```lua
--- 查找给定时间槽和到达时间的下一个有效时间槽
---@param slots table 时间槽数组 {{hour,min,hour,min}, ...}
---@param arrivalTime number 到达时间（秒）
---@param vehiclesWaiting table 等待车辆表
---@param line integer 线路ID（新增参数）
---@param station integer 车站编号（新增参数）
---@param vehicle integer 列车ID（新增参数）
---@return table | nil 最近的时间槽
function timetable.getNextSlot(slots, arrivalTime, vehiclesWaiting, line, station, vehicle)
    -- 如果列车已绑定到特定时间槽，则优先返回绑定的时间槽
    if vehicle and timetable.isTrainAssigned(line, station, vehicle) then
        local assignedSlot = timetable.getAssignedSlot(line, station, vehicle)
        -- 需要验证绑定的时间槽仍然有效
        if assignedSlot and timetable.isValidSlot(assignedSlot, arrivalTime) then
            return assignedSlot
        end
    end

    -- 原有逻辑...
    -- Put the slots in chronological order by arrival time
    table.sort(slots, function(slot1, slot2)
        local arrivalSlot1 = timetable.slotToArrivalSlot(slot1)
        local arrivalSlot2 = timetable.slotToArrivalSlot(slot2)
        return arrivalSlot1 < arrivalSlot2
    end)

    -- Find the distance from the arrival time
    local res = {diff = 3601, value = nil}
    for index, slot in pairs(slots) do
        local arrivalSlot = timetable.slotToArrivalSlot(slot)
        local diff = timetable.getTimeDifference(arrivalSlot, arrivalTime % 3600)

        if (diff < res.diff) then
            res = {diff = diff, index = index}
        end
    end

    -- Return nil when there are no contraints
    if not res.index then return nil end

    -- Split vehiclesWaiting by whether they have departed
    local waitingSlots = {}
    local departedSlots = {}
    if #slots == 1 then
        for vehicle, _ in pairs(vehiclesWaiting) do
            vehiclesWaiting[vehicle] = nil
        end
    else
        for vehicle, waitingVehicle in pairs(vehiclesWaiting) do
            local departureTime = waitingVehicle.departureTime
            local slot = waitingVehicle.slot
            local time = timetableHelper.getTime()
            -- Remove waitingVehicle if it is in invalid format
            if not (departureTime and slot) then
                vehiclesWaiting[vehicle] = nil
            elseif timetable.afterDepartureTime(departureTime, time) then
                vehiclesWaiting[vehicle] = nil
                print("PRUNING OLD WAITING VEHICLE SLOT")
            elseif arrivalTime <= departureTime then
                waitingSlots[vehicle] = slot
            else
                departedSlots[vehicle] = slot
            end
        end
    end

    -- Find if the slot with the closest arrival time is currently being used
    -- If true, find the next consecutive available slot
    for i = res.index, #slots + res.index - 1 do
        -- Need to make sure that 2 mod 2 returns 2 rather than 0
        local normalisedIndex = ((i - 1) % #slots) + 1

        local slot = slots[normalisedIndex]
        local slotAvailable = true
        if timetable.getWaitTime(slot, arrivalTime) <= 0 then
            slotAvailable = false
        elseif timetable.arrayContainsSlot(slot, waitingSlots) then
            slotAvailable = false
            -- if the nearest slot is still waiting, then all departedSlots can be removed
            for vehicle, _ in pairs(departedSlots) do
                vehiclesWaiting[vehicle] = nil
                departedSlots[vehicle] = nil
            end
        else
            -- if the nearest slot is a departed, all other departedSlots can be removed
            for vehicle, departedSlot in pairs(departedSlots) do
                if timetable.slotsEqual(slot, departedSlot) then
                    slotAvailable = false
                else
                    vehiclesWaiting[vehicle] = nil
                    departedSlots[vehicle] = nil
                end
            end
        end

        if slotAvailable then
            return slot
        end
    end

    -- If all slots are being used, still return the closest slot anyway.
    return slots[res.index]
end
```

### 修改 readyToDepartArrDep 函数

更新调用 `getNextSlot` 的地方以传递新参数：

```lua
--- ArrDep 类型的出发准备检查
---@param vehicle integer 列车ID
---@param doorsTime integer 门开启时间
---@param vehicles table 线路上的列车
---@param currentTime integer 当前时间
---@param line integer 线路ID
---@param stop integer 车站编号
---@param vehiclesWaiting table 等待车辆表
---@return boolean 是否准备好出发
function timetable.readyToDepartArrDep(vehicle, doorsTime, vehicles, currentTime, line, stop, vehiclesWaiting)
    local slots = timetableObject[line].stations[stop].conditions.ArrDep
    if not slots or slots == {} then
        timetableObject[line].stations[stop].conditions.type = "None"
        -- If there aren't any timetable slots, then the vehicle should depart now.
        return true
    end

    local slot = nil
    local departureTime = nil
    local validSlot = nil
    if  vehiclesWaiting[vehicle] then
        local arrivalTime = vehiclesWaiting[vehicle].arrivalTime
        slot = vehiclesWaiting[vehicle].slot
        departureTime = vehiclesWaiting[vehicle].departureTime

        -- Make sure the timetable slot for this vehicle isn't old. If it is old, remove it.
        if not arrivalTime or arrivalTime < doorsTime then
            vehiclesWaiting[vehicle] = nil
        elseif slot and departureTime then
            validSlot = timetable.arrayContainsSlot(slot, slots)
        end
    end
    if not validSlot then
        -- 传递额外参数给getNextSlot
        slot = timetable.getNextSlot(slots, doorsTime, vehiclesWaiting, line, stop, vehicle)
        -- getNextSlot returns nil when there are no slots. We should depart ASAP.
        if (slot == nil) then
            return true
        end
        local waitTime = timetable.getWaitTime(slot, doorsTime)
        departureTime = timetable.getDepartureTime(line, stop, doorsTime, waitTime)
        vehiclesWaiting[vehicle] = {
            arrivalTime = doorsTime,
            slot = slot,
            departureTime = departureTime
        }
    end

    if timetable.afterDepartureTime(departureTime, currentTime) then
        vehiclesWaiting[vehicle] = nil
        return true
    end

    return false
end
```

## 数据初始化和清理

### 在适当位置初始化 trainAssignments

确保在创建车站信息时初始化 `trainAssignments` 表：

```lua
-- 在setConditionType函数中
function timetable.setConditionType(line, stationNumber, type)
    local stationID = timetableHelper.getStationID(line, stationNumber)
    if not(line and stationNumber) then return -1 end

    if not timetableObject[line] then
        timetableObject[line] = { hasTimetable = false, stations = {} }
    end
    if not timetableObject[line].stations[stationNumber] then
        timetableObject[line].stations[stationNumber] = { 
            stationID = stationID, 
            conditions = {},
            -- 初始化trainAssignments
            trainAssignments = {}
        }
    end

    local stopInfo = timetableObject[line].stations[stationNumber]
    stopInfo.conditions.type = type

    if not stopInfo.conditions[type] then
        stopInfo.conditions[type] = {}
    end

    if type == "ArrDep" then
        if not stopInfo.vehiclesWaiting then
            stopInfo.vehiclesWaiting = {}
        end
        -- 确保trainAssignments存在
        if not stopInfo.trainAssignments then
            stopInfo.trainAssignments = {}
        end
    else
        stopInfo.vehiclesWaiting = nil
        stopInfo.trainAssignments = nil
    end
end
```

## 保存/加载考虑

虽然第一阶段不实现持久化，但我们应确保数据结构能够被序列化：

```lua
-- 在cleanTimetable函数中可以添加清理无效绑定的逻辑
function timetable.cleanTimetable()
    for lineID, _ in pairs(timetableObject) do
        if not timetableHelper.lineExists(lineID) then
            timetableObject[lineID] = nil
            print("removed line " .. lineID)
        else
            local stations = timetableHelper.getAllStations(lineID)
            for stationID = #stations + 1, #timetableObject[lineID].stations, 1 do
                timetableObject[lineID].stations[stationID] = nil
                print("removed station " .. stationID)
            end
            
            -- 清理每个车站的无效绑定
            for stationIndex, stationInfo in pairs(timetableObject[lineID].stations) do
                if stationInfo.trainAssignments then
                    timetable.clearInvalidAssignments(lineID, stationIndex)
                end
            end
        end
    end
end
```

## 错误处理和边界情况

1. 参数验证：所有公共函数都应验证输入参数
2. 空值检查：在访问嵌套表之前检查表是否存在
3. 类型检查：确保参数类型符合预期
4. 边界条件：处理空数组、不存在的索引等情况

## 测试考虑

为新功能编写单元测试：

1. `assignTrainToSlot` 成功和失败情况
2. `removeTrainAssignment` 正确移除绑定
3. `getAssignedSlot` 返回正确的绑定槽位
4. `isTrainAssigned` 正确识别绑定状态
5. `isValidSlot` 验证槽位有效性
6. `getNextSlot` 优先返回绑定槽位的逻辑
7. 与现有 `readyToDepartArrDep` 功能的集成

## 向后兼容性

1. 新增的 `trainAssignments` 字段默认为空表，不影响现有功能
2. 修改后的 `getNextSlot` 函数增加了可选参数，不会破坏现有调用
3. 只有在明确使用绑定功能时才会影响调度逻辑
4. 现有的时刻表约束和调度逻辑完全不受影响