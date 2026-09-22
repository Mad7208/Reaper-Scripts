# Bildibeat REAPER Tools

A collection of Lua tools for building click tracks, editing musical time, and
preparing verified show-track files in REAPER.

## Tools

| Tool | Version | What it does | Requirements |
| --- | --- | --- | --- |
| [Click Track Mapper](click-track-mapper/) | 10.21 | Builds and verifies section markers, tempo maps, click patterns, and portable MIDI/MP3 click packages from XLSX or CSV song structures. | Windows x64, REAPER 7.77+, SWS/S&M |
| [Musical Time Manager](musical-time-manager/) | 1.6 | Inserts or removes complete measures or beats, and retimes bar-aligned selections while protecting the rest of the project. | REAPER 7.75+, no extensions required |
| [Show Track App](show-track-app/) | 4.2 | Builds and verifies stereo show WAVs with IEM content on the left and optional FOH content on the right. | REAPER 7.77+; SWS 2.14+ recommended |

## Quick installation

1. Download the package you want from [`downloads/`](downloads/).
2. Extract it.
3. In REAPER, choose **Options > Show REAPER resource path in explorer/finder**.
4. Copy the extracted files into the `Scripts` folder. Keep every file from a
   package together unless that package's README says otherwise.
5. Open **Actions > Show action list**.
6. Choose **ReaScript: Load**, select the main `.lua` file, and run it or assign
   it to a shortcut or toolbar button.

Each tool folder contains browsable source code and its complete documentation.
The `downloads` folder contains ready-to-extract release packages.

## Repository layout

```text
Reaper-Scripts/
├── click-track-mapper/      Source and full v10.21 manual
├── musical-time-manager/    Source and full v1.6 manual
├── show-track-app/          Source and full v4.2 manual
└── downloads/               Ready-to-install ZIP packages
```

## Safety

These tools can make substantial changes to REAPER projects. Read the included
manual, save the project, and keep the automatically created safety copies and
audit files until you have verified the result.
