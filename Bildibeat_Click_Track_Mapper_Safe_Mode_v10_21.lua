-- Bildibeat Click Track Mapper v10.21 - Safe Mode launcher
-- Keep this file beside Bildibeat_Click_Track_Mapper_v10_21.lua.
-- Safe Mode loads exactly the same v10.21 main code and production parser as a
-- normal launch. It ignores remembered workspace/layout state and tempo-edit recovery restoration
-- for one run; it does not read, overwrite, or delete a
-- normal-session recovery record. It does not delete preferences or bypass validation, automatic project checks,
-- preflight, logging, verified rollback, COUNT IN, END, BPM, Ramp, Repeat, or
-- Block safety contracts.
--
-- v10.21 retains staged Section, Part, and END underlying-BPM editing. Section
-- edits preserve No Accent and may add the Section's total loaded-workbook BPM
-- difference to explicit Part overrides. Repeated edits are recalculated from
-- that baseline and cannot accumulate drift. REAPER BPM is recalculated from
-- the underlying BPM and click multiplier but is never directly editable.
-- Repeated Parts and every repeated Block pass remain tied to their source.
--
-- Rows whose underlying BPM, calculated REAPER BPM, or Ramp destination differs
-- from the loaded workbook baseline are tinted yellow. Selection keeps a blue
-- edge. Revert Tempo Edit restores the selected yellow row or Shift-selected
-- rows to the loaded workbook, deduplicates Repeat/Block occurrences, confirms
-- Section-wide consequences, and preserves unrelated Part edits. Reloading or
-- validating restores every saved value after a broader discard confirmation.
-- Close, workbook switching, unload, preference reset, and revalidation report
-- the exact number of affected Sections and logical source Parts, plus END when
-- applicable, before staged edits can be discarded. Normal mode writes each
-- accepted edit to a fingerprint/source-hash-bound recovery record and restores
-- it only after the unchanged workbook passes the production parser again.
-- Undo Last Build changes REAPER only and leaves the plan marked as not applied.
-- Accent behavior remains read-only: No Accent, normal Section accents, and
-- automatic COUNT IN accents cannot be changed by editing or reversion.
--
-- Build & Project includes the same explicit audio policy as normal mode.
-- Preserve Audio Exactly is the safe default and restores/verifies positions,
-- lengths, rates, pitch, timebases, fades, take offsets, and stretch markers.
-- Conform Audio to New Tempo — Preserve Pitch is available only when project
-- marker order/measure positions, COUNT IN/END, meter/count, Repeat/Block
-- expansion, and Ramp boundaries exactly match the validated workbook. Locked,
-- mixed audio/MIDI, boundary-crossing, or structurally mismatched material
-- blocks Conform instead of being guessed. Source media is never rewritten or
-- deleted. The click-map build, audio handling, verification, and rollback use
-- one REAPER undo transaction and verify both tempo/map and audio signatures.
--
-- Validate Against Open Project remains a separate read-only action from
-- Validate Only. It checks the active tab's COUNT IN, Section markers,
-- expanded Part starts, meters, calculated REAPER BPM, click patterns, Ramp
-- boundaries/linear states, END, and unexpected extra events without changing
-- project, workbook, media, transport, undo, or save state. Compact labels are
-- Compare Open Project and Project Match. The retired Validation Diff button is
-- not restored; a failed workbook validation uses that slot for Validation
-- Issues. PRJ-007 documents comparison differences and failures. An exact match
-- authorizes Preview Play, Stop, Loop, and 50% Speed for that exact plan,
-- project tab, and project signature without requiring a rebuild. Section and
-- Part BPM edits can then be staged normally; edited values require a verified
-- build before the changed Preview can be auditioned.
--
-- Create Verified Workbook From Open Project is also retained. It reads the
-- active project's exact COUNT IN, END, Section-marker names, meters, tempos,
-- click patterns, and Ramps without modifying REAPER. Repeats, Blocks, and
-- tuplets are inferred conservatively; the production parser must reproduce the
-- project one-for-one before XLSX/CSV Save is offered, and the saved file is
-- reopened and verified again. RCN-001 through RCN-011 document and log failures.
--
-- The original workbook is never overwritten. Save Updated Workbook Copy is
-- enabled only after the exact staged plan is built and verified. A verified
-- XLSX/CSV copy is reopened through the production parser, adopted as the new
-- validated baseline, and clears the yellow differences without invalidating
-- the matching built REAPER plan.
--
-- Export MIDI + MP3 Click is the same non-mutating full-plan export as normal
-- mode. It writes a synchronized type-1 MIDI tempo/meter/marker and channel-10
-- wood-block click file plus an audible MP3 with the same base name. Both begin
-- with automatic COUNT IN at time zero and end at the validated END boundary.
-- MIDI adds no note at END; MP3 adds no extra beat and only a 75 ms safety tail.
-- Existing files are never overwritten. The export synthesizes its own complete
-- event list and is independent of REAPER live-metronome playback/record,
-- count-in, pattern, and routing settings. Exact required/audio/MIDI/WAV-consumed
-- click counts must agree or export stops. The verified result table is retained
-- through the protected export transaction so success confirmation cannot index
-- the xpcall boolean. Generic Part Names Off keeps workbook Section names in
-- MIDI marker metadata; On writes PART 1, PART 2, and so on. COUNT IN and END
-- remain explicit, and REAPER project markers never change. CPX-001 through
-- CPX-006 remain active.
--
-- User-Friendly Song Structure offers Simplified Readout, Measure Numbers,
-- Show BPM, Generic Part Names, exact MM:SS Duration Calculator, text export,
-- and print. Generic names use PART 1, PART 2, and so on while keeping COUNT-IN
-- and END explicit; workbook Sections and REAPER markers are not renamed.
-- Page numbering is left to the browser/operating-system print dialog, and the
-- redundant full-song Copy Readout action is not present.
--
-- Preview supports single-click plain English, double-click jump,
-- Up/Down/Home/End/Enter navigation, Shift-selected ranges, and right-click
-- actions. Copy Syntax is selection-aware and per row. Send to Scratchpad turns
-- highlighted playable rows into one ordered expression with explicit underlying
-- BPM values, opens Help, validates it, and waits for Play Preview; it never
-- autoplays or changes REAPER. Jump to Ramp appears only for an active Ramp.
--
-- Verified-map audition keeps Play, Stop, Loop, and 50% Speed. It excludes the
-- following Part's first click and restores the earlier time selection, loop,
-- repeat, stop-at-loop-end, playrate, and preserve-pitch state. Tempo Preview is
-- a separate main-page card with a metronome icon, BPM field, and Play/Stop.
-- Syntax Scratchpad audio uses Play Preview, Stop, Loop, and 50% Speed without
-- inserting media or rebuilding the project.
--
-- ENT(N) is an Eighth Note Triplet at x1.5; SXT{N}, QNT{N}, and SPT{N} are
-- Sextuplet x3, Quintuplet x5, and Septuplet x7. "120 no accent" uses all-A
-- clicks for that musical Section while automatic COUNT IN remains accented.
-- Click Frequencies default to A 1760 Hz / B 1600 Hz. A verified build enables
-- REAPER's native metronome; failure and Undo restore the pre-build state.
--
-- Settings consolidates window, panels, Preview columns, and horizontal scroll
-- under Remember Layout. Restore Default Layout resets all four. Diagnostics
-- contains Copy Diagnostics and Create Support Bundle; Clean Up Logs appears
-- only in Settings. Unload Current Workbook and every action that can replace or
-- close a staged plan warns before discarding it and its recovery copy.
--
-- Dynamic resizing, pane-scoped TOOLTIP messages, MM-DD-YYYY calendars, wrapped and scrollable errors,
-- and Larger text throughout app apply to all app-owned
-- panes and dialogs. Segoe UI is used for prose and all Help headings, including
-- punctuated headings such as IN-APP TEMPO EDITING; Consolas is limited to raw
-- syntax/examples and normalized syntax. The retired MODIFIED badge, separate
-- Build Preview/Export Preview, Reset Tempo Edits, Page Numbers, full-song Copy
-- Readout, and redundant Settings controls are not restored in Safe Mode.
--
-- The pre-build and post-build prompts use unique editable REAPER .RPP names.
-- Safe Mode shares the same Help, README discovery, Error Reference, diagnostics,
-- build logging, SWS dependency, post-build verification, and parser/self-tests
-- as normal mode. Parser Self-Test includes the automated golden compact,
-- Windows client-border, standard, wide, wide-short, and compact/wide-short
-- Larger Text visual-regression matrix for all main panes, Preview footers,
-- app/confirmation dialogs, and calendars. README
-- guidance explains Preserve/Conform audio behavior, REAPER timebase effects
-- on MIDI/automation/custom content, and preserve-pitch locations.
-- Browse prefers REAPER's current GetUserFileName chooser and automatically
-- falls back to the older core GetUserFileNameForRead chooser. Safe Mode
-- therefore keeps the same XLSX/CSV file-selection compatibility as normal mode.

local EXTSTATE_SECTION = "REAPER_Song_Structure_Builder"
local function script_directory()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1,1) == "@" then source = source:sub(2) end
  return source:match("^(.*[\\/])") or ""
end

local main_path = script_directory() .. "Bildibeat_Click_Track_Mapper_v10_21.lua"
local f = io.open(main_path, "rb")
if not f then
  reaper.ShowMessageBox("Safe Mode could not find the main script beside this launcher:\n\n" .. main_path .. "\n\nKeep both Lua files in the same folder.", "Bildibeat Click Track Mapper - Safe Mode", 0)
  return
end
f:close()
reaper.SetExtState(EXTSTATE_SECTION, "safe_mode_once", "1", false)
local ok, err = pcall(dofile, main_path)
if not ok then
  reaper.DeleteExtState(EXTSTATE_SECTION, "safe_mode_once", false)
  reaper.ShowMessageBox("Bildibeat Click Track Mapper failed to start in Safe Mode:\n\n" .. tostring(err), "Safe Mode Error", 0)
end
