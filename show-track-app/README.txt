BILDIBEAT SHOW TRACK APP v4.2
=============================

WHAT TO LOAD
------------
Load only Bildibeat_Show_Track_App_v4.2.lua into REAPER's Action List.

The Lua file is one self-contained app. Its window contains Mix, Preview & Build
Show Track, Repair Last Failed WAV, Recover Interrupted Render, Manage ALT Click
Sample, Set Approved Reference, Validate Complete Show Folder, and Analyze
Breakout Loopback. README.txt is documentation only;
it is not another script and contains no required functionality.

The main window, track mixer, and live build-progress window are resizable. Build
confirmations are deliberately compact; complete track measurements, warnings,
and repair details are written to the REAPER console and final audit instead of
an oversized native dialog. The progress window has safe cancellation: if a
REAPER render is active, cancellation waits for that one render to finish,
removes its temporary file, and never publishes a partial WAV.

BUILD OPTIONS, TRACK MIXER, AND MONO PREVIEW
-------------------------------------------
The last setup window has two unchecked-by-default checkboxes: Preview mono IEM
mix before render, and Also render CLICK +3 dB and -3 dB versions. Click Build
without preview to proceed automatically through analysis, final rendering,
verification, and publication; no further mixer/preview input is required.
The second checkbox is unavailable when the song has no CLICK track.

With preview checked, v4.2 opens a mixer after source analysis containing every
included CLICK, BACKING, and FOH track. Each row has a guarded -6 to +6 dB level offset
in 0.5 dB steps. The offset is applied after automatic per-track matching, so
0 dB means the app's calculated consistent level rather than the source file's
arbitrary recorded level. The chosen relative balance is preserved when the
complete left and right sides are normalized for the final render.

The checked preview starts playback of the real processed IEM route: replacement CLICK plus
all BACKING tracks, phase-safely summed to mono and sent to the LEFT output only.
The FOH bus is explicitly muted during preview. FOH rows remain adjustable for
the final render but can never enter the preview. Preview loops the selected song
range by default; Stop or the spacebar stops it.

Render Show Track uses the exact offsets heard in preview. Closing the mixer or
pressing Escape renders nothing and restores the complete original project.

With the extra-render checkbox checked, the app first verifies and publishes
the normal WAV, then automatically renders and independently verifies two more
WAVs from the same song: CLICK +3 dB and CLICK -3 dB relative to its assigned
track offset. For example, a CLICK assigned +3 dB yields companion files with
resulting offsets +6 dB and 0 dB. Filenames show both the resulting offset and
change, such as `_CLICK_+6dB_delta+3dB.wav` and
`_CLICK_+0dB_delta-3dB.wav`. Each has its own audit. These are relative
CLICK-to-BACKING balance variants: for +3 dB, the app holds an already-limited
CLICK steady and lowers the BACKING component by 3 dB; for -3 dB, it lowers
the CLICK component by 3 dB. This is fixed post-FX gain, so the difference
remains meaningful even when CLICK peaks have reached their safety limiter.
FOH stays unchanged. Because the final safety limiter can change the audible
result, the app measures quiet-hit CLICK prominence against the normal WAV and
can refine that one fixed component gain before independently rechecking hard
peak, content, routing, padding, and CLICK-audibility requirements. It reports
the measured change and final fixed gains in each audit; no time-varying gain
or pumping is introduced. A failed optional companion cannot remove the
already-verified normal file. The original project is restored after all
requested renders finish.

REQUIREMENTS
------------
- REAPER 7.77 or newer.
- Write access to REAPER's resource folder and the selected output folder.
- SWS 2.14+ is strongly recommended. The app uses SWS for item-level preflight
  and a final independent loudness/true-peak cross-check when available. SWS is
  not mandatory because the app retains its own complete analyzer and verifier;
  a missing extension is stated in the report.

ONE SONG PER PROJECT
--------------------
Create a REAPER time selection around the exact musical content, then run Build
Show Track. The stereo 24-bit PCM WAV contains 2.5 seconds of verified digital
silence, the exact selected content, and 30 seconds of verified digital silence.

The left channel is the IEM feed. The right channel is the FOH feed. A project
does not need a FOH track; in that case the right channel is verified digital
silence. At least one BACKING track is required.

