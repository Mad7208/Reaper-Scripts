BILDIBEAT CLICK TRACK MAPPER V10.21
Made by Bidlibop
Windows / REAPER edition

======================================================================
RELEASE FILES
======================================================================

Keep these three matching v10.21 files together:

- Bildibeat_Click_Track_Mapper_v10_21.lua
- Bildibeat_Click_Track_Mapper_Safe_Mode_v10_21.lua
- Bildibeat_Click_Track_Mapper_README_v10_21.txt

The app discovers the highest numbered matching README beside the running
script. Numeric version comparison makes v10.21 newer than v10.15.

This build is Windows-only. It uses Windows PowerShell for XLSX extraction,
clipboard integration, file/folder dialogs, exports, and support bundles. The
Lua parser and most REAPER APIs are portable, but the complete v10.21 package
is not advertised as macOS-compatible.

Target environment: REAPER 7.77 or newer on Windows x64, the SWS/S&M
Extension, and stock Windows PowerShell. SWS/S&M lets the app operate REAPER's
native A/B metronome-frequency fields and apply/restore the 50% audition's
Preserve pitch in audio items setting.

======================================================================
WHAT IS NEW IN V10.21
======================================================================

- Create Verified Workbook From Open Project is a new Workbook action. It reads
  the active REAPER project without changing it and reconstructs a fresh XLSX or
  CSV from COUNT IN, END, exact Section-marker names, meter, tempo, click accent
  patterns, and linear ramps.
- Reconstruction is verification-first. The inferred rows are expanded with the
  production parser and compared against the project marker/tempo/click map.
  If any marker, bar, meter, tempo, pattern, Ramp, COUNT IN, or END detail differs,
  no file is offered. After saving, the file is reopened and verified a second
  time; an unverified file is removed.
- Ordinary repeats are compacted where exact. Repeated multi-Part sequences may
  become < > Blocks only when the complete sequence repeats identically and does
  not create ambiguous Ramp behavior. The analyzer tries the compact form first
  and automatically falls back to non-Block syntax if that is the only exact
  representation.
- Tuplet names are inferred only when the effective project tempo is an exact
  supported multiple of the chosen underlying Section BPM: ENT x1.5, SXT x3,
  QNT x5, or SPT x7. Ambiguous 4/4 material remains ordinary [N] syntax with an
  explicit @BPM override instead of being guessed.
- RCN-001 through RCN-011 document off-grid markers, conflicting Section names,
  unsupported meters/patterns, ambiguous ramps, stale-project transactions,
  writer failures, and post-save verification failures. Failures are also logged
  beside saved projects under SONG STRUCTURE BUILD LOGS.
- Export MIDI + MP3 Click is a new prominent full-width Build-page action. It
  creates a synchronized portable package from the complete current validated
  plan without rebuilding or changing the REAPER project.
- One editable Save As base name produces two new same-stem files: a type-1
  Standard MIDI File and an audible MP3. Existing files are never overwritten.
  The MIDI has a tempo/meter/marker track and a General MIDI channel-10
  wood-block click track, so importing its tempo and time signatures in Logic or
  Pro Tools can create the matching bar grid.
- MIDI marker metadata follows the current Generic Part Names toggle. Off keeps
  workbook Section names; On writes PART 1, PART 2, and so on. COUNT IN and END
  remain explicit, and neither the workbook nor REAPER project markers change.
- MIDI and MP3 both begin with automatic COUNT IN at time zero. There is no
  leading silence or separate intro tail. The MIDI has no click at END, and the
  MP3 adds no extra beat—only a 75 ms audio safety tail so its last click is not
  truncated. CPX-001 through CPX-006 cover every export stage.
- Exported clicks are independent of REAPER's live metronome playback/record,
  count-in, pattern, and routing settings. Exact mathematical click-count checks
  require the audio schedule, consumed WAV onsets, and explicit MIDI notes to
  agree before either final file is delivered.
- The complete export-button transaction now preserves its verified result table
  through the protected export call. A successful file export therefore reaches
  its confirmation dialog instead of producing a boolean-index ReaScript error.
- Validate Against Open Project is a new, separate read-only comparison. Validate
  Only still validates workbook contents; the new action checks that the active
  REAPER tab has the same Section markers, expanded Part starts, meters,
  calculated REAPER BPM, click accents, Ramps, COUNT IN, END, and no unexpected
  extra marker/tempo events. It reports Exact Match or every mismatch.
- The redundant Validation Diff button is removed. If workbook validation fails,
  its fourth control slot becomes Validation Issues; after successful validation,
  it becomes Validate Against Open Project.
- Build & Project now has an explicit audio policy for tempo-map rebuilding.
  Preserve Audio Exactly is the safe default and signature-verifies that every
  detected audio item's position, length, rate, pitch, timebase, fades, take
  offsets, and stretch markers remain unchanged.
- Conform Audio to New Tempo — Preserve Pitch keeps eligible audio on the same
  musical counts while REAPER rate-stretches it to the new BPM without changing
  pitch. It unlocks only when marker order/measure positions, COUNT IN/END,
  meter/count, Repeat/Block expansion, and Ramp boundaries match exactly.
  Changed counts and unsafe items block Conform instead of being guessed.
- Audio handling, click-map construction, verification, and rollback share one
  REAPER undo transaction. Failed builds and Undo Last Build verify the original
  audio signature as well as marker/tempo state. Source media files are never
  rewritten or deleted, and AUD-005 through AUD-008 document build-audio errors.
- Staged tempo changes are now compared directly with the currently loaded
  workbook. Every impacted Preview row is tinted yellow when its underlying
  BPM, calculated REAPER BPM, or Ramp destination differs. Repeated Parts and
  repeated Block passes are all highlighted; time-only downstream shifts are
  not. A selected changed row keeps the yellow fill with a blue selection edge,
  and hovering it states the workbook and staged values.
- Right-click Edit Section BPM, Edit Part BPM, and Edit END BPM remain
  non-destructive. Section edits preserve No Accent and can optionally move
  explicit Part overrides by the Section's total additive difference from the
  loaded workbook. Repeated Section edits are recomputed from that baseline,
  preventing cumulative drift. Calculated REAPER BPM updates automatically but
  is never directly editable.
- Revert Tempo Edit replaces the former chronological tempo-undo control. It is
  enabled only for selected yellow changed rows and restores their logical
  Section, Part, Ramp destination, or END sources to the loaded workbook.
  Shift-selected rows are supported; Repeat/Block occurrences are deduplicated,
  Section-wide consequences are confirmed, and unrelated Part edits remain
  staged. Reloading or validating remains the broader discard-all workflow.
- Accent behavior is read-only throughout tempo editing and reversion. A loaded
  "no accent" Section remains no accent, normal Sections remain accented, and
  automatic COUNT-IN retains its accented first beat.
- Save Updated Workbook Copy is available only after the exact staged plan is
  built and verified. The new XLSX/CSV is reopened through the production
  parser, adopted as the current workbook baseline, and immediately treated as
  validated. Its yellow row differences clear while the verified REAPER-project
  association remains valid. The original workbook is never overwritten.
- Undo Last Build changes REAPER only. The staged plan remains visible and is
  explicitly marked as not currently applied; audition and updated-workbook
  saving stay disabled until the displayed plan is built and verified again.
- The retired MODIFIED badge, Build Preview, Export Preview, Reset Tempo Edits,
  and separate read-only preview controls are removed. The automatic project
  snapshot and preflight still run after validation and again immediately before
  Build. Open User-Friendly Song Structure is now the prominent full-width
  readout action.
- User-Friendly Song Structure removes its Page Numbers and full-song Copy
  Readout controls. Export and Print remain. Generic Part Names can replace
  musical Section headings with PART 1, PART 2, and so on in full and Simplified
  output, durations, export, and print; COUNT-IN and END stay explicit. REAPER
  marker names and workbook content are unchanged.
- Preview row actions add Send to Scratchpad. It converts the currently
  highlighted playable rows into one ordered expression with explicit underlying
  BPM values, opens Help, validates the result, and waits for the user to choose
  Play Preview. It never starts audio or changes REAPER automatically.
- Tempo Preview remains a separate main-page card with a metronome icon, one BPM
  text field, and Play/Stop. Syntax Scratchpad can play the complete parsed
  expression with Stop, Loop, and 50% Speed controls.
