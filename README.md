# LFO_RELEASE_2025

This repository contains the release snapshot of the Universa LFO MIDI output work for 2025.

Highlights:
- SceneKit-rendered simulation (MeshBird) drives MIDI CC output.
- Per-frame MIDI dispatch on the main thread with coalescing for smooth, glitch-free sends.
- LFO overlay ring history throttled to ~30 Hz to reduce SwiftUI invalidations.

Getting started
- Open universa.xcodeproj in Xcode 15+ (iOS 17 SDK recommended).
- Run on device for BLE/CoreMIDI.

Branches
- main: release branch mirrored from local RELEASE_IT.

Publishing
- Tag format: vYYYY.N (e.g., v2025.1).
