Bildibeat Musical Time Manager
==============================

Version 1.6

PURPOSE

This dependency-free REAPER Lua app inserts and removes musical time while
protecting the rest of the project map. It supports five operations:

- Insert complete measures in a chosen time signature.
- Remove complete measures.
- Add beats to the end of the measure before the edit cursor.
- Remove beats from the end of the measure before the edit cursor.
- Retime a bar-aligned time selection while locking both selection edges.

The meter and amount are dynamic. There is no fixed time signature or fixed
number of beats.

WORKFLOW

1. Put the edit cursor at the bar line where the change begins. The app includes
   a Snap to Nearest Bar button.
2. Choose one of the five operations.
3. Set the number of measures or beats. For inserted measures, also choose the
   numerator and denominator. Click a displayed number to type it directly, or
   use a common-meter preset.
4. Read the live preview and click Review Insertion or Review Removal.
5. Read the preservation/destructive-scope summary and confirm.

For Retime Selected Section, create a time selection with both edges exactly on
bar lines. The app reads that section's current tempo and time signature into
the controls. SET START BPM changes the starting tempo and scales later tempo
markers proportionally. ADJUST ALL adds or subtracts one signed BPM amount from
every tempo segment in the selection while preserving all existing time
signatures. Review the fixed clock-time range, choose a pitch-stretch algorithm
and seam-fade length, and confirm. The edit cursor is not used for this
operation. The Snap Selection to Bars button fixes nearby selection edges
automatically. Run Read-Only Safety Check performs the complete preflight and
project-fingerprint check without changing the project.

PRESERVATION MODEL

- Inserted measures become new bars. Existing later material moves later in
  clock time and keeps its beat while its displayed measure number increases by
  the number of inserted measures.
- Removed measures disappear. Existing later material moves earlier in clock
  time and keeps its beat while its displayed measure number decreases by the
  number of removed measures.
- Adding or removing beats changes only the preceding measure's numerator.
  Existing later material moves in clock time but retains its original displayed
  measure and beat.
- Retime Selected Section keeps both clock-time boundaries fixed. It inserts a
  new tempo/meter boundary at the left edge and restores the exact preceding
  tempo/meter at the unchanged right edge. When the requested tempo does not
  fill a whole number of new measures, the right marker explicitly allows the
  preceding partial measure instead of moving anything outside the selection.
- Media items crossing either selection edge are split automatically. Only the
  middle pieces are repositioned/rate-stretched by new-BPM / old-BPM, and pitch
  preservation is enabled on audio takes. Left/right pieces and every wholly
  outside item are restored exactly. Faster tempos can leave unused time before
  the fixed right edge; the exact theoretical gap is reported. Slower tempos
  that would extend past it require a separate explicit trim confirmation that
  names the affected items and reports the total overflow time.
- ADJUST ALL uses a separate old/new BPM ratio for every step-tempo segment.
  Media crossing a boundary where that ratio changes is split automatically so
  each piece receives the correct local playback rate. Meter-only markers are
  retained without unnecessary media splits.
- Native REAPER click-source items are repositioned/resized with the selected
  musical section but are never rate-stretched. Their take playback rate is
  preserved so the click remains driven directly by the new project tempo and
  time-signature map.
- Configurable short seam fades are applied only where selected audio meets a
  new boundary or is trimmed. They reduce clicks without changing outside
  items. New same-track/same-lane collisions are detected and rejected.
- Existing audio stretch markers are retained: their item positions are scaled,
  source positions and slopes are restored, and every marker is verified.
- Internal step-tempo and time-signature markers are retained and moved by the
  applicable local tempo ratio. SET START BPM scales their BPM values
  proportionally; ADJUST ALL adds the same signed BPM amount to each one and
  preserves every meter. Internal linear ramps remain intentionally blocked
  because a fixed-window ramp transformation requires a user-defined curve
  decision.
- The pitch algorithm is selected from the algorithms installed in REAPER.
  Elastique Pro is preferred as the first-run default when available; Project
  Default remains selectable.
- Item state chunks are structurally fingerprinted after boundary splitting.
  Group IDs, fixed lanes, pooled MIDI/source data, take identities, take
  envelopes, comping data, and other non-retime metadata must remain unchanged.
- Retime Selected Section restores complete non-tempo automation-envelope state
  chunks, including ordinary points and automation items, so automation does not
  shift with the tempo-map edit.
- Downstream whole media items are restored from exact state chunks, changing
  only their required position.
- Project markers/regions and tempo/time-signature markers are rebuilt at their
  required musical boundaries and verified.
- Sub-microsecond boundary rounding is normalized for project markers, tempo
  points, and media items so objects on a bar line remain on the intended side.
- Ordinary track and master-track automation points are checked for their exact
  value, shape, selection state, and required musical position.
- Custom metronome patterns and the exact tempo-marker count are verified.
- REAPER's all-track insert/remove-time actions handle the underlying project
  edit, including ordinary automation movement.
- Every operation is one undo step. If verification fails, the app immediately
  undoes the complete operation and verifies markers, tempo data, media items,
  and automation envelopes after Undo before reporting the project restored.
- If the project changes while the confirmation window is open, the stale plan
  is rejected without making changes.
- Before an approved operation, the app writes a timestamped .rpp safety copy.
  After success it writes a text report beside the backup with the exact split,
  stretch-marker, tempo-marker, fade, gap, trim, collision, and verification
  counts. Saving the backup copy does not replace the active project filename.

REMOVAL WARNING

Removing time is intentionally destructive inside the removed span. Media items
overlapping that span may be split, shortened, or deleted. Markers inside it are
removed, and crossing regions are shortened to close the gap. The confirmation
window reports these counts before anything changes. Objects beginning at or
after the end of the removed span are treated as protected downstream objects.

SAFETY LIMITS

- REAPER 7.75 or newer is required. No SWS, ReaPack, or ReaImGui dependency is
  required.
- Playback/recording must be stopped and the project must not be read-only.
- The edit cursor must be exactly on a bar line.
- Retime Selected Section instead requires a non-empty time selection whose two
  edges are exactly on bar lines. The app can snap both edges. Step tempo/meter
  changes are supported; internal linear ramps are rejected.
- Existing stretch markers are remapped and verified. Locked overlapping media
  items must still be unlocked because REAPER must split or resize them.
- Fixed-boundary retiming supports 1-960 BPM and the displayed denominator
  choices 1, 2, 4, 8, 16, and 32.
- A resized measure must retain at least one beat; numerator safety limit is 64.
- Operations that intersect a linear tempo ramp are rejected. Continuing or
  joining a ramp across newly inserted/removed time requires a musical choice.
- Inserting at a point crossed by a media item splits that item around the new
  gap. The confirmation window reports crossing items.

INSTALLATION

1. In REAPER, choose Options > Show REAPER resource path in explorer/finder.
2. Copy Bildibeat_Musical_Time_Manager.lua into the Scripts folder.
3. Open Actions > Show action list.
4. Click ReaScript: Load and choose the Lua file.
5. Run it from the Action List, or assign it to a toolbar button/shortcut.

The UI stays open until closed and can be docked or undocked from its right-click
menu. The preview shows the exact affected bars, clock-time range, and duration.
The app remembers its last operation, values, size, position, and dock state.
