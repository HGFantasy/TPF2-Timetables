# THIS MOD IS IN ALPHA TESTING, PLEASE BE AWARE THAT INKNOW ERRORS MIGHT OCCUR!



# TPF2-Timetables V2

## Overview

This is a mod for Transport Fever 2 that adds a comprehensive timetable system to the game. It allows you to specify when vehicles should stop at stations and when they should depart, enabling realistic schedules for trains, buses, trams, and other vehicles.

## Features

### Core Timetable Types

For every stop on a line, you can choose between four modes:

- **None**: The vehicle uses vanilla game logic - stops, waits for loading to complete, and departs.
- **Arrival/Departure**: Specify exact arrival and departure time slots. Vehicles choose the nearest available slot and wait until the scheduled departure time.
- **Unbunch**: Enforces a minimum time span between departures at a station to prevent vehicles from bunching up.
- **AutoUnbunch**: Automatically spaces out vehicles by the line's frequency, with configurable buffer time for delays.

### Advanced Features

- **Train Assignment**: Bind specific vehicles to specific timetable slots for precise control
- **Platform Assignment**: Assign vehicles to specific platforms at stations
- **Maximum Delay Tolerance**: Configure threshold after which vehicles skip to next available slot
- **Delay Recovery Strategies**: Multiple recovery modes (catch up, skip to next, hold at terminus, gradual recovery, skip stops, reset at terminus)
- **Express/Local Patterns**: Skip-stop patterns for express and local services

### New Modules

- **Timetable Templates**: Save and reuse common timetable patterns (frequency-based, ArrDep, unbunch)
- **Timetable Validator**: Automatically detect conflicts, overlaps, and impossible schedules
- **Line Coordinator**: Coordinate timetables across multiple lines for synchronized transfers
- **Timetable Scheduler**: Time-based, day-based, seasonal, and event-based timetable variations
- **Timetable Visualizer**: Data export for timeline visualization and conflict analysis

### Analytics & Monitoring

- **Delay Tracking**: Comprehensive delay statistics per line and station
- **Delay Alerts**: Real-time notifications when delays exceed thresholds
- **Advanced Analytics**: Delay trends, punctuality heatmaps, service frequency analysis, capacity utilization metrics
- **Statistics Dashboard**: On-time performance, average delays, and service quality metrics

### Integration & Management

- **CommonAPI2 Integration**: Enhanced performance, persistence, event-driven updates, and resource management
- **Enhanced Export/Import**: Export timetables to files, import from files, timetable library for sharing
- **Batch Operations**: Apply templates, copy timetables, and configure settings across multiple lines/stations at once
- **Persistence**: Automatic save/load of all timetable data, settings, and statistics

## Installation

### Via Steam Workshop

Subscribe to the mod on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=2408373260).

### Manual Installation

1. Download the mod by clicking the green "Code" button on the top right of this page and selecting "Download ZIP"
2. Extract the files to your Transport Fever 2 mods folder:
   - **Windows**: `C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 2\mods`
   - **Linux**: `~/.steam/steam/steamapps/common/Transport Fever 2/mods`
   - **macOS**: `~/Library/Application Support/Steam/steamapps/common/Transport Fever 2/mods`
3. Ensure the folder is named `TPF2-Timetables` and contains a `mod.lua` file
4. The mod should now appear in your mod list in Transport Fever 2

**Note**: If TPF2 shows a warning about deprecated mod format, you can safely ignore it. The mod is fully functional.

## Usage

1. Open the line overview in Transport Fever 2
2. Enable timetables by checking the checkbox next to the line
3. Click on a station to configure its timetable constraints
4. Choose your timetable type (ArrDep, Unbunch, or AutoUnbunch)
5. Configure time slots, frequencies, or other settings as needed

Timetables only work when the checkbox on the line overview is enabled.

## CommonAPI2 Integration

This mod integrates with CommonAPI2 when available, providing:

- **Improved Performance**: Batch operations, caching, and optimized API calls
- **Persistent Data**: Automatic saving and loading of all mod data across game sessions
- **Event-Driven Updates**: Real-time updates when lines, vehicles, or stations change
- **Enhanced Reliability**: Better error handling and resource management

The mod gracefully falls back to native TPF2 APIs if CommonAPI2 is not available.

## Project Status

This mod is actively maintained and developed. It is a fork of the original [TPF2-Timetables mod](https://github.com/IncredibleHannes/TPF2-Timetables) by [@IncredibleHannes](https://github.com/IncredibleHannes), with contributions from [@Gregory365](https://github.com/Gregory365), [@quittung](https://github.com/quittung), [@H3lyx](https://github.com/H3lyx), [@HGFantasy] (https://github.com/HGFantasy/TPF2-Timetables) and others.

The current version includes significant enhancements:
- Full CommonAPI2 integration
- Advanced timetable management features
- Comprehensive analytics and monitoring
- Multiple new modules for extended functionality

## Compatibility

- **Save Compatibility**: Timetables from older versions can be imported, but saves cannot be transferred back to older versions
- **Breaking Changes**: 
  - Vehicles now use the *nearest* arrival time slot instead of *next* arrival time
  - Multiple vehicles at the same station will pick consecutive available slots when the nearest is taken

**Recommendation**: Make backups of saves before migrating to this version.

## Tutorials

- **English**: [YouTube Tutorial](https://www.youtube.com/watch?v=DFCW1PTCO4)
- **German**: [YouTube Tutorial](https://www.youtube.com/watch?v=ykh5ttBoTAs)
- **Advanced Timetabling for Local/Express**: [Steam Guide](https://steamcommunity.com/sharedfiles/filedetails/?id=2528355010)

## Contributing

Found a bug? Have an idea for a new feature? Want to help with documentation? Please open an issue or a pull request. Contributions are welcome!

### How to Contribute

1. Fork this repository
2. Create a branch for your changes
3. Make your modifications
4. Test thoroughly
5. Submit a pull request

If you want to discuss your changes before starting work, please open an issue or contact the maintainers on Discord.

### Development

For developers wanting to understand or modify the code, see the [technical documentation](documentation.md).

## Community

- **Discord Server**: [Join the TPF2-Timetables Discord](https://discord.gg/7KbVP8Fr6Z)
- **GitHub Issues**: [Report bugs or request features](https://github.com/Gregory365/TPF2-Timetables/issues)
- **Discussions**: Use the GitHub Discussions tab for questions and ideas

## License

See [LICENSE](LICENSE) file for details.

## Credits

- Original mod by [@IncredibleHannes](https://github.com/IncredibleHannes)
- Maintained and enhanced by [@Gregory365](https://github.com/Gregory365)
- Contributions from [@quittung](https://github.com/quittung), [@H3lyx](https://github.com/H3lyx), [@Celmi](https://github.com/Celmi), and the community