- Settings is consolidated: Remember Layout owns the window, panels, Preview
  columns, and horizontal scroll; Restore Default Layout resets all of them.
  Diagnostics opens one modal containing Copy Diagnostics and Create Support
  Bundle. Clean Up Logs appears only in Settings. Validation errors are always
  complete, wrapped, and scrollable.
- Unload Current Workbook replaces Reset Current Workspace. Browse, Recent
  Files, Validate Only, Unload, Reset App Preferences, app Close, and window
  close all warn before discarding staged edits. The warning reports the exact
  number of affected Sections and logical source Parts, plus END when relevant.
- Every accepted tempo edit is mirrored to a compact crash/session-recovery
  record in REAPER's resource Data folder. Restoration is offered only after
  the same workbook path validates with the identical file fingerprint and
  source SHA-256. Damaged, stale, or mismatched recovery data is never applied.
- The Preview-row audition boundary excludes the following Part's first click.
  Play, Stop, Loop, and 50% Speed restore the prior REAPER transport, loop,
  playrate, and preserve-pitch state. A verified build enables REAPER's native
  metronome and applies editable A/B click defaults of 1760/1600 Hz.
- SPT{N} is Septuplet syntax at underlying BPM x7. ENT(N), SXT{N}, and QNT{N}
  remain Eighth Note Triplet x1.5, Sextuplet x3, and Quintuplet x5. Section BPM
  text such as "120 no accent" uses all-A clicks while automatic COUNT-IN keeps
  its normal accented first beat.
- Responsive window, modal, Help, error, table, footer, and Larger-text layouts
  are rechecked at minimum, default, expanded, and wide-short sizes. Segoe UI is
  used for prose and musician-facing text; Consolas is limited to raw syntax,
  examples, and normalized syntax output.
- Parser Self-Test includes a golden automated visual-regression matrix for
  Build, History, Settings, Help, Preview footers, app/confirmation dialogs,
  and calendars at compact, real Windows client-border, standard, wide,
  wide-short, compact Larger Text, and wide-short Larger Text sizes.
- Browse now detects REAPER's available file-dialog API. It prefers the current
  filtered GetUserFileName chooser and automatically falls back to the older
  core GetUserFileNameForRead chooser, preserving XLSX/CSV selection on REAPER
  installations that predate the newer call.
- Help headings containing punctuation such as IN-APP TEMPO EDITING use the
  normal Segoe UI heading style. Consolas remains limited to genuine syntax.
- Help, Error Reference, tooltips, Safe Mode, parser/self-tests, and this README
  are synchronized with the v10.21 behavior.

======================================================================
CORE TERMS
======================================================================

Section
  One non-END workbook row. Its Section name creates a standard REAPER marker
  at the section start. Its BPM supplies the inherited underlying tempo, and
  its PARTS cell supplies the playable structure.

Part
  One playable meter/click instruction inside a PARTS cell. A Part may include
  a bar Repeat, BPM Override, and Ramp.

Block
  One or more ordinary Parts selected inside < > and treated as one repeatable
  entity. Repeating a Block creates passes but does not create extra REAPER
  Section markers.

Ramp
  One or more trailing dashes on an ordinary Part. Each dash adds one final
  bar to the continuous tempo transition toward the next legal destination.

BPM Override
  @BPM changes the underlying tempo for that Part only. If the Part is a
  simulated click type, its multiplier is applied after the BPM Override.

======================================================================
QUICK START
======================================================================

1. Save the workbook.
2. Save the active REAPER project at least once as an .RPP.
3. Run Bildibeat_Click_Track_Mapper_v10_21.lua from REAPER.
4. Browse to the saved XLSX or CSV workbook.
5. Choose Validate Only.
6. Review Validated Preview. Optionally choose Validate Against Open Project to
   compare it explicitly with the active REAPER tab.
7. Optionally right-click Preview rows to stage Section, Part, or END BPM edits.
   Review the updated Section BPM and calculated REAPER BPM values. Use Revert
   Tempo Edit if needed, or reload the workbook to restore all saved values.
8. Optionally use Tempo Preview, add Build Notes, send selected rows to the
   Syntax Scratchpad, or open User-Friendly Song Structure.
9. Optionally choose Export MIDI + MP3 Click to create a portable click package.
   Or choose Create Verified Workbook From Open Project to reconstruct a new
   XLSX/CSV from the current project without changing REAPER.
10. Choose Build Click Track Map, or Apply & Verify Tempo Edits when staged.
11. Choose whether to save a separate pre-build REAPER project.
12. Review the final timed confirmation, then build. The automatic REAPER
    project check and structural preflight run without a separate Preview button.
13. After successful verification, optionally save a verified updated workbook
    copy, then save the completed REAPER project when
    prompted.

Browse is compatible with both REAPER file-dialog generations. Current REAPER
uses the filtered GetUserFileName chooser. Older installations automatically
use the core GetUserFileNameForRead chooser, after which the app confirms that
the selected file ends in .xlsx or .csv. Neither path requires an optional
extension. WB-015 appears only if the REAPER installation provides neither
core chooser.

======================================================================
VALIDATE AGAINST OPEN PROJECT
======================================================================

Validate Only and Validate Against Open Project answer different questions:

- Validate Only: Is the saved XLSX/CSV internally valid and safe to parse?
- Validate Against Open Project: Does that currently validated structure exactly
  match the active REAPER project tab?

The project comparison is explicitly read-only. It checks:

- Automatic two-bar COUNT IN and song start at visible measure 3.
- Standard Section marker names, order, and measure positions.
- Every expanded Part start generated by ordinary repeats and Block passes.
- Meter and calculated REAPER BPM at every Part boundary.
- A/B click accent patterns, including No Accent Sections.
- Ramp start boundaries and REAPER linear-tempo states.
- END position, meter, and destination tempo.
- Unexpected extra standard markers or tempo/time-signature events.

An exact result reports the project name and Section, expanded-Part, marker, and
tempo-event totals. A mismatch result lists each discrepancy with its
Section/Part/measure context. The check does not edit or save the workbook or
project, move media, touch transport, create an undo point, or change app tempo
edits. It can compare the validated workbook with whichever project tab is
currently active.

An exact match authorizes Preview Play, Stop, Loop, and 50% Speed for that exact
validated plan, project tab, and project marker/tempo/click signature. Existing
matching projects can therefore be auditioned without rebuilding. Section and
Part BPM edits may be staged from that clean baseline, but the newly edited
Preview no longer matches REAPER and cannot be auditioned until the edit is
built and verified. Reverting every edit to the unchanged matched baseline makes
the original authorization valid again.

At compact widths the button reads Compare Open Project; compact Larger Text uses
Project Match. Both have the same tooltip and behavior. If workbook validation
has errors, that fourth Workbook control temporarily becomes Validation Issues
so the complete wrapped error list remains one click away. PRJ-007 covers a
comparison mismatch or failure. The retired Validation Diff control is absent.

======================================================================
CREATE VERIFIED WORKBOOK FROM OPEN PROJECT
======================================================================

This is the reverse of a normal Build. It is intended for a project whose
musical click map already exists but whose source workbook is missing or needs
to be recreated.

The analyzer requires:

- One standard marker named COUNT IN on visible measure 1.
- Exactly two accented 4/4 COUNT IN bars at one BPM.
- The first uniquely named Section marker on visible measure 3.
- One uniquely named standard marker for each later Section start.
- One standard marker named END at the exact final boundary.
- Tempo/time-signature events, Section markers, and Ramp starts/targets on exact
  measure boundaries.
- Meters whose denominators have supported syntax: 4, 8, 16, or 32.
- One consistent normal-accent or no-accent click pattern within each Section.

Actual marker spelling and capitalization are preserved in SECTION NAME cells.
COUNT IN and END remain explicit automatic anchors. Unrelated standard markers
cannot be silently discarded; convert them to regions or remove them before
reconstruction. Regions are not turned into workbook Sections.

For the first Section, the two-bar COUNT IN establishes the underlying Section
BPM. Later Sections use the simplest underlying BPM that explains the greatest
amount of material without overrides. A tuplet label is used only for an exact
supported ratio. When the project contains only one ambiguous 4/4 effective
tempo, the conservative result is ordinary Quarter Note syntax, not a guessed
tuplet.

