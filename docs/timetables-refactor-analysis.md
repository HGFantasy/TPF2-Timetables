# Timetable模块重构分析报告

## 概述

本文档详细分析了从提交70c7d14dccb5bcb8d27bdd332199d96d97c5488b到当前HEAD（ec33fad）对`res/scripts/celmi/timetables/timetable.lua`文件进行的主要更改。这些更改主要是由H3lyx的修改应用到原始1.3源码上产生的重构(refactor: apply H3lyx's modification on original 1.3 source)。

## 主要改进方面

### 1. 函数参数优化

#### `updateForVehicle`函数签名变更
旧版本：
```lua
function timetable.updateForVehicle(vehicle, vehicleInfo, line, vehicles)
```

新版本：
```lua
function timetable.updateForVehicle(vehicle, line, vehicles, vehicleState)
```

**改进说明：**
- 移除了重复的`vehicleInfo`参数，避免在函数内部多次调用`timetableHelper.getVehicleInfo(vehicle)`获取相同信息
- 新增了`vehicleState`参数，直接传递车辆状态信息，提高了性能并简化了函数逻辑
- 简化了函数调用逻辑，减少了不必要的条件判断

#### `departIfReady`函数签名变更
旧版本：
```lua
function timetable.departIfReady(vehicle, vehicleInfo, vehicles, line, stop)
```

新版本：
```lua
function timetable.departIfReady(vehicle, vehicles, line, stop, vehicleState)
```

**改进说明：**
- 同样移除了`vehicleInfo`参数，改为使用传入的`vehicleState`参数
- 直接使用`vehicleState.autoDeparture`和`vehicleState.doorsOpen`等属性，避免重复查询

### 2. 错误处理与调试增强

#### 失败情况打印增强
新增了错误提示信息：
```lua
function timetable.updateArrDep(line, station, indexKey, indexValue, value)
    -- ...
    else
        print("FAILED TO FIND DEPARTURE INDEX")
        return -2
    end
```

**改进说明：**
- 在更新ArrDep条件失败时增加调试信息输出，便于排查问题
- 提高了代码的可维护性和调试友好性

#### 车辆等待状态清理增强
在`getNextSlot`函数中增加了旧等待车辆槽位的清理机制：
```lua
local time = timetableHelper.getTime()
-- Remove waitingVehicle if it is in invalid format
if not (departureTime and slot) then
    vehiclesWaiting[vehicle] = nil
elseif timetable.afterDepartureTime(departureTime, time) then
    vehiclesWaiting[vehicle] = nil
    print("PRUNING OLD WAITING VEHICLE SLOT")
```

**改进说明：**
- 增加了时间检查，自动清理已经过期的等待车辆槽位
- 添加了清理操作的日志输出，方便跟踪系统行为
- 防止内存泄漏和无效数据占用资源

### 3. 条件判断逻辑优化

#### `readyToDepart`函数返回值修正
旧版本：
```lua
function timetable.readyToDepart(vehicle, arrivalTime, vehicles, line, stop)
    if not timetableObject[line] then return end
    if not timetableObject[line].stations then return end
    if not timetableObject[line].stations[stop] then return end
    if not timetableObject[line].stations[stop].conditions then return end
    if not timetableObject[line].stations[stop].conditions.type then return end
```

新版本：
```lua
function timetable.readyToDepart(vehicle, arrivalTime, vehicles, line, stop)
    if not timetableObject[line] then return true end
    if not timetableObject[line].stations then return true end
    if not timetableObject[line].stations[stop] then return true end
    if not timetableObject[line].stations[stop].conditions then return true end
    if not timetableObject[line].stations[stop].conditions.type then return true end
```

**改进说明：**
- 将空检查后的返回值从`nil`改为`true`，确保函数总是返回明确的布尔值
- 统一了返回逻辑，提高代码的一致性和可预测性

#### `readyToDepartArrDep`函数逻辑优化
新增了成功出发后清除等待车辆状态的逻辑：
```lua
if timetable.afterDepartureTime(departureTime, currentTime) then
    vehiclesWaiting[vehicle] = nil
    return true
end
```

**改进说明：**
- 在车辆准备出发后，及时清理其等待状态
- 避免了状态残留导致的问题

### 4. 强制出发功能完善

#### `getForceDepartureEnabled`函数逻辑完善
旧版本：
```lua
function timetable.getForceDepartureEnabled(line)
    if timetableObject[line] then
        -- if true or nil
        if timetableObject[line].forceDeparture ~= true then
            return false
        end
    end
    
    return false
end
```

新版本：
```lua
function timetable.getForceDepartureEnabled(line)
    if timetableObject[line] then
        -- if true or nil
        if timetableObject[line].forceDeparture == nil then
            timetableObject[line].forceDeparture = false
        end
        return timetableObject[line].forceDeparture
    end
    
    return false
end
```

**改进说明：**
- 明确处理了`nil`值的情况，将其初始化为`false`
- 简化了逻辑判断，使代码更清晰易懂
- 避免了潜在的`nil`值比较问题

### 5. 槽位可用性检查增强

#### `getNextSlot`函数中增加等待时间检查
新增了等待时间检查逻辑：
```lua
local slotAvailable = true
if timetable.getWaitTime(slot, arrivalTime) <= 0 then
    slotAvailable = false
elseif timetable.arrayContainsSlot(slot, waitingSlots) then
    slotAvailable = false
```

**改进说明：**
- 增加了对等待时间的检查，确保分配的槽位是有效的
- 防止分配已经过去的或者无效的时间槽位
- 提高了时间表调度的准确性

### 6. 代码结构优化

#### 移除了冗余的`updateFor`函数
旧版本包含了一个用于遍历车辆并更新的函数：
```lua
function timetable.updateFor(line, vehicles)
    for _, vehicle in pairs(vehicles) do
        local vehicleInfo = timetableHelper.getVehicleInfo(vehicle)
        if vehicleInfo then
            if timetable.hasTimetable(line) then
                timetable.updateForVehicle(vehicle, vehicleInfo, line, vehicles)
            elseif not vehicleInfo.autoDeparture then
                timetableHelper.restartAutoVehicleDeparture(vehicle)
            end
        end
    end
end
```

**改进说明：**
- 该函数被移除，可能是移到了其他地方实现或者采用了不同的更新策略
- 简化了timetable模块的职责，使其更加专注核心功能

#### 注释清理
移除了多余的空行和注释，使代码更加整洁：
```lua
local timetable = { }
local timetableObject = { }

function timetable.getTimetableObject()
    return timetableObject
end
```

**改进说明：**
- 删除了不必要的空行，提高了代码密度
- 清理了无用的调试注释，使代码更专业

## 总结

这次重构主要集中在以下几个方面：

1. **性能优化**：通过减少重复的函数调用和优化参数传递，提高了代码执行效率
2. **错误处理增强**：添加了更多的调试信息输出和错误状态清理机制
3. **逻辑完善**：修正了一些边界条件下的逻辑问题，使系统行为更加稳定可靠
4. **代码质量提升**：优化了函数签名、清理了冗余代码、统一了返回值逻辑

这些改进使得时间表系统的稳定性、可维护性和性能都得到了显著提升，为后续的功能扩展和维护奠定了良好基础。