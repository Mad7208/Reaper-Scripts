# Bildibeat Click Track Mapper

Version 10.21 for Windows and REAPER.

Build and verify REAPER section markers, tempo/time-signature maps, metronome
patterns, and synchronized MIDI/MP3 click packages from an XLSX or CSV song
structure. The app also supports read-only project comparison, tempo-edit
staging, project-to-workbook reconstruction, preview playback, and rollback.

## Requirements

- Windows x64
- REAPER 7.77 or newer
- SWS/S&M Extension
- Stock Windows PowerShell

## Install

1. Download and extract
   [`Bildibeat_Click_Track_Mapper_v10.21.zip`](../downloads/Bildibeat_Click_Track_Mapper_v10.21.zip).
2. Keep these three version-matched files together:
   - `Bildibeat_Click_Track_Mapper_v10_21.lua`
   - `Bildibeat_Click_Track_Mapper_Safe_Mode_v10_21.lua`
   - `Bildibeat_Click_Track_Mapper_README_v10_21.txt`
3. Copy them into REAPER's `Scripts` folder.
4. Load the main Lua file from **Actions > Show action list > ReaScript: Load**.

Read the [complete v10.21 manual](Bildibeat_Click_Track_Mapper_README_v10_21.txt)
before using the build or audio-conform features.