The app first builds the simplest exact Part runs. It then looks for adjacent
identical multi-Part sequences that can safely be represented as <...>xR.
Detection never crosses a Section boundary and never wraps a one-Part Block.
Ramp-containing repetition is left expanded unless its Block semantics are
unambiguous. The compact candidate and a non-Block fallback both pass through
the production parser; only a candidate whose expanded map is one-for-one with
the project can reach Save.

The review dialog reports Section, expanded-Part, musical-bar, tempo-event,
marker, and inferred-Block counts. Save Verified XLSX creates a formatted
workbook with a frozen header and useful column widths. Save Verified CSV creates
the same three-column data without formatting. Both use an editable timestamped
default name and never overwrite the REAPER project. The saved file is reopened,
parsed, and compared again against the unchanged project. If the project changes
while the dialog is open, RCN-009 requires a fresh analysis.

Reconstruction does not move the edit cursor, start playback, create tracks or
items, change markers/tempo, alter audio/MIDI, create an undo point, or replace
the currently loaded workbook. Open Generated Workbook is offered only after
post-save verification passes.

======================================================================
WORKBOOK FORMAT
======================================================================

The first sheet/CSV table uses three columns:

SECTION NAME | BPM | PARTS

- The first musical row must have a Section name and BPM.
- Every musical row requires a unique Section name and creates one standard
  REAPER marker at that row's start.
- Section names create standard REAPER markers at the Section start.
- COUNT IN is reserved and is created automatically by the app.
- END is the required final row.
- END PARTS must be blank.
- Workbook changes must be saved before validation can read them.

COMPLETE SPREADSHEET EXAMPLE

The Help button Copy Spreadsheet Example and the Scratchpad Reset example use
the same supported syntax families. Copy Spreadsheet Example copies:

SECTION NAME | BPM | PARTS
INTRO | 120 | [4]x2, (7)x3@135--
VERSE | 160 | {9}x2@160, *11*x2@170-
CHORUS | 120 | ENT(4)x2@120, SXT{7}x2@100-
BRIDGE | 90 | QNT{5}x2@90-, <[3]x2@140, SXT{5}@110->x2
BREAKDOWN | 110 no accent | SPT{7}x2@110-
OUTRO | 130 | [4]x2@130--
END | 90 |

======================================================================
PART SYNTAX
======================================================================

Ordinary note-value meters

  [N]       N/4, Quarter Note click
  (N)       N/8, Eighth Note click
  {N}       N/16, Sixteenth Note click
  *N*       N/32, Thirty-Second Note click

Simulated click types

  ENT(N)     N/4 at underlying BPM x1.5, Eighth Note Triplet
  SXT{N}    N/4 at underlying BPM x3, Sextuplet
  QNT{N}    N/4 at underlying BPM x5, Quintuplet
  SPT{N}    N/4 at underlying BPM x7, Septuplet

Terminology is uniform throughout the app:

- ENT is translated as Eighth Note Triplet.
- SXT is translated as Sextuplet.
- QNT is translated as Quintuplet.
- SPT is translated as Septuplet.
- Literal workbook syntax uses ENT, SXT, QNT, and SPT.

The former ET(N) and QUINT{N} spellings are invalid in v10.21. ENT(N) retains
the same x1.5 timing, SXT{N} remains x3, and QNT{N} retains the same x5 timing.
Whitespace is ignored, so QNT {5} is accepted and normalized to QNT{5}. STP
is not an alias for SPT and is rejected with a specific correction. No
simulated-rhythm multiplier or resulting tempo math changed in this release.

Part Repeat

  xR or XR repeats one ordinary Part for R total bars.

Examples:

  [4]x8      eight bars of 4/4
  SXT{7}x3   three bars of 7/4 with a Sextuplet click
  SPT{7}x2   two bars of 7/4 with a Septuplet click

R must be a positive whole number. Omitting xR means one bar.

BPM Override

  @BPM changes the underlying BPM of that Part only.

Examples:

  [4]@150
  SXT{7}@100      effective REAPER BPM is 300
  QNT{5}@90    effective REAPER BPM is 450
  SPT{7}@80    effective REAPER BPM is 560

The next Part again inherits its Section BPM unless it has its own @BPM.

Ramp

  -      Ramp over the final one bar of the Part
  --     Ramp over the final two bars
  ---    Ramp over the final three bars

The number of dashes cannot exceed that Part's bar count. The destination is
the next legal Part or END. A Ramp can cross a normal Section boundary. A
normal Part immediately before a Block may Ramp into the Block's first Part.

Modifier order

  METER, optional xR, optional @BPM, then trailing Ramp dashes

Examples:

  [4]x4@150--
  ENT(4)x2@120-
  SXT{7}x3@110--
  QNT{5}x2@90-
  SPT{7}x2@80-

======================================================================
SECTION BPM AND NO ACCENT
======================================================================

A normal BPM cell contains one positive number, such as:

  120

To remove the accented downbeat from every musical Part in that Section, add
the words "no accent":

  120 no accent

Capitalization and extra spaces are accepted. The app normalizes the value to
"120 no accent". This is a Section setting, not a Part modifier: every beat in
that Section uses the primary A click. The next Section returns to the normal
A-then-B pattern unless its own BPM cell also says "no accent". The automatic
COUNT IN always retains the normal accented first beat.

The @BPM Part modifier still means a temporary underlying musical BPM Override;
it does not change the Section's accent mode.

======================================================================
IN-APP TEMPO EDITING
======================================================================

The current workbook baseline remains the authority. In-app edits are staged
in memory and rebuilt through the production parser before the Preview accepts
them. The Section column shows both Section name and underlying Section BPM.
The calculated REAPER BPM column is read-only: when an
underlying BPM changes, each Quarter/Eighth/Sixteenth/Thirty-Second/ENT/SXT/QNT/
SPT multiplier is reapplied automatically.

Right-click row actions:

- Edit Section BPM changes the inherited BPM for the entire source Section.
  No Accent from the worksheet is preserved. Parts without @BPM inherit the
  new Section BPM.
- If the Section contains explicit @BPM overrides, the dialog includes a fully
  wrapped checkbox: shift explicit Part BPM Overrides by the Section's numerical
  difference from the loaded workbook. With it off, @135 remains @135 when the
  Section changes from 120 to 123. With it on, @135 becomes @138. Editing the
  same Section again to 126 produces @141 from the original 120/@135 baseline,
  not @144 from an accumulated shift. This is additive, not a percentage or
  multiplier. A separately edited Part is independently tracked.
- Edit Part BPM changes the selected source Part's underlying BPM. If that
  source Part is expanded by xR or a repeated < > group, every generated
  occurrence changes together. A BPM equal to its Section is normalized by
  removing the redundant @BPM token.
- Edit END BPM stages the legal Ramp destination BPM. A blank value restores
  the app's normal 25 BPM non-ramped END behavior.
- COUNT IN does not have an independent editable BPM. Edit the first Section
  BPM; COUNT IN follows it and remains normally accented.

Revert Tempo Edit is selection-aware rather than chronological. Select one
yellow changed row, or Shift-select a range containing yellow rows. The button
restores every distinct staged source required for those rows to match the
currently loaded workbook:

- An inherited row restores its Section BPM. All inherited rows from that
  Section update, and any explicit overrides shifted by the Section checkbox
  return to their workbook values.
- An individually edited Part restores that logical source Part. Every xR or
  repeated-Block occurrence updates together.
- A Ramp row can restore the edited destination responsible for its changed
  Ramp value.
- END restores the workbook END BPM cell.
- If both Section and Part changes are required for a selected row to match the
  workbook, the confirmation identifies and restores both.
- Multiple selected occurrences of one logical source are processed only once.

The confirmation lists Section-wide consequences and the number of Preview rows
that will refresh. Unrelated staged Part edits remain intact. To discard every
staged edit, reload or validate the workbook and confirm the broader warning.
Neither reversion nor reloading changes REAPER or the workbook. Apply & Verify
Tempo Edits performs the normal save, automatic project-check, preflight,
transaction, and verification workflow after rereading the source and proving
the staged hash still equals the displayed Preview.

Accent behavior is never editable in the app. For example, editing a loaded
"120 no accent" Section to 126 behaves as "126 no accent," and reverting it
returns to "120 no accent." Normal Section accents and the automatic COUNT-IN
accented first beat are likewise preserved.

