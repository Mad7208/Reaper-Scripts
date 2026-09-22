# Bildibeat Musical Time Manager

Version 1.6 for REAPER.

Insert or remove complete measures, add or remove beats at a bar boundary, or
retime a bar-aligned selection while protecting material outside the edited
range. Every approved operation is a single undo step and creates a timestamped
project safety copy.

## Requirements

- REAPER 7.75 or newer
- No SWS, ReaPack, or ReaImGui dependency

## Install

1. Download and extract
   [`Bildibeat_Musical_Time_Manager_v1.6.zip`](../downloads/Bildibeat_Musical_Time_Manager_v1.6.zip).
2. Copy `Bildibeat_Musical_Time_Manager.lua` into REAPER's `Scripts` folder.
3. Load it from **Actions > Show action list > ReaScript: Load**.

See the [complete manual](Bildibeat_Musical_Time_Manager_README.txt) for the
preservation model, retiming workflow, and safety limits.
