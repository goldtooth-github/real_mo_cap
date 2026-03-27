# Low Power Mode Implementation - SimplePlant Ladybirds

## Overview
Successfully implemented automatic low power mode for SimplePlant Ladybirds simulation, matching the pattern used in Barley and Jellyfish simulations.

## Implementation Date
December 24, 2025

## Changes Made

### 1. SimplePlantLadybirdsSimulation.swift
**Added state variables:**
- `lowPowerMode: Bool` - tracks current power mode
- `originalLeafCount: Int?` - stores original leaf count
- `originalMaxLeaves: Int?` - stores original max leaves
- `originalLadybirdCount: Int?` - stores original ladybird count

**Added `setLowPowerMode(_ enabled: Bool)` method:**

#### When Enabled (Low Power):
- **Reduces leaf cell visibility by 75%** - Shows only 1 in 4 leaf cells (hides 3 out of 4)
- **Simplifies ladybirds** - Hides all leg nodes for reduced geometry
- **Preserves original config values** for restoration

#### When Disabled (Full Power):
- **Restores all leaf cells** - Makes all non-eaten cells visible
- **Restores ladybird legs** - Shows all leg detail
- **Clears saved original values**

### 2. SimplePlantSimulationAsync.swift
**Added passthrough method:**
```swift
func setLowPowerMode(_ enabled: Bool) { inner.setLowPowerMode(enabled) }
```

### 3. SimplePlantLadybirdsLifeformView.swift
**Added PowerModeMonitor:**
- `@StateObject private var powerModeMonitor = PowerModeMonitor()`

**Added onChange handler:**
```swift
.onChange(of: powerModeMonitor.isLowPowerMode) { _, isLowPower in
    simHolder.sim?.setLowPowerMode(isLowPower)
}
```

## How It Works

### Automatic Detection
- Uses `PowerModeMonitor` class (already exists in project)
- Monitors `ProcessInfo.processInfo.isLowPowerModeEnabled`
- Listens for `NSProcessInfoPowerStateDidChange` notifications
- Automatically triggers `setLowPowerMode()` when iOS enters/exits low power mode

### Performance Impact

#### Estimated Node Reduction in Low Power Mode:
- **Before:** ~4,800 nodes (30 leaves × 150 cells + stems + ladybirds)
- **After:** ~1,800 nodes (75% of leaf cells hidden + ladybird legs hidden)
- **Reduction:** ~62% fewer visible nodes

#### Material/Draw Call Reduction:
- Fewer visible cells = fewer material bindings
- Simplified ladybird geometry reduces overhead
- Maintains visual recognizability while improving performance

## Comparison with Other Simulations

### Barley (BarleySimulation.swift)
- Reduces stalk count by 50% (e.g., 40 → 20 stalks)
- Rebuilds entire field geometry
- Uses `originalStalkCount` to track original value

### Jellyfish (JellyfishSimulation.swift)
- Reduces dot count (25 → 6 dots)
- Reduces frill count (7 → 3 frills)
- Adjusts alpha values for simpler rendering
- Calls `reset()` to rebuild geometry

### SimplePlant (New Implementation)
- Reduces leaf cell visibility by 75%
- Simplifies ladybird geometry (hides legs)
- **Does NOT rebuild** - toggles visibility for instant switching
- More lightweight approach than Barley/Jellyfish

## Testing Recommendations

1. **Enable iOS Low Power Mode** in Settings → Battery
2. **Verify leaf cells** reduce to ~25% visible
3. **Verify ladybird legs** disappear (body remains)
4. **Disable Low Power Mode** and confirm full detail returns
5. **Check performance** metrics in Xcode Instruments

## Future Enhancements (Optional)

If further optimization needed:
- Reduce leaf count dynamically (like Barley's stalk reduction)
- Use single shared material for all leaf cells in low power mode
- Skip stem joint spheres in low power mode
- Reduce ladybird count (e.g., 5 → 2 ladybirds)
- Lower simulation update rate (120Hz → 60Hz)

## Code Consistency
✅ Matches Barley/Jellyfish pattern
✅ Uses PowerModeMonitor (same as other sims)
✅ Automatic iOS low power mode detection
✅ Clean separation: simulation logic in core, monitoring in view
✅ No compilation errors