Every expanded Preview row whose underlying BPM, calculated REAPER BPM, or Ramp
destination differs from the workbook baseline is tinted yellow. A changed row
that is selected keeps its yellow fill and gains a blue selection edge. Hovering
the row shows its workbook and staged values. Repeated Parts and every repeated
Block pass are highlighted consistently; a row is not highlighted merely
because an earlier edit changed its absolute clock position.

All failures are wrapped and scrollable, logged when part of a build attempt,
and searchable as EDT-001 through EDT-005 in Error Reference.

======================================================================
UNSAVED TEMPO-EDIT PROTECTION AND SESSION RECOVERY
======================================================================

Staged BPM edits are protected before any action that would replace or unload
their workbook baseline:

- Closing the app from its Close button or the window close control.
- Choosing another workbook with Browse or Recent Files.
- Reloading/revalidating the current workbook.
- Unloading the current workbook.
- Resetting app preferences.

The confirmation reports the exact number of changed Sections and distinct
logical source Parts, plus END when its destination BPM changed. Repeated xR
occurrences and repeated Block passes count once per source Part, not once per
expanded Preview row. Cancel returns to the unchanged staged Preview. Confirming
discard removes the staged data and its recovery copy; it never modifies the
workbook or REAPER project.

Each successful Section, Part, END, or Revert operation also refreshes a compact
temporary recovery file named:

  Bildibeat_Click_Track_Mapper_v10_21_Tempo_Recovery.txt

It is stored in REAPER's resource Data folder and contains the saved workbook
path, complete file fingerprint, source SHA-256, staged source-cell values,
independent Part values, Section override-shift policy, END value, and tempo
audit text. It does not contain the whole workbook or REAPER project.

After a crash, forced stop, or other interrupted session:

1. Launch the normal v10.21 script.
2. Select and validate the same unchanged workbook.
3. If path, fingerprint, and source hash all match, choose Restore Staged Edits
   or Discard Recovery.
4. Restored data is rebuilt through the normal production parser before it can
   appear in Preview. Yellow rows, calculated REAPER BPM, Ramps, durations,
   readouts, audition, and Scratchpad output are recalculated normally.

A workbook with different saved contents is never accepted merely because its
filename is the same. A damaged or parser-invalid record is also rejected and
removed after the warning. Safe Mode ignores recovery restoration for that run
without deleting the record. Saving and adopting a verified updated workbook
copy clears the old recovery because the new workbook is now the clean baseline.

Session Recovery Error Reference entries:

- REC-001: workbook fingerprint/source mismatch.
- REC-002: damaged, incomplete, unsupported, or parser-invalid recovery data.
- REC-003: recovery record could not be written.
- REC-004: confirmed recovery discard could not delete the temporary file.

======================================================================
UPDATED WORKBOOK COPY
======================================================================

Save Updated Workbook Copy is normally disabled. It becomes available only
when all of these statements are true:

- At least one tempo edit is staged.
- The exact staged plan was applied and verified in REAPER.
- The same REAPER project is active and its marker/tempo signature is unchanged.
- The original source workbook still matches its validated fingerprint.

The Save As dialog suggests a unique editable name such as:

  My Song_CTM_TEMPO_UPDATE_2026-07-20_143500_ID-01FB.xlsx

The user may change it. The original source path is explicitly rejected, so the
source cannot be overwritten. XLSX output starts as a complete copy of the
original package and changes only staged BPM/PARTS cells on the validated sheet;
other worksheets and ordinary package content remain present. CSV output keeps
the original row structure and replaces only staged cells.

After writing, the app reopens the new file through the production parser. Its
plan hash must exactly match the staged plan that was built and verified. If it
does not, the unverified destination is deleted. After exact verification, the
new copy becomes the current validated workbook baseline automatically. The
yellow row highlighting and tempo-edit history clear, while the verified
REAPER association remains valid because the musical plan did not change.
Workbook-copy failures use WBK-001 through WBK-004 and include a likely fix and
alternate next step.

Undo Last Build affects REAPER only. It intentionally leaves staged Preview
values visible and labels them as not currently applied. Audition and Save
Updated Workbook Copy remain unavailable until the displayed plan is built and
verified again.

======================================================================
BLOCK SYNTAX
======================================================================

Form:

  <PART, PART, ...>xR

The Parts inside < > are one Block. The optional xR after > repeats the whole
Block for R passes. Omit it for one pass. x1 is valid.

Example:

  <[4]x2@120, SXT{7}@100->x2

This expands in chronological order as:

  Block Pass 1 of 2, Part 1 of 2: [4]x2@120
  Block Pass 1 of 2, Part 2 of 2: SXT{7}@100-
  Block Pass 2 of 2, Part 1 of 2: [4]x2@120
  Block Pass 2 of 2, Part 2 of 2: SXT{7}@100-

On pass 1, the final internal SXT Ramp targets the first [4] Part on pass 2.
On pass 2, that same final internal Ramp is inactive because it cannot escape
the closing > boundary. Whatever follows the Block starts normally.

Rules:

- Blocks remain inside one PARTS cell.
- Blocks cannot nest.
- Ordinary Part Repeat, BPM Override, and Ramp modifiers work inside a Block.
- A non-final internal Ramp targets the next internal Part on every pass.
- A final internal Ramp targets the first Part of the next Block pass.
- A final internal Ramp is inactive on the last pass and never crosses >.
- A one-pass Block may not end with an internal Ramp because it has no next
  pass. That is a validation error, not a silently ignored modifier.
- A Ramp modifier immediately after > or >xR is not allowed.
- A Block-level @BPM after > is not allowed.
- A normal Part before a Block may still Ramp into the first Block Part.
- Expansion is limited to 10,000 Part occurrences per PARTS cell.

Examples of invalid Block syntax:

  <[4], SXT{7}>x2-       Block-level Ramp is not allowed
  <[4], SXT{7}>@120      Block-level BPM Override is not allowed
  <[4], SXT{7}->         final internal Ramp has no next pass
  <[4], <SXT{7}>x2>x2   nested Block is not allowed

======================================================================
COUNT IN, FIRST BPM, AND END
======================================================================

COUNT IN

- Automatically created at visible measure 1.
- Always two bars of 4/4 in visible measures 1 and 2.
- Uses the BPM column from the first musical Section row.
- Spreadsheet processing begins at visible measure 3.
- COUNT IN is a reserved Section name.

First musical Part

- May omit @BPM.
- May use @BPM exactly equal to the first Section BPM.
- May not use a different underlying first-Part BPM Override.
- Eighth Note Triplet, Sextuplet, Quintuplet, and Septuplet Parts are allowed because their
  effective REAPER multiplier does not change the underlying Section BPM.

END

- END is the final required row.
- END PARTS is blank.
- If the last outside Part has a legal Ramp, it targets END BPM.
- Otherwise the app uses its standard non-ramped END behavior.

======================================================================
VALIDATED PREVIEW AND SYNTAX BADGES
======================================================================

Single-click a Preview row to place a concise plain-English translation in the
bottom bar. The message is pane-scoped: History, Settings, and Help show their
own relevant tooltip/status text.

Show Syntax Badges uses complete readable labels:

- Quarter Note
- Eighth Note
- Sixteenth Note
- Thirty-Second Note
- Eighth Note Triplet
- Sextuplet
- Quintuplet
- Septuplet
- No Accent
- Repeat x2 (or the actual Repeat count)
- BPM Override: 150 (or the actual BPM)
- Ramp: 1 Bar / Ramp: N Bars
- Ramp Inactive
- Block Pass 1 of 2 (or the actual pass values)

These names use uniform title-style capitalization. Unexplained ENT, SXT,
QNT, SPT, R1, R-OFF, or similar abbreviations are not used as visible badges.

Mouse actions

- Single-click: select and show concise plain English.
- Shift-click: extend or shrink one contiguous audition selection; the range
  may cross Section boundaries.
- Double-click valid Part: move REAPER edit cursor to the Part start.
- Double-click END: move edit cursor to the standard END marker.
- Right-click: open full readout and contextual actions.
- Right-click actions include Copy Readout and selection-aware Copy Syntax.
  Copy Syntax copies only the selected Part row, or joins all Shift-selected
  Part rows in order; it does not substitute the original whole-Block wrapper.
- Jump to Ramp appears only for a row with an active Ramp.

Right-click row explanations is enabled by default in Settings. When disabled,
the compact actions-only menu remains available.

Keyboard Preview actions

