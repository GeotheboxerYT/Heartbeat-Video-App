# HeartbeatVideo (Xcode Scaffold)

This folder contains a compile-ready Swift source scaffold for an iOS 17 SwiftUI app.

## Defaults used
- App name: `HeartbeatVideo`
- iOS target: `17.0`
- Orientation: portrait only
- Recording: video only
- Heart rate input: BLE Heart Rate Service (`0x180D`, characteristic `0x2A37`)

## Create the Xcode project
1. Open Xcode.
2. Create a new iOS App project named `HeartbeatVideo` with SwiftUI + Swift.
3. Delete the template `ContentView.swift` and app file.
4. Drag all files from this folder into the Xcode project target.
5. In target `Info`, add privacy keys from `Resources/Info.plist.template`.
6. Ensure `Signing & Capabilities` is set for your personal team.
7. Build and run on a real iPhone.

## Next implementation milestones
1. Verify BLE discovery and live BPM updates.
2. Record and save `video.mov` + `heartRate.json` in one session folder.
3. Improve playback timeline range using real video duration.
4. Add session list UI with metadata (date, duration).