TRACK LABELS
------------
Labels may appear anywhere as complete words in a track name:

  CLICK                  one timing track, left only
  BACKING                one or more IEM music tracks, left only
  FOH                    one or more FOH program tracks, right only

Examples such as "Synth - FOH", "Guitar FOH LEAD", and "Pads BACKING" are
valid. FOH tracks may also contain LEAD, RHYTHM, or BED. If no priority label is
present, RHYTHM is used. A signed value such as +2 or -1.5 is a bounded mix-
intent offset. Conflicting labels stop the build.

Solo is respected. If any labeled source is soloed, only soloed labeled sources
participate. If that rule would exclude a labeled CLICK track, the app now stops
before analysis and names the excluded track instead of silently producing a
clickless file. Every BACKING and FOH source becomes mono before routing, but the
app no longer blindly adds its stereo channels. It first performs a phase-aware
preflight over the complete time selection. Safe stereo uses normal L+R mono;
if that would cancel, the app selects the more complete/cleaner source channel.
Consistently balanced polarity-inverted material uses a guarded L-R fold. The
decision and measurements are written to the audit. FOH is then routed only to
the right, while CLICK and BACKING are routed only to the left.

WHAT IS IGNORED AND RESET
-------------------------
Measurements are made at unity from the selected source material. Source track
faders are set to 0 dB, pan is reset, item/take gain and fades are neutralized,
take FX and existing track/master FX are bypassed, envelopes are bypassed, and
the app builds temporary routing. Existing FX are bypassed, not deleted. Before
any of this happens, v4.2 snapshots every complete original track and the master.
After success, cancellation, or failure, it deletes all generated processing
tracks and restores the original sends, FX states, items, takes, envelopes,
faders, pans, solo/mute states, render settings, and time selection.

INTENTIONAL SILENCE
-------------------
Silence inside the selected song is normal content. It is not counted, warned
about, classified as a dropout, treated as a failure, or repaired. Loudness
gating excludes it. Passage maps and reactive whole-track gain riding are
disabled, so rests cannot trigger recovery swells.

The only structural exception is a required labeled track that contains no
measurable audio anywhere in the complete time selection; such a track cannot
produce the requested output and is reported plainly.

LEVELING AND CONSISTENCY
------------------------
The locked show profile defines the IEM target/ceiling, click-over-backing
advantage, and FOH target/ceiling. Reusing the same profile produces the same
measured loudness targets across song projects, so mixer gain does not need to
change between songs.

Every BACKING and FOH source is analyzed and processed independently before it
reaches its side's bus. The app:

- performs a lightweight phase/cancellation scan and chooses one stable mono
  path per source before loudness normalization;
- calculates one constant trim for each complete source and output side;
- never boosts silent/noise-floor windows;
- allocates level for the average number of simultaneously active stems;
- caps the pre-render phase at three passes and remeasures only
  sources whose controls changed;
- applies 18 Hz subsonic protection to CLICK and musical sources;
- applies app-owned, bounded soft-knee source compression to spiky BACKING,
  and gentler peak compression to CLICK before its fixed level adjustment;
- keeps FOH compression and all bus compressors off; no track follows another
  track's envelope;
- uses static LEAD (+1 dB), RHYTHM (0 dB), and BED (-1.5 dB) hierarchy instead
  of dynamic sidechain ducking;
- uses an oversampled, look-ahead true-peak safety limiter;
- keeps CLICK on a separate transient-safe bus so it remains louder than the
  BACKING bed, then measures click prominence again at every detected beat in
  the actual rendered WAV.

Raw non-CLICK analysis and dynamics scans are cached inside the song project with
a source/item fingerprint and the selected downmix mode. Editing source
placement, length, rate, pitch, gain, fades, file contents, or the selected
mono path invalidates the cache automatically.