- Tab / Shift+Tab: move focus.
- Up / Down: select the previous or next Preview row.
- Shift+Up / Shift+Down: extend the contiguous audition selection.
- Home / End: select the first or last Preview row.
- Enter or Shift+F10: open row actions.
- Escape: close row actions.

There are no J or R Preview shortcuts in v10.21.

Audition controls

- Available only after the current validated structure has been built,
  verified, and still matches the active REAPER project.
- Play auditions the selected Part rows once. Loop repeats the selected range.
  The audition range ends 20 milliseconds before the following Part's
  downbeat. For one-shot audition the app temporarily enables REAPER's native
  "stop playback at end of loop if repeat is disabled" transport behavior, so
  that next Part's first click is never buffered or included. [4]x2 therefore
  produces exactly eight clicks.
- Stop stops playback and returns the edit cursor to the beginning of the
  earliest selected Part.
- 50% Speed temporarily sets project playback to half speed and enables
  master-playrate pitch preservation so the click can be inspected closely.
- Ending audition restores the previous time selection, loop points, repeat
  state, native stop-at-loop-end setting, project play rate, and
  master-playrate preserve-pitch state. The edit cursor intentionally stays at
  the first selected Part after Stop.
- COUNT IN may be auditioned; END is not an auditionable Part.
- Existing double-click jumps and right-click row actions remain unchanged.

Tempo Preview is a separate, compact card on the main Build page. It does not
require a built map because it plays generated temporary audio instead of the
project transport. Enter an underlying musical BPM from 20 through 400 in its
single text field. Play or Enter starts a continuously looping four-beat
reference; Stop ends it.

The reference is a 4/4 Quarter Note click whose synthesized frequency remains
unchanged. SWS background
preview is preferred so no media item, track, marker, tempo event, loop point,
cursor position, or project undo state is changed. Error Reference AUD-001
through AUD-004 covers scheduling, WAV creation, and preview-backend failures.

======================================================================
MIDI + MP3 CLICK PACKAGE
======================================================================

Export MIDI + MP3 Click becomes available after a workbook has a current,
successful validation. It does not require a built map because it renders from
the exact plan displayed in Validated Preview, and it does not change the active
REAPER project.

One editable Save As base filename creates both:

- .mid: Standard MIDI File format 1, PPQ 960.
  - Track 1 contains tempo, time signatures, COUNT IN, Section markers, and END.
  - Track 2 contains General MIDI channel-10 High/Low Wood Block click notes.
  - Calculated REAPER BPM is used for simulated click multipliers so tuplets and
    Ramps retain their exact musical bar timing.
- .mp3: mono audible click using the current editable A/B click frequencies.

Both outputs are generated from the same part list and duration contract:

- Automatic two-bar 4/4 COUNT IN begins immediately at time zero.
- There is no leading silence and no separate intro tail.
- Every ordinary Part, Repeat, Block pass, BPM Override, meter, No Accent state,
  and Ramp follows the validated plan.
- END is a boundary and marker, not an extra click.
- The authored MP3 adds only a 75 ms safety tail after END so the last click can
  decay without being cut off. MP3 encoder padding can add a tiny technical
  delay, but the app does not author another beat.

MIDI marker naming follows User-Friendly Song Structure's Generic Part Names
toggle at export time:

- Off: COUNT IN, original workbook Section names, END.
- On: COUNT IN, PART 1, PART 2, and so on, END.

This changes only marker metadata in the newly exported MIDI file. It never
renames workbook Sections or markers in the active REAPER project. The export
success confirmation reports which naming mode was used.

The export does not record or render REAPER's live metronome. It generates every
click directly from the validated structure, so REAPER playback-click,
record-click, count-in, metronome pattern, and metronome-routing settings cannot
silence individual exported beats. Before MP3 conversion and final file commit,
the app:

- Calculates the exact required click count from every meter numerator, Part
  repeat, and repeated Block pass, including automatic COUNT IN.
- Requires the finite audio schedule to contain exactly that many events.
- Requires the MIDI click track to contain exactly that many explicit notes.
- Requires PCM WAV rendering to consume every scheduled click onset.

Any disagreement cancels export under CPX-003 or CPX-004. The app will not offer
a known-partial click package.

Import the MIDI tempo and time-signature data into Logic or Pro Tools to create
the matching bar grid. Import its click track as well, or use the MP3 when an
immediately audible reference is preferable. The human-facing app continues to
show underlying musical BPM even though the MIDI must use calculated effective
tempo events where click multipliers require them.

The export never replaces an existing .mid or .mp3. If either same-stem file
already exists, choose a new base name. REAPER performs MP3 encoding in a hidden
stock batch-converter process; no extra codec or project render setup is needed.

Error Reference codes:

- CPX-001: validated click-package plan is unavailable or stale.
- CPX-002: output name is invalid, cancelled, or already exists.
- CPX-003: MIDI generation or verification failed.
- CPX-004: permanent audio schedule or WAV creation failed.
- CPX-005: REAPER MP3 conversion failed.
- CPX-006: final package commit or verification failed.

======================================================================
APP-WIDE KEYBOARD AND TEXT EDITING
======================================================================

Global shortcuts when the base app is available:

- Ctrl+O: Browse for workbook.
- Ctrl+F: open Error Reference Search.
- F1: open Help.
- Tab / Shift+Tab: move focus.
- Enter / Space: activate focused button.
- Escape: cancel or close supported popovers/modals.

Every app-owned text field supports:

- Mouse click caret placement and drag selection.
- Left/Right, Home/End, Shift selection, and Ctrl word movement.
- Backspace/Delete and Ctrl word deletion.
- Double-click word selection.
- Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+V.
- Typing over a selection.
- Horizontal scrolling that keeps the caret visible.

======================================================================
SYNTAX SCRATCHPAD
======================================================================

Help contains a non-mutating Scratchpad that uses the same production parser
as workbook validation. It never changes the workbook or REAPER project.

Test Syntax reports:

- Validity and Error Reference code when invalid.
- Normalized syntax.
- Expanded Part, Block, and bar counts.
- Pass-by-pass plain-English results.
- BPM Override, Repeat, and Ramp behavior.
- Internal and final Ramp destinations.

Reset Syntax Example restores Section BPM 120 and this complete PARTS value,
then immediately tests it:

  [4]x2, (7)x3@135--, {9}x2@160, *11*x2@170-, ENT(4)x2@120, SXT{7}x2@100-, QNT{5}x2@90-, SPT{7}x2@80-, <[3]x2@140, SXT{5}@110->x2

Copy Normalized and Copy Readout preserve the complete content. Play Preview
renders the complete tested expression—including note values, tuplets, repeats,
Block passes, overrides, and Ramp timing—to temporary audio without inserting
anything into the project. Stop, Loop, and 50% Speed control that preview. A new
test or reset stops any previous Scratchpad preview so stale audio cannot remain.
Scratchpad results wrap, scroll, and use the Larger text setting.

Send to Scratchpad is available from a Preview row's right-click actions. It
uses the complete highlighted row range in top-to-bottom order and writes each
playable Part with its explicit underlying BPM so selections crossing Section
boundaries keep the intended tempos. It opens Help, validates the generated
expression, and waits for Play Preview; it does not autoplay or change REAPER.
END alone has no playable duration. A selection mixing accented and No Accent
Sections is rejected because one Scratchpad expression has one accent mode.

======================================================================
SONG STRUCTURE READOUT
======================================================================

The Build page includes Song Structure Readout. It is intended for musicians,
not parser troubleshooting.

The cue sheet is flattened into chronological performance instructions:

- Clean song title from the workbook basename.
- File extension and full path removed.
- Underscores become spaces; existing capitalization is preserved.
- Section headings.
- Bar count, meter, optional underlying musical BPM, and click type.
- Clear Ramp destination when applicable.
- No Block pass, parser, or workbook-row jargon.
- Normal app typography rather than code/syntax typography; Larger text scales
  the complete cue sheet and its wrapped, scrollable body.

Simplified Readout reduces each instruction to the numerator, Part repeat, and
written click type. Section names and COUNT-IN remain. Repeated groups list
their musical Parts inside parentheses and put the whole-group repeat below;
the word "Block" is not shown. For example:

  VERSE
  (4 x2 — Quarter Note
  7 — Sextuplet)
  x3

Measure Numbers and Show BPM are independent toggles in both the full and
Simplified Readouts. Show BPM controls COUNT-IN, every Part, and Ramp
destinations. When enabled, the displayed BPM is the underlying musical BPM,
never the multiplied REAPER tempo. Both toggles apply to the modal, text export,
and print.

