# 列车与时刻表绑定功能设计方案

## 概述

本方案旨在实现将特定列车与其运营时刻表（交路）绑定的功能，使每列车严格按照其预定的时间表运行，提高时刻表系统的真实性和可控性。

## 设计原则

1. **向后兼容**：新功能不应影响现有非绑定时刻表的正常工作
2. **渐进实现**：分阶段实现功能，降低开发风险
3. **用户友好**：提供直观的界面让用户管理和配置列车绑定
4. **数据持久化**：确保绑定关系在游戏保存/加载时正确保存

## 分阶段实现方案

### 第一阶段：核心逻辑扩展

#### 目标
在现有系统基础上增加对列车绑定的支持，不改变现有行为。

#### 实现内容

1. **数据结构扩展**
   - 在`stationInfo`中增加`trainAssignments`字段：
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

2. **新增核心函数**
   - `assignTrainToSlot(line, station, vehicle, slotIndex)` - 将列车绑定到特定时间槽
   - `removeTrainAssignment(line, station, vehicle)` - 解除列车绑定
   - `getAssignedSlot(line, station, vehicle)` - 获取列车的绑定时间槽
   - `isTrainAssigned(line, station, vehicle)` - 检查列车是否已绑定

3. **修改分配逻辑**
   - 在`getNextSlot`函数中增加检查：
     ```lua
     function timetable.getNextSlot(slots, arrivalTime, vehiclesWaiting, line, station, vehicle)
         -- 如果列车已绑定到特定时间槽，则优先返回绑定的时间槽
         if timetable.isTrainAssigned(line, station, vehicle) then
             local assignedSlot = timetable.getAssignedSlot(line, station, vehicle)
             -- 需要验证绑定的时间槽仍然有效
             if assignedSlot and timetable.isValidSlot(assignedSlot, arrivalTime) then
                 return assignedSlot
             end
         end

         -- 原有逻辑...
     end
     ```

4. **增加辅助函数**
   - `isValidSlot(slot, arrivalTime)` - 验证时间槽对当前到达时间是否有效
   - `clearInvalidAssignments(line, station)` - 清理无效的绑定关系

#### 影响范围
- 仅修改`timetable.lua`文件
- 不改变现有API接口
- 不影响未使用绑定功能的线路

### 第二阶段：GUI界面改造

#### 目标
提供用户友好的界面来管理和配置列车绑定关系。

#### 实现内容

1. **新增GUI组件**
   - 在车站时刻表编辑界面增加"列车绑定"选项卡
   - 显示当前已绑定的列车列表
   - 提供绑定/解绑操作按钮

2. **绑定配置界面**
   - 列出当前在线路上运行的所有列车
   - 显示可用的时间槽列表
   - 允许用户将列车拖拽到时间槽上完成绑定
   - 提供批量绑定功能

3. **可视化增强**
   - 在时刻表视图中用不同颜色标识已绑定的时间槽
   - 在列车信息中显示其绑定的时间槽信息

4. **交互逻辑**
   - 实时验证绑定的合法性
   - 提供冲突检测和解决建议
   - 支持撤销/重做操作

#### 影响范围
- 修改`timetable_gui.lua`文件
- 可能需要增加新的本地化字符串

### 第三阶段：数据持久化和高级功能

#### 目标
实现绑定关系的持久化存储，并增加高级管理功能。

#### 实现内容

1. **数据持久化**
   - 修改保存/加载逻辑以包含列车绑定信息
   - 确保在游戏重新加载后绑定关系得以恢复

2. **冲突处理**
   - 实现时间槽冲突检测机制
   - 提供自动解决冲突的选项
   - 增加冲突报告功能

3. **高级管理功能**
   - 批量导入/导出绑定配置
   - 基于模板的绑定配置（如按车型或线路自动生成绑定）
   - 绑定历史记录和变更追踪

4. **性能优化**
   - 优化大量列车绑定时的查找效率
   - 增加缓存机制减少重复计算

#### 影响范围
- 修改保存/加载相关函数
- 可能需要扩展现有数据结构

## 技术细节

### API设计

1. **核心API**
   ```lua
   -- 绑定列车到时间槽
   timetable.assignTrainToSlot(line, station, vehicle, slotIndex)

   -- 解除列车绑定
   timetable.removeTrainAssignment(line, station, vehicle)

   -- 获取列车绑定信息
   timetable.getTrainAssignment(line, station, vehicle)

   -- 检查列车是否已绑定
   timetable.isTrainAssigned(line, station, vehicle)
   ```

2. **GUI集成API**
   ```lua
   -- 获取可用于绑定的列车列表
   timetable.getAssignableTrains(line, station)

   -- 获取车站的时间槽信息
   timetable.getStationSlots(line, station)
   ```

### 数据存储格式

在保存文件中，列车绑定信息将以如下格式存储：
```lua
trainAssignments = {
    [lineId] = {
        [stationNumber] = {
            [vehicleId] = {
                slotIndex = 1,
                slot = {12, 30, 15, 00}  -- 到达小时, 到达分钟, 出发小时, 出发分钟
            }
        }
    }
}
```

## 风险评估和缓解措施

### 技术风险
1. **性能影响**：大量列车绑定可能导致性能下降
   - 缓解措施：实现高效的查找算法和缓存机制

2. **数据一致性**：保存/加载过程中可能出现数据不一致
   - 缓解措施：增加数据校验和修复机制

### 用户体验风险
1. **学习曲线**：新功能可能增加用户学习成本
   - 缓解措施：提供详细的帮助文档和引导教程

2. **误操作风险**：复杂的绑定关系可能导致用户误操作
   - 缓解措施：增加确认对话框和撤销功能

## 后续优化方向

1. **智能绑定**：基于列车类型、线路特征等自动推荐绑定关系
2. **动态调整**：根据实际运行情况动态调整绑定关系
3. **多线路协调**：在复杂网络中协调不同线路间的列车绑定