BOUNDED DYNAMICS WITHOUT GAIN-RECOVERY PUMPING
----------------------------------------------
"Pumping" means artificial audible ducking and swelling caused by a compressor,
limiter recovery, reactive leveler, or sidechain. It is a rejected processing
condition. v4.2 uses a fixed soft-knee input/output curve on CLICK and BACKING,
with a strict maximum of 1.5 dB and 3.5 dB source peak reduction respectively.
Already-flat backing can receive no compression. The curve has no detector,
attack, release, or gain-recovery envelope; it cannot follow a kick or make the
music breathe. Each source and each final side also receives one fixed gain for
the complete selected song. The look-ahead peak guard stores any necessary peak
correction with the corresponding delayed sample and has no programme-following
release envelope. If normalized peaks cross the ceiling, only their delayed
samples are attenuated; there is no recovery swell. Immediately
before preview and every render it reasserts the app's exact source curves,
bus compression OFF, passage maps OFF, reactive leveling OFF, makeup at 0 dB,
and sidechain ducking OFF. User track/master/take FX never supply this processing.
Natural dynamics or pumping already printed into an input file cannot be erased
without more invasive time-varying processing; the app does not promise that
every quiet and loud musical phrase becomes identical in level. Excessive static
compression can alter tone, which is why these maximum reductions are small.

CLICK REPLACEMENT
-----------------
CLICK supplies timing only. The app tests five safe transient thresholds, uses
their median hit count to reject a sparse accent-only result, and then chooses
the safe full-coverage result that best matches REAPER's tempo grid. It never
invents beats or fills intentional rests. Detected hits are replaced one-for-one
with a checksum-verified single-hit sample, and item count is verified before
routing. The source CLICK track remains the sole timing authority: if you cut
out clicks, the app does not regenerate them from the tempo map.

Outside ALT sections, detected hits use the A or B sample configured in this
project's REAPER Metronome and pre-roll settings. The app reads the current live
project settings (even if not yet saved), including its beat pattern and A/B
relative gain. Set both A and B to real single-hit audio files before building.
The project tempo map determines which existing CLICK hit gets A or B, but it
never creates a new hit. The app maintains the metronome A/B accent ratio while
its show profile controls the final overall CLICK level. REAPER's metronome
master volume is not used as a second show-volume control. If the pattern uses
C/D, those existing hits use B; only the A/B sample slots are supported.

Manage ALT Click Sample selects one single-hit file for all alternate sections.
Create two standard project markers with matching names to define a section:

  CLICK ALT       ... CLICK ALT
  CLICK ALT 1     ... CLICK ALT 1
  CLICK ALT 2     ... CLICK ALT 2
  ALT CLICK       ... ALT CLICK
  ALT CLICK 1     ... ALT CLICK 1
  ALT CLICK 2     ... ALT CLICK 2

ALT CLICK and CLICK ALT are interchangeable: ALT CLICK 1 opens the same range as
CLICK ALT 1, so either spelling may close the pair. Every ALT range, numbered
or not, uses the same selected ALT sample on each existing hit, without A/B
accent alternation. Names are
case-insensitive and extra spaces are ignored; the complete marker title must
be one of these forms (with any positive number and no leading zero). Marker
occurrences are paired chronologically, so one slot may define multiple sections. The opening
marker is included; the matching closing marker resumes metronome A/B. Adjacent
ranges are allowed. An odd marker count, zero-length pair, or overlap between
different alternate ranges stops before the project is changed and identifies
the problem. Markers outside the selected song range do not alter that render.
If an ALT range is used but no valid ALT file is selected, Build asks for one.
v4.2 has a new processing profile ID so older one-sample CLICK renders cannot
be mistaken for metronome A/B renders. Optional CLICK variants still identify
their additional offset separately in the filename and audit.

Every sample is checksum-verified and copied to REAPER's resource
Media/Bildibeat/ClickSamples folder so moving the original file cannot break a
later song. Before placement, A, B, and ALT are converted to a phase-safe mono
path. B is RMS-matched to A while preserving the project's relative A/B gain;
ALT is RMS-matched to A, so ALT hits are uniform. Corrections have a guarded
+/-24 dB maximum. The complete replacement track uses the same click gain,
transient-safe limiting, and final quiet-hit prominence verification as before.
The audit lists each sample's filename, checksum ID, ALT-range count, hit count,
mono choice, and level-match gain. CLICK uses only gentle bounded peak shaping,
not a music-following compressor, so changing samples cannot trigger ducking.

