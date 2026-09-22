# Bildibeat Show Track App

Version 4.2 for REAPER.

Build and verify a stereo 24-bit PCM show WAV from labeled REAPER tracks. The
left channel carries the mono IEM mix; the right carries optional FOH content.
The app provides source analysis, click replacement, preview mixing, bounded
repair, audit files, interrupted-render recovery, and complete show-folder
validation.

## Requirements

- REAPER 7.77 or newer
- Write access to REAPER's resource folder and the output folder
- SWS 2.14 or newer is strongly recommended, but not required

## Install

1. Download and extract
   [`Bildibeat_Show_Track_App_v4.2.zip`](../downloads/Bildibeat_Show_Track_App_v4.2.zip).
2. Copy `Bildibeat_Show_Track_App_v4.2.lua` into REAPER's `Scripts` folder.
3. Load only that Lua file from **Actions > Show action list > ReaScript: Load**.

Read the [complete manual](README.txt) before the first show build, especially
the track-label, routing, click-sample, and hardware-loopback sections.
