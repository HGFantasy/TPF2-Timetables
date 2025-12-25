# Technical Documentation

## Introduction

This is the technical documentation for the TPF2-Timetables mod. It is intended for developers who want to understand or modify the code. Normal users should read the [README](README.md) instead.

---

## Architecture Overview

### Module Structure

The mod is organized into several modules:

#### Core Modules

- **`timetable.lua`**: Main timetable control logic. Handles slot assignment, delay recovery, train/platform assignments, and batch operations.
- **`timetable_helper.lua`**: Game API interaction layer. Provides wrappers for game APIs, CommonAPI2 integration, event handling, and utility functions.
- **`timetable_gui.lua`**: GUI implementation. Creates menus, handles user input, and displays timetable information.

#### Supporting Modules

- **`delay_tracker.lua`**: Delay tracking, statistics, alerts, and advanced analytics
- **`settings.lua`**: Centralized configuration management with CommonAPI2 persistence
- **`persistence_manager.lua`**: Unified persistence coordination for all mod data
- **`guard.lua`**: Safety and validation utilities
- **`route_finder.lua`**: Route finding, network analysis, and automatic timetable generation

#### Feature Modules

- **`timetable_templates.lua`**: Template system for saving and reusing timetable patterns
- **`timetable_validator.lua`**: Conflict detection and timetable validation
- **`line_coordinator.lua`**: Multi-line coordination for synchronized transfers
- **`timetable_scheduler.lua`**: Seasonal and event-based timetable variations
- **`timetable_visualizer.lua`**: Data export for visualization and analysis
- **`network_graph_cache.lua`**: Network graph caching and invalidation

### CommonAPI2 Integration

The mod extensively uses CommonAPI2 when available, with graceful fallback to native APIs:

- **Persistence**: Automatic save/load via `commonapi.persistence`
- **Events**: Event-driven updates via `commonapi.events`
- **Commands**: Optimized command batching via `commonapi.cmd`
- **Components**: Batch component operations via `commonapi.getComponents`
- **Logging**: Structured logging via `commonapi.log`
- **Localization**: String/number/time formatting via `commonapi.localization`
- **Error Reporting**: Enhanced error reporting via `commonapi.error`
- **Performance**: Metrics reporting via `commonapi.performance`

### Data Flow

```
Game Events → timetable_helper (event listeners) → timetable (update logic) → delay_tracker (statistics)
                                                                              ↓
                                                                    persistence_manager (save/load)
```

---

## Core Functionality

### Timetable Control Logic

The control logic is implemented in `timetable.lua`. It reads the timetable object and decides whether a particular vehicle should wait at a station.

#### Main Functions

- **`timetable.updateForVehicle(vehicle, line, vehicles, vehicleState, currentTime)`**: Called periodically for each vehicle. Checks if the vehicle should wait based on timetable constraints.
- **`timetable.readyToDepart(vehicle, arrivalTime, vehicles, line, stop, currentTime)`**: Determines if a vehicle is ready to depart from a station.
- **`timetable.readyToDepartArrDep(...)`**: Handles ArrDep constraint logic.
- **`timetable.readyToDepartDebounce(...)`**: Handles Unbunch/AutoUnbunch constraint logic.
- **`timetable.departIfReady(...)`**: Checks if vehicle should depart and triggers departure if ready.

### Wait Logic

Whether a vehicle needs to wait depends on several factors:
- The type of timetable constraint (ArrDep, Unbunch, AutoUnbunch)
- The last departure time for that line/station
- The current time
- Vehicle assignments (if train assignment is enabled)
- Delay tolerance settings
- Delay recovery mode

For every stop, the script tracks:
- The last recorded departure
- A list of vehicles currently waiting with their intended departure times
- Train assignments (vehicle-to-slot bindings)
- Platform assignments (vehicle-to-platform bindings)

When a vehicle arrives at a station, `timetable.updateForVehicle()` is called. If a timetable constraint exists and the vehicle is not registered in the waiting list, it assumes the vehicle just arrived and assigns a departure time.

### Arrival/Departure Constraint

With ArrDep constraints, users specify arrival/departure time slots. The system:

1. Finds the nearest available slot based on arrival time
2. Checks if the slot is already assigned to another vehicle
3. If train assignment exists, uses the assigned slot (if valid)
4. Assigns the vehicle to the slot and calculates departure time
5. Applies delay recovery strategies if the vehicle is delayed
6. Checks maximum delay tolerance and skips to next slot if exceeded

**Slot Selection Algorithm:**
- Uses `timetable.getNextSlot()` to find the nearest available slot
- Considers vehicles already waiting to avoid conflicts
- Respects train assignments if configured
- Handles slot conflicts by finding the next consecutive available slot