AUTOMATIC REPAIR AND RECOVERY
-----------------------------
The app renders a temporary WAV, adds and verifies padding, measures the actual
file, and repairs only the affected component or side. Repairs use fixed gain:

  native-rate PCM peak check -> fixed-gain WAV safety candidate -> independent
  remeasurement -> safe audible fallback with quality differences in the audit

There is no surgical passage map and no compressor escalation. A rendered
true-peak overshoot of up to 3 dB can be corrected without a full rerender:
the app attenuates only the affected physical WAV channel with one constant
gain, then verifies true peak, loudness, padding, channel isolation, and CLICK
again. If that candidate cannot pass, the embedded memoryless peak guard is
tightened on a bounded render retry.

CLICK audibility has its own independent repair state. If final click
prominence is low, CLICK is raised modestly and BACKING is lowered by the
complementary amount; the complete left bus is not blindly boosted. A response
that fails to improve prominence by at least 0.05 dB restores both component
trims and retires that strategy. CLICK repair never postpones a hard IEM peak
correction. The audit identifies the ten weakest measured hits by project time
and WAV time, so a real masking problem can be located rather than guessed at.
If an expected CLICK hit is actually missing, v4.2 first retries a failed audio
read, then repairs the specific replacement item(s) and rerenders to prove the
beats audible. Many simultaneous missing hits trigger one clean routing-graph
retry instead of hundreds of arbitrary boosts. Incomplete expected CLICK
coverage can no longer pass through the quality fallback.

IEM and FOH have independent two-attempt budgets. Each repair response is
measured. A response that makes the objective worse is rolled back before a new
strategy is tried. Measured gain response is used for the second correction.
Up to two total repair renders are available, with at most two
render-engine retries when REAPER creates no file. A render that remains active
for five minutes times out without starting an overlapping render.

v4.2 directly scans the rendered 24-bit PCM words at the WAV's own sample rate
for sample and four-phase cubic peak estimates, keeping the most conservative
result from that scan, REAPER, and SWS. Digital silence or a non-finite analyzer
result is never interpreted as "very quiet" and
never receives gain. The repair that produced it is rolled back, the complete
source/send/bus/master graph is reasserted, and one clean no-gain render retry is
allowed. Every completed WAV must also remain size-stable for one second before
verification, preventing incomplete external-drive files from entering repair.
The latest independently measured audible render is preserved throughout the
loop, so a later bad repair can never replace it with a silent failed file.

Repair Last Failed WAV is in the SAME APP, not another script. Choose the
preserved _FAILED_INSPECTION.wav (including a v3.7 failed WAV). Recovery checks
its accompanying audit and SHA-256, accepts only peak/preferred-click failures,
re-verifies the 2.5/30-second padding, stages a local copy, and tests a fixed
per-channel gain candidate. It publishes a new _RECOVERED.wav and audit only if
the complete WAV safety checks and a full-file publication checksum pass. The
original failed file and audit are
never overwritten. If the failed WAV is silent, has missing clicks, changed
since its audit, or has another hard defect, recovery refuses it clearly.

Recover Interrupted Render is also inside this same Lua app. Select the prior
SONG_SHOWTRACK.bildibeat_checkpoint.txt. The app checks its stored verification
profile and checksum, copies the fully written local temporary WAV without
changing it, detects whether the 2.5/30-second silence is already present,
performs the complete final analysis, and publishes a new verified WAV/audit
pair without rerendering the song. A partial WAV is refused. If the original
WAV/audit pair already exists and matches, it simply reports that the build was
complete. The checkpoint and old temporary WAV are removed only after success.

Normal builds now stage and fully checksum both the WAV and audit before
publication. The audit is committed first and the WAV last; a failed second
commit removes the new audit and retains the verified local WAV for recovery.
The app cannot report success when the audit is missing or mismatched.

All labeled media that lives on a removable or network volume is copied once to
a LOCALAPPDATA working cache and the in-memory song takes are
repointed there before analysis. Temporary meter and final-verification renders
also stay on that fixed local drive, even if REAPER itself is a portable install
on removable media. Source staging receives sampled content-integrity checks;
final WAV publication receives a full-file SHA-256 match. Only the finished
verified WAV/audit pair is committed to the chosen destination. An output-drive failure
cannot create a silent mix; a destination failure offers another location, and
an unavailable source drive stops plainly before any render begins.