Generic Part Names replaces musical Section headings with PART 1, PART 2, and
so on. COUNT-IN and END remain explicit. The option applies consistently to the
full and Simplified cue sheets, Duration Calculator, text export, print, and
subsequent MIDI click-package marker metadata. It does not rename workbook
Sections or REAPER project markers.

The Duration Calculator appears in both full and Simplified Readout. It shows
COUNT-IN, every Section, Musical Content, and Total with Count-In as MM:SS.
Calculations use full internal precision and account for meters, simulated
rhythm multipliers, Part repeats, Block passes, BPM Overrides, and linear Ramps;
only the displayed result is rounded to the nearest whole second.

Measure Numbers is off by default. Toggle it on to include measure ranges in
the modal, export, and print. Browser/operating-system print settings control
headers, footers, and page numbers. Print retains Section-aware page breaks.

Actions:

- Export as text
- Print
- Measure Numbers On/Off
- Simplified Readout On/Off
- Show BPM On/Off
- Generic Part Names On/Off

======================================================================
HISTORY FILTERS AND DATE PICKER
======================================================================

History filters support song/workbook, status, Build Notes, Build ID, and an
inclusive local date range.

- Keyboard date format: MM-DD-YYYY.
- Date From and Date To are inclusive.
- Date From may not be later than Date To.
- Calendar supports Previous Month and Next Month.
- Today selects today's local date.
- Clear Date clears one active endpoint.
- Clear Range clears both endpoints.
- Arrow keys move the selected calendar day/week.
- Enter or Space chooses the selected day.
- T selects today.
- Backspace/Delete clears the active date.

Invalid dates are reported inline and through Error Reference HIS-001.

======================================================================
VALIDATION ISSUES AND ERROR REFERENCE
======================================================================

All error, explanation, readout, and dialog text wraps and scrolls. Long syntax
tokens are split visually when necessary instead of ending in an unreadable
ellipsis. Copy actions preserve the full original content.

A validation row can provide:

- Search Error Reference (opens the matching entry directly).
- Copy Error Code (for Search Error Reference or support).
- Copy Readout.
- Copy Syntax.
- Open Workbook.
- Copy Corrected Cell only when an exact high-confidence replacement exists.

The Open Workbook action remains visible in the normal Build & Project card whenever
a workbook is selected. It is not removed after validation or a successful
build.

The app never edits a workbook automatically. Copy Corrected Cell always asks
for confirmation. No useless "no correction available" dialog is shown.

Search Error Reference matches:

- Code.
- Title.
- Category.
- Technical error text.
- Syntax/example text.
- Most likely fix.

Blank search shows the full catalog. Each entry includes What Happened, Why It
Matters, Most Likely Fix, Alternate Fix or Next Step, examples when applicable,
and related documentation.

REC-001 through REC-004 cover fingerprint-bound tempo recovery mismatch,
damaged/invalid recovery data, recovery write failure, and recovery-delete
failure. Recovery errors never cause unvalidated staged values to be applied.

Workbook-selection compatibility code:

- WB-015: neither REAPER's current GetUserFileName chooser nor its legacy
  GetUserFileNameForRead chooser is available. Update or reinstall REAPER.

Important Block codes:

- SYN-015: invalid Block delimiters.
- SYN-016: nested Blocks are not allowed.
- SYN-017: invalid Block Repeat.
- SYN-018: Block-level Ramp is not allowed.
- SYN-019: Block-level BPM Override is not allowed.
- SYN-020: final internal Ramp has no destination.
- SYN-021: empty Block.
- SYN-022: Block expansion safety limit exceeded.

Tempo-edit codes:

- EDT-001: a proposed edit failed production-parser validation.
- EDT-002: a Section source expression could not be rewritten safely.
- EDT-003: a selected Part source could not be located unambiguously.
- EDT-004: the source or staged plan changed before Build.

Updated-workbook-copy codes:

- WBK-001: native Workbook Save As could not open.
- WBK-002: the source workbook changed before copy.
- WBK-003: the CSV/XLSX copy could not be written.
- WBK-004: the copy did not reopen as the exact verified plan.

Audio-preview codes:

- AUD-001: a finite click schedule could not be generated.
- AUD-002: the temporary WAV could not be rendered.
- AUD-003: REAPER/SWS could not start the generated source preview.
- AUD-004: no non-mutating preview backend is available.

Build-audio codes:

- AUD-005: the current project structure does not exactly match the workbook,
  so Conform Audio cannot map old counts to new tempo safely.
- AUD-006: an audio item is locked, mixes audio/MIDI takes, or crosses COUNT IN
  or END and therefore cannot be conformed automatically.
- AUD-007: Preserve Audio Exact restoration/signature verification failed.
- AUD-008: conformed audio did not retain its original musical counts or
  pitch-preserving playback.

Project save code:

- PRJ-006: REAPER project Save As was not confirmed. It covers a canceled or
  failed native Save As, an unwritable path, an unexpected active-project tab,
  or any result where REAPER does not activate the exact requested .RPP path.

======================================================================
REAPER PROJECT SAVE WORKFLOW
======================================================================

Readiness wording

"REAPER project saved at least once" means the active REAPER project has an
.RPP filename and location. It does not claim current project changes are saved.

Before Build

The app strongly suggests saving a separate pre-build REAPER project. The
message explicitly refers to the active REAPER .RPP, not the workbook, app
state, or Bildibeat Click Track Mapper settings.

Buttons:

- Save REAPER Project As...
- Continue Without Saving
- Cancel Build

The unique editable suggestion is:

  OriginalSong_CTM_PREBUILD_BACKUP_YYYY-MM-DD_HHMMSS.RPP

Save As makes the chosen copy the active REAPER project. The current and
suggested paths are shown before the native Save As dialog. If the user cancels
the native dialog, the app prompt remains available.

After Successful Build

The app explains that the verified map exists in the active REAPER project in
memory and is not guaranteed to be written to disk until saved.

If a pre-build copy was saved, actions are:

- Save Another Copy As...
- Save Completed REAPER Project
- Close Without Saving

If pre-build saving was skipped, actions are:

- Save Completed Project As...
- Close Without Saving

The separate completed-build suggestion is:

  OriginalSong_CTM_COMPLETED_BUILD_YYYY-MM-DD_HHMMSS_ID-01FB.RPP

The four-character ID suffix comes from the Build ID. The suggested filename
is editable. Missing .RPP is appended. If an automatically suggested name
already exists, _02, _03, and so on are used. The completed exact path and
Build ID are confirmed after saving.

======================================================================
SETTINGS, ACCESSIBILITY, AND TOOLTIPS
======================================================================

Settings uses aligned two-column controls with equal widths and consistent
spacing. Full-width leftover controls span the row cleanly.

Preview Table settings include density, alternating rows, Section emphasis,
full syntax badges, and right-click row explanations. Workbook-difference row
highlighting is now always active whenever staged values differ; it is no
longer a separate preference.

Logging includes Click Frequencies. The editable app defaults are:

- Primary/accent A: 1760 Hz.
- Secondary B: 1600 Hz.

Save stores the two whole-number values for future builds. Restore Defaults
loads 1760/1600 into the fields; choose Save to commit them. A build applies
the frozen values to the active project and verifies them. A failed build or
Undo Last Build restores the project's previous click-frequency values.
These project settings are read and written through REAPER's native Metronome
and pre-roll settings controls, addressed through the SWS/S&M Extension. One
hidden frequency session is reused for the complete build transaction.
If SWS is missing, Environment Readiness remains failed and Build is disabled.
The Preview and audition-readiness loop never opens that native window. On
some Windows systems a single brief appearance may occur when the build first
creates its hidden session, but repeated or continuous flashing is not expected.
No clipboard text is used or replaced.

Workspace & Accessibility includes:

- Remember last page.
- Remember Layout for window size/position, resizable panels, Preview column
  widths, and Preview horizontal scroll.
- Remember History filters.
- Larger text throughout app.
- Unload Current Workbook, recent/filter cleanup, and Restore Default Layout.

Restore Default Layout resets the window, panels, Preview columns, and Preview
horizontal scroll together. Diagnostics opens one modal containing Copy
Diagnostics and Create Support Bundle. Clean Up Logs appears only in Settings;
History does not repeat the same maintenance control. Validation errors always
show their complete wrapped, scrollable text.