### Unbunch Constraints

Unbunch constraints guarantee a minimum separation between vehicles on a line. The departure time assigned is always the last departure plus the time span set in the constraint.

**AutoUnbunch** automatically calculates the separation based on the line's frequency, with configurable buffer time for delays.

### Delay Recovery

Multiple delay recovery modes are available:

- **`catch_up`**: Try to return to schedule (default behavior)
- **`skip_to_next`**: Abandon current slot, use next available
- **`hold_at_terminus`**: Wait longer at end stations to realign
- **`gradual_recovery`**: Slowly return to schedule over multiple stops
- **`skip_stops`**: Skip intermediate stops to catch up
- **`reset_at_terminus`**: Reset schedule at terminus stations

### Maximum Delay Tolerance

When enabled, if a vehicle's delay exceeds the configured threshold, it will skip the current slot and move to the next available slot. This prevents vehicles from trying to catch up to unrecoverable delays.

### Train Assignment

Vehicles can be assigned to specific timetable slots:

- **`timetable.assignTrainToSlot(line, stop, vehicle, slotIndex)`**: Binds a vehicle to a specific slot
- **`timetable.removeTrainAssignment(line, stop, vehicle)`**: Removes the assignment
- **`timetable.getTrainAssignment(line, stop, vehicle)`**: Gets assignment info
- **`timetable.isTrainAssigned(line, stop, vehicle)`**: Checks if assigned

When a vehicle has an assignment, `getNextSlot()` prioritizes the assigned slot if it's still valid.

### Platform Assignment

Vehicles can be assigned to specific platforms at stations:

- **`timetable.assignVehicleToPlatform(line, stop, vehicle, platform)`**: Assigns vehicle to platform
- **`timetable.getPlatformAssignment(line, stop, vehicle)`**: Gets platform assignment
- **`timetable.getAvailablePlatforms(line, stop, maxPlatforms)`**: Lists available platforms

---

## API Interaction

### Getting Data

The mod uses `timetable_helper.lua` for all game API interactions:

- **Vehicle Information**: `timetableHelper.getVehicleInfo(vehicle)`, `timetableHelper.getLineVehicles(line, time)`
- **Station Information**: `timetableHelper.getStationID(line, stop)`, `timetableHelper.getStationName(stationID)`
- **Line Information**: `timetableHelper.getLineInfo(line)`, `timetableHelper.getAllStations(line)`
- **Component Access**: `timetableHelper.getComponent(entity, componentType, time)` (with CommonAPI2 batch support)

### Sending Commands

Commands are created and sent through CommonAPI2 when available:

```lua
-- Via CommonAPI2 (preferred)
local cmd = commonapi2_cmd.make.setVehicleShouldDepart(vehicle)
commonapi2_cmd.send(cmd)

-- Fallback to native API
local cmd = api.cmd.make.setVehicleShouldDepart(vehicle)
api.cmd.sendCommand(cmd)
```

**Key Commands:**
- **`setUserStopped`**: Stops a vehicle (same as user pressing "Stop")
- **`setVehicleManualDeparture`**: Prevents vehicle from departing automatically
- **`setVehicleShouldDepart`**: Commands vehicle to depart immediately

### CommonAPI2 Integration

The mod uses CommonAPI2 for:

- **Batch Operations**: `timetableHelper.batchGetLineComponents()`, `timetableHelper.batchGetVehicleComponents()`
- **Event Subscriptions**: `timetableHelper.addEventListener()` for line/vehicle/station changes
- **Persistence**: Automatic save/load via `persistenceManager`
- **Caching**: Intelligent cache invalidation based on events
- **Performance**: Metrics reporting and resource management

---

## New Features

### Timetable Templates

The `timetable_templates.lua` module provides:

- **Template Creation**: Save common timetable patterns (frequency-based, ArrDep slots, unbunch)
- **Template Application**: Apply templates to lines/stations with variable substitution
- **Template Management**: Create, update, delete, and list templates
- **Persistence**: Templates are saved via CommonAPI2

### Timetable Validation

The `timetable_validator.lua` module provides:

- **Conflict Detection**: Finds overlapping slots, duplicate assignments, platform conflicts
- **Validation**: Checks for impossible travel times, invalid slot structures
- **Warnings**: Identifies potential issues before they cause problems
- **Line/Station Validation**: Validate individual stations or entire lines

### Line Coordination

The `line_coordinator.lua` module provides:

- **Transfer Points**: Define connections between lines at stations
- **Synchronization**: Automatically adjust departure times for coordinated transfers
- **Connection Times**: Configurable minimum connection times
- **Multi-Line Support**: Coordinate multiple lines at transfer hubs

### Timetable Scheduler

The `timetable_scheduler.lua` module provides:

- **Time-Based Schedules**: Different timetables for peak hours, off-peak, etc.
- **Day-Based Schedules**: Weekday vs weekend variations
- **Seasonal Schedules**: Different timetables for different seasons (when API available)
- **Event Schedules**: Manually activated special event timetables

### Delay Tracking & Analytics

The `delay_tracker.lua` module provides:

- **Delay Recording**: Tracks arrival and departure delays
- **Statistics**: On-time percentage, average delays, min/max delays
- **Alert System**: Notifications when delays exceed thresholds
- **Advanced Analytics**:
  - Delay trends over time
  - Punctuality heatmaps (by time of day)
  - Service frequency analysis
  - Capacity utilization metrics
  - Delay pattern detection

### Timetable Visualizer

The `timetable_visualizer.lua` module provides:

- **Timeline Data**: Vehicle positions and schedules over time
- **Station Occupancy**: Vehicle counts per time slot
- **Conflict Visualization**: Identifies and reports scheduling conflicts
- **Export**: Text export for debugging and analysis

---

## Persistence System

All mod data is persisted via `persistence_manager.lua`:

- **Timetable Data**: All timetable constraints, assignments, and settings
- **Delay Statistics**: Historical delay data and statistics
- **Templates**: Saved timetable templates
- **Settings**: Global mod settings
- **Coordination Data**: Multi-line transfer points
- **Scheduler Data**: Seasonal/event schedule definitions

The persistence system:
- Uses CommonAPI2 when available
- Falls back to native APIs if needed
- Handles data versioning and migration
- Auto-saves periodically
- Loads on game start

---

## Performance Optimizations

The mod includes several performance optimizations:

- **Caching**: Entity existence, component access, sorted slots, vehicle state
- **Batch Operations**: Group multiple API calls into single operations
- **Event-Driven Updates**: Only update when changes occur (via CommonAPI2 events)
- **Lazy Loading**: Load data only when needed
- **Cache Invalidation**: Smart cache clearing based on events and memory pressure

---

## Error Handling

The mod uses comprehensive error handling:

- **Safe API Calls**: All CommonAPI2 calls wrapped in `pcall`
- **Graceful Degradation**: Falls back to native APIs if CommonAPI2 unavailable
- **Error Reporting**: Uses CommonAPI2 error reporting when available
- **Logging**: Structured logging with multiple levels (debug, info, warn, error)

---

## Data Structures

### Timetable Object

```lua
timetableObject = {
    [lineID] = {
        hasTimetable = true,
        frequency = 900,  -- seconds
        stations = {
            [stopNumber] = {
                stationID = 123,
                conditions = {
                    type = "ArrDep" | "debounce" | "auto_debounce" | "None",
                    ArrDep = {{arrMin, arrSec, depMin, depSec}, ...},
                    debounce = interval  -- seconds
                },
                vehiclesWaiting = {
                    [vehicleID] = {
                        arrivalTime = 1800,
                        slot = {30, 0, 35, 0},
                        departureTime = 2100
                    }
                },
                trainAssignments = {
                    [vehicleID] = {
                        slotIndex = 1,
                        slot = {30, 0, 35, 0}
                    }
                },
                platformAssignments = {
                    [vehicleID] = 1  -- platform number
                },
                maxDelayTolerance = 300,  -- seconds
                maxDelayToleranceEnabled = true,
                delayRecoveryMode = "catch_up"
            }
        }
    }
}
```

---

## Extension Points

Developers can extend the mod by:

1. **Adding New Modules**: Create new Lua modules following the existing patterns
2. **Event Listeners**: Subscribe to timetable events via `timetableHelper.addEventListener()`
3. **Custom Recovery Modes**: Add new delay recovery strategies
4. **Template Types**: Extend the template system with new pattern types
5. **Analytics**: Add custom analytics functions to `delay_tracker.lua`

---

## Testing

The mod includes test files in the `tests/` directory:

- `timetable_tests.lua`: Core timetable logic tests
- `timetable_helper_tests.lua`: Helper function tests
- `test_nextDeparture.lua`: Slot selection algorithm tests

Run tests to verify functionality after making changes.

---

## Future Considerations

Potential areas for future enhancement:

- GUI improvements for new features
- Additional visualization options
- Enhanced demand-based timetable generation
- More sophisticated delay recovery algorithms
- Integration with other TPF2 mods