The actual WAV uses a two-LU normal completion tolerance. Short-term range is a
reported quality measurement, not a failure gate: the new source curves can
reduce spiky peaks, but forcing every phrase flat would require time-varying
gain that the anti-pump contract forbids. After bounded
constant-gain correction, larger loudness differences are published only under
the safe-audible fallback with a prominent audit warning. This policy never
relaxes true-peak ceilings, required audible content, channel isolation, WAV
format, duration, or exact padding. CLICK must remain measurably above the
music; after repairs, the final fallback still requires at least 3 dB measured
prominence at the quiet-hit percentile and 100% coverage of expected beat windows.

If a safe audible file remains outside only the numerical loudness/range quality
targets after bounded repair, the final safety policy publishes it and records
the exact exception instead of failing the song indefinitely. This last policy
still cannot publish silence, missing CLICK/FOH, wrong-channel audio, excessive
peak, invalid measurement, corrupt duration/format, or incorrect padding.

Before changing a normal project, the app captures a complete in-memory state
snapshot and saves a timestamped PREBUILD_BACKUP
RPP beside the output. A small checkpoint records the current stage and remains
after a crash or failure; the next run restarts cleanly. Failures also create a
stable-code DIAGNOSTIC text file. A successfully verified build removes its
checkpoint. If final publication to the chosen filename fails, the already-
verified WAV can be moved to an alternate destination without rerendering.

OUTPUT VALIDATION
-----------------
The final file must be stereo 24-bit PCM, have the expected duration and exact
2.5/30-second zero-byte padding, target the loudness profile, stay
under both true-peak ceilings, preserve click audibility at the detected beat
positions, contain audible left/IEM content, contain audible right/FOH content
whenever FOH sources were included, and contain no right-channel audio when FOH
is absent. A completely silent show file can never pass. The final WAV
is atomically published only after verification. Its audit includes SHA-256,
actual loudness, true peak, native PCM peak, natural range, spectrum, final click prominence, click
sample ID, profile ID, every source's phase-aware mono decision, cancellation
window count, constant-gain corrections and rollbacks, hardware ceiling, and SWS
cross-check information.

HARDWARE BLEED AND IPAD PLAYBACK
--------------------------------
A WAV has perfectly separate digital channels, but it cannot eliminate analog
crosstalk in an iPad, adapter, headphone output, breakout cable, DI, or mixer.
Use Analyze Breakout Loopback with a recording of the generated calibration
file through the exact show chain. The analyzer stores a hardware-safe IEM
ceiling with 0.5 dB margin. Future builds automatically cap the left ceiling to
that measurement and identify its loopback report. The app never raises a
profile ceiling from a hardware result.

Running the iPad at full volume is acceptable only after downstream gains and
the stored loopback ceiling have been tested safely. Start physical IEM and FOH
gain low. A passive breakout cable does not provide galvanic isolation; use a
reliable adapter/DI when the show environment requires it.

SHOW-FOLDER VALIDATION
----------------------
Validate Complete Show Folder checks audit/WAV checksums, profile and click-
sample consistency, padding, actual loudness, true peaks, dynamic range,
hardware ceiling compliance, spectral outliers, and emergency-mode use. This is
the final check before copying the set to the iPad. It ignores calibration,
loopback, failed-inspection, and unrelated WAV files. A file already accepted
by the builder's documented emergency/safety policy remains a pass with a clear
warning; the folder validator no longer contradicts that decision by applying
an older stricter range or show-median limit.

FILES CREATED BESIDE A BUILD
----------------------------
- SONG_SHOWTRACK.wav                    verified show track
- SONG_SHOWTRACK_AUDIT.txt              measurements and repair history
- SONG_SHOWTRACK_PREBUILD_BACKUP_*.rpp  recoverable project copy
- SONG_SHOWTRACK_BREAKOUT_CAL.wav       optional calibration
- SONG_SHOWTRACK_DIAGNOSTIC.txt         only when a failure needs diagnosis
- SONG_SHOWTRACK.bildibeat_checkpoint.txt only while incomplete or failed

The package itself always contains one functional Lua app plus this README.