Larger text throughout app is persisted and increases all app-owned text by
about 50 percent, with a minimum six-point increase:

- Navigation, cards, labels, buttons, tables, and bottom bar.
- Help, Scratchpad results, tooltips, and status messages.
- Validation errors, Error Reference, readouts, and dialogs.
- Dedicated row heights, padding, wrapping, scroll areas, Settings spacing,
  calendar geometry, and modal layout adjust with the text.

Typography remains purpose-specific at either size. The app uses Segoe UI for explanations,
definitions, errors, and musician-facing prose. It uses Consolas only for syntax entry,
raw workbook/PARTS examples, and normalized syntax output. A Help sentence stays in Segoe UI
when it merely mentions a token such as ENT(N), SXT{N}, QNT{N}, or SPT{N}.

The high-visibility layout is exercised at the supported 980 x 680 minimum,
the 1480 x 880 default, and larger dynamically resized windows. Long validation
errors and technical syntax tokens wrap inside their panels and remain
scrollable rather than extending beyond a dialog border.

Windows-owned title bars and native file dialogs continue to use Windows
accessibility/display settings.

Hover tooltips are accurate for every visible control, field, date action,
status badge, Readiness item, renamed button, save action, and disabled state.
File Loaded, Validated, and Ready are informational badges with dynamic help.

======================================================================
REAPER TIMEBASE, BUILD AUDIO POLICY, AND PRESERVE PITCH
======================================================================

Bildibeat Click Track Mapper replaces the project tempo/time-signature map.
Build & Project therefore requires an explicit audio policy:

Preserve Audio Exactly

- This is the safe default after validating a workbook or changing project tab.
- Before the tempo map changes, the app snapshots every detected audio item's
  absolute position, length, snap offset, rate, pitch, item timebase,
  automatic-stretch setting, fades, take source offset, and stretch markers.
- During the map change, audio is held to absolute time. The complete snapshot
  is then restored and compared with a fresh signature. A difference fails and
  rolls back the build.
- Recorded audio remains exactly where and how it was. MIDI is not stretched
  by this mode.

Conform Audio to New Tempo — Preserve Pitch

- Eligible audio remains on the same musical counts while its duration/rate
  follows the new underlying musical BPM.
- Example: a four-bar VERSE recorded at 185 BPM remains four bars when changed
  to 200 BPM. Its equivalent playback-rate ratio is 200/185, approximately
  1.081081, its duration becomes 92.5 percent of the original, and pitch stays
  unchanged.
- REAPER's Beats (position, length, rate), automatic stretch-marker behavior,
  and per-take Preserve pitch are used during the transaction. An item crossing
  multiple eligible Parts or Ramps remains one item; stretch markers carry the
  internal tempo boundaries. The app does not split it.
- The original recorded/source media files are never rewritten or deleted.

Conform eligibility is deliberately strict. Current standard REAPER markers
must match the validated workbook marker names, order, and measure/beat
positions, including COUNT IN and END. Every bar's meter/count,
Repeat/Block expansion, and Ramp boundaries must also match. BPM values may
differ. A changed count, missing/extra/reordered marker, different meter or
Ramp topology, locked eligible item, mixed audio/MIDI item, or audio item that
crosses COUNT IN or END blocks Conform. Choose Preserve Audio Exactly instead.
Audio wholly outside COUNT IN through END remains unchanged.

The final confirmation, success dialog, and logfile state the chosen policy and
item counts. Audio handling and click-map construction occur in the same named
REAPER Undo transaction. A failed build verifies both marker/tempo and audio
rollback signatures. Undo Last Build verifies the pre-build audio signature.

MIDI, automation, and other nonstandard project content still follow REAPER's
project/track/item timebases. Check File > Project Settings > Project Settings,
especially "Project timebase for items/envelopes/markers" and "Timebase for
tempo/time signature envelope." REAPER also provides Help > Project timebase
help. Track and individual-item timebases can override the project setting.

Project timebase for items/envelopes/markers:

- Time: item positions and lengths remain tied to clock time. Changing tempo
  changes where those fixed-time items fall against measures and beats.
- Beats (position only): item starts follow beat positions, but item lengths
  and playback rates do not automatically stretch with the tempo map.
- Beats (position, length, rate): item starts and lengths follow the musical
  grid. Audio may be rate-stretched as tempo changes; MIDI and beat-based
  material generally remain aligned to measures and beats.
- The "Timebase affects MIDI items" option controls whether the chosen project
  timebase is also applied to MIDI items. Track or item overrides still matter.
- The automation-item option similarly determines whether beat-position
  behavior changes automation-item length.

Timebase for tempo/time-signature envelope:

- Beats keeps tempo and time-signature events attached to musical positions.
- Time keeps them attached to absolute time.
- Time Signature: Beats, Tempo: Time is the hybrid option indicated by its
  name: time-signature changes follow beats while tempo events follow time.

For a project already containing carefully aligned MIDI, automation, or custom
markers, save the uniquely named pre-build .RPP copy and test the result before
continuing production. The explicit audio policy protects or conforms audio;
other content still depends on its REAPER timebase.

Preserve pitch controls:

- For the app's temporary 50% audition, use the master-playrate option. If the
  Rate control is hidden, right-click an empty part of REAPER's Transport Bar
  and enable Show play rate control. Then right-click the Rate edit box or
  playrate control. Choose "Preserve pitch in audio items when changing master playrate."
  The app temporarily enables this option and restores its
  previous state when audition ends.
- For rate changes stored on an individual audio item, select the item and
  press F2 to open Media Item Properties. The Take properties area contains
  "Preserve pitch when changing rate." Item/track/project timebase and the
  chosen pitch-shift algorithm determine the audible result.
- Preserve pitch affects audio pitch processing. The app's Conform policy also
  verifies musical-count placement; MIDI, automation, and custom content remain
  governed by their own timebases.

======================================================================
AUTOMATIC PROJECT CHECK, SAFETY, LOGGING, AND UNDO
======================================================================

After validation, the app maintains a read-only automatic project snapshot that
compares current REAPER markers/tempo data with the validated plan without
modifying the project. It refreshes when REAPER changes. There is no separate
Build Preview or Export Preview button; the automatic check and a fresh
immediate preflight provide the build-safety contract.

The real build:

- Revalidates the saved workbook.
- Rejects a changed workbook/project tab.
- When tempo edits are staged, rebuilds them against the newly reread source and
  rejects any source-plan or staged-plan hash mismatch before modification.
- Runs structural preflight before modification.
- Recalculates the selected audio policy and blocks unsafe Conform requests
  before project modification.
- Requires stopped REAPER transport.
- Uses one named REAPER undo transaction.
- Applies and verifies Preserve Audio Exactly or Conform Audio to New Tempo —
  Preserve Pitch inside that transaction.
- Verifies COUNT IN, Section markers, END, and tempo-map results.
- Verifies per-measure metronome patterns and the selected A/B click frequencies.
- Enables and verifies REAPER's native metronome so the built clicks are audible.
- Automatically undoes a failed build when possible.
- Logs every staged Section/Part/END edit, including whether Section overrides
  were shifted, plus both source and staged plan identity.
- Verifies the restored marker/tempo and audio signatures after rollback.
- Restores the pre-build metronome state and A/B frequencies after failure or
  Undo Last Build.

Each started attempt receives a unique Build ID and a SUCCESS, FAILURE,
CANCELLED, or UNDO log. Logs include workbook/plan hashes, normalized plan,
Build Notes, project snapshot, audio policy and impact counts, exact error,
Error Reference match, and result.

Logs are stored beside the active saved .RPP in:

  SONG STRUCTURE BUILD LOGS

Copy Latest Build ID remains in Settings. The success dialog does not add a
redundant extra Copy Build ID action.

Undo Last Build is available only when the active project is the project that
received the last successful build and no intervening REAPER action replaced
the expected undo entry. Undo changes REAPER only. The displayed staged plan
remains loaded and is clearly labeled not currently applied; rebuild it before
auditioning or saving an updated workbook copy.

======================================================================
SAFE MODE
======================================================================

Run Bildibeat_Click_Track_Mapper_Safe_Mode_v10_21.lua beside the matching main file.

Safe Mode ignores persisted layout, recent workspace state, preferences, and
tempo-recovery restoration for one run without deleting them. It launches the
v10.21 main script with the safe-mode flag and retains:

- The production parser and Block rules.
- Staged Section, Part, and END tempo editing with additive override option,
  No Accent preservation, calculated REAPER BPM, Revert Tempo Edit, and yellow
  workbook-difference rows.
- Exact-scope discard confirmations for staged edits. Safe Mode does not read,
  overwrite, or delete a normal-session tempo recovery record.
- Verified Save Updated Workbook Copy for XLSX and CSV without source overwrite,
  including automatic adoption as the current validated baseline.
- Read-only Create Verified Workbook From Open Project with conservative
  repeat/Block/tuplet inference, editable XLSX/CSV Save As, reconstruction error
  logging, and mandatory in-memory plus post-save one-for-one verification.
- Preserve Audio Exactly and structurally gated Conform Audio to New Tempo —
  Preserve Pitch, with shared transaction rollback and audio signature checks.
- Tempo Preview card with metronome icon, editable BPM text field, and a
  continuously looping four-beat reference controlled by Play and Stop.
- SPT{N} Septuplets, "BPM no accent," and editable A/B click frequencies.
- Full terminology and syntax badges.
- Syntax Scratchpad, complete reset example, Send to Scratchpad, and
  non-mutating audio preview.
- User-Friendly Song Structure with Simplified Readout, Generic Part Names,
  Measure Numbers, Show BPM, Duration Calculator, export, and print.
- Multi-row verified-map audition controls.
- History calendar.
- Accessibility-aware app layout.
- Error wrapping and Error Reference actions.
- Pre-build/post-build REAPER save workflows.
- Consolidated Settings, diagnostics, logging, verification, rollback, and
  self-tests, including the automated visual-regression matrix.

Safe Mode is not a different parser and does not bypass validation or build
safety.

======================================================================
DIAGNOSTICS AND RELEASE VERIFICATION
======================================================================

Run Parser Self-Test from Settings. It is non-mutating and covers, among other
contracts:

- All meter families and simulated click multipliers.
- Staged Section/Part/END edit rewriting, inherited tempo, additive override,
  repeat/Block source ownership, No Accent preservation, Revert Tempo Edit, and
  exact-scope discard-on-close/switch/reload state.
- Tempo-recovery serialization, workbook fingerprint/source-hash binding,
  production-parser restoration, logical Section/Part counts, and rejection of
  stale or damaged recovery data.
- CSV/XLSX updated-copy cell manifests, unique filenames, source protection,
  revalidation, and exact plan-hash verification.
- Tempo Preview and Scratchpad audio schedules, including Ramp timing,
  Scratchpad Loop/50% Speed, finite-duration limits, and temporary-WAV checks.
- SPT{N} Septuplet syntax/math and rejection of transposed STP spelling.
- Section-level no-accent patterns, normal COUNT IN accenting, and A/B defaults.
- Duration totals with full-precision meter/tempo/Repeat/Block/Ramp math.
- Simplified grouped readout, Generic Part Names, and independent BPM/measure
  toggles.
- Contiguous Preview selection and verified-map audition helper contracts.
- Repeat, BPM Override, Ramp, END, COUNT IN, and first-Part BPM rules.
- Block expansion, pass order, internal Ramp confinement, and invalid syntax.
- Full-word badge labels for note types, Repeats, BPM Overrides, Ramps, and
  Block passes.
- Plain-English Eighth Note Triplet, Sextuplet, Quintuplet, and Septuplet wording.
- Scratchpad normalization and reset example.
- Preview row actions, selection-aware Send to Scratchpad, and keyboard
  navigation.
- MM-DD-YYYY History dates and calendar validation.
- Song title cleanup and Song Structure Readout generation.
- Runtime-state scope ordering, permanent Open Workbook availability, native
  metronome enable/restore helpers, and plain-text readout typography.
- Unique pre-build/completed .RPP filename generation.
- Error Reference search and correction gating.
- Golden responsive visual-regression snapshots for Build, History, Settings,
  Help, Preview footers, app dialogs, confirmation dialogs, and calendars at
  980 x 680 compact, 964 x 649 Windows client-border, 1480 x 880 standard,
  2200 x 1200 wide, 1600 x 680 wide-short, and compact/wide-short Larger Text
  layouts. Each snapshot checks exact breakpoints plus boundary invariants.
- Help/README/Safe Mode version synchronization.
- Parser stress, rebuild simulation, rollback normalization, and local-variable
  headroom.

Diagnostics and support bundles do not include the workbook or .RPP project.

======================================================================
SUMMARY OF V10.21 USER CONTRACTS
======================================================================

- Section names create standard REAPER markers.
- Section BPM and calculated REAPER BPM remain distinct: the former is editable
  in-app, while the latter is read-only and always recalculated.
- Part edits update the source Part across ordinary repeats and Block passes.
- No Accent is preserved by Section and Part tempo changes.
- The source workbook is never edited; an updated copy is available only after
  the exact staged plan is built and verified, and an exactly verified copy
  becomes the new validated workbook baseline.
- Yellow Preview rows identify every musical difference from that baseline.
- Validate Only checks the workbook; Validate Against Open Project separately
  checks the active REAPER tab's complete representable click-map structure
  without changing either side. Validation Diff is retired.
- Revert Tempo Edit restores selected yellow rows to the loaded workbook,
  confirms Section-wide consequences, deduplicates Repeat/Block occurrences,
  and preserves unrelated staged Part edits.
- Closing, switching, unloading, preference reset, and revalidation report the
  exact changed Section/source-Part scope before staged edits can be discarded.
- Staged tempo edits survive an interrupted session through a temporary recovery
  record, but restoration requires the identical saved workbook fingerprint and
  source hash and must pass the production parser again.
- Proportional Section shifts are always calculated from the loaded workbook
  baseline, so repeated edits cannot accumulate numerical drift.
- Accent behavior is read-only: No Accent, normal Section accents, and the
  automatic COUNT-IN accent remain unchanged by editing and reversion.
- Tempo Preview and Scratchpad Preview play generated clicks without rebuilding
  or inserting media into the active project.
- Export MIDI + MP3 Click creates synchronized portable files from the current
  validated plan without changing the project. Both start with COUNT IN at time
  zero, stop musically at END, and the MP3 has only a 75 ms safety tail.
- Parts are playable instructions; Blocks group Parts for repeat passes.
- Ramps never attach to the outside of a Block.
- A final internal Block Ramp reaches only the next Block pass.
- A normal Part before a Block may still Ramp into that Block.
- Visible translations use complete names for note values, triplets,
  quintuplets, Repeats, BPM Overrides, Ramps, and Block passes.
- Preview navigation is mouse-friendly and keyboard-accessible without J/R.
- Send to Scratchpad transfers highlighted playable rows in order and waits for
  the user to start its non-mutating audio preview.
- Error text is complete, wrapped, scrollable, and easy to copy/search.
- Parser Self-Test enforces golden compact, standard, wide, and Larger Text UI
  geometry so clipped panes, overlapping controls, and breakpoint drift fail.
- Date typing uses MM-DD-YYYY and calendars are available.
- Song Structure Readout is musician-facing and optionally includes measures.
- Simplified Readout never says Block; BPM and Measure Numbers toggle independently.
- Generic Part Names affects readout, durations, text export, print, and
  subsequent MIDI click-package markers without renaming workbook Sections or
  REAPER project markers.
- Duration totals are shown as MM:SS for each Section and the complete song.
- Shift-click/Shift+Arrow selects a contiguous audition range; Play, Stop, Loop,
  and 50% Speed operate after either a current verified build or an exact
  Validate Against Open Project result. An exact comparison therefore unlocks
  Preview audition without rebuilding. This authorization is bound to the exact
  validated plan, active project tab, and project marker/tempo/click signature;
  changing any of them disables audition until the project is built or matched
  again.
- "120 no accent" applies all-A clicks to one musical Section; COUNT IN stays accented.
- Click-frequency defaults are editable, with A 1760 Hz and B 1600 Hz defaults.
- Successful builds and auditions enable REAPER's native metronome; failure and
  Undo restore the prior build-time state.
- Larger text scales the whole app-owned interface.
- Save prompts always say REAPER project/.RPP when that is what they mean.
- The main script, Safe Mode launcher, Help, Error Reference, examples,
  tooltips, and README all describe the same v10.21 behavior. Punctuated Help
  headings use Segoe UI; Consolas is reserved for genuine syntax.
