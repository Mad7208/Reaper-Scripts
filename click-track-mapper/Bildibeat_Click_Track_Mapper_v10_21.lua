--[[
  Bildibeat Click Track Mapper
  Target: REAPER 7.77+ / Windows x64
  Dependencies: REAPER, the SWS/S&M Extension, and Windows PowerShell.
  Open workbooks are read through a temporary shared-access snapshot; only saved
  spreadsheet changes are visible to the script.
  The app never edits the workbook automatically. Before building it offers a
  unique editable pre-build REAPER .RPP Save As name, Continue Without Saving,
  or Cancel Build. After a verified build it offers a clearly differentiated
  completed-build .RPP name containing the Build ID and verifies the save path.
  v10.21 adds verified workbook reconstruction from the active REAPER project.
  The analyzer preserves COUNT IN, END, exact Section-marker names, bar counts,
  meters, tempos, click patterns, and ramps; infers tuplets only from exact
  supported tempo ratios; and conservatively compresses exact repeats/Blocks.
  A generated XLSX or CSV is offered only after the production parser expands it
  back to a musical map that matches the open project one-for-one.
  The synchronized Click Package export, exact click-count verification, and
  read-only Validate Against Open Project workflow remain unchanged.
  The v10.19 Preserve/Conform audio policies, selection-aware tempo reversion,
  workbook-difference rows, verified workbook-copy adoption, Generic Part Names,
  Tempo Preview, and Send to Scratchpad remain unchanged.

  Spreadsheet columns (header capitalization and spacing are flexible):
    SECTION NAME | BPM | PARTS

  Part syntax:
    [N]      = N/4
    (N)      = N/8
    {N}      = N/16
    *N*      = N/32
    ENT(N)    = Eighth Note Triplet: N/4 at underlying BPM x 1.5
    SXT{N}   = Sextuplet: N/4 at underlying BPM x 3
    QNT{N}   = Quintuplet: N/4 at underlying BPM x 5
    SPT{N}   = Septuplet: N/4 at underlying BPM x 7
                 N is the positive whole-number beat count. The multiplier
                 applies after an optional @BPM override and does not carry
                 forward. Existing repeat and trailing-ramp rules apply.
    xR / XR  = total number of repeated measures; omitted means 1
    @BPM     = underlying BPM override for that part only
    - / --   = ramp across the final 1 / 2 bars; dash count may not exceed repeats
    <...>xR  = repeat all contained ordinary parts as one block for R passes
               (xR omitted means one pass; nesting, >@BPM, and >xR- are invalid)
    Outside blocks, parts are separated by commas. Internal commas stay inside
    the block. A final internal ramp targets only the next block pass, is
    inactive on the final pass, and cannot cross >. A normal part before a block
    may still ramp into the block's first part.

  The final populated row must be END. END PARTS must be blank; END BPM may
  be blank or a positive decimal. One or more trailing dashes define how many final bars of a part gradually
  transition to the next effective BPM. A dashed final musical part transitions
  to the END-row BPM (or 25 if blank). Otherwise END is 25.
  END always creates a 1/4 tempo/time-signature marker at the exact endpoint.

  BPM cell syntax:
    120            = section tempo with the normal A-first/B-rest click pattern
    120 no accent  = section tempo with an all-A click pattern; case and spacing
                     are flexible. Automatic COUNT IN always stays accented.

  Automatic count-in:
    - A standard project marker named COUNT IN is created at visible measure 1.
    - Visible measures 1 and 2 are rebuilt as exactly two bars of 4/4.
    - The count-in BPM matches the BPM cell of the first musical spreadsheet row.
    - The first musical part may omit @BPM or use the same BPM as that first row.
      A differing first-part @BPM override is rejected during validation so the
      count-in and song start cannot disagree about the underlying base tempo.
    - COUNT IN is a reserved automatic marker name and cannot be used as a
      spreadsheet section name.
    - Preview, confirmation, comparison, exports, and logs identify the exact
      spreadsheet row and section that supply the count-in BPM, and separately
      show the first part's effective REAPER BPM.
    - Spreadsheet-driven song processing still begins at visible measure 3.
]]

local SCRIPT_NAME = "Bildibeat Click Track Mapper v10.21"
local SCRIPT_VERSION = "10.21"
local MADE_BY = "Bidlibop"
local EXTSTATE_SECTION = "REAPER_Song_Structure_Builder"
local PREF_SCHEMA_VERSION = 2
local TEMPO_RECOVERY_SCHEMA = 1
local TEMPO_RECOVERY_FILENAME = "Bildibeat_Click_Track_Mapper_v10_21_Tempo_Recovery.txt"
local START_VISIBLE_MEASURE = 3
local COUNT_IN = {name="COUNT IN", visible_measure=1, bars=2, numerator=4, denominator=4}
local END_BPM = 25.0
local MAX_EXPANDED_BLOCK_PARTS = 10000
local DEFAULT_CLICK_A_HZ = 1760
local DEFAULT_CLICK_B_HZ = 1600

-- Keep the release portable as one Lua file while storing implementation
-- functions in a private application namespace. Top-level function declarations
-- below write into App through _ENV instead of consuming persistent Lua locals.
-- This leaves substantial headroom beneath Lua's 200-active-local limit.
local App = setmetatable({modules={}}, {__index=_G})
local _ENV = App
local state, show_info, set_status, show_input

function script_directory()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1,1) == "@" then source = source:sub(2) end
  return source:match("^(.*[\\/])") or ""
end
local END_NUM = 1
local END_DEN = 4
local EPS_TIME = 1e-7
local AUDITION_TRANSPORT_END_GUARD = 0.020
local ACTION_STOP_PLAYBACK_AT_LOOP_END = 41834
local ACTION_TOGGLE_METRONOME = 40364
local ACCESSIBILITY_FONT_SCALE = 1.50
local ACCESSIBILITY_FONT_ADD = 6
local EPS_BPM = 0.0051
local PREVIEW_SAMPLE_RATE = 44100
local PREVIEW_CLICK_SECONDS = 0.028
local PREVIEW_MAX_SECONDS = 600
local CLICK_EXPORT_TAIL_SECONDS = 0.075
local CLICK_EXPORT_MAX_SECONDS = 14400
local CLICK_EXPORT_MAX_MIDI_EVENTS = 2000000
local MIDI_PPQ = 960
local MIDI_RAMP_STEPS_PER_QN = 32
local MIDI_ACCENT_NOTE = 76
local MIDI_REGULAR_NOTE = 77
local MIDI_ACCENT_VELOCITY = 120
local MIDI_REGULAR_VELOCITY = 88
local MIDI_NOTE_LENGTH_TICKS = 60
local DEFAULT_MP3_RENDER_CONFIG = "bDNwbYAAAAAAAAAAAgAAAP////8EAAAAgAAAAAAAAAA="
local TEMPO_AUDITION_MIN_BPM = 20
local TEMPO_AUDITION_MAX_BPM = 400
local TEST_MODE = rawget(_G,"CLICK_TRACK_MAPPER_TEST_MODE")==true or reaper.GetExtState(EXTSTATE_SECTION,"test_mode_once")=="1"
if reaper.GetExtState(EXTSTATE_SECTION,"test_mode_once")=="1" then reaper.DeleteExtState(EXTSTATE_SECTION,"test_mode_once",false) end

-- Safe Mode is activated once by the companion launcher. It ignores persisted
-- window/layout/theme/workspace preferences for this run without deleting them.
local SAFE_MODE = reaper.GetExtState(EXTSTATE_SECTION,"safe_mode_once") == "1"
if SAFE_MODE then reaper.DeleteExtState(EXTSTATE_SECTION,"safe_mode_once",false) end

function trim(s)
  if s == nil then return "" end
  return tostring(s):match("^%s*(.-)%s*$") or ""
end

function upper(s)
  return string.upper(tostring(s or ""))
end

function normalize_header(s)
  return upper(trim(s)):gsub("[%s_%-%.]+", "")
end

function normalize_name(s)
  return upper(trim(s))
end

function round_hundredth(n)
  return math.floor(n * 100 + 0.5) / 100
end

function nearly_equal(a, b, tolerance)
  return math.abs((a or 0) - (b or 0)) <= (tolerance or 1e-9)
end

function file_extension(path)
  return (path:match("%.([^%.\\/]+)$") or ""):lower()
end

function validate_workbook_selection_path(path)
  path=trim(path)
  if path=="" then return nil,"[WB-001] No workbook was selected." end
  local ext=file_extension(path)
  if ext~="xlsx" and ext~="csv" then
    return nil,"[WB-003] Choose a saved XLSX or CSV workbook."
  end
  return path
end

function workbook_open_dialog_kind(api)
  api=api or reaper
  if type(api.GetUserFileName)=="function" then return "modern" end
  if type(api.GetUserFileNameForRead)=="function" then return "legacy" end
  return nil
end

function choose_workbook_path(initial,api)
  api=api or reaper
  local kind=workbook_open_dialog_kind(api)
  local ok,path
  if kind=="modern" then
    ok,path=api.GetUserFileName(1,"Choose click track map spreadsheet",initial or "","Excel workbooks|*.xlsx|CSV files|*.csv|All files|*.*")
  elseif kind=="legacy" then
    -- GetUserFileName was added after the older read-only chooser. Keeping this
    -- fallback lets the same release run on REAPER installations that predate
    -- the newer filtered dialog API.
    ok,path=api.GetUserFileNameForRead(initial or "","Choose click track map spreadsheet","")
  else
    return nil,"[WB-015] This REAPER installation does not provide a supported workbook Browse dialog.",false
  end
  if not ok then return nil,nil,true end
  local validated,err=validate_workbook_selection_path(path)
  return validated,err,false
end

function file_exists(path)
  if reaper.file_exists then return reaper.file_exists(path) end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

function file_fingerprint(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local size = 0
  local hash = 5381
  while true do
    local chunk = f:read(1024 * 1024)
    if not chunk then break end
    size = size + #chunk
    for i = 1, #chunk do
      hash = (hash * 33 + chunk:byte(i)) % 4294967291
    end
  end
  f:close()
  return string.format("%d:%u", size, hash)
end

function format_bpm(n)
  if nearly_equal(n, math.floor(n + 0.5), 1e-9) then
    return tostring(math.floor(n + 0.5))
  end
  local s = string.format("%.10f", n):gsub("0+$", ""):gsub("%.$", "")
  return s
end

function format_effective_bpm(n)
  return string.format("%.2f", n)
end

function format_duration_precise(seconds)
  if seconds < 0 then seconds = 0 end
  local minutes = math.floor(seconds / 60)
  local secs = seconds - minutes * 60
  return string.format("%d:%06.3f", minutes, secs)
end

function format_duration(seconds)
  if seconds < 0 then seconds = 0 end
  local rounded = math.floor(seconds + 0.5)
  return string.format("%02d:%02d", math.floor(rounded / 60), rounded % 60)
end

function split_tab(line)
  local out = {}
  local start = 1
  while true do
    local p = line:find("\t", start, true)
    if not p then
      out[#out + 1] = line:sub(start)
      break
    end
    out[#out + 1] = line:sub(start, p - 1)
    start = p + 1
  end
  return out
end

-- Minimal Base64 decoder for PowerShell extractor output.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_MAP = {}
for i = 1, #B64_CHARS do B64_MAP[B64_CHARS:sub(i, i)] = i - 1 end

function base64_decode(data)
  data = tostring(data or ""):gsub("%s", "")
  local out = {}
  local i = 1
  while i <= #data do
    local c1 = data:sub(i, i); i = i + 1
    local c2 = data:sub(i, i); i = i + 1
    local c3 = data:sub(i, i); i = i + 1
    local c4 = data:sub(i, i); i = i + 1
    local n1, n2 = B64_MAP[c1], B64_MAP[c2]
    if n1 == nil or n2 == nil then break end
    local n3 = c3 == "=" and nil or B64_MAP[c3]
    local n4 = c4 == "=" and nil or B64_MAP[c4]
    local triple = n1 * 262144 + n2 * 4096 + (n3 or 0) * 64 + (n4 or 0)
    out[#out + 1] = string.char(math.floor(triple / 65536) % 256)
    if n3 ~= nil then out[#out + 1] = string.char(math.floor(triple / 256) % 256) end
    if n4 ~= nil then out[#out + 1] = string.char(triple % 256) end
  end
  return table.concat(out)
end

function base64_encode(data)
  data=tostring(data or "")
  local out={}
  for index=1,#data,3 do
    local a=data:byte(index) or 0;local b=data:byte(index+1);local c=data:byte(index+2)
    local triple=a*65536+(b or 0)*256+(c or 0)
    local n1=math.floor(triple/262144)%64;local n2=math.floor(triple/4096)%64;local n3=math.floor(triple/64)%64;local n4=triple%64
    out[#out+1]=B64_CHARS:sub(n1+1,n1+1);out[#out+1]=B64_CHARS:sub(n2+1,n2+1)
    out[#out+1]=b and B64_CHARS:sub(n3+1,n3+1) or "="
    out[#out+1]=c and B64_CHARS:sub(n4+1,n4+1) or "="
  end
  return table.concat(out)
end

local POWERSHELL_SHARED_COPY = [=[
param(
  [Parameter(Mandatory=$true)][string]$InputPath,
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [Parameter(Mandatory=$true)][string]$StatusPath
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function To-B64([string]$Text) {
  if ($null -eq $Text) { $Text = '' }
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

$source = $null
$destination = $null
try {
  $shareMode = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $source = [IO.File]::Open($InputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $shareMode)
  $destination = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $source.CopyTo($destination)
  $destination.Flush()
  $destination.Dispose(); $destination = $null
  $source.Dispose(); $source = $null
  [IO.File]::WriteAllText($StatusPath, 'OK', $Utf8NoBom)
}
catch {
  if ($null -ne $destination) { $destination.Dispose() }
  if ($null -ne $source) { $source.Dispose() }
  [IO.File]::WriteAllText($StatusPath, ('ERROR' + "`t" + (To-B64 $_.Exception.Message)), $Utf8NoBom)
  exit 1
}
]=]

local POWERSHELL_XLSX_EXTRACTOR = [=[
param(
  [Parameter(Mandatory=$true)][string]$InputPath,
  [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function To-B64([string]$Text) {
  if ($null -eq $Text) { $Text = '' }
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Col-To-Number([string]$Reference) {
  $letters = ([regex]::Match($Reference, '^[A-Za-z]+')).Value.ToUpperInvariant()
  $n = 0
  foreach ($ch in $letters.ToCharArray()) {
    $n = ($n * 26) + ([int][char]$ch - [int][char]'A' + 1)
  }
  return $n
}

$zip = $null
$writer = $null
try {
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($InputPath)

  function Read-ZipEntry([string]$Name) {
    $entry = $zip.GetEntry($Name.Replace('\\','/'))
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
  }

  $workbookText = Read-ZipEntry 'xl/workbook.xml'
  $relsText = Read-ZipEntry 'xl/_rels/workbook.xml.rels'
  if ([string]::IsNullOrWhiteSpace($workbookText) -or [string]::IsNullOrWhiteSpace($relsText)) {
    throw 'The workbook is missing required Open XML files.'
  }

  [xml]$workbook = $workbookText
  [xml]$rels = $relsText

  $wbNs = New-Object Xml.XmlNamespaceManager($workbook.NameTable)
  $wbNs.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
  $wbNs.AddNamespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
  $relNs = New-Object Xml.XmlNamespaceManager($rels.NameTable)
  $relNs.AddNamespace('pr', 'http://schemas.openxmlformats.org/package/2006/relationships')

  $shared = New-Object System.Collections.Generic.List[string]
  $sharedText = Read-ZipEntry 'xl/sharedStrings.xml'
  if (-not [string]::IsNullOrWhiteSpace($sharedText)) {
    [xml]$sharedXml = $sharedText
    $sharedNs = New-Object Xml.XmlNamespaceManager($sharedXml.NameTable)
    $sharedNs.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
    foreach ($si in $sharedXml.SelectNodes('//m:si', $sharedNs)) {
      $pieces = New-Object System.Collections.Generic.List[string]
      foreach ($t in $si.SelectNodes('.//m:t', $sharedNs)) { [void]$pieces.Add($t.InnerText) }
      [void]$shared.Add(($pieces -join ''))
    }
  }

  $writer = New-Object IO.StreamWriter($OutputPath, $false, $Utf8NoBom)
  $writer.WriteLine('OK')

  $sheetIndex = 0
  foreach ($sheet in $workbook.SelectNodes('//m:sheets/m:sheet', $wbNs)) {
    $sheetIndex++
    $sheetName = $sheet.GetAttribute('name')
    $rid = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $relNode = $rels.SelectSingleNode("//pr:Relationship[@Id='$rid']", $relNs)
    if ($null -eq $relNode) { throw "Could not resolve worksheet relationship for '$sheetName'." }

    $baseUri = [Uri]'http://local/xl/workbook.xml'
    $sheetUri = [Uri]::new($baseUri, [string]$relNode.Target)
    $entryName = $sheetUri.AbsolutePath.TrimStart('/')
    $sheetText = Read-ZipEntry $entryName
    if ([string]::IsNullOrWhiteSpace($sheetText)) { throw "Could not read worksheet '$sheetName'." }

    [xml]$sheetXml = $sheetText
    $sheetNs = New-Object Xml.XmlNamespaceManager($sheetXml.NameTable)
    $sheetNs.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')

    $writer.WriteLine(('SHEET' + "`t" + $sheetIndex + "`t" + (To-B64 $sheetName)))

    foreach ($merge in $sheetXml.SelectNodes('//m:mergeCells/m:mergeCell', $sheetNs)) {
      $writer.WriteLine(('MERGE' + "`t" + $sheetIndex + "`t" + (To-B64 $merge.GetAttribute('ref'))))
    }

    foreach ($cell in $sheetXml.SelectNodes('//m:sheetData/m:row/m:c', $sheetNs)) {
      $reference = $cell.GetAttribute('r')
      $rowMatch = [regex]::Match($reference, '\d+$')
      if (-not $rowMatch.Success) { continue }
      $rowNumber = [int]$rowMatch.Value
      $colNumber = Col-To-Number $reference
      $cellType = $cell.GetAttribute('t')
      $formulaNode = $cell.SelectSingleNode('m:f', $sheetNs)
      $kind = 'V'
      $value = ''

      if ($null -ne $formulaNode) {
        $kind = 'F'
        $value = $formulaNode.InnerText
      }
      elseif ($cellType -eq 's') {
        $v = $cell.SelectSingleNode('m:v', $sheetNs)
        if ($null -ne $v -and $v.InnerText -match '^\d+$') {
          $idx = [int]$v.InnerText
          if ($idx -ge 0 -and $idx -lt $shared.Count) { $value = $shared[$idx] }
        }
      }
      elseif ($cellType -eq 'inlineStr') {
        $pieces = New-Object System.Collections.Generic.List[string]
        foreach ($t in $cell.SelectNodes('m:is//m:t', $sheetNs)) { [void]$pieces.Add($t.InnerText) }
        $value = $pieces -join ''
      }
      else {
        $v = $cell.SelectSingleNode('m:v', $sheetNs)
        if ($null -ne $v) { $value = $v.InnerText }
      }

      if ($kind -eq 'F' -or -not [string]::IsNullOrEmpty($value)) {
        $writer.WriteLine(('CELL' + "`t" + $sheetIndex + "`t" + $rowNumber + "`t" + $colNumber + "`t" + $kind + "`t" + (To-B64 $value)))
      }
    }
  }
}
catch {
  if ($null -ne $writer) { $writer.Dispose(); $writer = $null }
  [IO.File]::WriteAllText($OutputPath, ('ERROR' + "`t" + (To-B64 $_.Exception.Message)), $Utf8NoBom)
  exit 1
}
finally {
  if ($null -ne $writer) { $writer.Dispose() }
  if ($null -ne $zip) { $zip.Dispose() }
}
]=]

local POWERSHELL_XLSX_PATCHER = [=[
param(
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [Parameter(Mandatory=$true)][string]$InputPath,
  [Parameter(Mandatory=$true)][string]$DestinationPath,
  [Parameter(Mandatory=$true)][int]$SheetIndex,
  [Parameter(Mandatory=$true)][string]$EditsPath
)
$ErrorActionPreference='Stop'
$Utf8NoBom=New-Object Text.UTF8Encoding($false)
function B64([string]$Text) { if ($null -eq $Text) {$Text=''}; [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Col-Name([int]$Number) { $name=''; while($Number -gt 0){$Number--; $name=[char](65+($Number%26))+$name; $Number=[math]::Floor($Number/26)}; $name }
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $source=$null;$destination=$null
  try {
    $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $source=[IO.File]::Open($InputPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
    $destination=[IO.File]::Open($DestinationPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $source.CopyTo($destination);$destination.Flush()
  } finally { if($destination){$destination.Dispose()};if($source){$source.Dispose()} }
  # Numeric enum values avoid Windows PowerShell type-resolution failures seen
  # on otherwise valid .NET 4.x installs: ZipArchiveMode.Update=2.
  $zip=[System.IO.Compression.ZipFile]::Open($DestinationPath,2)
  try {
    function Read-Entry([string]$Name){$entry=$zip.GetEntry($Name.Replace('\','/'));if(!$entry){return $null};$stream=$entry.Open();$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true);try{$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}}
    [xml]$workbook=Read-Entry 'xl/workbook.xml';[xml]$rels=Read-Entry 'xl/_rels/workbook.xml.rels'
    $wbNs=New-Object Xml.XmlNamespaceManager($workbook.NameTable);$wbNs.AddNamespace('m','http://schemas.openxmlformats.org/spreadsheetml/2006/main');$wbNs.AddNamespace('r','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $relNs=New-Object Xml.XmlNamespaceManager($rels.NameTable);$relNs.AddNamespace('pr','http://schemas.openxmlformats.org/package/2006/relationships')
    $sheets=$workbook.SelectNodes('//m:sheets/m:sheet',$wbNs);if($SheetIndex -lt 1 -or $SheetIndex -gt $sheets.Count){throw 'Validated worksheet index is unavailable.'}
    $sheet=$sheets[$SheetIndex-1];$rid=$sheet.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships');$rel=$rels.SelectSingleNode("//pr:Relationship[@Id='$rid']",$relNs);if(!$rel){throw 'Worksheet relationship could not be resolved.'}
    $base=[Uri]'http://local/xl/workbook.xml';$uri=[Uri]::new($base,[string]$rel.Target);$entryName=$uri.AbsolutePath.TrimStart('/');$sheetText=Read-Entry $entryName;if([string]::IsNullOrWhiteSpace($sheetText)){throw 'Worksheet XML could not be read.'}
    [xml]$sheetXml=$sheetText;$nsUri='http://schemas.openxmlformats.org/spreadsheetml/2006/main';$sheetNs=New-Object Xml.XmlNamespaceManager($sheetXml.NameTable);$sheetNs.AddNamespace('m',$nsUri)
    foreach($line in [IO.File]::ReadAllLines($EditsPath,[Text.Encoding]::UTF8)){
      if([string]::IsNullOrWhiteSpace($line)){continue};$fields=$line.Split("`t");if($fields.Count -lt 4){throw 'An updated-workbook edit record is malformed.'}
      $rowNumber=[int]$fields[0];$colNumber=[int]$fields[1];$kind=$fields[2];$value=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fields[3]));$reference=(Col-Name $colNumber)+$rowNumber
      $row=$sheetXml.SelectSingleNode("//m:sheetData/m:row[@r='$rowNumber']",$sheetNs)
      if(!$row){$sheetData=$sheetXml.SelectSingleNode('//m:sheetData',$sheetNs);$row=$sheetXml.CreateElement('row',$nsUri);$row.SetAttribute('r',[string]$rowNumber);[void]$sheetData.AppendChild($row)}
      $cell=$row.SelectSingleNode("m:c[@r='$reference']",$sheetNs)
      if($kind -eq 'B'){if($cell){[void]$row.RemoveChild($cell)};continue}
      if(!$cell){$cell=$sheetXml.CreateElement('c',$nsUri);$cell.SetAttribute('r',$reference);[void]$row.AppendChild($cell)}
      while($cell.HasChildNodes){[void]$cell.RemoveChild($cell.FirstChild)}
      if($kind -eq 'N'){
        [void]$cell.RemoveAttribute('t');$v=$sheetXml.CreateElement('v',$nsUri);$v.InnerText=$value;[void]$cell.AppendChild($v)
      } else {
        $cell.SetAttribute('t','inlineStr');$is=$sheetXml.CreateElement('is',$nsUri);$t=$sheetXml.CreateElement('t',$nsUri);$space=$sheetXml.CreateAttribute('xml','space','http://www.w3.org/XML/1998/namespace');$space.Value='preserve';[void]$t.Attributes.Append($space);$t.InnerText=$value;[void]$is.AppendChild($t);[void]$cell.AppendChild($is)
      }
    }
    # CompressionLevel.Optimal=0.
    $old=$zip.GetEntry($entryName);if(!$old){throw 'Worksheet archive entry disappeared before update.'};$old.Delete();$new=$zip.CreateEntry($entryName,0);$stream=$new.Open()
    try{$settings=New-Object Xml.XmlWriterSettings;$settings.Encoding=$Utf8NoBom;$settings.Indent=$false;$writer=[Xml.XmlWriter]::Create($stream,$settings);try{$sheetXml.Save($writer)}finally{$writer.Dispose()}}finally{$stream.Dispose()}
  } finally {$zip.Dispose()}
  [IO.File]::WriteAllText($OutputPath,'OK',$Utf8NoBom)
} catch {
  [IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+(B64 $_.Exception.Message)),$Utf8NoBom);exit 1
}
]=]

local POWERSHELL_XLSX_CREATOR = [=[
param(
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [Parameter(Mandatory=$true)][string]$DestinationPath,
  [Parameter(Mandatory=$true)][string]$RowsPath,
  [Parameter(Mandatory=$true)][string]$SheetName
)
$ErrorActionPreference='Stop'
$Utf8NoBom=New-Object Text.UTF8Encoding($false)
function B64([string]$Text){if($null -eq $Text){$Text=''};[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}
function X([string]$Text){[Security.SecurityElement]::Escape([string]$Text)}
function Add-TextEntry($Zip,[string]$Name,[string]$Text){
  $entry=$Zip.CreateEntry($Name,0);$stream=$entry.Open()
  try{$writer=New-Object IO.StreamWriter($stream,$Utf8NoBom);try{$writer.Write($Text)}finally{$writer.Dispose()}}finally{$stream.Dispose()}
}
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if([IO.File]::Exists($DestinationPath)){[IO.File]::Delete($DestinationPath)}
  $zip=[System.IO.Compression.ZipFile]::Open($DestinationPath,1)
  try {
    $rows=New-Object Collections.Generic.List[string]
    $rowNumber=0
    foreach($line in [IO.File]::ReadAllLines($RowsPath,[Text.Encoding]::UTF8)){
      if([string]::IsNullOrWhiteSpace($line)){continue}
      $rowNumber++
      $fields=$line.Split("`t")
      if($fields.Count -lt 3){throw "Generated workbook row manifest is malformed at line $rowNumber."}
      $values=@()
      foreach($field in $fields){$values += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($field))}
      $cells=New-Object Collections.Generic.List[string]
      for($column=0;$column -lt 3;$column++){
        $reference=([char](65+$column))+[string]$rowNumber
        $value=[string]$values[$column]
        $style=if($rowNumber -eq 1){' s="1"'}else{''}
        if($column -eq 1 -and $rowNumber -gt 1 -and $value -match '^\d+(\.\d+)?$'){
          $cells.Add("<c r=`"$reference`"$style><v>$(X $value)</v></c>")
        } elseif(-not [string]::IsNullOrEmpty($value)){
          $cells.Add("<c r=`"$reference`" t=`"inlineStr`"$style><is><t xml:space=`"preserve`">$(X $value)</t></is></c>")
        }
      }
      $rows.Add("<row r=`"$rowNumber`">"+($cells -join '')+"</row>")
    }
    if($rowNumber -lt 3){throw 'Generated workbook needs a header, at least one Section, and END.'}
    $sheetXml='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'+
      '<dimension ref="A1:C'+$rowNumber+'"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'+
      '<cols><col min="1" max="1" width="28" customWidth="1"/><col min="2" max="2" width="18" customWidth="1"/><col min="3" max="3" width="90" customWidth="1"/></cols>'+
      '<sheetData>'+($rows -join '')+'</sheetData><autoFilter ref="A1:C'+$rowNumber+'"/></worksheet>'
    $safeSheet=(X $SheetName)
    Add-TextEntry $zip '[Content_Types].xml' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
    Add-TextEntry $zip '_rels/.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>'
    Add-TextEntry $zip 'xl/workbook.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="'+$safeSheet+'" sheetId="1" r:id="rId1"/></sheets></workbook>')
    Add-TextEntry $zip 'xl/_rels/workbook.xml.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
    Add-TextEntry $zip 'xl/styles.xml' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Segoe UI"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Segoe UI"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
    Add-TextEntry $zip 'xl/worksheets/sheet1.xml' $sheetXml
    $now=[DateTime]::UtcNow.ToString('s')+'Z'
    Add-TextEntry $zip 'docProps/core.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>Bildibeat Click Track Mapper</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">'+$now+'</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">'+$now+'</dcterms:modified></cp:coreProperties>')
    Add-TextEntry $zip 'docProps/app.xml' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Bildibeat Click Track Mapper</Application></Properties>'
  } finally {$zip.Dispose()}
  [IO.File]::WriteAllText($OutputPath,'OK',$Utf8NoBom)
} catch {
  if([IO.File]::Exists($DestinationPath)){[IO.File]::Delete($DestinationPath)}
  [IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+(B64 $_.Exception.Message)),$Utf8NoBom);exit 1
}
]=]

function make_temp_path(extension)
  local root = os.getenv("TEMP") or os.getenv("TMP") or reaper.GetResourcePath()
  local unique = string.format("reaper_song_structure_%d_%d", os.time(), math.random(100000, 999999))
  return root .. "\\" .. unique .. extension
end

function command_quote(path)
  return '"' .. tostring(path):gsub('"', '\\"') .. '"'
end

function exec_process_result(result)
  if result == nil then return nil, "" end
  local first, output = tostring(result):match("^([^\r\n]*)\r?\n?(.*)$")
  return tonumber(trim(first)), trim(output or "")
end

function create_shared_read_snapshot(path, extension)
  if not reaper.GetOS():match("Win") then
    return nil, "Reading an open spreadsheet through a shared snapshot requires Windows PowerShell."
  end

  local snapshot_path = make_temp_path(extension or ".tmp")
  local ps_path = make_temp_path(".ps1")
  local status_path = make_temp_path(".txt")
  local ps, err = io.open(ps_path, "wb")
  if not ps then
    os.remove(snapshot_path)
    return nil, "Could not create temporary PowerShell file: " .. tostring(err)
  end
  ps:write(POWERSHELL_SHARED_COPY)
  ps:close()

  local command = table.concat({
    "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File",
    command_quote(ps_path),
    "-InputPath", command_quote(path),
    "-OutputPath", command_quote(snapshot_path),
    "-StatusPath", command_quote(status_path)
  }, " ")

  local process_output = reaper.ExecProcess(command, 120000)
  os.remove(ps_path)

  local status_file = io.open(status_path, "rb")
  local status_text = ""
  if status_file then
    status_text = status_file:read("*a") or ""
    status_file:close()
  end
  os.remove(status_path)
  status_text = status_text:gsub("^\239\187\191", "")

  if status_text:sub(1, 5) == "ERROR" then
    local fields = split_tab(status_text)
    os.remove(snapshot_path)
    return nil, "Could not create a readable snapshot of the spreadsheet: " .. base64_decode(fields[2] or "")
  end
  if status_text ~= "OK" or not file_exists(snapshot_path) then
    os.remove(snapshot_path)
    return nil, "Could not create a readable snapshot of the spreadsheet. Save the file, then try again. PowerShell output: " .. trim(process_output)
  end
  return snapshot_path
end

function parse_xlsx(path)
  if not reaper.GetOS():match("Win") then
    return nil, nil, "XLSX reading in this version requires Windows PowerShell."
  end

  local snapshot_path, snapshot_err = create_shared_read_snapshot(path, ".xlsx")
  if not snapshot_path then return nil, nil, snapshot_err end
  local snapshot_fingerprint, fp_err = file_fingerprint(snapshot_path)
  if not snapshot_fingerprint then
    os.remove(snapshot_path)
    return nil, nil, "Could not fingerprint the saved workbook snapshot: " .. tostring(fp_err)
  end

  local ps_path = make_temp_path(".ps1")
  local out_path = make_temp_path(".txt")
  local ps, err = io.open(ps_path, "wb")
  if not ps then
    os.remove(snapshot_path)
    return nil, nil, "Could not create temporary PowerShell file: " .. tostring(err)
  end
  ps:write(POWERSHELL_XLSX_EXTRACTOR)
  ps:close()

  local command = table.concat({
    "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File",
    command_quote(ps_path),
    "-InputPath", command_quote(snapshot_path),
    "-OutputPath", command_quote(out_path)
  }, " ")

  local process_output = reaper.ExecProcess(command, 120000)
  os.remove(ps_path)

  local f = io.open(out_path, "rb")
  if not f then
    os.remove(snapshot_path)
    return nil, nil, "PowerShell could not read the workbook snapshot. Process output: " .. trim(process_output)
  end
  local text = f:read("*a") or ""
  f:close()
  os.remove(out_path)
  os.remove(snapshot_path)
  text = text:gsub("^\239\187\191", "")

  local sheets = {}
  local first_line = true
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    if first_line then
      first_line = false
      if line:sub(1, 5) == "ERROR" then
        local fields = split_tab(line)
        return nil, nil, "XLSX reader error: " .. base64_decode(fields[2] or "")
      elseif line ~= "OK" then
        return nil, nil, "Unexpected response from the XLSX reader."
      end
    elseif line ~= "" then
      local fields = split_tab(line)
      local record_type = fields[1]
      if record_type == "SHEET" then
        local idx = tonumber(fields[2])
        sheets[idx] = {name = base64_decode(fields[3] or ""), cells = {}, formulas = {}, merges = {}, max_row = 0, max_col = 0}
      elseif record_type == "MERGE" then
        local idx = tonumber(fields[2])
        if sheets[idx] then sheets[idx].merges[#sheets[idx].merges + 1] = base64_decode(fields[3] or "") end
      elseif record_type == "CELL" then
        local idx = tonumber(fields[2])
        local row = tonumber(fields[3])
        local col = tonumber(fields[4])
        local kind = fields[5]
        local value = base64_decode(fields[6] or "")
        local sheet = sheets[idx]
        if sheet then
          sheet.cells[row] = sheet.cells[row] or {}
          sheet.cells[row][col] = {value = value, kind = kind}
          sheet.max_row = math.max(sheet.max_row, row)
          sheet.max_col = math.max(sheet.max_col, col)
          if kind == "F" then sheet.formulas[#sheet.formulas + 1] = {row = row, col = col, formula = value} end
        end
      end
    end
  end

  if #sheets == 0 then return nil, nil, "No worksheets were found in the workbook." end
  return sheets, snapshot_fingerprint, nil
end

function parse_csv_rows(text)
  text = text:gsub("^\239\187\191", "")
  local rows, row, field = {}, {}, {}
  local in_quotes = false
  local i = 1
  local function push_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end
  local function push_row()
    push_field()
    rows[#rows + 1] = row
    row = {}
  end

  while i <= #text do
    local ch = text:sub(i, i)
    if in_quotes then
      if ch == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          in_quotes = false
        end
      else
        field[#field + 1] = ch
      end
    else
      if ch == '"' then
        if #field > 0 then return nil, "Malformed CSV: a quoted field begins after unquoted text." end
        in_quotes = true
      elseif ch == ',' then
        push_field()
      elseif ch == '\r' then
        if text:sub(i + 1, i + 1) == '\n' then i = i + 1 end
        push_row()
      elseif ch == '\n' then
        push_row()
      else
        field[#field + 1] = ch
      end
    end
    i = i + 1
  end

  if in_quotes then return nil, "Malformed CSV: an opening quote is not closed." end
  if #field > 0 or #row > 0 then push_row() end
  return rows
end

function parse_csv(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, "Could not open CSV file: " .. tostring(err) end
  local text = f:read("*a") or ""
  f:close()
  local rows, parse_err = parse_csv_rows(text)
  if not rows then return nil, parse_err end

  local sheet = {name = "CSV", cells = {}, formulas = {}, merges = {}, max_row = #rows, max_col = 0, csv_row_widths = {}}
  for r, values in ipairs(rows) do
    sheet.cells[r] = {}
    sheet.csv_row_widths[r] = #values
    sheet.max_col = math.max(sheet.max_col, #values)
    for c, value in ipairs(values) do
      if value ~= "" then sheet.cells[r][c] = {value = value, kind = "V"} end
    end
  end
  return {sheet}
end

function cell_value(sheet, row, col)
  local cell = sheet.cells[row] and sheet.cells[row][col]
  return cell and cell.value or ""
end

function row_has_any_value(sheet, row)
  local cells = sheet.cells[row]
  if not cells then return false end
  for _, cell in pairs(cells) do
    if cell.kind == "F" or trim(cell.value) ~= "" then return true end
  end
  return false
end

function parse_positive_decimal(value, label)
  local s = trim(value)
  if not (s:match("^%d+$") or s:match("^%d+%.%d+$")) then
    return nil, label .. " must be a positive whole number or decimal without scientific notation."
  end
  local n = tonumber(s)
  if not n or n <= 0 then return nil, label .. " must be greater than zero." end
  return n
end

function parse_positive_integer(value, label)
  local s = trim(value)
  if not s:match("^%d+$") then return nil, label .. " must be a positive whole number." end
  local n = tonumber(s)
  if not n or n < 1 then return nil, label .. " must be at least 1." end
  return n
end

function split_parts(parts_text)
  if trim(parts_text) == "" then return nil, "PARTS cannot be empty." end
  local parts = {}
  local text = tostring(parts_text)
  local start_index, angle_depth = 1, 0
  for index = 1, #text do
    local character = text:sub(index,index)
    if character == "<" then
      if angle_depth > 0 then return nil, "Blocks cannot be nested. Remove the inner < > pair." end
      angle_depth = 1
    elseif character == ">" then
      if angle_depth == 0 then return nil, "Block syntax has a closing > without a matching opening <." end
      angle_depth = 0
    elseif character == "," and angle_depth == 0 then
      local piece = text:sub(start_index,index-1)
      if trim(piece) == "" then
        return nil, "Parts cannot be empty. Check for a leading, doubled, or trailing comma."
      end
      parts[#parts+1] = trim(piece)
      start_index = index+1
    end
  end
  if angle_depth ~= 0 then return nil, "Block syntax is missing its closing >." end
  local piece = text:sub(start_index)
  if trim(piece) == "" then
      return nil, "Parts cannot be empty. Check for a leading, doubled, or trailing comma."
  end
  parts[#parts+1] = trim(piece)
  return parts
end

function parse_part(source, section_bpm)
  local compact = trim(source):gsub("%s+", "")
  local normalized = upper(compact)
  if normalized == "" then return nil, "Part is empty." end

  local ramp_suffix = normalized:match("(%-+)$")
  local ramp_bars = ramp_suffix and #ramp_suffix or 0
  local ramp = ramp_bars > 0
  if ramp then
    normalized = normalized:sub(1, #normalized - ramp_bars)
    if normalized == "" then return nil, "The gradual-transition dashes must follow a complete part." end
  end
  if normalized:find("-", 1, true) then
    return nil, "Gradual-transition dashes must be consecutive and must be the final non-space characters of the part."
  end

  local body = normalized
  local override_bpm = nil
  local at_count = select(2, normalized:gsub("@", ""))
  if at_count > 1 then return nil, "A part may contain only one @BPM override." end
  if at_count == 1 then
    local before, bpm_text = normalized:match("^(.-)@(.+)$")
    if not before or before == "" then return nil, "@BPM must appear after the meter and optional repeat count." end
    local bpm, err = parse_positive_decimal(bpm_text, "Part BPM")
    if not bpm then return nil, err end
    body = before
    override_bpm = bpm
  end

  local repeat_count = 1
  local repeat_probe=body:match("^SXT(.*)$") or body
  local x_count=select(2,repeat_probe:gsub("X",""))
  if x_count>1 then return nil,"A part may contain only one repeat indicator." end
  if x_count==1 then
    local meter_text,repeat_text=body:match("^(.*)X(.+)$")
    if not meter_text or meter_text=="" then return nil,"Repeat syntax must follow the meter." end
    local repeats, err = parse_positive_integer(repeat_text, "Repeat count")
    if not repeats then return nil, err end
    body = meter_text
    repeat_count = repeats
  end

  local kind, numerator, denominator, multiplier, meter_display
  local n = body:match("^%[(%d+)%]$")
  if n then
    kind, numerator, denominator, multiplier = "quarter", tonumber(n), 4, 1
    meter_display = "[" .. n .. "]"
  else
    n = body:match("^%((%d+)%)$")
    if n then
      kind, numerator, denominator, multiplier = "eighth", tonumber(n), 8, 1
      meter_display = "(" .. n .. ")"
    else
      n = body:match("^%{(%d+)%}$")
      if n then
        kind, numerator, denominator, multiplier = "sixteenth", tonumber(n), 16, 1
        meter_display = "{" .. n .. "}"
      else
        n = body:match("^%*(%d+)%*$")
        if n then
          kind, numerator, denominator, multiplier = "thirty_second", tonumber(n), 32, 1
          meter_display = "*" .. n .. "*"
        else
          n = body:match("^ENT%((%d+)%)$")
          if n then
            kind, numerator, denominator, multiplier = "eighth_triplet", tonumber(n), 4, 1.5
            meter_display = "ENT(" .. n .. ")"
          else
            n = body:match("^SXT%{(%d+)%}$")
            if n then
              kind, numerator, denominator, multiplier = "sextuplet", tonumber(n), 4, 3
              meter_display = "SXT{" .. n .. "}"
            else
              n = body:match("^QNT%{(%d+)%}$")
              if n then
                kind, numerator, denominator, multiplier = "quintuplet", tonumber(n), 4, 5
                meter_display = "QNT{" .. n .. "}"
              else
                n = body:match("^SPT%{(%d+)%}$")
                if n then
                  kind, numerator, denominator, multiplier = "septuplet", tonumber(n), 4, 7
                  meter_display = "SPT{" .. n .. "}"
                end
              end
            end
          end
        end
      end
    end
  end

  if not kind then
    if body:match("^ET") then return nil, "Obsolete ET syntax is not supported. Use ENT(N) for an Eighth Note Triplet at underlying BPM x1.5." end
    if body:match("^QUINT") then return nil, "Obsolete QUINT syntax is not supported. Use QNT{N} for a Quintuplet at underlying BPM x5." end
    if body:match("^QT") then return nil, "Legacy QT syntax is not supported. Use ENT(N) for an Eighth Note Triplet at underlying BPM x1.5." end
    if body:match("^QNT%^") then return nil, "Caret-delimited QNT syntax is invalid. Use QNT{N} for a Quintuplet at underlying BPM x5." end
    if body:match("^STP") then return nil, "STP is not valid Septuplet syntax. Use SPT{N} at underlying BPM x7." end
    return nil, "Invalid meter syntax. Use [N], (N), {N}, *N*, ENT(N), SXT{N}, QNT{N}, or SPT{N}."
  end
  if numerator < 1 then return nil, "Meter count must be at least 1." end

  local underlying_bpm = override_bpm or section_bpm
  local effective_bpm = underlying_bpm
  if multiplier ~= 1 then effective_bpm = round_hundredth(underlying_bpm * multiplier) end
  if effective_bpm <= 0 then return nil, "Calculated BPM must be greater than zero." end

  if ramp_bars > repeat_count then
    return nil, string.format("Gradual-transition dash count (%d) cannot exceed the part's total bar count (%d).", ramp_bars, repeat_count)
  end

  local canonical = meter_display
  if repeat_count ~= 1 then canonical = canonical .. "x" .. repeat_count end
  if override_bpm then canonical = canonical .. "@" .. format_bpm(override_bpm) end
  if ramp then canonical = canonical .. string.rep("-", ramp_bars) end

  local result={
    source = source,
    canonical = canonical,
    kind = kind,
    numerator = numerator,
    denominator = denominator,
    repeats = repeat_count,
    underlying_bpm = underlying_bpm,
    effective_bpm = effective_bpm,
    has_override = override_bpm ~= nil,
    multiplier = multiplier,
    ramp = ramp,
    ramp_bars = ramp_bars
  }
  if boot_trace then boot_trace("parse_part: return") end
  return result
end

function clone_part(part)
  local copy={}
  for key,value in pairs(part or {}) do copy[key]=value end
  return copy
end

function parse_section_bpm_cell(source)
  local text=trim(source)
  if text=="" then return nil,nil,"Section BPM is required." end
  local normalized=text:gsub("%s+"," ")
  local bpm_text=normalized:match("^(.-)%s+[Nn][Oo]%s+[Aa][Cc][Cc][Ee][Nn][Tt]$")
  local no_accent=bpm_text~=nil
  if not no_accent then bpm_text=normalized end
  local bpm,err=parse_positive_decimal(trim(bpm_text),"Section BPM")
  if not bpm then
    if upper(normalized):find("NO%s+ACCENT") then
      return nil,nil,"Use a positive decimal followed by 'no accent', for example 120 no accent."
    end
    return nil,nil,err
  end
  return bpm,no_accent
end

function parse_parts_expression(parts_text,section_bpm)
  local items,split_err=split_parts(parts_text)
  if not items then return nil,nil,split_err end
  local expanded,blocks={},{}
  for item_index,item in ipairs(items) do
    local has_angle=item:find("<",1,true)~=nil or item:find(">",1,true)~=nil
    if has_angle then
      local body,suffix=item:match("^%s*<(.*)>%s*(.-)%s*$")
      if not body then return nil,nil,string.format("Item %d ('%s'): a block must use <PART, PART, ...> followed only by optional xR.",item_index,item) end
      body,suffix=trim(body),trim(suffix)
      if body=="" then return nil,nil,string.format("Item %d ('%s'): a block must contain at least one part.",item_index,item) end
      if suffix:find("-",1,true) then return nil,nil,string.format("Item %d ('%s'): block-level ramp modifiers after > are not allowed. Put ramps on parts inside the block.",item_index,item) end
      if suffix:find("@",1,true) then return nil,nil,string.format("Item %d ('%s'): block-level @BPM overrides after > are not allowed. Put @BPM on parts inside the block.",item_index,item) end
      local block_repeats=1
      if suffix~="" then
        local repeat_text=suffix:match("^[xX](%d+)$")
        if not repeat_text then return nil,nil,string.format("Item %d ('%s'): block repeat must be xR with a positive whole number, or be omitted for one pass.",item_index,item) end
        block_repeats=tonumber(repeat_text)
        if not block_repeats or block_repeats<1 then return nil,nil,string.format("Item %d ('%s'): block repeat count must be at least 1.",item_index,item) end
      end
      local inner,inner_err=split_parts(body)
      if not inner then return nil,nil,string.format("Item %d block ('%s'): %s",item_index,item,inner_err) end
      local templates={}
      for inner_index,inner_source in ipairs(inner) do
        local part,part_err=parse_part(inner_source,section_bpm)
        if not part then return nil,nil,string.format("Item %d block, part %d ('%s'): %s",item_index,inner_index,inner_source,part_err) end
        templates[#templates+1]=part
      end
      local final_template=templates[#templates]
      if block_repeats==1 and final_template and final_template.ramp then
        return nil,nil,string.format("Item %d block ('%s'): the final internal part has a ramp, but a one-pass block has no legal next pass for that ramp. Remove the final dash or repeat the block at least twice.",item_index,item)
      end
      local expanded_count=#templates*block_repeats
      if #expanded+expanded_count>MAX_EXPANDED_BLOCK_PARTS then
        return nil,nil,string.format("Block expansion exceeds the safety limit of %d part occurrences in one PARTS cell.",MAX_EXPANDED_BLOCK_PARTS)
      end
      local canonical_parts={}
      for _,template in ipairs(templates) do canonical_parts[#canonical_parts+1]=template.canonical end
      local block_canonical="<"..table.concat(canonical_parts,", ")..">"
      if block_repeats~=1 then block_canonical=block_canonical.."x"..block_repeats end
      local block={
        item_index=item_index,source=item,canonical=block_canonical,body=body,repeat_count=block_repeats,
        part_count=#templates,expanded_count=expanded_count,block_index=#blocks+1,templates=templates
      }
      blocks[#blocks+1]=block
      for pass=1,block_repeats do
        for inner_index,template in ipairs(templates) do
          local part=clone_part(template)
          part.item_index=item_index
          part.block_index=block.block_index
          part.block_source=item
          part.block_repeat_index=pass
          part.block_repeat_total=block_repeats
          part.block_part_index=inner_index
          part.block_part_total=#templates
          part.declared_ramp=template.ramp
          part.declared_ramp_bars=template.ramp_bars
          if inner_index==#templates and pass==block_repeats and template.ramp then
            part.ramp=false
            part.ramp_bars=0
            part.ramp_suppressed=true
          end
          expanded[#expanded+1]=part
        end
      end
    else
      local part,part_err=parse_part(item,section_bpm)
      if not part then return nil,nil,string.format("part %d ('%s'): %s",item_index,item,part_err) end
      part.item_index=item_index
      expanded[#expanded+1]=part
    end
  end
  if #blocks>0 and #expanded>MAX_EXPANDED_BLOCK_PARTS then
    return nil,nil,string.format("Block expansion exceeds the safety limit of %d total expanded part occurrences in one PARTS cell.",MAX_EXPANDED_BLOCK_PARTS)
  end
  return expanded,blocks
end

function part_display_label(part)
  if part and part.block_repeat_index then
    return string.format("Block %d/%d — %s",part.block_repeat_index,part.block_repeat_total,part.canonical)
  end
  return part and part.canonical or ""
end

function find_header_candidate(sheets)
  local candidates = {}
  for sheet_index, sheet in ipairs(sheets) do
    for row = 1, sheet.max_row do
      local found, duplicates = {}, {}
      local cells = sheet.cells[row] or {}
      for col, cell in pairs(cells) do
        if cell.kind ~= "F" then
          local normalized = normalize_header(cell.value)
          if normalized == "SECTIONNAME" or normalized == "BPM" or normalized == "PARTS" then
            if found[normalized] then duplicates[normalized] = true else found[normalized] = col end
          end
        end
      end
      if found.SECTIONNAME and found.BPM and found.PARTS and not next(duplicates) then
        candidates[#candidates + 1] = {
          sheet_index = sheet_index, sheet = sheet, row = row,
          section_col = found.SECTIONNAME, bpm_col = found.BPM, parts_col = found.PARTS
        }
      end
    end
  end
  if #candidates == 0 then
    return nil, "No worksheet contains one header row with SECTION NAME, BPM, and PARTS."
  elseif #candidates > 1 then
    local locations = {}
    for _, c in ipairs(candidates) do locations[#locations + 1] = string.format("%s row %d", c.sheet.name, c.row) end
    return nil, "Multiple matching header rows were found: " .. table.concat(locations, "; ") .. "."
  end
  return candidates[1]
end

function simple_hash_text(text)
  local hash = 5381
  for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 4294967291 end
  return string.format("%08X", hash)
end

function run_powershell_text(script_text, arguments, timeout)
  if not reaper.GetOS():match("Win") then return nil, "This operation requires Windows PowerShell." end
  local ps_path = make_temp_path(".ps1")
  local out_path = make_temp_path(".txt")
  local f, err = io.open(ps_path, "wb")
  if not f then return nil, "Could not create temporary PowerShell script: " .. tostring(err) end
  f:write(script_text)
  f:close()
  local pieces = {"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File", command_quote(ps_path), "-OutputPath", command_quote(out_path)}
  for _, arg in ipairs(arguments or {}) do
    pieces[#pieces + 1] = "-" .. arg.name
    pieces[#pieces + 1] = command_quote(arg.value)
  end
  local process_output = reaper.ExecProcess(table.concat(pieces, " "), timeout or 120000)
  os.remove(ps_path)
  local out = io.open(out_path, "rb")
  if not out then return nil, "PowerShell did not create its output file. " .. trim(process_output) end
  local text = out:read("*a") or ""
  out:close(); os.remove(out_path)
  text = text:gsub("^\239\187\191", "")
  if text:sub(1, 6) == "ERROR\t" then return nil, base64_decode(text:sub(7)) end
  return trim(text)
end

local PS_SHA256 = [=[
param([string]$OutputPath,[string]$InputPath)
$ErrorActionPreference='Stop'; $e=New-Object Text.UTF8Encoding($false)
try { [IO.File]::WriteAllText($OutputPath,(Get-FileHash -LiteralPath $InputPath -Algorithm SHA256).Hash,$e) }
catch { [IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e); exit 1 }
]=]

function sha256_file(path, use_snapshot)
  local target = path
  if use_snapshot then
    local snapshot, err = create_shared_read_snapshot(path, ".hash")
    if not snapshot then return nil, err end
    target = snapshot
  end
  local result, err = run_powershell_text(PS_SHA256, {{name="InputPath", value=target}}, 120000)
  if use_snapshot then os.remove(target) end
  return result, err
end

function sha256_text(text)
  local tmp = make_temp_path(".txt")
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(text); f:close()
  local hash, hash_err = sha256_file(tmp, false)
  os.remove(tmp)
  return hash, hash_err
end

function normalized_plan_text(plan)
  local lines = {
    "START_VISIBLE_MEASURE=" .. START_VISIBLE_MEASURE,
    "COUNT_IN_MARKER=" .. COUNT_IN.name,
    "COUNT_IN_VISIBLE_MEASURE=" .. COUNT_IN.visible_measure,
    "COUNT_IN_BARS=" .. COUNT_IN.bars,
    "COUNT_IN_METER=" .. COUNT_IN.numerator .. "/" .. COUNT_IN.denominator,
    "COUNT_IN_BPM=" .. format_effective_bpm(plan.count_in_bpm or 0),
    "COUNT_IN_SOURCE_ROW=" .. tostring(plan.count_in_source_row or ""),
    "COUNT_IN_SOURCE_SECTION=" .. tostring(plan.count_in_source_section or ""),
    "FIRST_PART=" .. tostring(plan.first_part_canonical or ""),
    "FIRST_PART_UNDERLYING_BPM=" .. format_effective_bpm(plan.first_part_underlying_bpm or plan.count_in_bpm or 0),
    "FIRST_PART_EFFECTIVE_BPM=" .. format_effective_bpm(plan.first_part_effective_bpm or plan.count_in_bpm or 0),
    "SHEET=" .. tostring(plan.sheet_name or ""),
    "END_ROW=" .. tostring(plan.end_row or ""),
    "END_BPM_CELL=" .. (plan.end_bpm_entered and format_bpm(plan.end_bpm_entered) or "BLANK"),
    "END_EFFECTIVE_BPM=" .. format_effective_bpm(plan.end_effective_bpm or END_BPM)
  }
  for _, section in ipairs(plan.sections or {}) do
    lines[#lines + 1] = string.format("SECTION|%d|%s|%s|NO_ACCENT=%s", section.row, section.name, format_bpm(section.bpm),tostring(section.no_accent==true))
    for _,block in ipairs(section.blocks or {}) do
      lines[#lines+1]=table.concat({
        "BLOCK",tostring(block.block_index),block.canonical,tostring(block.repeat_count),
        tostring(block.part_count),tostring(block.expanded_count)
      },"|")
    end
    for _, part in ipairs(section.parts) do
      lines[#lines + 1] = table.concat({
        "PART", tostring(part.part_index), part.canonical,
        string.format("%d/%d", part.numerator, part.denominator),
        tostring(part.repeats), format_effective_bpm(part.underlying_bpm),
        format_effective_bpm(part.effective_bpm),
        part.ramp_suppressed and ("RAMP_SUPPRESSED:"..tostring(part.declared_ramp_bars or 0)) or (part.ramp and ("RAMP:" .. tostring(part.ramp_bars)) or "STEADY"),
        part.ramp_target_bpm and format_effective_bpm(part.ramp_target_bpm) or "",
        part.block_repeat_index and string.format("BLOCK:%d:%d/%d:%d/%d",part.block_index or 0,part.block_repeat_index,part.block_repeat_total,part.block_part_index,part.block_part_total) or "NO_BLOCK"
      }, "|")
    end
  end
  return table.concat(lines, "\n")
end

function validate_sheets(sheets, source_type)
  local header, header_err = find_header_candidate(sheets)
  if not header then return nil, {header_err} end
  local sheet = header.sheet
  local errors = {}

  if #sheet.merges > 0 then
    errors[#errors + 1] = "Worksheet '" .. sheet.name .. "' contains merged cells (for example " .. sheet.merges[1] .. "). Merged cells are not allowed."
  end
  if #sheet.formulas > 0 then
    local f = sheet.formulas[1]
    errors[#errors + 1] = string.format("Worksheet '%s' contains a formula at row %d, column %d. All cells must contain literal values.", sheet.name, f.row, f.col)
  end
  if #errors > 0 then return nil, errors end

  if source_type == "csv" and sheet.csv_row_widths then
    local header_width = sheet.csv_row_widths[header.row] or 0
    for row = header.row + 1, sheet.max_row do
      if (sheet.csv_row_widths[row] or 0) > header_width then
        errors[#errors + 1] = string.format("CSV row %d contains more fields than the header row. Quote the PARTS field when it contains commas.", row)
        break
      end
    end
  end
  if #errors > 0 then return nil, errors end

  local sections, seen_names = {}, {}
  local end_row, end_bpm_entered = nil, nil
  local row = header.row + 1
  while row <= sheet.max_row do
    local has_any = row_has_any_value(sheet, row)
    local section_name = trim(cell_value(sheet, row, header.section_col))
    local bpm_text = trim(cell_value(sheet, row, header.bpm_col))
    local parts_text = trim(cell_value(sheet, row, header.parts_col))

    if not has_any then
      errors[#errors + 1] = string.format("Row %d is blank before the required END row.", row)
      row = row + 1
    elseif normalize_name(section_name) == "END" then
      if parts_text ~= "" then errors[#errors + 1] = string.format("Row %d (END), PARTS: value must remain blank.", row) end
      if bpm_text ~= "" then
        local end_bpm, end_err = parse_positive_decimal(bpm_text, "END BPM")
        if not end_bpm then errors[#errors + 1] = string.format("Row %d, END BPM ('%s'): %s", row, bpm_text, end_err)
        else end_bpm_entered = end_bpm end
      end
      end_row = row
      break
    else
      if section_name == "" then errors[#errors + 1] = string.format("Row %d, SECTION NAME: value is required.", row) end
      if bpm_text == "" then errors[#errors + 1] = string.format("Row %d, BPM: value is required.", row) end
      if parts_text == "" then errors[#errors + 1] = string.format("Row %d, PARTS: value is required.", row) end

      local key = normalize_name(section_name)
      if key ~= "" then
        if key == normalize_name(COUNT_IN.name) then
          errors[#errors + 1] = string.format("Row %d, SECTION NAME: '%s' is reserved for the automatic COUNT IN marker at visible measure 1. Rename this spreadsheet section.", row, section_name)
        elseif seen_names[key] then
          errors[#errors + 1] = string.format("Row %d, SECTION NAME: '%s' duplicates row %d (capitalization is ignored).", row, section_name, seen_names[key])
        else
          seen_names[key] = row
        end
      end

      local section_bpm,section_no_accent
      if bpm_text ~= "" then
        local bpm,no_accent,bpm_err = parse_section_bpm_cell(bpm_text)
        if not bpm then errors[#errors + 1] = string.format("Row %d, BPM ('%s'): %s", row, bpm_text, bpm_err)
        else section_bpm,section_no_accent=bpm,no_accent end
      end

      local parsed_parts,blocks = {},{}
      if parts_text ~= "" and section_bpm then
        local parsed,parsed_blocks,parts_err=parse_parts_expression(parts_text,section_bpm)
        if not parsed then
          errors[#errors+1]=string.format("Row %d, PARTS ('%s'): %s",row,parts_text,parts_err)
        else
          parsed_parts,blocks=parsed,parsed_blocks
          for part_index,part in ipairs(parsed_parts) do
            part.row,part.part_index,part.no_accent=row,part_index,section_no_accent==true
          end
          for _,block in ipairs(blocks) do block.row=row end
        end
      end
      sections[#sections + 1] = {row=row, section_index=#sections+1, name=section_name, bpm=section_bpm, bpm_text=bpm_text, no_accent=section_no_accent==true, parts_text=parts_text, parts=parsed_parts,blocks=blocks}
      row = row + 1
    end
  end

  if not end_row then
    errors[#errors + 1] = "The final populated row must be a section named END. END PARTS must be blank; END BPM may be blank or a positive decimal."
  else
    for later = end_row + 1, sheet.max_row do
      if row_has_any_value(sheet, later) then
        errors[#errors + 1] = string.format("Row %d contains data after END. END must be the final populated row.", later)
        break
      end
    end
  end
  if #sections == 0 then errors[#errors + 1] = "At least one musical section must appear before END." end

  -- COUNT IN uses the first section BPM. The first musical part may omit @BPM
  -- or explicitly repeat that same BPM, but it may not establish a different
  -- underlying tempo at measure 3. This avoids a count-in/song-start mismatch.
  local first_section = sections[1]
  local first_part = first_section and first_section.parts and first_section.parts[1]
  if first_section and first_section.bpm and first_part and first_part.has_override
      and not nearly_equal(first_part.underlying_bpm, first_section.bpm, 1e-9) then
    errors[#errors + 1] = string.format(
      "Row %d, PARTS, part 1 ('%s'): the first musical part's @BPM override (%s) must match the first section BPM column (%s). The automatic COUNT IN uses the first section BPM, so remove the override or change it to @%s.",
      first_part.row or first_section.row, tostring(first_part.source or first_part.canonical or ""),
      format_bpm(first_part.underlying_bpm), format_bpm(first_section.bpm), format_bpm(first_section.bpm)
    )
  end

  if #errors > 0 then return nil, errors end

  local current_measure, total_bars, total_duration = START_VISIBLE_MEASURE, 0, 0
  local flat_parts,block_count,block_passes = {},0,0
  for _, section in ipairs(sections) do
    section.start_visible_measure = current_measure
    section.duration_seconds=0
    for _,block in ipairs(section.blocks or {}) do
      block.section_name=section.name
      block_count=block_count+1
      block_passes=block_passes+block.repeat_count
    end
    for _, part in ipairs(section.parts) do
      part.section_name, part.section_row = section.name, section.row
      part.start_visible_measure = current_measure
      part.next_visible_measure = current_measure + part.repeats
      flat_parts[#flat_parts + 1] = part
      current_measure = part.next_visible_measure
      total_bars = total_bars + part.repeats
    end
    section.next_visible_measure = current_measure
  end

  local final_part = flat_parts[#flat_parts]
  local end_effective_bpm = (final_part and final_part.ramp) and (end_bpm_entered or END_BPM) or END_BPM
  local ramps_present = false
  for i, part in ipairs(flat_parts) do
    if part.ramp then
      ramps_present = true
      local next_part = flat_parts[i + 1]
      part.ramp_target_bpm = next_part and next_part.effective_bpm or end_effective_bpm
      part.ramp_start_visible_measure = part.next_visible_measure - part.ramp_bars
    end
    local qn_per_bar = part.numerator * 4 / part.denominator
    local steady_bars = part.repeats - (part.ramp and part.ramp_bars or 0)
    local duration = steady_bars * qn_per_bar * 60 / part.effective_bpm
    if part.ramp then
      local average = (part.effective_bpm + part.ramp_target_bpm) / 2
      duration = duration + part.ramp_bars * qn_per_bar * 60 / average
    end
    part.duration_seconds = duration
    local duration_section=sections[1]
    for _,candidate in ipairs(sections) do
      if candidate.row==part.section_row then duration_section=candidate break end
    end
    duration_section.duration_seconds=(duration_section.duration_seconds or 0)+duration
    total_duration = total_duration + duration
  end

  local count_in_bpm = sections[1].bpm
  local count_in_duration = COUNT_IN.bars * COUNT_IN.numerator * 60 / count_in_bpm
  local first_flat_part = flat_parts[1]
  local plan = {
    sheet_name=sheet.name, sheet_index=header.sheet_index, header_row=header.row,
    section_col=header.section_col, bpm_col=header.bpm_col, parts_col=header.parts_col,
    end_row=end_row, end_bpm_text=end_bpm_entered and format_bpm(end_bpm_entered) or "",
    end_bpm_entered=end_bpm_entered, end_effective_bpm=end_effective_bpm,
    count_in_bpm=count_in_bpm, count_in_duration=count_in_duration,
    count_in_source_row=sections[1].row, count_in_source_section=sections[1].name,
    first_part_canonical=first_flat_part and first_flat_part.canonical or "",
    first_part_underlying_bpm=first_flat_part and first_flat_part.underlying_bpm or count_in_bpm,
    first_part_effective_bpm=first_flat_part and first_flat_part.effective_bpm or count_in_bpm,
    first_part_multiplier=first_flat_part and first_flat_part.multiplier or 1,
    first_part_has_override=first_flat_part and first_flat_part.has_override or false,
    sections=sections, flat_parts=flat_parts, total_bars=total_bars,
    block_count=block_count,block_passes=block_passes,
    total_duration=total_duration, total_duration_with_count_in=total_duration+count_in_duration, duration_is_approx=false,
    end_visible_measure=current_measure
  }
  plan.normalized_text = normalized_plan_text(plan)
  plan.plan_hash_short = simple_hash_text(plan.normalized_text)
  return plan
end

function validate_file(path)
  if trim(path) == "" then return nil, {"Choose an .xlsx or .csv file first."} end
  if not file_exists(path) then return nil, {"The selected file does not exist."} end
  local ext = file_extension(path)
  local sheets, fingerprint, read_err
  if ext == "xlsx" then sheets, fingerprint, read_err = parse_xlsx(path)
  elseif ext == "csv" then sheets, read_err = parse_csv(path)
  else return nil, {"Unsupported file type. Choose an .xlsx or .csv file."} end
  if not sheets then return nil, {read_err} end
  local plan, errors = validate_sheets(sheets, ext)
  if not plan then return nil, errors end
  if not fingerprint then
    fingerprint, read_err = file_fingerprint(path)
    if not fingerprint then return nil, {"Could not fingerprint the spreadsheet: " .. tostring(read_err)} end
  end
  plan.file_path, plan.file_type, plan.fingerprint = path, ext, fingerprint
  plan.source_sheets=sheets
  local source_hash, source_hash_err = sha256_file(path, ext == "xlsx")
  plan.source_sha256 = source_hash or ("UNAVAILABLE: " .. tostring(source_hash_err))
  local plan_hash, plan_hash_err = sha256_text(plan.normalized_text)
  plan.plan_sha256 = plan_hash or ("UNAVAILABLE: " .. tostring(plan_hash_err))
  return plan
end

function clone_sheet_data(sheets)
  local copies={}
  for sheet_index,sheet in ipairs(sheets or {}) do
    local copy={name=sheet.name,cells={},formulas={},merges={},max_row=sheet.max_row or 0,max_col=sheet.max_col or 0}
    if sheet.csv_row_widths then
      copy.csv_row_widths={}
      for row,width in pairs(sheet.csv_row_widths) do copy.csv_row_widths[row]=width end
    end
    for _,value in ipairs(sheet.formulas or {}) do copy.formulas[#copy.formulas+1]={row=value.row,col=value.col,formula=value.formula} end
    for _,value in ipairs(sheet.merges or {}) do copy.merges[#copy.merges+1]=value end
    for row,cells in pairs(sheet.cells or {}) do
      copy.cells[row]={}
      for col,cell in pairs(cells) do copy.cells[row][col]={value=cell.value,kind=cell.kind} end
    end
    copies[sheet_index]=copy
  end
  return copies
end

function set_sheet_cell(sheet,row,col,value)
  sheet.cells[row]=sheet.cells[row] or {}
  local text=tostring(value or "")
  if text=="" then sheet.cells[row][col]=nil
  else sheet.cells[row][col]={value=text,kind="V"} end
  sheet.max_row=math.max(sheet.max_row or 0,row)
  sheet.max_col=math.max(sheet.max_col or 0,col)
  if sheet.csv_row_widths then sheet.csv_row_widths[row]=math.max(sheet.csv_row_widths[row] or 0,col) end
end

function clone_tempo_edits(edits)
  local copy={rows={},end_bpm_set=edits and edits.end_bpm_set==true,end_bpm_text=edits and edits.end_bpm_text or ""}
  for row,entry in pairs((edits and edits.rows) or {}) do
    local part_bpms={}
    for key,value in pairs(entry.part_bpms or {}) do part_bpms[key]=value end
    copy.rows[row]={
      bpm_text=entry.bpm_text,parts_text=entry.parts_text,
      section_shift_overrides=entry.section_shift_overrides==true,
      part_bpms=part_bpms
    }
  end
  return copy
end

function tempo_edits_empty(edits)
  return not edits or (next(edits.rows or {})==nil and not edits.end_bpm_set)
end

function attach_rebuilt_plan_metadata(plan,base_plan,sheets)
  plan.file_path=base_plan.file_path
  plan.file_type=base_plan.file_type
  plan.fingerprint=base_plan.fingerprint
  plan.source_sha256=base_plan.source_sha256
  plan.source_sheets=base_plan.source_sheets
  plan.tempo_source_sheets=sheets
  local plan_hash,plan_hash_err=sha256_text(plan.normalized_text)
  plan.plan_sha256=plan_hash or ("UNAVAILABLE: "..tostring(plan_hash_err))
  return plan
end

function rebuild_plan_from_tempo_edits(base_plan,edits)
  if not base_plan or not base_plan.source_sheets then return nil,{"The original validated worksheet snapshot is unavailable."} end
  local sheets=clone_sheet_data(base_plan.source_sheets)
  local sheet=sheets[base_plan.sheet_index]
  if not sheet then return nil,{"The validated worksheet could not be reconstructed."} end
  for row,entry in pairs((edits and edits.rows) or {}) do
    if entry.bpm_text~=nil then set_sheet_cell(sheet,row,base_plan.bpm_col,entry.bpm_text) end
    if entry.parts_text~=nil then set_sheet_cell(sheet,row,base_plan.parts_col,entry.parts_text) end
  end
  if edits and edits.end_bpm_set then set_sheet_cell(sheet,base_plan.end_row,base_plan.bpm_col,edits.end_bpm_text or "") end
  local plan,errors=validate_sheets(sheets,base_plan.file_type)
  if not plan then return nil,errors end
  return attach_rebuilt_plan_metadata(plan,base_plan,sheets)
end

function dirname(path)
  return tostring(path or ""):match("^(.*)[\\/][^\\/]+$") or ""
end

function basename(path)
  return tostring(path or ""):match("([^\\/]+)$") or tostring(path or "")
end

function path_join(a, b)
  if a == "" then return b end
  local sep = reaper.GetOS():match("Win") and "\\" or "/"
  if a:sub(-1) == "\\" or a:sub(-1) == "/" then return a .. b end
  return a .. sep .. b
end

function sanitize_filename(s)
  s = tostring(s or ""):gsub('[<>:"/\\|%?%*]', "-"):gsub("%s+", "_")
  return s:gsub("_+", "_"):gsub("%-+", "-")
end

function ensure_directory(path)
  if path == "" then return false, "Folder path is empty." end
  local cmd = 'cmd.exe /C if not exist ' .. command_quote(path) .. ' mkdir ' .. command_quote(path)
  reaper.ExecProcess(cmd, 30000)
  local test = path_join(path, ".ssb_write_test_" .. tostring(math.random(100000,999999)) .. ".tmp")
  local f, err = io.open(test, "wb")
  if not f then return false, "Folder is not writable: " .. tostring(err) end
  f:write("ok"); f:close(); os.remove(test)
  return true
end

function get_active_project_info()
  local proj, path = reaper.EnumProjects(-1)
  if not proj then return nil end
  local tab_index = 0
  for i = 0, 99 do
    local p = reaper.EnumProjects(i)
    if not p then break end
    if p == proj then tab_index = i + 1; break end
  end
  return {
    proj=proj, pointer=tostring(proj), path=path or "", name=reaper.GetProjectName(proj) or basename(path or ""),
    folder=dirname(path or ""), tab_index=tab_index, state_count=reaper.GetProjectStateChangeCount(proj)
  }
end

function project_is_saved(info)
  return info and trim(info.path) ~= "" and info.path:lower():match("%.rpp$") ~= nil
end

function project_start_location(proj)
  local count_time = reaper.parse_timestr_pos(tostring(COUNT_IN.visible_measure) .. ".1.00", 2)
  local count_beat, count_measure = reaper.TimeMap2_timeToBeats(proj, count_time)
  if count_measure == nil then return nil, "Could not resolve visible measure " .. COUNT_IN.visible_measure .. "." end
  if math.abs(count_beat or 0) > 1e-5 then return nil, "Visible measure " .. COUNT_IN.visible_measure .. " did not resolve to an exact measure boundary." end

  local song_time = reaper.parse_timestr_pos(tostring(START_VISIBLE_MEASURE) .. ".1.00", 2)
  local song_beat, song_measure = reaper.TimeMap2_timeToBeats(proj, song_time)
  if song_measure == nil then return nil, "Could not resolve visible measure " .. START_VISIBLE_MEASURE .. "." end
  if math.abs(song_beat or 0) > 1e-5 then return nil, "Visible measure " .. START_VISIBLE_MEASURE .. " did not resolve to an exact measure boundary." end
  if song_measure-count_measure ~= COUNT_IN.bars then return nil, "Visible measures 1 through 3 did not resolve as exactly two count-in measures." end

  return {
    count_in={time=count_time, measure_index=count_measure},
    song={time=song_time, measure_index=song_measure}
  }
end

function delete_all_standard_markers(proj)
  local total = select(1, reaper.CountProjectMarkers(proj))
  for i = total - 1, 0, -1 do
    local ok, is_region = reaper.EnumProjectMarkers3(proj, i)
    if ok > 0 and not is_region and not reaper.DeleteProjectMarkerByIndex(proj, i) then error("Failed to delete project marker at index " .. i .. ".") end
  end
end

function delete_tempo_markers_from(proj, start_time)
  for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do
    local ok, timepos = reaper.GetTempoTimeSigMarker(proj, i)
    if ok and timepos >= start_time - EPS_TIME and not reaper.DeleteTempoTimeSigMarker(proj, i) then error("Failed to delete tempo marker at index " .. i .. ".") end
  end
end

function collect_standard_markers(proj)
  local markers = {}
  local total = select(1, reaper.CountProjectMarkers(proj))
  for i=0,total-1 do
    local ok,is_region,pos,rgnend,name = reaper.EnumProjectMarkers3(proj,i)
    if ok>0 and not is_region then markers[#markers+1]={pos=pos,name=name,index=i} end
  end
  table.sort(markers,function(a,b) if nearly_equal(a.pos,b.pos,EPS_TIME) then return a.name<b.name end return a.pos<b.pos end)
  return markers
end

function click_pattern(numerator,no_accent)
  if no_accent then return string.rep("A",numerator) end
  return "A"..string.rep("B",math.max(0,numerator-1))
end

function get_project_int_config(proj,name)
  local error_value=-2147483647
  if type(reaper.SNM_GetIntConfigVarEx)=="function" then
    local value=reaper.SNM_GetIntConfigVarEx(proj or 0,name,error_value)
    if value~=error_value then return value end
  elseif type(reaper.SNM_GetIntConfigVar)=="function" then
    local value=reaper.SNM_GetIntConfigVar(name,error_value)
    if value~=error_value then return value end
  end
  return nil
end

function set_project_int_config(proj,name,value)
  if type(reaper.SNM_SetIntConfigVarEx)=="function" then return reaper.SNM_SetIntConfigVarEx(proj or 0,name,math.floor(value+0.5))~=false end
  if type(reaper.SNM_SetIntConfigVar)=="function" then return reaper.SNM_SetIntConfigVar(name,math.floor(value+0.5))~=false end
  return false
end

function find_metronome_dialog()
  return reaper.BR_Win32_FindWindowEx("0","0","#32770","Metronome and pre-roll settings",true,true)
end

local click_frequency_session=nil
local pending_click_frequency_close=nil

function metronome_dialog_child(dialog,wanted_id)
  if not dialog then return nil end
  local child=reaper.BR_Win32_GetWindow(dialog,reaper.BR_Win32_GetConstant("GW_CHILD"))
  local next_code=reaper.BR_Win32_GetConstant("GW_HWNDNEXT")
  for _=1,256 do
    if not child then break end
    if reaper.BR_Win32_GetWindowLong(child,-12)==wanted_id then return child end
    child=reaper.BR_Win32_GetWindow(child,next_code)
  end
  return nil
end

function begin_click_frequency_session()
  if click_frequency_session then return true end
  local dialog=find_metronome_dialog()
  local opened_here=not dialog
  if opened_here then reaper.Main_OnCommand(40363,0);dialog=find_metronome_dialog() end
  if not dialog then return false,"REAPER's Metronome and pre-roll settings window did not open." end
  local field_a=metronome_dialog_child(dialog,1025)
  local field_b=metronome_dialog_child(dialog,1026)
  if not field_a or not field_b then
    if opened_here then reaper.BR_Win32_SendMessage(dialog,reaper.BR_Win32_GetConstant("WM_CLOSE"),0,0) end
    return false,"The A/B frequency fields were not found in REAPER's Metronome and pre-roll settings window."
  end
  if opened_here then reaper.BR_Win32_ShowWindow(dialog,reaper.BR_Win32_GetConstant("SW_HIDE")) end
  click_frequency_session={dialog=dialog,field_a=field_a,field_b=field_b,opened_here=opened_here}
  return true
end

function end_click_frequency_session()
  local session=click_frequency_session
  click_frequency_session=nil
  if session and session.opened_here and reaper.BR_Win32_IsWindow(session.dialog) then
    reaper.BR_Win32_ShowWindow(session.dialog,reaper.BR_Win32_GetConstant("SW_HIDE"))
    reaper.BR_Win32_SendMessage(session.dialog,reaper.BR_Win32_GetConstant("WM_CLOSE"),0,0)
    pending_click_frequency_close=session.dialog
  end
end

function service_click_frequency_cleanup()
  local dialog=pending_click_frequency_close
  if not dialog then return end
  if reaper.BR_Win32_IsWindow(dialog) then
    reaper.BR_Win32_ShowWindow(dialog,reaper.BR_Win32_GetConstant("SW_HIDE"))
    reaper.BR_Win32_SendMessage(dialog,reaper.BR_Win32_GetConstant("WM_CLOSE"),0,0)
  else pending_click_frequency_close=nil end
end

function with_metronome_frequency_fields(callback)
  local owns_session=not click_frequency_session
  if owns_session then
    local opened,open_error=begin_click_frequency_session()
    if not opened then return nil,open_error end
  end
  local session=click_frequency_session
  if not session or not reaper.BR_Win32_IsWindow(session.dialog) then
    if owns_session then end_click_frequency_session() end
    return nil,"REAPER's Metronome and pre-roll settings window closed before the frequency operation completed."
  end
  local field_a,field_b=session.field_a,session.field_b
  local ok,result_a,result_b=pcall(callback,field_a,field_b)
  if owns_session then end_click_frequency_session() end
  if not ok then return nil,tostring(result_a) end
  return result_a,result_b
end

function read_window_number(field)
  local _,text=reaper.BR_Win32_GetWindowText(field,"",128)
  return tonumber(trim(text or ""))
end

function get_click_frequencies(proj)
  local a,b_or_error=with_metronome_frequency_fields(function(field_a,field_b)
    return read_window_number(field_a),read_window_number(field_b)
  end)
  if not a or not b_or_error then return nil,nil,tostring(b_or_error or "REAPER did not return both project metronome frequencies.") end
  return a,b_or_error
end

function set_click_frequencies(a,b,proj)
  local function type_number(field,value)
    local text=tostring(math.floor(value+0.5))
    reaper.BR_Win32_SetFocus(field)
    reaper.BR_Win32_SendMessage(field,reaper.BR_Win32_GetConstant("EM_SETSEL"),0,-1)
    for i=1,#text do reaper.BR_Win32_SendMessage(field,0x0102,text:byte(i),0) end
  end
  local read_a,read_b_or_error=with_metronome_frequency_fields(function(field_a,field_b)
    type_number(field_a,a);type_number(field_b,b)
    return read_window_number(field_a),read_window_number(field_b)
  end)
  if not read_a or not read_b_or_error then return false,tostring(read_b_or_error or "REAPER did not accept both project metronome frequencies.") end
  if not nearly_equal(read_a,a,0.5) or not nearly_equal(read_b_or_error,b,0.5) then return false,string.format("REAPER returned A %.3f Hz / B %.3f Hz after the frequency update.",read_a,read_b_or_error) end
  return true
end

function metronome_enabled_state()
  local section=reaper.SectionFromUniqueID(0)
  local name=section and reaper.kbd_getTextFromCmd(ACTION_TOGGLE_METRONOME,section) or ""
  if trim(name)=="" then return nil,"REAPER's metronome toggle action is unavailable." end
  local current=reaper.GetToggleCommandStateEx(0,ACTION_TOGGLE_METRONOME)
  if current~=0 and current~=1 then return nil,"REAPER did not report a valid metronome enabled state." end
  return current
end

function set_metronome_enabled(proj,enabled)
  local wanted=enabled and 1 or 0
  local current,err=metronome_enabled_state();if current==nil then return false,err end
  if current~=wanted then reaper.Main_OnCommandEx(ACTION_TOGGLE_METRONOME,0,proj) end
  local verified,verify_err=metronome_enabled_state()
  if verified~=wanted then return false,verify_err or "REAPER did not apply the requested metronome state." end
  return true
end

function valid_click_frequency(value)
  local n=tonumber(value)
  return n and n>=20 and n<=20000 and math.floor(n+0.5)==n
end

function build_expected_map(plan, count_in_measure_index, song_start_measure_index)
  plan.count_in_internal_measure_index = count_in_measure_index
  local raw = {}
  local song_offset = song_start_measure_index-count_in_measure_index
  local measure_offset = song_offset
  local function put(offset, bpm, num, den, linear, force, label,pattern)
    raw[offset] = {offset=offset, measure_index=count_in_measure_index+offset, bpm=bpm, numerator=num, denominator=den, linear=linear or false, force=force or false, label=label,pattern=pattern or click_pattern(num,false)}
  end

  put(0, plan.count_in_bpm, COUNT_IN.numerator, COUNT_IN.denominator, false, true, COUNT_IN.name,click_pattern(COUNT_IN.numerator,false))

  local previous_part_ramped = false
  for _, section in ipairs(plan.sections) do
    section.internal_measure_index = count_in_measure_index + measure_offset
    for _, part in ipairs(section.parts) do
      part.internal_measure_index = count_in_measure_index + measure_offset
      part.ramp_internal_measure_index = part.ramp and (part.internal_measure_index + part.repeats - part.ramp_bars) or nil
      local starts_ramp = part.ramp and part.ramp_bars == part.repeats
      local force_boundary = starts_ramp or previous_part_ramped
      put(measure_offset, part.effective_bpm, part.numerator, part.denominator, starts_ramp, force_boundary, part.section_name .. " / " .. part_display_label(part),click_pattern(part.numerator,part.no_accent))
      if part.ramp and part.ramp_bars < part.repeats then
        put(measure_offset + part.repeats - part.ramp_bars, part.effective_bpm, part.numerator, part.denominator, true, true, part.section_name .. " / " .. part_display_label(part) .. " " .. part.ramp_bars .. "-bar ramp",click_pattern(part.numerator,part.no_accent))
      end
      previous_part_ramped = part.ramp
      measure_offset = measure_offset + part.repeats
    end
  end
  local end_measure_index = count_in_measure_index + measure_offset
  put(measure_offset, plan.end_effective_bpm, END_NUM, END_DEN, false, true, "END",click_pattern(END_NUM,false))

  local offsets = {}
  for offset in pairs(raw) do offsets[#offsets+1]=offset end
  table.sort(offsets)
  local expected = {}
  local bpm,num,den,pattern = nil,nil,nil,nil
  for _, offset in ipairs(offsets) do
    local e = raw[offset]
    local changed = bpm==nil or not nearly_equal(bpm,e.bpm,1e-9) or num~=e.numerator or den~=e.denominator or pattern~=e.pattern
    if changed or e.force or e.linear then expected[#expected+1]=e end
    bpm,num,den,pattern=e.bpm,e.numerator,e.denominator,e.pattern
  end
  return expected,end_measure_index
end

function serialize_expected_map(plan,count_in_measure_index,song_start_measure_index)
  local expected,end_measure_index=build_expected_map(plan,count_in_measure_index,song_start_measure_index)
  local lines={}
  for _,event in ipairs(expected) do
    lines[#lines+1]=string.format("%d|%d|%.6f|%d/%d|%s|%s|%s",event.offset,event.measure_index,event.bpm,event.numerator,event.denominator,tostring(event.linear),event.pattern or "",tostring(event.label or ""))
  end
  lines[#lines+1]="END_MEASURE|"..tostring(end_measure_index)
  return table.concat(lines,"\n")
end

function add_tempo_event(proj, e)
  local ok = reaper.SetTempoTimeSigMarker(proj,-1,-1,e.measure_index,0,e.bpm,e.numerator,e.denominator,e.linear)
  if not ok then error(string.format("REAPER rejected tempo marker at measure %d: %.2f BPM, %d/%d, linear=%s.",e.measure_index,e.bpm,e.numerator,e.denominator,tostring(e.linear))) end
  local time=select(1,reaper.TimeMap_GetMeasureInfo(proj,e.measure_index))
  local pattern_ok=reaper.TimeMap_GetMetronomePattern(proj,time,"SET:"..e.pattern)
  if not pattern_ok or pattern_ok==0 then error(string.format("REAPER rejected click pattern '%s' at measure %d.",e.pattern,e.measure_index)) end
end

function verify_build(proj, plan, locations, expected, end_measure_index,expected_click_a,expected_click_b,expected_metronome_enabled)
  local discrepancies = {}
  for offset=0,COUNT_IN.bars-1 do
    local _,_,_,cnum,cden,ctempo = reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index+offset)
    if cnum~=COUNT_IN.numerator or cden~=COUNT_IN.denominator or not nearly_equal(ctempo,plan.count_in_bpm,EPS_BPM) then
      discrepancies[#discrepancies+1]=string.format("COUNT IN bar %d: expected %.2f BPM and %d/%d, found %.6f BPM and %d/%d.",offset+1,plan.count_in_bpm,COUNT_IN.numerator,COUNT_IN.denominator,ctempo or -1,cnum or -1,cden or -1)
    end
    local ctime=select(1,reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index+offset))
    local _,cpattern=reaper.TimeMap_GetMetronomePattern(proj,ctime,"EXTENDED")
    if cpattern~=click_pattern(COUNT_IN.numerator,false) then
      discrepancies[#discrepancies+1]=string.format("COUNT IN bar %d: expected accented click pattern %s, found %s.",offset+1,click_pattern(COUNT_IN.numerator,false),tostring(cpattern))
    end
  end
  local first_part = plan.flat_parts[1]
  if first_part and first_part.internal_measure_index ~= locations.song.measure_index then
    discrepancies[#discrepancies+1]=string.format("Song-start placement: first spreadsheet part should begin at visible measure %d (internal measure %d), but its planned internal measure is %d.",START_VISIBLE_MEASURE,locations.song.measure_index,first_part.internal_measure_index or -1)
  end
  for _, part in ipairs(plan.flat_parts) do
    local _,_,_,num,den,tempo = reaper.TimeMap_GetMeasureInfo(proj,part.internal_measure_index)
    if num~=part.numerator or den~=part.denominator then discrepancies[#discrepancies+1]=string.format("%s / %s: expected %d/%d, found %d/%d.",part.section_name,part.canonical,part.numerator,part.denominator,num or -1,den or -1) end
    if not nearly_equal(tempo,part.effective_bpm,EPS_BPM) then discrepancies[#discrepancies+1]=string.format("%s / %s: expected %.2f BPM at part start, found %.6f.",part.section_name,part.canonical,part.effective_bpm,tempo or -1) end
    local ptime=select(1,reaper.TimeMap_GetMeasureInfo(proj,part.internal_measure_index))
    local _,actual_pattern=reaper.TimeMap_GetMetronomePattern(proj,ptime,"EXTENDED")
    local expected_pattern=click_pattern(part.numerator,part.no_accent)
    if actual_pattern~=expected_pattern then discrepancies[#discrepancies+1]=string.format("%s / %s: expected click pattern %s, found %s.",part.section_name,part.canonical,expected_pattern,tostring(actual_pattern)) end
    if part.ramp then
      local _,_,_,rnum,rden,rtempo = reaper.TimeMap_GetMeasureInfo(proj,part.ramp_internal_measure_index)
      if rnum~=part.numerator or rden~=part.denominator or not nearly_equal(rtempo,part.effective_bpm,EPS_BPM) then discrepancies[#discrepancies+1]=part.section_name.." / "..part.canonical..": "..part.ramp_bars.."-bar ramp start state is incorrect." end
    end
  end
  local end_time,_,_,end_num,end_den,end_tempo = reaper.TimeMap_GetMeasureInfo(proj,end_measure_index)
  if end_num~=END_NUM or end_den~=END_DEN or not nearly_equal(end_tempo,plan.end_effective_bpm,EPS_BPM) then discrepancies[#discrepancies+1]=string.format("END: expected %.2f BPM and 1/4, found %.6f BPM and %d/%d.",plan.end_effective_bpm,end_tempo or -1,end_num or -1,end_den or -1) end

  local actual = {}
  for i=0,reaper.CountTempoTimeSigMarkers(proj)-1 do
    local ok,timepos,measurepos,beatpos,bpm,num,den,linear = reaper.GetTempoTimeSigMarker(proj,i)
    if ok and timepos>=locations.count_in.time-EPS_TIME then actual[#actual+1]={measure_index=measurepos,beatpos=beatpos,bpm=bpm,numerator=num,denominator=den,linear=linear} end
  end
  for _,a in ipairs(actual) do
    if a.measure_index>locations.count_in.measure_index and a.measure_index<locations.song.measure_index then
      discrepancies[#discrepancies+1]=string.format("Unexpected tempo/time-signature marker inside the two-bar count-in at internal measure %d.",a.measure_index)
    end
  end
  if #actual~=#expected then discrepancies[#discrepancies+1]=string.format("Expected %d generated tempo markers, found %d.",#expected,#actual)
  else
    for i,e in ipairs(expected) do
      local a=actual[i]
      local etime=select(1,reaper.TimeMap_GetMeasureInfo(proj,e.measure_index))
      local _,apattern=reaper.TimeMap_GetMetronomePattern(proj,etime,"EXTENDED")
      if a.measure_index~=e.measure_index or math.abs(a.beatpos or 0)>1e-6 or a.numerator~=e.numerator or a.denominator~=e.denominator or not nearly_equal(a.bpm,e.bpm,EPS_BPM) or a.linear~=e.linear or apattern~=e.pattern then
        discrepancies[#discrepancies+1]=string.format("Tempo marker %d (%s) does not match the validated plan. Expected %.2f BPM %d/%d linear=%s pattern=%s at internal measure %d.",i,e.label,e.bpm,e.numerator,e.denominator,tostring(e.linear),e.pattern,e.measure_index)
      end
    end
  end

  local expected_markers={{name=COUNT_IN.name,pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index))}}
  for _,section in ipairs(plan.sections) do expected_markers[#expected_markers+1]={name=section.name,pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,section.internal_measure_index))} end
  expected_markers[#expected_markers+1]={name="END",pos=end_time}
  table.sort(expected_markers,function(a,b) if nearly_equal(a.pos,b.pos,EPS_TIME) then return a.name<b.name end return a.pos<b.pos end)
  local actual_markers=collect_standard_markers(proj)
  if #actual_markers~=#expected_markers then discrepancies[#discrepancies+1]=string.format("Expected %d standard markers, found %d.",#expected_markers,#actual_markers)
  else
    for i,e in ipairs(expected_markers) do local a=actual_markers[i]; if a.name~=e.name or not nearly_equal(a.pos,e.pos,1e-6) then discrepancies[#discrepancies+1]=string.format("Project marker %d mismatch: expected '%s' at %.9f; found '%s' at %.9f.",i,e.name,e.pos,a.name,a.pos) end end
  end
  if expected_click_a and expected_click_b then
    local actual_a,actual_b,freq_err=get_click_frequencies(proj)
    if not actual_a or not actual_b then discrepancies[#discrepancies+1]="Click-frequency verification failed: "..tostring(freq_err)
    else
      if not nearly_equal(actual_a,expected_click_a,0.5) then discrepancies[#discrepancies+1]=string.format("Primary A click frequency: expected %d Hz, found %.3f Hz.",expected_click_a,actual_a) end
      if not nearly_equal(actual_b,expected_click_b,0.5) then discrepancies[#discrepancies+1]=string.format("Secondary B click frequency: expected %d Hz, found %.3f Hz.",expected_click_b,actual_b) end
    end
  end
  if expected_metronome_enabled then
    local metronome_state,metronome_err=metronome_enabled_state()
    if metronome_state~=1 then discrepancies[#discrepancies+1]="REAPER metronome verification failed: "..tostring(metronome_err or "the metronome is not enabled.") end
  end
  if #discrepancies>0 then return false,table.concat(discrepancies,"\n") end
  return true,end_time
end

function compare_validated_plan_to_project(plan,proj)
  if not plan then return false,"[PRJ-007] Validate a workbook before comparing it with the open REAPER project." end
  if not proj then return false,"[PRJ-007] No active REAPER project is available." end
  local locations,location_error=project_start_location(proj)
  if not locations then return false,"[PRJ-007] "..tostring(location_error) end
  local expected,end_measure_index=build_expected_map(plan,locations.count_in.measure_index,locations.song.measure_index)
  local matches,detail=verify_build(proj,plan,locations,expected,end_measure_index,nil,nil,false)
  if not matches then return false,"[PRJ-007] "..tostring(detail) end
  return true,{
    locations=locations,expected=expected,end_measure_index=end_measure_index,
    section_count=#(plan.sections or {}),part_count=#(plan.flat_parts or {}),
    marker_count=#(plan.sections or {})+2,tempo_event_count=#expected
  }
end

function reconstruction_sheet(rows)
  local sheet={name="REAPER Song Sections",cells={},formulas={},merges={},max_row=#rows,max_col=3,csv_row_widths={}}
  for row_index,row in ipairs(rows or {}) do
    sheet.cells[row_index]={}
    sheet.csv_row_widths[row_index]=3
    for column=1,3 do
      local value=tostring(row[column] or "")
      if value~="" then sheet.cells[row_index][column]={value=value,kind=(column==2 and row_index>1 and value:match("^%d+%.?%d*$")) and "N" or "S"} end
    end
  end
  return {sheet}
end

function reconstruction_ratio_kind(effective_bpm,section_bpm,denominator)
  if denominator==8 then return "eighth",1 end
  if denominator==16 then return "sixteenth",1 end
  if denominator==32 then return "thirty_second",1 end
  if denominator~=4 then return nil,nil end
  local ratio=effective_bpm/section_bpm
  local kinds={{1,"quarter"},{1.5,"eighth_triplet"},{3,"sextuplet"},{5,"quintuplet"},{7,"septuplet"}}
  for _,candidate in ipairs(kinds) do if nearly_equal(ratio,candidate[1],1e-8) then return candidate[2],candidate[1] end end
  return "quarter_override",1
end

function choose_reconstruction_section_bpm(pieces,fixed_bpm)
  if fixed_bpm then return round_hundredth(fixed_bpm) end
  local candidates={}
  local function add(value)
    value=round_hundredth(value)
    if value<=0 then return end
    for _,existing in ipairs(candidates) do if nearly_equal(existing,value,1e-8) then return end end
    candidates[#candidates+1]=value
  end
  for _,piece in ipairs(pieces or {}) do
    if piece.denominator==4 then
      for _,multiplier in ipairs({1,1.5,3,5,7}) do add(piece.bpm/multiplier) end
    else add(piece.bpm) end
  end
  table.sort(candidates)
  local best,best_score
  for _,candidate in ipairs(candidates) do
    local score=0
    for _,piece in ipairs(pieces or {}) do
      local kind,multiplier=reconstruction_ratio_kind(piece.bpm,candidate,piece.denominator)
      local bars=math.max(1,piece.repeats or 1)
      if not kind then score=score+100000*bars
      elseif kind=="quarter_override" or (multiplier==1 and not nearly_equal(piece.bpm,candidate,1e-8)) then score=score+100*bars
      elseif multiplier~=1 then score=score+bars end
    end
    if not best_score or score<best_score-1e-9 or (nearly_equal(score,best_score,1e-9) and candidate<best) then best,best_score=candidate,score end
  end
  return best,best_score
end

function reconstruction_part_token(piece,section_bpm)
  local kind,multiplier=reconstruction_ratio_kind(piece.bpm,section_bpm,piece.denominator)
  if not kind then return nil,string.format("[RCN-006] Meter %d/%d is not representable by Bildibeat syntax.",piece.numerator,piece.denominator) end
  local n=tostring(piece.numerator)
  local token
  if kind=="quarter" then token="["..n.."]"
  elseif kind=="eighth" then token="("..n..")"
  elseif kind=="sixteenth" then token="{"..n.."}"
  elseif kind=="thirty_second" then token="*"..n.."*"
  elseif kind=="eighth_triplet" then token="ENT("..n..")"
  elseif kind=="sextuplet" then token="SXT{"..n.."}"
  elseif kind=="quintuplet" then token="QNT{"..n.."}"
  elseif kind=="septuplet" then token="SPT{"..n.."}"
  else
    token="["..n.."]@"..format_bpm(piece.bpm)
  end
  if multiplier==1 and kind~="quarter_override" and not nearly_equal(piece.bpm,section_bpm,1e-8) then token=token.."@"..format_bpm(piece.bpm) end
  local repeats=math.max(1,math.floor(piece.repeats or 1))
  if repeats~=1 then token=token.."x"..repeats end
  if piece.linear then token=token..string.rep("-",repeats) end
  return token
end

function compress_reconstruction_blocks(tokens,pieces)
  local output={}
  local index=1
  while index<=#tokens do
    local best_length,best_repeats,best_saving=nil,nil,0
    local remaining=#tokens-index+1
    for length=2,math.floor(remaining/2) do
      local ramp_free=true
      for offset=0,length-1 do if pieces[index+offset] and pieces[index+offset].linear then ramp_free=false break end end
      if ramp_free then
        local repeats=1
        while index+(repeats+1)*length-1<=#tokens do
          local same=true
          for offset=0,length-1 do if tokens[index+offset]~=tokens[index+repeats*length+offset] then same=false break end end
          if not same then break end
          repeats=repeats+1
        end
        if repeats>=2 then
          local raw_length=0
          for pass=1,repeats do for offset=0,length-1 do raw_length=raw_length+#tokens[index+offset]+2 end end
          local block_length=4+#tostring(repeats)
          for offset=0,length-1 do block_length=block_length+#tokens[index+offset]+2 end
          local saving=raw_length-block_length
          if saving>best_saving then best_length,best_repeats,best_saving=length,repeats,saving end
        end
      end
    end
    if best_length then
      local inside={}
      for offset=0,best_length-1 do inside[#inside+1]=tokens[index+offset] end
      output[#output+1]="<"..table.concat(inside,", ")..">x"..best_repeats
      index=index+best_length*best_repeats
    else output[#output+1]=tokens[index];index=index+1 end
  end
  return output
end

function project_measure_boundary(proj,time,label)
  local beat,measure=reaper.TimeMap2_timeToBeats(proj,time)
  if measure==nil or math.abs(beat or 0)>1e-6 then return nil,string.format("[RCN-002] %s at %.9f seconds is not on an exact measure boundary.",label,time) end
  return math.floor(measure+0.5)
end

function collect_reconstruction_project_model(proj)
  local locations,location_error=project_start_location(proj)
  if not locations then return nil,"[RCN-001] "..tostring(location_error) end
  local markers=collect_standard_markers(proj)
  local count_marker,end_marker,section_markers=nil,nil,{}
  local seen_names={}
  for _,marker in ipairs(markers) do
    local measure,measure_error=project_measure_boundary(proj,marker.pos,"Marker '"..tostring(marker.name).."'")
    if not measure then return nil,measure_error end
    marker.measure_index=measure
    if marker.name=="COUNT IN" then
      if count_marker then return nil,"[RCN-003] More than one standard marker is named COUNT IN." end
      count_marker=marker
    elseif marker.name=="END" then
      if end_marker then return nil,"[RCN-003] More than one standard marker is named END." end
      end_marker=marker
    else
      if trim(marker.name)=="" or trim(marker.name)~=marker.name then return nil,"[RCN-003] Every Section marker needs a nonblank name without leading or trailing spaces." end
      local key=normalize_name(marker.name)
      if seen_names[key] then return nil,string.format("[RCN-003] Section marker '%s' duplicates another marker name when capitalization is ignored.",marker.name) end
      seen_names[key]=true
      section_markers[#section_markers+1]=marker
    end
  end
  if not count_marker or count_marker.measure_index~=locations.count_in.measure_index or not nearly_equal(count_marker.pos,locations.count_in.time,1e-6) then return nil,"[RCN-001] A standard marker named COUNT IN must be on visible measure 1." end
  if not end_marker then return nil,"[RCN-001] A standard marker named END is required at the exact song boundary." end
  if end_marker.measure_index<=locations.song.measure_index then return nil,"[RCN-001] END must occur after at least one musical bar." end
  table.sort(section_markers,function(a,b)return a.measure_index<b.measure_index end)
  if #section_markers==0 or section_markers[1].measure_index~=locations.song.measure_index then return nil,"[RCN-003] The first Section marker must begin at visible measure 3." end
  for index,marker in ipairs(section_markers) do
    if marker.measure_index>=end_marker.measure_index then return nil,string.format("[RCN-003] Section marker '%s' must occur before END.",marker.name) end
    if index>1 and marker.measure_index==section_markers[index-1].measure_index then return nil,"[RCN-003] Two Section markers share one measure boundary; one workbook row cannot preserve both." end
  end
  if #markers~=#section_markers+2 then return nil,"[RCN-003] Standard markers outside COUNT IN, Sections, and END cannot be represented without changing the project map." end

  local tempo_events,event_by_measure={},{}
  for index=0,reaper.CountTempoTimeSigMarkers(proj)-1 do
    local ok,timepos,measurepos,beatpos,bpm,num,den,linear=reaper.GetTempoTimeSigMarker(proj,index)
    if ok and timepos>=locations.count_in.time-EPS_TIME then
      if math.abs(beatpos or 0)>1e-6 or not nearly_equal(measurepos,math.floor(measurepos+0.5),1e-6) then return nil,string.format("[RCN-004] Tempo/time-signature marker %d is not on an exact measure boundary.",index+1) end
      local measure=math.floor(measurepos+0.5)
      if measure>end_marker.measure_index then return nil,"[RCN-004] Tempo/time-signature markers after END prevent a one-for-one workbook reconstruction." end
      if event_by_measure[measure] then return nil,string.format("[RCN-004] Multiple tempo/time-signature markers occur at internal measure %d.",measure) end
      local _,pattern=reaper.TimeMap_GetMetronomePattern(proj,timepos,"EXTENDED")
      local event={time=timepos,measure_index=measure,bpm=bpm,numerator=num,denominator=den,linear=linear==true,pattern=pattern}
      tempo_events[#tempo_events+1]=event;event_by_measure[measure]=event
    end
  end
  table.sort(tempo_events,function(a,b)return a.measure_index<b.measure_index end)
  if #tempo_events==0 or tempo_events[1].measure_index~=locations.count_in.measure_index then return nil,"[RCN-004] The project needs an explicit tempo/time-signature marker at COUNT IN." end
  local _,_,_,count_num,count_den,count_bpm=reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index)
  for offset=0,COUNT_IN.bars-1 do
    local time,_,_,num,den,bpm=reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index+offset)
    local _,pattern=reaper.TimeMap_GetMetronomePattern(proj,time,"EXTENDED")
    if num~=4 or den~=4 or not nearly_equal(bpm,count_bpm,EPS_BPM) or pattern~=click_pattern(4,false) then return nil,"[RCN-001] COUNT IN must be exactly two accented bars of 4/4 at one BPM." end
  end
  if count_num~=4 or count_den~=4 then return nil,"[RCN-001] COUNT IN must use 4/4." end
  local _,_,_,end_num,end_den,end_bpm=reaper.TimeMap_GetMeasureInfo(proj,end_marker.measure_index)
  if end_num~=END_NUM or end_den~=END_DEN then return nil,"[RCN-005] END must be an explicit 1/4 tempo/time-signature boundary." end

  local sections={}
  for section_index,marker in ipairs(section_markers) do
    local section_end=(section_markers[section_index+1] and section_markers[section_index+1].measure_index) or end_marker.measure_index
    local boundaries={marker.measure_index,section_end}
    for _,event in ipairs(tempo_events) do if event.measure_index>marker.measure_index and event.measure_index<section_end then boundaries[#boundaries+1]=event.measure_index end end
    table.sort(boundaries)
    local pieces={}
    for boundary_index=1,#boundaries-1 do
      local start_measure,finish_measure=boundaries[boundary_index],boundaries[boundary_index+1]
      local start_time,_,_,num,den,bpm=reaper.TimeMap_GetMeasureInfo(proj,start_measure)
      local _,pattern=reaper.TimeMap_GetMetronomePattern(proj,start_time,"EXTENDED")
      local event=event_by_measure[start_measure]
      local linear=event and event.linear or false
      if linear then
        local next_event_measure=nil
        for _,candidate in ipairs(tempo_events) do if candidate.measure_index>start_measure then next_event_measure=candidate.measure_index break end end
        if next_event_measure~=finish_measure then return nil,string.format("[RCN-005] A linear ramp beginning at visible measure %d crosses a Section boundary or lacks an exact target marker.",START_VISIBLE_MEASURE+(start_measure-locations.song.measure_index)) end
      end
      for measure=start_measure,finish_measure-1 do
        local bar_time,_,_,bar_num,bar_den,bar_bpm=reaper.TimeMap_GetMeasureInfo(proj,measure)
        local _,bar_pattern=reaper.TimeMap_GetMetronomePattern(proj,bar_time,"EXTENDED")
        if bar_num~=num or bar_den~=den or bar_pattern~=pattern then return nil,string.format("[RCN-004] Meter or click pattern changes inside an interval without an explicit boundary at visible measure %d.",START_VISIBLE_MEASURE+(measure-locations.song.measure_index)) end
        if not linear and not nearly_equal(bar_bpm,bpm,EPS_BPM) then return nil,string.format("[RCN-004] Tempo changes inside an interval without an explicit ramp marker at visible measure %d.",START_VISIBLE_MEASURE+(measure-locations.song.measure_index)) end
      end
      pieces[#pieces+1]={start_measure=start_measure,end_measure=finish_measure,repeats=finish_measure-start_measure,numerator=num,denominator=den,bpm=round_hundredth(bpm),pattern=pattern,linear=linear}
    end
    local no_accent=false
    for _,piece in ipairs(pieces) do
      local normal=click_pattern(piece.numerator,false);local flat=click_pattern(piece.numerator,true)
      if piece.pattern~=normal and piece.pattern~=flat then return nil,string.format("[RCN-007] Section '%s' uses a click pattern that is neither the normal accented pattern nor no-accent all-A.",marker.name) end
      if piece.numerator>1 and piece.pattern==flat then no_accent=true end
    end
    for _,piece in ipairs(pieces) do
      if piece.pattern~=click_pattern(piece.numerator,no_accent) then return nil,string.format("[RCN-007] Section '%s' mixes accented and no-accent click patterns; the workbook BPM cell can represent only one Section-wide choice.",marker.name) end
    end
    local section_bpm=choose_reconstruction_section_bpm(pieces,section_index==1 and count_bpm or nil)
    sections[#sections+1]={name=marker.name,bpm=section_bpm,no_accent=no_accent,pieces=pieces}
  end
  return {locations=locations,markers=markers,tempo_events=tempo_events,event_by_measure=event_by_measure,sections=sections,end_marker=end_marker,end_bpm=round_hundredth(end_bpm),count_in_bpm=round_hundredth(count_bpm)}
end

function reconstruction_rows_for_model(model,use_blocks)
  local rows={{"SECTION NAME","BPM","PARTS"}}
  local block_count=0
  for _,section in ipairs(model.sections or {}) do
    local tokens={}
    for _,piece in ipairs(section.pieces) do
      local token,token_error=reconstruction_part_token(piece,section.bpm)
      if not token then return nil,token_error end
      tokens[#tokens+1]=token
    end
    local encoded=use_blocks and compress_reconstruction_blocks(tokens,section.pieces) or tokens
    for _,token in ipairs(encoded) do if token:sub(1,1)=="<" then block_count=block_count+1 end end
    rows[#rows+1]={section.name,format_bpm(section.bpm)..(section.no_accent and " no accent" or ""),table.concat(encoded,", ")}
  end
  local final_section=model.sections[#model.sections];local final_piece=final_section and final_section.pieces[#final_section.pieces]
  rows[#rows+1]={"END",(final_piece and final_piece.linear) and format_bpm(model.end_bpm) or "",""}
  return rows,block_count
end

function reconstruct_workbook_plan_from_project(proj)
  local model,model_error=collect_reconstruction_project_model(proj)
  if not model then return nil,model_error end
  local failures={}
  for _,use_blocks in ipairs({true,false}) do
    local rows,block_count_or_error=reconstruction_rows_for_model(model,use_blocks)
    if rows then
      local plan,validation_errors=validate_sheets(reconstruction_sheet(rows),"xlsx")
      if plan then
        local matched,match_result=compare_validated_plan_to_project(plan,proj)
        if matched then
          return {model=model,rows=rows,plan=plan,block_count=block_count_or_error or 0,used_blocks=use_blocks,verification=match_result}
        end
        failures[#failures+1]=tostring(match_result)
      else failures[#failures+1]=table.concat(validation_errors or {"Unknown generated-workbook validation error."},"\n") end
    else failures[#failures+1]=tostring(block_count_or_error) end
  end
  return nil,"[RCN-008] The project could not be reduced to workbook syntax without changing its musical map.\n\n"..table.concat(failures,"\n\n")
end

function project_comparison_available()
  if not state.plan then return false,"Validate a workbook successfully before comparing it with the open REAPER project." end
  if state.preview_stale then return false,"The workbook changed after validation; run Validate Only again before comparing." end
  if state.operation_busy then return false,"Wait for the current workbook, export, logging, or build operation to finish." end
  local active=get_active_project_info()
  if not active or not active.proj then return false,"Open a REAPER project before comparing it with the validated workbook." end
  return true
end

function validate_against_open_project()
  local available,reason=project_comparison_available()
  if not available then show_info("Open Project Comparison Unavailable","[PRJ-007] "..tostring(reason),"warning");return end
  mark_file_stale_if_changed()
  if state.preview_stale then show_info("Open Project Comparison Unavailable","[PRJ-007] The workbook changed after validation. Run Validate Only again before comparing.","warning");return end
  local active=get_active_project_info()
  state.operation_busy=true
  set_status("Comparing the validated workbook with the open REAPER project...","info")
  local call_ok,matches,result=xpcall(function()
    local is_match,comparison=compare_validated_plan_to_project(state.plan,active and active.proj)
    return is_match,comparison
  end,debug.traceback)
  state.operation_busy=false
  if not call_ok then
    state.last_verified_project_match=nil
    set_status("Open-project comparison failed.","error")
    show_info("Open Project Comparison Failed","[PRJ-007] "..tostring(matches),"error")
    return
  end
  local project_name=trim(active and active.name or "")~="" and active.name or "Untitled REAPER Project"
  if matches then
    state.last_verified_project_match={
      project_pointer=active.pointer,
      plan_sha256=state.plan.plan_sha256,
      project_signature=transaction_project_signature(active.proj)
    }
    state.validation_project=active
    state.project_changed=false
    set_status("Validated workbook and open REAPER project are an exact structural match.","success")
    show_info(
      "Open Project — Exact Match",
      "The validated workbook and active REAPER project match exactly.\n\nProject: "..project_name..
      "\nSections: "..tostring(result.section_count)..
      "\nExpanded Parts: "..tostring(result.part_count)..
      "\nStandard markers: "..tostring(result.marker_count)..
      "\nTempo/meter events: "..tostring(result.tempo_event_count)..
      "\nEND: visible measure "..tostring(state.plan.end_visible_measure)..
      "\n\nChecked: COUNT IN, Section marker names/order/positions, every expanded Part start, meter, calculated REAPER BPM, click accents, Ramp boundaries and linear states, END, and unexpected extra standard or tempo markers.\n\nPreview-row Play, Stop, Loop, and 50% Speed are now available for this exact matched structure without rebuilding it.\n\nNo project, workbook, media, transport, or save state was changed.",
      "success"
    )
  else
    state.last_verified_project_match=nil
    set_status("Validated workbook and open REAPER project do not match.","warning")
    show_info(
      "Open Project — Differences Found",
      "The active REAPER project does not exactly match the currently validated workbook.\n\nProject: "..project_name..
      "\n\nMISMATCHES\n"..tostring(result)..
      "\n\nThis comparison was read-only. No project, workbook, media, transport, or save state was changed.",
      "warning"
    )
  end
end

function format_comparison_position(visible_measure, beatpos, seconds)
  local beat = (beatpos or 0) + 1
  if math.abs((beatpos or 0)) < 1e-6 then
    return string.format("visible measure %d (%.6f seconds)", visible_measure, seconds or 0)
  end
  return string.format("visible measure %d beat %.3f (%.6f seconds)", visible_measure, beat, seconds or 0)
end

function tempo_description(e)
  return string.format("%.2f BPM %d/%d linear=%s pattern=%s", e.bpm, e.numerator, e.denominator, tostring(e.linear),tostring(e.pattern or "inherited"))
end

function comparison_coordinate_key(measure_index, beatpos)
  return tostring(measure_index) .. "|" .. string.format("%.6f", beatpos or 0)
end

function build_net_result(snapshot)
  local marker_lines, tempo_lines = {}, {}
  local marker_counts = {unchanged=0, changed=0, added=0, removed=0}
  local tempo_counts = {unchanged=0, changed=0, added=0, removed=0}

  local planned_by_coord = {}
  for _,p in ipairs(snapshot.planned_marker_objects or {}) do
    local key=comparison_coordinate_key(p.measure_index,p.beatpos)
    planned_by_coord[key]=planned_by_coord[key] or {}
    planned_by_coord[key][#planned_by_coord[key]+1]=p
  end
  local used_planned={}
  for _,e in ipairs(snapshot.existing_marker_objects or {}) do
    local key=comparison_coordinate_key(e.measure_index,e.beatpos)
    local candidates=planned_by_coord[key] or {}
    local same_index=nil
    for i,p in ipairs(candidates) do
      if not used_planned[p] and p.name==e.name then same_index=i;break end
    end
    if same_index then
      local p=candidates[same_index];used_planned[p]=true;marker_counts.unchanged=marker_counts.unchanged+1
      marker_lines[#marker_lines+1]="UNCHANGED: '"..e.name.."' at "..e.position_label
    else
      local replacement=nil
      for _,p in ipairs(candidates) do if not used_planned[p] then replacement=p;break end end
      if replacement then
        used_planned[replacement]=true;marker_counts.changed=marker_counts.changed+1
        marker_lines[#marker_lines+1]="CHANGED: '"..e.name.."' -> '"..replacement.name.."' at "..e.position_label
      else
        marker_counts.removed=marker_counts.removed+1
        marker_lines[#marker_lines+1]="REMOVED: '"..e.name.."' at "..e.position_label
      end
    end
  end
  for _,p in ipairs(snapshot.planned_marker_objects or {}) do
    if not used_planned[p] then
      marker_counts.added=marker_counts.added+1
      marker_lines[#marker_lines+1]="ADDED: '"..p.name.."' at "..p.position_label
    end
  end

  local planned_tempo_by_coord={}
  for _,p in ipairs(snapshot.planned_tempo_objects or {}) do
    local key=comparison_coordinate_key(p.measure_index,p.beatpos)
    planned_tempo_by_coord[key]=planned_tempo_by_coord[key] or {}
    planned_tempo_by_coord[key][#planned_tempo_by_coord[key]+1]=p
  end
  local used_tempo={}
  for _,e in ipairs(snapshot.existing_tempo_objects or {}) do
    local key=comparison_coordinate_key(e.measure_index,e.beatpos)
    local candidates=planned_tempo_by_coord[key] or {}
    local exact=nil
    for _,p in ipairs(candidates) do
      if not used_tempo[p] and nearly_equal(e.bpm,p.bpm,EPS_BPM) and e.numerator==p.numerator and e.denominator==p.denominator and e.linear==p.linear and e.pattern==p.pattern then exact=p;break end
    end
    if exact then
      used_tempo[exact]=true;tempo_counts.unchanged=tempo_counts.unchanged+1
      tempo_lines[#tempo_lines+1]="UNCHANGED: "..tempo_description(e).." at "..e.position_label
    else
      local replacement=nil
      for _,p in ipairs(candidates) do if not used_tempo[p] then replacement=p;break end end
      if replacement then
        used_tempo[replacement]=true;tempo_counts.changed=tempo_counts.changed+1
        tempo_lines[#tempo_lines+1]="CHANGED: "..tempo_description(e).." -> "..tempo_description(replacement).." at "..e.position_label
      else
        tempo_counts.removed=tempo_counts.removed+1
        tempo_lines[#tempo_lines+1]="REMOVED: "..tempo_description(e).." at "..e.position_label
      end
    end
  end
  for _,p in ipairs(snapshot.planned_tempo_objects or {}) do
    if not used_tempo[p] then
      tempo_counts.added=tempo_counts.added+1
      tempo_lines[#tempo_lines+1]="ADDED: "..tempo_description(p).." at "..p.position_label.." ("..p.label..")"
    end
  end
  snapshot.net_marker_lines=marker_lines
  snapshot.net_tempo_lines=tempo_lines
  snapshot.net_marker_counts=marker_counts
  snapshot.net_tempo_counts=tempo_counts
end

function collect_project_snapshot(proj, plan)
  local locations,start_err=project_start_location(proj)
  if not locations then return nil,start_err end
  local start=locations.song
  local total,markers,regions=reaper.CountProjectMarkers(proj)
  local existing_marker_details={}
  local existing_marker_objects={}
  for _,m in ipairs(collect_standard_markers(proj)) do
    local beat,measure_index=reaper.TimeMap2_timeToBeats(proj,m.pos)
    local visible_measure=START_VISIBLE_MEASURE+(measure_index-start.measure_index)
    local obj={name=m.name~="" and m.name or "(unnamed)",pos=m.pos,measure_index=measure_index,beatpos=beat or 0,visible_measure=visible_measure}
    obj.position_label=format_comparison_position(visible_measure,obj.beatpos,m.pos)
    existing_marker_objects[#existing_marker_objects+1]=obj
    existing_marker_details[#existing_marker_details+1]=string.format("%s at %s",obj.name,obj.position_label)
  end
  local tempo_from=0
  local existing_tempo_details={}
  local existing_tempo_objects={}
  for i=0,reaper.CountTempoTimeSigMarkers(proj)-1 do
    local ok,t,measurepos,beatpos,tbpm,tnum,tden,linear=reaper.GetTempoTimeSigMarker(proj,i)
    if ok and t>=locations.count_in.time-EPS_TIME then
      tempo_from=tempo_from+1
      local visible_measure=START_VISIBLE_MEASURE+(measurepos-start.measure_index)
      local _,pattern=reaper.TimeMap_GetMetronomePattern(proj,t,"EXTENDED")
      local obj={time=t,measure_index=measurepos,beatpos=beatpos or 0,bpm=tbpm,numerator=tnum,denominator=tden,linear=linear,pattern=pattern,visible_measure=visible_measure}
      obj.position_label=format_comparison_position(visible_measure,obj.beatpos,t)
      existing_tempo_objects[#existing_tempo_objects+1]=obj
      existing_tempo_details[#existing_tempo_details+1]=tempo_description(obj).." at "..obj.position_label
    end
  end
  local expected,end_idx=build_expected_map(plan,locations.count_in.measure_index,locations.song.measure_index)
  local new_marker_details={}
  local planned_marker_objects={}
  local section_range_details={}
  local part_range_details={}
  local count_pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index))
  local count_obj={name=COUNT_IN.name,measure_index=locations.count_in.measure_index,beatpos=0,visible_measure=COUNT_IN.visible_measure,pos=count_pos}
  count_obj.position_label=format_comparison_position(COUNT_IN.visible_measure,0,count_pos)
  planned_marker_objects[#planned_marker_objects+1]=count_obj
  new_marker_details[#new_marker_details+1]=string.format("%s at visible measure %d",COUNT_IN.name,COUNT_IN.visible_measure)
  for _,section in ipairs(plan.sections) do
    local measure_index=start.measure_index+(section.start_visible_measure-START_VISIBLE_MEASURE)
    local pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,measure_index))
    local obj={name=section.name,measure_index=measure_index,beatpos=0,visible_measure=section.start_visible_measure,pos=pos}
    obj.position_label=format_comparison_position(obj.visible_measure,0,pos)
    planned_marker_objects[#planned_marker_objects+1]=obj
    new_marker_details[#new_marker_details+1]=string.format("%s at visible measure %d",section.name,section.start_visible_measure)
    section_range_details[#section_range_details+1]=string.format("%s (spreadsheet row %d): visible measures %d-%d",section.name,section.row,section.start_visible_measure,math.max(section.start_visible_measure,section.next_visible_measure-1))
    for _,part in ipairs(section.parts or {}) do
      local ramp_detail=""
      if part.ramp_suppressed then ramp_detail="; declared internal ramp inactive at final block boundary"
      elseif part.ramp then ramp_detail="; ramp begins at "..part.ramp_start_visible_measure.." toward "..format_effective_bpm(part.ramp_target_bpm).." BPM" end
      part_range_details[#part_range_details+1]=string.format("Row %d / %s / %s: visible measures %d-%d; %s; %.2f effective BPM%s",section.row,section.name,part_display_label(part),part.start_visible_measure,math.max(part.start_visible_measure,part.next_visible_measure-1),string.format("%d/%d",part.numerator,part.denominator),part.effective_bpm,ramp_detail)
    end
  end
  local end_pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,end_idx))
  local end_obj={name="END",measure_index=end_idx,beatpos=0,visible_measure=plan.end_visible_measure,pos=end_pos}
  end_obj.position_label=format_comparison_position(end_obj.visible_measure,0,end_pos)
  planned_marker_objects[#planned_marker_objects+1]=end_obj
  new_marker_details[#new_marker_details+1]=string.format("END at visible measure %d",plan.end_visible_measure)

  local new_tempo_details={}
  local planned_tempo_objects={}
  for _,e in ipairs(expected) do
    local visible_measure=COUNT_IN.visible_measure+e.offset
    local pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,e.measure_index))
    local obj={measure_index=e.measure_index,beatpos=0,bpm=e.bpm,numerator=e.numerator,denominator=e.denominator,linear=e.linear,pattern=e.pattern,label=e.label,visible_measure=visible_measure,pos=pos}
    obj.position_label=format_comparison_position(visible_measure,0,pos)
    planned_tempo_objects[#planned_tempo_objects+1]=obj
    new_tempo_details[#new_tempo_details+1]=string.format("Visible measure %d: %.2f BPM %d/%d linear=%s pattern=%s (%s)",visible_measure,e.bpm,e.numerator,e.denominator,tostring(e.linear),e.pattern,e.label)
  end
  local snapshot={
    markers_to_delete=markers or 0, regions_preserved=regions or 0,
    tempo_total=reaper.CountTempoTimeSigMarkers(proj), tempo_to_delete=tempo_from,
    tracks=reaper.CountTracks(proj), media_items=reaper.CountMediaItems(proj),
    new_markers=#plan.sections+2,new_tempo=#expected,end_internal_measure=end_idx,
    expected_events=expected,start=start,count_in=locations.count_in,project_length=reaper.GetProjectLength(proj),
    existing_marker_details=existing_marker_details,existing_tempo_details=existing_tempo_details,
    new_marker_details=new_marker_details,new_tempo_details=new_tempo_details,
    existing_marker_objects=existing_marker_objects,existing_tempo_objects=existing_tempo_objects,
    planned_marker_objects=planned_marker_objects,planned_tempo_objects=planned_tempo_objects,
    section_range_details=section_range_details,part_range_details=part_range_details,
    plan_count_in_bpm=plan.count_in_bpm,
    count_in_source_row=plan.count_in_source_row,count_in_source_section=plan.count_in_source_section,
    first_part_canonical=plan.first_part_canonical,first_part_underlying_bpm=plan.first_part_underlying_bpm,
    first_part_effective_bpm=plan.first_part_effective_bpm,
    total_duration=plan.total_duration,total_duration_with_count_in=plan.total_duration_with_count_in,
    click_a_hz=state and state.click_a_hz or DEFAULT_CLICK_A_HZ,click_b_hz=state and state.click_b_hz or DEFAULT_CLICK_B_HZ
  }
  build_net_result(snapshot)
  return snapshot
end

AUDIO_MODE_PRESERVE="PRESERVE"
AUDIO_MODE_CONFORM="CONFORM"
AUDIO_ITEM_FIELDS={"D_POSITION","D_LENGTH","D_SNAPOFFSET","D_FADEINLEN","D_FADEOUTLEN","D_FADEINDIR","D_FADEOUTDIR","C_BEATATTACHMODE","C_AUTOSTRETCH","C_LOCK"}
AUDIO_TAKE_FIELDS={"D_STARTOFFS","D_PLAYRATE","D_PITCH","B_PPITCH","I_PITCHMODE"}

function media_item_guid(item)
  if type(reaper.GetSetMediaItemInfo_String)=="function" then
    local ok,value=reaper.GetSetMediaItemInfo_String(item,"GUID","",false)
    if ok and trim(value)~="" then return value end
  end
  return tostring(item)
end

function capture_take_audio_state(take,take_index)
  local values={}
  for _,field in ipairs(AUDIO_TAKE_FIELDS) do values[field]=reaper.GetMediaItemTakeInfo_Value(take,field) end
  local stretch={}
  if type(reaper.GetTakeNumStretchMarkers)=="function" and type(reaper.GetTakeStretchMarker)=="function" then
    for marker_index=0,reaper.GetTakeNumStretchMarkers(take)-1 do
      local returned,pos,source_pos=reaper.GetTakeStretchMarker(take,marker_index)
      if type(returned)=="number" and returned>=0 then
        stretch[#stretch+1]={pos=pos,source_pos=source_pos,slope=type(reaper.GetTakeStretchMarkerSlope)=="function" and reaper.GetTakeStretchMarkerSlope(take,marker_index) or 0}
      end
    end
  end
  return {pointer=take,index=take_index,is_midi=reaper.TakeIsMIDI(take)==true,values=values,stretch=stretch}
end

function capture_audio_project_state(proj)
  local snapshot={items={},audio_items=0,midi_only_items=0,mixed_items=0,audio_takes=0}
  for item_index=0,reaper.CountMediaItems(proj)-1 do
    local item=reaper.GetMediaItem(proj,item_index)
    local item_state={pointer=item,index=item_index,guid=media_item_guid(item),values={},takes={},has_audio=false,has_midi=false}
    for _,field in ipairs(AUDIO_ITEM_FIELDS) do item_state.values[field]=reaper.GetMediaItemInfo_Value(item,field) end
    item_state.position=item_state.values.D_POSITION or 0
    item_state.length=item_state.values.D_LENGTH or 0
    item_state.finish=item_state.position+item_state.length
    item_state.qn_start=reaper.TimeMap2_timeToQN(proj,item_state.position)
    item_state.qn_end=reaper.TimeMap2_timeToQN(proj,item_state.finish)
    item_state.qn_snap=reaper.TimeMap2_timeToQN(proj,item_state.position+(item_state.values.D_SNAPOFFSET or 0))
    for take_index=0,reaper.GetMediaItemNumTakes(item)-1 do
      local take=reaper.GetTake(item,take_index)
      if take then
        local take_state=capture_take_audio_state(take,take_index)
        item_state.takes[#item_state.takes+1]=take_state
        if take_state.is_midi then item_state.has_midi=true else item_state.has_audio=true;snapshot.audio_takes=snapshot.audio_takes+1 end
      end
    end
    if item_state.has_audio then
      snapshot.audio_items=snapshot.audio_items+1
      if item_state.has_midi then snapshot.mixed_items=snapshot.mixed_items+1 end
      snapshot.items[#snapshot.items+1]=item_state
    elseif item_state.has_midi then snapshot.midi_only_items=snapshot.midi_only_items+1 end
  end
  return snapshot
end

function audio_state_signature(snapshot)
  local lines={}
  for _,item in ipairs((snapshot and snapshot.items) or {}) do
    local values={"ITEM",item.guid}
    for _,field in ipairs(AUDIO_ITEM_FIELDS) do values[#values+1]=field.."="..transaction_signature_number(item.values[field],10) end
    lines[#lines+1]=table.concat(values,"|")
    for _,take in ipairs(item.takes or {}) do
      if not take.is_midi then
        local take_values={"TAKE",item.guid,tostring(take.index)}
        for _,field in ipairs(AUDIO_TAKE_FIELDS) do take_values[#take_values+1]=field.."="..transaction_signature_number(take.values[field],10) end
        lines[#lines+1]=table.concat(take_values,"|")
        for marker_index,marker in ipairs(take.stretch or {}) do
          lines[#lines+1]=table.concat({"STRETCH",item.guid,tostring(take.index),tostring(marker_index),transaction_signature_number(marker.pos,10),transaction_signature_number(marker.source_pos,10),transaction_signature_number(marker.slope,10)},"|")
        end
      end
    end
  end
  return table.concat(lines,"\n")
end

function valid_media_pointer(proj,pointer,type_name)
  return type(reaper.ValidatePtr2)~="function" or reaper.ValidatePtr2(proj,pointer,type_name)
end

function replace_take_stretch_markers(take,markers)
  if type(reaper.GetTakeNumStretchMarkers)~="function" or type(reaper.DeleteTakeStretchMarkers)~="function" or type(reaper.SetTakeStretchMarker)~="function" then
    return #(markers or {})==0,"This REAPER version does not expose the complete stretch-marker API."
  end
  local count=reaper.GetTakeNumStretchMarkers(take)
  if count>0 then reaper.DeleteTakeStretchMarkers(take,0,count) end
  for _,marker in ipairs(markers or {}) do
    local index=reaper.SetTakeStretchMarker(take,-1,marker.pos,marker.source_pos)
    if type(index)~="number" or index<0 then return false,"A take stretch marker could not be restored." end
    if type(reaper.SetTakeStretchMarkerSlope)=="function" then reaper.SetTakeStretchMarkerSlope(take,index,marker.slope or 0) end
  end
  return true
end

function restore_audio_project_state(proj,snapshot)
  local failures={}
  for _,item in ipairs((snapshot and snapshot.items) or {}) do
    if not valid_media_pointer(proj,item.pointer,"MediaItem*") then
      failures[#failures+1]="Audio item "..tostring(item.guid).." no longer exists."
    else
      for _,field in ipairs(AUDIO_ITEM_FIELDS) do
        if not reaper.SetMediaItemInfo_Value(item.pointer,field,item.values[field]) then failures[#failures+1]="Could not restore "..field.." for audio item "..tostring(item.guid).."." end
      end
      for _,take in ipairs(item.takes or {}) do
        if not take.is_midi then
          if not valid_media_pointer(proj,take.pointer,"MediaItem_Take*") then
            failures[#failures+1]="An audio take in item "..tostring(item.guid).." no longer exists."
          else
            for _,field in ipairs(AUDIO_TAKE_FIELDS) do
              if not reaper.SetMediaItemTakeInfo_Value(take.pointer,field,take.values[field]) then failures[#failures+1]="Could not restore "..field.." for an audio take in item "..tostring(item.guid).."." end
            end
            local stretch_ok,stretch_err=replace_take_stretch_markers(take.pointer,take.stretch)
            if not stretch_ok then failures[#failures+1]=tostring(stretch_err).." Item "..tostring(item.guid).."." end
          end
        end
      end
      reaper.UpdateItemInProject(item.pointer)
    end
  end
  return #failures==0,table.concat(failures,"\n")
end

function marker_structure_matches(snapshot)
  local existing=snapshot and snapshot.existing_marker_objects or {}
  local planned=snapshot and snapshot.planned_marker_objects or {}
  if #existing~=#planned then return false,string.format("project markers do not match the workbook (%d current, %d expected)",#existing,#planned) end
  table.sort(existing,function(a,b)if a.measure_index==b.measure_index then return (a.beatpos or 0)<(b.beatpos or 0) end return a.measure_index<b.measure_index end)
  table.sort(planned,function(a,b)if a.measure_index==b.measure_index then return (a.beatpos or 0)<(b.beatpos or 0) end return a.measure_index<b.measure_index end)
  for index=1,#planned do
    local current,target=existing[index],planned[index]
    if normalize_name(current.name)~=normalize_name(target.name) or current.measure_index~=target.measure_index or not nearly_equal(current.beatpos or 0,target.beatpos or 0,1e-7) then
      return false,string.format("project marker %d does not match '%s' at measure %d",index,tostring(target.name),target.visible_measure or target.measure_index)
    end
  end
  return true
end

function meter_structure_matches(proj,plan,snapshot)
  local expected={}
  for offset=0,COUNT_IN.bars-1 do expected[snapshot.count_in.measure_index+offset]={COUNT_IN.numerator,COUNT_IN.denominator,"COUNT IN"} end
  for _,part in ipairs((plan and plan.flat_parts) or {}) do
    local first=snapshot.start.measure_index+(part.start_visible_measure-START_VISIBLE_MEASURE)
    local bars=math.max(0,part.next_visible_measure-part.start_visible_measure)
    for offset=0,bars-1 do expected[first+offset]={part.numerator,part.denominator,part_display_label(part)} end
  end
  local indexes={};for measure_index in pairs(expected) do indexes[#indexes+1]=measure_index end;table.sort(indexes)
  for _,measure_index in ipairs(indexes) do
    local _,_,_,numerator,denominator=reaper.TimeMap_GetMeasureInfo(proj,measure_index)
    local target=expected[measure_index]
    if numerator~=target[1] or denominator~=target[2] then
      local visible=START_VISIBLE_MEASURE+(measure_index-snapshot.start.measure_index)
      return false,string.format("measure %d is %d/%d in REAPER but the workbook requires %d/%d",visible,numerator or 0,denominator or 0,target[1],target[2])
    end
  end
  return true
end

function ramp_structure_matches(snapshot)
  local function linear_positions(objects)
    local out={}
    for _,event in ipairs(objects or {}) do if event.linear then out[#out+1]=comparison_coordinate_key(event.measure_index,event.beatpos or 0) end end
    table.sort(out);return out
  end
  local current,target=linear_positions(snapshot and snapshot.existing_tempo_objects),linear_positions(snapshot and snapshot.planned_tempo_objects)
  if #current~=#target then return false,"the current project and workbook have different Ramp boundaries" end
  for index=1,#target do if current[index]~=target[index] then return false,"the current project and workbook have different Ramp boundaries" end end
  return true
end

function planned_tempo_differs(proj,snapshot)
  for _,event in ipairs((snapshot and snapshot.planned_tempo_objects) or {}) do
    local time=select(1,reaper.TimeMap_GetMeasureInfo(proj,event.measure_index))
    local returned={reaper.TimeMap_GetTimeSigAtTime(proj,time)}
    local current_bpm=returned[#returned]
    if not nearly_equal(current_bpm,event.bpm,1e-5) then return true end
  end
  return false
end

function analyze_audio_tempo_handling(proj,plan,snapshot)
  local analysis={mode=state and state.audio_tempo_mode or AUDIO_MODE_PRESERVE,allowed=true,reasons={},eligible_items=0,unaffected_items=0,audio_items=0,audio_takes=0,tempo_changed=false}
  local audio=capture_audio_project_state(proj);analysis.audio_snapshot=audio;analysis.audio_items=audio.audio_items;analysis.audio_takes=audio.audio_takes
  analysis.tempo_changed=planned_tempo_differs(proj,snapshot)
  local marker_ok,marker_reason=marker_structure_matches(snapshot);if not marker_ok then analysis.reasons[#analysis.reasons+1]=marker_reason end
  local meter_ok,meter_reason=meter_structure_matches(proj,plan,snapshot);if not meter_ok then analysis.reasons[#analysis.reasons+1]=meter_reason end
  local ramp_ok,ramp_reason=ramp_structure_matches(snapshot);if not ramp_ok then analysis.reasons[#analysis.reasons+1]=ramp_reason end
  local range_start=select(1,reaper.TimeMap_GetMeasureInfo(proj,snapshot.count_in.measure_index))
  local range_end=select(1,reaper.TimeMap_GetMeasureInfo(proj,snapshot.end_internal_measure))
  analysis.range_start=range_start;analysis.range_end=range_end
  for _,item in ipairs(audio.items) do
    local crosses_start=item.position<range_start-EPS_TIME and item.finish>range_start+EPS_TIME
    local crosses_end=item.position<range_end-EPS_TIME and item.finish>range_end+EPS_TIME
    local inside=item.position>=range_start-EPS_TIME and item.finish<=range_end+EPS_TIME
    item.conform_eligible=inside
    if inside then
      analysis.eligible_items=analysis.eligible_items+1
      if item.has_midi then analysis.reasons[#analysis.reasons+1]="audio item "..item.guid.." also contains a MIDI take" end
      if (item.values.C_LOCK or 0)~=0 then analysis.reasons[#analysis.reasons+1]="audio item "..item.guid.." is locked" end
    else
      analysis.unaffected_items=analysis.unaffected_items+1
      if crosses_start or crosses_end then analysis.reasons[#analysis.reasons+1]="audio item "..item.guid.." crosses the COUNT IN or END boundary" end
    end
  end
  analysis.conform_allowed=#analysis.reasons==0
  if analysis.audio_items==0 then
    analysis.summary="No audio items detected. The tempo map can be rebuilt without audio-item changes."
  elseif analysis.mode==AUDIO_MODE_CONFORM and analysis.conform_allowed then
    if analysis.tempo_changed then
      analysis.summary=string.format("%d audio item%s will conform to the new tempo with pitch preserved; %d item%s outside COUNT IN through END will remain unchanged.",analysis.eligible_items,analysis.eligible_items==1 and "" or "s",analysis.unaffected_items,analysis.unaffected_items==1 and "" or "s")
    else
      analysis.summary=string.format("The musical tempo already matches. %d eligible audio item%s require no timing change.",analysis.eligible_items,analysis.eligible_items==1 and "" or "s")
    end
  elseif analysis.mode==AUDIO_MODE_CONFORM then
    analysis.summary="Conform Audio is unavailable: "..table.concat(analysis.reasons,"; ")..". Choose Preserve Audio Exactly."
  else
    analysis.summary=string.format("Preserve Audio Exactly will keep %d audio item%s at the same time, length, rate, pitch, and stretch-marker state.",analysis.audio_items,analysis.audio_items==1 and "" or "s")
  end
  return analysis
end

function prepare_audio_for_tempo_build(proj,mode,analysis)
  local context={mode=mode or AUDIO_MODE_PRESERVE,before=analysis and analysis.audio_snapshot or capture_audio_project_state(proj),analysis=analysis}
  context.before_signature=audio_state_signature(context.before)
  for _,item in ipairs(context.before.items or {}) do
    local conform=context.mode==AUDIO_MODE_CONFORM and item.conform_eligible
    reaper.SetMediaItemInfo_Value(item.pointer,"C_BEATATTACHMODE",conform and 1 or 0)
    reaper.SetMediaItemInfo_Value(item.pointer,"C_AUTOSTRETCH",conform and 1 or 0)
    if conform then
      for _,take in ipairs(item.takes or {}) do if not take.is_midi then reaper.SetMediaItemTakeInfo_Value(take.pointer,"B_PPITCH",1) end end
    end
    reaper.UpdateItemInProject(item.pointer)
  end
  return context
end

function finalize_audio_after_tempo_build(proj,context)
  if not context then return true,{summary="No audio context was required."} end
  if context.mode==AUDIO_MODE_PRESERVE then
    local restored,restore_err=restore_audio_project_state(proj,context.before)
    if not restored then return false,"Preserve Audio restoration failed:\n"..tostring(restore_err) end
    local after=capture_audio_project_state(proj)
    if audio_state_signature(after)~=context.before_signature then return false,"Preserve Audio verification failed: one or more audio item properties changed." end
    return true,{summary=context.analysis and context.analysis.summary or "Audio items were preserved exactly.",after_signature=audio_state_signature(after)}
  end
  local failures={}
  for _,item in ipairs(context.before.items or {}) do
    if item.conform_eligible then
      reaper.SetMediaItemInfo_Value(item.pointer,"C_BEATATTACHMODE",item.values.C_BEATATTACHMODE)
      reaper.SetMediaItemInfo_Value(item.pointer,"C_AUTOSTRETCH",item.values.C_AUTOSTRETCH)
      local position=reaper.GetMediaItemInfo_Value(item.pointer,"D_POSITION")
      local current_length=reaper.GetMediaItemInfo_Value(item.pointer,"D_LENGTH")
      local finish=position+current_length
      local snap_time=reaper.TimeMap2_QNToTime(proj,item.qn_snap)
      reaper.SetMediaItemInfo_Value(item.pointer,"D_SNAPOFFSET",math.max(0,math.min(current_length,snap_time-position)))
      local qn_start=reaper.TimeMap2_timeToQN(proj,position);local qn_end=reaper.TimeMap2_timeToQN(proj,finish)
      if not nearly_equal(qn_start,item.qn_start,1e-6) or not nearly_equal(qn_end,item.qn_end,1e-6) then failures[#failures+1]="Audio item "..item.guid.." no longer occupies its original musical count." end
      local qn_snap=reaper.TimeMap2_timeToQN(proj,position+reaper.GetMediaItemInfo_Value(item.pointer,"D_SNAPOFFSET"))
      if not nearly_equal(qn_snap,item.qn_snap,1e-6) then failures[#failures+1]="Audio item "..item.guid.." snap offset no longer occupies its original musical count." end
      for _,take in ipairs(item.takes or {}) do
        if not take.is_midi and reaper.GetMediaItemTakeInfo_Value(take.pointer,"B_PPITCH")<0.5 then failures[#failures+1]="Preserve pitch is not enabled for an audio take in item "..item.guid.."." end
      end
      reaper.UpdateItemInProject(item.pointer)
    else
      local single={items={item}}
      local restored,restore_err=restore_audio_project_state(proj,single)
      if not restored then failures[#failures+1]=restore_err end
    end
  end
  if #failures>0 then return false,"Conform Audio verification failed:\n"..table.concat(failures,"\n") end
  local after=capture_audio_project_state(proj)
  return true,{summary=context.analysis and context.analysis.summary or "Eligible audio conformed with pitch preserved.",after_signature=audio_state_signature(after)}
end

function verify_audio_rollback(proj,context)
  if not context then return true end
  local after=capture_audio_project_state(proj)
  return audio_state_signature(after)==context.before_signature
end

function read_file(path)
  local f,err=io.open(path,"rb"); if not f then return nil,err end
  local text=f:read("*a") or ""; f:close(); return text
end

function write_file(path,text)
  local f,err=io.open(path,"wb"); if not f then return false,err end
  local ok,write_err=f:write(text or ""); f:close(); if not ok then return false,write_err end
  return true
end

function recovery_hex_encode(value)
  return (tostring(value or ""):gsub(".",function(char)return string.format("%02X",string.byte(char))end))
end

function recovery_hex_decode(value)
  value=tostring(value or "")
  if #value%2~=0 or value:find("[^0-9A-Fa-f]") then return nil,"Invalid hexadecimal recovery text." end
  return (value:gsub("(%x%x)",function(pair)return string.char(tonumber(pair,16))end))
end

function serialize_tempo_recovery(record)
  if not record or not record.edits then return nil,"No staged tempo-edit recovery record is available." end
  local lines={
    "BCTM-TEMPO-RECOVERY\t"..tostring(TEMPO_RECOVERY_SCHEMA),
    "PATH\t"..recovery_hex_encode(record.path),
    "FINGERPRINT\t"..recovery_hex_encode(record.fingerprint),
    "SOURCE-SHA256\t"..recovery_hex_encode(record.source_sha256),
    "END\t"..(record.edits.end_bpm_set and "1" or "0").."\t"..recovery_hex_encode(record.edits.end_bpm_text)
  }
  local rows={};for row in pairs(record.edits.rows or {}) do rows[#rows+1]=tonumber(row) end;table.sort(rows)
  for _,row in ipairs(rows) do
    local entry=record.edits.rows[row] or {}
    lines[#lines+1]=table.concat({"ROW",tostring(row),entry.section_shift_overrides and "1" or "0",recovery_hex_encode(entry.bpm_text),recovery_hex_encode(entry.parts_text)},"\t")
    local keys={};for key in pairs(entry.part_bpms or {}) do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys) do lines[#lines+1]=table.concat({"PART",tostring(row),recovery_hex_encode(key),format_bpm(entry.part_bpms[key])},"\t") end
  end
  for _,entry in ipairs(record.log or {}) do lines[#lines+1]="LOG\t"..recovery_hex_encode(entry) end
  return table.concat(lines,"\n").."\n"
end

function deserialize_tempo_recovery(text)
  local record={edits={rows={},end_bpm_set=false,end_bpm_text=""},log={}}
  local header=false
  for line in (tostring(text or "").."\n"):gmatch("(.-)\n") do
    local fields={};for field in (line.."\t"):gmatch("(.-)\t") do fields[#fields+1]=field end
    local kind=fields[1]
    if kind=="BCTM-TEMPO-RECOVERY" then
      if tonumber(fields[2])~=TEMPO_RECOVERY_SCHEMA then return nil,"Unsupported tempo-recovery schema." end
      header=true
    elseif kind=="PATH" or kind=="FINGERPRINT" or kind=="SOURCE-SHA256" then
      local decoded,err=recovery_hex_decode(fields[2]);if not decoded then return nil,err end
      if kind=="PATH" then record.path=decoded elseif kind=="FINGERPRINT" then record.fingerprint=decoded else record.source_sha256=decoded end
    elseif kind=="END" then
      local decoded,err=recovery_hex_decode(fields[3]);if not decoded then return nil,err end
      record.edits.end_bpm_set=fields[2]=="1";record.edits.end_bpm_text=decoded
    elseif kind=="ROW" then
      local row=tonumber(fields[2]);if not row or row<1 or row%1~=0 then return nil,"Invalid spreadsheet row in tempo-recovery data." end
      local bpm,bpm_err=recovery_hex_decode(fields[4]);if not bpm then return nil,bpm_err end
      local parts,parts_err=recovery_hex_decode(fields[5]);if not parts then return nil,parts_err end
      record.edits.rows[row]={bpm_text=bpm~="" and bpm or nil,parts_text=parts~="" and parts or nil,section_shift_overrides=fields[3]=="1",part_bpms={}}
    elseif kind=="PART" then
      local row=tonumber(fields[2]);local key,key_err=recovery_hex_decode(fields[3]);local bpm=tonumber(fields[4])
      if not row or not key or key=="" or not bpm or bpm<=0 then return nil,key_err or "Invalid Part BPM in tempo-recovery data." end
      record.edits.rows[row]=record.edits.rows[row] or {part_bpms={}};record.edits.rows[row].part_bpms=record.edits.rows[row].part_bpms or {};record.edits.rows[row].part_bpms[key]=bpm
    elseif kind=="LOG" then
      local decoded,err=recovery_hex_decode(fields[2]);if not decoded then return nil,err end;record.log[#record.log+1]=decoded
    elseif line~="" then return nil,"Unknown tempo-recovery record type: "..tostring(kind) end
  end
  if not header or trim(record.path)=="" or trim(record.fingerprint)=="" or tempo_edits_empty(record.edits) then return nil,"The tempo-recovery record is incomplete." end
  return record
end

function tempo_recovery_path()
  if TEST_MODE then return nil end
  local root=type(reaper.GetResourcePath)=="function" and reaper.GetResourcePath() or script_directory()
  return path_join(path_join(root,"Data"),TEMPO_RECOVERY_FILENAME)
end

function load_tempo_edit_recovery()
  if SAFE_MODE or TEST_MODE then return nil end
  local path=tempo_recovery_path();if not path or not file_exists(path) then return nil end
  local text,read_err=read_file(path);if not text then return {load_error=tostring(read_err),recovery_path=path} end
  local record,parse_err=deserialize_tempo_recovery(text)
  if not record then return {load_error=tostring(parse_err),recovery_path=path} end
  record.recovery_path=path;return record
end

function clear_tempo_edit_recovery()
  if SAFE_MODE or TEST_MODE then return true end
  local path=tempo_recovery_path();if path and file_exists(path) then local ok,err=os.remove(path);if not ok then return false,err end end
  if state then state.pending_tempo_recovery=nil end
  return true
end

function persist_tempo_edit_recovery()
  if SAFE_MODE or TEST_MODE or not state then return true end
  if state.suppress_tempo_recovery or tempo_edits_empty(state.tempo_edits) then return clear_tempo_edit_recovery() end
  if not state.base_plan or trim(state.file_path)=="" or trim(state.base_plan.fingerprint)=="" then return false,"The validated workbook identity is unavailable." end
  local record={path=state.file_path,fingerprint=state.base_plan.fingerprint,source_sha256=state.base_plan.source_sha256 or "",edits=clone_tempo_edits(state.tempo_edits),log={table.unpack(state.tempo_edit_log or {})}}
  local serialized,serialize_err=serialize_tempo_recovery(record);if not serialized then return false,serialize_err end
  local path=tempo_recovery_path();local ok,write_err=write_file(path,serialized);if not ok then return false,write_err end
  state.pending_tempo_recovery=record;state.pending_tempo_recovery.recovery_path=path
  return true
end

function tempo_part_identity(part)
  return table.concat({tostring(part and part.section_row or ""),tostring(part and part.item_index or ""),tostring(part and part.block_part_index or 0)},":")
end

function tempo_edit_scope(base_plan,current_plan)
  local section_count,part_count,end_changed=0,0,false
  local current_sections={};for _,section in ipairs((current_plan and current_plan.sections) or {}) do current_sections[section.row]=section end
  for _,base in ipairs((base_plan and base_plan.sections) or {}) do local current=current_sections[base.row];if current and not nearly_equal(base.bpm,current.bpm,1e-9) then section_count=section_count+1 end end
  local base_parts,current_parts={},{ }
  for _,part in ipairs((base_plan and base_plan.flat_parts) or {}) do local key=tempo_part_identity(part);base_parts[key]=base_parts[key] or part end
  for _,part in ipairs((current_plan and current_plan.flat_parts) or {}) do local key=tempo_part_identity(part);current_parts[key]=current_parts[key] or part end
  for key,base in pairs(base_parts) do local current=current_parts[key];if current and not nearly_equal(base.underlying_bpm,current.underlying_bpm,1e-9) then part_count=part_count+1 end end
  if base_plan and current_plan then
    local base_end=base_plan.end_bpm_entered or END_BPM;local current_end=current_plan.end_bpm_entered or END_BPM
    end_changed=not nearly_equal(base_end,current_end,1e-9)
  end
  return {sections=section_count,parts=part_count,end_changed=end_changed}
end

function tempo_edit_scope_text(base_plan,current_plan)
  local scope=tempo_edit_scope(base_plan,current_plan)
  local text=string.format("%d Section%s and %d source Part%s",scope.sections,scope.sections==1 and "" or "s",scope.parts,scope.parts==1 and "" or "s")
  if scope.end_changed then text=text..", plus END" end
  return text,scope
end

function tempo_recovery_matches_plan(record,path,plan)
  local function comparable(value)return tostring(value or ""):gsub("\\","/"):lower() end
  if not record or not plan then return false,"missing" end
  if comparable(record.path)~=comparable(path) then return false,"path" end
  if record.fingerprint~=plan.fingerprint then return false,"fingerprint" end
  if trim(record.source_sha256)~="" and trim(plan.source_sha256)~="" and record.source_sha256~=plan.source_sha256 then return false,"source" end
  return true
end

function csv_escape(value)
  local s=tostring(value or "")
  if s:find('[,\r\n"]') then s='"'..s:gsub('"','""')..'"' end
  return s
end

function workbook_edit_records(edits,base_plan)
  local records={}
  for row,entry in pairs((edits and edits.rows) or {}) do
    if entry.bpm_text~=nil then records[#records+1]={row=row,col=base_plan.bpm_col,value=entry.bpm_text} end
    if entry.parts_text~=nil then records[#records+1]={row=row,col=base_plan.parts_col,value=entry.parts_text} end
  end
  if edits and edits.end_bpm_set then records[#records+1]={row=base_plan.end_row,col=base_plan.bpm_col,value=edits.end_bpm_text or ""} end
  table.sort(records,function(a,b) return a.row==b.row and a.col<b.col or a.row<b.row end)
  for _,record in ipairs(records) do
    if record.value=="" then record.kind="B"
    elseif record.col==base_plan.bpm_col and tostring(record.value):match("^%d+%.?%d*$") then record.kind="N"
    else record.kind="S" end
  end
  return records
end

function write_updated_csv_copy(path,records)
  local sheets=clone_sheet_data(state.base_plan.source_sheets)
  local sheet=sheets[state.base_plan.sheet_index]
  for _,record in ipairs(records) do set_sheet_cell(sheet,record.row,record.col,record.value) end
  local lines={}
  for row=1,sheet.max_row do
    local values={}
    local width=sheet.csv_row_widths and sheet.csv_row_widths[row] or sheet.max_col
    width=math.max(width or 0,state.base_plan.section_col,state.base_plan.bpm_col,state.base_plan.parts_col)
    for col=1,width do values[col]=csv_escape(cell_value(sheet,row,col)) end
    lines[#lines+1]=table.concat(values,",")
  end
  return write_file(path,table.concat(lines,"\r\n").."\r\n")
end

function write_updated_xlsx_copy(path,records)
  local edits_path=make_temp_path(".txt")
  local lines={}
  for _,record in ipairs(records) do lines[#lines+1]=table.concat({record.row,record.col,record.kind,base64_encode(record.value)},"\t") end
  local ok,write_err=write_file(edits_path,table.concat(lines,"\r\n").."\r\n")
  if not ok then return false,"Could not create the temporary workbook-edit manifest: "..tostring(write_err) end
  local result,patch_err=run_powershell_text(POWERSHELL_XLSX_PATCHER,{
    {name="InputPath",value=state.file_path},{name="DestinationPath",value=path},
    {name="SheetIndex",value=tostring(state.base_plan.sheet_index)},{name="EditsPath",value=edits_path}
  },120000)
  os.remove(edits_path)
  if result~="OK" then os.remove(path);return false,"Updated XLSX copy could not be created: "..tostring(patch_err or result) end
  return true
end

function write_reconstructed_csv(path,rows)
  local lines={}
  for _,row in ipairs(rows or {}) do lines[#lines+1]=table.concat({csv_escape(row[1]),csv_escape(row[2]),csv_escape(row[3])},",") end
  return write_file(path,table.concat(lines,"\r\n").."\r\n")
end

function write_reconstructed_xlsx(path,rows)
  local manifest_path=make_temp_path(".txt")
  local lines={}
  for _,row in ipairs(rows or {}) do
    lines[#lines+1]=table.concat({base64_encode(row[1] or ""),base64_encode(row[2] or ""),base64_encode(row[3] or "")},"\t")
  end
  local wrote,write_error=write_file(manifest_path,table.concat(lines,"\r\n").."\r\n")
  if not wrote then return false,"Could not create the temporary reconstruction manifest: "..tostring(write_error) end
  local result,create_error=run_powershell_text(POWERSHELL_XLSX_CREATOR,{
    {name="DestinationPath",value=path},{name="RowsPath",value=manifest_path},{name="SheetName",value="REAPER Song Sections"}
  },120000)
  os.remove(manifest_path)
  if result~="OK" then os.remove(path);return false,"Reconstructed XLSX could not be created: "..tostring(create_error or result) end
  return true
end

function reconstructed_workbook_default_name(project,extension)
  local stem=project_filename_stem(project and (project.path~="" and project.path or project.name) or "REAPER_Project")
  return string.format("%s_BCTM_RECONSTRUCTED_%s.%s",sanitize_filename(stem),os.date("%Y-%m-%d_%H%M%S"),extension)
end

function log_reconstruction_error(project,message)
  local entry=string.format("%s | v%s | %s | %s",os.date("%Y-%m-%d %H:%M:%S"),SCRIPT_VERSION,tostring(project and project.path or "(unsaved project)"),tostring(message):gsub("[\r\n]+"," | "))
  state.reconstruction_log=state.reconstruction_log or {}
  state.reconstruction_log[#state.reconstruction_log+1]=entry
  if project_is_saved(project) then
    local folder=project_log_folder(project)
    ensure_directory(folder)
    local path=path_join(folder,os.date("%m-%d-%Y_%I-%M-%S_%p").."_RECONSTRUCTION_ERROR.txt")
    write_file(path,"BILDIBEAT WORKBOOK RECONSTRUCTION ERROR\r\nVersion: "..SCRIPT_VERSION.."\r\nProject: "..tostring(project.path).."\r\nTime: "..os.date("%Y-%m-%d %H:%M:%S %Z").."\r\n\r\n"..tostring(message).."\r\n")
    state.last_reconstruction_log_path=path
  end
end

function reconstruction_project_still_matches(project,result)
  local current=get_active_project_info()
  if not current or not current.proj or current.pointer~=project.pointer then return false,current end
  if transaction_project_signature(current.proj)~=result.project_signature then return false,current end
  return true,current
end

function save_reconstructed_workbook(result,project,extension)
  local unchanged,current=reconstruction_project_still_matches(project,result)
  if not unchanged then
    local message="[RCN-009] The active REAPER project or its marker/tempo map changed after reconstruction analysis. Run Create Workbook From Open Project again."
    log_reconstruction_error(current or project,message);set_status("Workbook reconstruction canceled because the project changed.","error");show_info("Project Changed Before Save",message,"error");return
  end
  local default_name=reconstructed_workbook_default_name(project,extension)
  local filter=extension=="xlsx" and "Excel workbooks (*.xlsx)|*.xlsx|CSV files (*.csv)|*.csv|All files (*.*)|*.*" or "CSV files (*.csv)|*.csv|Excel workbooks (*.xlsx)|*.xlsx|All files (*.*)|*.*"
  local path,dialog_error=choose_save_path("Save Verified Workbook Reconstructed From REAPER",filter,default_name,project.folder)
  if not path then
    if dialog_error~="CANCELLED" then log_reconstruction_error(project,"[RCN-010] Save dialog failed: "..tostring(dialog_error));show_info("Reconstructed Workbook Save Failed","[RCN-010] "..tostring(dialog_error),"error") end
    return
  end
  unchanged,current=reconstruction_project_still_matches(project,result)
  if not unchanged then
    local message="[RCN-009] The active REAPER project or its marker/tempo map changed while the save dialog was open. No workbook was written. Run Create Workbook From Open Project again."
    log_reconstruction_error(current or project,message);set_status("Workbook reconstruction canceled because the project changed.","error");show_info("Project Changed Before Save",message,"error");return
  end
  if not path:lower():match("%."..extension.."$") then path=path.."."..extension end
  state.operation_busy=true;set_status("Writing and reopening the reconstructed workbook for final verification...","info");gfx.update()
  local ok,write_error
  if extension=="xlsx" then ok,write_error=write_reconstructed_xlsx(path,result.rows)
  else ok,write_error=write_reconstructed_csv(path,result.rows) end
  if not ok then
    state.operation_busy=false;log_reconstruction_error(project,"[RCN-010] "..tostring(write_error));set_status("Reconstructed workbook could not be written.","error");show_info("Reconstructed Workbook Save Failed","[RCN-010] "..tostring(write_error),"error");return
  end
  unchanged,current=reconstruction_project_still_matches(project,result)
  if not unchanged then
    os.remove(path);state.operation_busy=false
    local message="[RCN-009] The active REAPER project or its marker/tempo map changed while the workbook was being written. The unverified file was removed. Run Create Workbook From Open Project again."
    log_reconstruction_error(current or project,message);set_status("Project changed during reconstruction; unverified file removed.","error");show_info("Project Changed During Save",message,"error");return
  end
  local verified_plan,validation_errors=validate_file(path)
  local matched,match_result=false,nil
  if verified_plan then matched,match_result=compare_validated_plan_to_project(verified_plan,current.proj) end
  if not verified_plan or not matched then
    os.remove(path);state.operation_busy=false
    local detail=not verified_plan and table.concat(validation_errors or {"Unknown generated-workbook validation error."},"\n") or tostring(match_result)
    local message="[RCN-011] The saved file did not pass the production parser and one-for-one open-project verification. The unverified file was removed.\n\n"..detail
    log_reconstruction_error(project,message);set_status("Post-save reconstruction verification failed; unverified file removed.","error");show_info("Reconstructed Workbook Verification Failed",message,"error");return
  end
  state.operation_busy=false;state.last_reconstructed_workbook=path
  set_status("Verified workbook reconstructed from the open REAPER project: "..path,"success")
  open_app_modal({
    title="Verified Workbook Created",
    message=string.format("The workbook was reopened with the production parser and verified one-for-one against the unchanged open REAPER project.\n\nSections: %d\nExpanded Parts: %d\nMusical bars: %d\nInferred Blocks: %d\nMarker names: preserved exactly\n\nSaved file:\n%s\n\nThe REAPER project, audio, items, markers, and tempo map were not changed.",#verified_plan.sections,#verified_plan.flat_parts,verified_plan.total_bars,result.block_count or 0,path),
    kind="success",
    buttons={{label="Open Generated Workbook",value="open",primary=true,stay_open=true},{label="Close",value="close",cancel=true}},
    on_result=function(value)
      if value=="open" then
        local opened,open_error=shell_open(path)
        if not opened and state.app_modal then state.app_modal.error=tostring(open_error) end
      end
    end
  })
end

function create_workbook_from_open_project()
  if state.operation_busy then return end
  local project=get_active_project_info()
  if not project or not project.proj then show_info("Create Workbook From Open Project","[RCN-001] Open a REAPER project first.","warning");return end
  if reaper.GetPlayStateEx(project.proj)~=0 then show_info("Create Workbook From Open Project","[RCN-001] Stop playback, pause, and recording before analyzing the project.","warning");return end
  state.operation_busy=true;set_status("Reading markers, meters, tempos, click patterns, ramps, and repeat structure from the open REAPER project...","info");gfx.update()
  local result,reconstruction_error=reconstruct_workbook_plan_from_project(project.proj)
  if not result then
    state.operation_busy=false;log_reconstruction_error(project,reconstruction_error);set_status("Open-project workbook reconstruction could not be verified.","error")
    show_info("Workbook Reconstruction Needs Review",tostring(reconstruction_error).."\n\nNo workbook was written and the REAPER project was not changed.","error");return
  end
  result.project_signature=transaction_project_signature(project.proj)
  state.operation_busy=false
  local block_note=result.block_count>0 and string.format("%d exact repeated sequence%s compressed as < > Block syntax.",result.block_count,result.block_count==1 and " was" or "s were") or "No unambiguous multi-Part Block was inferred; ordinary repeats remain compact where exact."
  open_app_modal({
    title="Open Project Reconstructed and Verified",
    message=string.format("The proposed workbook passed the production parser and matches the open REAPER project one-for-one.\n\nSections: %d\nExpanded Parts: %d\nMusical bars: %d\nTempo/time-signature events: %d\nStandard markers: %d\n\n%s\nTuplet names were inferred only where the effective tempo is an exact supported multiple of the Section BPM. Ambiguous rhythms remain ordinary meter syntax with an explicit BPM override.\n\nChoose XLSX or CSV. The saved file will be reopened and verified again before it is accepted. This analysis did not change REAPER.",#result.plan.sections,#result.plan.flat_parts,result.plan.total_bars,#result.model.tempo_events,#result.model.markers,block_note),
    kind="success",
    buttons={{label="Save Verified XLSX...",value="xlsx",primary=true},{label="Save Verified CSV...",value="csv"},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value)
      if value=="xlsx" or value=="csv" then save_reconstructed_workbook(result,project,value) end
    end
  })
end

function updated_workbook_copy_available()
  if tempo_edits_empty(state.tempo_edits) then return false,"No staged tempo edits are available to save." end
  local build=state.last_successful_build
  if not build or not build.plan or build.plan.plan_sha256~=state.plan.plan_sha256 then return false,"Apply and verify the exact staged tempo plan in REAPER first." end
  if state.preview_stale then return false,"The source workbook changed after validation." end
  local project=get_active_project_info()
  if not project or project.pointer~=build.project_pointer then return false,"Return to the REAPER project that received the verified tempo edits." end
  if transaction_project_signature(project.proj)~=build.built_signature then return false,"The REAPER project marker or tempo state changed after verification." end
  return true,"Available"
end

function updated_workbook_default_name()
  local stem=basename(state.file_path):gsub("%.[^%.]+$","")
  stem=sanitize_filename(stem)
  local suffix=state.last_successful_build and state.last_successful_build.attempt and state.last_successful_build.attempt.suffix or string.format("%04X",math.random(0,65535))
  return string.format("%s_CTM_TEMPO_UPDATE_%s_ID-%s.%s",stem,os.date("%Y-%m-%d_%H%M%S"),suffix:sub(-4),state.base_plan.file_type)
end

function save_updated_workbook_copy()
  local available,reason=updated_workbook_copy_available()
  if not available then show_info("Save Updated Workbook Copy Unavailable",reason,"warning");return end
  local source_fingerprint=file_fingerprint(state.file_path)
  if source_fingerprint~=state.base_plan.fingerprint then state.preview_stale=true;show_info("Source Workbook Changed","[WBK-002] The saved source workbook changed after validation. Revalidate before creating an updated copy.","error");return end
  local ext=state.base_plan.file_type;local filter=ext=="xlsx" and "Excel workbooks (*.xlsx)|*.xlsx|All files (*.*)|*.*" or "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
  local path,dialog_err=choose_save_path("Save Updated Workbook Copy",filter,updated_workbook_default_name(),dirname(state.file_path))
  if not path then if dialog_err~="CANCELLED" then show_info("Workbook Save As Could Not Open","[WBK-001] "..tostring(dialog_err),"error") end;return end
  if file_extension(path)~=ext then path=path.."."..ext end
  if normalized_path_for_compare(path)==normalized_path_for_compare(state.file_path) then show_info("Choose a New Workbook Filename","The validated source workbook will not be overwritten. Choose a different filename for the updated copy.","warning");return end
  state.operation_busy=true;set_status("Creating and verifying updated workbook copy...","info");gfx.update()
  local records=workbook_edit_records(state.tempo_edits,state.base_plan)
  local ok,write_err
  if ext=="xlsx" then ok,write_err=write_updated_xlsx_copy(path,records) else ok,write_err=write_updated_csv_copy(path,records) end
  if not ok then state.operation_busy=false;set_status("Updated workbook copy failed.","error");show_info("Updated Workbook Copy Failed","[WBK-003] "..tostring(write_err),"error");return end
  local verified,verify_errors=validate_file(path)
  if not verified or verified.plan_sha256~=state.plan.plan_sha256 then
    os.remove(path);state.operation_busy=false
    local detail=verified and "The saved copy reopened, but its validated plan did not match the staged and built tempo plan." or table.concat(verify_errors or {"The saved copy could not be reopened."},"\n")
    set_status("Updated workbook verification failed; the unverified copy was removed.","error")
    show_info("Updated Workbook Verification Failed","[WBK-004] "..detail,"error")
    return
  end
  local original_path=state.file_path
  local successful_build=state.last_successful_build
  state.file_path=path;state.base_plan=verified;state.plan=verified
  state.tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""};state.tempo_edit_history={};state.tempo_edit_log={}
  state.suppress_tempo_recovery=false;clear_tempo_edit_recovery()
  state.updated_workbook_copy=path;state.preview_rows=preview_rows(verified);state.preview_vscroll=0;state.preview_hscroll=0;clear_preview_selection()
  state.preview_stale=false;state.project_changed=false;state.validated_timestamp=verified.validated_timestamp or make_attempt_id().timestamp
  local project=get_active_project_info();state.validation_project=project;state.dry_run=project and collect_project_snapshot(project.proj,verified) or nil;state.dry_run_stale=state.dry_run==nil
  if successful_build and successful_build.plan and successful_build.plan.plan_sha256==verified.plan_sha256 then
    successful_build.plan=verified;successful_build.source_file=path;successful_build.source_fingerprint=verified.fingerprint;state.last_successful_build=successful_build
  end
  refresh_staged_row_changes();reaper.SetExtState(EXTSTATE_SECTION,"last_file",path,true);add_recent_file(state,path)
  state.operation_busy=false
  set_status("Updated workbook copy saved, revalidated, and adopted as the current workbook: "..path,"success")
  show_info("Updated Workbook Copy Verified","The original workbook was not changed:\n"..original_path.."\n\nThe verified updated copy is now the current workbook baseline, so its tempo-change highlighting has cleared:\n"..path.."\n\nIts validated plan still exactly matches the tempo map built in REAPER.","success")
end

local ZONE_MAP={
  ["EASTERN STANDARD TIME"]="EST",["EASTERN DAYLIGHT TIME"]="EDT",
  ["CENTRAL STANDARD TIME"]="CST",["CENTRAL DAYLIGHT TIME"]="CDT",
  ["MOUNTAIN STANDARD TIME"]="MST",["MOUNTAIN DAYLIGHT TIME"]="MDT",
  ["PACIFIC STANDARD TIME"]="PST",["PACIFIC DAYLIGHT TIME"]="PDT",
  ["ALASKA STANDARD TIME"]="AKST",["ALASKA DAYLIGHT TIME"]="AKDT",
  ["HAWAII STANDARD TIME"]="HST",["UTC"]="UTC",["COORDINATED UNIVERSAL TIME"]="UTC"
}

function local_zone_label()
  local raw=upper(trim(os.date("%Z") or ""))
  if ZONE_MAP[raw] then return ZONE_MAP[raw] end
  if raw:match("^[A-Z][A-Z][A-Z]?[A-Z]?$" ) then return raw end
  for long,short in pairs(ZONE_MAP) do if raw:find(long,1,true) then return short end end
  local offset=os.date("%z") or ""
  if offset:match("^[%+%-]%d%d%d%d$") then return "UTC"..offset:sub(1,3).."-"..offset:sub(4,5) end
  return "LOCAL"
end

function make_attempt_id()
  local zone=local_zone_label()
  local suffix=string.format("%04X",math.random(0,65535))
  local display=os.date("%m/%d/%Y %I:%M:%S %p").." "..zone.."-"..suffix
  local safe=os.date("%m-%d-%Y_%I-%M-%S_%p").."_"..sanitize_filename(zone).."_"..suffix
  return {id=display,safe_id=safe,timestamp=os.date("%m/%d/%Y %I:%M:%S %p").." "..zone,zone=zone,suffix=suffix}
end

function copy_to_clipboard(text)
  local tmp=make_temp_path(".txt")
  local ok,err=write_file(tmp,text or "")
  if not ok then return false,err end
  local ps=[=[
param([string]$OutputPath,[string]$Path)
$ErrorActionPreference='Stop'; $e=New-Object Text.UTF8Encoding($false)
try {
  Set-Clipboard -Value ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))
  [IO.File]::WriteAllText($OutputPath,'OK',$e)
} catch {
  [IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e)
  exit 1
}
]=]
  local result,copy_err=run_powershell_text(ps,{{name="Path",value=tmp}},30000)
  os.remove(tmp)
  if result~="OK" then return false,copy_err or "Windows did not confirm the clipboard operation." end
  return true
end

function read_from_clipboard()
  local ps=[=[
param([string]$OutputPath)
$ErrorActionPreference='Stop'; $e=New-Object Text.UTF8Encoding($false)
try {
  $value=Get-Clipboard -Raw -Format Text
  if ($null -eq $value) { $value='' }
  [IO.File]::WriteAllText($OutputPath,[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$value)),$e)
} catch {
  [IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e)
  exit 1
}
]=]
  local encoded,err=run_powershell_text(ps,nil,30000)
  if not encoded then return nil,err or "Windows did not provide clipboard text." end
  return base64_decode(encoded)
end

function shell_open(path)
  if not path or path=="" then return false,"Path is empty." end
  local cmd='cmd.exe /C start "" '..command_quote(path)
  local exit_code,output=exec_process_result(reaper.ExecProcess(cmd,30000))
  if exit_code==nil then return false,"Windows could not start the requested path." end
  if exit_code~=0 then return false,"Windows shell returned exit code "..tostring(exit_code)..(output~="" and (": "..output) or ".") end
  return true
end

local PS_SAVE_DIALOG=[=[
param([string]$OutputPath,[string]$Title,[string]$Filter,[string]$DefaultName,[string]$InitialDirectory)
$ErrorActionPreference='Stop'; $e=New-Object Text.UTF8Encoding($false)
try {
 Add-Type -AssemblyName System.Windows.Forms
 $d=New-Object System.Windows.Forms.SaveFileDialog
 $d.Title=$Title; $d.Filter=$Filter; $d.FileName=$DefaultName
 if(-not [string]::IsNullOrWhiteSpace($InitialDirectory)){$d.InitialDirectory=$InitialDirectory}
 if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){[IO.File]::WriteAllText($OutputPath,$d.FileName,$e)}
 else {[IO.File]::WriteAllText($OutputPath,'CANCELLED',$e)}
} catch {[IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e);exit 1}
]=]

function choose_save_path(title,filter,default_name,initial_dir)
  local result,err=run_powershell_text(PS_SAVE_DIALOG,{
    {name="Title",value=title},{name="Filter",value=filter},{name="DefaultName",value=default_name},{name="InitialDirectory",value=initial_dir or ""}
  },120000)
  if not result then return nil,err end
  if result=="CANCELLED" then return nil,"CANCELLED" end
  return result
end

function ensure_rpp_extension(path)
  path=trim(path or "")
  if path~="" and not path:lower():match("%.rpp$") then path=path..".RPP" end
  return path
end

function project_filename_stem(path)
  local stem=basename(path or ""):gsub("%.[Rr][Pp][Pp]$","")
  stem=stem:gsub("_CTM_PREBUILD_BACKUP_%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d.*$","")
  stem=stem:gsub("_CTM_COMPLETED_BUILD_%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d_ID%-%x+.*$","")
  stem=trim(stem):gsub("[%. ]+$","")
  return stem~="" and stem or "REAPER_Project"
end

function unique_file_path(folder,filename)
  local candidate=path_join(folder,filename)
  if not file_exists(candidate) then return candidate end
  local stem,ext=filename:match("^(.*)(%.[^%.]+)$");stem=stem or filename;ext=ext or ""
  local index=2
  repeat
    candidate=path_join(folder,string.format("%s_%02d%s",stem,index,ext));index=index+1
  until not file_exists(candidate)
  return candidate
end

function prebuild_backup_path(project)
  local folder=project and project.folder or ""
  local name=project_filename_stem(project and project.path or "").."_CTM_PREBUILD_BACKUP_"..os.date("%Y-%m-%d_%H%M%S")..".RPP"
  return unique_file_path(folder,name)
end

function completed_build_path(project,attempt)
  local folder=project and project.folder or ""
  local id=attempt and attempt.suffix or "BUILD"
  local name=project_filename_stem(project and project.path or "").."_CTM_COMPLETED_BUILD_"..os.date("%Y-%m-%d_%H%M%S").."_ID-"..sanitize_filename(id)..".RPP"
  return unique_file_path(folder,name)
end

function normalized_path_for_compare(path)
  local value=tostring(path or ""):gsub("/","\\"):gsub("\\+","\\")
  return reaper.GetOS():match("Win") and value:lower() or value
end

function save_reaper_project_as(project,path)
  if not project or not project.proj then return false,"The active REAPER project is unavailable." end
  path=ensure_rpp_extension(path)
  if path=="" then return false,"Choose a filename for the REAPER .RPP project." end
  local ok,err=pcall(reaper.Main_SaveProjectEx,project.proj,path,8)
  if not ok then return false,"REAPER could not save the project: "..tostring(err) end
  local current=get_active_project_info()
  if not current or current.pointer~=project.pointer then return false,"The active REAPER project changed while Save As was running." end
  if normalized_path_for_compare(current.path)~=normalized_path_for_compare(path) or not file_exists(path) then
    return false,"REAPER did not confirm the requested .RPP filename. No build was started."
  end
  return true,current
end

function save_reaper_project_current(project)
  if not project_is_saved(project) then return false,"The active REAPER project does not yet have an .RPP filename." end
  local ok,err=pcall(reaper.Main_SaveProject,project.proj,false)
  if not ok then return false,"REAPER could not save the project: "..tostring(err) end
  local current=get_active_project_info()
  if not current or current.pointer~=project.pointer or not file_exists(current.path) then return false,"REAPER did not confirm that the active .RPP project was saved." end
  return true,current
end

function project_log_folder(project_info)
  return path_join(project_info.folder,"SONG STRUCTURE BUILD LOGS")
end

function history_index_path(folder)
  return path_join(folder,"BUILD HISTORY.csv")
end

local HISTORY_HEADERS={"Build ID","Timestamp","Status","Project","Spreadsheet","Plan Hash","Log Filename","Available","Original Build ID","Notes"}

function load_history(folder, limit)
  local path=history_index_path(folder)
  if not file_exists(path) then return {} end
  local text=read_file(path); if not text then return {} end
  local rows=parse_csv_rows(text); if not rows then return {} end
  local entries={}
  for i=2,#rows do
    local r=rows[i]
    if #r>=8 then
      entries[#entries+1]={id=r[1] or "",timestamp=r[2] or "",status=r[3] or "",project=r[4] or "",spreadsheet=r[5] or "",plan_hash=r[6] or "",log_filename=r[7] or "",available=(r[8] or "YES")~="NO",original_build_id=r[9] or "",notes=r[10] or ""}
    end
  end
  if limit and #entries>limit then
    local out={}; for i=#entries-limit+1,#entries do out[#out+1]=entries[i] end; return out
  end
  return entries
end

function save_history(folder, entries)
  local lines={}
  local h={};for _,v in ipairs(HISTORY_HEADERS) do h[#h+1]=csv_escape(v) end;lines[#lines+1]=table.concat(h,",")
  for _,e in ipairs(entries) do
    local row={e.id,e.timestamp,e.status,e.project,e.spreadsheet,e.plan_hash,e.log_filename,e.available==false and "NO" or "YES",e.original_build_id or "",e.notes or ""}
    for i,v in ipairs(row) do row[i]=csv_escape(v) end
    lines[#lines+1]=table.concat(row,",")
  end
  return write_file(history_index_path(folder),table.concat(lines,"\r\n").."\r\n")
end

function add_history_entry(folder, entry)
  local all=load_history(folder,nil)
  all[#all+1]=entry
  return save_history(folder,all)
end

function bar_count_phrase(count)
  local bars=tonumber(count) or 0
  return string.format("%d %s",bars,bars==1 and "bar" or "bars")
end

function simulated_rhythm_name(part)
  if not part then return nil end
  if part.kind=="eighth_triplet" then return "Eighth Note Triplet" end
  if part.kind=="sextuplet" then return "Sextuplet" end
  if part.kind=="quintuplet" then return "Quintuplet" end
  if part.kind=="septuplet" then return "Septuplet" end
  return nil
end

function click_type_name(part)
  local simulated=simulated_rhythm_name(part);if simulated then return simulated end
  local denominator=part and tonumber(part.denominator) or nil
  if denominator==4 then return "Quarter Note" end
  if denominator==8 then return "Eighth Note" end
  if denominator==16 then return "Sixteenth Note" end
  if denominator==32 then return "Thirty-Second Note" end
  return "Standard"
end

function preview_part_plain_english(part,section,next_part)
  if not part then return "" end
  local prefix=""
  if part.block_repeat_index then
    prefix=string.format("Block pass %d of %d, part %d of %d: ",part.block_repeat_index,part.block_repeat_total,part.block_part_index,part.block_part_total)
  end
  local sentence=string.format("%s%s of %d/%d at %s",prefix,bar_count_phrase(part.repeats),part.numerator,part.denominator,format_bpm(part.effective_bpm))
  local rhythm=simulated_rhythm_name(part)
  if rhythm then
    sentence=sentence..string.format(" effective REAPER BPM (%s: %s underlying BPM x%s).",rhythm,format_bpm(part.underlying_bpm),format_bpm(part.multiplier))
  else
    sentence=sentence.." BPM."
    if part.has_override and section and not nearly_equal(part.underlying_bpm,section.bpm,1e-9) then
      sentence=sentence..string.format(" Part override; section BPM is %s.",format_bpm(section.bpm))
    end
  end

  if part.ramp_suppressed then
    sentence=sentence.." Its declared final internal ramp is inactive at the final block boundary and does not leave the block."
  elseif part.ramp then
    local subject=part.ramp_bars==1 and "Its final bar ramps" or string.format("Its final %d bars ramp",part.ramp_bars)
    local destination="to "..format_bpm(part.ramp_target_bpm).." BPM"
    if next_part then
      if next_part.block_repeat_index and part.block_repeat_index and next_part.block_repeat_index~=part.block_repeat_index then
        destination=string.format("into block pass %d at %s BPM",next_part.block_repeat_index,format_bpm(part.ramp_target_bpm))
      elseif next_part.block_repeat_index and not part.block_repeat_index then
        destination=string.format("into block pass %d at %s BPM",next_part.block_repeat_index,format_bpm(part.ramp_target_bpm))
      elseif next_part.block_repeat_index and part.block_repeat_index then
        destination="into the next block part at "..format_bpm(part.ramp_target_bpm).." BPM"
      elseif next_part.section_name and part.section_name and next_part.section_name~=part.section_name then
        destination=string.format("into %s at %s BPM",next_part.section_name,format_bpm(part.ramp_target_bpm))
      end
    end
    sentence=sentence.." "..subject.." "..destination.."."
  end
  return sentence
end

function preview_row_blurb(row)
  if not row then return nil end
  if trim(row.plain_english)~="" then return row.plain_english end
  if row.issue then
    local code=row.issue.reference and row.issue.reference.code or "Validation issue"
    local title=row.issue.reference and row.issue.reference.title or "Workbook validation error"
    return string.format("%s%s: %s. Right-click or press Enter for the complete explanation.",row.issue.row and ("Row "..row.issue.row.."  •  ") or "",code,title)
  end
  return nil
end

function pane_default_context(active_view)
  if active_view=="HISTORY" then
    return "History: filter, inspect, and open logged build attempts."
  elseif active_view=="SETTINGS" then
    return "Settings: configure Preview, logging, workspace, and advanced behavior."
  elseif active_view=="HELP" then
    return "Help: review syntax, shortcuts, Error Reference, and troubleshooting."
  end
  return "Build: choose or validate a workbook, review the Preview, and build when all Readiness checks pass."
end

function resolve_bottom_bar_content(app_state,now,rows)
  local display_status=app_state and app_state.status or ""
  local display_kind=app_state and app_state.status_kind or "info"
  if app_state and (now or 0)>=(app_state.status_until or 0) then
    if trim(app_state.hover_context)~="" then
      display_status,display_kind=app_state.hover_context,"info"
    elseif app_state.active_view=="BUILD" and app_state.selected_preview_row then
      local selected_blurb=preview_row_blurb(rows and rows[app_state.selected_preview_row] or nil)
      if selected_blurb then
        display_status,display_kind=selected_blurb,"info"
      else
        display_status,display_kind=pane_default_context(app_state.active_view),"info"
      end
    else
      display_status,display_kind=pane_default_context(app_state.active_view),"info"
    end
  end
  return display_status,display_kind
end

function preview_rows(plan)
  local rows={}
  if not plan then return rows end
  rows[#rows+1]={row="AUTO",section=COUNT_IN.name.."  •  "..format_bpm(plan.count_in_bpm).." BPM",part=COUNT_IN.name,bars=tostring(COUNT_IN.bars),meter=string.format("%d/%d",COUNT_IN.numerator,COUNT_IN.denominator),base_bpm=format_bpm(plan.count_in_bpm),reaper_bpm=format_effective_bpm(plan.count_in_bpm),ramp="No",start=tostring(COUNT_IN.visible_measure),next=tostring(START_VISIBLE_MEASURE),internal_measure_index=plan.count_in_internal_measure_index,source="AUTO COUNT-IN",section_row=plan.count_in_source_row,section_bpm=plan.count_in_bpm,section_name=plan.count_in_source_section,section_index=1,is_count_in=true,plain_english=string.format("Automatic count-in: %s of %d/%d at %s BPM. The song begins at measure %d.",bar_count_phrase(COUNT_IN.bars),COUNT_IN.numerator,COUNT_IN.denominator,format_bpm(plan.count_in_bpm),START_VISIBLE_MEASURE),details=string.format("Automatically generated count-in\nMarker: %s\nBars: %d\nMeter: %d/%d\nBPM source: spreadsheet row %d, section %s, BPM column %.2f\nFirst musical part: %s\nFirst part underlying BPM: %.2f\nFirst part effective REAPER BPM: %.2f\nStart measure: %d\nSong begins: measure %d",COUNT_IN.name,COUNT_IN.bars,COUNT_IN.numerator,COUNT_IN.denominator,plan.count_in_source_row or 0,plan.count_in_source_section or "",plan.count_in_bpm,plan.first_part_canonical or "",plan.first_part_underlying_bpm or plan.count_in_bpm,plan.first_part_effective_bpm or plan.count_in_bpm,COUNT_IN.visible_measure,START_VISIBLE_MEASURE)}
  local flat_index=0
  for _,section in ipairs(plan.sections) do
    for i,part in ipairs(section.parts) do
      flat_index=flat_index+1
      local next_part=plan.flat_parts and plan.flat_parts[flat_index+1] or nil
      local display_part=part_display_label(part)
      local ramp_label="No"
      if part.ramp_suppressed then ramp_label="Inactive at final block boundary"
      elseif part.ramp then ramp_label=(part.ramp_bars == 1 and "Last bar" or ("Last "..part.ramp_bars.." bars")).." -> "..format_effective_bpm(part.ramp_target_bpm) end
      local detail_lines={
        "Spreadsheet row: "..section.row,
        "Section: "..section.name,
        "Original part: "..tostring(part.source),
        "Normalized: "..part.canonical
      }
      if part.block_repeat_index then
        detail_lines[#detail_lines+1]=string.format("Block pass: %d/%d",part.block_repeat_index,part.block_repeat_total)
        detail_lines[#detail_lines+1]=string.format("Part within block: %d/%d",part.block_part_index,part.block_part_total)
        detail_lines[#detail_lines+1]="Original block: "..tostring(part.block_source)
      end
      detail_lines[#detail_lines+1]="Bars: "..part.repeats
      detail_lines[#detail_lines+1]=string.format("Meter: %d/%d",part.numerator,part.denominator)
      detail_lines[#detail_lines+1]=string.format("Underlying BPM: %.2f",part.underlying_bpm)
      detail_lines[#detail_lines+1]=string.format("Effective REAPER BPM: %.2f",part.effective_bpm)
      detail_lines[#detail_lines+1]="Click accent pattern: "..(part.no_accent and "No accent (all A clicks)" or "Normal (A first beat, B remaining beats)")
      detail_lines[#detail_lines+1]="Start measure: "..part.start_visible_measure
      detail_lines[#detail_lines+1]="Next measure: "..part.next_visible_measure
      if part.ramp_suppressed then
        detail_lines[#detail_lines+1]=string.format("Gradual transition: Inactive at final block boundary (declared %d %s)",part.declared_ramp_bars or 0,(part.declared_ramp_bars or 0)==1 and "dash" or "dashes")
        detail_lines[#detail_lines+1]="The final internal ramp never escapes the block. The following outside part or section starts with a hard tempo change."
      elseif part.ramp then
        detail_lines[#detail_lines+1]="Gradual transition: Yes, final "..part.ramp_bars..(part.ramp_bars == 1 and " bar" or " bars")
        detail_lines[#detail_lines+1]="Ramp begins at measure: "..part.ramp_start_visible_measure
        detail_lines[#detail_lines+1]="Ramp destination: "..format_effective_bpm(part.ramp_target_bpm).." BPM"
      else
        detail_lines[#detail_lines+1]="Gradual transition: No"
      end
      rows[#rows+1]={
        row=tostring(section.row),section=i==1 and (section.name.."  •  "..format_bpm(section.bpm).." BPM") or ("↳  "..format_bpm(section.bpm).." BPM"),part=display_part,bars=tostring(part.repeats),
        meter=string.format("%d/%d",part.numerator,part.denominator),base_bpm=format_bpm(part.underlying_bpm),
        reaper_bpm=format_effective_bpm(part.effective_bpm),ramp=ramp_label,
        start=tostring(part.start_visible_measure),next=tostring(part.next_visible_measure),ramp_start=part.ramp_start_visible_measure and tostring(part.ramp_start_visible_measure) or nil,internal_measure_index=part.internal_measure_index,ramp_internal_measure_index=part.ramp_internal_measure_index,source=part.source,canonical=part.canonical,block_source=part.block_source,section_name=section.name,section_row=section.row,section_bpm=section.bpm,section_index=section.section_index,item_index=part.item_index,block_part_index=part.block_part_index,part_index=part.part_index,
        no_accent=part.no_accent,part_object=part,
        plain_english=preview_part_plain_english(part,section,next_part),
        details=table.concat(detail_lines,"\n")
      }
    end
  end
  rows[#rows+1]={row=tostring(plan.end_row),section="END  •  "..format_bpm(plan.end_effective_bpm).." BPM",part="END",bars="0",meter="1/4",base_bpm=plan.end_bpm_entered and format_bpm(plan.end_bpm_entered) or "blank",reaper_bpm=format_effective_bpm(plan.end_effective_bpm),ramp="N/A",start=tostring(plan.end_visible_measure),next=tostring(plan.end_visible_measure),source="END",is_end=true,plain_english=string.format("END at measure %d: 1/4 at %s BPM. END adds no musical bar.",plan.end_visible_measure,format_bpm(plan.end_effective_bpm)),details=string.format("END row: %d\nTime signature: 1/4\nEffective BPM: %.2f\nEND BPM cell: %s\nPosition: measure %d",plan.end_row,plan.end_effective_bpm,plan.end_bpm_entered and format_bpm(plan.end_bpm_entered) or "blank",plan.end_visible_measure)}
  return rows
end

function refresh_staged_row_changes()
  state.staged_changed_rows={}
  state.staged_change_details={}
  if not state.base_plan or not state.plan then return end
  local workbook_rows=preview_rows(state.base_plan)
  local staged_rows=state.preview_rows or preview_rows(state.plan)
  for index=1,math.max(#workbook_rows,#staged_rows) do
    local workbook_row,staged_row=workbook_rows[index],staged_rows[index]
    local changes={}
    if not workbook_row or not staged_row then
      changes[#changes+1]="Row structure differs from the current workbook."
    else
      for _,field in ipairs({
        {key="base_bpm",label="Underlying BPM"},
        {key="reaper_bpm",label="Calculated REAPER BPM"},
        {key="ramp",label="Ramp"}
      }) do
        local before=tostring(workbook_row[field.key] or "")
        local after=tostring(staged_row[field.key] or "")
        if before~=after then changes[#changes+1]=field.label..": workbook "..before.." -> staged "..after end
      end
    end
    if #changes>0 then
      state.staged_changed_rows[index]=true
      state.staged_change_details[index]=table.concat(changes,"; ")
    end
  end
end

function row_original_syntax(row)
  if not row then return nil end
  local source=trim(row.source)
  if source~="" and source~="AUTO COUNT-IN" and source~="COUNT IN" and source~="END" then return source end
  if row.issue then
    local message=tostring(row.issue.message or "")
    return message:match("part%s+%d+%s+%('(.-)'%)") or message:match("PARTS%s+%('(.-)'%)")
  end
  return nil
end

function selected_preview_syntax(fallback_row)
  if fallback_row and fallback_row.issue then
    local syntax=row_original_syntax(fallback_row);return syntax,syntax and 1 or 0
  end
  local first,last=selected_preview_range()
  local rows=state.preview_rows or {};local parts={}
  if first and last then
    for index=first,last do
      local syntax=row_original_syntax(rows[index])
      if syntax then parts[#parts+1]=syntax end
    end
  else
    local syntax=row_original_syntax(fallback_row)
    if syntax then parts[1]=syntax end
  end
  return #parts>0 and table.concat(parts,", ") or nil,#parts
end

function preview_row_full_readout(row)
  if not row then return "No Preview row is selected." end
  if row.issue then return validation_issue_summary(row.issue) end
  local lines={preview_row_blurb(row) or "No plain-English explanation is available for this row."}
  local start_measure=tonumber(row.start);local next_measure=tonumber(row.next)
  if start_measure and next_measure and next_measure>start_measure and tostring(row.source or "")~="END" then
    lines[#lines+1]=string.format("It occupies measure%s %d through %d.",next_measure-start_measure==1 and "" or "s",start_measure,next_measure-1)
  end
  if tonumber(row.row) and trim(row.section_name or row.section)~="" then
    lines[#lines+1]=string.format("It comes from spreadsheet row %s in section %s.",tostring(row.row),trim(row.section_name or row.section))
  end
  return table.concat(lines," ")
end

function normalized_parts_expression(parts,blocks)
  local items,seen={},{}
  for _,part in ipairs(parts or {}) do
    local key=part.block_index and ("B"..tostring(part.block_index)) or ("P"..tostring(part.item_index or #items+1))
    if not seen[key] then
      local value=part.canonical
      if part.block_index and blocks and blocks[part.block_index] then value=blocks[part.block_index].canonical end
      items[#items+1]=tostring(value or part.source or "")
      seen[key]=true
    end
  end
  return table.concat(items,", ")
end

function part_meter_syntax(part)
  if part.kind=="quarter" then return "["..part.numerator.."]" end
  if part.kind=="eighth" then return "("..part.numerator..")" end
  if part.kind=="sixteenth" then return "{"..part.numerator.."}" end
  if part.kind=="thirty_second" then return "*"..part.numerator.."*" end
  if part.kind=="eighth_triplet" then return "ENT("..part.numerator..")" end
  if part.kind=="sextuplet" then return "SXT{"..part.numerator.."}" end
  if part.kind=="quintuplet" then return "QNT{"..part.numerator.."}" end
  if part.kind=="septuplet" then return "SPT{"..part.numerator.."}" end
  return tostring(part.canonical or part.source or "")
end

function canonical_part_with_underlying_bpm(part,new_bpm,section_bpm)
  local value=part_meter_syntax(part)
  if (part.repeats or 1)~=1 then value=value.."x"..tostring(part.repeats) end
  if new_bpm and not nearly_equal(new_bpm,section_bpm,1e-9) then value=value.."@"..format_bpm(new_bpm) end
  local ramp_bars=part.declared_ramp_bars or part.ramp_bars or 0
  if ramp_bars>0 then value=value..string.rep("-",ramp_bars) end
  return value
end

function rewrite_part_bpm_in_expression(parts_text,section_bpm,item_index,block_part_index,new_bpm)
  local items,split_err=split_parts(parts_text)
  if not items then return nil,split_err end
  local source=items[item_index]
  if not source then return nil,"The selected Part source could not be found in its worksheet cell." end
  if block_part_index then
    local body,suffix=source:match("^%s*<(.*)>%s*(.-)%s*$")
    if not body then return nil,"The selected Block source could not be reconstructed." end
    local inner,inner_err=split_parts(body)
    if not inner then return nil,inner_err end
    local target=inner[block_part_index]
    if not target then return nil,"The selected Part could not be found inside its Block." end
    local parsed,parse_err=parse_part(target,section_bpm)
    if not parsed then return nil,parse_err end
    inner[block_part_index]=canonical_part_with_underlying_bpm(parsed,new_bpm,section_bpm)
    items[item_index]="<"..table.concat(inner,", ")..">"..trim(suffix)
  else
    local parsed,parse_err=parse_part(source,section_bpm)
    if not parsed then return nil,parse_err end
    items[item_index]=canonical_part_with_underlying_bpm(parsed,new_bpm,section_bpm)
  end
  return table.concat(items,", ")
end

function rewrite_section_overrides(parts_text,old_bpm,new_bpm,shift_overrides,first_section)
  local items,split_err=split_parts(parts_text)
  if not items then return nil,split_err end
  local delta=new_bpm-old_bpm
  local source_part_number=0
  local function rewrite_source(source)
    source_part_number=source_part_number+1
    local parsed,parse_err=parse_part(source,old_bpm)
    if not parsed then return nil,parse_err end
    if not parsed.has_override then return source end
    if first_section and source_part_number==1 and nearly_equal(parsed.underlying_bpm,old_bpm,1e-9) then
      return canonical_part_with_underlying_bpm(parsed,nil,new_bpm)
    end
    if shift_overrides then
      local shifted=parsed.underlying_bpm+delta
      if shifted<=0 then return nil,"The Section change would make a modified Part BPM zero or negative." end
      return canonical_part_with_underlying_bpm(parsed,shifted,new_bpm)
    end
    return source
  end
  for item_index,source in ipairs(items) do
    if source:find("<",1,true) or source:find(">",1,true) then
      local body,suffix=source:match("^%s*<(.*)>%s*(.-)%s*$")
      if not body then return nil,"A Block source could not be reconstructed while changing the Section BPM." end
      local inner,inner_err=split_parts(body)
      if not inner then return nil,inner_err end
      for inner_index,inner_source in ipairs(inner) do
        local rewritten,rewrite_err=rewrite_source(inner_source)
        if not rewritten then return nil,rewrite_err end
        inner[inner_index]=rewritten
      end
      items[item_index]="<"..table.concat(inner,", ")..">"..trim(suffix)
    else
      local rewritten,rewrite_err=rewrite_source(source)
      if not rewritten then return nil,rewrite_err end
      items[item_index]=rewritten
    end
  end
  return table.concat(items,", ")
end

function section_for_row(plan,row_number)
  for _,section in ipairs((plan and plan.sections) or {}) do if section.row==tonumber(row_number) then return section end end
  return nil
end

function base_section_for_row(row_number)
  return section_for_row(state and state.base_plan,row_number)
end

function format_section_bpm_cell(bpm,no_accent)
  return format_bpm(bpm)..(no_accent and " no accent" or "")
end

function tempo_part_key(item_index,block_part_index)
  return tostring(item_index or 0)..":"..tostring(block_part_index or 0)
end

function source_parts_for_section(section)
  local result,seen={},{}
  for _,part in ipairs((section and section.parts) or {}) do
    local key=tempo_part_key(part.item_index,part.block_part_index)
    if not seen[key] then
      seen[key]=true
      result[#result+1]={key=key,part=part}
    end
  end
  table.sort(result,function(a,b)
    local ai,bi=tonumber(a.part.item_index) or 0,tonumber(b.part.item_index) or 0
    if ai~=bi then return ai<bi end
    return (tonumber(a.part.block_part_index) or 0)<(tonumber(b.part.block_part_index) or 0)
  end)
  return result
end

function natural_part_bpm_for_edit(base_section,entry,source_part,staged_section_bpm,is_first_source)
  if base_section.section_index==1 and is_first_source then
    return staged_section_bpm
  end
  local delta=staged_section_bpm-base_section.bpm
  if entry.section_shift_overrides and source_part.has_override then return source_part.underlying_bpm+delta end
  if source_part.has_override then return source_part.underlying_bpm end
  return staged_section_bpm
end

function compose_tempo_edit_row(candidate,row)
  local base=base_section_for_row(row)
  local entry=candidate and candidate.rows and candidate.rows[row]
  if not base or not entry then return true end
  entry.part_bpms=entry.part_bpms or {}
  local staged_bpm=base.bpm
  if entry.bpm_text~=nil then
    local parsed,_,parse_error=parse_section_bpm_cell(entry.bpm_text)
    if not parsed then return nil,parse_error end
    staged_bpm=parsed
  end
  local section_changed=not nearly_equal(staged_bpm,base.bpm,1e-9)
  if not section_changed then entry.section_shift_overrides=false end
  local rewritten=base.parts_text
  for source_index,source in ipairs(source_parts_for_section(base)) do
    local part,key=source.part,source.key
    local manual=entry.part_bpms[key]
    local target=manual
    if target==nil and entry.section_shift_overrides and section_changed and part.has_override then
      target=part.underlying_bpm+(staged_bpm-base.bpm)
    elseif target==nil and base.section_index==1 and source_index==1
      and section_changed and part.has_override and nearly_equal(part.underlying_bpm,base.bpm,1e-9) then
      target=staged_bpm
    end
    if target~=nil then
      if target<=0 then return nil,"The Section change would make a modified Part BPM zero or negative." end
      local next_text,rewrite_error=rewrite_part_bpm_in_expression(rewritten,staged_bpm,part.item_index,part.block_part_index,target)
      if not next_text then return nil,rewrite_error end
      rewritten=next_text
    end
  end
  entry.parts_text=rewritten~=base.parts_text and rewritten or nil
  return true
end

function normalize_tempo_edit_row(candidate,row)
  local base=base_section_for_row(row)
  local entry=candidate.rows[row]
  if not base or not entry then return end
  if entry.bpm_text==base.bpm_text then entry.bpm_text=nil end
  if entry.parts_text==base.parts_text then entry.parts_text=nil end
  local part_bpms=entry.part_bpms or {}
  if next(part_bpms)==nil then entry.part_bpms=nil end
  if entry.bpm_text==nil then entry.section_shift_overrides=false end
  if entry.bpm_text==nil and entry.parts_text==nil then candidate.rows[row]=nil end
end

function refresh_staged_plan(plan)
  state.plan=plan
  state.preview_rows=preview_rows(plan)
  refresh_staged_row_changes()
  clear_preview_selection()
  state.preview_vscroll=0
  local project=get_active_project_info()
  if project and state.validation_project and project.pointer==state.validation_project.pointer then
    state.dry_run=collect_project_snapshot(project.proj,plan)
    state.dry_run_stale=state.dry_run==nil
    state.audio_tempo_analysis=state.dry_run and analyze_audio_tempo_handling(project.proj,plan,state.dry_run) or nil
    if state.audio_tempo_mode==AUDIO_MODE_CONFORM and state.audio_tempo_analysis and not state.audio_tempo_analysis.conform_allowed then state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=analyze_audio_tempo_handling(project.proj,plan,state.dry_run) end
  else
    state.dry_run=nil
    state.dry_run_stale=true
    state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil
  end
end

function commit_tempo_edit(candidate,description,log_entry)
  local plan,errors=rebuild_plan_from_tempo_edits(state.base_plan,candidate)
  if not plan then
    local message=table.concat(errors or {"The staged tempo edit could not be validated."},"\n")
    set_status("Tempo edit rejected: "..message,"error")
    show_info("Tempo Edit Could Not Be Applied","[EDT-001] The proposed tempo edit did not pass the production parser. No staged values were changed.\n\n"..message,"error")
    return false
  end
  state.tempo_edit_history[#state.tempo_edit_history+1]=clone_tempo_edits(state.tempo_edits)
  if #state.tempo_edit_history>100 then table.remove(state.tempo_edit_history,1) end
  state.tempo_edits=clone_tempo_edits(candidate)
  state.tempo_edit_log[#state.tempo_edit_log+1]=log_entry or description
  refresh_staged_plan(tempo_edits_empty(candidate) and state.base_plan or plan)
  state.suppress_tempo_recovery=false
  local recovery_ok,recovery_err=persist_tempo_edit_recovery()
  if not recovery_ok then
    state.tempo_edit_log[#state.tempo_edit_log+1]="[REC-003] Tempo recovery could not be written: "..tostring(recovery_err)
    show_info("Tempo Recovery Could Not Be Saved","[REC-003] The BPM edit is staged in this running app session, but its crash-recovery record could not be written. Save an updated workbook copy before closing if you need to preserve the edit.\n\n"..tostring(recovery_err),"warning")
  end
  set_status(description.." The Preview, Ramps, durations, readouts, and calculated REAPER BPM were refreshed.","success")
  return true
end

function preview_tempo_values_differ(a,b)
  if not a or not b then return a~=b end
  for _,key in ipairs({"base_bpm","reaper_bpm","ramp"}) do
    if tostring(a[key] or "")~=tostring(b[key] or "") then return true end
  end
  return false
end

function tempo_edit_units(edits)
  local units={}
  local rows={};for row in pairs((edits and edits.rows) or {}) do rows[#rows+1]=row end;table.sort(rows)
  for _,row in ipairs(rows) do
    local entry=edits.rows[row]
    if entry.bpm_text~=nil then units[#units+1]={kind="section",row=row,key="section:"..row} end
    local part_keys={};for key in pairs(entry.part_bpms or {}) do part_keys[#part_keys+1]=key end;table.sort(part_keys)
    for _,key in ipairs(part_keys) do units[#units+1]={kind="part",row=row,part_key=key,key="part:"..row..":"..key} end
    if entry.parts_text~=nil and entry.bpm_text==nil and #part_keys==0 then units[#units+1]={kind="legacy_parts",row=row,key="legacy:"..row} end
  end
  if edits and edits.end_bpm_set then units[#units+1]={kind="end",row=state.base_plan and state.base_plan.end_row or 0,key="end"} end
  return units
end

function remove_tempo_edit_unit(candidate,unit)
  if unit.kind=="end" then candidate.end_bpm_set=false;candidate.end_bpm_text="";return true end
  local entry=candidate.rows[unit.row]
  if not entry then return true end
  if unit.kind=="section" then
    entry.bpm_text=nil;entry.section_shift_overrides=false
  elseif unit.kind=="part" then
    entry.part_bpms=entry.part_bpms or {};entry.part_bpms[unit.part_key]=nil
  elseif unit.kind=="legacy_parts" then
    entry.parts_text=nil;entry.part_bpms=nil
  end
  local composed,compose_error=compose_tempo_edit_row(candidate,unit.row)
  if not composed then return nil,compose_error end
  normalize_tempo_edit_row(candidate,unit.row)
  return true
end

function selected_revert_available()
  if tempo_edits_empty(state.tempo_edits) then return false,"No staged tempo differences exist." end
  local first,last=selected_preview_range()
  if not first then return false,"Select a yellow changed Preview row first." end
  for index=first,last do if state.staged_changed_rows and state.staged_changed_rows[index] then return true,"Available" end end
  return false,"The selected Preview row already matches the loaded workbook."
end

function selected_revert_candidate(first,last)
  local units=tempo_edit_units(state.tempo_edits)
  local selected={};for index=first,last do if state.staged_changed_rows and state.staged_changed_rows[index] then selected[#selected+1]=index end end
  if #selected==0 then return nil,nil,nil,"The selected Preview rows already match the loaded workbook." end
  local wanted={}
  local function want(unit) if unit then wanted[unit.key]=unit end end
  local by_key={};for _,unit in ipairs(units) do by_key[unit.key]=unit end

  for _,index in ipairs(selected) do
    local row=state.preview_rows[index]
    if row and row.is_end then want(by_key["end"])
    elseif row and row.section_row then
      local entry=state.tempo_edits.rows[row.section_row]
      local base_section=base_section_for_row(row.section_row)
      if entry and base_section then
        if row.is_count_in then want(by_key["section:"..row.section_row])
        elseif row.item_index then
          local part_key=tempo_part_key(row.item_index,row.block_part_index)
          local manual=(entry.part_bpms or {})[part_key]~=nil
          if manual then want(by_key["part:"..row.section_row..":"..part_key]) end
          local base_source,source_index=nil,nil
          for source_i,source in ipairs(source_parts_for_section(base_section)) do if source.key==part_key then base_source=source.part;source_index=source_i;break end end
          local section_affects=entry.bpm_text~=nil and base_source and (
            not base_source.has_override or entry.section_shift_overrides or (base_section.section_index==1 and source_index==1)
          )
          if section_affects then want(by_key["section:"..row.section_row]) end
        end
      end
    end
  end

  -- A selected Ramp row can differ because its destination row was edited. Include
  -- any additional edit unit whose removal changes the selected row's tempo fields.
  for _,unit in ipairs(units) do
    if not wanted[unit.key] then
      local trial=clone_tempo_edits(state.tempo_edits)
      local removed=remove_tempo_edit_unit(trial,unit)
      if removed then
        local trial_plan=rebuild_plan_from_tempo_edits(state.base_plan,trial)
        if trial_plan then
          local trial_rows=preview_rows(trial_plan)
          for _,index in ipairs(selected) do
            if preview_tempo_values_differ(state.preview_rows[index],trial_rows[index]) then want(unit);break end
          end
        end
      end
    end
  end

  local relevant={};for _,unit in ipairs(units) do if wanted[unit.key] then relevant[#relevant+1]=unit end end
  if #relevant==0 then return nil,nil,nil,"No staged Section, Part, or END tempo edit could be associated with the selected changed row." end
  local candidate=clone_tempo_edits(state.tempo_edits)
  for _,unit in ipairs(relevant) do local ok,remove_error=remove_tempo_edit_unit(candidate,unit);if not ok then return nil,nil,nil,remove_error end end
  local plan,errors=rebuild_plan_from_tempo_edits(state.base_plan,candidate)
  if not plan then return nil,nil,nil,table.concat(errors or {"The workbook values could not be reconstructed."},"\n") end
  local candidate_rows=preview_rows(plan);local affected=0
  for index=1,math.max(#state.preview_rows,#candidate_rows) do if preview_tempo_values_differ(state.preview_rows[index],candidate_rows[index]) then affected=affected+1 end end
  return candidate,plan,{units=relevant,selected_count=#selected,affected_count=affected},nil
end

function revert_unit_description(unit)
  if unit.kind=="end" then
    local value=state.base_plan.end_bpm_entered and format_bpm(state.base_plan.end_bpm_entered).." BPM" or "blank (standard 25 BPM behavior)"
    return "END: restore the loaded workbook value "..value.."."
  end
  local base=base_section_for_row(unit.row);if not base then return "Spreadsheet row "..tostring(unit.row)..": restore its loaded workbook tempo." end
  if unit.kind=="section" then
    local entry=state.tempo_edits.rows[unit.row] or {};local extra=""
    if entry.section_shift_overrides then
      local count=unique_section_override_count(base)
      if count>0 then extra=string.format(" Its %d proportionally shifted explicit Part override%s will return to the loaded workbook values.",count,count==1 and "" or "s") end
    end
    return string.format("Section %s: restore %s BPM.%s Accent behavior remains %s.",base.name,format_bpm(base.bpm),extra,base.no_accent and "no accent" or "normal")
  end
  if unit.kind=="part" then
    local source_part=nil
    for _,source in ipairs(source_parts_for_section(base)) do if source.key==unit.part_key then source_part=source.part;break end end
    local value=source_part and (source_part.has_override and ("@"..format_bpm(source_part.underlying_bpm)) or ("inherited "..format_bpm(base.bpm).." BPM")) or "its loaded workbook value"
    return string.format("Part in %s: restore %s. Repeated and Block-expanded occurrences update together.",base.name,value)
  end
  return string.format("Spreadsheet row %d PARTS: restore the loaded workbook tempo syntax.",unit.row)
end

function revert_selected_tempo_edits()
  local available,reason=selected_revert_available();if not available then show_info("Revert Tempo Edit Unavailable",reason,"warning");return end
  local first,last=selected_preview_range()
  local candidate,plan,summary,revert_error=selected_revert_candidate(first,last)
  if not candidate then show_info("Revert Tempo Edit Failed","[EDT-005] "..tostring(revert_error),"error");return end
  local lines={}
  for _,unit in ipairs(summary.units) do lines[#lines+1]="- "..revert_unit_description(unit) end
  local noun=#summary.units==1 and "tempo edit" or "tempo edits"
  local message=string.format("Restore the selected changed Preview %s to the currently loaded and validated workbook?\n\n%s\n\nThis will update %d Preview %s. Base BPM, calculated REAPER BPM, Ramps, durations, readouts, auditions, and Scratchpad output will be recalculated. Accent behavior cannot be edited and will not change.\n\nThe workbook and REAPER project will not be changed by this action.",summary.selected_count==1 and "row" or "rows",table.concat(lines,"\n"),summary.affected_count,summary.affected_count==1 and "row" or "rows")
  show_confirm("Revert Tempo Edit",message,#summary.units==1 and "Revert Tempo Edit" or "Revert Tempo Edits","Cancel",function()
    local description=string.format("Reverted %d selected workbook %s; %d Preview %s refreshed.",#summary.units,noun,summary.affected_count,summary.affected_count==1 and "row was" or "rows were")
    local log_entry=string.format("REVERT TO LOADED WORKBOOK: %d source tempo %s across selected Preview rows %d-%d; accent behavior preserved",#summary.units,noun,first,last)
    if commit_tempo_edit(candidate,description,log_entry) and tempo_edits_empty(candidate) then state.tempo_edit_log={} end
  end,nil,"warning")
end

function evaluate_syntax_scratchpad(bpm_text,parts_text)
  local bpm,no_accent,bpm_error=parse_section_bpm_cell(bpm_text)
  if not bpm then
    local reference=identify_error_reference(bpm_error)
    return {ok=false,code=reference and reference.code or "SYN-001",message=bpm_error,readout=bpm_error..(reference and ("\n\nMost likely fix: "..tostring(reference.fix or "Enter a positive Section BPM.")) or "")}
  end
  if trim(parts_text)=="" then
    local message="Enter one PARTS expression to test."
    return {ok=false,code="SYN-001",message=message,readout=message}
  end
  local parts,blocks,parse_error=parse_parts_expression(parts_text,bpm)
  if not parts then
    local reference=identify_error_reference(parse_error)
    local compact=upper(parts_text):gsub("%s+","")
    local preferred=(compact:match("^ET") or compact:match("^QT") or compact:match("^ENT")) and "SYN-004" or compact:match("^SXT") and "SYN-005" or (compact:match("^QUINT") or compact:match("^QNT")) and "SYN-006" or (compact:match("^STP") or compact:match("^SPT")) and "SYN-023" or nil
    if preferred then reference=search_error_reference(preferred)[1] or reference end
    if not reference or reference.code=="UNK-001" then reference=search_error_reference("SYN-001")[1] end
    return {ok=false,code=reference and reference.code or "SYN-001",message=parse_error,readout=parse_error..(reference and ("\n\nMost likely fix: "..tostring(reference.fix or "Correct the expression and test it again.")) or "")}
  end
  local current_measure=1
  for _,part in ipairs(parts) do
    part.section_name="Scratchpad";part.no_accent=no_accent==true;part.start_visible_measure=current_measure;part.next_visible_measure=current_measure+part.repeats
    current_measure=part.next_visible_measure
  end
  for index,part in ipairs(parts) do
    local next_part=parts[index+1]
    if part.ramp and next_part then
      part.ramp_target_bpm=next_part.effective_bpm
      part.ramp_start_visible_measure=part.next_visible_measure-part.ramp_bars
    end
  end
  local readouts={}
  local section={name="Scratchpad",bpm=bpm,no_accent=no_accent==true}
  for index,part in ipairs(parts) do
    local next_part=parts[index+1]
    local readout
    if part.ramp and not next_part then
      local without_final_target=clone_part(part);without_final_target.ramp=false;without_final_target.ramp_bars=0
      readout=preview_part_plain_english(without_final_target,section,nil)
      readout=readout..string.format(" Its final %d %s form a valid ramp whose destination is supplied by the following workbook row or END BPM.",part.ramp_bars,part.ramp_bars==1 and "bar" or "bars")
    else
      readout=preview_part_plain_english(part,section,next_part)
    end
    readouts[#readouts+1]=string.format("%d. %s — %s",index,part_display_label(part),readout)
  end
  local normalized=normalized_parts_expression(parts,blocks)
  local summary=string.format("Valid: %d expanded part%s, %d block%s, %d musical bar%s.",#parts,#parts==1 and "" or "s",#blocks,#blocks==1 and "" or "s",current_measure-1,current_measure==2 and "" or "s")
  return {
    ok=true,code=nil,message=summary,normalized=normalized,parts=parts,blocks=blocks,bpm=bpm,no_accent=no_accent==true,
    readout=summary.."\nNormalized syntax: "..normalized.."\n\n"..table.concat(readouts,"\n")
  }
end

function preview_syntax_badges(row)
  local display=tostring(row and row.part or "")
  local syntax=display:match("^Block%s+%d+/%d+%s+—%s+(.*)$") or display
  local badges={}
  local block_pass,block_total=display:match("^Block%s+(%d+)/(%d+)")
  if syntax~=display then badges[#badges+1]=block_pass and ("Block Pass "..block_pass.." of "..block_total) or "Block" end
  if syntax:match("^%[") then badges[#badges+1]="Quarter Note"
  elseif syntax:match("^%(") then badges[#badges+1]="Eighth Note"
  elseif syntax:match("^{") then badges[#badges+1]="Sixteenth Note"
  elseif syntax:match("^%*") then badges[#badges+1]="Thirty-Second Note"
  elseif syntax:match("^ENT") then badges[#badges+1]="Eighth Note Triplet"
  elseif syntax:match("^SXT") then badges[#badges+1]="Sextuplet"
  elseif syntax:match("^QNT%{") then badges[#badges+1]="Quintuplet"
  elseif syntax:match("^SPT%{") then badges[#badges+1]="Septuplet" end
  local repeats=syntax:match("[xX](%d+)");if repeats then badges[#badges+1]="Repeat x"..repeats end
  local override=syntax:match("@([%d%.]+)");if override then badges[#badges+1]="BPM Override: "..override end
  local dash=syntax:match("(%-+)%s*$")
  if row and row.ramp=="Inactive at final block boundary" and dash then badges[#badges+1]="Ramp Inactive"
  elseif dash then badges[#badges+1]=#dash==1 and "Ramp: 1 Bar" or ("Ramp: "..#dash.." Bars") end
  if row and row.no_accent then badges[#badges+1]="No Accent" end
  return badges
end

function project_snapshot_lines(s)
  if not s then return {"Comparison unavailable."} end
  local mc=s.net_marker_counts or {unchanged=0,changed=0,added=0,removed=0}
  local tc=s.net_tempo_counts or {unchanged=0,changed=0,added=0,removed=0}
  local lines={
    "BUILD PREVIEW - VALIDATION ONLY / NO PROJECT CHANGES",
    "====================================================",
    "",
    "SUMMARY",
    "-------",
    "Tracks: "..s.tracks,
    "Media items: "..s.media_items,
    "Project length before build (seconds): "..string.format("%.3f",s.project_length or 0),
    "Regions preserved: "..s.regions_preserved,
    string.format("Automatic count-in: visible measures %d-%d, %d/%d at %.2f BPM",COUNT_IN.visible_measure,START_VISIBLE_MEASURE-1,COUNT_IN.numerator,COUNT_IN.denominator,s.plan_count_in_bpm or 0),
    string.format("Count-in BPM source: spreadsheet row %s, section %s",tostring(s.count_in_source_row or ""),tostring(s.count_in_source_section or "")),
    string.format("First musical part: %s; underlying %.2f BPM; effective REAPER %.2f BPM",tostring(s.first_part_canonical or ""),s.first_part_underlying_bpm or 0,s.first_part_effective_bpm or 0),
    string.format("Duration: %s musical content; %s including COUNT IN",format_duration(s.total_duration or 0),format_duration(s.total_duration_with_count_in or 0)),
    string.format("Planned synthesized click frequencies: A %d Hz; B %d Hz",s.click_a_hz or DEFAULT_CLICK_A_HZ,s.click_b_hz or DEFAULT_CLICK_B_HZ),
    "Planned REAPER metronome state after verified build: Enabled",
    "Spreadsheet song start: visible measure "..START_VISIBLE_MEASURE,
    "Planned END: visible measure "..tostring(START_VISIBLE_MEASURE + (s.end_internal_measure-s.start.measure_index)),
    "This preview was calculated without adding, deleting, or moving project data.",
    "",
    "SECTION MEASURE RANGES"
  }
  if #(s.section_range_details or {})==0 then lines[#lines+1]="(none)" else for _,v in ipairs(s.section_range_details) do lines[#lines+1]="- "..v end end
  lines[#lines+1]="";lines[#lines+1]="PART MEASURE RANGES"
  if #(s.part_range_details or {})==0 then lines[#lines+1]="(none)" else for _,v in ipairs(s.part_range_details) do lines[#lines+1]="- "..v end end
  lines[#lines+1]="";lines[#lines+1]="WARNINGS AND ASSUMPTIONS"
  lines[#lines+1]="- Standard project markers are replaceable build output; regions are preserved."
  lines[#lines+1]="- Tempo/time-signature markers from visible measure 1 onward are replaceable build output."
  lines[#lines+1]="- Tempo data before visible measure 1 is preserved."
  lines[#lines+1]="- The workbook and active project must remain unchanged until the final build confirmation."
  if (s.media_items or 0)>0 then lines[#lines+1]=string.format("- WARNING: %d media item%s may react to tempo-map rebuilding according to project and item timebase settings.",s.media_items,s.media_items==1 and "" or "s") else lines[#lines+1]="- No media items were present when this preview was calculated." end
  lines[#lines+1]="";lines[#lines+1]="BUILD OPERATIONS";lines[#lines+1]="----------------"
  lines[#lines+1]="Standard project markers to delete: "..s.markers_to_delete
  lines[#lines+1]="Tempo/time-signature markers to delete from visible measure "..COUNT_IN.visible_measure..": "..s.tempo_to_delete
  lines[#lines+1]="Standard project markers to create: "..s.new_markers
  lines[#lines+1]="Tempo/time-signature markers to create: "..s.new_tempo
  lines[#lines+1]="Regions are preserved and are not modified."
  lines[#lines+1]="";lines[#lines+1]="EXISTING STANDARD MARKERS TO DELETE"
  if #(s.existing_marker_details or {})==0 then lines[#lines+1]="(none)" else for _,v in ipairs(s.existing_marker_details) do lines[#lines+1]="- "..v end end
  lines[#lines+1]="";lines[#lines+1]="EXISTING TEMPO/TIME-SIGNATURE MARKERS TO DELETE"
  if #(s.existing_tempo_details or {})==0 then lines[#lines+1]="(none)" else for _,v in ipairs(s.existing_tempo_details) do lines[#lines+1]="- "..v end end
  lines[#lines+1]="";lines[#lines+1]="NEW STANDARD PROJECT MARKERS"
  for _,v in ipairs(s.new_marker_details or {}) do lines[#lines+1]="- "..v end
  lines[#lines+1]="";lines[#lines+1]="NEW TEMPO/TIME-SIGNATURE MARKERS"
  for _,v in ipairs(s.new_tempo_details or {}) do lines[#lines+1]="- "..v end
  lines[#lines+1]="";lines[#lines+1]="NET RESULT"
  lines[#lines+1]="----------"
  lines[#lines+1]=string.format("Markers: %d unchanged, %d changed, %d added, %d removed",mc.unchanged,mc.changed,mc.added,mc.removed)
  lines[#lines+1]=string.format("Tempo map: %d unchanged, %d changed, %d added, %d removed",tc.unchanged,tc.changed,tc.added,tc.removed)
  lines[#lines+1]=""
  lines[#lines+1]="NET MARKER RESULT"
  if #(s.net_marker_lines or {})==0 then lines[#lines+1]="(none)" else for _,v in ipairs(s.net_marker_lines) do lines[#lines+1]="- "..v end end
  lines[#lines+1]="";lines[#lines+1]="NET TEMPO/TIME-SIGNATURE RESULT"
  if #(s.net_tempo_lines or {})==0 then lines[#lines+1]="(none)" else for _,v in ipairs(s.net_tempo_lines) do lines[#lines+1]="- "..v end end
  return lines
end

function project_snapshot_text(s)
  return table.concat(project_snapshot_lines(s),"\n")
end

function build_log_content(attempt,status,details)
  local plan=attempt.plan
  local p=attempt.project
  local lines={
    "SONG STRUCTURE BUILDER ATTEMPT LOG",
    "==================================",
    "BUILD ID: "..attempt.id,
    "TIMESTAMP: "..attempt.timestamp,
    "STATUS: "..status,
    "ACTION: "..(attempt.action or "BUILD SONG STRUCTURE"),
    "SCRIPT VERSION: "..SCRIPT_VERSION,
    "MADE BY: "..MADE_BY,
    "",
    "PROJECT",
    "-------",
    "Project name: "..tostring(p and p.name or ""),
    "Project path: "..tostring(p and p.path or ""),
    "Project pointer: "..tostring(p and p.pointer or ""),
    "Project tab position: "..tostring(p and p.tab_index or ""),
    "Pre-build REAPER save choice: "..(attempt.prebuild_saved_copy and "SEPARATE .RPP COPY SAVED" or attempt.prebuild_skipped and "CONTINUED WITHOUT A NEW SAVE" or "NOT APPLICABLE"),
    "Pre-build saved .RPP path: "..tostring(attempt.prebuild_saved_path or ""),
    "Post-build save policy: a verified build opens explicit completed REAPER project save choices.",
    "",
    "SOURCE",
    "------",
    "Spreadsheet path: "..tostring(plan and plan.file_path or ""),
    "Worksheet: "..tostring(plan and plan.sheet_name or ""),
    "Source SHA-256: "..tostring(plan and plan.source_sha256 or ""),
    "Plan SHA-256: "..tostring(plan and plan.plan_sha256 or ""),
    "Plan short hash: "..tostring(plan and plan.plan_hash_short or ""),
    "Validated timestamp: "..tostring(attempt.validated_timestamp or ""),
    "Workbook reminder: Only saved spreadsheet changes were read.",
    "Build notes: "..tostring(attempt.notes or ""),
    "Staged tempo edits: "..tostring(attempt.tempo_edit_log and #attempt.tempo_edit_log or 0),
    "Audio handling mode: "..(attempt.audio_mode==AUDIO_MODE_CONFORM and "CONFORM AUDIO TO NEW TEMPO - PRESERVE PITCH" or "PRESERVE AUDIO EXACTLY"),
    "Audio handling summary: "..tostring(attempt.audio_result_summary or (attempt.audio_analysis and attempt.audio_analysis.summary) or "Not yet analyzed"),
    "Audio items detected: "..tostring(attempt.audio_analysis and attempt.audio_analysis.audio_items or 0),
    "Audio items eligible to conform: "..tostring(attempt.audio_analysis and attempt.audio_analysis.eligible_items or 0),
    "Audio items outside the structured range: "..tostring(attempt.audio_analysis and attempt.audio_analysis.unaffected_items or 0),
    "Audio structural eligibility: "..tostring(attempt.audio_analysis and (attempt.audio_analysis.conform_allowed and "PASSED" or "BLOCKED") or "Not calculated"),
    "Preflight: "..tostring(attempt.preflight_summary or "Not yet run"),
    "Transaction policy: one REAPER undo block; failed builds require marker/tempo and audio rollback-signature verification.",
    "",
    "SUMMARY",
    "-------",
    "Sections: "..tostring(plan and #plan.sections or 0),
    "Blocks: "..tostring(plan and plan.block_count or 0),
    "Block passes: "..tostring(plan and plan.block_passes or 0),
    "Expanded part occurrences: "..tostring(plan and #plan.flat_parts or 0),
    "Musical bars: "..tostring(plan and plan.total_bars or 0),
    "Primary A click frequency: "..tostring(attempt.click_a_hz or DEFAULT_CLICK_A_HZ).." Hz",
    "Secondary B click frequency: "..tostring(attempt.click_b_hz or DEFAULT_CLICK_B_HZ).." Hz",
    "Verified-build metronome state: ENABLED (failed build and Undo restore the pre-build state)",
    "COUNT IN marker: visible measure "..COUNT_IN.visible_measure,
    "COUNT IN length: "..COUNT_IN.bars.." bars",
    "COUNT IN meter: "..COUNT_IN.numerator.."/"..COUNT_IN.denominator,
    "COUNT IN BPM: "..tostring(plan and format_effective_bpm(plan.count_in_bpm) or ""),
    "COUNT IN BPM source row: "..tostring(plan and plan.count_in_source_row or ""),
    "COUNT IN BPM source section: "..tostring(plan and plan.count_in_source_section or ""),
    "COUNT IN BPM source: first musical row's section-level BPM column",
    "First musical part: "..tostring(plan and plan.first_part_canonical or ""),
    "First part underlying BPM: "..tostring(plan and format_effective_bpm(plan.first_part_underlying_bpm) or ""),
    "First part effective REAPER BPM: "..tostring(plan and format_effective_bpm(plan.first_part_effective_bpm) or ""),
    "First-part @BPM consistency validation: PASSED",
    "Reserved section-name validation: PASSED (COUNT IN is automatic only)",
    "Spreadsheet song start measure: "..START_VISIBLE_MEASURE,
    "END measure: "..tostring(plan and plan.end_visible_measure or ""),
    "END effective BPM: "..tostring(plan and format_effective_bpm(plan.end_effective_bpm) or ""),
    "Musical-content duration: "..tostring(plan and format_duration(plan.total_duration) or "" ),
    "Duration including count-in: "..tostring(plan and format_duration(plan.total_duration_with_count_in) or "" ),
    "",
    "PRE-BUILD PROJECT STATE / DRY RUN",
    "---------------------------------",
    project_snapshot_text(attempt.snapshot),
    "",
    "VALIDATED PREVIEW",
    "-----------------",
    "Row\tSection\tOriginal Part\tNormalized Part\tBars\tMeter\tUnderlying BPM\tEffective BPM\tClick Pattern\tRamp\tStart\tNext"
  }
  if attempt.tempo_edit_log and #attempt.tempo_edit_log>0 then
    lines[#lines+1]=""
    lines[#lines+1]="STAGED TEMPO EDIT AUDIT"
    lines[#lines+1]="-----------------------"
    for index,entry in ipairs(attempt.tempo_edit_log) do lines[#lines+1]=tostring(index)..". "..tostring(entry) end
  end
  if plan then
    lines[#lines+1]=table.concat({"AUTO",COUNT_IN.name,"AUTO COUNT-IN",COUNT_IN.name,tostring(COUNT_IN.bars),string.format("%d/%d",COUNT_IN.numerator,COUNT_IN.denominator),format_effective_bpm(plan.count_in_bpm),format_effective_bpm(plan.count_in_bpm),click_pattern(COUNT_IN.numerator,false),"NO",tostring(COUNT_IN.visible_measure),tostring(START_VISIBLE_MEASURE)},"\t")
    for _,section in ipairs(plan.sections) do
      for i,part in ipairs(section.parts) do
        lines[#lines+1]=table.concat({tostring(section.row),i==1 and section.name or "",part.source,part.canonical,tostring(part.repeats),string.format("%d/%d",part.numerator,part.denominator),format_effective_bpm(part.underlying_bpm),format_effective_bpm(part.effective_bpm),click_pattern(part.numerator,part.no_accent),part.ramp and ("FINAL "..part.ramp_bars..(part.ramp_bars == 1 and " BAR" or " BARS").." TO "..format_effective_bpm(part.ramp_target_bpm)) or "NO",tostring(part.start_visible_measure),tostring(part.next_visible_measure)},"\t")
      end
      lines[#lines+1]=string.format("SECTION DURATION\t%s\t%s",section.name,format_duration(section.duration_seconds or 0))
    end
    lines[#lines+1]=table.concat({tostring(plan.end_row),"END","END","END","0","1/4",plan.end_bpm_entered and format_bpm(plan.end_bpm_entered) or "BLANK",format_effective_bpm(plan.end_effective_bpm),click_pattern(END_NUM,false),"N/A",tostring(plan.end_visible_measure),tostring(plan.end_visible_measure)},"\t")
  end
  lines[#lines+1]=""
  lines[#lines+1]="NORMALIZED PLAN"
  lines[#lines+1]="---------------"
  lines[#lines+1]=plan and plan.normalized_text or ""
  lines[#lines+1]=""
  lines[#lines+1]="ATTEMPT DETAILS"
  lines[#lines+1]="---------------"
  if details then
    if details.cancelled_stage then lines[#lines+1]="CANCELLED STAGE: "..details.cancelled_stage end
    if details.error then
      lines[#lines+1]="TECHNICAL ERROR: "..details.error
      local reference=identify_error_reference(details.error)
      lines[#lines+1]="ERROR REFERENCE CODE: "..tostring(reference.code)
      lines[#lines+1]="ERROR REFERENCE TITLE: "..tostring(reference.title)
      lines[#lines+1]="ERROR CATEGORY / LIKELY FAILURE STAGE: "..tostring(reference.category)
      lines[#lines+1]="USER-FACING EXPLANATION: "..tostring(reference.what)
      lines[#lines+1]="WHY IT MATTERS: "..tostring(reference.why)
      lines[#lines+1]="MOST LIKELY FIX: "..tostring(reference.fix)
      lines[#lines+1]="ALTERNATE FIX / NEXT STEP: "..tostring(reference.alternate)
      lines[#lines+1]="RELATED DOCUMENTATION: "..tostring(reference.related)
    end
    if details.message then lines[#lines+1]="DETAIL: "..details.message end
    if details.original_build_id then lines[#lines+1]="ORIGINAL BUILD ID: "..details.original_build_id end
    if details.log_note then lines[#lines+1]="LOG NOTE: "..details.log_note end
  end
  lines[#lines+1]=""
  lines[#lines+1]="END OF LOG"
  return table.concat(lines,"\r\n").."\r\n"
end

function verify_log_file(path,attempt,status)
  local text,err=read_file(path); if not text then return false,"Could not reopen logfile: "..tostring(err) end
  local required={"BUILD ID: "..attempt.id,"STATUS: "..status,"VALIDATED PREVIEW","END OF LOG"}
  for _,needle in ipairs(required) do if not text:find(needle,1,true) then return false,"Required log content is missing: "..needle end end
  if #text<200 then return false,"The logfile is unexpectedly short." end
  return true
end

function start_attempt(project,plan,notes,action,save_context)
  local id=make_attempt_id()
  local folder=project_log_folder(project)
  local ok,err=ensure_directory(folder); if not ok then return nil,"Could not create or write the log folder:\n"..folder.."\n\n"..tostring(err) end
  local attempt={id=id.id,safe_id=id.safe_id,timestamp=id.timestamp,zone=id.zone,suffix=id.suffix,project=project,plan=plan,notes=notes or "",action=action or "BUILD SONG STRUCTURE",folder=folder,validated_timestamp=plan and plan.validated_timestamp or "",status="IN PROGRESS",prebuild_saved_copy=save_context and save_context.prebuild_saved_copy or false,prebuild_saved_path=save_context and save_context.prebuild_saved_path or "",prebuild_skipped=save_context and save_context.prebuild_skipped or false,click_a_hz=state and state.click_a_hz or DEFAULT_CLICK_A_HZ,click_b_hz=state and state.click_b_hz or DEFAULT_CLICK_B_HZ,tempo_edit_log=state and {table.unpack(state.tempo_edit_log or {})} or {},audio_mode=state and state.audio_tempo_mode or AUDIO_MODE_PRESERVE,audio_analysis=state and state.audio_tempo_analysis or nil}
  attempt.inprogress_path=path_join(folder,attempt.safe_id.."_IN_PROGRESS.txt")
  local content=build_log_content(attempt,"IN PROGRESS",{message="Attempt ID generated. No project changes have occurred yet."})
  local written,write_err=write_file(attempt.inprogress_path,content)
  if not written then return nil,"Could not create the required IN_PROGRESS logfile: "..tostring(write_err) end
  local verified,verify_err=verify_log_file(attempt.inprogress_path,attempt,"IN PROGRESS")
  if not verified then os.remove(attempt.inprogress_path); return nil,"The required IN_PROGRESS logfile failed its integrity check: "..verify_err end
  return attempt
end

function finalize_attempt(attempt,status,details,history_status)
  attempt.status=status
  local content=build_log_content(attempt,status,details)
  local ok,err=write_file(attempt.inprogress_path,content)
  if not ok then return false,"Could not finalize the logfile: "..tostring(err) end
  local verified,verify_err=verify_log_file(attempt.inprogress_path,attempt,status)
  if not verified then return false,"Log integrity check failed before final rename: "..verify_err end
  local safe_status=sanitize_filename(status)
  local final_name=attempt.safe_id.."_"..safe_status..".txt"
  local final_path=path_join(attempt.folder,final_name)
  os.remove(final_path)
  local renamed,rename_err=os.rename(attempt.inprogress_path,final_path)
  if not renamed then return false,"The logfile was complete but could not be renamed: "..tostring(rename_err) end
  local final_ok,final_err=verify_log_file(final_path,attempt,status)
  attempt.log_path,attempt.log_filename,attempt.log_verified=final_path,final_name,final_ok
  local hist={id=attempt.id,timestamp=attempt.timestamp,status=history_status or status,project=attempt.project.path,spreadsheet=attempt.plan and attempt.plan.file_path or "",plan_hash=attempt.plan and attempt.plan.plan_sha256 or "",log_filename=final_name,available=true,original_build_id=details and details.original_build_id or "",notes=attempt.notes or ""}
  local index_ok,index_err=add_history_entry(attempt.folder,hist)
  if not final_ok then return false,"Final log integrity verification failed: "..tostring(final_err) end
  if not index_ok then return false,"Log verified, but BUILD HISTORY.csv could not be updated: "..tostring(index_err) end
  return true,final_path
end

function list_inprogress_logs(folder)
  local ps=[=[param([string]$OutputPath,[string]$Folder)
$ErrorActionPreference='Stop';$e=New-Object Text.UTF8Encoding($false)
try{
  $x=@(Get-ChildItem -LiteralPath $Folder -Filter '*_IN_PROGRESS.txt' -File -ErrorAction SilentlyContinue|ForEach-Object{[string]$_.FullName})
  $content=if($x.Count -gt 0){($x -join "`r`n")+"`r`n"}else{''}
  [IO.File]::WriteAllText($OutputPath,$content,$e)
}catch{[IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e);exit 1}]=]
  local text=run_powershell_text(ps,{{name="Folder",value=folder}},30000)
  local files={}; if not text or text=="" then return files end
  for line in (text.."\n"):gmatch("(.-)\r?\n") do if trim(line)~="" then files[#files+1]=line end end
  return files
end

function refresh_attempt_history(state)
  local info=get_active_project_info()
  if not project_is_saved(info) then state.history={};state.history_folder="";return end
  local folder=project_log_folder(info)
  state.history=load_history(folder,100)
  state.history_folder=folder
  if state.history_selected and state.history_selected>#state.history then state.history_selected=nil end
  -- Clamp-to-bottom happens during rendering once the visible row count is known.
  state.history_scroll=math.huge
end

function cancel_attempt(state,attempt,stage,message)
  local ok,log_or_err=finalize_attempt(attempt,"CANCELLED",{cancelled_stage=stage,message=message or "User selected Cancel. No project changes were made."},"CANCELLED")
  state.current_attempt=attempt
  state.build_status="CANCELLED"
  state.log_status=ok and "VERIFIED" or ("VERIFICATION FAILED: "..tostring(log_or_err))
  state.status=message or ("Build cancelled at: "..stage)
  state.status_kind="info"
  if ok then state.current_log_path=log_or_err end
  refresh_attempt_history(state)
end

function fail_attempt(state,attempt,error_text,message)
  local ok,log_or_err=finalize_attempt(attempt,"FAILURE",{error=error_text,message=message or "No unverified project changes were retained."},"FAILURE")
  state.current_attempt=attempt
  state.build_status="FAILURE"
  state.log_status=ok and "VERIFIED" or ("VERIFICATION FAILED: "..tostring(log_or_err))
  state.status=error_text
  state.status_kind="error"
  if ok then state.current_log_path=log_or_err end
  refresh_attempt_history(state)
end

function duplicate_plan_exists(folder,plan_hash)
  if not plan_hash or plan_hash=="" then return false end
  local entries=load_history(folder,nil)
  for i=#entries,1,-1 do
    local e=entries[i]
    if e.plan_hash==plan_hash and e.status=="SUCCESS" then return true,e end
  end
  return false
end

function preflight_build_plan(plan,locations,click_a_hz,click_b_hz)
  local failures={}
  if not plan or not locations or not locations.count_in or not locations.song then return false,"Validated plan or project start coordinates are unavailable." end
  if #(plan.sections or {})<1 then failures[#failures+1]="At least one musical section is required." end
  if #(plan.flat_parts or {})<1 then failures[#failures+1]="At least one musical part is required." end
  local expected,end_measure_index=build_expected_map(plan,locations.count_in.measure_index,locations.song.measure_index)
  if #expected<2 then failures[#failures+1]="The generated tempo map must include COUNT IN and END events; the song start may inherit an identical count-in tempo/meter event." end
  if end_measure_index<=locations.song.measure_index then failures[#failures+1]="END must occur after the song-start measure." end
  local names={}
  for _,section in ipairs(plan.sections or {}) do
    local key=normalize_name(section.name)
    if key=="" then failures[#failures+1]="A section marker name is blank."
    elseif names[key] then failures[#failures+1]="Duplicate section marker name: "..tostring(section.name)
    else names[key]=true end
    if tostring(section.name or ""):find("[\r\n%z]") then failures[#failures+1]="Section marker names cannot contain line breaks or NUL characters: "..tostring(section.name) end
  end
  for i,event in ipairs(expected) do
    if type(event.bpm)~="number" or event.bpm~=event.bpm or event.bpm<=0 or event.bpm==math.huge then failures[#failures+1]="Tempo event "..i.." has an invalid BPM." end
    if type(event.measure_index)~="number" or event.measure_index%1~=0 then failures[#failures+1]="Tempo event "..i.." is not on an exact measure boundary." end
    if type(event.numerator)~="number" or event.numerator<1 or event.numerator%1~=0 then failures[#failures+1]="Tempo event "..i.." has an invalid numerator." end
    if type(event.denominator)~="number" or event.denominator<1 or event.denominator%1~=0 then failures[#failures+1]="Tempo event "..i.." has an invalid denominator." end
  end
  local checked_a=click_a_hz or (state and state.click_a_hz) or DEFAULT_CLICK_A_HZ
  local checked_b=click_b_hz or (state and state.click_b_hz) or DEFAULT_CLICK_B_HZ
  if not valid_click_frequency(checked_a) then failures[#failures+1]="Primary A click frequency must be a whole number from 20 through 20000 Hz." end
  if not valid_click_frequency(checked_b) then failures[#failures+1]="Secondary B click frequency must be a whole number from 20 through 20000 Hz." end
  if #failures>0 then return false,table.concat(failures,"\n") end
  return true,{expected=expected,end_measure_index=end_measure_index,summary=string.format("%d sections, %d blocks, %d expanded part occurrences, %d tempo events, END internal measure %d",#plan.sections,plan.block_count or 0,#plan.flat_parts,#expected,end_measure_index)}
end

function transaction_signature_number(value,decimals)
  local number=tonumber(value) or 0
  local places=decimals or 9
  if math.abs(number)<0.5*(10^(-places)) then number=0 end
  return string.format("%."..places.."f",number)
end

function transaction_project_signature(proj)
  local lines={}
  local total=select(1,reaper.CountProjectMarkers(proj))
  for i=0,total-1 do
    local ok,is_region,pos,rgnend,name,index,color=reaper.EnumProjectMarkers3(proj,i)
    if ok>0 then lines[#lines+1]=table.concat({"M",tostring(is_region),transaction_signature_number(pos,9),transaction_signature_number(rgnend,9),tostring(name or ""),tostring(index or ""),tostring(color or "")},"|") end
  end
  for i=0,reaper.CountTempoTimeSigMarkers(proj)-1 do
    local ok,timepos,measurepos,beatpos,bpm,num,den,linear=reaper.GetTempoTimeSigMarker(proj,i)
    if ok then
      local _,pattern=reaper.TimeMap_GetMetronomePattern(proj,timepos,"EXTENDED")
      lines[#lines+1]=table.concat({"T",transaction_signature_number(timepos,9),transaction_signature_number(measurepos,9),transaction_signature_number(beatpos,9),transaction_signature_number(bpm,6),tostring(num or ""),tostring(den or ""),tostring(linear),tostring(pattern or "")},"|")
    end
  end
  return table.concat(lines,"\n")
end

function perform_logged_build(attempt)
  local info=get_active_project_info()
  if not info or info.pointer~=attempt.project.pointer then return false,"The active REAPER project changed after the build attempt was prepared." end
  local proj=info.proj
  if reaper.GetSetProjectInfo(proj,"READONLY",0,false)~=0 then return false,"The project is read-only." end
  if reaper.GetPlayStateEx(proj)~=0 then return false,"Stop playback, pause, and recording before building." end
  local locations,start_err=project_start_location(proj);if not locations then return false,start_err end
  local preflight_ok,preflight=preflight_build_plan(attempt.plan,locations,attempt.click_a_hz,attempt.click_b_hz)
  if not preflight_ok then return false,"Build preflight failed before project modification:\n"..tostring(preflight) end
  local live_snapshot,snapshot_err=collect_project_snapshot(proj,attempt.plan)
  if not live_snapshot then return false,"Audio handling preflight could not inspect the active project:\n"..tostring(snapshot_err) end
  local audio_analysis=analyze_audio_tempo_handling(proj,attempt.plan,live_snapshot)
  audio_analysis.mode=attempt.audio_mode or AUDIO_MODE_PRESERVE
  if audio_analysis.mode==AUDIO_MODE_CONFORM and not audio_analysis.conform_allowed then
    return false,"Conform Audio to New Tempo is unavailable because the current project structure does not exactly match the workbook:\n"..table.concat(audio_analysis.reasons,"\n")
  end
  attempt.audio_analysis=audio_analysis
  local before_signature=transaction_project_signature(proj)
  local before_metronome,metronome_state_err=metronome_enabled_state()
  if before_metronome==nil then return false,tostring(metronome_state_err) end
  local metronome_ready,metronome_ready_err=set_metronome_enabled(proj,true)
  if not metronome_ready then return false,"REAPER's metronome could not be enabled before building:\n"..tostring(metronome_ready_err) end
  local frequency_session_ok,frequency_session_err=begin_click_frequency_session()
  if not frequency_session_ok then set_metronome_enabled(proj,before_metronome==1);return false,tostring(frequency_session_err) end
  local before_click_a,before_click_b=get_click_frequencies(proj)
  if not before_click_a or not before_click_b then end_click_frequency_session();set_metronome_enabled(proj,before_metronome==1);return false,"The original project click frequencies could not be read before building." end

  local undo_label="Build Click Track Map ["..attempt.id.."]"
  local undo_started,ui_suppressed=false,false
  local function restore_ui() if ui_suppressed then reaper.PreventUIRefresh(-1);ui_suppressed=false end end
  reaper.Undo_BeginBlock2(proj);undo_started=true
  reaper.PreventUIRefresh(1);ui_suppressed=true

  local audio_context=nil
  local ok,result=xpcall(function()
    local frequency_ok,frequency_err=set_click_frequencies(attempt.click_a_hz,attempt.click_b_hz,proj)
    if not frequency_ok then error(frequency_err) end
    audio_context=prepare_audio_for_tempo_build(proj,attempt.audio_mode,audio_analysis)
    delete_all_standard_markers(proj)
    delete_tempo_markers_from(proj,locations.count_in.time)
    local expected,end_measure_index=preflight.expected,preflight.end_measure_index
    attempt.plan.count_in_internal_measure_index=locations.count_in.measure_index
    for _,event in ipairs(expected) do add_tempo_event(proj,event) end
    reaper.UpdateTimeline()
    local count_in_time=select(1,reaper.TimeMap_GetMeasureInfo(proj,locations.count_in.measure_index))
    if reaper.AddProjectMarker2(proj,false,count_in_time,0,COUNT_IN.name,-1,0)<0 then error("Failed to add COUNT IN marker.") end
    for _,section in ipairs(attempt.plan.sections) do
      local pos=select(1,reaper.TimeMap_GetMeasureInfo(proj,section.internal_measure_index))
      if reaper.AddProjectMarker2(proj,false,pos,0,section.name,-1,0)<0 then error("Failed to add project marker '"..section.name.."'.") end
    end
    local end_time=select(1,reaper.TimeMap_GetMeasureInfo(proj,end_measure_index))
    if reaper.AddProjectMarker2(proj,false,end_time,0,"END",-1,0)<0 then error("Failed to add END marker.") end
    reaper.UpdateTimeline();reaper.UpdateArrange()
    local audio_ok,audio_result=finalize_audio_after_tempo_build(proj,audio_context)
    if not audio_ok then error(audio_result) end
    attempt.audio_result_summary=audio_result.summary
    local verified,verify_result=verify_build(proj,attempt.plan,locations,expected,end_measure_index,attempt.click_a_hz,attempt.click_b_hz,true)
    if not verified then error("Post-build verification failed:\n"..verify_result) end
    reaper.SetEditCurPos2(proj,verify_result,true,false)
    return {end_time=verify_result,expected=expected,end_measure_index=end_measure_index,undo_label=undo_label,preflight_summary=preflight.summary,transaction_signature=before_signature,built_signature=transaction_project_signature(proj),original_click_a=before_click_a,original_click_b=before_click_b,original_metronome_enabled=before_metronome,audio_mode=attempt.audio_mode,audio_summary=audio_result.summary,audio_before_signature=audio_context.before_signature,audio_after_signature=audio_result.after_signature,audio_before_snapshot=audio_context.before}
  end,debug.traceback)
  restore_ui()
  if ok then
    reaper.Undo_EndBlock2(proj,undo_label,-1)
    reaper.UpdateTimeline();reaper.UpdateArrange()
    end_click_frequency_session()
    return true,result
  end
  if undo_started then
    reaper.Undo_EndBlock2(proj,undo_label.." (failed)",-1)
    local undone=reaper.Undo_DoUndo2(proj)
    local frequency_restored,frequency_restore_err=true,nil
    if before_click_a and before_click_b then frequency_restored,frequency_restore_err=set_click_frequencies(before_click_a,before_click_b,proj) end
    local metronome_restored,metronome_restore_err=set_metronome_enabled(proj,before_metronome==1)
    reaper.UpdateTimeline();reaper.UpdateArrange()
    local after_signature=transaction_project_signature(proj)
    local audio_rollback_ok=verify_audio_rollback(proj,audio_context)
    if undone==0 or after_signature~=before_signature or not audio_rollback_ok or not frequency_restored or not metronome_restored then
      end_click_frequency_session()
      return false,"CRITICAL: the build failed and automatic rollback could not be verified. Do not save the project until you inspect the marker, tempo, audio-item, metronome, and click-frequency state or manually undo."..(not audio_rollback_ok and "\n\nAudio-item restoration: the pre-build audio signature did not match." or "")..(frequency_restore_err and ("\n\nClick-frequency restoration: "..tostring(frequency_restore_err)) or "")..(metronome_restore_err and ("\n\nMetronome restoration: "..tostring(metronome_restore_err)) or "").."\n\n"..tostring(result)
    end
  end
  end_click_frequency_session()
  return false,"The rebuild was automatically undone, and the original marker/tempo and audio signatures were verified.\n\n"..tostring(result)
end

local DEFAULT_COLUMNS={52,190,520,54,68,88,102,155,64,64}
local COLUMN_HEADERS={"Row","Section","Part","Bars","Meter","Base BPM","REAPER BPM","Ramp","Start","Next"}
local COLUMN_KEYS={"row","section","part","bars","meter","base_bpm","reaper_bpm","ramp","start","next"}

function parse_number_list(text,defaults)
  local out={}
  for n in tostring(text or ""):gmatch("[^,]+") do out[#out+1]=tonumber(n) end
  if #out~=#defaults then out={};for i,v in ipairs(defaults) do out[i]=v end end
  return out
end

function serialize_number_list(values)
  local t={};for _,v in ipairs(values) do t[#t+1]=tostring(math.floor(v+0.5)) end;return table.concat(t,",")
end

function load_recent_files()
  local out={};local text=reaper.GetExtState(EXTSTATE_SECTION,"recent_files") or ""
  for line in (text.."\n"):gmatch("(.-)\n") do if trim(line)~="" and file_exists(trim(line)) then out[#out+1]=trim(line) end end
  return out
end

function save_recent_files(files)
  reaper.SetExtState(EXTSTATE_SECTION,"recent_files",table.concat(files,"\n"),true)
end

function add_recent_file(state,path)
  local out={path}
  for _,p in ipairs(state.recent_files) do if p~=path and #out<(state.recent_limit or 10) then out[#out+1]=p end end
  state.recent_files=out;save_recent_files(out)
end

function environment_check()
  local issues={}
  if not reaper.GetOS():match("Win") then issues[#issues+1]="Windows is required for XLSX and advanced file operations." end
  if not workbook_open_dialog_kind(reaper) then issues[#issues+1]="Missing REAPER workbook Browse API: GetUserFileName or GetUserFileNameForRead" end
  local required={"SetTempoTimeSigMarker","GetTempoTimeSigMarker","TimeMap_GetMetronomePattern","TimeMap2_timeToQN","TimeMap2_QNToTime","Undo_CanUndo2","Undo_DoUndo2","GetProjectStateChangeCount","GetSetRepeatEx","Master_GetPlayRate","GetTakeNumStretchMarkers","GetTakeStretchMarker","SetTakeStretchMarker","DeleteTakeStretchMarkers","ExecProcess"}
  for _,name in ipairs(required) do if not reaper.APIExists(name) then issues[#issues+1]="Missing REAPER API: "..name end end
  local sws_required={"BR_Win32_FindWindowEx","BR_Win32_GetWindow","BR_Win32_GetWindowLong","BR_Win32_GetWindowText","BR_Win32_GetConstant","BR_Win32_SetFocus","BR_Win32_SendMessage","BR_Win32_ShowWindow","BR_Win32_IsWindow"}
  for _,name in ipairs(sws_required) do if type(reaper[name])~="function" then issues[#issues+1]="Missing SWS/S&M API: "..name end end
  local has_sws_get=type(reaper.SNM_GetIntConfigVarEx)=="function" or type(reaper.SNM_GetIntConfigVar)=="function"
  local has_sws_set=type(reaper.SNM_SetIntConfigVarEx)=="function" or type(reaper.SNM_SetIntConfigVar)=="function"
  if not has_sws_get or not has_sws_set then issues[#issues+1]="The SWS/S&M configuration API is required for 50% audition pitch preservation." end
  local main_section=reaper.SectionFromUniqueID(0)
  if not main_section or trim(reaper.kbd_getTextFromCmd(ACTION_TOGGLE_METRONOME,main_section) or "")=="" then issues[#issues+1]="REAPER's metronome toggle action is unavailable." end
  local powershell_exit=select(1,exec_process_result(reaper.ExecProcess('cmd.exe /C where powershell.exe',10000)))
  if powershell_exit~=0 then issues[#issues+1]="PowerShell was not found." end
  return #issues==0,issues
end
function ext_bool(key,default)
  if SAFE_MODE then return default end
  local v=reaper.GetExtState(EXTSTATE_SECTION,key)
  if v=="" then return default end
  return v=="1" or v=="true" or v=="TRUE"
end
function persist_bool(key,value)
  if not SAFE_MODE then reaper.SetExtState(EXTSTATE_SECTION,key,value and "1" or "0",true) end
end
function pretty_setting_name(key)
  local names={remember_layout="Remember Layout",alternating_rows="Alternating row shading",section_emphasis="Section boundary emphasis",show_syntax_badges="Show syntax badges",show_row_explanations="Right-click row explanations",remember_history_filters="Remember history filters",remember_last_page="Remember last page",show_hashes="Show plan hashes",show_full_path="Show workbook full path",developer_mode="Developer diagnostics mode",larger_text="Larger text throughout app"}
  return names[key] or tostring(key):gsub("_"," ")
end

function normalize_preference_snapshot(raw)
  raw=raw or {}
  local density=upper(raw.preview_density or "")
  if density=="DENSE" then density="COMPACT" end
  if density~="COMPACT" and density~="COMFORTABLE" then density="COMFORTABLE" end
  local schema=tonumber(raw.preferences_schema) or 0
  return {preferences_schema=PREF_SCHEMA_VERSION,previous_schema=schema,preview_density=density}
end

function migrate_saved_preferences()
  if SAFE_MODE then return {safe_mode=true,changed=false} end
  local normalized=normalize_preference_snapshot({
    preferences_schema=reaper.GetExtState(EXTSTATE_SECTION,"preferences_schema"),
    preview_density=reaper.GetExtState(EXTSTATE_SECTION,"preview_density")
  })
  local changed=false
  if reaper.GetExtState(EXTSTATE_SECTION,"remember_layout")=="" then
    local old_keys={"remember_window","remember_panels","remember_column_widths","remember_hscroll"};local found=false;local enabled=false
    for _,key in ipairs(old_keys) do local value=reaper.GetExtState(EXTSTATE_SECTION,key);if value~="" then found=true;if value=="1" or value=="true" or value=="TRUE" then enabled=true end end end
    reaper.SetExtState(EXTSTATE_SECTION,"remember_layout",(not found or enabled) and "1" or "0",true);changed=true
  end
  local stored_density=reaper.GetExtState(EXTSTATE_SECTION,"preview_density")
  if stored_density~="" and stored_density~=normalized.preview_density then reaper.SetExtState(EXTSTATE_SECTION,"preview_density",normalized.preview_density,true);changed=true end
  if normalized.previous_schema<PREF_SCHEMA_VERSION then
    local stored_columns=reaper.GetExtState(EXTSTATE_SECTION,"column_widths")
    if stored_columns~="" then
      local widths=parse_number_list(stored_columns,DEFAULT_COLUMNS)
      if (tonumber(widths[2]) or 0)<DEFAULT_COLUMNS[2] then widths[2]=DEFAULT_COLUMNS[2];reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(widths),true) end
    end
    reaper.SetExtState(EXTSTATE_SECTION,"preferences_schema",tostring(PREF_SCHEMA_VERSION),true);changed=true
  end
  return {safe_mode=false,changed=changed,previous_schema=normalized.previous_schema,current_schema=PREF_SCHEMA_VERSION,preview_density=normalized.preview_density}
end

function workbook_identity(path)
  path=tostring(path or "")
  return path:lower()
end

function workbook_display(path)
  local name=basename(path):gsub("%.[Xx][Ll][Ss][Xx]$",""):gsub("%.[Cc][Ss][Vv]$","")
  local folder=dirname(path)
  return name,folder
end

function plan_diff_lines(old_plan,new_plan)
  state.validation_diff_targets={}
  state.changed_preview_rows={}
  if not old_plan then return {"No previous validated plan exists in this workspace."} end
  local old=preview_rows(old_plan); local new=preview_rows(new_plan)
  local groups={added={},removed={},modified={},timing={}}
  local maxn=math.max(#old,#new)
  for i=1,maxn do
    local a,b=old[i],new[i]
    if not a and b then
      groups.added[#groups.added+1]=string.format("Row %d: %s | %s | %s | starts %s",i,b.section,b.part,b.meter,b.start)
      state.validation_diff_targets[#state.validation_diff_targets+1]={label="Added row "..i..": "..b.section.." / "..b.part,row=i};state.changed_preview_rows[i]=true
    elseif a and not b then
      groups.removed[#groups.removed+1]=string.format("Former row %d: %s | %s | %s | started %s",i,a.section,a.part,a.meter,a.start)
    elseif a and b then
      local content={}
      for _,k in ipairs({"section","part","bars","meter","base_bpm","reaper_bpm","ramp"}) do
        if tostring(a[k] or "")~=tostring(b[k] or "") then content[#content+1]=k..": "..tostring(a[k] or "").." -> "..tostring(b[k] or "") end
      end
      if #content>0 then
        groups.modified[#groups.modified+1]=string.format("Row %d: %s",i,table.concat(content,"; "))
        state.validation_diff_targets[#state.validation_diff_targets+1]={label="Modified row "..i..": "..b.section.." / "..b.part,row=i};state.changed_preview_rows[i]=true
      end
      local timing={}
      for _,k in ipairs({"start","next"}) do
        if tostring(a[k] or "")~=tostring(b[k] or "") then timing[#timing+1]=k..": "..tostring(a[k] or "").." -> "..tostring(b[k] or "") end
      end
      if #timing>0 and #content==0 then
        groups.timing[#groups.timing+1]=string.format("Row %d: %s. Timing shift only, caused by an earlier structural change.",i,table.concat(timing,"; "))
        state.validation_diff_targets[#state.validation_diff_targets+1]={label="Timing shift row "..i..": "..b.section.." / "..b.part,row=i};state.changed_preview_rows[i]=true
      elseif #timing>0 then
        groups.timing[#groups.timing+1]=string.format("Row %d: %s. This row also has a content change listed above.",i,table.concat(timing,"; "))
      end
    end
  end
  if old_plan.end_visible_measure~=new_plan.end_visible_measure then
    groups.timing[#groups.timing+1]=string.format("END measure: %d -> %d",old_plan.end_visible_measure,new_plan.end_visible_measure)
  end
  local lines={}
  for _,g in ipairs({{"ADDED",groups.added},{"REMOVED",groups.removed},{"MODIFIED",groups.modified},{"TIMING SHIFTS",groups.timing}}) do
    lines[#lines+1]=g[1]
    if #g[2]==0 then lines[#lines+1]="None" else for _,line in ipairs(g[2]) do lines[#lines+1]="• "..line end end
    lines[#lines+1]=""
  end
  if #groups.added+#groups.removed+#groups.modified+#groups.timing==0 then return {"No musical-structure changes from the previous validated plan."} end
  return lines
end

function find_end_marker_position(proj)
  local _,num_markers,num_regions=reaper.CountProjectMarkers(proj)
  local total=(num_markers or 0)+(num_regions or 0)
  local exact={}
  for i=0,total-1 do
    local ok,is_region,pos,_,name=reaper.EnumProjectMarkers3(proj,i)
    if ok and not is_region and tostring(name or "")=="END" then exact[#exact+1]=pos end
  end
  if #exact==0 then return nil end
  if #exact==1 or not state.plan then return exact[1] end
  local planned_index=(state.plan.end_visible_measure or START_VISIBLE_MEASURE)-START_VISIBLE_MEASURE
  local planned_time=select(1,reaper.TimeMap_GetMeasureInfo(proj,planned_index))
  local best,best_distance=exact[1],math.abs(exact[1]-planned_time)
  for i=2,#exact do
    local d=math.abs(exact[i]-planned_time)
    if d<best_distance then best,best_distance=exact[i],d end
  end
  return best
end

function jump_to_preview_row(row,use_ramp_start)
  if not row or not state.plan then return end
  if state.preview_stale then show_info("Measure Jump","The workbook preview is stale. Revalidate before jumping.","warning");return end
  local info=get_active_project_info()
  if not info or not state.validation_project or info.pointer~=state.validation_project.pointer then
    show_info("Measure Jump","The active REAPER project is not the project associated with this preview.","error");return
  end
  if tostring(row.source or "")=="END" or tostring(row.part or "")=="END" then
    local marker_time=find_end_marker_position(info.proj)
    if not marker_time then
      show_info("Measure Jump","No standard project marker named END exists in the active project. Build the click map, or create an END marker, before using this jump.","warning")
      return
    end
    reaper.SetEditCurPos2(info.proj,marker_time,true,false)
    reaper.UpdateArrange()
    set_status("Moved REAPER edit cursor to the END marker.","success")
    return
  end
  local measure=tonumber(use_ramp_start and row.ramp_start or row.start)
  local internal_index=use_ramp_start and row.ramp_internal_measure_index or row.internal_measure_index
  if not measure or internal_index==nil then show_info("Measure Jump","This row does not have a valid jump position.","error");return end
  local time=select(1,reaper.TimeMap_GetMeasureInfo(info.proj,internal_index))
  reaper.SetEditCurPos2(info.proj,time,true,false)
  reaper.UpdateArrange()
  set_status(string.format("Moved REAPER edit cursor to visible measure %d.",measure),"success")
end

SCRATCHPAD_DEFAULT_BPM="120"
SCRATCHPAD_DEFAULT_PARTS="[4]x2, (7)x3@135--, {9}x2@160, *11*x2@170-, ENT(4)x2@120, SXT{7}x2@100-, QNT{5}x2@90-, SPT{7}x2@80-, <[3]x2@140, SXT{5}@110->x2"

local COMPLETE_WORKBOOK_EXAMPLE=[[
COMPLETE WORKBOOK EXAMPLE

SECTION NAME | BPM | PARTS
INTRO | 120 | [4]x2, (7)x3@135--
VERSE | 160 | {9}x2@160, *11*x2@170-
CHORUS | 120 | ENT(4)x2@120, SXT{7}x2@100-
BRIDGE | 90 | QNT{5}x2@90-, <[3]x2@140, SXT{5}@110->x2
BREAKDOWN | 110 no accent | SPT{7}x2@110-
OUTRO | 130 | [4]x2@130--
END | 90 |
]]

ERROR_REFERENCE={
  {code="WB-001",title="No workbook selected",category="Workbook",what="No workbook path is selected, so the app has nothing to validate.",why="Validation and building require a saved XLSX or CSV source.",fix="Click Browse, select the saved workbook, and run Validate Only.",alternate="Use Recent Files if the workbook was opened previously.",invalid="",corrected="",related="Workbook selection and Quick Start",matches={"CHOOSE AN XLSX","NO WORKBOOK","WORKBOOK PATH IS EMPTY"}},
  {code="WB-002",title="Workbook file not found",category="Workbook",what="The selected workbook path no longer exists or cannot be reached.",why="The saved preview cannot be reproduced without the source file.",fix="Restore the file, reconnect the drive, or select the workbook at its new location.",alternate="Remove the stale entry from Recent Files and browse to the correct copy.",invalid="",corrected="",related="Workbook selection",matches={"FILE DOES NOT EXIST","WORKBOOK DOES NOT EXIST","NOT FOUND"}},
  {code="WB-003",title="Unsupported workbook type",category="Workbook",what="The selected file is not a supported XLSX or CSV workbook.",why="The parser only understands the documented workbook formats.",fix="Save or export the file as .xlsx or .csv, then select that file.",alternate="Do not rename another file type to .xlsx or .csv.",invalid="song.ods",corrected="song.xlsx",related="Workbook requirements",matches={"UNSUPPORTED FILE","SUPPORTED XLSX OR CSV","FILE TYPE"}},
  {code="WB-004",title="Workbook could not be read",category="Workbook",what="PowerShell or the CSV reader could not extract the workbook contents.",why="Validation cannot continue without literal cell values.",fix="Close any damaged copies, save the workbook again, and retry. For XLSX, verify that Windows PowerShell can run.",alternate="Try Save As to a new XLSX file or export a CSV copy.",invalid="",corrected="",related="Troubleshooting workbook access",matches={"COULD NOT READ","FAILED TO READ","XLSX EXTRACTION","WORKBOOK READ"}},
  {code="WB-005",title="No matching worksheet",category="Workbook",what="No worksheet contains the required SECTION NAME, BPM, and PARTS headers.",why="The app needs exactly one sheet that identifies the song data columns.",fix="Add the three required headers to one worksheet and save the workbook.",alternate="Header capitalization and spacing may vary, but the words must remain recognizable.",invalid="SECTION | TEMPO | BARS",corrected="SECTION NAME | BPM | PARTS",related="Worksheet detection",matches={"NO MATCHING SHEET","NO WORKSHEET","REQUIRED HEADERS"}},
  {code="WB-006",title="Multiple matching worksheets",category="Workbook",what="More than one worksheet contains the required headers.",why="The app cannot safely guess which sheet is authoritative.",fix="Keep the required headers on only the intended song-data sheet.",alternate="Rename or remove one required header on reference or archive sheets.",invalid="",corrected="",related="Worksheet detection",matches={"MORE THAN ONE","MULTIPLE MATCHING","MULTIPLE WORKSHEETS"}},
  {code="WB-007",title="Required header missing",category="Workbook",what="One or more required headers are missing or unrecognizable.",why="Columns cannot be mapped reliably without all three headers.",fix="Use SECTION NAME, BPM, and PARTS in the header row.",alternate="Remove merged header cells and save again.",invalid="SECTION | SPEED | STRUCTURE",corrected="SECTION NAME | BPM | PARTS",related="Required headers",matches={"MISSING HEADER","REQUIRED HEADER","SECTION NAME, BPM, AND PARTS"}},
  {code="WB-008",title="Merged cells are not supported",category="Workbook",what="A relevant workbook cell is merged.",why="Merged cells make row and column ownership ambiguous.",fix="Unmerge the cells, repeat literal values where needed, save, and validate again.",alternate="Use ordinary formatting instead of merged cells.",invalid="",corrected="",related="Workbook cell restrictions",matches={"MERGED CELL","MERGED CELLS"}},
  {code="WB-009",title="Formulas are not supported",category="Workbook",what="A required value is stored as a formula instead of a literal value.",why="The app validates saved literal values and does not evaluate Excel formulas.",fix="Copy the calculated cells and use Paste Special > Values, then save and revalidate.",alternate="Maintain a separate calculation sheet and paste final values into the song sheet.",invalid="=A1*2",corrected="150",related="Workbook cell restrictions",matches={"FORMULA","FORMULAS ARE NOT SUPPORTED"}},
  {code="WB-015",title="Workbook Browse dialog unavailable",category="Workbook",what="This REAPER installation exposes neither the current workbook chooser nor its legacy read-only equivalent.",why="Browse cannot open a native file-selection window without one of those core REAPER APIs.",fix="Update or reinstall REAPER, restart it, and try Browse again.",alternate="If the workbook was opened previously, Recent Files may remain available.",invalid="",corrected="",related="Workbook selection and environment readiness",matches={"WORKBOOK BROWSE DIALOG","GETUSERFILENAME","GETUSERFILENAMEFORREAD","BROWSE API"}},
  {code="WB-010",title="Required cell is blank",category="Workbook",what="A normal musical row is missing SECTION NAME, BPM, or PARTS.",why="Each musical row must be complete so the plan is deterministic.",fix="Fill all three cells on the affected row.",alternate="Use END only for the special final row where PARTS must be blank.",invalid="VERSE | 150 |",corrected="VERSE | 150 | [4]x8",related="Row requirements",matches={"REQUIRED CELL","MISSING REQUIRED","MUST CONTAIN SECTION NAME"}},
  {code="WB-011",title="Invalid section BPM",category="Workbook",what="A section BPM is blank, zero, negative, scientific notation, or otherwise invalid.",why="The section BPM is the underlying tempo source for its parts and may optionally select the documented no-accent pattern.",fix="Enter a positive whole or decimal BPM such as 150 or 137.5; use 150 no accent for all-A clicks in that section.",alternate="Do not use a plus sign, BPM units, or other words.",invalid="150 + no accent",corrected="150 no accent",related="BPM values and section click accents",matches={"INVALID BPM","POSITIVE BPM","SECTION BPM","USE A POSITIVE DECIMAL FOLLOWED BY 'NO ACCENT'"}},
  {code="WB-012",title="Duplicate section name",category="Workbook",what="Two musical rows use the same section name after case and outer-space normalization.",why="Section markers and history comparisons require unique names.",fix="Rename one section so every section name is unique.",alternate="Use names such as VERSE 1 and VERSE 2 when repetition must be distinguished.",invalid="VERSE / verse",corrected="VERSE 1 / VERSE 2",related="Section names",matches={"DUPLICATE SECTION","SECTION NAMES MUST BE UNIQUE"}},
  {code="WB-013",title="COUNT IN is a reserved section name",category="Workbook",what="A spreadsheet section is named COUNT IN.",why="COUNT IN belongs exclusively to the automatic marker created at measure 1.",fix="Rename the spreadsheet section to INTRO, PRE-ROLL, OPENING, or another unique name.",alternate="Do not add a manual count-in row; the app creates it automatically.",invalid="COUNT IN | 150 | [4]x2",corrected="INTRO | 150 | [4]x2",related="Automatic COUNT IN",matches={"RESERVED FOR THE AUTOMATIC COUNT IN","RESERVED COUNT IN","SECTION NAMED COUNT IN"}},
  {code="WB-014",title="Unexpected data after terminating blank row",category="Workbook",what="A blank terminating row appears before additional populated song rows.",why="Rows are processed top to bottom and the first fully blank row ends the song-data block.",fix="Remove the blank gap or move all musical rows above it.",alternate="Keep notes and unrelated data on another sheet.",invalid="",corrected="",related="Row order",matches={"BLANK ROW","AFTER TERMINATING","DATA AFTER"}},
  {code="SYN-001",title="Invalid PARTS syntax",category="Syntax",what="A part does not match any supported meter or simulated-rhythm form.",why="The parser must identify meter, repeats, override, and ramp unambiguously.",fix="Rewrite the part using [N], (N), {N}, *N*, ENT(N), SXT{N}, QNT{N}, or SPT{N}.",alternate="Check for missing delimiters, extra characters, or unsupported punctuation.",invalid="Q^5^",corrected="QNT{5}",related="Syntax overview",matches={"INVALID PARTS SYNTAX","INVALID PART SYNTAX","COULD NOT PARSE PART"}},
  {code="SYN-002",title="Empty part or trailing comma",category="Syntax",what="The PARTS cell contains an empty comma-separated item, often from a trailing comma.",why="Commas are separators only; every separated item must be a real part.",fix="Remove the trailing comma or fill the missing part.",alternate="Use commas only between parts.",invalid="[4]x4,",corrected="[4]x4",related="Part separators",matches={"TRAILING COMMA","EMPTY PART","EMPTY COMMA"}},
  {code="SYN-003",title="Invalid normal meter",category="Syntax",what="A bracket, parenthesis, brace, or asterisk meter has a missing, non-whole, zero, or negative beat count.",why="Meter numerators must be positive whole numbers.",fix="Use forms such as [4], (7), {5}, or *9*.",alternate="Confirm the opening and closing delimiter match.",invalid="[4.5]",corrected="[4]",related="Normal meter syntax",matches={"INVALID METER","POSITIVE WHOLE","MISMATCHED DELIMITER"}},
  {code="SYN-004",title="Invalid ENT syntax",category="Syntax",what="An Eighth Note Triplet part is malformed.",why="ENT requires matching parentheses and a positive whole beat count; it creates N/4 at underlying BPM x1.5.",fix="Use ENT(N), followed only by optional xR, @BPM, and trailing ramp dashes.",alternate="The former ET(N) spelling is no longer accepted; replace it with ENT(N).",invalid="ET(4)",corrected="ENT(4)",related="Eighth Note Triplet syntax",matches={"INVALID ENT","ENT(","EIGHTH NOTE TRIPLET","EIGHTH-NOTE TRIPLET","ET SYNTAX WAS REPLACED"}},
  {code="SYN-005",title="Invalid SXT syntax",category="Syntax",what="A Sextuplet part is malformed.",why="SXT requires matching braces and a positive whole beat count; it creates N/4 at underlying BPM x3.",fix="Use SXT{N}, followed only by optional xR, @BPM, and trailing ramp dashes.",alternate="Use braces, not parentheses, brackets, or carets.",invalid="SXT(7)",corrected="SXT{7}",related="Sextuplet syntax",matches={"INVALID SXT","SXT{","SEXTUPLET"}},
  {code="SYN-006",title="Invalid QNT syntax",category="Syntax",what="A Quintuplet part is malformed.",why="QNT requires matching braces and a positive whole beat count; it creates N/4 at underlying BPM x5.",fix="Use QNT{N}, followed only by optional xR, @BPM, and trailing ramp dashes.",alternate="The former QUINT{N} spelling is no longer accepted; replace it with QNT{N}.",invalid="QUINT{5}",corrected="QNT{5}",related="Quintuplet syntax",matches={"INVALID QNT","QNT{","QNT SYNTAX","QUINT SYNTAX WAS REPLACED"}},
  {code="SYN-007",title="Invalid repeat modifier",category="Syntax",what="The xR repeat is missing a positive whole count or contains unsupported text.",why="Repeats define the total number of bars for the part.",fix="Use x2, X4, or another positive whole number after the meter.",alternate="Omit xR when one bar is intended.",invalid="[4]x0",corrected="[4]x2",related="Repeat modifier",matches={"INVALID REPEAT","REPEAT COUNT","XR"}},
  {code="SYN-008",title="Duplicate repeat modifier",category="Syntax",what="A part contains more than one xR repeat modifier.",why="Only one total repeat count can be applied to a part.",fix="Keep one xR modifier.",alternate="Split distinct structures into separate comma-separated parts.",invalid="[4]x2x3",corrected="[4]x3",related="Repeat modifier",matches={"MULTIPLE REPEAT","DUPLICATE REPEAT"}},
  {code="SYN-009",title="Invalid BPM override",category="Syntax",what="The @BPM modifier is missing a valid positive number.",why="A part-specific underlying BPM must be explicit and numeric.",fix="Use @120, @137.5, or another positive decimal after the optional repeat.",alternate="Remove the modifier to inherit the section BPM.",invalid="[4]@fast",corrected="[4]@150",related="BPM override",matches={"INVALID @BPM","INVALID BPM OVERRIDE","PART-SPECIFIC BPM"}},
  {code="SYN-010",title="Duplicate BPM override",category="Syntax",what="A part contains more than one @BPM modifier.",why="Only one underlying BPM override can apply to a part.",fix="Keep one @BPM value.",alternate="Create separate parts when different tempos are required.",invalid="[4]@120@130",corrected="[4]@130",related="BPM override",matches={"MULTIPLE @","DUPLICATE BPM OVERRIDE"}},
  {code="SYN-011",title="Modifier order is invalid",category="Syntax",what="Repeat, BPM override, or ramp tokens appear in the wrong order.",why="The supported order keeps parsing and canonical output deterministic.",fix="Use meter, then optional xR, then optional @BPM, then final consecutive dashes.",alternate="Compare the part to examples in the syntax guide.",invalid="[4]@120x4",corrected="[4]x4@120",related="Token order",matches={"MODIFIER ORDER","TOKEN ORDER","UNEXPECTED SUFFIX"}},
  {code="SYN-012",title="Ramp length exceeds part length",category="Syntax",what="The number of trailing dashes is greater than the number of repeated bars.",why="Each dash assigns one final bar to the continuous ramp.",fix="Reduce the dash count or increase xR so dash count is not greater than the number of bars.",alternate="With no xR, only one dash is allowed.",invalid="[4]x2---",corrected="[4]x2--",related="Ramp syntax",matches={"RAMP LENGTH","EXCEED","DASH COUNT"}},
  {code="SYN-013",title="Ramp dashes are malformed",category="Syntax",what="Ramp dashes are separated, contain other characters, or are not the final non-space characters.",why="A ramp must be represented by one consecutive trailing dash group.",fix="Move consecutive dashes to the very end of the part.",alternate="Do not use arrows or internal hyphens.",invalid="[4]-x4",corrected="[4]x4-",related="Ramp syntax",matches={"RAMP DASH","TRAILING DASH","CONSECUTIVE"}},
  {code="SYN-014",title="First-part BPM override conflict",category="Syntax",what="The first musical part uses an explicit @BPM that differs from the first section BPM column.",why="The automatic COUNT IN uses the first section BPM, so the song-start underlying BPM must match it.",fix="Remove the first part's @BPM or change it to the same value as the first section BPM.",alternate="ENT, SXT, QNT, and SPT multipliers remain valid because they change effective REAPER BPM without changing the underlying base BPM.",invalid="INTRO | 145 | [4]@150",corrected="INTRO | 145 | [4] or [4]@145",related="Automatic COUNT IN and first-part BPM rule",matches={"MUST MATCH THE FIRST SECTION BPM","FIRST-PART BPM","FIRST MUSICAL PART"}},
  {code="SYN-015",title="Invalid block delimiters",category="Syntax",what="A block has a missing, unmatched, or misplaced < or > delimiter.",why="The parser must know exactly which comma-separated parts belong to the block.",fix="Wrap the complete group as <PART, PART, ...> and keep it within one PARTS cell.",alternate="Check that every opening < has one closing > and that no text appears before < in the same item.",invalid="<[4], SXT{7}x2",corrected="<[4], SXT{7}>x2",related="Block syntax",matches={"MISSING ITS CLOSING >","CLOSING > WITHOUT","A BLOCK MUST USE <PART"}},
  {code="SYN-016",title="Nested blocks are not allowed",category="Syntax",what="A < > block appears inside another block.",why="Nested repeat and ramp boundaries would make pass destinations ambiguous.",fix="Flatten the inner parts into one non-nested block or use adjacent blocks.",alternate="Every part inside a block remains an ordinary part and may still use xR, @BPM, and internal ramp dashes.",invalid="<[4], <SXT{7}, [3]>x2>x2",corrected="<[4], SXT{7}, [3]>x2",related="Block syntax",matches={"BLOCKS CANNOT BE NESTED","NESTED BLOCK"}},
  {code="SYN-017",title="Invalid block repeat",category="Syntax",what="The suffix after > is not an optional xR positive-whole-number repeat.",why="A block may be repeated only as a whole number of passes.",fix="Use >x2, >X4, or omit xR for one pass.",alternate="Part-level xR modifiers remain valid inside the block.",invalid="<[4], SXT{7}>x1.5",corrected="<[4], SXT{7}>x2",related="Block repeats",matches={"BLOCK REPEAT MUST BE XR","BLOCK REPEAT COUNT"}},
  {code="SYN-018",title="Block-level ramp is not allowed",category="Syntax",what="A ramp dash is attached after the block's closing > or block repeat suffix.",why="A block-level ramp would conflict with internal pass boundaries and the following outside part.",fix="Remove the dash after >. Put ramps on ordinary parts inside or outside the block.",alternate="A normal part before a block may still ramp into the block's first part.",invalid="<[4], SXT{7}>x2-",corrected="<[4], SXT{7}>x2",related="Block ramp boundaries",matches={"BLOCK-LEVEL RAMP MODIFIERS AFTER > ARE NOT ALLOWED","BLOCK-LEVEL RAMP"}},
  {code="SYN-019",title="Block-level BPM override is not allowed",category="Syntax",what="An @BPM modifier appears after the block's closing >.",why="Tempo belongs to each ordinary part, not to the block container.",fix="Move @BPM onto the intended part or parts inside the block.",alternate="The section BPM remains the inherited underlying tempo for internal parts without overrides.",invalid="<[4], SXT{7}>x2@120",corrected="<[4]@120, SXT{7}@120>x2",related="Block syntax and BPM overrides",matches={"BLOCK-LEVEL @BPM OVERRIDES AFTER > ARE NOT ALLOWED","BLOCK-LEVEL BPM"}},
  {code="SYN-020",title="Final internal ramp has no destination",category="Syntax",what="The final part inside a one-pass block has a trailing ramp dash.",why="A final internal ramp may target only the first part of the block's next pass. A one-pass block has no next pass, and the ramp may not escape past >.",fix="Remove the final internal dash or repeat the block at least twice.",alternate="Ramps on non-final internal parts still target the next internal part on every pass.",invalid="<[4], SXT{7}->",corrected="<[4], SXT{7}> or <[4], SXT{7}->x2",related="Final internal block ramps",matches={"ONE-PASS BLOCK HAS NO LEGAL NEXT PASS","FINAL INTERNAL PART HAS A RAMP"}},
  {code="SYN-021",title="Empty block",category="Syntax",what="A < > block contains no ordinary parts.",why="A repeatable block must contain at least one playable part.",fix="Add at least one valid part between < and >.",alternate="Remove the empty block if no material should be played.",invalid="<>x2",corrected="<[4]>x2",related="Block syntax",matches={"BLOCK MUST CONTAIN AT LEAST ONE PART","EMPTY BLOCK"}},
  {code="SYN-022",title="Block expansion safety limit exceeded",category="Syntax",what="Expanding block repeats would create more than 10,000 part occurrences in one PARTS cell.",why="The cap prevents accidental repeat values from consuming excessive time or memory.",fix="Reduce the block repeat count or split the arrangement into additional section rows.",alternate="Part-level bar repeats can represent long steady spans more compactly.",invalid="<[4], SXT{7}>x6000",corrected="<[4]x6000, SXT{7}>x2",related="Block repeat safety",matches={"BLOCK EXPANSION EXCEEDS THE SAFETY LIMIT","10000 PART OCCURRENCES"}},
  {code="SYN-023",title="Invalid SPT syntax",category="Syntax",what="A Septuplet part is malformed or uses the transposed STP abbreviation.",why="SPT requires matching braces and a positive whole beat count; it creates N/4 at underlying BPM x7.",fix="Use SPT{N}, followed only by optional xR, @BPM, and trailing ramp dashes.",alternate="Use SPT, not STP, and use braces rather than parentheses or brackets.",invalid="STP{7}",corrected="SPT{7}",related="Septuplet syntax",matches={"INVALID SPT","SPT{","SEPTUPLET","STP IS NOT VALID SEPTUPLET SYNTAX"}},
  {code="END-001",title="Missing END row",category="END",what="The workbook has no final END row.",why="END defines the exact endpoint and final 1/4 tempo marker.",fix="Add END as the final populated row.",alternate="END BPM may be blank or a positive number; END PARTS must be blank.",invalid="CHORUS | 160 | [4]x4",corrected="END | 25 |",related="END row",matches={"MISSING END","FINAL ROW MUST BE END","REQUIRES A FINAL ROW"}},
  {code="END-002",title="END row is not final",category="END",what="A populated row appears after END, or END appears before the last musical row.",why="Parsing must have one unambiguous endpoint.",fix="Move END to the final populated row and remove all song data below it.",alternate="Move notes to another sheet.",invalid="END followed by OUTRO",corrected="OUTRO followed by END",related="END row",matches={"END MUST BE LAST","END ROW MUST BE FINAL","AFTER END"}},
  {code="END-003",title="END PARTS must be blank",category="END",what="The END row contains a PARTS value.",why="END marks an endpoint and never creates a counted bar.",fix="Clear the END PARTS cell.",alternate="Put the final musical part on the row above END.",invalid="END | 25 | [1]",corrected="END | 25 |",related="END row",matches={"END PARTS","PARTS MUST BE BLANK"}},
  {code="END-004",title="Invalid END BPM",category="END",what="The END BPM cell is not blank or a valid positive decimal.",why="A final ramp needs a valid destination tempo; blank means 25 BPM.",fix="Enter a positive BPM or leave the cell blank.",alternate="Do not enter text such as STOP.",invalid="END | STOP |",corrected="END | 25 |",related="END row",matches={"INVALID END BPM","END BPM"}},
  {code="CI-001",title="COUNT IN marker verification failed",category="Count-In",what="Post-build verification could not find exactly one standard marker named COUNT IN at visible measure 1.",why="The automatic count-in marker is required for a verified build.",fix="Undo or allow automatic undo, then rebuild in the intended project tab.",alternate="Open Diagnostics if the problem repeats.",invalid="",corrected="",related="Automatic COUNT IN verification",matches={"COUNT IN MARKER","FAILED TO ADD COUNT IN","VERIFY COUNT IN"}},
  {code="CI-002",title="COUNT IN meter or BPM verification failed",category="Count-In",what="One of the two count-in bars is not 4/4 at the first section BPM.",why="Measures 1 and 2 must be deterministic before spreadsheet processing begins at measure 3.",fix="Allow automatic undo, validate again, and rebuild after stopping playback.",alternate="Check for project corruption or external scripts altering the tempo map during the build.",invalid="",corrected="",related="Automatic COUNT IN verification",matches={"COUNT IN BPM","COUNT IN METER","TWO COUNT-IN BARS"}},
  {code="CI-003",title="Unexpected tempo marker inside count-in",category="Count-In",what="Verification found an unintended tempo/time-signature marker between measure 1 and measure 3.",why="The count-in must remain exactly two uninterrupted bars of 4/4 at one base BPM.",fix="Allow automatic undo and rebuild. Disable any script that edits the tempo map concurrently.",alternate="Open Diagnostics and create a Support Bundle if it repeats.",invalid="",corrected="",related="Automatic COUNT IN verification",matches={"UNINTENDED TEMPO MARKER","INSIDE THE COUNT-IN"}},
  {code="CI-004",title="Song did not start at measure 3",category="Count-In",what="The first spreadsheet part or first section marker was not verified at visible measure 3.",why="The two-bar count-in contract requires spreadsheet processing to begin at measure 3.",fix="Allow automatic undo, revalidate, and rebuild in a saved project.",alternate="Open Diagnostics and preserve the exact verification detail.",invalid="",corrected="",related="Song start and count-in",matches={"MEASURE 3","FIRST SPREADSHEET PART","SONG START"}},
  {code="PRJ-001",title="REAPER project has no .RPP path",category="Project",what="The active REAPER project has not yet been saved as an .RPP file.",why="Attempt logs, support files, and unique pre-build/completed Save As suggestions need a known REAPER project folder.",fix="Save the active REAPER project once as an .RPP file, then validate and retry.",alternate="The Readiness label means an .RPP path exists; current REAPER project changes may still be unsaved.",invalid="",corrected="",related="REAPER project save workflow",matches={"PROJECT MUST BE SAVED","SAVE THE RPP","VALID .RPP","REAPER PROJECT SAVED AT LEAST ONCE"}},
  {code="PRJ-002",title="Active project tab changed",category="Project",what="The active REAPER project is not the project used for validation or build preparation.",why="Building into another tab could alter the wrong song.",fix="Return to the intended project tab and validate again.",alternate="Do not switch tabs during confirmation or build.",invalid="",corrected="",related="Project-tab protection",matches={"ACTIVE PROJECT CHANGED","PROJECT TAB CHANGED","VALIDATED PREVIEW BELONGS"}},
  {code="PRJ-003",title="Project is read-only",category="Project",what="REAPER reports that the active project is read-only.",why="The app cannot write markers or tempo data to a read-only project.",fix="Save an editable copy or remove the read-only condition, then retry.",alternate="Verify file and folder permissions.",invalid="",corrected="",related="Project requirements",matches={"PROJECT IS READ-ONLY","READONLY"}},
  {code="PRJ-004",title="Playback or recording is active",category="Project",what="REAPER is playing, paused, or recording when the build begins.",why="Tempo-map rebuilding must occur while transport is stopped.",fix="Stop playback, pause, and recording, then retry.",alternate="Wait for any transport state to fully settle.",invalid="",corrected="",related="Build safety",matches={"STOP PLAYBACK","RECORDING BEFORE BUILDING","PLAY STATE"}},
  {code="PRJ-005",title="Project snapshot failed",category="Project",what="The app could not inspect current markers, tempo data, tracks, media items, or project length.",why="Confirmation and verification depend on an accurate automatic REAPER project check.",fix="Retry in the intended project tab after saving the project.",alternate="Open Diagnostics and restart REAPER if the API state appears unstable.",invalid="",corrected="",related="Automatic REAPER project check",matches={"PROJECT COMPARISON FAILED","SNAPSHOT FAILED","COLLECT PROJECT"}},
  {code="PRJ-006",title="REAPER project Save As was not confirmed",category="Project",what="The pre-build or completed-build REAPER .RPP save did not produce and activate the requested path, or the native Save As dialog could not complete.",why="The app must not claim that a backup or completed project exists unless REAPER confirms the exact active .RPP path on disk.",fix="Choose a writable local folder and an editable .RPP filename, complete Save As, and keep the intended REAPER project tab active.",alternate="Use REAPER's File > Save Project As directly, then return to Bildibeat Click Track Mapper; a canceled native dialog leaves the app save prompt open.",invalid="",corrected="OriginalSong_CTM_COMPLETED_BUILD_YYYY-MM-DD_HHMMSS_ID-01FB.RPP",related="Pre-build and post-build REAPER project save workflow",matches={"REAPER DID NOT CONFIRM","SAVE AS COULD NOT OPEN","REAPER COULD NOT SAVE THE PROJECT","ACTIVE REAPER PROJECT CHANGED WHILE SAVE AS","SAVE AS WAS CANCELED"}},
  {code="PRJ-007",title="Validated workbook and open project do not match",category="Project Comparison",what="The read-only Validate Against Open Project check found a marker, position, meter, calculated REAPER BPM, click pattern, Ramp boundary/linear state, Part start, COUNT IN, END, or extra-event difference.",why="A workbook and project should be treated as the same structural version only when their complete expanded click maps agree.",fix="Review every listed measure/Section/Part mismatch, then either open the matching workbook/project pair or intentionally rebuild from the validated workbook.",alternate="If the workbook changed on disk, run Validate Only first. The comparison never changes or saves either file.",invalid="",corrected="Open Project — Exact Match",related="Validate Against Open Project",matches={"OPEN PROJECT COMPARISON","OPEN PROJECT — DIFFERENCES FOUND","DO NOT MATCH","PRJ-007"}},
  {code="BLD-001",title="Workbook revalidation failed before build",category="Build",what="The workbook no longer validates when the build attempt re-reads it.",why="The displayed preview must match the saved source at build time.",fix="Correct the reported workbook errors, save, and run Validate Only again.",alternate="Do not build from unsaved Excel edits.",invalid="",corrected="",related="Pre-build revalidation",matches={"REVALIDATION FAILED","BUILD REVALIDATION FAILED"}},
  {code="BLD-002",title="Workbook changed after validation",category="Build",what="The workbook fingerprint or normalized plan changed after the displayed preview was created.",why="Building a stale preview could create a different map than the user reviewed.",fix="Save the workbook and run Validate Only again.",alternate="Confirm that no sync tool is replacing the file during validation.",invalid="",corrected="",related="Stale preview protection",matches={"WORKBOOK CHANGED","SPREADSHEET HAS CHANGED","PREVIEW IS STALE"}},
  {code="BLD-003",title="Project marker creation failed",category="Build",what="REAPER rejected creation of COUNT IN, a section marker, or END.",why="A complete standard-marker map is required for a verified result.",fix="Allow automatic undo, restart REAPER, and rebuild in an editable saved project.",alternate="Check for external scripts manipulating markers at the same time.",invalid="",corrected="",related="Build and verification",matches={"FAILED TO ADD PROJECT MARKER","FAILED TO ADD END MARKER","FAILED TO ADD COUNT IN MARKER"}},
  {code="BLD-004",title="Tempo-map marker creation failed",category="Build",what="REAPER rejected a planned tempo or time-signature event.",why="The click map cannot be verified without the complete expected tempo map.",fix="Allow automatic undo, validate the workbook, and retry with transport stopped.",alternate="Open Diagnostics to identify the affected event.",invalid="",corrected="",related="Build and verification",matches={"TEMPO MARKER","FAILED TO ADD TEMPO","SETTEMPOSIGMARKER"}},
  {code="BLD-005",title="Post-build verification failed",category="Build",what="The resulting project does not exactly match the validated plan.",why="The app must not leave unverified markers or tempo data in the project.",fix="Allow the automatic undo, then revalidate and retry.",alternate="Create a Support Bundle with the Build ID if the same verification detail repeats.",invalid="",corrected="",related="Post-build verification",matches={"POST-BUILD VERIFICATION FAILED","VERIFICATION FAILED"}},
  {code="BLD-006",title="Rollback verification failed",category="Build",what="A failed build was not followed by a verifiable restoration of the original standard-marker and tempo-map signature.",why="Unverified project changes may remain even if REAPER accepted an undo request.",fix="Do not save the project. Inspect the tempo map and markers, then use REAPER Undo History to restore the exact pre-build state if available.",alternate="Close without saving and reopen the last saved project or backup if the map cannot be verified manually.",invalid="",corrected="",related="Transactional build rollback verification",matches={"ROLLBACK COULD NOT BE VERIFIED","AUTOMATIC ROLLBACK","SIGNATURE WAS NOT RESTORED","CRITICAL:"}},
  {code="BLD-007",title="Interrupted attempt detected",category="Build",what="An IN_PROGRESS logfile from an earlier run was found without a finalized status.",why="The prior app or REAPER session may have closed during an attempt.",fix="Open the interrupted log, inspect the project, and confirm the current map before rebuilding.",alternate="Create a Support Bundle if the interruption is unexplained.",invalid="",corrected="",related="Interrupted attempts",matches={"INTERRUPTED ATTEMPT","IN_PROGRESS LOG"}},
  {code="BLD-009",title="Build preflight rejected the plan",category="Build",what="The final structural preflight found an invalid event, marker name, meter, BPM, or END coordinate before the undo transaction began.",why="A plan that cannot be represented safely in the active project must never reach project-changing code.",fix="Run Validate Only again in the intended project tab, then correct the exact preflight detail before building.",alternate="If workbook validation passes repeatedly but preflight does not, run Parser Self-Test and preserve the exact detail.",invalid="",corrected="",related="Automatic build preflight",matches={"BUILD PREFLIGHT FAILED","PREFLIGHT REJECTED","BEFORE PROJECT MODIFICATION"}},
  {code="BLD-008",title="Undo Last Build unavailable",category="Build",what="The app cannot safely undo the last build because another REAPER action occurred, the project changed, or no session build exists.",why="Undo Last Build must never undo an unrelated action.",fix="Use REAPER's Undo History and select the exact Build Click Track Map action manually.",alternate="Rebuild only after confirming the current project state.",invalid="",corrected="",related="Undo Last Build",matches={"UNDO LAST BUILD UNAVAILABLE","NO SUCCESSFUL BUILD","ANOTHER REAPER ACTION"}},
  {code="LOG-001",title="Log folder could not be created",category="Logging",what="The project log folder could not be created or written.",why="A Build ID cannot proceed without its required audit log.",fix="Verify write permission to the saved project folder and available disk space.",alternate="Save the project to a writable local folder.",invalid="",corrected="",related="Logging and permissions",matches={"COULD NOT CREATE OR WRITE THE LOG FOLDER","LOG FOLDER"}},
  {code="LOG-002",title="IN_PROGRESS log could not be created",category="Logging",what="The required initial attempt log could not be written.",why="The app does not modify the project until the attempt is auditable.",fix="Check project-folder permissions, disk space, antivirus, and filename access.",alternate="Retry after closing programs that may lock the log folder.",invalid="",corrected="",related="Attempt logging",matches={"COULD NOT CREATE THE REQUIRED IN_PROGRESS","IN_PROGRESS LOGFILE"}},
  {code="LOG-003",title="Log integrity check failed",category="Logging",what="A written attempt log could not be reopened or was missing required content.",why="The app treats an incomplete audit record as a logging failure.",fix="Check disk health and permissions, then retry in a local writable project folder.",alternate="Open Diagnostics and create a Support Bundle if possible.",invalid="",corrected="",related="Log integrity",matches={"LOG INTEGRITY","REQUIRED LOG CONTENT IS MISSING","UNEXPECTEDLY SHORT"}},
  {code="LOG-004",title="Final log rename failed",category="Logging",what="The complete IN_PROGRESS log could not be renamed to its final status filename.",why="History should point to a stable finalized log name.",fix="Close programs scanning the folder and retry after confirming write permission.",alternate="The complete IN_PROGRESS file may still contain the attempt details.",invalid="",corrected="",related="Log finalization",matches={"COULD NOT BE RENAMED","FINALIZE THE LOGFILE"}},
  {code="LOG-005",title="Build History index update failed",category="Logging",what="The finalized log exists, but BUILD HISTORY.csv could not be updated.",why="The attempt may not appear normally in Attempt History.",fix="Check permission and file locks on BUILD HISTORY.csv, then reopen the app.",alternate="The finalized text log remains the authoritative attempt record.",invalid="",corrected="",related="Attempt History index",matches={"BUILD HISTORY.CSV COULD NOT BE UPDATED","HISTORY INDEX"}},
  {code="LOG-006",title="Log folder could not be opened",category="Logging",what="Windows could not open the expected log folder.",why="The folder may not exist yet or the shell-open operation failed.",fix="Save the project and create at least one attempt, then use Open Log Folder again.",alternate="Open the project folder manually and locate SONG STRUCTURE BUILD LOGS.",invalid="",corrected="",related="Open Log Folder",matches={"LOG FOLDER UNAVAILABLE","OPEN LOG FOLDER"}},
  {code="LOG-007",title="Log cleanup failed",category="Logging",what="Old logs could not be enumerated, deleted, or marked unavailable.",why="Cleanup must not silently remove history records or unintended files.",fix="Close open log files, verify permission, and retry with a smaller age range.",alternate="Delete specific finalized logs manually only after reviewing BUILD HISTORY.csv.",invalid="",corrected="",related="Clean Up Logs",matches={"CLEAN UP LOGS","DELETE FINALIZED LOG"}},
  {code="LOG-008",title="Support bundle creation failed",category="Logging",what="The support files could not be copied or compressed into a ZIP archive.",why="Troubleshooting data was not packaged successfully.",fix="Choose a writable local destination and verify PowerShell Compress-Archive is available.",alternate="Open Diagnostics, copy its report, and attach the relevant log manually.",invalid="",corrected="",related="Support bundles",matches={"SUPPORT BUNDLE FAILED","COMPRESS-ARCHIVE"}},
  {code="HIS-001",title="Invalid History date range",category="History",what="Date From or Date To is not a real MM-DD-YYYY date, or Date From is later than Date To.",why="History filtering needs an unambiguous inclusive local-date range.",fix="Type a real MM-DD-YYYY date or choose one from Calendar, and keep Date From on or before Date To.",alternate="Use Clear Date for one endpoint or Clear Range for both.",invalid="14-99-2026",corrected="07-01-2026",related="Attempt History calendar and filters",matches={"INVALID DATE","DATE FROM CANNOT BE AFTER","MM-DD-YYYY","CALENDAR"}},
  {code="HIS-002",title="Selected history log unavailable",category="History",what="The selected attempt's log file no longer exists or was cleaned up.",why="History metadata can remain even when a finalized log is unavailable.",fix="Select another attempt or restore the log from backup.",alternate="Use the Build ID and BUILD HISTORY.csv to identify the missing filename.",invalid="",corrected="",related="Attempt History",matches={"SELECTED LOG UNAVAILABLE","LOGFILE IS NOT AVAILABLE","CURRENT LOG UNAVAILABLE"}},
  {code="HIS-003",title="Clipboard operation failed",category="Interface",what="The app could not copy, cut, or paste text through the Windows clipboard.",why="The requested text transfer was not completed, so the editor leaves the original value intact when possible.",fix="Retry after closing clipboard-management tools or paste targets running with different privileges.",alternate="Use ordinary typing or open the source text in its native application.",invalid="",corrected="",related="App-wide text editing and clipboard actions",matches={"COPY FAILED","PASTE FAILED","CLIPBOARD"}},
  {code="UI-001",title="Action is unavailable",category="Interface",what="A control is disabled because its specific workbook, validation, project, selection, ramp, history, environment, or undo prerequisite is not currently satisfied.",why="The app prevents unsafe or meaningless actions while preserving the exact reason in the TOOLTIP bar.",fix="Hover the disabled control and follow the precise prerequisite shown after Unavailable.",alternate="Hover the corresponding failed Readiness check for its repair step.",invalid="",corrected="",related="Context and status bar",matches={"CURRENTLY UNAVAILABLE","ACTION UNAVAILABLE","CONTROL IS CURRENTLY UNAVAILABLE","UNAVAILABLE:"}},
  {code="UI-002",title="Preview row actions did not open",category="Interface",what="The contextual Preview-row popover could not open because no row is selected, another modal owns input, or the Preview is unavailable.",why="Jump, Copy Readout, and Copy Syntax actions require one identifiable Preview row and topmost input ownership.",fix="Close the current modal, select a Preview row, then right-click it or focus the table and press Enter or Shift+F10.",alternate="Double-click a valid row to jump directly to its part or END.",invalid="",corrected="Right-click a Preview row",related="Preview row explanations and contextual actions",matches={"PREVIEW ROW ACTIONS","ROW EXPLANATION","ROW ACTIONS DID NOT OPEN"}},
  {code="EDT-001",title="Staged tempo edit failed validation",category="Tempo Editing",what="A proposed Section, Part, or END tempo edit did not pass the same production parser used for workbook validation.",why="The app will not stage a value that could not later be reproduced safely from a workbook copy.",fix="Enter a positive BPM and correct the exact parser detail shown in the dialog.",alternate="Cancel the edit; the previously validated plan remains unchanged.",invalid="0",corrected="145",related="In-app tempo editing",matches={"TEMPO EDIT COULD NOT BE APPLIED","PROPOSED TEMPO EDIT DID NOT PASS","EDT-001"}},
  {code="EDT-002",title="Section tempo source could not be rewritten",category="Tempo Editing",what="The selected Section's original PARTS expression could not be reconstructed while changing its BPM.",why="Section edits must preserve every meter, repeat, Block pass, ramp, and accent choice from the source row.",fix="Revalidate the source workbook, then retry the Section BPM edit.",alternate="Edit the source workbook directly if its PARTS cell was changed outside the app.",invalid="",corrected="",related="Section BPM editing",matches={"SELECTED SECTION SOURCE","SECTION TEMPO SOURCE","EDT-002"}},
  {code="EDT-003",title="Part tempo source could not be rewritten",category="Tempo Editing",what="The selected Part could not be located unambiguously in its source PARTS expression.",why="One source-level edit must apply consistently to all expanded occurrences created by repeats and Block passes.",fix="Revalidate the source workbook and reopen the row action before retrying.",alternate="Edit the Part's @BPM override directly in the workbook.",invalid="",corrected="",related="Part BPM editing and repeated Parts",matches={"SELECTED PART SOURCE","PART COULD NOT BE FOUND INSIDE","EDT-003"}},
  {code="EDT-004",title="Staged tempo plan changed before build",category="Tempo Editing",what="The saved source workbook or rebuilt staged plan no longer exactly matches the validated Preview table.",why="Building a different tempo plan from the one shown could corrupt the intended map.",fix="Run Validate Only again, recreate the intended tempo edits, and review the yellow changed rows.",alternate="Save or close outside workbook edits before trying again.",invalid="",corrected="",related="Pre-build staged-plan verification",matches={"TEMPO EDIT REVALIDATION FAILED","STAGED TEMPO PLAN","EDT-004"}},
  {code="EDT-005",title="Selected tempo edit could not be reverted",category="Tempo Editing",what="The app could not associate the selected yellow Preview row with a valid staged Section, Part, Ramp destination, or END edit, or the loaded workbook baseline could not be reconstructed.",why="Revert Tempo Edit must restore exact workbook-source values without discarding unrelated edits.",fix="Revalidate the workbook, recreate the intended edits, select the yellow row again, and retry Revert Tempo Edit.",alternate="Reload the workbook to discard every staged edit after confirming the broader reset.",invalid="",corrected="",related="Selection-aware Revert Tempo Edit",matches={"REVERT TEMPO EDIT FAILED","NO STAGED SECTION, PART, OR END","EDT-005"}},
  {code="REC-001",title="Tempo recovery workbook fingerprint mismatch",category="Session Recovery",what="A tempo-edit recovery record names the current workbook path, but its saved fingerprint or source hash does not match the workbook that was just validated.",why="Applying edits to a different workbook revision could target the wrong rows or syntax.",fix="Use the newly validated workbook values and recreate the intended edits.",alternate="Restore the exact unchanged workbook revision first, then validate it before recreating any newer edits.",invalid="",corrected="",related="Fingerprint-bound staged tempo recovery",matches={"RECOVERY DOES NOT MATCH","WORKBOOK CONTENTS HAVE CHANGED","REC-001"}},
  {code="REC-002",title="Tempo recovery record could not be read or validated",category="Session Recovery",what="The saved recovery record is damaged, incomplete, uses an unsupported schema, or fails the current production parser.",why="Only a complete fingerprint-matched edit set that validates normally can be restored.",fix="Keep the validated workbook values and recreate the edits in the app.",alternate="Inspect Diagnostics and the recovery warning before discarding the unusable record.",invalid="",corrected="",related="Validated staged tempo recovery",matches={"RECOVERY COULD NOT BE READ","RECOVERY COULD NOT BE RESTORED","REC-002"}},
  {code="REC-003",title="Tempo recovery record could not be written",category="Session Recovery",what="The BPM edit is staged in the current session, but the app could not write its temporary recovery file to REAPER's resource Data folder.",why="A crash or forced shutdown could lose the staged edit until an updated workbook copy is saved.",fix="Check write access and available disk space in REAPER's resource Data folder, then stage the edit again.",alternate="Keep the app open and save an updated workbook copy after applying and verifying the staged plan.",invalid="",corrected="",related="Crash/session recovery storage",matches={"TEMPO RECOVERY COULD NOT BE SAVED","RECOVERY COULD NOT BE WRITTEN","REC-003"}},
  {code="REC-004",title="Tempo recovery record could not be deleted",category="Session Recovery",what="The user confirmed that staged edits should be discarded, but the temporary recovery file could not be removed.",why="A stale recovery prompt could otherwise appear during a later matching validation.",fix="Close the app, verify write/delete access to REAPER's resource Data folder, and remove the named v10.21 recovery file.",alternate="If prompted again, choose Discard Recovery after confirming the workbook values are correct.",invalid="",corrected="",related="Intentional staged-edit discard",matches={"RECOVERY COULD NOT BE DELETED","REC-004"}},
  {code="WBK-001",title="Updated workbook Save As could not open",category="Workbook Copy",what="Windows could not open the Save As dialog for the updated workbook copy.",why="The app requires an explicit new destination and will not overwrite the validated source workbook.",fix="Retry after closing other native dialogs and verify Windows PowerShell is available.",alternate="Keep the verified REAPER build and edit the workbook manually from the logged tempo-edit audit.",invalid="",corrected="",related="Save Updated Workbook Copy",matches={"WORKBOOK SAVE AS COULD NOT OPEN","WBK-001"}},
  {code="WBK-002",title="Source workbook changed before copy",category="Workbook Copy",what="The source workbook fingerprint changed after validation and before the updated copy was created.",why="Applying staged cell edits to a different source revision could discard or combine unrelated workbook changes.",fix="Run Validate Only again and recreate the intended in-app tempo edits.",alternate="Save external workbook changes to a separate file before revalidating.",invalid="",corrected="",related="Source preservation",matches={"SOURCE WORKBOOK CHANGED","WBK-002"}},
  {code="WBK-003",title="Updated workbook copy could not be written",category="Workbook Copy",what="The new CSV or XLSX package could not be created with the staged tempo cells.",why="A workbook copy is only offered when the source can be preserved and the destination written safely.",fix="Choose a writable local filename, close any file with the same name, and retry.",alternate="Inspect the attempt log and apply the recorded values manually.",invalid="",corrected="",related="Save Updated Workbook Copy",matches={"UPDATED WORKBOOK COPY FAILED","UPDATED XLSX COPY COULD NOT BE CREATED","WBK-003"}},
  {code="WBK-004",title="Updated workbook copy failed verification",category="Workbook Copy",what="The saved copy did not reopen as the exact staged and verified tempo plan.",why="The app deletes an unverified output rather than presenting it as a trustworthy workbook.",fix="Retry with a new local filename after confirming the original workbook validates.",alternate="Create a Support Bundle and include the exact verification detail.",invalid="",corrected="",related="Workbook-copy post-write verification",matches={"UPDATED WORKBOOK VERIFICATION FAILED","UNVERIFIED COPY WAS REMOVED","WBK-004"}},
  {code="AUD-001",title="Audio-preview schedule could not be generated",category="Audio Preview",what="The Scratchpad or Tempo Preview expression could not be converted into a finite click-event schedule.",why="Preview playback needs complete meter, tempo, repeat, Block, and ramp timing before audio is rendered.",fix="Test valid Scratchpad syntax or enter a BPM from 20 through 400.",alternate="Run Parser Self-Test if a validated expression repeatedly fails.",invalid="",corrected="",related="Scratchpad Play Preview and Tempo Preview",matches={"AUDIO PREVIEW UNAVAILABLE","SCHEDULE","AUD-001"}},
  {code="AUD-002",title="Temporary click audio could not be rendered",category="Audio Preview",what="The app could not create the temporary WAV used for a non-mutating audio preview.",why="Scratchpad and Tempo Preview deliberately avoid changing the REAPER project and therefore require a temporary audio source.",fix="Verify free space and write access in the Windows temporary folder.",alternate="Restart REAPER to release stale preview files.",invalid="",corrected="",related="Non-mutating audio previews",matches={"TEMPORARY CLICK-PREVIEW WAV","AUD-002"}},
  {code="AUD-003",title="SWS audio preview could not start",category="Audio Preview",what="REAPER or SWS could not open the generated WAV as a background source preview.",why="The clean in-app audition path depends on the SWS CF_Preview API.",fix="Install or update SWS, restart REAPER, and open Diagnostics.",alternate="Use the Media Explorer fallback when available.",invalid="",corrected="",related="SWS background preview",matches={"CREATE A SOURCE PREVIEW","TEMPORARY WAV SOURCE","AUD-003"}},
  {code="AUD-004",title="No non-mutating audio-preview backend",category="Audio Preview",what="Neither the SWS background-preview API nor a usable Media Explorer playback path is available.",why="The app will not insert audition media into the active project merely to play a Scratchpad expression.",fix="Install or update SWS/S&M and restart REAPER.",alternate="Use REAPER's native metronome manually until SWS is available.",invalid="",corrected="",related="Audio-preview requirements",matches={"NO NON-MUTATING AUDIO-PREVIEW","INSTALL SWS/S&M FOR BACKGROUND PREVIEWS","AUD-004"}},
  {code="AUD-005",title="Conform Audio structure mismatch",category="Build Audio",what="Conform Audio was requested, but the current project markers, counts, meters, Repeat/Block expansion, or Ramp boundaries do not exactly match the validated workbook.",why="Audio can only be mapped safely when the old and new versions describe the same musical counts.",fix="Choose Preserve Audio Exactly, or restore a matching project/workbook pair before conforming.",alternate="Validate the workbook used to create the current project and compare the Preview structure.",invalid="",corrected="",related="Audio handling for tempo-map builds",matches={"CONFORM AUDIO TO NEW TEMPO IS UNAVAILABLE","CURRENT PROJECT STRUCTURE DOES NOT EXACTLY MATCH","AUD-005"}},
  {code="AUD-006",title="Audio item cannot be conformed safely",category="Build Audio",what="An eligible audio item is locked, mixes audio and MIDI takes, or crosses the COUNT IN or END boundary.",why="Automatically stretching that item could change material outside the validated musical structure.",fix="Choose Preserve Audio Exactly.",alternate="Unlock and reorganize the item so it lies fully inside one validated structure, then analyze again.",invalid="",corrected="",related="Conform Audio eligibility",matches={"CROSSES THE COUNT IN OR END BOUNDARY","ALSO CONTAINS A MIDI TAKE","AUDIO ITEM","IS LOCKED","AUD-006"}},
  {code="AUD-007",title="Preserve Audio verification failed",category="Build Audio",what="One or more audio item properties did not exactly match the pre-build snapshot after the tempo map was rebuilt.",why="Preserve Audio Exactly promises no timing, rate, pitch, fade, timebase, or stretch-marker change.",fix="Do not save; allow the automatic rollback and inspect the project.",alternate="Use REAPER Undo History if the rollback warning says verification failed.",invalid="",corrected="",related="Preserve Audio Exactly and rollback",matches={"PRESERVE AUDIO VERIFICATION FAILED","PRESERVE AUDIO RESTORATION FAILED","AUD-007"}},
  {code="AUD-008",title="Conformed audio verification failed",category="Build Audio",what="An audio item did not remain on its original musical counts or did not retain pitch-preserving playback.",why="Conform Audio must change duration/rate while preserving both musical alignment and pitch.",fix="Do not save; allow the automatic rollback and inspect the affected item.",alternate="Choose Preserve Audio Exactly for the next build.",invalid="",corrected="",related="Conform Audio to New Tempo",matches={"CONFORM AUDIO VERIFICATION FAILED","ORIGINAL MUSICAL COUNT","PRESERVE PITCH IS NOT ENABLED","AUD-008"}},
  {code="CPX-001",title="Click package plan is unavailable or stale",category="Click Package Export",what="Export MIDI + MP3 Click was requested without a current validated workbook plan.",why="Both output files must be generated from exactly the structure the user reviewed.",fix="Save the workbook and run Validate Only again, then retry the export.",alternate="Resolve any Validation Issues before exporting.",invalid="",corrected="",related="Export MIDI + MP3 Click",matches={"CLICK PACKAGE UNAVAILABLE","PLAN IS UNAVAILABLE","CPX-001"}},
  {code="CPX-002",title="Click package destination is invalid or already exists",category="Click Package Export",what="The selected base filename is empty, the Save As dialog failed, or either derived .mid/.mp3 file already exists.",why="One action owns both synchronized files and never replaces only half of an existing package.",fix="Choose a writable folder and a new base filename.",alternate="Move or rename the earlier package before trying again.",invalid="ExistingName.mp3 plus ExistingName.mid",corrected="Song_CLICK_PACKAGE_2026-07-23_120000.mp3",related="Click package Save As",matches={"CHOOSE A NEW CLICK PACKAGE NAME","DESTINATION FILE","CPX-002"}},
  {code="RCN-001",title="Project reconstruction anchors are invalid",category="Project Reconstruction",what="COUNT IN, visible measure 3, END, playback state, or another required project anchor is unavailable.",why="A generated workbook must begin with the exact two-bar COUNT IN and end at one unambiguous musical boundary.",fix="Stop playback and place COUNT IN at visible measure 1, the first Section at visible measure 3, and END after the final musical bar.",alternate="Build a known-good workbook once, then retry reconstruction from that verified project.",invalid="",corrected="",related="Create Verified Workbook From Open Project",matches={"RCN-001","RECONSTRUCTION ANCHOR","COUNT IN MUST","END MUST OCCUR"}},
  {code="RCN-002",title="Project marker is off the measure grid",category="Project Reconstruction",what="A standard project marker is not on an exact measure boundary.",why="Workbook Sections can begin only at whole-measure Part boundaries.",fix="Move the named marker to the first beat of its intended measure.",alternate="Use REAPER snap and verify the marker position before retrying.",invalid="",corrected="",related="Section markers",matches={"RCN-002","NOT ON AN EXACT MEASURE BOUNDARY"}},
  {code="RCN-003",title="Section markers cannot form workbook rows",category="Project Reconstruction",what="Section marker names are missing, duplicated, misplaced, or ambiguous.",why="Every workbook Section needs one unique marker name and one exact start measure.",fix="Keep one COUNT IN, one END, and one uniquely named Section marker at every intended Section start.",alternate="Remove unrelated standard markers or convert them to regions before reconstruction.",invalid="",corrected="",related="Section definition",matches={"RCN-003","SECTION MARKER","DUPLICATES ANOTHER MARKER"}},
  {code="RCN-004",title="Tempo map contains an unrepresentable event",category="Project Reconstruction",what="A tempo/time-signature event is off-grid, duplicated, after END, or changes state without a representable boundary.",why="The workbook must reproduce every generated tempo marker exactly and may not invent or discard events.",fix="Move tempo/time-signature markers to measure boundaries and remove redundant or post-END events.",alternate="Keep a copy of the project, rebuild its map from a validated workbook, and retry.",invalid="",corrected="",related="One-for-one tempo-map verification",matches={"RCN-004","TEMPO/TIME-SIGNATURE MARKER","AFTER END","WITHOUT AN EXPLICIT"}},
  {code="RCN-005",title="Ramp or END boundary cannot be represented",category="Project Reconstruction",what="A linear ramp crosses a Section improperly, lacks an exact target event, or END is not a 1/4 boundary.",why="Trailing ramp dashes need a known whole-bar span and exact destination.",fix="End every ramp on an explicit measure-boundary tempo marker and retain the standard 1/4 END marker.",alternate="Split or shorten the ramp so it terminates at the next Section or Part boundary.",invalid="",corrected="",related="Ramp and END syntax",matches={"RCN-005","LINEAR RAMP","END MUST BE AN EXPLICIT 1/4"}},
  {code="RCN-006",title="Project meter has no Bildibeat syntax",category="Project Reconstruction",what="The project uses a denominator other than 4, 8, 16, or 32.",why="The current PARTS grammar has no lossless spelling for that meter.",fix="Use a supported meter denominator or retain the project without generating a workbook.",alternate="Request a future syntax extension for the required denominator.",invalid="",corrected="",related="PARTS meter syntax",matches={"RCN-006","NOT REPRESENTABLE BY BILDIBEAT"}},
  {code="RCN-007",title="Section click patterns are inconsistent",category="Project Reconstruction",what="A Section mixes normal accents, no-accent patterns, or a custom metronome pattern.",why="The BPM cell's no accent modifier applies to the entire Section.",fix="Use one normal accented pattern or one all-A no-accent pattern throughout the Section.",alternate="Split the material at the pattern change and give each range its own Section marker.",invalid="",corrected="",related="No-accent Sections",matches={"RCN-007","MIXES ACCENTED","CLICK PATTERN"}},
  {code="RCN-008",title="Inferred workbook did not match the project",category="Project Reconstruction",what="Every conservative syntax candidate changed at least one marker, tempo, meter, pattern, ramp, COUNT IN, or END detail.",why="The app refuses to save a guessed workbook that is not a one-for-one musical map.",fix="Review the reported mismatch and simplify only the conflicting project event.",alternate="Rebuild from an existing validated workbook to normalize the project map.",invalid="",corrected="",related="Round-trip verification",matches={"RCN-008","COULD NOT BE REDUCED","ONE-FOR-ONE"}},
  {code="RCN-009",title="Project changed during reconstruction",category="Project Reconstruction",what="The active project tab or its marker/tempo signature changed after analysis.",why="Saving an earlier reconstruction could describe stale project state.",fix="Run Create Verified Workbook From Open Project again after edits are complete.",alternate="Avoid changing tabs, markers, or tempo events while the save prompt is open.",invalid="",corrected="",related="Reconstruction transaction safety",matches={"RCN-009","PROJECT CHANGED BEFORE SAVE"}},
  {code="RCN-010",title="Reconstructed workbook could not be written",category="Project Reconstruction",what="The XLSX/CSV save dialog, manifest, destination, or writer failed.",why="The verified in-memory plan was not safely persisted.",fix="Choose a writable local filename and retry.",alternate="Try CSV if XLSX creation is unavailable, then open and resave it in a spreadsheet application.",invalid="",corrected="",related="Reconstructed workbook save",matches={"RCN-010","RECONSTRUCTED XLSX","RECONSTRUCTION MANIFEST"}},
  {code="RCN-011",title="Saved reconstruction failed final verification",category="Project Reconstruction",what="The new file did not reopen, parse, or match the unchanged project exactly.",why="Disk encoding and the saved workbook must preserve the same verified plan as the in-memory analysis.",fix="Retry with a new destination; the unverified file is removed automatically.",alternate="Create a Support Bundle and include the reconstruction error log.",invalid="",corrected="",related="Post-save parser verification",matches={"RCN-011","POST-SAVE RECONSTRUCTION","UNVERIFIED FILE WAS REMOVED"}},
  {code="CPX-003",title="MIDI click or tempo map could not be created",category="Click Package Export",what="The validated plan could not be represented as a type-1 Standard MIDI File or the generated file failed its header, track-count, PPQ, exact click-count, note, or END-boundary checks.",why="The MIDI must contain one explicit click note for every scheduled musical beat plus a trustworthy tempo/meter track before it is offered for Logic or Pro Tools.",fix="Use meter numerators from 1 through 255, rerun Parser Self-Test, and retry with a new filename.",alternate="Preserve the exact error text and create a Support Bundle if ordinary syntax still fails.",invalid="",corrected="",related="MIDI tempo/meter and click export",matches={"MIDI FILE","STANDARD MIDI","MIDI END-BOUNDARY","MIDI CONTAINS","CPX-003"}},
  {code="CPX-004",title="Permanent click audio could not be synthesized",category="Click Package Export",what="The complete validated click schedule or its temporary PCM WAV could not be created, the mathematical click count differed, or the renderer did not consume every scheduled onset.",why="The MP3 must contain every scheduled click from COUNT IN through the final Part and is intentionally independent of REAPER's live metronome playback/record settings.",fix="Verify temporary-folder write access and that the song is shorter than the documented four-hour export safety limit.",alternate="Run Parser Self-Test to check exact click scheduling and WAV generation.",invalid="",corrected="",related="MP3 click synthesis",matches={"PERMANENT AUDIO SCHEDULE","CLICK IS LONGER THAN","AUDIO SCHEDULE CONTAINS","SCHEDULED CLICKS","CPX-004"}},
  {code="CPX-005",title="REAPER MP3 conversion failed",category="Click Package Export",what="The hidden stock-REAPER batch conversion did not produce a valid MP3 from the temporary click WAV.",why="The app delegates MP3 encoding to the installed REAPER version instead of shipping a separate encoder.",fix="Confirm REAPER's compressed-file/MP3 support is installed, close other conversion dialogs, and retry.",alternate="Update or repair REAPER, then rerun the export.",invalid="",corrected="",related="REAPER MP3 encoder",matches={"MP3 CONVERSION","MP3 HEADER","BATCH-CONVERSION","CPX-005"}},
  {code="CPX-006",title="Click package final verification or commit failed",category="Click Package Export",what="The verified temporary MIDI and MP3 could not both be copied and atomically committed to the chosen folder.",why="The app removes partial output rather than leaving an apparently complete but mismatched package.",fix="Choose a writable local folder with a new filename and sufficient free space.",alternate="Avoid cloud-synchronized or removable destinations while troubleshooting.",invalid="",corrected="",related="Synchronized click package commit",matches={"FINAL MIDI VERIFICATION","FINAL MP3","COULD NOT BE COMMITTED","CPX-006"}},
  {code="HELP-001",title="README not found",category="Help",what="No file matching Bildibeat_Click_Track_Mapper_README_v*.txt was found beside the main script.",why="Open README cannot select a manual without a matching file.",fix="Place the v10.21 README in the same folder as the main Lua script.",alternate="The app chooses the highest semantic version automatically.",invalid="",corrected="Bildibeat_Click_Track_Mapper_README_v10_21.txt",related="Help and README",matches={"README UNAVAILABLE","README NOT FOUND","NO FILE MATCHING CLICK_TRACK_MAPPER_README"}},
  {code="HELP-002",title="README could not be opened",category="Help",what="The README was found but Windows could not open it with the associated text viewer.",why="The file exists, but the shell-open action failed.",fix="Open the README directly from File Explorer or repair the .txt file association.",alternate="Copy the path from the script folder and open it in Notepad.",invalid="",corrected="",related="Help and README",matches={"OPEN README","COULD NOT OPEN README"}},
  {code="ENV-001",title="PowerShell process failed",category="Environment",what="Windows PowerShell returned an error while reading XLSX, hashing, opening a dialog, or creating a ZIP.",why="Several stock-Windows integrations depend on PowerShell.",fix="Open Diagnostics, confirm Windows PowerShell is available, and retry with local file paths.",alternate="Temporarily test with CSV to isolate XLSX extraction issues.",invalid="",corrected="",related="Environment diagnostics",matches={"POWERSHELL","EXEC PROCESS","PROCESS FAILED"}},
  {code="ENV-002",title="PowerShell operation timed out",category="Environment",what="A PowerShell operation did not finish within the allowed time.",why="The app cannot wait indefinitely while the UI is blocked.",fix="Retry with the workbook and project on a local drive and close programs locking the files.",alternate="Check antivirus, network latency, and very large workbooks.",invalid="",corrected="",related="Environment diagnostics",matches={"TIMED OUT","TIMEOUT"}},
  {code="ENV-003",title="Temporary file operation failed",category="Environment",what="The app could not create, read, or delete a required temporary file or folder.",why="XLSX extraction, dialogs, and support bundles use temporary files.",fix="Verify free disk space and permission to the Windows temp directory.",alternate="Restart REAPER to release stale handles.",invalid="",corrected="",related="Environment diagnostics",matches={"TEMPORARY FILE","TEMP FILE","TEMP FOLDER"}},
  {code="ENV-004",title="Filesystem permission denied",category="Environment",what="Windows denied access to the workbook, project folder, log, README, or destination file.",why="The requested read or write operation cannot complete.",fix="Move the files to a writable local folder or correct Windows permissions.",alternate="Avoid protected system folders and mismatched administrator privileges.",invalid="",corrected="",related="Filesystem permissions",matches={"ACCESS DENIED","PERMISSION","DENIED"}},
  {code="ENV-005",title="Parser self-test failed",category="Environment",what="One or more built-in valid or invalid syntax cases produced an unexpected result.",why="The running script may be damaged or incompatible with the current environment.",fix="Replace the main script with a fresh v10.21 copy and rerun the self-test.",alternate="Create a Support Bundle and include the exact failed test details.",invalid="",corrected="",related="Parser Self-Test",matches={"PARSER TESTS PASSED","PARSER SELF-TEST","TEST FAILED"}},
  {code="ENV-006",title="SWS/S&M Extension unavailable",category="Environment",what="The SWS/S&M window or configuration APIs needed for project click frequencies or 50% audition pitch preservation are not available.",why="Bildibeat Click Track Mapper uses SWS to control REAPER's native metronome frequency fields and to restore the master-playrate preserve-pitch setting safely.",fix="Install or update the SWS Extension, restart REAPER, and open Diagnostics again.",alternate="Keep SWS current with the installed REAPER release, then reopen Bildibeat Click Track Mapper.",invalid="",corrected="SWS/S&M Extension installed",related="Click Frequencies and 50% Speed audition",matches={"SWS/S&M","BR_WIN32","SNM_GETINTCONFIGVAR","PROJECT CLICK FREQUENCIES","PITCH PRESERVATION"}},
  {code="ENV-007",title="REAPER metronome could not be enabled",category="Environment",what="REAPER did not expose or accept its native metronome toggle state before a build or audition.",why="The generated tempo and click-pattern map is audible only while REAPER's metronome is enabled.",fix="Stop playback, confirm REAPER's native metronome control is available, then rebuild or audition again.",alternate="Enable Options > Metronome manually, open Diagnostics, and preserve the exact error if the app still cannot verify the enabled state.",invalid="Metronome disabled",corrected="REAPER metronome enabled",related="Build verification and Preview audition",matches={"METRONOME COULD NOT BE ENABLED","METRONOME TOGGLE ACTION IS UNAVAILABLE","METRONOME VERIFICATION FAILED","METRONOME ENABLED STATE"}},
  {code="SAFE-001",title="Safe Mode main script not found",category="Safe Mode",what="The Safe Mode launcher cannot find Bildibeat_Click_Track_Mapper_v10_21.lua beside itself.",why="The launcher must execute the matching main-version file.",fix="Keep both v10.21 Lua files in the same folder and do not rename either one.",alternate="Reload the Safe Mode script in REAPER after moving the files.",invalid="",corrected="Bildibeat_Click_Track_Mapper_v10_21.lua",related="Safe Mode",matches={"SAFE MODE COULD NOT FIND","MAIN SCRIPT BESIDE THIS LAUNCHER"}},
  {code="SAFE-002",title="Safe Mode launch failed",category="Safe Mode",what="The main script raised an error while being loaded through the Safe Mode launcher.",why="Safe Mode can ignore preferences, but it cannot bypass a damaged or invalid script.",fix="Replace both Lua files with fresh v10.21 copies and retry.",alternate="Use the exact technical error text to search this Error Reference.",invalid="",corrected="",related="Safe Mode",matches={"FAILED TO START IN SAFE MODE","SAFE MODE ERROR"}},
  {code="UNK-001",title="Unexpected or uncatalogued error",category="Unexpected",what="The app encountered technical error text that does not match a known catalog entry.",why="REAPER, Windows, PowerShell, filesystems, or future environments can produce failures that cannot be predicted completely.",fix="Save the project and workbook, close and reopen Bildibeat Click Track Mapper, then retry the same action once.",alternate="Run Diagnostics, preserve the exact error text, note the Build ID if one exists, open the attempt log, and create a Support Bundle.",invalid="",corrected="",related="Diagnostics and support",matches={}},
}


function error_reference_search_blob(entry)
  return upper(table.concat({entry.code or "",entry.title or "",entry.category or "",entry.what or "",entry.why or "",entry.fix or "",entry.alternate or "",entry.invalid or "",entry.corrected or "",entry.related or ""}," "))
end

function format_error_reference_entry(entry,index_only)
  if index_only then
    return string.format("[%s] %s (%s)\nMost likely fix: %s",entry.code,entry.title,entry.category,entry.fix)
  end
  local lines={
    string.format("[%s] %s",entry.code,entry.title),
    "Category: "..entry.category,
    "",
    "WHAT HAPPENED",
    entry.what,
    "",
    "WHY IT MATTERS",
    entry.why,
    "",
    "MOST LIKELY FIX",
    entry.fix
  }
  if entry.alternate and entry.alternate~="" then lines[#lines+1]="";lines[#lines+1]="ALTERNATE FIX OR NEXT STEP";lines[#lines+1]=entry.alternate end
  if entry.invalid and entry.invalid~="" then lines[#lines+1]="";lines[#lines+1]="INVALID EXAMPLE";lines[#lines+1]=entry.invalid end
  if entry.corrected and entry.corrected~="" then lines[#lines+1]="";lines[#lines+1]="CORRECTED EXAMPLE";lines[#lines+1]=entry.corrected end
  if entry.related and entry.related~="" then lines[#lines+1]="";lines[#lines+1]="RELATED DOCUMENTATION";lines[#lines+1]=entry.related end
  return table.concat(lines,"\n")
end

function identify_error_reference(error_text)
  local hay=upper(tostring(error_text or ""))
  local best=nil;local best_length=0
  for _,entry in ipairs(ERROR_REFERENCE) do
    if entry.code~="UNK-001" then
      for _,needle in ipairs(entry.matches or {}) do
        local normalized=upper(needle)
        if normalized~="" and hay:find(normalized,1,true) and #normalized>best_length then
          best=entry;best_length=#normalized
        end
      end
    end
  end
  return best or ERROR_REFERENCE[#ERROR_REFERENCE]
end

function search_error_reference(query)
  local q=upper(trim(query))
  local matches={}
  for _,entry in ipairs(ERROR_REFERENCE) do
    if q=="" or error_reference_search_blob(entry):find(q,1,true) then
      matches[#matches+1]=entry
    end
  end
  return matches,q
end

function show_error_reference_search()
  show_input(
    "Error Reference Search",
    "Search by error code, title, category, technical error text, syntax, or likely fix. Matching is case-insensitive. Leave Search blank to show the complete catalog index.",
    "Search:","",nil,
    function(value)
      local matches,q=search_error_reference(value)
      if #matches==0 then
        local unknown=ERROR_REFERENCE[#ERROR_REFERENCE]
        show_info("Error Reference - No Exact Match",format_error_reference_entry(unknown,false).."\n\nSearch text: "..tostring(value),"warning",nil,"Close")
        return
      end
      local rendered={}
      local index_only=q==""
      for _,entry in ipairs(matches) do rendered[#rendered+1]=format_error_reference_entry(entry,index_only) end
      local heading=index_only and (tostring(#matches).." catalog entries. Refine the search for full explanations.") or (tostring(#matches).." matching error reference entr"..(#matches==1 and "y" or "ies")..".")
      show_info("Error Reference Results",heading.."\n\n"..table.concat(rendered,"\n\n----------------------------------------\n\n"),"info",nil,"Close")
    end,
    nil,"Search"
  )
end

function show_error_reference_entry(entry)
  entry=entry or ERROR_REFERENCE[#ERROR_REFERENCE]
  show_info("Error Reference - "..tostring(entry.code),format_error_reference_entry(entry,false),"info",nil,"Close")
end

function suggested_part_correction(source,error_text)
  local raw=trim(source)
  local normalized=upper(raw):gsub("%s+","")
  local n=normalized:match("^QT%^([1-9]%d*)%^$") or normalized:match("^Q%^([1-9]%d*)%^$")
  if n then return "QNT{"..n.."}" end
  n=normalized:match("^QUINT[%[%(%{]([1-9]%d*)[%]%)%}]$")
    or normalized:match("^QUINT%^([1-9]%d*)%^$")
    or normalized:match("^QNT[%[%(%{]([1-9]%d*)[%]%)%}]$")
    or normalized:match("^QNT%^([1-9]%d*)$")
    or normalized:match("^QNT([1-9]%d*)%^$")
  if n then return "QNT{"..n.."}" end
  n=normalized:match("^ET%(([1-9]%d*)%)$") or normalized:match("^QT%[([1-9]%d*)%]$") or normalized:match("^ENT[%[%{]([1-9]%d*)[%]%}]$")
  if n then return "ENT("..n..")" end
  n=normalized:match("^SXT[%[%(%{]([1-9]%d*)[%]%)%}]$")
  if n then return "SXT{"..n.."}" end
  n=normalized:match("^STP[%[%(%{]([1-9]%d*)[%]%)%}]$") or normalized:match("^SPT[%[%(%{]([1-9]%d*)[%]%)%}]$")
  if n then return "SPT{"..n.."}" end
  local meter,bpm,repeats=normalized:match("^(.-)@([%d%.]+)X([1-9]%d*)$")
  if meter and bpm and repeats then return meter.."x"..repeats.."@"..bpm end
  if tostring(error_text or ""):find("dash count",1,true) then
    local base,dashes=normalized:match("^(.-)(%-+)$")
    local total=base and tonumber(base:match("X([1-9]%d*)")) or 1
    if base and dashes and total and #dashes>total then return base..string.rep("-",total) end
  end
  return nil
end

function validation_issue_from_error(message,index)
  message=tostring(message or "Unknown validation error.")
  local row=tonumber(message:match("[Rr]ow%s+(%d+)"))
  local field="Workbook"
  if message:find("SECTION NAME",1,true) then field="SECTION NAME"
  elseif message:find("PARTS",1,true) then field="PARTS"
  elseif message:find("BPM",1,true) then field="BPM"
  elseif message:find("END",1,true) then field="END" end
  local entry=identify_error_reference(message)
  local source=message:match("part%s+%d+%s+%('(.-)'%)") or message:match("PARTS%s+%('(.-)'%)")
  local source_upper=upper(source or ""):gsub("%s+","")
  local preferred_code=nil
  if source_upper:match("^QNT") or source_upper:match("^QUINT") or source_upper:match("^Q%^%d+%^$") or source_upper:match("^QT%^%d+%^$") then preferred_code="SYN-006"
  elseif source_upper:match("^ET") or source_upper:match("^QT") or source_upper:match("^ENT") then preferred_code="SYN-004"
  elseif source_upper:match("^SXT") then preferred_code="SYN-005"
  elseif source_upper:match("^STP") or source_upper:match("^SPT") then preferred_code="SYN-023" end
  if preferred_code then local preferred=search_error_reference(preferred_code);entry=preferred[1] or entry end
  local correction=source and suggested_part_correction(source,message) or nil
  if not correction and source and message:find("first musical part's @BPM override",1,true) then
    correction=trim(source:gsub("@[%d%.]+", ""))
  elseif not correction and source and message:find("leading, doubled, or trailing comma",1,true) then
    correction=trim(source:gsub("^,+",""):gsub(",+$",""):gsub(",%s*,+",","))
  elseif not correction and field=="BPM" then
    local quoted=message:match("BPM%s+%('(.-)'%)")
    local numeric=quoted and quoted:match("([%d]+%.?[%d]*)")
    if numeric and tonumber(numeric) and tonumber(numeric)>0 then correction=upper(message):find("NO%s+ACCENT") and (numeric.." no accent") or numeric end
  elseif not correction and message:find("(END), PARTS",1,true) then
    correction="Leave the END row PARTS cell blank"
  elseif not correction and message:find("reserved for the automatic COUNT IN",1,true) then
    correction="INTRO"
  end
  return {
    index=index or 1,message=message,row=row,field=field,reference=entry,
    suggestion=entry and entry.fix or "Correct the reported workbook value and validate again.",
    correction=correction
  }
end

function build_validation_issues(errors)
  local issues={}
  for i,message in ipairs(errors or {}) do issues[#issues+1]=validation_issue_from_error(message,i) end
  return issues
end

function validation_issue_summary(issue)
  if not issue then return "No validation issue is selected." end
  local where=issue.row and ("Spreadsheet row "..issue.row..", "..issue.field) or issue.field
  local lines={
    where,
    "Error Reference: "..tostring(issue.reference and issue.reference.code or "UNK-001"),
    "",
    "EXACT VALIDATION ERROR",
    issue.message,
    "",
    "MOST LIKELY FIX",
    issue.suggestion or "Correct the affected workbook value and validate again."
  }
  if issue.correction then
    lines[#lines+1]="";lines[#lines+1]="SUGGESTED CORRECTION (NOT APPLIED AUTOMATICALLY)";lines[#lines+1]=issue.correction
  else
    lines[#lines+1]="";lines[#lines+1]="No high-confidence cell replacement is offered for this issue. The workbook will not be edited."
  end
  if issue.reference then lines[#lines+1]="";lines[#lines+1]=format_error_reference_entry(issue.reference,false) end
  return table.concat(lines,"\n")
end

function confirm_copy_validation_correction(issue)
  if not issue or not issue.correction then return end
  show_confirm(
    "Confirm Corrected Cell Copy",
    "The app will not edit the workbook. Copy this exact high-confidence corrected cell value to the clipboard?\n\n"..issue.correction.."\n\nReview the affected spreadsheet row before pasting.",
    "Copy Corrected Cell","Cancel",
    function()
      local ok,err=copy_to_clipboard(issue.correction)
      set_status(ok and "Suggested correction copied. Review before pasting." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
    end,nil,"warning"
  )
end

function show_validation_issue(issue)
  if not issue then show_info("Validation Issue","Select a validation-error row first.","warning",nil,"Close");return end
  local buttons={{label="Search Error Reference",value="reference",primary=true},{label="Copy Error Code",value="copy_code"}}
  if issue.correction then buttons[#buttons+1]={label="Copy Corrected Cell",value="copy_correction"} end
  buttons[#buttons+1]={label="Open Workbook",value="open"};buttons[#buttons+1]={label="Close",value="close",cancel=true}
  open_app_modal({
    title=issue.row and ("Validation Issue - Row "..issue.row) or "Validation Issue",
    message=validation_issue_summary(issue),kind="error",buttons=buttons,
    on_result=function(value)
      if value=="reference" then show_error_reference_entry(issue.reference)
      elseif value=="copy_code" then
        local code=tostring(issue.reference and issue.reference.code or "UNK-001");local ok,err=copy_to_clipboard(code);set_status(ok and ("Error code "..code.." copied.") or ("Copy failed: "..tostring(err)),ok and "success" or "error")
      elseif value=="copy_correction" then confirm_copy_validation_correction(issue)
      elseif value=="open" then
        local ok,err=shell_open(state.file_path)
        set_status(ok and "Workbook opened. Navigate to the reported row." or ("Could not open workbook: "..tostring(err)),ok and "success" or "error")
      end
    end
  })
end

function show_validation_issues()
  if not state.validation_issues or #state.validation_issues==0 then show_info("Validation Issues","No validation issues are available.","info",nil,"Close");return end
  local lines={string.format("%d validation issue%s. Select or double-click its row in the table for the full explanation and any confirmed copyable correction.",#state.validation_issues,#state.validation_issues==1 and "" or "s"),""}
  for _,issue in ipairs(state.validation_issues) do
    lines[#lines+1]=string.format("%d. %sError Reference: %s",issue.index,issue.row and ("Row "..issue.row..". ") or "",issue.reference and issue.reference.code or "UNK-001")
    lines[#lines+1]="Exact validation error:"
    lines[#lines+1]=tostring(issue.message or "Unknown validation issue.")
    lines[#lines+1]=""
  end
  show_info("Validation Issues",table.concat(lines,"\n"),"error",nil,"Close")
end


local HELP_TEXT=[[
BILDIBEAT CLICK TRACK MAPPER V10.21 HELP

CORE TERMS
Section: One non-END workbook row. Its Section name creates a standard REAPER marker at the section start; its BPM supplies the inherited underlying tempo; its PARTS cell supplies the playable structure.
Part: One playable meter/click instruction inside a PARTS cell. A part may include a bar repeat, BPM Override, and Ramp.
Block: One or more ordinary parts selected inside < > and treated as one repeatable entity. A block repeat creates additional passes but no additional REAPER section markers.
Ramp: One or more trailing dashes on an ordinary part. Each dash adds one final bar to the continuous tempo transition toward the next legal destination.
BPM Override: @BPM changes the underlying tempo for that part only. The simulated click multiplier is applied after the override.

QUICK START
1. Save the workbook and save the active REAPER project at least once as an .RPP.
2. Browse to the saved XLSX or CSV and choose Validate Only.
3. Review Validated Preview. Optionally run Validate Against Open Project for an explicit read-only comparison with the active REAPER tab.
4. Optionally enter Build Notes and open User-Friendly Song Structure for a musician-facing cue sheet.
5. Optionally choose Export MIDI + MP3 Click, or reconstruct a verified XLSX/CSV from the active project with Create Verified Workbook From Open Project. Neither action changes REAPER.
6. Choose Build Click Track Map, make the pre-build REAPER save choice, review the final confirmation, and build.
7. After verification, save the completed REAPER project when prompted.

WORKBOOK BROWSE COMPATIBILITY
Browse uses REAPER's current filtered GetUserFileName chooser when that API is available. On older REAPER installations it automatically falls back to the standard GetUserFileNameForRead chooser, then confirms that the selected file is XLSX or CSV. No optional extension supplies either chooser. WB-015 reports the unlikely case where neither core API exists.

VALIDATE AGAINST OPEN PROJECT
Validate Only checks the workbook itself. Validate Against Open Project is a separate, explicit, read-only comparison between the current validated plan and whichever REAPER project tab is active. In compact windows it is labeled Compare Open Project; compact Larger Text uses Project Match.
The comparison checks COUNT IN, standard Section marker names/order/positions, every expanded Part start, meters, calculated REAPER BPM, click accent patterns, Ramp boundaries and linear states, END, and unexpected extra standard markers or tempo events. Exact Match reports totals. Differences Found lists every mismatch with its musical context. No project, workbook, media, transport, undo, or save state is changed. When workbook validation has errors, the same fourth Workbook slot becomes Validation Issues so the complete error list remains available. The retired Validation Diff button is not present. PRJ-007 documents comparison failures and mismatches.

CREATE VERIFIED WORKBOOK FROM OPEN PROJECT
This read-only reverse-build action reconstructs a new three-column workbook from the active project. It requires COUNT IN on visible measure 1, exactly two accented 4/4 count-in bars, the first uniquely named Section marker on visible measure 3, later unique Section markers on whole-measure boundaries, supported meter denominators, one consistent accent mode per Section, exact Ramp starts/targets, and a 1/4 END boundary.
Actual Section marker names, spelling, capitalization, order, and measure positions are preserved. Ordinary repeats are compacted. Exact repeated multi-Part sequences may become < > Blocks, but detection never crosses a Section and excludes ambiguous Ramp behavior. Tuplet names are used only for exact supported effective/underlying BPM ratios; ambiguous 4/4 material remains ordinary Quarter Note syntax with an explicit @BPM override.
The compact candidate and a no-Block fallback are both expanded by the production parser. Save is offered only when one candidate matches every standard marker, tempo/time-signature event, click pattern, Ramp state, COUNT IN, and END detail one-for-one. XLSX and CSV use editable timestamped filenames. The saved file is reopened and compared again; an unverified file is deleted. The action never changes REAPER, audio/MIDI, transport, cursor, markers, tempo, undo history, or the currently loaded workbook. RCN-001 through RCN-011 document and log every failure stage.

IN-APP TEMPO EDITING
Validated Preview shows the Section name and its underlying Section BPM in the Section column. REAPER BPM is calculated from the underlying musical BPM and the Part's click multiplier; it updates automatically but is never directly editable.
Right-click a musical row and choose Edit Section BPM to stage a new inherited tempo for that entire Section. Existing Part BPM Overrides remain numerically unchanged by default. When explicit overrides exist, the wrapped context checkbox can shift each workbook override by the Section's total numerical difference from the loaded workbook. For example, changing a workbook Section from 120 to 123 changes @135 to @138. Editing it again to 126 produces @141 from the same baseline, never a cumulative drift. Separately edited Parts remain independently tracked. No Accent is always preserved, cannot be edited in the app, and COUNT IN remains normally accented.
Edit Part BPM stages an underlying BPM for the source Part represented by the selected row. The edit applies to every expanded occurrence of that source created by its xR repeat or repeated < > group. It does not edit just one generated pass. Edit END BPM changes the optional END destination tempo; blank restores the normal 25 BPM default.
Every edit is rebuilt through the production parser before it becomes visible. Revert Tempo Edit restores the selected yellow row or Shift-selected yellow rows to the currently loaded workbook values. A Section reversion updates inherited rows and returns its proportionally shifted explicit overrides to their workbook values; a Part reversion updates every Repeat/Block occurrence of that logical source. The confirmation names any Section-wide effects before proceeding, and unrelated Part edits remain staged. Reloading/validating the workbook remains the broader way to discard every edit after confirmation. The original workbook and REAPER project are not changed by reversion.
Every Preview row whose underlying BPM, calculated REAPER BPM, or Ramp destination differs from the current workbook baseline is tinted yellow. All expanded Repeat/Block occurrences generated by an edited source are included, as are COUNT-IN, END, or Ramp rows when their musical definition changes. Rows are not highlighted merely because an earlier edit shifts their clock position. A selected changed row keeps its yellow fill and blue selection edge; hovering states workbook versus staged values.

UNSAVED EDIT PROTECTION AND SESSION RECOVERY
Closing the app, choosing another workbook, unloading the workspace, resetting preferences, or reloading/validating the current workbook asks before discarding staged BPM edits. The warning reports the exact number of affected Sections and logical source Parts, plus END when applicable. Cancel keeps the staged Preview unchanged. Confirming removes both the staged edits and their temporary recovery record; the workbook and REAPER project are never changed by a discard.
Each successful tempo edit also writes a compact recovery record to REAPER's resource Data folder. It contains the workbook path, full saved-file fingerprint, source SHA-256, staged Section/Part/END edit data, and audit text. After an interruption, validate that same unchanged workbook: the production parser verifies the recovery data, then Restore Staged Edits or Discard Recovery is offered. A changed workbook fingerprint is never accepted. Safe Mode ignores recovery data without deleting it. REC-001 through REC-004 explain fingerprint mismatch, damaged data, write failure, and delete failure.

AUTOMATED VISUAL REGRESSION
Run Parser Self-Test also runs a golden responsive UI matrix for Build, History, Settings, Help, Preview footers, app dialogs, confirmation dialogs, and calendar dialogs. Compact 980 x 680, real Windows client-border 964 x 649, standard 1480 x 880, wide 2200 x 1200, wide-short 1600 x 680, and both compact/wide-short Larger Text layouts must keep their expected geometry and remain inside every pane/window boundary. A deliberate layout change requires updating the golden contract; accidental clipping, overlap, or changed breakpoints fail the self-test.

UPDATED WORKBOOK COPY
Save Updated Workbook Copy remains disabled until the exact staged tempo plan has been built and verified in the matching REAPER project. It then offers a unique editable filename such as Song_CTM_TEMPO_UPDATE_2026-07-20_143500_ID-01FB.xlsx or .csv. The source workbook is never overwritten.
For XLSX, the app copies the original package and changes only the staged BPM/PARTS cells on the validated worksheet, preserving other worksheets and ordinary workbook content. CSV keeps the source rows and replaces only staged cells. The new copy is reopened with the production parser and must match the verified plan exactly; an unverified output is deleted. After exact verification, the copy becomes the current workbook baseline automatically, its yellow differences clear, and the verified REAPER association remains valid because the musical plan is unchanged. EDT-001 through EDT-005, WBK-001 through WBK-004, and REC-001 through REC-004 document and log these workflows.

TEMPO PREVIEW
The main Build page includes a separate Tempo Preview card with a metronome icon, one editable BPM text field, and Play/Stop controls. Enter an underlying musical BPM from 20 through 400; Enter or Play starts a continuously looping four-beat Quarter Note reference, and Stop ends it. The synthesized click pitch remains unchanged.
The preferred audio path uses SWS background preview and does not rebuild or insert anything into the REAPER project. The prior Preview-row Play/Stop/Loop audition remains separate and still checks the exact click map already built in the project.

AUDIO HANDLING FOR TEMPO-MAP BUILDS
Build & Project always shows the audio policy selected for the next build. Preserve Audio Exactly is the safe default after workbook validation or a project-tab change. It snapshots every detected audio item's absolute position, length, snap offset, rate, pitch, item timebase, automatic-stretch setting, fades, take offsets, and stretch markers. Those values are restored and signature-verified after the tempo map changes, so recorded audio remains exactly where and how it was. MIDI is not stretched by this mode.
Conform Audio to New Tempo — Preserve Pitch keeps eligible audio on the same musical counts while its duration/rate follows the new tempo without changing pitch. For example, audio occupying a four-bar VERSE at 185 BPM continues to occupy those same four bars at 200 BPM and plays approximately 200/185 times as fast. REAPER's per-item Beats (position, length, rate), automatic stretch-marker system, and Preserve pitch are used during the transaction; the original source media files are never rewritten or deleted.
Conform is enabled only when the active project's standard marker names/order/measure positions, COUNT IN and END, meter/count for every bar, Repeat/Block expansion, and Ramp boundaries exactly match the validated workbook. BPM values may differ. A changed count, missing/extra/reordered marker, different meter, different Ramp topology, locked eligible item, mixed audio/MIDI item, or item crossing COUNT IN/END blocks Conform rather than guessing. Audio wholly outside COUNT IN through END remains unchanged.
The final confirmation and logfile show the selected policy and item counts. Build, audio changes, verification, and rollback use one REAPER undo transaction. A failed build must restore and verify both marker/tempo and audio signatures. Undo Last Build also verifies the pre-build audio signature. AUD-005 through AUD-008 document structure, item-eligibility, Preserve verification, and Conform verification failures.

MIDI + MP3 CLICK PACKAGE
Export MIDI + MP3 Click creates two new files from the complete current validated plan without rebuilding or changing the REAPER project. One editable Save As base name produces a type-1 .mid and an audible .mp3 with matching filenames. Existing files are never replaced.
The MIDI file contains a dedicated tempo/meter/marker track plus a General MIDI channel-10 wood-block click track. It includes automatic COUNT IN, every meter and Section marker, calculated tempo events for note-value multipliers and Ramps, and an END marker. With Generic Part Names off, MIDI markers retain the workbook Section names. With Generic Part Names on in User-Friendly Song Structure, the next MIDI export uses PART 1, PART 2, and so on while retaining COUNT IN and END. Import its tempo and time-signature data in Logic or Pro Tools to create the correct bar grid. The MP3 uses the app's current A/B click frequencies and follows the same schedule.
The permanent files do not use REAPER's live metronome playback. Playback/record click toggles, count-in options, beat-pattern settings, and metronome routing cannot omit exported clicks. Before writing final files, the app calculates the exact required click count from every Part, Repeat, and Block pass; both the audio event schedule and explicit MIDI note count must equal it, and WAV rendering must consume every onset. A mismatch cancels export instead of producing a partial package.
Both formats start immediately with COUNT IN at time zero. No leading silence or separate intro tail is added. No MIDI note is placed at END and the MP3 adds no extra beat; it contains only a 75 ms audio safety tail after the validated musical endpoint so the final click is not cut off. MP3 encoder padding may add a tiny technical delay beyond the authored audio.
The MIDI tempo map uses calculated REAPER BPM where a click multiplier requires it so tuplets and simulated click types retain exact bar timing. Human-facing readouts continue to show underlying musical BPM. CPX-001 through CPX-006 cover stale validation, destination, MIDI, audio, REAPER conversion, and final-file failures.
The export action retains its verified result table through the protected transaction before it opens the success confirmation, so a completed export cannot be followed by a boolean-result indexing error.

COMPLETE SPREADSHEET EXAMPLE
Copy Spreadsheet Example copies this exact labeled example:

SECTION NAME | BPM | PARTS
INTRO | 120 | [4]x2, (7)x3@135--
VERSE | 160 | {9}x2@160, *11*x2@170-
CHORUS | 120 | ENT(4)x2@120, SXT{7}x2@100-
BRIDGE | 90 | QNT{5}x2@90-, <[3]x2@140, SXT{5}@110->x2
BREAKDOWN | 110 no accent | SPT{7}x2@110-
OUTRO | 130 | [4]x2@130--
END | 90 |

SYNTAX
[N] creates N/4 with a Quarter Note click.
(N) creates N/8 with an Eighth Note click.
{N} creates N/16 with a Sixteenth Note click.
*N* creates N/32 with a Thirty-Second Note click.
ENT(N) creates N/4 at underlying BPM x1.5: Eighth Note Triplet.
SXT{N} creates N/4 at underlying BPM x3: Sextuplet.
QNT{N} creates N/4 at underlying BPM x5: Quintuplet.
SPT{N} creates N/4 at underlying BPM x7: Septuplet.
Whitespace is ignored, so QNT {N} is accepted and normalized to QNT{N}.
xR or XR repeats an ordinary part for R total bars. A block-level xR repeats the complete < > block for R passes. R is a positive whole number; omitted means one.
@BPM is the BPM Override for that ordinary part. It does not change the Section BPM inherited by later parts.
One trailing dash is a one-bar Ramp; two dashes are a two-bar Ramp, and so on. Dashes must be last on an ordinary part.
Token order is meter, optional xR, optional @BPM, then trailing ramp dashes.
A Section BPM may be written as "120 no accent" to make every musical beat in that Section an A click. Case and extra spaces are accepted. COUNT IN keeps its normal accented first beat; the next Section returns to normal accenting unless it also says no accent.

BLOCK RULES
<PART, PART, ...> selects ordinary parts as one Block. <PART, PART, ...>xR repeats the whole Block for R passes.
Blocks stay inside one PARTS cell, cannot nest, and may not carry a trailing block Ramp or block-level @BPM after >.
Part-level Repeat, BPM Override, and Ramp modifiers remain valid inside a Block.
A non-final internal Ramp targets the next part inside the Block on every pass.
A final internal Ramp targets the first part of the next Block pass. It is inactive on the final pass and cannot escape the closing > boundary.
A one-pass Block cannot end with an internal Ramp because no next pass exists; validation asks you to remove the dash or repeat the Block.
A normal part before a Block may Ramp into the Block's first part. A part after the completed Block begins normally unless its preceding outside part provides a legal Ramp.

COUNT-IN, END, AND FIRST BPM
COUNT IN is always two bars of 4/4 in visible measures 1-2. Its BPM is the first musical Section BPM, and spreadsheet processing starts at measure 3. COUNT IN is reserved as a Section name.
The first musical part may omit @BPM or match the first Section BPM exactly. A different first-part BPM Override is rejected. Eighth Note Triplet, Sextuplet, Quintuplet, and Septuplet parts remain valid because their multiplier changes effective REAPER BPM without changing the underlying Section BPM.
END is the required final row. END PARTS is blank. A legal final outside Ramp targets the END BPM; otherwise the standard non-ramped END behavior is used.

SYNTAX BADGES AND PLAIN ENGLISH
Show Syntax Badges uses readable, uniformly capitalized labels rather than unexplained abbreviations: Quarter Note, Eighth Note, Sixteenth Note, Thirty-Second Note, Eighth Note Triplet, Sextuplet, Quintuplet, Septuplet, Repeat x2, BPM Override: 150, Ramp: 1 Bar, Ramp: 2 Bars, Ramp Inactive, No Accent, and Block Pass 1 of 2.
Single-click a Preview row for a concise bottom-bar translation. Right-click or press Enter on a focused row for the complete readout and actions. Terminology is identical in Preview, the Scratchpad, copied readouts, Song Structure Readout, Help, Error Reference, and README.

PREVIEW MOUSE AND KEYBOARD
Single-click selects one row. Shift-click or Shift+Up/Down extends a contiguous audition selection across Part and Section rows. Double-click a valid Preview row to jump to its part; double-click END to jump to the standard END marker. Right-click opens Copy Readout, selection-aware Copy Syntax, Send to Scratchpad, contextual jump actions, and Jump to Ramp only when that row has an active Ramp. Copy Syntax copies one selected Part per Preview row in top-to-bottom order; a single row inside a Block copies only that row's Part rather than the entire Block expression. Send to Scratchpad converts the highlighted playable rows into one ordered expression with explicit underlying BPM values, opens Help, validates it, and waits for Play Preview; it never starts audio or changes REAPER automatically.
Play auditions the selected rows once; Loop repeats them; Stop returns the edit cursor to the earliest selected Part. The audition range ends 20 milliseconds before the following Part's downbeat, and one-shot audition temporarily enables REAPER's native "stop playback at end of loop if repeat is disabled" transport behavior. A selected [4]x2 therefore plays exactly eight clicks rather than including click one of the next Part. 50% Speed temporarily uses half project playrate with master-playrate preserve pitch. Audition is enabled after either a current verified build or an exact Validate Against Open Project result, so a matching existing click map can be auditioned without rebuilding. The authorization is bound to the exact validated plan, active project tab, and project marker/tempo/click signature. Audition restores the previous time selection, loop, repeat, native stop-at-loop-end setting, playrate, and preserve-pitch state. END is not auditionable.
Tab or Shift+Tab moves app focus. When Validated Preview is focused, Up/Down selects rows, Shift+Up/Down extends the range, Home/End selects the first/last row, and Enter or Shift+F10 opens row actions. There are no J or R shortcuts.
Enter or Space activates a focused button. Escape closes row actions or cancels a supported modal. Ctrl+O opens Browse, Ctrl+F opens Error Reference Search, and F1 opens Help.

TEXT EDITING
All app-owned text fields share one editor. Click to position the caret; drag or Shift+Arrow to select; double-click selects a word. Left/Right, Home/End, Ctrl+Left/Right, Backspace/Delete, and Ctrl+Backspace/Delete edit in place. Ctrl+A/C/X/V provide select all, copy, cut, and paste. Long fields scroll horizontally. Windows-owned title bars and Save As dialogs follow Windows settings.

SYNTAX SCRATCHPAD
The non-mutating Help Scratchpad uses the production workbook parser. Test Syntax reports validity, normalized syntax, expanded parts/blocks/bars, and full plain-English results. Reset Syntax Example restores Section BPM 120 and:
[4]x2, (7)x3@135--, {9}x2@160, *11*x2@170-, ENT(4)x2@120, SXT{7}x2@100-, QNT{5}x2@90-, SPT{7}x2@80-, <[3]x2@140, SXT{5}@110->x2
It then tests the restored example. Copy Normalized and Copy Readout copy the complete untruncated Scratchpad result. Play Preview renders and plays the complete parsed expression without inserting media or changing the project; Stop, Loop, and 50% Speed control that preview. Preview-row Send to Scratchpad can populate this expression from one or more highlighted playable rows. The result wraps and scrolls. Preview-audio failures use AUD-001 through AUD-004; build-audio failures use AUD-005 through AUD-008 in Error Reference.

SONG STRUCTURE READOUT
User-Friendly Song Structure opens a chronological musician-facing cue sheet with the clean workbook title, Section headings, bar counts, meter, optional BPM, click type, and Ramp destinations. Block/pass/parser wording is flattened away. Simplified Readout shows only COUNT-IN, Section headings, numerator, Part repeat, and click type; repeated groups appear in parentheses followed by xR and never use the word Block. Measure Numbers and Show BPM are independent in full and Simplified modes; Show BPM controls COUNT-IN, every Part, and Ramp destinations and always displays underlying musical BPM. Generic Part Names replaces musical Section headings with PART 1, PART 2, and so on in the on-screen readout, Duration Calculator, text export, print, and subsequent MIDI click-package marker metadata while retaining COUNT-IN and END explicitly; workbook names and REAPER project markers never change. The Duration Calculator shows COUNT-IN, every Section/Part label, Musical Content, and Total with Count-In as MM:SS using full-precision meter/tempo/Repeat/Block/Ramp math before whole-second display rounding. Export and Print use every active toggle. Page numbering, headers, and footers are controlled by the browser/operating-system print dialog.

HISTORY DATES
History Date From and Date To are inclusive. Type MM-DD-YYYY or use Calendar. Previous/Next Month changes the view; Today selects today; Clear Date clears one endpoint; Clear Range clears both. Date From may not be later than Date To. Arrow keys move the calendar selection, Enter chooses it, T selects today, and Delete clears the active date.

VALIDATION ISSUES AND ERROR REFERENCE
All error and explanation text wraps, scrolls, and can be copied in full; long syntax tokens are split visually instead of becoming unreadable ellipses. A validation row provides Search Error Reference, Copy Error Code, Copy Readout, Copy Syntax, and Open Workbook. Copy Corrected Cell appears only when an exact high-confidence replacement exists and always asks for confirmation. The workbook is never edited automatically.
Error Reference search matches code, title, category, technical text, syntax, and likely fix. Blank search shows the entire catalog. Entries include what happened, why it matters, likely fix, alternate next step, examples, and related documentation.
Open Workbook is permanently available in Build & Project whenever a workbook is selected, including after a successful build.

REAPER PROJECT SAVE WORKFLOW
The Readiness label "REAPER project saved at least once" means an .RPP filename/location exists; current project changes may still be unsaved.
Before a build, Save REAPER Project As opens a unique editable suggestion such as OriginalSong_CTM_PREBUILD_BACKUP_YYYY-MM-DD_HHMMSS.RPP. Continue Without Saving proceeds without writing current REAPER project changes; Cancel Build changes nothing.
After a verified build, the app clearly states that the map changed the active REAPER project in memory and offers a save. A completed-copy suggestion uses OriginalSong_CTM_COMPLETED_BUILD_YYYY-MM-DD_HHMMSS_ID-01FB.RPP. The filename is editable, .RPP is appended when needed, and collisions receive a numeric suffix. These prompts refer to the REAPER project, not the workbook or app state.
If REAPER does not create and activate the exact requested .RPP path, the app reports the failure instead of claiming a save; Error Reference PRJ-006 documents recovery.

ACCESSIBILITY, RESIZING, AND TOOLTIPS
Larger text throughout app is a persisted Settings toggle that increases every app-owned label, table, dialog, error, tooltip, Help line, and Scratchpad result by about 50 percent, with a minimum six-point increase. Dedicated high-visibility spacing, row-height, wrapping, scroll, pane, calendar, and modal rules keep content inside the app. Dynamic resizing recomputes all panes and modal bounds; the supported minimum is 980 by 680, and Restore Default Layout resets the window, panels, Preview columns, and horizontal scroll to the 1480 by 880 default.
Remember Layout now controls window size/position, panel sizes, Preview column widths, and Preview horizontal scroll together. Validation errors are always complete and wrapped. Diagnostics opens one panel containing Copy Diagnostics and Create Support Bundle. Clean Up Logs appears only in Settings. Unload Current Workbook, Browse, Recent Files, Validate Only, Reset App Preferences, the app Close control, and the window close action warn before discarding unsaved staged tempo edits.
Typography is scoped by purpose: explanations, definitions, and musician-facing prose use Segoe UI. Consolas is reserved for editable syntax fields, raw workbook/PARTS examples, and the Scratchpad's normalized syntax output; a prose line does not switch fonts merely because it mentions ENT(N), SXT{N}, QNT{N}, SPT{N}, or another token.
The bottom bar says TOOLTIP for hover help and shows only information relevant to the active pane. Disabled controls, status badges, Readiness checks, buttons, fields, calendars, and save actions explain their exact behavior or missing prerequisite.

CLICK FREQUENCIES AND REAPER TIMEBASE
The SWS/S&M Extension is required for project click frequencies and the 50% audition's temporary Preserve pitch setting. Settings > Logging > Click Frequencies stores editable defaults: primary A 1760 Hz and secondary B 1600 Hz. A build applies and verifies them and enables REAPER's native metronome so the generated clicks are audible. A failed build restores the earlier metronome state and frequencies; Undo Last Build restores both pre-build settings. Starting an audition also verifies that the metronome is enabled and leaves it enabled. One hidden Metronome-settings session is reused for the build. Preview and audition readiness do not open it, so the window must not flash continuously. A single brief appearance may occur on some Windows systems when that hidden session is created. Bildibeat Click Track Mapper does not replace clipboard contents.
Outside the app's explicit audio policy, MIDI, automation, and nonstandard project content still follow REAPER's project/track/item timebases. Review File > Project Settings > Project Settings and Help > Project timebase help before Build. Time preserves clock placement; Beats (position only) follows beat starts without automatically stretching lengths/rates; Beats (position, length, rate) follows the musical grid and may rate-stretch audio. The tempo/time-signature envelope has Time, Beats, and hybrid Time Signature: Beats, Tempo: Time choices.
For the 50% audition's master preserve-pitch option, show the Transport Rate control by right-clicking the Transport background if needed, then right-click the Rate control. Individual audio-item Preserve pitch when changing rate is in Media Item Properties (select the item and press F2). Audition temporarily enables and then restores the master-playrate option.

BUILD SAFETY, LOGGING, AND SAFE MODE
The app maintains a read-only automatic REAPER project snapshot after validation and refreshes it when the project changes; there is no separate Build Preview or Export Preview control. Immediately before a build, it rereads the saved source, verifies its original fingerprint and plan, reapplies staged cell edits in memory, requires that rebuilt hash to equal the displayed Preview table, and runs fresh structure and audio-policy preflights before project modification. It then uses one REAPER undo block, enables and verifies the native metronome, applies and verifies the selected audio policy, verifies tempo, meter, per-measure click patterns, and A/B frequencies, and automatically rolls back a failed build when possible. Undo Last Build changes REAPER only: the displayed workbook/staged plan stays loaded, is clearly marked as not applied, and must be rebuilt before audition or updated-workbook saving. Attempts that receive an ID are logged with source and staged plan/workbook hashes, every tempo edit, exact durations, click patterns, audio policy and impact counts, Build Notes, exact errors, and Error Reference matches beside the saved .RPP in SONG STRUCTURE BUILD LOGS.
Run Bildibeat_Click_Track_Mapper_Safe_Mode_v10_21.lua beside this main script to ignore saved workspace/layout state and tempo-recovery restoration for one run without deleting either. Safe Mode retains the full v10.21 parser, read-only verified workbook reconstruction from the open project, staged tempo editing, discard guards, selection-aware Revert Tempo Edit, yellow workbook-difference rows, verified workbook-copy adoption, Preserve/Conform audio policies, Tempo Preview, Scratchpad audio preview and Send to Scratchpad, SPT Septuplets, no-accent Sections, click frequencies, badges, accessibility, Help, Error Reference, User-Friendly Song Structure, durations, row audition, calendar, save workflows, logging, automated visual-regression contracts, and verification.

ABOUT
Bildibeat Click Track Mapper v10.21
Made by Bidlibop
]]
if rawget(_G,"CTM_TEST_PROGRESS") then _G.CTM_TEST_PROGRESS("definitions complete") end
preference_migration=migrate_saved_preferences()
saved_click_a=not SAFE_MODE and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"click_a_hz")) or DEFAULT_CLICK_A_HZ
saved_click_b=not SAFE_MODE and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"click_b_hz")) or DEFAULT_CLICK_B_HZ
if not valid_click_frequency(saved_click_a) then saved_click_a=DEFAULT_CLICK_A_HZ end
if not valid_click_frequency(saved_click_b) then saved_click_b=DEFAULT_CLICK_B_HZ end
state={
  file_path=SAFE_MODE and "" or (reaper.GetExtState(EXTSTATE_SECTION,"last_file") or ""),
  plan=nil,base_plan=nil,tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""},tempo_edit_history={},tempo_edit_log={},updated_workbook_copy="",pending_tempo_recovery=nil,suppress_tempo_recovery=false,
  preview_rows={},errors={},validation_issues={},status="Choose a saved XLSX or CSV file, then validate it.",status_kind="info",
  preview_vscroll=0,preview_hscroll=0,selected_preview_row=nil,preview_selection_anchor=nil,preview_selection_start=nil,preview_selection_end=nil,hover_preview_row=nil,
  column_widths=(ext_bool("remember_layout",ext_bool("remember_window",true)) and parse_number_list(reaper.GetExtState(EXTSTATE_SECTION,"column_widths"),DEFAULT_COLUMNS) or parse_number_list("",DEFAULT_COLUMNS)),
  resize_col=nil,resize_start_x=0,resize_start_width=0,last_divider_click_time=0,last_divider_click_col=nil,
  mouse_down_last=false,right_mouse_down_last=false,suppress_click_until_release=false,action_consumed_this_frame=false,
  active_press_layer=nil,press_consumed=false,after_release_queue={},base_input_block_until=0,
  last_row_click_time=0,last_row_click_index=nil,
  current_attempt=nil,current_log_path=nil,build_status="NOT RUN",log_status="N/A",original_build_id="",plan_was_undone=false,
  last_successful_build=nil,last_verified_project_match=nil,build_notes="",pending_build=nil,confirm_modal=nil,app_modal=nil,operation_busy=false,active_attempt=nil,last_key=0,
  prebuild_saved_copy=false,prebuild_saved_path="",prebuild_skipped=false,
  audio_tempo_mode=AUDIO_MODE_PRESERVE,audio_tempo_analysis=nil,
  recent_files=SAFE_MODE and {} or load_recent_files(),history={},history_folder="",history_filter="ALL",history_song="ALL",history_notes_search="",history_id_search="",history_date_from="",history_date_to="",history_selected=nil,history_scroll=0,
  history_limit=100,recent_limit=10,remember_history_filters=ext_bool("remember_history_filters",true),remember_last_page=ext_bool("remember_last_page",true),remember_layout=ext_bool("remember_layout",ext_bool("remember_window",true)),help_scroll=0,
  hover_context="",status_until=0,row_popover=nil,preview_table_bounds=nil,song_readout_show_measures=false,song_readout_show_bpm=false,song_readout_simplified=false,song_readout_generic_names=false,
  preview_density=(SAFE_MODE and "COMFORTABLE" or (reaper.GetExtState(EXTSTATE_SECTION,"preview_density")~="" and reaper.GetExtState(EXTSTATE_SECTION,"preview_density") or "COMFORTABLE")),alternating_rows=ext_bool("alternating_rows",true),section_emphasis=ext_bool("section_emphasis",true),show_syntax_badges=ext_bool("show_syntax_badges",true),show_row_explanations=ext_bool("show_row_explanations",true),
  show_hashes=ext_bool("show_hashes",false),show_full_path=ext_bool("show_full_path",false),developer_mode=ext_bool("developer_mode",false),larger_text=ext_bool("larger_text",false),click_a_hz=saved_click_a,click_b_hz=saved_click_b,
  audition_loop=true,audition_half_speed=false,audition_active=false,audition_restore=nil,
  audio_preview=nil,audio_preview_cleanup={},scratchpad_preview_loop=false,scratchpad_preview_half_speed=false,
  tempo_audition_bpm=120,tempo_audition_taps={},tempo_dial_dragging=false,
  tempo_preview_field={value="120",cursor=3,anchor=3,view_start=0},tempo_preview_has_focus=false,
  history_panel_height=(ext_bool("remember_layout",ext_bool("remember_window",true)) and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"history_panel_height"))) or 300,
  history_resize_active=false,history_resize_start_y=0,history_resize_start_height=0,
  side_panel_height=(ext_bool("remember_layout",ext_bool("remember_window",true)) and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"side_panel_height"))) or 0,
  side_panel_resize_active=false,side_panel_resize_start_y=0,side_panel_resize_start_height=0,
  side_panel_resize_current_height=0,
  validation_project=nil,dry_run=nil,preview_stale=false,project_changed=false,dry_run_stale=false,previous_plan=nil,validation_diff_lines={},validation_diff_targets={},changed_preview_rows={},staged_changed_rows={},staged_change_details={},
  last_workbook_check=0,last_project_check=0,validated_timestamp="",environment_ok=false,environment_issues={},
  interrupted_logs={},reconstruction_log={},last_reconstruction_log_path="",last_reconstructed_workbook="",show_details=nil,comparison_open=false,comparison_lines={},comparison_vscroll=0,comparison_hscroll=0,
  comparison_vdrag=false,comparison_hdrag=false,theme="DARK",preference_migration=preference_migration,
  focus_controls={},focus_next={},focus_index=nil,focus_draw_index=0,focus_view=nil,keyboard_activate_index=nil,keyboard_activate_label=nil,base_focus_enabled=true,
  scratchpad_fields={{label="Section BPM",value=SCRATCHPAD_DEFAULT_BPM,cursor=#SCRATCHPAD_DEFAULT_BPM,anchor=#SCRATCHPAD_DEFAULT_BPM,view_start=0},{label="PARTS expression",value=SCRATCHPAD_DEFAULT_PARTS,cursor=#SCRATCHPAD_DEFAULT_PARTS,anchor=#SCRATCHPAD_DEFAULT_PARTS,view_start=0}},scratchpad_focus=0,scratchpad_has_focus=false,scratchpad_result=nil,scratchpad_result_scroll=0
}

if TEST_MODE then
  state.environment_ok,state.environment_issues=true,{}
else
  state.environment_ok,state.environment_issues=environment_check()
end
if rawget(_G,"CTM_TEST_PROGRESS") then _G.CTM_TEST_PROGRESS("state initialized") end
if state.show_syntax_badges and tonumber(state.column_widths[3])==190 then state.column_widths[3]=DEFAULT_COLUMNS[3] end
if state.remember_layout and not SAFE_MODE then state.preview_hscroll=tonumber(reaper.GetExtState(EXTSTATE_SECTION,"preview_hscroll")) or 0 end
if state.remember_last_page and not SAFE_MODE then local av=reaper.GetExtState(EXTSTATE_SECTION,"active_view");if av~="" then state.active_view=av end end
state.pending_tempo_recovery=load_tempo_edit_recovery()

set_status=function(text,kind)
  state.status=text;state.status_kind=kind or "info";state.status_until=reaper.time_precise()+4.0
end

-- Queue callbacks that may open another modal or a native Windows dialog until
-- the current physical mouse press has been fully released. This prevents one
-- press from being reinterpreted by a newly exposed control or dialog.
function queue_after_mouse_release(fn)
  if not fn then return end
  local mouse_is_down=(gfx.mouse_cap&1)==1
  if mouse_is_down or state.active_press_layer~=nil then
    state.after_release_queue[#state.after_release_queue+1]=fn
  else
    fn()
  end
end

function run_after_release_queue()
  if #state.after_release_queue==0 then return end
  local queued=state.after_release_queue
  state.after_release_queue={}
  for _,fn in ipairs(queued) do fn() end
end

-- Base actions are never executed directly from a mouse-down frame. They are
-- released only after the physical press is up, and are discarded if any modal
-- or build workflow is active. This is a second independent guard in addition to
-- the topmost-layer click router.
function run_base_action(fn)
  if not fn then return end
  if state.app_modal or state.confirm_modal or state.comparison_open or state.row_popover or state.operation_busy then return end
  queue_after_mouse_release(function()
    if state.app_modal or state.confirm_modal or state.comparison_open or state.row_popover or state.operation_busy then return end
    if reaper.time_precise() < (state.base_input_block_until or 0) then return end
    fn()
  end)
end

function quarantine_base_input(seconds)
  local until_time=reaper.time_precise()+(seconds or 0.30)
  state.base_input_block_until=math.max(state.base_input_block_until or 0,until_time)
  state.suppress_click_until_release=true
end

function top_input_layer(ui_state)
  if ui_state.app_modal then return "APP_MODAL" end
  if ui_state.confirm_modal then return "CONFIRM_MODAL" end
  if ui_state.comparison_open then return "COMPARISON_MODAL" end
  if ui_state.row_popover then return "ROW_POPOVER" end
  return "BASE"
end


-- In-app modal framework. Ordinary warnings, confirmations, text input, and errors
-- are rendered inside the gfx window so they cannot fall behind the app. Native
-- file chooser / Save As dialogs remain system dialogs by necessity.
function open_app_modal(opts)
  opts=opts or {}
  state.row_popover=nil
  local buttons=opts.buttons or {{label="OK",value="ok",primary=true,cancel=true}}
  local input=opts.input~=nil and tostring(opts.input) or nil
  local fields=opts.fields
  if fields then
    for _,field in ipairs(fields) do
      field.value=tostring(field.value or "")
      field.cursor=#field.value
      field.anchor=field.cursor
      field.view_start=0
    end
  end
  state.app_modal={
    title=opts.title or SCRIPT_NAME,
    message=tostring(opts.message or ""),
    kind=opts.kind or "info",
    buttons=buttons,
    on_result=opts.on_result,
    input=input,
    input_cursor=input and #input or nil,
    input_anchor=input and #input or nil,
    input_view_start=0,
    input_label=opts.input_label or "",
    input_hint=opts.input_hint or "",
    fields=fields,
    checkbox=opts.checkbox and {label=tostring(opts.checkbox.label or ""),value=opts.checkbox.value==true,help=tostring(opts.checkbox.help or "")} or nil,
    active_field=1,
    focus_slot=1,
    validator=opts.validator,
    fields_validator=opts.fields_validator,
    on_change=opts.on_change,
    plain_text=opts.plain_text==true,
    body_font_size=tonumber(opts.body_font_size),
    error="",
    scroll=0,
    vdrag=false,
    opened_at=reaper.time_precise()
  }
  quarantine_base_input(0.20)
end

function finish_app_modal(value)
  local modal=state.app_modal
  if not modal then return end
  local input=modal.input
  local chosen=nil
  for _,b in ipairs(modal.buttons or {}) do if b.value==value then chosen=b;break end end
  if chosen and chosen.disabled then modal.error=tostring(chosen.disabled_reason or "This option is not currently available.");return end
  if chosen and chosen.primary and modal.validator then
    local ok,err=modal.validator(input or "")
    if not ok then modal.error=tostring(err or "Invalid value.");return end
  end
  if chosen and chosen.primary and modal.fields_validator then
    local ok,err=modal.fields_validator(modal.fields or {})
    if not ok then modal.error=tostring(err or "Invalid filter value.");return end
  end
  if chosen and chosen.stay_open then
    if modal.on_result then
      local callback=modal.on_result;local callback_input=input or "";local callback_fields=modal.fields;local callback_checkbox=modal.checkbox and modal.checkbox.value or false
      queue_after_mouse_release(function() callback(value,callback_input,callback_fields,callback_checkbox) end)
    end
    quarantine_base_input(0.18);return
  end
  state.app_modal=nil
  quarantine_base_input(0.35)
  if modal.on_result then
    local callback=modal.on_result
    local callback_input=input or ""
    local callback_fields=modal.fields;local callback_checkbox=modal.checkbox and modal.checkbox.value or false
    queue_after_mouse_release(function() callback(value,callback_input,callback_fields,callback_checkbox) end)
  end
end

function modal_button_value(modal,role)
  for _,button in ipairs((modal and modal.buttons) or {}) do if button[role] and not button.disabled then return button.value end end
  return nil
end

show_info=function(title,message,kind,on_close,close_label)
  open_app_modal({title=title,message=message,kind=kind or "info",buttons={{label=close_label or "OK",value="ok",primary=true,cancel=true}},on_result=function() if on_close then on_close() end end})
end

function show_confirm(title,message,yes_label,no_label,on_yes,on_no,kind)
  open_app_modal({
    title=title,message=message,kind=kind or "warning",
    buttons={{label=yes_label or "Continue",value="yes",primary=true},{label=no_label or "Cancel",value="no",cancel=true}},
    on_result=function(value) if value=="yes" then if on_yes then on_yes() end else if on_no then on_no() end end end
  })
end

show_input=function(title,message,label,initial,validator,on_submit,on_cancel,submit_label)
  open_app_modal({
    title=title,message=message,kind="input",input=initial or "",input_label=label or "",validator=validator,
    buttons={{label=submit_label or "Save",value="save",primary=true},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value,input) if value=="save" then if on_submit then on_submit(input) end else if on_cancel then on_cancel() end end end
  })
end

function clear_errors()
  state.errors={};state.validation_issues={}
  if state.plan then set_status("Errors cleared. Validated preview preserved.","info") else set_status("Errors cleared. File selection preserved.","info") end
end

function clear_preview_selection()
  state.selected_preview_row=nil;state.preview_selection_anchor=nil;state.preview_selection_start=nil;state.preview_selection_end=nil
end

function intentionally_discard_tempo_recovery()
  state.suppress_tempo_recovery=true
  local ok,err=clear_tempo_edit_recovery()
  if not ok then state.tempo_edit_log[#state.tempo_edit_log+1]="[REC-004] Tempo recovery could not be deleted: "..tostring(err) end
end

function confirm_discard_staged_edits(action_description,confirm_label,on_confirm)
  if tempo_edits_empty(state.tempo_edits) then on_confirm();return false end
  local scope_text=tempo_edit_scope_text(state.base_plan,state.plan)
  local recovery_notice=SAFE_MODE and "Safe Mode has not written a tempo-recovery copy for these edits." or "The recovery copy for these staged edits will also be deleted."
  show_confirm(
    "Discard Unsaved Tempo Edits?",
    tostring(action_description).." will discard the BPM edits currently staged in the app. The staged differences currently affect "..scope_text..". They have not been saved to an updated workbook copy.\n\n"..recovery_notice.." The original workbook and REAPER project will not be changed by discarding them.",
    confirm_label or "Discard Edits","Cancel",on_confirm,nil,"warning"
  )
  return true
end

function apply_tempo_edit_recovery(record,recovered_plan)
  state.tempo_edits=clone_tempo_edits(record.edits);state.tempo_edit_history={};state.tempo_edit_log={table.unpack(record.log or {})}
  state.tempo_edit_log[#state.tempo_edit_log+1]="RECOVERED SESSION: fingerprint-matched staged tempo edits restored"
  state.suppress_tempo_recovery=false;state.pending_tempo_recovery=record
  refresh_staged_plan(recovered_plan)
  local scope_text=tempo_edit_scope_text(state.base_plan,recovered_plan)
  persist_tempo_edit_recovery()
  set_status("Recovered unsaved tempo edits affecting "..scope_text..".","success")
end

function maybe_offer_tempo_edit_recovery()
  if SAFE_MODE or TEST_MODE then return false end
  local record=state.pending_tempo_recovery;if not record then return false end
  if record.load_error then
    show_info("Tempo Recovery Could Not Be Read","[REC-002] A saved tempo-recovery record exists, but it is damaged or incomplete and cannot be restored. It will be removed.\n\n"..tostring(record.load_error),"warning",function()clear_tempo_edit_recovery()end)
    return true
  end
  local recovery_matches,mismatch_kind=tempo_recovery_matches_plan(record,state.file_path,state.base_plan)
  if mismatch_kind=="path" then return false end
  if not recovery_matches then
    show_info("Tempo Recovery Does Not Match This Workbook","[REC-001] Unsaved tempo edits were found for this workbook path, but the saved workbook contents have changed since those edits were staged. The recovery record cannot be applied and will be removed.\n\nThe newly validated workbook remains unchanged.","warning",function()clear_tempo_edit_recovery()end)
    return true
  end
  local recovered_plan,recovery_errors=rebuild_plan_from_tempo_edits(state.base_plan,record.edits)
  if not recovered_plan then
    show_info("Tempo Recovery Could Not Be Restored","[REC-002] The fingerprint-matched recovery record did not pass the current production parser and will be removed. The workbook remains loaded at its saved values.\n\n"..table.concat(recovery_errors or {"Unknown recovery validation error."},"\n"),"warning",function()clear_tempo_edit_recovery()end)
    return true
  end
  local scope_text=tempo_edit_scope_text(state.base_plan,recovered_plan)
  show_confirm(
    "Recover Unsaved Tempo Edits?",
    "Bildibeat Click Track Mapper found fingerprint-matched unsaved BPM edits from an earlier interrupted or closed session. They affect "..scope_text..".\n\nRestore them to the staged Preview? The workbook and REAPER project will not be changed until their separate save/build actions are used.",
    "Restore Staged Edits","Discard Recovery",
    function()apply_tempo_edit_recovery(record,recovered_plan)end,
    function()intentionally_discard_tempo_recovery();set_status("Saved tempo-edit recovery discarded. The validated workbook values remain loaded.","info")end,
    "warning"
  )
  return true
end

function clear_session(force)
  if not force and not tempo_edits_empty(state.tempo_edits) then confirm_discard_staged_edits("Unloading the current workbook","Unload and Discard Edits",function()clear_session(true)end);return end
  if not tempo_edits_empty(state.tempo_edits) then intentionally_discard_tempo_recovery() end
  if state.audition_active then restore_audition_state() end
  if stop_audio_preview then stop_audio_preview() end
  state.file_path="";state.plan=nil;state.base_plan=nil;state.tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""};state.tempo_edit_history={};state.tempo_edit_log={};state.updated_workbook_copy="";state.preview_rows={};state.errors={};state.validation_issues={};state.preview_vscroll=0;state.preview_hscroll=0;clear_preview_selection()
  state.current_attempt=nil;state.current_log_path=nil;state.build_status="NOT RUN";state.log_status="N/A";state.original_build_id="";state.last_successful_build=nil;state.last_verified_project_match=nil;state.plan_was_undone=false
  state.validation_project=nil;state.dry_run=nil;state.preview_stale=false;state.project_changed=false;state.dry_run_stale=false;state.build_notes="";state.staged_changed_rows={};state.staged_change_details={};state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil
  state.comparison_open=false;state.comparison_lines={};state.comparison_vscroll=0;state.comparison_hscroll=0;state.app_modal=nil;state.row_popover=nil
  reaper.SetExtState(EXTSTATE_SECTION,"last_file","",true)
  set_status("Current workbook unloaded. Choose another spreadsheet.","info")
end

function choose_file(force)
  if state.operation_busy or state.app_modal or state.confirm_modal or state.comparison_open then return end
  if not force and not tempo_edits_empty(state.tempo_edits) then confirm_discard_staged_edits("Choosing another workbook","Choose and Discard Edits",function()choose_file(true)end);return end
  local initial=state.file_path~="" and state.file_path or ""
  local path,dialog_error,cancelled=choose_workbook_path(initial)
  if path then
    if not tempo_edits_empty(state.tempo_edits) then intentionally_discard_tempo_recovery() end
    if state.audition_active then restore_audition_state() end
    if stop_audio_preview then stop_audio_preview() end
    state.file_path=path;reaper.SetExtState(EXTSTATE_SECTION,"last_file",path,true)
    state.plan=nil;state.base_plan=nil;state.tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""};state.tempo_edit_history={};state.tempo_edit_log={};state.updated_workbook_copy="";state.preview_rows={};state.errors={};state.validation_issues={};state.preview_stale=false;state.validation_project=nil;state.last_verified_project_match=nil;state.dry_run=nil;state.dry_run_stale=false;state.staged_changed_rows={};state.staged_change_details={};state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil;clear_preview_selection();state.preview_vscroll=0;state.preview_hscroll=0
    set_status("File selected. Run Validate Only. Only saved workbook changes will be read.","info")
  elseif not cancelled then
    set_status("Workbook Browse failed: "..tostring(dialog_error),"error")
    show_info("Workbook Browse Could Not Open",tostring(dialog_error),"error")
  end
end

function choose_recent_file(force)
  if #state.recent_files==0 then show_info("Recent Files","No recent spreadsheets are available.","info");return end
  if not force and not tempo_edits_empty(state.tempo_edits) then confirm_discard_staged_edits("Choosing a recent workbook","Choose and Discard Edits",function()choose_recent_file(true)end);return end
  local menu={};for _,p in ipairs(state.recent_files) do menu[#menu+1]=p:gsub("|","/") end
  gfx.x,gfx.y=120,100
  local choice=gfx.showmenu(table.concat(menu,"|"))
  if choice>0 then
    if not tempo_edits_empty(state.tempo_edits) then intentionally_discard_tempo_recovery() end
    if state.audition_active then restore_audition_state() end
    if stop_audio_preview then stop_audio_preview() end
    state.file_path=state.recent_files[choice];reaper.SetExtState(EXTSTATE_SECTION,"last_file",state.file_path,true)
    state.plan=nil;state.base_plan=nil;state.tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""};state.tempo_edit_history={};state.tempo_edit_log={};state.updated_workbook_copy="";state.preview_rows={};state.errors={};state.validation_issues={};state.preview_stale=false;state.validation_project=nil;state.last_verified_project_match=nil;state.dry_run=nil;state.dry_run_stale=false;state.staged_changed_rows={};state.staged_change_details={};state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil;clear_preview_selection();state.preview_vscroll=0;state.preview_hscroll=0
    set_status("Recent file selected. Run Validate Only.","info")
  end
end

function open_selected_workbook()
  if trim(state.file_path)=="" then
    set_status("Open Workbook unavailable: no workbook is selected.","warning")
    return
  end
  local ok,err=shell_open(state.file_path)
  if ok then set_status("Workbook opened.","success")
  else
    local detail="The selected workbook could not be opened.\n\n"..tostring(err)
    set_status("Could not open workbook: "..tostring(err),"error")
    show_info("Workbook Could Not Open",detail,"error")
  end
end

function validate_and_preview(force)
  if state.operation_busy then return end
  if not force and not tempo_edits_empty(state.tempo_edits) then confirm_discard_staged_edits("Reloading and validating the current workbook","Reload and Discard Edits",function()validate_and_preview(true)end);return end
  if force and not tempo_edits_empty(state.tempo_edits) then intentionally_discard_tempo_recovery() end
  if state.audition_active then restore_audition_state() end
  if stop_audio_preview then stop_audio_preview() end
  state.operation_busy=true;set_status("Reading, hashing, and validating spreadsheet...","info");gfx.update()
  local plan,errors=validate_file(state.file_path)
  if not plan then
    state.plan=nil;state.base_plan=nil;state.tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""};state.tempo_edit_history={};state.tempo_edit_log={};state.preview_rows={};state.errors=errors or {"Unknown validation error."};state.validation_issues=build_validation_issues(state.errors);state.preview_stale=false;state.validation_project=nil;state.last_verified_project_match=nil;state.dry_run=nil;state.dry_run_stale=false;state.project_changed=false;state.staged_changed_rows={};state.staged_change_details={};state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil;clear_preview_selection();state.preview_vscroll=0;state.preview_hscroll=0
    set_status(string.format("Validation failed with %d error%s.",#state.errors,#state.errors==1 and "" or "s"),"error")
    state.operation_busy=false
    show_validation_issues()
    return
  end
  local previous_plan=state.plan
  local project=get_active_project_info()
  local dry,dry_err=nil,nil
  if project then dry,dry_err=collect_project_snapshot(project.proj,plan) end
  plan.validated_timestamp=make_attempt_id().timestamp
  state.previous_plan=previous_plan
  state.validation_diff_lines=plan_diff_lines(previous_plan,plan)
  state.plan=plan;state.base_plan=plan;state.tempo_edits={rows={},end_bpm_set=false,end_bpm_text=""};state.tempo_edit_history={};state.tempo_edit_log={};state.updated_workbook_copy="";state.preview_rows=preview_rows(plan);state.errors={};state.validation_issues={};state.preview_vscroll=0;state.preview_hscroll=0;state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil;state.last_verified_project_match=nil;clear_preview_selection()
  refresh_staged_row_changes()
  state.validation_project=project;state.dry_run=dry;state.dry_run_stale=false;state.project_changed=false;state.preview_stale=false;state.validated_timestamp=plan.validated_timestamp;state.plan_was_undone=false
  if project and dry then state.audio_tempo_analysis=analyze_audio_tempo_handling(project.proj,plan,dry) end
  state.last_workbook_check=reaper.time_precise();state.last_project_check=reaper.time_precise()
  add_recent_file(state,state.file_path)
  set_status(string.format("Validation passed: COUNT IN measures 1-2 at %.2f BPM from row %d / %s; first part %s uses %.2f effective REAPER BPM; %d sections, %d blocks, %d expanded part occurrences, %d musical bars; song starts at measure 3; END at measure %d.%s",plan.count_in_bpm,plan.count_in_source_row or 0,plan.count_in_source_section or "",plan.first_part_canonical or "",plan.first_part_effective_bpm or plan.count_in_bpm,#plan.sections,plan.block_count or 0,#plan.flat_parts,plan.total_bars,plan.end_visible_measure,dry_err and (" Dry run unavailable: "..dry_err) or ""),"success")
  state.operation_busy=false
  maybe_offer_tempo_edit_recovery()
end

function refresh_dry_run()
  if not state.plan then return end
  local info=get_active_project_info()
  if not info or not state.validation_project or info.pointer~=state.validation_project.pointer then
    state.project_changed=true;state.dry_run_stale=true;state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil;return
  end
  local dry=collect_project_snapshot(info.proj,state.plan)
  if dry then
    state.dry_run=dry;state.dry_run_stale=false
    state.audio_tempo_analysis=analyze_audio_tempo_handling(info.proj,state.plan,dry)
    if state.audio_tempo_mode==AUDIO_MODE_CONFORM and not state.audio_tempo_analysis.conform_allowed then state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=analyze_audio_tempo_handling(info.proj,state.plan,dry) end
  end
end

function view_current_project_comparison()
  if state.operation_busy then return end
  if not state.plan then
    show_info("Build Preview","Validate the workbook before opening the read-only build preview.","warning")
    return
  end
  if state.preview_stale then
    show_info("Build Preview","The saved workbook changed after validation. Run Validate Only again before viewing the build preview.","warning")
    return
  end
  local info=get_active_project_info()
  if not info or not state.validation_project or info.pointer~=state.validation_project.pointer then
    state.project_changed=true
    show_info("Active Project Changed","The comparison can only be generated for the REAPER project that was active when this spreadsheet was validated.\n\nReturn to the intended project tab and validate again.","error")
    return
  end
  local snapshot,err=collect_project_snapshot(info.proj,state.plan)
  if not snapshot then
    set_status("Current project comparison failed: "..tostring(err),"error")
    show_info("Build Preview Failed","Could not generate the read-only build preview:\n\n"..tostring(err),"error")
    return
  end
  state.dry_run=snapshot;state.dry_run_stale=false
  state.comparison_lines=project_snapshot_lines(snapshot)
  state.comparison_vscroll=0;state.comparison_hscroll=0;state.comparison_focus=1;state.comparison_open=true
  set_status("Build Preview refreshed. No project changes were made.","success")
end

function mark_file_stale_if_changed()
  if not state.plan or state.preview_stale or state.file_path=="" then return end
  local fp=file_fingerprint(state.file_path)
  if fp and fp~=state.plan.fingerprint then
    state.preview_stale=true
    set_status("The saved spreadsheet changed after validation. Run Validate Only again.","error")
  end
end

function finalize_cancel_dialog(attempt,stage,message)
  cancel_attempt(state,attempt,stage,message)
  state.pending_build=nil;state.confirm_modal=nil;state.operation_busy=false;state.active_attempt=nil
end

local continue_build_after_duplicate,continue_build_after_media,continue_build_after_save,continue_build_after_prebuild,open_prebuild_save_prompt

continue_build_after_save=function(attempt,snapshot)
  attempt.snapshot=snapshot
  state.pending_build=attempt
  state.confirm_modal={attempt=attempt,started=reaper.time_precise(),delay=2.0}
end

continue_build_after_media=function(attempt,snapshot)
  local analysis=attempt.audio_analysis or analyze_audio_tempo_handling(attempt.project.proj,attempt.plan,snapshot)
  attempt.audio_analysis=analysis
  local non_audio_items=math.max(0,(snapshot.media_items or 0)-(analysis.audio_items or 0))
  if attempt.audio_mode==AUDIO_MODE_CONFORM and not analysis.conform_allowed then
    local reason="Conform Audio to New Tempo cannot run because the current project structure does not exactly match the validated workbook:\n\n"..table.concat(analysis.reasons,"\n").."\n\nChoose Preserve Audio Exactly, then start the build again. No project changes were made."
    cancel_attempt(state,attempt,"Audio structure eligibility",reason)
    state.pending_build=nil;state.operation_busy=false;state.active_attempt=nil
    state.audio_tempo_mode=AUDIO_MODE_PRESERVE
    show_info("Conform Audio Is Unavailable",reason,"error")
  elseif analysis.audio_items>0 or non_audio_items>0 then
    local heading=analysis.audio_items==0 and "Existing MIDI or Non-Audio Media" or (attempt.audio_mode==AUDIO_MODE_CONFORM and "Conform Existing Audio" or "Preserve Existing Audio Exactly")
    local action=analysis.audio_items==0 and "Continue to Build" or (attempt.audio_mode==AUDIO_MODE_CONFORM and "Conform and Build" or "Preserve and Build")
    local non_audio_note=non_audio_items>0 and string.format("\n\nThis project also contains %d MIDI or non-audio media item%s. The audio policy does not transform those items; they continue to follow their REAPER project, track, and item timebase settings.",non_audio_items,non_audio_items==1 and "" or "s") or ""
    show_confirm(
      heading,
      tostring(analysis.summary)..non_audio_note.."\n\nThe original source files will not be rewritten or deleted. The build, audio handling, verification, and any automatic rollback use one REAPER undo transaction.\n\nContinue?",
      action,"Cancel",
      function() continue_build_after_save(attempt,snapshot) end,
      function() finalize_cancel_dialog(attempt,"Audio handling confirmation","User cancelled after reviewing the selected audio handling mode. No project changes were made.") end,
      "warning"
    )
  else
    continue_build_after_save(attempt,snapshot)
  end
end

continue_build_after_duplicate=function(attempt,snapshot)
  local duplicate,previous=duplicate_plan_exists(attempt.folder,state.plan.plan_sha256)
  if duplicate then
    show_confirm(
      "Duplicate Plan Advisory",
      "The same normalized plan was previously logged as a successful build in this project.\n\nPrevious build ID:\n"..previous.id.."\n\nContinue anyway?",
      "Continue","Cancel",
      function() continue_build_after_media(attempt,snapshot) end,
      function() finalize_cancel_dialog(attempt,"Duplicate-plan advisory","User cancelled after being advised that the same normalized plan was previously built successfully.") end,
      "warning"
    )
  else
    continue_build_after_media(attempt,snapshot)
  end
end

continue_build_after_prebuild=function(expected_project)
  local project=get_active_project_info()
  if not project or project.pointer~=expected_project.pointer then
    state.operation_busy=false
    set_status("Build cancelled: the active REAPER project changed during the save step.","error")
    show_info("Active REAPER Project Changed","The active REAPER project changed before the build attempt began. No project changes were made by Bildibeat Click Track Mapper.\n\nReturn to the intended project tab and validate again.","error")
    return
  end
  if not state.validation_project or project.pointer~=state.validation_project.pointer then
    state.operation_busy=false;state.project_changed=true
    set_status("Build cancelled: the active REAPER project no longer matches validation.","error")
    show_info("Active REAPER Project Changed","The validated preview no longer belongs to the active REAPER project. No build was started.","error")
    return
  end
  state.validation_project.path=project.path;state.validation_project.folder=project.folder
  local snapshot,snap_err=collect_project_snapshot(project.proj,state.plan)
  if not snapshot then
    state.operation_busy=false;set_status(tostring(snap_err),"error")
    show_info("Automatic REAPER Project Check Failed",tostring(snap_err),"error")
    return
  end
  local preflight_ok,preflight_result=preflight_build_plan(state.plan,{count_in=snapshot.count_in,song=snapshot.start})
  if not preflight_ok then
    state.operation_busy=false;set_status("Build preflight failed before project modification.","error")
    show_info("Build Preflight Failed",tostring(preflight_result).."\n\nNo project changes were made.","error",nil,"Close")
    return
  end
  state.audio_tempo_analysis=analyze_audio_tempo_handling(project.proj,state.plan,snapshot)
  local attempt,attempt_err=start_attempt(project,state.plan,state.build_notes,tempo_edits_empty(state.tempo_edits) and "BUILD SONG STRUCTURE" or "APPLY AND VERIFY TEMPO EDITS",{prebuild_saved_copy=state.prebuild_saved_copy,prebuild_saved_path=state.prebuild_saved_path,prebuild_skipped=state.prebuild_skipped})
  if not attempt then
    state.operation_busy=false;set_status(attempt_err,"error");show_info("Build Attempt Could Not Start",attempt_err,"error");return
  end
  state.build_notes=""
  attempt.snapshot=snapshot;attempt.preflight_summary=preflight_result.summary;attempt.audio_mode=state.audio_tempo_mode;attempt.audio_analysis=state.audio_tempo_analysis
  attempt.prebuild_saved_copy=state.prebuild_saved_copy;attempt.prebuild_saved_path=state.prebuild_saved_path;attempt.prebuild_skipped=state.prebuild_skipped
  state.active_attempt=attempt
  state.current_attempt=attempt;state.build_status="IN PROGRESS";state.log_status="VERIFIED";state.current_log_path=attempt.inprogress_path
  set_status("Build attempt created: "..attempt.id,"info")

  local revalidated_source,errors=validate_file(state.plan.file_path)
  if not revalidated_source then
    local detail="Revalidation failed before project modification:\n"..table.concat(errors,"\n")
    fail_attempt(state,attempt,detail,"No project changes were made.")
    state.operation_busy=false;state.active_attempt=nil
    show_info("Build Revalidation Failed",detail,"error")
    return
  end
  if not state.base_plan or revalidated_source.fingerprint~=state.base_plan.fingerprint or revalidated_source.plan_sha256~=state.base_plan.plan_sha256 then
    cancel_attempt(state,attempt,"Workbook changed / revalidation required","The saved workbook changed after the displayed preview was validated. No project changes were made.")
    state.operation_busy=false;state.active_attempt=nil
    show_confirm(
      "Workbook Changed",
      "The spreadsheet has changed since it was validated.\n\nThis attempt was logged as CANCELLED. Revalidate the updated file now?",
      "Revalidate Now","Not Now",
      function() validate_and_preview() end,nil,"warning"
    )
    return
  end
  local revalidated,rebuild_errors=rebuild_plan_from_tempo_edits(revalidated_source,state.tempo_edits)
  if not revalidated or revalidated.plan_sha256~=state.plan.plan_sha256 then
    local detail="The staged tempo plan could not be reproduced from the current workbook snapshot.\n"..table.concat(rebuild_errors or {"The rebuilt plan hash did not match the displayed Preview."},"\n")
    cancel_attempt(state,attempt,"Staged tempo plan revalidation",detail.." No project changes were made.")
    state.operation_busy=false;state.active_attempt=nil
    show_info("Tempo Edit Revalidation Failed","[EDT-004] "..detail,"error")
    return
  end
  if reaper.GetSetProjectInfo(project.proj,"READONLY",0,false)~=0 then
    fail_attempt(state,attempt,"The project is read-only.","No project changes were made.")
    state.operation_busy=false;state.active_attempt=nil
    show_info("Build Failed","The REAPER project is read-only.\n\nNo project changes were made.","error")
    return
  end
  if reaper.GetPlayStateEx(project.proj)~=0 then
    fail_attempt(state,attempt,"Stop playback, pause, and recording before building.","No project changes were made.")
    state.operation_busy=false;state.active_attempt=nil
    show_info("Build Failed","Stop REAPER playback, pause, and recording before building.\n\nNo project changes were made.","error")
    return
  end
  continue_build_after_duplicate(attempt,snapshot)
end

open_prebuild_save_prompt=function(project)
  local suggested=prebuild_backup_path(project)
  state.prebuild_saved_copy=false;state.prebuild_saved_path="";state.prebuild_skipped=false
  open_app_modal({
    title="Save the REAPER Project Before Building",
    message="Saving the active REAPER project (.RPP) before building is strongly suggested. This refers only to the REAPER project—not the workbook, Bildibeat Click Track Mapper settings, or app state.\n\nSave REAPER Project As creates a separate pre-build backup and makes that copy active in REAPER. The filename is editable.\n\nCurrent REAPER project:\n"..tostring(project.path).."\n\nSuggested pre-build backup:\n"..suggested,
    kind="warning",
    buttons={
      {label="Save REAPER Project As...",value="save_as",primary=true,stay_open=true},
      {label="Continue Without Saving",value="continue"},
      {label="Cancel Build",value="cancel",cancel=true}
    },
    on_result=function(value)
      if value=="save_as" then
        local path,dialog_err=choose_save_path("Save REAPER Project Before Building","REAPER projects (*.RPP)|*.RPP|All files (*.*)|*.*",basename(suggested),project.folder)
        if not path then
          if dialog_err~="CANCELLED" and state.app_modal then state.app_modal.error="REAPER project Save As could not open: "..tostring(dialog_err)
          elseif state.app_modal then state.app_modal.error="Save As was canceled. Choose Save REAPER Project As, Continue Without Saving, or Cancel Build." end
          return
        end
        path=ensure_rpp_extension(path)
        local saved,result=save_reaper_project_as(project,path)
        if not saved then if state.app_modal then state.app_modal.error=tostring(result) end;set_status(tostring(result),"error");return end
        state.prebuild_saved_copy=true;state.prebuild_saved_path=result.path;state.prebuild_skipped=false
        state.app_modal=nil;quarantine_base_input(0.35)
        set_status("Pre-build REAPER project saved as: "..result.path,"success")
        continue_build_after_prebuild(result)
      elseif value=="continue" then
        state.prebuild_saved_copy=false;state.prebuild_saved_path="";state.prebuild_skipped=true
        set_status("Continuing without saving current REAPER project changes. A save choice will be offered after the build.","warning")
        continue_build_after_prebuild(project)
      else
        state.operation_busy=false;state.prebuild_saved_copy=false;state.prebuild_saved_path="";state.prebuild_skipped=false
        set_status("Build cancelled before project modification.","info")
      end
    end
  })
end

function begin_build_attempt()
  if not state.plan or state.operation_busy then return end
  local project=get_active_project_info()
  if not project_is_saved(project) then
    set_status("Build blocked: save the REAPER project as an .RPP file first so the required attempt log has a valid location.","error")
    show_info("Build Click Track Map Cannot Run","The active REAPER project must be saved at least once as an .RPP file before a build attempt can receive an ID and logfile. This does not refer to the workbook or Bildibeat Click Track Mapper settings.\n\nSave the active REAPER project, then try again.","error")
    return
  end
  if not state.validation_project or project.pointer~=state.validation_project.pointer then
    state.project_changed=true;set_status("Build blocked: the active project tab changed after validation.","error")
    show_info("Active Project Changed","The validated preview belongs to:\n"..tostring(state.validation_project and state.validation_project.path or "Unknown").."\n\nThe current project is:\n"..project.path.."\n\nValidate again in the intended project tab.","error")
    return
  end
  state.operation_busy=true
  local snapshot,snap_err=collect_project_snapshot(project.proj,state.plan)
  if not snapshot then
    state.operation_busy=false;set_status(snap_err,"error")
    show_info("Automatic REAPER Project Check Failed",tostring(snap_err),"error")
    return
  end
  local preflight_ok,preflight_result=preflight_build_plan(state.plan,{count_in=snapshot.count_in,song=snapshot.start})
  if not preflight_ok then
    state.operation_busy=false;set_status("Build preflight failed before project modification.","error")
    show_info("Build Preflight Failed",tostring(preflight_result).."\n\nNo project changes were made.","error",nil,"Close")
    return
  end
  open_prebuild_save_prompt(project)
end

function show_postbuild_save_prompt(attempt)
  local project=get_active_project_info()
  if not project or project.pointer~=attempt.project.pointer then
    show_info("Build Successful — Save the REAPER Project","The build and verification succeeded, but the active REAPER project tab changed before the save prompt opened.\n\nReturn to the project that received Build ID "..attempt.id.." and save that REAPER .RPP project from within REAPER. This message does not refer to the workbook or Bildibeat Click Track Mapper settings.","warning")
    return
  end
  local suggested=completed_build_path(project,attempt)
  local prebuild_note=attempt.prebuild_saved_copy and ("A pre-build REAPER project was saved at:\n"..tostring(attempt.prebuild_saved_path).."\n\nSaving the completed build as a separate copy is strongly suggested so it is unmistakable beside the pre-build backup.") or "You chose to continue without a new pre-build save. Save the completed REAPER project now so the verified map is written to disk."
  local buttons
  if attempt.prebuild_saved_copy then
    buttons={
      {label="Save Another Copy As...",value="save_as",primary=true,stay_open=true},
      {label="Save Completed REAPER Project",value="save_current",stay_open=true},
      {label="Close Without Saving",value="close",cancel=true}
    }
  else
    buttons={
      {label="Save Completed Project As...",value="save_as",primary=true,stay_open=true},
      {label="Close Without Saving",value="close",cancel=true}
    }
  end
  open_app_modal({
    title="Build Successful — Save the REAPER Project",
    message="The song structure was built and verified successfully in the active REAPER project. REAPER's native metronome is enabled so the generated clicks are audible.\n\nBuild ID:\n"..attempt.id.."\n\nLog status: "..state.log_status.."\n\nAudio handling:\n"..(attempt.audio_mode==AUDIO_MODE_CONFORM and "Conform Audio to New Tempo — Preserve Pitch" or "Preserve Audio Exactly").."\n"..tostring(attempt.audio_result_summary or (attempt.audio_analysis and attempt.audio_analysis.summary) or "").."\n\nBildibeat Click Track Mapper changed the REAPER project in memory. The completed map is not guaranteed to be saved on disk until you choose a save action. This refers to the REAPER .RPP project—not the workbook, Bildibeat Click Track Mapper settings, or app state.\n\n"..prebuild_note.."\n\nCurrent REAPER project:\n"..project.path.."\n\nSuggested completed-build copy:\n"..suggested.."\n\nThe suggested filename is editable.",
    kind="success",buttons=buttons,
    on_result=function(value)
      if value=="save_current" then
        local current=get_active_project_info()
        if not current or current.pointer~=attempt.project.pointer then if state.app_modal then state.app_modal.error="The active REAPER project changed. Return to the built project before saving." end;return end
        local saved,result=save_reaper_project_current(current)
        if not saved then if state.app_modal then state.app_modal.error=tostring(result) end;set_status(tostring(result),"error");return end
        set_status("Completed REAPER project saved: "..result.path,"success")
        show_info("Completed REAPER Project Saved","The verified click map is saved in the active REAPER project:\n\n"..result.path.."\n\nBuild ID:\n"..attempt.id.."\n\nThe workbook and Bildibeat Click Track Mapper settings were not changed by this save.","success")
      elseif value=="save_as" then
        local current=get_active_project_info()
        if not current or current.pointer~=attempt.project.pointer then if state.app_modal then state.app_modal.error="The active REAPER project changed. Return to the built project before saving." end;return end
        local path,dialog_err=choose_save_path("Save Completed REAPER Project","REAPER projects (*.RPP)|*.RPP|All files (*.*)|*.*",basename(suggested),current.folder)
        if not path then
          if dialog_err~="CANCELLED" and state.app_modal then state.app_modal.error="Completed-project Save As could not open: "..tostring(dialog_err)
          elseif state.app_modal then state.app_modal.error="Save As was canceled. Choose a save action or Close Without Saving." end
          return
        end
        path=ensure_rpp_extension(path)
        local saved,result=save_reaper_project_as(current,path)
        if not saved then if state.app_modal then state.app_modal.error=tostring(result) end;set_status(tostring(result),"error");return end
        set_status("Completed REAPER project saved as: "..result.path,"success")
        show_info("Completed REAPER Project Saved","The verified click map is saved in a separate REAPER project and that .RPP is now active:\n\n"..result.path.."\n\nBuild ID:\n"..attempt.id.."\n\nThe filename could be edited in Save As; the workbook and Bildibeat Click Track Mapper settings were not changed.","success")
      else
        set_status("Build verified, but the completed REAPER project was not saved by Bildibeat Click Track Mapper.","warning")
      end
    end
  })
end

function execute_pending_build()
  local attempt=state.pending_build;if not attempt then return end
  state.confirm_modal=nil;set_status("Building and verifying click track map...","info");gfx.update()
  local ok,result=perform_logged_build(attempt)
  local completed_attempt=nil
  if ok then
    local log_ok,log_result=finalize_attempt(attempt,"SUCCESS",{message="The click track map was built and post-build verification passed."},"SUCCESS")
    state.current_attempt=attempt;state.current_log_path=log_ok and log_result or nil;state.build_status="SUCCESS";state.log_status=log_ok and "VERIFIED" or ("VERIFICATION FAILED: "..tostring(log_result))
    state.last_successful_build={attempt=attempt,project_pointer=attempt.project.pointer,project_path=attempt.project.path,undo_label=result.undo_label,original_build_id=attempt.id,plan=attempt.plan,built_signature=result.built_signature,source_file=state.file_path,source_fingerprint=state.base_plan and state.base_plan.fingerprint or state.plan.fingerprint,tempo_edit_log={table.unpack(state.tempo_edit_log or {})},original_click_a=result.original_click_a,original_click_b=result.original_click_b,original_metronome_enabled=result.original_metronome_enabled,audio_mode=result.audio_mode,audio_summary=result.audio_summary,audio_before_signature=result.audio_before_signature,audio_after_signature=result.audio_after_signature,audio_before_snapshot=result.audio_before_snapshot};state.plan_was_undone=false
    set_status("Build completed and verified. Build ID: "..attempt.id,"success")
    completed_attempt=attempt
  else
    local rollback_verified=tostring(result):find("signatures were verified",1,true)~=nil
    fail_attempt(state,attempt,result,rollback_verified and "Build changes were automatically undone and the original marker/tempo and audio signatures were verified." or "Automatic rollback could not be verified; inspect the project before saving.")
    show_info("Build Failed",result,"error")
  end
  state.pending_build=nil;state.operation_busy=false;state.active_attempt=nil;refresh_dry_run();refresh_attempt_history(state)
  if completed_attempt then show_postbuild_save_prompt(completed_attempt) end
end

function undo_available()
  local b=state.last_successful_build;if not b then return false,"No successful build is available in this script run." end
  local info=get_active_project_info();if not info or info.pointer~=b.project_pointer then return false,"The active project is not the project that received the build." end
  local label=reaper.Undo_CanUndo2(info.proj)
  if label~=b.undo_label then return false,"Another REAPER action occurred after the build." end
  return true,"Available"
end

function undo_last_build()
  if state.operation_busy then return end
  local available,reason=undo_available()
  if not available then
    set_status("Undo Last Build unavailable: "..reason,"error")
    show_info("Undo Last Build Unavailable",reason.."\n\nNo project changes were made.","error")
    return
  end
  local b=state.last_successful_build
  local project=get_active_project_info()
  local snapshot=collect_project_snapshot(project.proj,b.plan)
  local attempt,err=start_attempt(project,b.plan,state.build_notes,"UNDO LAST BUILD")
  if not attempt then set_status(err,"error");show_info("Undo Attempt Could Not Start",err,"error");return end
  state.build_notes=""
  attempt.snapshot=snapshot
  state.operation_busy=true;state.active_attempt=attempt
  show_confirm(
    "Undo Last Build",
    "Undo the last successful Song Structure Builder action?\n\nOriginal build ID:\n"..b.original_build_id.."\n\nOnly the exact current REAPER undo action will be used.",
    "Undo Build","Cancel",
    function()
      local undone=reaper.Undo_DoUndo2(project.proj)
      if undone==0 then
        fail_attempt(state,attempt,"REAPER did not complete the requested undo.","No additional action was taken.")
        state.operation_busy=false;state.active_attempt=nil
        show_info("Undo Failed","REAPER did not complete the requested undo.\n\nNo additional action was taken.","error")
        return
      end
      local frequency_ok,frequency_err=true,nil
      if b.original_click_a and b.original_click_b then frequency_ok,frequency_err=set_click_frequencies(b.original_click_a,b.original_click_b,project.proj) end
      local metronome_ok,metronome_err=true,nil
      if b.original_metronome_enabled~=nil then metronome_ok,metronome_err=set_metronome_enabled(project.proj,b.original_metronome_enabled==1) end
      reaper.UpdateTimeline();reaper.UpdateArrange()
      local audio_undo_ok=not b.audio_before_signature or audio_state_signature(capture_audio_project_state(project.proj))==b.audio_before_signature
      if not frequency_ok or not metronome_ok or not audio_undo_ok then
        local restore_details={}
        if not frequency_ok then restore_details[#restore_details+1]="Original click frequencies: "..tostring(frequency_err) end
        if not metronome_ok then restore_details[#restore_details+1]="Original metronome state: "..tostring(metronome_err) end
        if not audio_undo_ok then restore_details[#restore_details+1]="Original audio-item state: the pre-build signature did not match after Undo." end
        local restore_text=table.concat(restore_details,"\n")
        fail_attempt(state,attempt,"REAPER undid the marker and tempo-map build, but one or more original metronome settings could not be restored:\n"..restore_text,"Inspect REAPER's Metronome and pre-roll settings before saving.")
        state.last_successful_build=nil;state.plan_was_undone=true;state.operation_busy=false;state.active_attempt=nil
        set_status("Build map undone, but metronome-setting restoration needs review.","error")
        refresh_dry_run();refresh_attempt_history(state)
        show_info("Undo Needs Review","REAPER performed the build Undo, but Bildibeat Click Track Mapper could not verify restoration of every original audio-item and metronome setting.\n\n"..restore_text.."\n\nInspect the project before saving.","error")
        return
      end
      local log_ok,log_result=finalize_attempt(attempt,"UNDO_SUCCESS",{original_build_id=b.original_build_id,message="The original successful build was undone through REAPER's undo system."},"UNDONE")
      state.current_attempt=attempt;state.current_log_path=log_ok and log_result or nil;state.build_status="UNDONE";state.original_build_id=b.original_build_id;state.log_status=log_ok and "VERIFIED" or ("VERIFICATION FAILED: "..tostring(log_result))
      state.last_successful_build=nil;state.plan_was_undone=true
      state.operation_busy=false;state.active_attempt=nil
      set_status("Last build was undone in REAPER. The displayed workbook/staged plan is still loaded but is not currently applied to the project. Original build ID: "..b.original_build_id,"warning")
      refresh_dry_run();refresh_attempt_history(state)
      show_info("Undo Complete","The last successful click-track-map build was undone in REAPER. The pre-build audio-item signature was restored and verified.\n\nThe displayed workbook/staged tempo plan remains loaded in Bildibeat Click Track Mapper, but it is no longer applied to the REAPER project. Audition and Save Updated Workbook Copy remain unavailable until this exact plan is built and verified again.\n\nOriginal build ID:\n"..b.original_build_id.."\n\nLog status: "..state.log_status,"success")
    end,
    function()
      cancel_attempt(state,attempt,"Undo confirmation","User cancelled the Undo Last Build confirmation. No project changes were made.")
      state.operation_busy=false;state.active_attempt=nil
    end,
    "warning"
  )
end

function history_date_key(timestamp)
  local m,d,y=tostring(timestamp or ""):match("(%d%d?)/(%d%d?)/(%d%d%d%d)")
  if not y then return "" end
  return string.format("%04d-%02d-%02d",tonumber(y),tonumber(m),tonumber(d))
end

function history_display_date(iso)
  local y,m,d=tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  return y and string.format("%s-%s-%s",m,d,y) or ""
end

function parse_history_display_date(value)
  value=trim(value);if value=="" then return "" end
  local m,d,y=value:match("^(%d%d)%-(%d%d)%-(%d%d%d%d)$")
  m,d,y=tonumber(m),tonumber(d),tonumber(y)
  if not y or m<1 or m>12 or d<1 or d>31 then return nil,"Use MM-DD-YYYY, such as 07-16-2026." end
  local stamp=os.time({year=y,month=m,day=d,hour=12})
  local checked=stamp and os.date("*t",stamp) or nil
  if not checked or checked.year~=y or checked.month~=m or checked.day~=d then return nil,"Enter a real calendar date in MM-DD-YYYY format." end
  return string.format("%04d-%02d-%02d",y,m,d)
end

function validate_history_filter_fields(fields)
  local df,from_error=parse_history_display_date(fields[2] and fields[2].value or "");if df==nil then return false,"Date From: "..from_error end
  local dt,to_error=parse_history_display_date(fields[3] and fields[3].value or "");if dt==nil then return false,"Date To: "..to_error end
  if df~="" and dt~="" and df>dt then return false,"Date From cannot be later than Date To." end
  return true,nil,df,dt
end

function history_entry_matches(e)
  if state.history_filter~="ALL" and e.status~=state.history_filter then return false end
  if state.history_song~="ALL" and workbook_identity(e.spreadsheet)~=state.history_song then return false end
  local notes=upper(e.notes or "");local id=upper(e.id or "");local key=history_date_key(e.timestamp)
  if trim(state.history_notes_search)~="" and not notes:find(upper(trim(state.history_notes_search)),1,true) then return false end
  if trim(state.history_id_search)~="" and not id:find(upper(trim(state.history_id_search)),1,true) then return false end
  if trim(state.history_date_from)~="" and key<trim(state.history_date_from) then return false end
  if trim(state.history_date_to)~="" and key>trim(state.history_date_to) then return false end
  return true
end

function filtered_history()
  local out={}
  for i=1,#state.history do local e=state.history[i];if history_entry_matches(e) then out[#out+1]=e end end
  return out
end

function selected_history_entry()
  if not state.history_selected then return nil end
  return filtered_history()[state.history_selected]
end

function choose_history_song()
  local unique={};local paths={}
  for _,e in ipairs(state.history) do
    local id=workbook_identity(e.spreadsheet)
    if id~="" and not unique[id] then unique[id]=true;paths[#paths+1]=e.spreadsheet end
  end
  table.sort(paths,function(a,b)return upper(a)<upper(b) end)
  local menu={"All Songs"}
  for _,p in ipairs(paths) do local n,f=workbook_display(p);menu[#menu+1]=n.." — "..f:gsub("|","/") end
  gfx.x,gfx.y=math.floor(gfx.mouse_x),math.floor(gfx.mouse_y)
  local c=gfx.showmenu(table.concat(menu,"|"))
  if c==1 then state.history_song="ALL" elseif c>1 then state.history_song=workbook_identity(paths[c-1]) end
  state.history_selected=nil;state.history_scroll=math.huge
end

function open_history_search()
  open_app_modal({
    title="History Filters",
    message="Build Notes matching is case-insensitive and partial. Dates use MM-DD-YYYY, are inclusive, and can be typed or selected from the calendar.",
    kind="input",
    fields={
      {label="Build Notes contains",value=state.history_notes_search or "",help="Filter History by a case-insensitive partial match anywhere in Build Notes; results update after Apply."},
      {label="Date From (MM-DD-YYYY)",value=history_display_date(state.history_date_from),date_picker=true,date_role="from",help="Inclusive earliest local History date. Type MM-DD-YYYY or open Calendar."},
      {label="Date To (MM-DD-YYYY)",value=history_display_date(state.history_date_to),date_picker=true,date_role="to",help="Inclusive latest local History date. Type MM-DD-YYYY or open Calendar."},
      {label="Build ID contains",value=state.history_id_search or "",help="Filter History by a case-insensitive partial Build ID match; results update after Apply."}
    },
    fields_validator=validate_history_filter_fields,
    on_change=function(fields,index)
      if index==1 then state.history_notes_search=fields[1].value or "";state.history_selected=nil;state.history_scroll=math.huge end
      local ok,err=validate_history_filter_fields(fields);if state.app_modal then state.app_modal.error=ok and "" or err end
    end,
    buttons={{label="Apply",value="apply",primary=true},{label="Reset Filters",value="reset"},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value,_,fields)
      if value=="apply" then
        local _,_,df,dt=validate_history_filter_fields(fields)
        state.history_notes_search=fields[1].value or ""
        state.history_date_from=df or ""
        state.history_date_to=dt or ""
        state.history_id_search=fields[4].value or ""
        state.history_selected=nil;state.history_scroll=math.huge
      elseif value=="reset" then
        clear_all_history_filters()
      end
    end
  })
end

function clear_all_history_filters()
  state.history_song="ALL";state.history_filter="ALL";state.history_notes_search="";state.history_id_search="";state.history_date_from="";state.history_date_to="";state.history_selected=nil;state.history_scroll=math.huge
end

function set_build_notes()
  show_input(
    "Build Notes",
    "Enter an optional note for the next build or undo attempt. The note is captured when the attempt ID is created, then cleared automatically.",
    "Optional note for the next attempt:",state.build_notes or "",nil,
    function(value)
      state.build_notes=value
      set_status(value~="" and "Build note saved for the next attempt." or "Build note cleared.","info")
    end
  )
end

function refresh_audio_tempo_analysis()
  local project=get_active_project_info()
  if not project or not state.plan or not state.validation_project or project.pointer~=state.validation_project.pointer then state.audio_tempo_analysis=nil;return nil end
  local snapshot=collect_project_snapshot(project.proj,state.plan)
  if not snapshot then state.audio_tempo_analysis=nil;return nil end
  state.audio_tempo_analysis=analyze_audio_tempo_handling(project.proj,state.plan,snapshot)
  return state.audio_tempo_analysis
end

function choose_audio_tempo_mode()
  if not state.plan then return end
  local analysis=refresh_audio_tempo_analysis()
  local conform_note=analysis and analysis.conform_allowed and "Available: project markers, counts, meters, Block/Repeat expansion, and Ramp boundaries match the validated workbook." or ("Unavailable: "..(analysis and table.concat(analysis.reasons,"; ") or "the current project could not be analyzed"))
  open_app_modal({
    title="Audio Handling for the Next Build",
    message="Preserve Audio Exactly keeps every detected audio item at the same absolute time, length, rate, pitch, timebase, fade, and stretch-marker state.\n\nConform Audio to New Tempo — Preserve Pitch keeps eligible audio on the same musical counts while REAPER rate-stretches it to the new tempo without changing pitch. It is allowed only when the current project structure exactly matches the workbook; items crossing COUNT IN or END, locked items, and mixed audio/MIDI items block it.\n\n"..conform_note.."\n\n"..tostring(analysis and analysis.summary or "No current audio summary is available."),
    kind=analysis and analysis.conform_allowed and "info" or "warning",
    buttons={
      {label="Preserve Audio Exactly",value=AUDIO_MODE_PRESERVE,primary=state.audio_tempo_mode==AUDIO_MODE_PRESERVE},
      {label="Conform + Preserve Pitch",value=AUDIO_MODE_CONFORM,primary=state.audio_tempo_mode==AUDIO_MODE_CONFORM,disabled=not (analysis and analysis.conform_allowed),disabled_reason=conform_note},
      {label="Cancel",value="CANCEL",cancel=true}
    },
    on_result=function(value)
      if value==AUDIO_MODE_PRESERVE or value==AUDIO_MODE_CONFORM then
        state.audio_tempo_mode=value
        refresh_audio_tempo_analysis()
        set_status(value==AUDIO_MODE_CONFORM and "Audio mode: Conform Audio to New Tempo — Preserve Pitch." or "Audio mode: Preserve Audio Exactly.","success")
      end
    end
  })
end

function export_preview_with_format(format)
  if not state.plan then return end
  format=trim(format):lower()
  local default=basename(state.plan.file_path):gsub("%.[^%.]+$","").."_validated_preview."..format
  local path,err=choose_save_path("Export Validated Preview",format=="txt" and "Text files (*.txt)|*.txt|All files (*.*)|*.*" or "CSV files (*.csv)|*.csv|All files (*.*)|*.*",default,dirname(state.plan.file_path))
  if not path then if err~="CANCELLED" then show_info("Export Preview Failed",err,"error") end;return end
  local lines={}
  if format=="csv" then
    local headers={"Row","Section","Original Part","Normalized Part","Bars","Meter","Underlying BPM","Effective BPM","Ramp","Start","Next","Plain-English Readout"};for i,v in ipairs(headers) do headers[i]=csv_escape(v) end;lines[#lines+1]=table.concat(headers,",")
    local count_preview=state.preview_rows[1]
    local count_row={"AUTO",COUNT_IN.name,"AUTO COUNT-IN",COUNT_IN.name,COUNT_IN.bars,string.format("%d/%d",COUNT_IN.numerator,COUNT_IN.denominator),format_effective_bpm(state.plan.count_in_bpm),format_effective_bpm(state.plan.count_in_bpm),"No",COUNT_IN.visible_measure,START_VISIBLE_MEASURE,count_preview and count_preview.plain_english or ""};for j,v in ipairs(count_row) do count_row[j]=csv_escape(v) end;lines[#lines+1]=table.concat(count_row,",")
    local flat_index=0
    for _,section in ipairs(state.plan.sections) do for i,part in ipairs(section.parts) do
      flat_index=flat_index+1;local preview=state.preview_rows[flat_index+1]
      local row={section.row,i==1 and section.name or "",part.source,part.canonical,part.repeats,string.format("%d/%d",part.numerator,part.denominator),format_effective_bpm(part.underlying_bpm),format_effective_bpm(part.effective_bpm),part.ramp and ("Final "..part.ramp_bars..(part.ramp_bars == 1 and " bar to " or " bars to ")..format_effective_bpm(part.ramp_target_bpm)) or "No",part.start_visible_measure,part.next_visible_measure,preview and preview.plain_english or ""}
      for j,v in ipairs(row) do row[j]=csv_escape(v) end;lines[#lines+1]=table.concat(row,",")
    end end
    local end_preview=state.preview_rows[#state.preview_rows];local end_row={state.plan.end_row,"END","END","END",0,"1/4",state.plan.end_bpm_entered and format_bpm(state.plan.end_bpm_entered) or "blank",format_effective_bpm(state.plan.end_effective_bpm),"N/A",state.plan.end_visible_measure,state.plan.end_visible_measure,end_preview and end_preview.plain_english or ""};for j,v in ipairs(end_row) do end_row[j]=csv_escape(v) end;lines[#lines+1]=table.concat(end_row,",")
  else
    lines[#lines+1]=SCRIPT_NAME.." Validated Preview";lines[#lines+1]="Source: "..state.plan.file_path;lines[#lines+1]="Plan SHA-256: "..state.plan.plan_sha256;lines[#lines+1]=""
    lines[#lines+1]=table.concat({"Row","Section","Part","Bars","Meter","Base BPM","REAPER BPM","Ramp","Start","Next","Plain-English Readout"},"\t")
    for _,r in ipairs(state.preview_rows) do lines[#lines+1]=table.concat({r.row,r.section,r.part,r.bars,r.meter,r.base_bpm,r.reaper_bpm,r.ramp,r.start,r.next,r.plain_english or ""},"\t") end
  end
  local written,write_err=write_file(path,table.concat(lines,"\r\n").."\r\n")
  if written then set_status("Preview exported: "..path,"success") else show_info("Export Preview Failed","Could not export preview: "..tostring(write_err),"error") end
end

function export_preview()
  if state.operation_busy or state.app_modal or state.confirm_modal or state.comparison_open then return end
  if not state.plan then return end
  open_app_modal({
    title="Export Preview",message="Choose the export format for the validated preview.",kind="input",
    buttons={{label="Text (.txt)",value="txt",primary=true},{label="CSV (.csv)",value="csv"},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value) if value=="txt" or value=="csv" then export_preview_with_format(value) end end
  })
end

function clean_workbook_title(path)
  local title=basename(path or ""):gsub("%.[^%.]+$",""):gsub("_"," "):gsub("%s+"," ")
  title=trim(title);return title~="" and title or "Song Structure"
end

function title_case_first(value)
  value=tostring(value or "");return value=="" and value or value:sub(1,1):upper()..value:sub(2)
end

function simplified_part_line(part,show_measures,show_bpm)
  local line=tostring(part.numerator)
  if part.repeats and part.repeats>1 then line=line.." x"..part.repeats end
  line=line.." — "..click_type_name(part)
  if show_bpm then line=line.." — "..format_bpm(part.underlying_bpm).." BPM" end
  if show_measures then
    local first=part.start_visible_measure or 0
    local last=(part.next_visible_measure or first+1)-1
    line=(first==last and ("Measure "..first) or ("Measures "..first.."-"..last))..": "..line
  end
  return line
end

function simplified_section_lines(section,show_measures,show_bpm)
  local lines,blocks_by_item,ordinary_by_item={}, {}, {}
  local max_item=0
  for _,block in ipairs(section.blocks or {}) do blocks_by_item[block.item_index]=block;max_item=math.max(max_item,block.item_index or 0) end
  for _,part in ipairs(section.parts or {}) do
    max_item=math.max(max_item,part.item_index or 0)
    if not part.block_index and not ordinary_by_item[part.item_index] then ordinary_by_item[part.item_index]=part end
  end
  for item_index=1,max_item do
    local block=blocks_by_item[item_index]
    if block then
      local group={}
      for template_index,template in ipairs(block.templates or {}) do
        local display_part=template
        for _,expanded in ipairs(section.parts or {}) do
          if expanded.block_index==block.block_index and expanded.block_repeat_index==1 and expanded.block_part_index==template_index then display_part=expanded break end
        end
        group[#group+1]=simplified_part_line(display_part,show_measures,show_bpm)
      end
      if #group>0 then
        group[1]="("..group[1]
        group[#group]=group[#group]..")"
        if (block.repeat_count or 1)>1 then group[#group]=group[#group].."\nx"..block.repeat_count end
        lines[#lines+1]=table.concat(group,"\n")
      end
    elseif ordinary_by_item[item_index] then lines[#lines+1]=simplified_part_line(ordinary_by_item[item_index],show_measures,show_bpm) end
  end
  return lines
end

function readout_section_title(section,index,generic_names)
  return generic_names and ("PART "..tostring(index)) or tostring(section.name or ("PART "..tostring(index)))
end

function duration_summary_lines(plan,generic_names)
  local lines={"DURATION CALCULATOR","COUNT-IN: "..format_duration(plan.count_in_duration or 0)}
  for index,section in ipairs(plan.sections or {}) do lines[#lines+1]=readout_section_title(section,index,generic_names)..": "..format_duration(section.duration_seconds or 0) end
  lines[#lines+1]="Musical Content: "..format_duration(plan.total_duration or 0)
  lines[#lines+1]="Total with Count-In: "..format_duration(plan.total_duration_with_count_in or 0)
  return lines
end

function song_structure_sections(plan,show_measures,simplified,show_bpm,generic_names)
  local sections={};if not plan then return sections end
  local count_line
  if simplified then
    count_line=tostring(COUNT_IN.numerator).." x"..COUNT_IN.bars.." — Quarter Note"
    if show_bpm then count_line=count_line.." — "..format_bpm(plan.count_in_bpm).." BPM" end
  else
    local count_pieces={bar_count_phrase(COUNT_IN.bars),string.format("%d/%d",COUNT_IN.numerator,COUNT_IN.denominator)}
    if show_bpm then count_pieces[#count_pieces+1]=format_bpm(plan.count_in_bpm).." BPM" end
    count_pieces[#count_pieces+1]="Quarter Note click"
    count_line=table.concat(count_pieces," | ")
  end
  if show_measures then count_line="Measures 1-2: "..count_line end
  sections[#sections+1]={title="COUNT-IN",lines={count_line}}
  local flat_index=0
  for section_index,section in ipairs(plan.sections or {}) do
    local lines=simplified and simplified_section_lines(section,show_measures,show_bpm) or {}
    if not simplified then
      for _,part in ipairs(section.parts or {}) do
        flat_index=flat_index+1;local next_part=plan.flat_parts and plan.flat_parts[flat_index+1] or nil
        local pieces={bar_count_phrase(part.repeats),string.format("%d/%d",part.numerator,part.denominator)}
        if show_bpm then pieces[#pieces+1]=format_bpm(part.underlying_bpm).." BPM" end
        local rhythm=click_type_name(part);pieces[#pieces+1]=rhythm.." click"
        if part.ramp then
          local destination=next_part and next_part.underlying_bpm or plan.end_effective_bpm
          local destination_rhythm=next_part and click_type_name(next_part) or nil
          if show_bpm then
            pieces[#pieces+1]="Ramp -> "..format_bpm(destination).." BPM"..(destination_rhythm and (" with "..destination_rhythm.." click") or "")
          else
            pieces[#pieces+1]="Ramp -> "..(destination_rhythm and (destination_rhythm.." click") or "END")
          end
        end
        if part.no_accent then pieces[#pieces+1]="No accent (all A clicks)" end
        local line=table.concat(pieces," | ")
        if show_measures then
          local first=tonumber(part.start_visible_measure) or 0;local last=(tonumber(part.next_visible_measure) or first+1)-1
          line=(first==last and ("Measure "..first) or ("Measures "..first.."-"..last))..": "..line
        end
        lines[#lines+1]=line
      end
    end
    sections[#sections+1]={title=readout_section_title(section,section_index,generic_names),lines=lines}
  end
  sections[#sections+1]={title="END",lines={show_measures and ("The song ends at measure "..tostring(plan.end_visible_measure)..".") or "End of song."}}
  return sections
end

function song_structure_text(plan,show_measures,simplified,show_bpm,generic_names)
  if not plan then return "No validated song structure is available." end
  local lines={clean_workbook_title(plan.file_path),simplified and "SIMPLIFIED READOUT" or "SONG STRUCTURE READOUT","Generated: "..os.date("%m-%d-%Y %I:%M %p"),""}
  for _,section in ipairs(song_structure_sections(plan,show_measures,simplified,show_bpm,generic_names)) do
    lines[#lines+1]=section.title
    for _,line in ipairs(section.lines) do lines[#lines+1]=line end
    lines[#lines+1]=""
  end
  for _,line in ipairs(duration_summary_lines(plan,generic_names)) do lines[#lines+1]=line end
  return table.concat(lines,"\n")
end

function html_escape(value)
  return tostring(value or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
end

function song_structure_print_html(plan,show_measures,simplified,show_bpm,generic_names)
  local title=clean_workbook_title(plan.file_path);local body={};local mode_title=simplified and "SIMPLIFIED READOUT" or "SONG STRUCTURE READOUT"
  for _,section in ipairs(song_structure_sections(plan,show_measures,simplified,show_bpm,generic_names)) do
    body[#body+1]="<section><h2>"..html_escape(section.title).."</h2>"
    for _,line in ipairs(section.lines) do body[#body+1]="<div class=\"entry\">"..html_escape(line).."</div>" end
    body[#body+1]="</section>"
  end
  body[#body+1]="<section><h2>DURATION CALCULATOR</h2>"
  for index,line in ipairs(duration_summary_lines(plan,generic_names)) do if index>1 then body[#body+1]="<div class=\"entry\">"..html_escape(line).."</div>" end end
  body[#body+1]="</section>"
  local page_rule="@page{size:auto;margin:0.65in 0.65in 0.75in}"
  return "<!doctype html><html><head><meta charset=\"utf-8\"><title>"..html_escape(title).." - "..html_escape(mode_title).."</title><style>"..page_rule.."body{font-family:Arial,sans-serif;color:#111;font-size:12pt;line-height:1.42}h1{font-size:22pt;margin:0}header{margin-bottom:24px;border-bottom:2px solid #222;padding-bottom:12px}.subtitle{font-weight:bold;letter-spacing:.08em;margin-top:4px}.generated{font-size:9pt;color:#555;margin-top:4px}section{break-inside:avoid-page;margin:0 0 20px}h2{font-size:15pt;margin:0 0 7px;border-bottom:1px solid #bbb;padding-bottom:3px}.entry{margin:4px 0}</style></head><body><header><h1>"..html_escape(title).."</h1><div class=\"subtitle\">"..html_escape(mode_title).."</div><div class=\"generated\">Generated "..html_escape(os.date("%m-%d-%Y %I:%M %p")).."</div></header>"..table.concat(body).."<script>window.addEventListener('load',function(){setTimeout(function(){window.print()},300)})</script></body></html>"
end

function export_song_structure_readout()
  if not state.plan then return end
  local default=sanitize_filename(clean_workbook_title(state.plan.file_path)).."_Song_Structure_Readout.txt"
  local path,err=choose_save_path("Export Song Structure Readout","Text files (*.txt)|*.txt|All files (*.*)|*.*",default,dirname(state.plan.file_path))
  if not path then if err~="CANCELLED" then show_info("Readout Export Failed",tostring(err),"error") end;return end
  if not path:lower():match("%.txt$") then path=path..".txt" end
  local ok,write_err=write_file(path,song_structure_text(state.plan,state.song_readout_show_measures,state.song_readout_simplified,state.song_readout_show_bpm,state.song_readout_generic_names).."\r\n")
  set_status(ok and ("Song Structure Readout exported: "..path) or ("Export failed: "..tostring(write_err)),ok and "success" or "error")
end

function print_song_structure_readout()
  if not state.plan then return end
  local html=song_structure_print_html(state.plan,state.song_readout_show_measures,state.song_readout_simplified,state.song_readout_show_bpm,state.song_readout_generic_names)
  local path=make_temp_path("_Song_Structure_Readout.html");local ok,err=write_file(path,html)
  if not ok then show_info("Print Readout Failed",tostring(err),"error");return end
  local opened,open_err=shell_open(path);set_status(opened and "Print-ready Song Structure Readout opened. Use the browser print dialog." or ("Could not open print view: "..tostring(open_err)),opened and "success" or "error")
end

function refresh_song_structure_modal()
  local modal=state.app_modal;if not modal or modal.context~="song_readout" then return end
  modal.message=song_structure_text(state.plan,state.song_readout_show_measures,state.song_readout_simplified,state.song_readout_show_bpm,state.song_readout_generic_names);modal.scroll=0
  modal.buttons[1].label="Simplified Readout: "..(state.song_readout_simplified and "On" or "Off")
  modal.buttons[2].label="Measure Numbers: "..(state.song_readout_show_measures and "On" or "Off")
  modal.buttons[3].label="Show BPM: "..(state.song_readout_show_bpm and "On" or "Off")
  modal.buttons[4].label="Generic Part Names: "..(state.song_readout_generic_names and "On" or "Off")
end

function open_song_structure_readout()
  if not state.plan then return end
  open_app_modal({
    title="User-Friendly Song Structure",message=song_structure_text(state.plan,state.song_readout_show_measures,state.song_readout_simplified,state.song_readout_show_bpm,state.song_readout_generic_names),kind="info",plain_text=true,body_font_size=14,
    buttons={
      {label="Simplified Readout: "..(state.song_readout_simplified and "On" or "Off"),value="simplified",stay_open=true},
      {label="Measure Numbers: "..(state.song_readout_show_measures and "On" or "Off"),value="measures",stay_open=true},
      {label="Show BPM: "..(state.song_readout_show_bpm and "On" or "Off"),value="bpm",stay_open=true},
      {label="Generic Part Names: "..(state.song_readout_generic_names and "On" or "Off"),value="generic",stay_open=true},
      {label="Export...",value="export",stay_open=true},
      {label="Print...",value="print",stay_open=true},
      {label="Close",value="close",cancel=true}
    },
    on_result=function(value)
      if value=="simplified" then state.song_readout_simplified=not state.song_readout_simplified;refresh_song_structure_modal()
      elseif value=="measures" then state.song_readout_show_measures=not state.song_readout_show_measures;refresh_song_structure_modal()
      elseif value=="bpm" then state.song_readout_show_bpm=not state.song_readout_show_bpm;refresh_song_structure_modal()
      elseif value=="generic" then state.song_readout_generic_names=not state.song_readout_generic_names;refresh_song_structure_modal()
      elseif value=="export" then export_song_structure_readout()
      elseif value=="print" then print_song_structure_readout() end
    end
  })
  state.app_modal.context="song_readout"
end

function copy_selected_preview_row()
  local r=state.selected_preview_row and state.preview_rows[state.selected_preview_row] or nil
  if not r then return end
  local ok,err=copy_to_clipboard(preview_row_full_readout(r))
  set_status(ok and "Selected Preview-row readout copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
end

function audition_build_matches()
  local project=get_active_project_info()
  if not project then return false,"Open the intended REAPER project before auditioning." end
  if state.preview_stale then return false,"Revalidate the workbook before auditioning." end
  local project_signature=transaction_project_signature(project.proj)
  local build=state.last_successful_build
  if build and build.built_signature
      and state.plan and build.plan and build.plan.plan_sha256==state.plan.plan_sha256
      and project.pointer==build.project_pointer
      and project_signature==build.built_signature then
    return true,project
  end
  local matched=state.last_verified_project_match
  if matched
      and state.plan and matched.plan_sha256==state.plan.plan_sha256
      and project.pointer==matched.project_pointer
      and project_signature==matched.project_signature then
    return true,project
  end
  if state.project_changed then return false,"Revalidate the workbook, then use Validate Against Open Project before auditioning." end
  return false,"Build and verify the current structure, or confirm it with Validate Against Open Project."
end

function selected_preview_range()
  local first=state.preview_selection_start or state.selected_preview_row
  local last=state.preview_selection_end or state.selected_preview_row
  if not first or not last then return nil,nil end
  if first>last then first,last=last,first end
  return first,last
end

function audition_time_range(proj)
  local first,last=selected_preview_range()
  if not first then return nil,nil,"Select one or more Preview rows first." end
  local first_row,last_row
  for index=first,last do
    local row=state.preview_rows[index]
    if row and row.source~="END" and row.internal_measure_index then first_row=first_row or row;last_row=row end
  end
  if not first_row or not last_row then return nil,nil,"END cannot be auditioned. Select a count-in or musical part row." end
  local bars=tonumber(last_row.bars) or 0
  if bars<1 then return nil,nil,"The selected range has no playable bars." end
  local start_time=select(1,reaper.TimeMap_GetMeasureInfo(proj,first_row.internal_measure_index))
  local end_time=select(1,reaper.TimeMap_GetMeasureInfo(proj,last_row.internal_measure_index+bars))
  return start_time,end_time
end

function audition_endpoint_times(start_time,boundary_time)
  local duration=math.max(0,(tonumber(boundary_time) or 0)-(tonumber(start_time) or 0))
  if duration<=EPS_TIME then return start_time end
  local transport_guard=math.min(AUDITION_TRANSPORT_END_GUARD,duration*0.01)
  return boundary_time-transport_guard
end

function audition_stop_at_loop_end_state()
  local section=reaper.SectionFromUniqueID(0)
  local name=section and reaper.kbd_getTextFromCmd(ACTION_STOP_PLAYBACK_AT_LOOP_END,section) or ""
  if trim(name)=="" then return nil,"REAPER's stop-playback-at-end-of-loop transport action is unavailable." end
  local current=reaper.GetToggleCommandStateEx(0,ACTION_STOP_PLAYBACK_AT_LOOP_END)
  if current~=0 and current~=1 then return nil,"REAPER did not report a valid stop-at-loop-end setting." end
  return current
end

function set_audition_stop_at_loop_end(proj,enabled)
  local wanted=enabled and 1 or 0
  local current,err=audition_stop_at_loop_end_state();if current==nil then return false,err end
  if current~=wanted then reaper.Main_OnCommandEx(ACTION_STOP_PLAYBACK_AT_LOOP_END,0,proj) end
  local verified,verify_err=audition_stop_at_loop_end_state()
  if verified~=wanted then return false,verify_err or "REAPER did not apply the stop-at-loop-end transport setting." end
  return true
end

function restore_audition_state(cursor_target)
  local restore=state.audition_restore
  if not restore then state.audition_active=false return end
  local proj=restore.proj
  reaper.OnStopButtonEx(proj)
  reaper.GetSet_LoopTimeRange2(proj,true,false,restore.time_start,restore.time_end,false)
  reaper.GetSet_LoopTimeRange2(proj,true,true,restore.loop_start,restore.loop_end,false)
  reaper.GetSetRepeatEx(proj,restore.repeat_state)
  if restore.stop_at_loop_end_state~=nil then set_audition_stop_at_loop_end(proj,restore.stop_at_loop_end_state==1) end
  reaper.CSurf_OnPlayRateChange(restore.playrate)
  if restore.preserve_pitch~=nil then set_project_int_config(proj,"audioprshift",restore.preserve_pitch) end
  reaper.SetEditCurPos2(proj,cursor_target or restore.cursor,true,false)
  state.audition_active=false;state.audition_restore=nil
  reaper.UpdateArrange()
end

function stop_audition()
  if state.audition_active and state.audition_restore then restore_audition_state(state.audition_restore.selection_start)
  else
    local ok,project=audition_build_matches()
    if ok then
      local start_time=audition_time_range(project.proj)
      reaper.OnStopButtonEx(project.proj)
      if start_time then reaper.SetEditCurPos2(project.proj,start_time,true,false) end
    end
  end
  set_status("Audition stopped. The cursor returned to the first selected part.","info")
end

function play_audition()
  local eligible,project_or_reason=audition_build_matches()
  if not eligible then show_info("Audition Unavailable",project_or_reason,"warning");return end
  local proj=project_or_reason.proj
  local start_time,end_time,range_err=audition_time_range(proj)
  if not start_time then show_info("Audition Unavailable",range_err,"warning");return end
  if state.audition_active then restore_audition_state(start_time) end
  local metronome_ready,metronome_err=set_metronome_enabled(proj,true)
  if not metronome_ready then
    show_info("Audition Unavailable","REAPER's metronome could not be enabled, so the selected click cannot be heard.\n\n"..tostring(metronome_err),"warning")
    return
  end
  local transport_end=audition_endpoint_times(start_time,end_time)
  local original_stop_state,stop_state_err=audition_stop_at_loop_end_state()
  if original_stop_state==nil then show_info("Audition Unavailable",stop_state_err,"warning");return end
  local stop_state_ready,stop_ready_err=set_audition_stop_at_loop_end(proj,true)
  if not stop_state_ready then
    set_audition_stop_at_loop_end(proj,original_stop_state==1)
    show_info("Audition Unavailable","REAPER could not enable exact stopping at the selected range boundary.\n\n"..tostring(stop_ready_err),"warning")
    return
  end
  local time_start,time_end=reaper.GetSet_LoopTimeRange2(proj,false,false,0,0,false)
  local loop_start,loop_end=reaper.GetSet_LoopTimeRange2(proj,false,true,0,0,false)
  local preserve_pitch=get_project_int_config(proj,"audioprshift")
  state.audition_restore={
    proj=proj,time_start=time_start,time_end=time_end,loop_start=loop_start,loop_end=loop_end,
    repeat_state=reaper.GetSetRepeatEx(proj,-1),playrate=reaper.Master_GetPlayRate(proj),
    preserve_pitch=preserve_pitch,cursor=reaper.GetCursorPositionEx(proj),
    selection_start=start_time,selection_end=end_time,transport_end=transport_end,
    stop_at_loop_end_state=original_stop_state
  }
  reaper.OnStopButtonEx(proj)
  reaper.GetSet_LoopTimeRange2(proj,true,true,start_time,transport_end,false)
  reaper.GetSetRepeatEx(proj,state.audition_loop and 1 or 0)
  if state.audition_half_speed then
    if not set_project_int_config(proj,"audioprshift",1) then
      restore_audition_state(start_time)
      show_info("Audition Unavailable","SWS/S&M could not enable Preserve pitch in audio items for the 50% audition.","warning")
      return
    end
    reaper.CSurf_OnPlayRateChange(0.5)
  end
  reaper.SetEditCurPos2(proj,start_time,true,false)
  reaper.OnPlayButtonEx(proj)
  state.audition_active=true
  set_status(string.format("Auditioning selected rows%s%s.",state.audition_loop and " in a loop" or " once",state.audition_half_speed and " at 50% speed" or ""),"success")
end

function update_audition_transport()
  if not state.audition_active or not state.audition_restore then return end
  local restore=state.audition_restore
  if not state.audition_loop and reaper.GetPlayStateEx(restore.proj)==0 then restore_audition_state(restore.selection_start);return end
  if not state.audition_loop and reaper.GetToggleCommandStateEx(0,ACTION_STOP_PLAYBACK_AT_LOOP_END)~=1 then
    reaper.OnStopButtonEx(restore.proj);restore_audition_state(restore.selection_start)
    set_status("Audition stopped because REAPER's exact range-end transport setting changed.","warning")
  end
end

function ramp_elapsed_for_qn(qn,total_qn,start_bpm,end_bpm)
  if total_qn<=0 then return 0 end
  if nearly_equal(start_bpm,end_bpm,1e-9) then return qn*60/start_bpm end
  local total_time=120*total_qn/(start_bpm+end_bpm)
  local slope=(end_bpm-start_bpm)/total_time
  local discriminant=math.max(0,start_bpm*start_bpm+120*slope*qn)
  return (-start_bpm+math.sqrt(discriminant))/slope
end

function click_events_for_parts(parts,speed_factor,max_seconds)
  local speed=tonumber(speed_factor) or 1
  if speed<=0 then return nil,nil,"Preview speed must be greater than zero." end
  if max_seconds==nil then max_seconds=PREVIEW_MAX_SECONDS end
  local events={};local elapsed=0
  for _,part in ipairs(parts or {}) do
    local qn_per_beat=4/part.denominator;local qn_per_bar=part.numerator*qn_per_beat
    local ramp_bars=part.ramp and (part.ramp_bars or 0) or 0;local steady_bars=part.repeats-ramp_bars
    local steady_bpm=part.effective_bpm*speed
    local beat_seconds=qn_per_beat*60/steady_bpm
    for bar=1,steady_bars do
      for beat=0,part.numerator-1 do events[#events+1]={time=elapsed+beat*beat_seconds,accent=part.no_accent or beat==0} end
      elapsed=elapsed+qn_per_bar*60/steady_bpm
    end
    if ramp_bars>0 then
      local target=(part.ramp_target_bpm or END_BPM)*speed;local total_qn=ramp_bars*qn_per_bar;local ramp_start=elapsed
      for bar=0,ramp_bars-1 do
        for beat=0,part.numerator-1 do
          local qn=bar*qn_per_bar+beat*qn_per_beat
          events[#events+1]={time=ramp_start+ramp_elapsed_for_qn(qn,total_qn,steady_bpm,target),accent=part.no_accent or beat==0}
        end
      end
      elapsed=ramp_start+ramp_elapsed_for_qn(total_qn,total_qn,steady_bpm,target)
    end
    if max_seconds and elapsed>max_seconds then return nil,nil,string.format("The generated click is longer than the %d-minute safety limit.",math.floor(max_seconds/60)) end
  end
  return events,elapsed
end

function simple_tempo_audition_parts(bpm)
  local part=parse_part("[4]",bpm)
  part.no_accent=false;part.section_name="Tempo Preview"
  return {part}
end

function tempo_preview_bpm()
  local field=state.tempo_preview_field or {value=tostring(state.tempo_audition_bpm or 120)}
  local bpm,err=parse_positive_decimal(field.value,"Tempo Preview BPM")
  if not bpm then return nil,err end
  if bpm<TEMPO_AUDITION_MIN_BPM or bpm>TEMPO_AUDITION_MAX_BPM then return nil,string.format("Tempo Preview BPM must be between %d and %d.",TEMPO_AUDITION_MIN_BPM,TEMPO_AUDITION_MAX_BPM) end
  return bpm
end

function play_tempo_preview()
  local bpm,err=tempo_preview_bpm()
  if not bpm then show_info("Tempo Preview Unavailable","[AUD-001] "..tostring(err),"error");return end
  state.tempo_audition_bpm=round_hundredth(bpm)
  start_click_audio_preview(simple_tempo_audition_parts(bpm),true,false,"tempo")
end

function handle_tempo_preview_keyboard(key,locked)
  if locked or state.active_view~="BUILD" or not state.tempo_preview_has_focus or not key or key==0 then return false end
  if key==TEXT_KEYS.ESCAPE then state.tempo_preview_has_focus=false;return true end
  if key==TEXT_KEYS.TAB then state.tempo_preview_has_focus=false;return false end
  if key==TEXT_KEYS.ENTER then play_tempo_preview();return true end
  local field=state.tempo_preview_field;local ctrl=(gfx.mouse_cap&4)==4;local shift=(gfx.mouse_cap&8)==8
  local value,cursor,anchor,changed,handled,clipboard_status,clipboard_error=edit_text_with_clipboard(field.value or "",field.cursor,field.anchor,key,ctrl,shift)
  if handled then
    field.value=value;field.cursor=cursor;field.anchor=anchor
    if changed and state.audio_preview and state.audio_preview.owner=="tempo" then stop_audio_preview(true) end
    if clipboard_status then set_status(clipboard_status,"success") end
    if clipboard_error then set_status(clipboard_error,"error") end
    return true
  end
  return false
end

function write_click_preview_wav(path,events,duration,click_a,click_b,tail_seconds)
  if not string.pack then return false,"This REAPER Lua runtime does not provide binary packing required for preview audio." end
  local sample_rate=PREVIEW_SAMPLE_RATE;local click_samples=math.max(1,math.floor(PREVIEW_CLICK_SECONDS*sample_rate+0.5));local tail=tonumber(tail_seconds);if tail==nil then tail=PREVIEW_CLICK_SECONDS end
  local total_samples=math.max(1,math.floor((duration+math.max(0,tail))*sample_rate+0.5));local data_bytes=total_samples*2
  local file,open_err=io.open(path,"wb");if not file then return false,"Temporary preview audio could not be created: "..tostring(open_err) end
  local header="RIFF"..string.pack("<I4",36+data_bytes).."WAVEfmt "..string.pack("<I4I2I2I4I4I2I2",16,1,1,sample_rate,sample_rate*2,2,16).."data"..string.pack("<I4",data_bytes)
  file:write(header)
  local event_index=1;local active={};local sample_index=0;local zero_block=string.rep("\0",8192)
  local ok,render_err=xpcall(function()
    while sample_index<total_samples do
      local next_event=events[event_index];local next_sample=next_event and math.max(0,math.floor(next_event.time*sample_rate+0.5)) or total_samples
      if #active==0 and sample_index<next_sample then
        local gap=math.min(next_sample-sample_index,total_samples-sample_index)
        while gap>0 do local count=math.min(gap,4096);file:write(count==4096 and zero_block or string.rep("\0",count*2));sample_index=sample_index+count;gap=gap-count end
      else
        while events[event_index] and math.floor(events[event_index].time*sample_rate+0.5)<=sample_index do
          local event=events[event_index];active[#active+1]={start=math.floor(event.time*sample_rate+0.5),frequency=event.accent and click_a or click_b,amplitude=event.accent and 0.82 or 0.58};event_index=event_index+1
        end
        local value=0
        for index=#active,1,-1 do
          local voice=active[index];local age=sample_index-voice.start
          if age>=click_samples then table.remove(active,index)
          elseif age>=0 then
            local envelope=math.exp(-7*age/click_samples);local attack=math.min(1,age/8)
            value=value+math.sin(2*math.pi*voice.frequency*age/sample_rate)*voice.amplitude*envelope*attack
          end
        end
        value=math.max(-1,math.min(1,value));file:write(string.pack("<i2",math.floor(value*32767)));sample_index=sample_index+1
      end
    end
  end,debug.traceback)
  file:close()
  if not ok then os.remove(path);return false,"Preview audio rendering failed: "..tostring(render_err) end
  if event_index<=#events then
    os.remove(path)
    return false,string.format("Audio rendering ended before all scheduled clicks were written (%d of %d consumed).",event_index-1,#events)
  end
  return true
end

function remove_preview_file(path)
  if not path or path=="" then return end
  if not os.remove(path) then state.audio_preview_cleanup[#state.audio_preview_cleanup+1]=path end
end

function stop_audio_preview(silent)
  local preview=state.audio_preview
  if not preview then return end
  if preview.backend=="sws" and preview.handle then
    if reaper.CF_Preview_Stop then pcall(reaper.CF_Preview_Stop,preview.handle) end
    if reaper.CF_Preview_Delete then pcall(reaper.CF_Preview_Delete,preview.handle) end
    if preview.source and reaper.PCM_Source_Destroy then pcall(reaper.PCM_Source_Destroy,preview.source) end
  elseif preview.backend=="media_explorer" and reaper.OpenMediaExplorer and reaper.time_precise()<(preview.started_at+preview.duration+0.15) then pcall(reaper.OpenMediaExplorer,preview.path,true) end
  remove_preview_file(preview.path);state.audio_preview=nil
  if not silent then set_status("Audio preview stopped.","info") end
end

function start_click_audio_preview(parts,looping,half_speed,owner)
  stop_audio_preview(true)
  local events,duration,schedule_err=click_events_for_parts(parts,half_speed and 0.5 or 1)
  if not events then show_info("Audio Preview Unavailable","[AUD-001] "..tostring(schedule_err),"error");return false end
  local path=make_temp_path(".wav");local rendered,render_err=write_click_preview_wav(path,events,duration,state.click_a_hz,state.click_b_hz)
  if not rendered then show_info("Audio Preview Unavailable","[AUD-002] "..tostring(render_err),"error");return false end
  if reaper.CF_CreatePreview and reaper.CF_Preview_Play and reaper.CF_Preview_SetValue then
    local source=reaper.PCM_Source_CreateFromFile(path)
    if not source then remove_preview_file(path);show_info("Audio Preview Unavailable","[AUD-003] REAPER could not open the generated temporary WAV source.","error");return false end
    local handle=reaper.CF_CreatePreview(source)
    if not handle then reaper.PCM_Source_Destroy(source);remove_preview_file(path);show_info("Audio Preview Unavailable","[AUD-003] SWS could not create a source preview.","error");return false end
    reaper.CF_Preview_SetValue(handle,"I_OUTCHAN",0);reaper.CF_Preview_SetValue(handle,"D_VOLUME",1);reaper.CF_Preview_SetValue(handle,"B_LOOP",looping and 1 or 0)
    local play_ok,play_result=pcall(reaper.CF_Preview_Play,handle)
    if not play_ok or play_result==false then
      if reaper.CF_Preview_Delete then pcall(reaper.CF_Preview_Delete,handle) end
      reaper.PCM_Source_Destroy(source);remove_preview_file(path);show_info("Audio Preview Unavailable","[AUD-003] SWS could not start the generated source preview.","error");return false
    end
    state.audio_preview={backend="sws",handle=handle,source=source,path=path,duration=duration+PREVIEW_CLICK_SECONDS,started_at=reaper.time_precise(),looping=looping,owner=owner}
  elseif reaper.OpenMediaExplorer then
    reaper.OpenMediaExplorer(path,true)
    state.audio_preview={backend="media_explorer",path=path,duration=duration+PREVIEW_CLICK_SECONDS,started_at=reaper.time_precise(),looping=looping,owner=owner}
    if looping then set_status("Native Media Explorer fallback is looping the preview; SWS provides the cleaner background-preview path.","warning") end
  else
    remove_preview_file(path);show_info("Audio Preview Unavailable","[AUD-004] Install SWS/S&M for background previews, or use a REAPER version that exposes Media Explorer playback to ReaScript.","error");return false
  end
  set_status(string.format("Playing %s%s%s.",owner=="scratchpad" and "the complete Scratchpad expression" or "Tempo Preview",looping and " in a loop" or "",half_speed and " at 50% speed" or ""),"success")
  return true
end

function service_audio_preview()
  local preview=state.audio_preview
  if preview then
    if preview.backend=="sws" then
      if not preview.looping and reaper.time_precise()>=preview.started_at+preview.duration+0.1 then stop_audio_preview(true) end
    elseif preview.backend=="media_explorer" and reaper.time_precise()>=preview.started_at+preview.duration then
      if preview.looping then reaper.OpenMediaExplorer(preview.path,true);preview.started_at=reaper.time_precise()
      else local path=preview.path;state.audio_preview=nil;remove_preview_file(path) end
    end
  end
  if #state.audio_preview_cleanup>0 then
    local remaining={};for _,path in ipairs(state.audio_preview_cleanup) do if file_exists(path) and not os.remove(path) then remaining[#remaining+1]=path end end;state.audio_preview_cleanup=remaining
  end
end

function scratchpad_play_preview()
  local result=state.scratchpad_result
  if not result or not result.ok then show_info("Scratchpad Preview Unavailable","Test a valid Scratchpad expression first.","warning");return end
  start_click_audio_preview(result.parts,state.scratchpad_preview_loop,state.scratchpad_preview_half_speed,"scratchpad")
end

function click_package_parts(plan)
  if not plan then return nil end
  local parts={{
    source="AUTO COUNT-IN",canonical="COUNT IN",section_name=COUNT_IN.name,
    numerator=COUNT_IN.numerator,denominator=COUNT_IN.denominator,repeats=COUNT_IN.bars,
    underlying_bpm=plan.count_in_bpm,effective_bpm=plan.count_in_bpm,
    no_accent=false,ramp=false,ramp_bars=0
  }}
  for _,part in ipairs(plan.flat_parts or {}) do parts[#parts+1]=part end
  return parts
end

function expected_click_count(parts)
  local total=0
  for index,part in ipairs(parts or {}) do
    local numerator=tonumber(part.numerator);local repeats=tonumber(part.repeats)
    if not numerator or numerator<1 or numerator%1~=0 or not repeats or repeats<1 or repeats%1~=0 then
      return nil,"Part "..tostring(index).." does not have a valid whole numerator and repeat count."
    end
    total=total+numerator*repeats
    if total>CLICK_EXPORT_MAX_MIDI_EVENTS then return nil,"The complete click count exceeds the "..CLICK_EXPORT_MAX_MIDI_EVENTS.."-event safety limit." end
  end
  return total
end

function midi_variable_length(value)
  value=math.max(0,math.floor(tonumber(value) or 0))
  local bytes={value&0x7F}
  value=math.floor(value/128)
  while value>0 do
    table.insert(bytes,1,(value&0x7F)|0x80)
    value=math.floor(value/128)
  end
  return string.char(table.unpack(bytes))
end

function midi_meta_event(meta_type,data)
  data=tostring(data or "")
  return string.char(0xFF,meta_type&0xFF)..midi_variable_length(#data)..data
end

function midi_tempo_data(bpm)
  bpm=tonumber(bpm)
  if not bpm or bpm<=0 then return nil,"MIDI tempo must be a positive number." end
  local microseconds=math.floor(60000000/bpm+0.5)
  if microseconds<1 or microseconds>0xFFFFFF then
    return nil,string.format("BPM %s cannot be represented by a Standard MIDI File tempo event.",format_bpm(bpm))
  end
  return string.char((microseconds>>16)&0xFF,(microseconds>>8)&0xFF,microseconds&0xFF)
end

function midi_time_signature_data(numerator,denominator)
  numerator=tonumber(numerator);denominator=tonumber(denominator)
  if not numerator or numerator<1 or numerator>255 or numerator%1~=0 then
    return nil,"Standard MIDI time-signature numerators must be whole numbers from 1 through 255."
  end
  local power=0;local value=denominator
  while value and value>1 and value%2==0 do value=value/2;power=power+1 end
  if value~=1 or power>7 then return nil,"The time-signature denominator is not representable by a Standard MIDI File." end
  return string.char(numerator,power,24,8)
end

function add_midi_event(events,tick,order,data)
  events[#events+1]={tick=math.max(0,math.floor((tonumber(tick) or 0)+0.5)),order=tonumber(order) or 0,data=data}
end

function add_midi_tempo(events,tick,bpm)
  local data,err=midi_tempo_data(bpm)
  if not data then return false,err end
  add_midi_event(events,tick,30,midi_meta_event(0x51,data))
  return true
end

function add_midi_time_signature(events,tick,numerator,denominator)
  local data,err=midi_time_signature_data(numerator,denominator)
  if not data then return false,err end
  add_midi_event(events,tick,20,midi_meta_event(0x58,data))
  return true
end

function midi_track_chunk(events,end_tick)
  add_midi_event(events,end_tick,1000,midi_meta_event(0x2F,""))
  table.sort(events,function(a,b) return a.tick==b.tick and a.order<b.order or a.tick<b.tick end)
  local body={};local previous=0
  for _,event in ipairs(events) do
    if event.tick<previous then return nil,"MIDI events are not in chronological order." end
    body[#body+1]=midi_variable_length(event.tick-previous)..event.data
    previous=event.tick
  end
  body=table.concat(body)
  return "MTrk"..string.pack(">I4",#body)..body
end

function midi_section_marker_name(plan,part,generic_names)
  if not generic_names then return tostring(part and part.section_name or "SECTION") end
  for index,section in ipairs((plan and plan.sections) or {}) do
    if part and section.row==part.section_row then return "PART "..tostring(index) end
  end
  return "PART"
end

function build_click_midi(plan,generic_marker_names)
  if not plan or not plan.flat_parts then return nil,nil,"[CPX-001] Validate a workbook before creating a click package." end
  if not string.pack then return nil,nil,"[CPX-003] This REAPER Lua runtime does not provide binary packing." end
  local tempo_events,note_events={},{}
  local title=clean_workbook_title(plan.file_path)
  add_midi_event(tempo_events,0,0,midi_meta_event(0x03,title.." Tempo and Meter Map"))
  add_midi_event(tempo_events,0,10,midi_meta_event(0x06,COUNT_IN.name))
  add_midi_event(note_events,0,0,midi_meta_event(0x03,title.." MIDI Click"))
  local ok,err=add_midi_time_signature(tempo_events,0,COUNT_IN.numerator,COUNT_IN.denominator)
  if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
  ok,err=add_midi_tempo(tempo_events,0,plan.count_in_bpm)
  if not ok then return nil,nil,"[CPX-003] "..tostring(err) end

  local qn_cursor=0
  local note_ticks={}
  local function add_part_clicks(part,start_qn)
    local qn_per_beat=4/part.denominator;local qn_per_bar=part.numerator*qn_per_beat
    for bar=0,part.repeats-1 do
      for beat=0,part.numerator-1 do
        if #note_ticks>=CLICK_EXPORT_MAX_MIDI_EVENTS then return false,"The MIDI click exceeds the "..CLICK_EXPORT_MAX_MIDI_EVENTS.."-note safety limit." end
        local tick=math.floor((start_qn+bar*qn_per_bar+beat*qn_per_beat)*MIDI_PPQ+0.5)
        local accent=part.no_accent or beat==0
        local note=accent and MIDI_ACCENT_NOTE or MIDI_REGULAR_NOTE
        local velocity=accent and MIDI_ACCENT_VELOCITY or MIDI_REGULAR_VELOCITY
        note_ticks[#note_ticks+1]=tick
        add_midi_event(note_events,tick,20,string.char(0x99,note,velocity))
        add_midi_event(note_events,tick+MIDI_NOTE_LENGTH_TICKS,10,string.char(0x89,note,0))
      end
    end
    return true
  end

  local count_part=click_package_parts(plan)[1]
  ok,err=add_part_clicks(count_part,qn_cursor)
  if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
  qn_cursor=qn_cursor+COUNT_IN.bars*COUNT_IN.numerator*4/COUNT_IN.denominator
  local previous_section_key=nil
  local marker_names={COUNT_IN.name}

  for _,part in ipairs(plan.flat_parts) do
    local start_qn=qn_cursor;local start_tick=math.floor(start_qn*MIDI_PPQ+0.5)
    local section_key=part.section_row or part.section_name
    if section_key~=previous_section_key then
      local marker_name=midi_section_marker_name(plan,part,generic_marker_names==true)
      add_midi_event(tempo_events,start_tick,10,midi_meta_event(0x06,marker_name))
      marker_names[#marker_names+1]=marker_name
      previous_section_key=section_key
    end
    ok,err=add_midi_time_signature(tempo_events,start_tick,part.numerator,part.denominator)
    if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
    local qn_per_bar=part.numerator*4/part.denominator
    local ramp_bars=part.ramp and (part.ramp_bars or 0) or 0
    local steady_qn=(part.repeats-ramp_bars)*qn_per_bar
    if steady_qn>0 or ramp_bars==0 then
      ok,err=add_midi_tempo(tempo_events,start_tick,part.effective_bpm)
      if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
    end
    if ramp_bars>0 then
      local ramp_qn=ramp_bars*qn_per_bar
      local target=part.ramp_target_bpm or plan.end_effective_bpm or END_BPM
      local step=1/MIDI_RAMP_STEPS_PER_QN
      local position=0
      while position<ramp_qn-1e-12 do
        if #tempo_events>=CLICK_EXPORT_MAX_MIDI_EVENTS then return nil,nil,"[CPX-003] The MIDI Ramp map exceeds the event safety limit." end
        local next_position=math.min(ramp_qn,position+step)
        local t0=ramp_elapsed_for_qn(position,ramp_qn,part.effective_bpm,target)
        local t1=ramp_elapsed_for_qn(next_position,ramp_qn,part.effective_bpm,target)
        local segment_bpm=60*(next_position-position)/(t1-t0)
        local tick=math.floor((start_qn+steady_qn+position)*MIDI_PPQ+0.5)
        ok,err=add_midi_tempo(tempo_events,tick,segment_bpm)
        if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
        position=next_position
      end
    end
    ok,err=add_part_clicks(part,start_qn)
    if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
    qn_cursor=qn_cursor+part.repeats*qn_per_bar
  end

  local end_tick=math.floor(qn_cursor*MIDI_PPQ+0.5)
  add_midi_event(tempo_events,end_tick,10,midi_meta_event(0x06,"END"))
  marker_names[#marker_names+1]="END"
  ok,err=add_midi_time_signature(tempo_events,end_tick,END_NUM,END_DEN)
  if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
  ok,err=add_midi_tempo(tempo_events,end_tick,plan.end_effective_bpm or END_BPM)
  if not ok then return nil,nil,"[CPX-003] "..tostring(err) end
  for _,event in ipairs(note_events) do
    if event.tick>end_tick then event.tick=end_tick end
  end
  local tempo_track,tempo_err=midi_track_chunk(tempo_events,end_tick)
  if not tempo_track then return nil,nil,"[CPX-003] "..tostring(tempo_err) end
  local note_track,note_err=midi_track_chunk(note_events,end_tick)
  if not note_track then return nil,nil,"[CPX-003] "..tostring(note_err) end
  local bytes="MThd"..string.pack(">I4I2I2I2",6,1,2,MIDI_PPQ)..tempo_track..note_track
  local model={
    end_tick=end_tick,end_qn=qn_cursor,note_ticks=note_ticks,
    tempo_event_count=#tempo_events,note_count=#note_ticks,
    section_marker_count=#(plan.sections or {})+2,marker_names=marker_names,generic_marker_names=generic_marker_names==true,bytes=#bytes
  }
  if note_ticks[#note_ticks] and note_ticks[#note_ticks]>=end_tick then
    return nil,nil,"[CPX-003] The generated MIDI click contains an unexpected note at END."
  end
  return bytes,model
end

function verify_click_midi_bytes(bytes,model)
  if type(bytes)~="string" or bytes:sub(1,4)~="MThd" then return false,"The MIDI header is missing." end
  if #bytes<30 then return false,"The MIDI file is unexpectedly short." end
  local header_length,format,tracks,division=string.unpack(">I4I2I2I2",bytes,5)
  if header_length~=6 or format~=1 or tracks~=2 or division~=MIDI_PPQ then
    return false,string.format("Unexpected MIDI header: length %s, format %s, tracks %s, PPQ %s.",tostring(header_length),tostring(format),tostring(tracks),tostring(division))
  end
  local track_chunks=0;local position=15
  while true do
    local found=bytes:find("MTrk",position,true)
    if not found then break end
    track_chunks=track_chunks+1;position=found+4
  end
  if track_chunks~=2 then return false,"The MIDI file does not contain exactly two tracks." end
  if not model or not model.end_tick or not model.note_ticks or model.note_ticks[#model.note_ticks]>=model.end_tick then
    return false,"The MIDI END-boundary contract did not verify."
  end
  return true
end

function copy_binary_file(source,destination)
  local input,input_err=io.open(source,"rb");if not input then return false,input_err end
  local output,output_err=io.open(destination,"wb")
  if not output then input:close();return false,output_err end
  local ok,err=xpcall(function()
    while true do
      local chunk=input:read(1024*1024)
      if not chunk then break end
      assert(output:write(chunk))
    end
  end,debug.traceback)
  input:close();output:close()
  if not ok then os.remove(destination);return false,err end
  return true
end

local PS_REAPER_MP3_CONVERT=[=[
param([string]$OutputPath,[string]$ExePath,[string]$JobPath,[string]$ExpectedPath)
$ErrorActionPreference='Stop';$e=New-Object Text.UTF8Encoding($false)
function B64([string]$Text){if($null-eq $Text){$Text=''};[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}
try{
  if(!(Test-Path -LiteralPath $ExePath)){throw "REAPER executable was not found: $ExePath"}
  $quoted='"'+$JobPath.Replace('"','\"')+'"'
  $process=Start-Process -FilePath $ExePath -ArgumentList @('-newinst','-nosplash','-batchconvert',$quoted) -WindowStyle Hidden -PassThru -Wait
  $deadline=[DateTime]::UtcNow.AddSeconds(90)
  while(!(Test-Path -LiteralPath $ExpectedPath) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
  if(!(Test-Path -LiteralPath $ExpectedPath)){
    $log=$JobPath+'.log';$detail=''
    if(Test-Path -LiteralPath $log){$detail=[IO.File]::ReadAllText($log)}
    throw "REAPER did not create the MP3 output. $detail"
  }
  $info=Get-Item -LiteralPath $ExpectedPath
  if($info.Length -lt 128){throw "REAPER created an unexpectedly small MP3 file ($($info.Length) bytes)."}
  [IO.File]::WriteAllText($OutputPath,'OK',$e)
}catch{
  [IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+(B64 $_.Exception.Message)),$e);exit 1
}
]=]

function mp3_batch_job_text(wav_path,mp3_path)
  return table.concat({
    wav_path.."\t"..mp3_path,
    "<CONFIG",
    "  SRATE "..PREVIEW_SAMPLE_RATE,
    "  NCH 1",
    "  <OUTFMT",
    "    "..DEFAULT_MP3_RENDER_CONFIG,
    "  >",
    ">",
    ""
  },"\r\n")
end

function render_wav_to_mp3(wav_path,mp3_path)
  if not reaper.GetOS():match("Win") then return false,"Click-package MP3 conversion currently requires the Windows release." end
  local exe=path_join(reaper.GetExePath(),"reaper.exe")
  if not file_exists(exe) then return false,"REAPER executable was not found at "..exe end
  local job=make_temp_path("_click_package_batch.txt")
  os.remove(mp3_path)
  local wrote,write_err=write_file(job,mp3_batch_job_text(wav_path,mp3_path))
  if not wrote then return false,"Could not create the temporary REAPER batch-conversion job: "..tostring(write_err) end
  local result,convert_err=run_powershell_text(PS_REAPER_MP3_CONVERT,{
    {name="ExePath",value=exe},{name="JobPath",value=job},{name="ExpectedPath",value=mp3_path}
  },300000)
  local log=job..".log";os.remove(job);os.remove(log)
  if result~="OK" then os.remove(mp3_path);return false,convert_err or "REAPER did not confirm MP3 conversion." end
  local file,file_err=io.open(mp3_path,"rb")
  if not file then return false,"The converted MP3 could not be reopened: "..tostring(file_err) end
  local header=file:read(3) or "";local size=file:seek("end") or 0;file:close()
  local b1,b2=header:byte(1,2)
  if size<128 or not (header=="ID3" or (b1==0xFF and b2 and (b2&0xE0)==0xE0)) then
    os.remove(mp3_path);return false,"REAPER's output did not pass the MP3 header and size checks."
  end
  return true
end

function click_package_default_filename(plan)
  local title=sanitize_filename(clean_workbook_title(plan and plan.file_path or state.file_path))
  if trim(title)=="" then title="Song" end
  return title.."_CLICK_PACKAGE_"..os.date("%Y-%m-%d_%H%M%S")..".mp3"
end

function click_package_output_paths(selected_path)
  selected_path=trim(selected_path)
  if selected_path=="" then return nil,nil,"No output filename was selected." end
  local stem=selected_path:gsub("%.[Mm][Pp]3$",""):gsub("%.[Mm][Ii][Dd][Ii]?$","")
  if trim(basename(stem))=="" then return nil,nil,"Enter a filename before the extension." end
  return stem..".mp3",stem..".mid"
end

function click_package_available()
  if not state.plan then return false,"Validate a workbook successfully before exporting a click package." end
  if state.preview_stale then return false,"The workbook changed after validation; validate it again before exporting." end
  if state.operation_busy then return false,"Wait for the current workbook, logging, export, or build operation to finish." end
  return true
end

function run_click_package_transaction(callback)
  local call_ok,result=xpcall(callback,debug.traceback)
  if not call_ok then return nil,result end
  return result
end

function export_click_package()
  local available,reason=click_package_available()
  if not available then show_info("Click Package Unavailable","[CPX-001] "..tostring(reason),"warning");return end
  mark_file_stale_if_changed()
  if state.preview_stale then show_info("Click Package Unavailable","[CPX-001] The workbook changed after validation. Validate it again before exporting.","warning");return end
  local selected,dialog_err=choose_save_path(
    "Export MIDI + MP3 Click Package",
    "MP3 click package (*.mp3)|*.mp3|All files (*.*)|*.*",
    click_package_default_filename(state.plan),
    dirname(state.plan.file_path)
  )
  if not selected then if dialog_err~="CANCELLED" then show_info("Click Package Export Failed","[CPX-002] "..tostring(dialog_err),"error") end;return end
  local mp3_path,midi_path,path_err=click_package_output_paths(selected)
  if not mp3_path then show_info("Click Package Export Failed","[CPX-002] "..tostring(path_err),"error");return end
  if file_exists(mp3_path) or file_exists(midi_path) then
    show_info("Choose a New Click Package Name","[CPX-002] This export never replaces an existing package file. Choose a different base filename so both outputs are new.\n\nMP3:\n"..mp3_path.."\n\nMIDI:\n"..midi_path,"warning")
    return
  end

  state.operation_busy=true
  set_status("Creating synchronized MIDI and MP3 click files...","info")
  gfx.update()
  local temp_wav=make_temp_path(".wav")
  local temp_mp3=make_temp_path(".mp3")
  local temp_midi=make_temp_path(".mid")
  local partial_mp3=mp3_path..".partial"
  local partial_midi=midi_path..".partial"
  local function cleanup()
    for _,path in ipairs({temp_wav,temp_mp3,temp_midi,partial_mp3,partial_midi}) do os.remove(path) end
  end
  local result,export_err=run_click_package_transaction(function()
    local parts=click_package_parts(state.plan)
    local audio_events,duration,schedule_err=click_events_for_parts(parts,1,CLICK_EXPORT_MAX_SECONDS)
    if not audio_events then error("[CPX-004] "..tostring(schedule_err)) end
    local expected_clicks,count_err=expected_click_count(parts)
    if not expected_clicks then error("[CPX-004] "..tostring(count_err)) end
    if #audio_events~=expected_clicks then
      error(string.format("[CPX-004] The audio schedule contains %d clicks, but the complete validated structure requires %d.",#audio_events,expected_clicks))
    end
    if math.abs(duration-(state.plan.total_duration_with_count_in or duration))>0.001 then
      error("[CPX-004] The permanent audio schedule does not match the validated song duration.")
    end
    local midi_bytes,midi_model,midi_err=build_click_midi(state.plan,state.song_readout_generic_names)
    if not midi_bytes then error(tostring(midi_err)) end
    if midi_model.note_count~=expected_clicks then
      error(string.format("[CPX-003] The MIDI contains %d click notes, but the complete validated structure requires %d.",midi_model.note_count,expected_clicks))
    end
    local midi_ok,midi_verify_err=verify_click_midi_bytes(midi_bytes,midi_model)
    if not midi_ok then error("[CPX-003] "..tostring(midi_verify_err)) end
    local midi_written,midi_write_err=write_file(temp_midi,midi_bytes)
    if not midi_written then error("[CPX-003] The temporary MIDI file could not be written: "..tostring(midi_write_err)) end
    local wav_written,wav_err=write_click_preview_wav(temp_wav,audio_events,duration,state.click_a_hz,state.click_b_hz,CLICK_EXPORT_TAIL_SECONDS)
    if not wav_written then error("[CPX-004] "..tostring(wav_err)) end
    local mp3_ok,mp3_err=render_wav_to_mp3(temp_wav,temp_mp3)
    if not mp3_ok then error("[CPX-005] "..tostring(mp3_err)) end
    local copied,copy_err=copy_binary_file(temp_mp3,partial_mp3)
    if not copied then error("[CPX-006] The MP3 could not be staged in the selected folder: "..tostring(copy_err)) end
    copied,copy_err=copy_binary_file(temp_midi,partial_midi)
    if not copied then error("[CPX-006] The MIDI file could not be staged in the selected folder: "..tostring(copy_err)) end
    if file_exists(mp3_path) or file_exists(midi_path) then error("[CPX-006] A destination file appeared while the package was being created; nothing was replaced.") end
    local moved_mp3,move_mp3_err=os.rename(partial_mp3,mp3_path)
    if not moved_mp3 then error("[CPX-006] The final MP3 could not be committed: "..tostring(move_mp3_err)) end
    local moved_midi,move_midi_err=os.rename(partial_midi,midi_path)
    if not moved_midi then os.remove(mp3_path);error("[CPX-006] The final MIDI file could not be committed: "..tostring(move_midi_err)) end
    local final_midi=read_file(midi_path);local final_ok,final_err=verify_click_midi_bytes(final_midi,midi_model)
    if not final_ok then os.remove(mp3_path);os.remove(midi_path);error("[CPX-006] Final MIDI verification failed: "..tostring(final_err)) end
    return {mp3=mp3_path,midi=midi_path,duration=duration,notes=midi_model.note_count,end_measure=state.plan.end_visible_measure}
  end)
  cleanup()
  state.operation_busy=false
  if not result then
    set_status("Click package export failed.","error")
    show_info("Click Package Export Failed",tostring(export_err),"error")
    return
  end
  set_status("MIDI and MP3 click package exported.","success")
  show_confirm(
    "MIDI + MP3 Click Package Exported",
    "Both files were generated from the same validated structure and verified.\n\nMIDI tempo/meter and click notes:\n"..result.midi..
    "\n\nAudible MP3 click:\n"..result.mp3..
    "\n\nMusical endpoint: END at measure "..tostring(result.end_measure)..
    "\nClick notes: "..tostring(result.notes)..
    "\nMIDI marker names: "..(state.song_readout_generic_names and "Generic PART 1, PART 2, etc." or "Original workbook Section names")..
    "\nMusical duration including COUNT IN: "..format_duration(result.duration)..
    "\n\nThe MIDI file has no note at END. The MP3 contains no extra beat and includes only a "..math.floor(CLICK_EXPORT_TAIL_SECONDS*1000+0.5).." ms audio safety tail. Import the MIDI tempo/time-signature data in Logic or Pro Tools to create the bar grid.",
    "Open Export Folder","Close",
    function()
      local opened,open_err=shell_open(dirname(result.mp3))
      if not opened then show_info("Export Folder Could Not Open",tostring(open_err),"warning") end
    end,nil,"success"
  )
end

function set_tempo_modal_bpm(modal,bpm)
  bpm=math.max(TEMPO_AUDITION_MIN_BPM,math.min(TEMPO_AUDITION_MAX_BPM,tonumber(bpm) or state.tempo_audition_bpm or 120))
  state.tempo_audition_bpm=round_hundredth(bpm)
  local field=modal and modal.fields and modal.fields[1]
  if field then field.value=format_bpm(state.tempo_audition_bpm);field.cursor=#field.value;field.anchor=field.cursor;field.view_start=0 end
end

function copy_current_build_id()
  if not state.current_attempt then return end
  local ok,err=copy_to_clipboard(state.current_attempt.id)
  set_status(ok and "Build ID copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
end

function open_current_log()
  if state.current_log_path and file_exists(state.current_log_path) then
    local ok,err=shell_open(state.current_log_path)
    if ok then set_status("Opened current attempt log.","success") else show_info("Current Log Could Not Open",tostring(err),"error") end
  else show_info("Current Log Unavailable","The current attempt logfile is not available.","warning") end
end

function open_log_folder()
  local info=get_active_project_info()
  if not project_is_saved(info) then show_info("Log Folder Unavailable","Save the active REAPER project as an .RPP first so its log-folder location is known.","warning");return end
  local folder=project_log_folder(info);local ok,err=ensure_directory(folder);if not ok then show_info("Log Folder Error",err,"error");return end
  local opened,open_err=shell_open(folder);if opened then set_status("Opened the project log folder.","success") else show_info("Log Folder Could Not Open",tostring(open_err),"error") end
end

function open_selected_log()
  local e=selected_history_entry();if not e then return end
  local path=path_join(state.history_folder,e.log_filename)
  if e.available and file_exists(path) then
    local ok,err=shell_open(path);if ok then set_status("Opened selected attempt log.","success") else show_info("Selected Log Could Not Open",tostring(err),"error") end
  else show_info("Selected Log Unavailable","The selected logfile is unavailable. It may have been removed by log cleanup.","warning") end
end

function copy_selected_history_id()
  local e=selected_history_entry();if not e then return end
  local ok,err=copy_to_clipboard(e.id);set_status(ok and "Selected build ID copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
end

local PS_OLD_LOGS=[=[
param([string]$OutputPath,[string]$Folder,[string]$Days)
$ErrorActionPreference='Stop';$e=New-Object Text.UTF8Encoding($false)
try{
  $cut=(Get-Date).AddDays(-[double]$Days)
  $lines=@(Get-ChildItem -LiteralPath $Folder -Filter '*.txt' -File -ErrorAction SilentlyContinue|Where-Object{$_.LastWriteTime -lt $cut -and $_.Name -notlike '*_IN_PROGRESS.txt'}|ForEach-Object{[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.FullName))+"`t"+$_.Length})
  $content=if($lines.Count -gt 0){($lines -join "`r`n")+"`r`n"}else{''}
  [IO.File]::WriteAllText($OutputPath,$content,$e)
}catch{[IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e);exit 1}
]=]

function clean_up_logs()
  local info=get_active_project_info()
  if not project_is_saved(info) then show_info("Clean Up Logs","Save the active REAPER project as an .RPP first so its log folder is known.","warning");return end
  local folder=project_log_folder(info)
  show_input(
    "Clean Up Logs",
    "Choose an age threshold. The app will scan finalized attempt logs, show the number and approximate size that qualify, and ask for final confirmation. BUILD HISTORY.csv is retained.",
    "Delete finalized logs older than this many days:","90",
    function(value)
      local days=tonumber(trim(value));if not days or days<1 or days~=math.floor(days) then return false,"Enter a positive whole number of days." end
      return true
    end,
    function(value)
      local days=tonumber(trim(value))
      state.operation_busy=true;set_status("Scanning logs older than "..days.." days...","info");gfx.update()
      local text_result,err=run_powershell_text(PS_OLD_LOGS,{{name="Folder",value=folder},{name="Days",value=tostring(days)}},60000)
      state.operation_busy=false
      if not text_result then show_info("Log Cleanup Scan Failed",err,"error");return end
      local files,total_size={},0
      for line in (text_result.."\n"):gmatch("(.-)\r?\n") do if line~="" then local b64,size=line:match("^(.-)\t(%d+)$");if b64 then local path=base64_decode(b64);files[#files+1]=path;total_size=total_size+(tonumber(size) or 0) end end end
      if #files==0 then show_info("Clean Up Logs","No finalized logfiles are older than "..days.." days.","info");return end
      show_confirm(
        "Clean Up Logs",
        string.format("%d finalized logfile%s qualify for deletion.\n\nApproximate size: %.2f MB\n\nBUILD HISTORY.csv will be retained and affected entries will be marked unavailable.\n\nDelete these files?",#files,#files==1 and "" or "s",total_size/1048576),
        "Delete Logs","Cancel",
        function()
          local deleted,failed=0,0;local deleted_names={}
          for _,path in ipairs(files) do if os.remove(path) then deleted=deleted+1;deleted_names[basename(path)]=true else failed=failed+1 end end
          local all=load_history(folder,nil);for _,e in ipairs(all) do if deleted_names[e.log_filename] then e.available=false end end;save_history(folder,all)
          refresh_attempt_history(state);set_status(string.format("Log cleanup complete: %d deleted, %d failed.",deleted,failed),failed==0 and "success" or "error")
          show_info("Log Cleanup Complete",string.format("Deleted: %d\nFailed: %d",deleted,failed),failed==0 and "success" or "warning")
        end,nil,"warning"
      )
    end
  )
end

local PS_ZIP_FOLDER=[=[
param([string]$OutputPath,[string]$SourceFolder,[string]$ZipPath)
$ErrorActionPreference='Stop';$e=New-Object Text.UTF8Encoding($false)
try{if(Test-Path -LiteralPath $ZipPath){Remove-Item -LiteralPath $ZipPath -Force};Compress-Archive -Path (Join-Path $SourceFolder '*') -DestinationPath $ZipPath -CompressionLevel Optimal;[IO.File]::WriteAllText($OutputPath,'OK',$e)}catch{[IO.File]::WriteAllText($OutputPath,('ERROR'+"`t"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))),$e);exit 1}
]=]

function create_support_bundle()
  if state.operation_busy or state.app_modal or state.confirm_modal or state.comparison_open then return end
  local info=get_active_project_info();if not project_is_saved(info) then show_info("Create Support Bundle","Save the active REAPER project as an .RPP first so its support/log folder is known.","warning");return end
  local folder=project_log_folder(info);ensure_directory(folder)
  local selected=selected_history_entry();local log_path=state.current_log_path
  if selected and selected.available then log_path=path_join(folder,selected.log_filename) end
  local token=state.current_attempt and state.current_attempt.safe_id or os.date("%m-%d-%Y_%I-%M-%S_%p")
  local zip_path,dlg_err=choose_save_path("Create Support Bundle","ZIP archives (*.zip)|*.zip|All files (*.*)|*.*","SSB_SUPPORT_"..sanitize_filename(token)..".zip",folder)
  if not zip_path then if dlg_err~="CANCELLED" then show_info("Support Bundle Failed",dlg_err,"error") end;return end
  local temp=make_temp_path("_support");local ok,err=ensure_directory(temp);if not ok then show_info("Support Bundle Failed",err,"error");return end
  local diagnostic={SCRIPT_NAME,"Made by "..MADE_BY,"Created: "..make_attempt_id().timestamp,"REAPER version: "..tostring(reaper.GetAppVersion()),"OS: "..tostring(reaper.GetOS()),"Project: "..info.path,"Project tab: "..info.tab_index,"Environment ready: "..tostring(state.environment_ok),"Build status: "..state.build_status,"Log status: "..state.log_status,"","Dry run:",project_snapshot_text(state.dry_run)}
  write_file(path_join(temp,"DIAGNOSTICS.txt"),table.concat(diagnostic,"\r\n"))
  if state.plan then write_file(path_join(temp,"NORMALIZED PLAN.txt"),state.plan.normalized_text.."\r\n\r\nSource SHA-256: "..state.plan.source_sha256.."\r\nPlan SHA-256: "..state.plan.plan_sha256.."\r\n") end
  if log_path and file_exists(log_path) then local txt=read_file(log_path);if txt then write_file(path_join(temp,basename(log_path)),txt) end end
  local idx=history_index_path(folder);if file_exists(idx) then local txt=read_file(idx);if txt then write_file(path_join(temp,"BUILD HISTORY.csv"),txt) end end
  write_file(path_join(temp,"README.txt"),"This support bundle intentionally excludes the workbook and REAPER .RPP project.\r\n")
  local result,zip_err=run_powershell_text(PS_ZIP_FOLDER,{{name="SourceFolder",value=temp},{name="ZipPath",value=zip_path}},120000)
  reaper.ExecProcess('cmd.exe /C rmdir /S /Q '..command_quote(temp),30000)
  if result=="OK" then
    local opened,open_err=shell_open(dirname(zip_path))
    if opened then set_status("Support bundle created: "..zip_path,"success")
    else show_info("Support Bundle Created","The ZIP was created successfully, but its folder could not be opened.\n\n"..zip_path.."\n\n"..tostring(open_err),"warning") end
  else show_info("Support Bundle Failed","Support bundle failed: "..tostring(zip_err),"error") end
end

function reset_column_widths()
  state.column_widths={};for i,v in ipairs(DEFAULT_COLUMNS) do state.column_widths[i]=v end
  state.preview_hscroll=0;if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(state.column_widths),true) end;set_status("Preview column widths restored.","success")
end

function reset_app_preferences(force)
  if not force and not tempo_edits_empty(state.tempo_edits) then confirm_discard_staged_edits("Resetting app preferences","Reset and Discard Edits",function()reset_app_preferences(true)end);return end
  show_confirm(
    "Reset App Preferences",
    "Reset recent files, column widths, saved window layout, filters, and other app preferences?\n\nThis does not delete logs or modify the project.",
    "Reset Preferences","Cancel",
    function()
      if state.audition_active then restore_audition_state() end
      intentionally_discard_tempo_recovery()
      for _,key in ipairs({"preferences_schema","last_file","recent_files","column_widths","preview_hscroll","preview_density","window_w","window_h","window_x","window_y","active_view","history_filter","history_song","history_notes_search","history_id_search","history_date_from","history_date_to","history_panel_height","side_panel_height","remember_layout","remember_column_widths","remember_hscroll","alternating_rows","highlight_changed_rows","section_emphasis","show_syntax_badges","show_row_explanations","remember_history_filters","remember_last_page","remember_window","remember_panels","show_detailed_errors","show_hashes","show_full_path","developer_mode","larger_text","click_a_hz","click_b_hz"}) do reaper.DeleteExtState(EXTSTATE_SECTION,key,true) end
      clear_session(true);state.recent_files={};state.history_filter="ALL";state.history_panel_height=300;state.side_panel_height=0;state.click_a_hz=DEFAULT_CLICK_A_HZ;state.click_b_hz=DEFAULT_CLICK_B_HZ;state.remember_layout=true;reset_column_widths();state.reinit_requested=true;set_status("App preferences reset.","success")
    end,nil,"warning"
  )
end

local UI={
  default_w=1480,default_h=880,margin=16,row_height=26,header_height=30,
  side_width=390,nav_width=168,status_height=54,header_bar_height=72,
  font_name="Segoe UI",mono_font_name="Consolas",
  colors={
    canvas={15,19,24},sidebar={18,23,29},header={15,19,24},card={23,29,36},
    card_border={53,65,78},divider={49,61,73},text={231,236,242},muted={155,166,178},
    button={32,40,49},button_hover={40,51,63},button_border={67,81,96},
    primary={47,143,234},primary_hover={57,155,239},accent={47,143,234},
    table_header={34,42,51},table_body={20,26,32},row={23,29,36},row_alt={26,33,41},
    row_hover={33,43,53},row_selected={31,55,78},scroll_track={31,39,48},scroll_thumb={91,105,119},
    good={104,196,76},warning={220,168,72},bad={226,102,102},status_bar={18,24,30}
  }
}

function responsive_layout(window_w,window_h)
  local w=math.max(1,tonumber(window_w) or UI.default_w)
  local h=math.max(1,tonumber(window_h) or UI.default_h)
  local narrow=w<1320;local very_narrow=w<1100;local short=h<850;local large_text=state and state.larger_text==true
  local roomy_accessibility=large_text and h>=800
  return {
    compact=narrow or short,
    nav_width=large_text and (very_narrow and 158 or narrow and 172 or 190) or (very_narrow and 126 or narrow and 146 or UI.nav_width),
    body_margin=very_narrow and 10 or narrow and 14 or w>1900 and 24 or 20,
    header_bar_height=(short and 64 or UI.header_bar_height)+(large_text and (roomy_accessibility and 18 or 8) or 0),
    body_y=(short and 74 or 84)+(large_text and (roomy_accessibility and 18 or 4) or 0),
    status_height=(short and 48 or UI.status_height)+(large_text and (roomy_accessibility and 26 or 10) or 0),
    body_bottom=(large_text and not roomy_accessibility) and 6 or short and 10 or 16,
    card_gap=short and 8 or 12,
    workbook_h=(short and 104 or 116)+(large_text and (roomy_accessibility and 34 or 14) or 0),
    bottom_h=(large_text and not roomy_accessibility) and 190 or (short and (large_text and 226 or 228) or (large_text and 286 or 288)),
    preview_table_top=(short and 54 or 60)+(large_text and (roomy_accessibility and 30 or 12) or 0),
    workbook_controls_y=large_text and (short and 76 or 84) or (short and 56 or 62),
    action_note_y=large_text and not roomy_accessibility and 34 or short and 40 or 58,
    action_major_y=large_text and not roomy_accessibility and 64 or short and 68 or 100,
    action_major_h=large_text and not roomy_accessibility and 32 or short and 38 or 50,
    action_small_y=large_text and not roomy_accessibility and 100 or short and 112 or 160,
    action_small_h=large_text and not roomy_accessibility and 26 or short and 28 or 34,
    action_export_y=large_text and not roomy_accessibility and 130 or short and 146 or 202,
    action_export_h=large_text and not roomy_accessibility and 26 or short and 28 or 34,
    action_edit_y=large_text and not roomy_accessibility and 160 or short and 180 or (large_text and 244 or 240),
    action_edit_h=large_text and not roomy_accessibility and 26 or short and 28 or 34,
    readiness_y=large_text and not roomy_accessibility and 36 or short and 48 or 72,
    readiness_gap=large_text and not roomy_accessibility and 27 or short and 30 or 40
  }
end

function settings_grid_metrics(card_h,larger_text)
  local compact=(tonumber(card_h) or 0)<260
  if larger_text then
    if compact then return {compact=true,dense_header=true,row_start=34,row_step=32,button_h=30} end
    return {compact=false,dense_header=true,row_start=48,row_step=47,button_h=40}
  end
  return {compact=compact,dense_header=false,row_start=54,row_step=compact and 31 or 40,button_h=compact and 27 or 32}
end

function app_modal_geometry(window_w,window_h,larger_text)
  local margin=larger_text and 24 or 40
  local max_w=larger_text and 920 or 760
  local max_h=larger_text and 700 or 600
  -- At the smallest Windows client height, Larger Text forms need the status
  -- bar's space more than the obscured background does. The modal remains
  -- inside the app window and still blocks all click-through.
  local status_reserve=larger_text and (tonumber(window_h) or max_h)<680 and 0 or responsive_layout(window_w,window_h).status_height
  local w=math.max(320,math.min(max_w,(tonumber(window_w) or max_w)-margin*2))
  local h=math.max(300,math.min(max_h,(tonumber(window_h) or max_h)-status_reserve-margin*2))
  return w,h
end

function confirmation_modal_geometry(window_w,window_h,larger_text)
  local margin=larger_text and 24 or 20
  local max_w=larger_text and 920 or 760
  local max_h=larger_text and 700 or 640
  local min_w=math.min(larger_text and 640 or 560,(tonumber(window_w) or max_w)-margin*2)
  local min_h=math.min(larger_text and 500 or 460,(tonumber(window_h) or max_h)-margin*2)
  local w=math.max(320,math.min(max_w,math.max(min_w,(tonumber(window_w) or max_w)-margin*2)))
  local h=math.max(320,math.min(max_h,math.max(min_h,(tonumber(window_h) or max_h)-margin*2)))
  return w,h
end

function calendar_modal_geometry(window_w,window_h,larger_text)
  local margin=larger_text and 24 or 40
  local max_w=larger_text and 540 or 470
  local max_h=larger_text and 550 or 400
  return math.max(320,math.min(max_w,(tonumber(window_w) or max_w)-margin*2)),math.max(360,math.min(max_h,(tonumber(window_h) or max_h)-margin*2))
end

function preview_footer_layout(preview_y,preview_h,table_y,hint_line_count,larger_text)
  local line_count=math.max(1,math.floor(tonumber(hint_line_count) or 1))
  -- Base compact accessibility spacing on the pane being laid out. Using the
  -- live gfx window here made tests of a hypothetical minimum-size pane depend
  -- on whichever window size happened to be open when Parser Self-Test ran.
  local compact_accessibility=larger_text and (tonumber(preview_h) or 0)<320
  local line_h=larger_text and (compact_accessibility and 20 or 28) or 19
  local pad_top=compact_accessibility and 5 or 8
  local pad_bottom=compact_accessibility and 4 or 6
  local controls_h=larger_text and (compact_accessibility and 34 or 46) or 34
  local control_gap=compact_accessibility and 4 or 6
  local footer_h=pad_top+controls_h+control_gap+line_count*line_h+pad_bottom
  local footer_top=preview_y+preview_h-footer_h
  local table_gap=compact_accessibility and 4 or 10
  return {
    footer_top=footer_top,
    footer_h=footer_h,
    controls_y=footer_top+pad_top,
    controls_h=controls_h,
    hint_y=footer_top+pad_top+controls_h+control_gap,
    line_h=line_h,
    table_gap=table_gap,
    table_h=math.max(compact_accessibility and 24 or 32,footer_top-table_y-table_gap)
  }
end

function ui_visual_regression_snapshot(name,window_w,window_h,larger_text)
  local saved_larger=state.larger_text;state.larger_text=larger_text==true
  local layout=responsive_layout(window_w,window_h)
  local body_h=window_h-layout.body_y-layout.status_height-layout.body_bottom
  local content_w=window_w-layout.nav_width-layout.body_margin*2
  local preview_h=body_h-layout.workbook_h-layout.bottom_h-layout.card_gap*2
  local footer=preview_footer_layout(0,preview_h,layout.preview_table_top,2,larger_text==true)
  local settings_top=larger_text and 76 or 62;local settings_gap=16
  local settings_card_h=math.floor((body_h-settings_top-16-settings_gap)/2)
  local settings_metrics=settings_grid_metrics(settings_card_h,larger_text==true)
  local settings_last_bottom=settings_metrics.row_start+4*settings_metrics.row_step+settings_metrics.button_h
  local settings_terse=larger_text and settings_metrics.compact
  local settings_info_y=settings_metrics.row_start+3*settings_metrics.row_step+3
  local settings_logging_bottom=settings_info_y+(settings_terse and 25 or settings_metrics.compact and 40 or 50)+(settings_terse and 20 or 17)
  local help_top=larger_text and 78 or 58;local help_inner_w=content_w-32;local help_inner_h=body_h-help_top-16;local help_gap=12
  local help_branch,help_scratch_h,help_guide_h
  if larger_text and help_inner_w>=700 then
    help_branch="SPLIT";help_scratch_h=help_inner_h;help_guide_h=help_inner_h
  elseif content_w>=1200 then
    help_branch="WIDE";help_scratch_h=math.max(270,math.min(340,math.floor(help_inner_h*0.46)));help_guide_h=help_inner_h-help_scratch_h-help_gap
  else
    help_branch="STACK";help_scratch_h=math.max(280,math.min(420,math.floor(help_inner_h*0.58)));help_guide_h=help_inner_h-help_scratch_h-help_gap
  end
  local help_scratch_w=help_branch=="SPLIT" and math.floor((help_inner_w-help_gap)/2) or help_inner_w
  local help_guide_w=help_branch=="SPLIT" and (help_inner_w-help_scratch_w-help_gap) or help_inner_w
  local scratch_side_by_side=help_scratch_w>=700
  local scratch_constrained=larger_text and not scratch_side_by_side and help_scratch_h<520
  local scratch_input_y=larger_text and 76 or 55
  local scratch_gap=scratch_constrained and 4 or larger_text and 9 or 7
  local scratch_button_y=scratch_input_y+(scratch_constrained and 128 or larger_text and 142 or 100)
  local scratch_button_h=scratch_constrained and 28 or larger_text and 44 or 31
  local help_scratch_result_h=scratch_side_by_side and (help_scratch_h-scratch_input_y-16) or (help_scratch_h-(scratch_button_y+(scratch_button_h+scratch_gap)*4+3)-12)
  local help_guide_footer_h=larger_text and help_guide_w<650 and 150 or larger_text and 66 or 54
  local help_guide_viewport_h=help_guide_h-(larger_text and 78 or 56)-help_guide_footer_h
  local app_w,app_h=app_modal_geometry(window_w,window_h,larger_text==true)
  local confirm_w,confirm_h=confirmation_modal_geometry(window_w,window_h,larger_text==true)
  local calendar_w,calendar_h=calendar_modal_geometry(window_w,window_h,larger_text==true)
  local modal_header=larger_text and 64 or 58;local modal_buttons=34+(larger_text and 56 or 44)
  local modal_inputs=3*(larger_text and 68 or 58)+12+(larger_text and 54 or 42)
  local modal_errors=3*(larger_text and 24 or 16)+10
  local modal_body=app_h-modal_header-modal_buttons-modal_inputs-modal_errors
  local build_left_w=math.floor((content_w-layout.card_gap)*0.56);local build_inner_w=build_left_w-36
  local compact_action=layout.compact
  local compact_side_w=larger_text and 112 or 120
  local side_button_w=compact_action and math.min(compact_side_w,math.floor((build_inner_w-24)/3)) or math.min(150,math.floor(build_inner_w*0.24))
  local audio_mode_button_w=build_inner_w-side_button_w*2-24
  local workbook_gap=layout.compact and 7 or 10
  local controls_available=content_w-36-workbook_gap*4
  local workbook_widths={math.max(78,math.floor(controls_available*0.12)),math.max(100,math.floor(controls_available*0.15)),math.max(112,math.floor(controls_available*0.17)),math.max(160,math.floor(controls_available*0.24))}
  workbook_widths[5]=math.max(150,controls_available-workbook_widths[1]-workbook_widths[2]-workbook_widths[3]-workbook_widths[4])
  local workbook_controls_used=workbook_widths[1]+workbook_widths[2]+workbook_widths[3]+workbook_widths[4]+workbook_widths[5]+workbook_gap*4
  local project_compare_label=larger_text and layout.compact and "Project Match" or layout.compact and "Compare Open Project" or "Validate Against Open Project"
  local reconstruct_label=larger_text and layout.compact and "Create Workbook" or layout.compact and "Create From Project..." or "Create Verified Workbook From Open Project..."
  local build_width=math.floor(build_inner_w*0.58);local undo_width=build_inner_w-build_width-12
  local edit_width=math.floor((build_inner_w-8)/2)
  local export_label=larger_text and layout.compact and "Export MIDI + MP3..." or "Export MIDI + MP3 Click..."
  local workbook_font=layout.compact and 12 or 14
  local primary_font=layout.action_major_h<46 and 15 or 18
  local save_copy_label=larger_text and layout.compact and "Save Workbook Copy" or "Save Updated Workbook Copy"
  local button_labels_fit=
    fit_text(project_compare_label,math.max(8,workbook_widths[4]-16),workbook_font,true)==project_compare_label
    and fit_text(reconstruct_label,math.max(8,workbook_widths[5]-16),workbook_font,true)==reconstruct_label
    and fit_text("Build Click Track Map",math.max(8,build_width-18),primary_font,true)=="Build Click Track Map"
    and fit_text("Undo Last Build",math.max(8,undo_width-16),12,true)=="Undo Last Build"
    and fit_text("Open User-Friendly Song Structure...",math.max(8,build_inner_w-16),14,true)=="Open User-Friendly Song Structure..."
    and fit_text(export_label,math.max(8,build_inner_w-16),14,true)==export_label
    and fit_text("Revert Tempo Edit",math.max(8,edit_width-16),12,true)=="Revert Tempo Edit"
    and fit_text(save_copy_label,math.max(8,build_inner_w-edit_width-8-16),12,true)==save_copy_label
  state.larger_text=saved_larger
  local snapshot={name=name,w=window_w,h=window_h,larger=larger_text==true,layout=layout,body_h=body_h,content_w=content_w,preview_h=preview_h,footer=footer,settings_card_h=settings_card_h,settings_last_bottom=settings_last_bottom,settings_logging_bottom=settings_logging_bottom,help_branch=help_branch,help_inner_h=help_inner_h,help_scratch_h=help_scratch_h,help_guide_h=help_guide_h,help_scratch_result_h=help_scratch_result_h,help_guide_viewport_h=help_guide_viewport_h,history_panel_h=body_h-(larger_text and 76 or 58)-16,app_w=app_w,app_h=app_h,confirm_w=confirm_w,confirm_h=confirm_h,calendar_w=calendar_w,calendar_h=calendar_h,modal_body=modal_body,audio_mode_button_w=audio_mode_button_w,workbook_controls_used=workbook_controls_used,button_labels_fit=button_labels_fit}
  snapshot.signature=table.concat({layout.nav_width,body_h,content_w,preview_h,settings_card_h,settings_last_bottom,help_inner_h,help_scratch_h,help_guide_h,app_w,app_h,confirm_w,confirm_h,calendar_w,calendar_h,footer.table_h,layout.action_export_y,layout.action_export_h,layout.action_edit_y,layout.action_edit_h,help_branch},"/")
  snapshot.inside=body_h>0 and content_w>0 and preview_h>=180
    and layout.preview_table_top+footer.table_h+footer.table_gap<=footer.footer_top
    and footer.hint_y+2*footer.line_h<=preview_h
    and settings_card_h>0 and settings_last_bottom<=settings_card_h and settings_logging_bottom<=settings_card_h
    and snapshot.history_panel_h>=240 and help_scratch_h>=270 and help_guide_h>=160
    and help_scratch_result_h>=(larger_text and 58 or 42) and help_guide_viewport_h>=60
    and app_w<=window_w and app_h<=window_h and confirm_w<=window_w and confirm_h<=window_h and calendar_w<=window_w and calendar_h<=window_h
    and modal_body>=64 and audio_mode_button_w>=150 and workbook_controls_used<=content_w-36 and button_labels_fit
    and layout.action_note_y+(layout.compact and 28 or 32)<=layout.action_major_y
    and layout.action_major_y+layout.action_major_h<=layout.action_small_y
    and layout.action_small_y+layout.action_small_h<=layout.action_export_y
    and layout.action_export_y+layout.action_export_h<=layout.action_edit_y
    and layout.action_edit_y+layout.action_edit_h<=layout.bottom_h
  return snapshot
end

function run_ui_visual_regression_matrix()
  local profiles={
    {"compact",980,680,false,"126/548/834/200/227/205/474/280/182/760/552/760/640/470/400/44/146/28/180/28/STACK"},
    {"standard",1480,880,false,"168/726/1272/298/316/246/652/299/341/760/600/760/640/470/400/136/202/34/240/34/WIDE"},
    {"wide",2200,1200,false,"168/1046/1984/618/476/246/972/340/620/760/600/760/640/470/400/456/202/34/240/34/WIDE"},
    {"larger-text-compact",980,680,true,"158/538/802/214/215/192/444/444/444/920/574/920/632/540/550/57/130/26/160/26/SPLIT"},
    {"client-border-compact",964,649,true,"158/507/786/183/199/192/413/413/413/916/601/916/601/540/550/26/130/26/160/26/SPLIT"},
    {"wide-short",1600,680,false,"168/548/1392/200/227/205/474/270/192/760/552/760/640/470/400/44/146/28/180/28/WIDE"},
    {"larger-text-wide-short",1600,680,true,"190/538/1370/214/215/192/444/444/444/920/574/920/632/540/550/57/130/26/160/26/SPLIT"}
  }
  local snapshots,failures={},{}
  for _,profile in ipairs(profiles) do
    local snapshot=ui_visual_regression_snapshot(profile[1],profile[2],profile[3],profile[4]);snapshots[#snapshots+1]=snapshot
    if not snapshot.inside then failures[#failures+1]=profile[1].." has a pane, footer, Settings grid, Help split, or modal outside its responsive boundary" end
    if profile[5] and snapshot.signature~=profile[5] then failures[#failures+1]=profile[1].." geometry changed: expected "..profile[5]..", got "..snapshot.signature end
  end
  return #failures==0,failures,snapshots
end

function scaled_font_size(size)
  local value=tonumber(size) or 13
  if state and state.larger_text then return math.floor(math.max(value+ACCESSIBILITY_FONT_ADD,value*ACCESSIBILITY_FONT_SCALE)+0.5) end
  return value
end

function set_color(r,g,b,a)
  if false then
    r=math.floor(255-(255-r)*0.30);g=math.floor(255-(255-g)*0.30);b=math.floor(255-(255-b)*0.30)
  end
  gfx.set(r/255,g/255,b/255,a or 1)
end
function set_ui_color(name,a)
  local c=UI.colors[name] or UI.colors.text
  set_color(c[1],c[2],c[3],a)
end
function draw_text(text,x,y,size,bold)
  gfx.setfont(1,UI.font_name,scaled_font_size(size or 14),bold and 98 or 0);gfx.x=x;gfx.y=y;gfx.drawstr(tostring(text or ""))
end
function draw_mono_text(text,x,y,size,bold)
  gfx.setfont(2,UI.mono_font_name,scaled_font_size(size or 13),bold and 98 or 0);gfx.x=x;gfx.y=y;gfx.drawstr(tostring(text or ""))
end
function point_inside(x,y,w,h) return gfx.mouse_x>=x and gfx.mouse_x<=x+w and gfx.mouse_y>=y and gfx.mouse_y<=y+h end
function consume_button_activation(enabled,hover,clicked)
  local activated=enabled and hover and clicked and not state.action_consumed_this_frame and not state.press_consumed
  if activated then
    -- One physical mouse press has one owner and may activate exactly one control.
    -- The ownership is retained until release even if the control closes one modal
    -- and exposes another window underneath it.
    state.action_consumed_this_frame=true
    state.press_consumed=true
    state.suppress_click_until_release=true
  end
  return activated
end

function begin_focus_frame(enabled)
  state.base_focus_enabled=enabled==true;state.focus_next={};state.focus_draw_index=0
end

function register_focus_control(label,enabled)
  if not state.base_focus_enabled then return false,false,nil end
  state.focus_draw_index=state.focus_draw_index+1
  local index=state.focus_draw_index
  local control_label=tostring(label or "Control")
  state.focus_next[index]={label=control_label,enabled=enabled==true}
  local focused=state.focus_index==index
  local keyboard_activate=enabled and state.keyboard_activate_index==index and state.keyboard_activate_label==control_label
  if state.keyboard_activate_index==index then state.keyboard_activate_index=nil;state.keyboard_activate_label=nil end
  return focused,keyboard_activate,index
end

function finish_focus_frame()
  state.focus_controls=state.focus_next or {};state.focus_view=state.active_view
  if state.focus_index and (not state.focus_controls[state.focus_index] or not state.focus_controls[state.focus_index].enabled) then state.focus_index=nil end
  state.keyboard_activate_index=nil;state.keyboard_activate_label=nil
end

function next_enabled_focus(controls,current,direction)
  controls=controls or {};direction=direction and direction<0 and -1 or 1
  if #controls==0 then return nil end
  local index=current
  if not index then index=direction>0 and 0 or (#controls+1) end
  for _=1,#controls do
    index=((index-1+direction)%#controls)+1
    if controls[index] and controls[index].enabled then return index end
  end
  return nil
end

function draw_focus_outline(x,y,w,h,focused)
  if not focused then return end
  set_color(118,190,245);gfx.rect(x-2,y-2,w+4,h+4,false)
  set_color(198,229,252,0.72);gfx.rect(x-1,y-1,w+2,h+2,false)
end

function set_preview_selection(index,extend)
  index=tonumber(index);local rows=preview_display_rows();if not index or not rows[index] then return end
  if extend then
    local anchor=state.preview_selection_anchor or state.selected_preview_row or index
    state.preview_selection_anchor=anchor
    state.preview_selection_start=math.min(anchor,index)
    state.preview_selection_end=math.max(anchor,index)
  else
    state.preview_selection_anchor=index
    state.preview_selection_start=index
    state.preview_selection_end=index
  end
  state.selected_preview_row=index
  if state.audition_active and state.audition_restore then
    local start_time=audition_time_range(state.audition_restore.proj)
    if start_time then state.audition_restore.selection_start=start_time end
  end
end

function handle_preview_table_keyboard(key,shift)
  if state.active_view~="BUILD" or not state.focus_index then return false end
  local control=state.focus_controls and state.focus_controls[state.focus_index]
  if not control or control.label~="Validated Preview rows" then return false end
  local rows=preview_display_rows()
  if #rows==0 then return false end
  if key==TEXT_KEYS.UP or key==TEXT_KEYS.DOWN or key==TEXT_KEYS.HOME or key==TEXT_KEYS.END_KEY then
    local current=tonumber(state.selected_preview_row)
    if key==TEXT_KEYS.HOME then current=1
    elseif key==TEXT_KEYS.END_KEY then current=#rows
    elseif not current then current=key==TEXT_KEYS.DOWN and 1 or #rows
    else current=math.max(1,math.min(#rows,current+(key==TEXT_KEYS.DOWN and 1 or -1))) end
    set_preview_selection(current,shift and (key==TEXT_KEYS.UP or key==TEXT_KEYS.DOWN))
    local bounds=state.preview_table_bounds or {};local visible=math.max(1,tonumber(bounds.visible_rows) or 1)
    if current<=state.preview_vscroll then state.preview_vscroll=current-1
    elseif current>state.preview_vscroll+visible then state.preview_vscroll=current-visible end
    local blurb=preview_row_blurb(rows[current]);if blurb then set_status(blurb,"info") end
    return true
  end
  local row=state.selected_preview_row and rows[state.selected_preview_row] or nil
  if (key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE or (shift and key==TEXT_KEYS.F10)) and row then
    local bounds=state.preview_table_bounds or {}
    open_row_popover(state.selected_preview_row,row,(bounds.x or gfx.w/2)+(bounds.w or 0)*0.55,(bounds.y or gfx.h/2)+42)
    return true
  end
  return false
end

function handle_base_keyboard(key,locked)
  if not key or key==0 or locked then return false end
  local ctrl=(gfx.mouse_cap&4)==4;local shift=(gfx.mouse_cap&8)==8
  if key==TEXT_KEYS.F1 then state.active_view="HELP";state.focus_index=nil;set_status("Opened Help. F1 is available throughout the app.","info");return true end
  if ctrl and key==TEXT_KEYS.CTRL_O then run_base_action(choose_file);return true end
  if ctrl and key==TEXT_KEYS.CTRL_F then state.active_view="HELP";run_base_action(show_error_reference_search);return true end
  if state.focus_view~=state.active_view then state.focus_index=nil end
  if handle_preview_table_keyboard(key,shift) then return true end
  if key==TEXT_KEYS.TAB then
    state.focus_index=next_enabled_focus(state.focus_controls,state.focus_index,shift and -1 or 1)
    if state.focus_index and state.focus_controls[state.focus_index] then state.hover_context="Keyboard focus: "..state.focus_controls[state.focus_index].label..". Press Enter or Space to activate." end
    return true
  end
  if (key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE) and state.focus_index then
    local control=state.focus_controls[state.focus_index]
    if control and control.enabled then state.keyboard_activate_index=state.focus_index;state.keyboard_activate_label=control.label;return true end
  end
  return false
end

BUTTON_HELP={
  ["Browse..."]="Choose a saved XLSX or CSV workbook. The app uses REAPER's current filtered chooser when available and its compatible legacy chooser on older installations. If staged tempo edits exist, their exact Section/Part scope is confirmed before they and their recovery copy can be discarded.",
  ["Browse"]="Choose a saved XLSX or CSV workbook; this shortened label is used only in a compact Larger Text window.",
  ["Recent Files..."]="Choose from recently opened workbooks. Staged tempo edits remain protected by the discard confirmation.",
  ["Recent..."]="Choose from recently opened workbooks; this shortened label is used only in a compact window.",
  ["Recent"]="Choose from recently opened workbooks; this shortest label is used only in a compact Larger Text window.",
  ["Validate Only"]="Read, hash, and validate the workbook without changing REAPER. Reloading over staged edits requires confirmation; a fingerprint-matched recovery record is offered after validation.",
  ["Validate"]="Read, hash, and validate the workbook without changing REAPER; this shortened label is used only in a compact Larger Text window.",
  ["Validate Against Open Project"]="Read-only comparison of the current validated workbook with the active REAPER project: markers, Part starts, meters, calculated REAPER BPM, click accents, Ramps, COUNT IN, END, and unexpected extra events.",
  ["Compare Open Project"]="Read-only comparison of the current validated workbook with the active REAPER project. This shorter label is used in compact windows.",
  ["Project Match"]="Read-only comparison of the current validated workbook with the active REAPER project. This shortest label is used in compact Larger Text windows.",
  ["Validation Issues"]="Review every workbook validation issue with its source row and Error Reference code.",
  ["Create Verified Workbook From Open Project..."]="Read the active REAPER project's COUNT IN, END, exact Section-marker names, meters, tempos, click patterns, and ramps; conservatively infer compact Parts, repeats, tuplets, and Blocks; then offer XLSX or CSV only after a one-for-one production-parser verification.",
  ["Create From Project..."]="Create a verified workbook from the active REAPER project; this shorter label is used only in a compact window.",
  ["Create Workbook"]="Create a verified workbook from the active REAPER project; this shortest label is used only in a compact Larger Text window.",
  ["All Validation Issues"]="Review every workbook validation issue with its source row and Error Reference code.",
  ["Copy Corrected Cell"]="Confirm and copy an exact high-confidence replacement. The workbook is never edited automatically.",
  ["Explain Error"]="Open the complete wrapped validation explanation and its relevant actions.",
  ["Copy Error Code"]="Copy the selected issue's Error Reference code for searching or support.",
  ["Copy Syntax"]="Copy the selected Preview row's Part syntax, or all Shift-selected Part rows as one comma-separated expression in top-to-bottom order; Block wrappers and parser-added pass labels are omitted.",
  ["Search Error Reference"]="Open the matching Error Reference entry directly, or search the catalog when no issue is selected.",
  ["Open Workbook"]="Open the currently selected workbook in its associated spreadsheet application; on a validation issue, use the reported row to locate the source cell.",
  ["Workbook"]="Open the currently selected workbook in its associated spreadsheet application; this shortened label is used only when Larger Text needs a compact window.",
  ["Build Notes..."]="Attach a note to the next build attempt and its logfile.",
  ["Notes..."]="Attach a note to the next build attempt and its logfile; this shortened label is used only when Larger Text needs a compact window.",
  ["Audio: Preserve"]="Review audio handling for the next build. Preserve Audio Exactly keeps every detected audio item's absolute placement, length, rate, pitch, timebase, fades, and stretch markers unchanged.",
  ["Audio: Conform"]="Review audio handling for the next build. Eligible audio follows the same musical counts at the new tempo using pitch-preserving rate stretch; structural mismatches block this mode.",
  ["Preserve Audio Exactly"]="Keep detected audio items exactly unchanged while rebuilding the click map and verify the complete pre-build audio signature.",
  ["Conform Audio — Preserve Pitch"]="Keep eligible audio on the same musical counts at the new tempo without changing pitch. This requires exact marker, count, meter, Repeat/Block, and Ramp-structure agreement.",
  ["Conform + Preserve Pitch"]="Keep eligible audio on the same musical counts at the new tempo without changing pitch. This requires exact marker, count, meter, Repeat/Block, and Ramp-structure agreement.",
  ["Build Click Track Map"]="Create a normally accented two-bar 4/4 COUNT IN at measure 1, then rebuild and verify spreadsheet-driven markers, tempo, Section click patterns, and A/B frequencies from measure 3 onward.",
  ["Apply & Verify Tempo Edits"]="Build the staged Section, Part, and END tempo changes into the active REAPER project, then verify the exact result.",
  ["Edit Section BPM..."]="Stage a new underlying Section BPM; inherited Parts recalculate, while explicit @BPM overrides remain fixed unless the context checkbox is selected.",
  ["Edit First Section BPM..."]="Stage the first Section BPM; the automatic COUNT IN follows it and retains its accented first beat.",
  ["Edit Part BPM..."]="Stage a new underlying BPM for this source Part; all repeats and Block passes generated from that source update together.",
  ["Edit END BPM..."]="Stage the END tempo used by a legal final Ramp; blank restores the standard 25 BPM END behavior.",
  ["Send to Scratchpad"]="Send the highlighted playable Preview rows to Help's Syntax Scratchpad in order, with explicit underlying BPM values, validate them, and wait for Play Preview.",
  ["Undo Last Build"]="Undo the most recent successful build made during this app session.",
  ["Open User-Friendly Song Structure..."]="Open the musician-facing full or Simplified Song Structure with measure, BPM, and Generic Part Names toggles, durations, export, and print.",
  ["Export MIDI + MP3 Click..."]="Create a synchronized type-1 MIDI tempo/meter/click file and audible MP3 from the complete validated plan. MIDI marker metadata follows the current Generic Part Names toggle; both files include COUNT IN and stop at END without an extra beat.",
  ["Export MIDI + MP3..."]="Create a synchronized type-1 MIDI and MP3 click package. MIDI markers follow Generic Part Names; this shortened label is used only in a compact Larger Text pane.",
  ["Revert Tempo Edit"]="Restore the selected yellow Preview row or rows to their currently loaded workbook tempos. Repeated/Block occurrences and any necessary Section-wide effects are confirmed first; accent behavior cannot change.",
  ["Save Updated Workbook Copy"]="After the exact staged plan is built and verified, save and revalidate a new XLSX or CSV copy while leaving the source workbook untouched.",
  ["Save Updated Workbook"]="After the exact staged plan is built and verified, save, revalidate, and adopt a new XLSX or CSV copy as the current clean workbook baseline.",
  ["Save Workbook Copy"]="After the exact staged plan is built and verified, save, revalidate, and adopt a new XLSX or CSV copy as the current clean workbook baseline.",
  ["Jump to Part"]="Move REAPER's edit cursor to the selected part start.",
  ["Jump to END"]="Move REAPER's edit cursor to the standard project marker named END.",
  ["Jump to Ramp"]="Move REAPER's edit cursor to the first bar of the selected active ramp.",
  ["Filter"]="Search Attempt History by Build Notes, Build ID, and inclusive date range.",
  ["Clear all"]="Clear song, status, notes, Build ID, and date filters.",
  ["Open Selected Log"]="Open the logfile for the selected attempt.",
  ["Copy Selected Build ID"]="Copy the selected attempt's Build ID to the clipboard.",
  ["Clean Up Logs..."]="Preview and remove old attempt log files by age.",
  ["Copy Latest Build ID"]="Copy the latest build attempt ID to the clipboard.",
  ["Open Log Folder"]="Open the active project's Bildibeat Click Track Mapper log folder.",
  ["Create Support Bundle"]="Create a troubleshooting bundle without including the workbook or RPP.",
  ["Unload Current Workbook"]="Unload the workbook, Preview, selection, staged edits, recovery copy, and pending Build Notes after any required discard confirmation; logs and REAPER are unchanged.",
  ["Unload Workbook"]="Unload the workbook, Preview, selection, staged edits, recovery copy, and pending Build Notes after any required discard confirmation; logs and REAPER are unchanged.",
  ["Clear Recent Workbooks"]="Remove all entries from the Recent Files list.",
  ["Clear Saved History Filters"]="Clear persisted History filters.",
  ["Clear Saved Filters"]="Clear persisted History filters.",
  ["Restore Default Layout"]="Restore the default window, panel sizes, Preview column widths, and Preview horizontal scroll position.",
  ["Diagnostics..."]="Open one diagnostics window with Copy Diagnostics and Create Support Bundle actions.",
  ["Run Parser Self-Test"]="Run parser and release regression tests, including the golden compact/standard/wide/Larger Text UI geometry matrix, without changing the project.",
  ["Reset App Preferences..."]="Reset app preferences while preserving logs and build history.",
  ["Open README"]="Find the highest-version README beside the script and open it.",
  ["Copy Spreadsheet Example"]="Copy the complete labeled v10.21 workbook example covering every supported syntax family, modifier, section, and END.",
  ["Play"]="Play the selected contiguous Preview rows after a verified build or exact Validate Against Open Project result, without rebuilding.",
  ["Stop"]="Stop audition playback, restore temporary audition settings, and return the edit cursor to the first selected row.",
  ["Reset Syntax Example"]="Restore the complete v10.21 Scratchpad example and Section BPM 120, then test it immediately.",
  ["Reset Example"]="Restore the complete v10.21 Scratchpad example and Section BPM 120, then test it immediately; this shortened label is used only in a compact Larger Text pane.",
  ["Restore Defaults"]="Load the v10.21 click-frequency defaults (A 1760 Hz and B 1600 Hz) into the fields; choose Save to store them.",
  ["Test Syntax"]="Validate the Scratchpad expression with the same production parser used for workbooks; no project or workbook data is changed.",
  ["Play Preview"]="Render and hear the complete valid Scratchpad expression without adding tracks, items, markers, or tempo changes to the REAPER project.",
  ["Copy Normalized"]="Copy the parser-normalized version of the valid Scratchpad expression.",
  ["Copy Readout"]="Copy the complete selected-row or Scratchpad plain-English readout without truncation.",
  ["Calendar..."]="Open the calendar for this inclusive MM-DD-YYYY History date field.",
  ["Previous Month"]="Show the previous calendar month without changing the selected date.",
  ["Next Month"]="Show the next calendar month without changing the selected date.",
  ["Today"]="Set this History date field to today's date.",
  ["Clear Date"]="Clear only the active History date field.",
  ["Clear Range"]="Clear both inclusive History date fields.",
  ["Close Calendar"]="Close the calendar without changing the current date fields.",
  ["Measure Numbers: On"]="Hide measure ranges from the musician-facing readout.",
  ["Measure Numbers: Off"]="Add measure ranges to the musician-facing readout.",
  ["Simplified Readout: On"]="Return to the full musician-facing Song Structure Readout.",
  ["Simplified Readout: Off"]="Show only count, repeat, written click type, and optional BPM/measure information; repeated groups are parenthesized without parser terminology.",
  ["Show BPM: On"]="Hide underlying musical BPM values from every full or Simplified Readout section and Ramp destination.",
  ["Show BPM: Off"]="Show underlying musical BPM values throughout the full or Simplified Readout; multiplied REAPER BPM is never used here.",
  ["Generic Part Names: On"]="Use workbook Section names again in the readout and subsequent MIDI click-package markers; REAPER project markers never change.",
  ["Generic Part Names: Off"]="Show musical Sections and subsequent MIDI click-package markers as PART 1, PART 2, and so on while retaining COUNT-IN and END; REAPER project markers never change.",
  ["Export..."]="Save the complete Song Structure Readout as a text file.",
  ["Print..."]="Open a print-ready Song Structure Readout with section-aware page breaks.",
  ["Save REAPER Project As..."]="Open Save As with a unique editable pre-build .RPP filename, save it, and make that REAPER project copy active before building.",
  ["Continue Without Saving"]="Proceed without writing current REAPER project changes to disk; a completed-project save choice will appear after a successful build.",
  ["Cancel Build"]="Cancel before Bildibeat Click Track Mapper changes the REAPER project.",
  ["Save Another Copy As..."]="Open Save As with a unique editable completed-build .RPP filename and make that copy active.",
  ["Save Completed REAPER Project"]="Save the verified completed map into the currently active REAPER .RPP project.",
  ["Save Completed Project As..."]="Open Save As with a unique editable completed-build .RPP filename and make that copy active.",
  ["Close Without Saving"]="Close this prompt without saving the completed REAPER project; the build remains only in the active in-memory project until saved.",
  ["Close"]="Close Bildibeat Click Track Mapper safely. Staged tempo edits are counted and confirmed before their recovery copy can be discarded."
}
function control_unavailable_reason(label)
  local clean=tostring(label or ""):gsub("^✓ ",""):gsub("^Density:.*$","Density")
  if state.operation_busy then return "A workbook, logging, or build operation is currently running." end
  if clean=="Recent Files..." then return "No recent workbook is available in this workspace." end
  if clean=="Validate Only" then return state.file_path=="" and "Choose a saved XLSX or CSV workbook first." or "Validation is temporarily blocked by another workflow." end
  if clean=="Validation Issues" then return "The current validation has no recorded issues." end
  if clean=="Validate Against Open Project" or clean=="Compare Open Project" or clean=="Project Match" then local _,reason=project_comparison_available();return reason end
  if clean=="Copy Corrected Cell" then
    local rows=preview_display_rows();local row=state.selected_preview_row and rows[state.selected_preview_row] or nil
    return not row and "Select a validation-error row first." or not row.issue and "The selected row is not a validation error." or not row.issue.correction and "The selected issue has no exact high-confidence corrected cell value." or "The correction workflow is temporarily unavailable."
  end
  if clean=="Open Workbook" or clean=="Workbook" then return state.file_path=="" and "No workbook is selected." or "The workbook cannot be opened during another operation." end
  if clean=="Build Click Track Map" or clean=="Apply & Verify Tempo Edits" or clean=="Jump to Part" or clean=="Jump to END" or clean=="Jump to Ramp" then
    local active=get_active_project_info()
    if not state.plan then return "Validate a workbook successfully first." end
    if state.preview_stale then return "The workbook changed after validation; validate it again." end
    if state.project_changed then return "The active REAPER project changed after validation; validate against the current project again." end
    if not active or not project_is_saved(active) then return "Save the active REAPER project first." end
    if not state.validation_project or active.pointer~=state.validation_project.pointer then return "The active project tab is not the project that was validated." end
    if not state.environment_ok then return "Environment diagnostics did not pass: "..table.concat(state.environment_issues or {"unknown environment issue"},"; ") end
    if (clean=="Build Click Track Map" or clean=="Apply & Verify Tempo Edits") and (not state.dry_run or state.dry_run_stale) then return state.dry_run and "The automatic REAPER project check became stale; wait for it to refresh." or "A current automatic REAPER project check is required before building." end
    local row=state.selected_preview_row and state.preview_rows[state.selected_preview_row] or nil
    if (clean=="Jump to Part" or clean=="Jump to END" or clean=="Jump to Ramp") and not row then return "Select a validated Preview row first." end
    if clean=="Jump to Ramp" and row and not row.ramp_start then return "The selected Preview row does not contain an active ramp." end
    return "The validated preview is not currently eligible for this action."
  end
  if clean=="Open User-Friendly Song Structure..." then return "Validate a workbook successfully before using this output." end
  if clean=="Export MIDI + MP3 Click..." or clean=="Export MIDI + MP3..." then local _,reason=click_package_available();return reason end
  if clean=="Revert Tempo Edit" then local _,reason=selected_revert_available();return reason end
  if clean=="Save Updated Workbook Copy" or clean=="Save Workbook Copy" then local _,reason=updated_workbook_copy_available();return reason end
  if clean=="Undo Last Build" then local _,reason=undo_available();return reason end
  if clean=="Open Selected Log" or clean=="Copy Selected Build ID" then return "Select an Attempt History row first." end
  if clean=="Clean Up Logs..." or clean=="Create Support Bundle" then return "Save the active REAPER project first so its log folder is known." end
  if clean=="Copy Latest Build ID" then return "No build attempt ID exists in this app session." end
  if clean=="Close" then return "Wait for the current operation to finish before closing the app." end
  if clean=="Unload Current Workbook" or clean=="Unload Workbook" or clean=="Reset App Preferences..." or clean=="Build Notes..." or clean=="Notes..." then return "Wait for the current operation to finish." end
  return "A required selection, validated plan, saved project, or completed workflow is missing."
end

function button_help_text(label,enabled,disabled_reason)
  local clean=tostring(label or ""):gsub("✓ ",""):gsub("^Density:.*$","Density")
  local text
  if state.active_view=="HELP" and clean=="Stop" then
    text="Stop the current Scratchpad audio preview and release its temporary audio file."
  elseif state.active_view=="HELP" and clean:match("^Loop:") then
    text="Toggle continuous looping for the complete Scratchpad audio preview."
  elseif state.active_view=="HELP" and clean:match("^50%% Speed:") then
    text="Render the Scratchpad preview at half tempo while keeping the configured click frequencies unchanged."
  elseif clean=="Close" and state.app_modal then
    text="Close this in-app panel and return to Bildibeat Click Track Mapper."
  else
    text=BUTTON_HELP[clean]
  end
  if not text then
    if clean:match("^Song:") then text="Filter Attempt History to one exact workbook path."
    elseif clean:match("^Filter") then text=BUTTON_HELP["Filter"]
    elseif clean:match("^Loop:") then text="Toggle continuous looping for the current or next row audition."
    elseif clean:match("^50%% Speed:") then text="Audition at half speed; Bildibeat Click Track Mapper temporarily enables master-playrate audio pitch preservation and restores the previous state afterward."
    elseif clean:match("^Click Frequencies:") then text="Edit the persisted A/B synthesized metronome frequencies applied by future verified builds."
    elseif clean=="All" or clean=="Success" or clean=="Failure" or clean=="Cancelled" or clean=="Undone" then text="Show only "..clean:lower().." attempts in history."
    elseif clean=="Density" then text="Switch the Preview Table between compact and comfortable row spacing."
    elseif clean=="Remember Layout" then text="Restore the app window, resizable panels, Preview column widths, and horizontal scroll position next time."
    elseif clean=="Alternating row shading" or clean=="Alternating Rows" then text="Use alternating row backgrounds to make wide rows easier to follow."
    elseif clean=="Section boundary emphasis" or clean=="Section Emphasis" then text="Draw a stronger divider at the first row of each section."
    elseif clean=="Show syntax badges" then text="Show full plain-English Part-column labels such as Quarter Note, Eighth Note Triplet, Sextuplet, Quintuplet, Septuplet, No Accent, Repeat x2, BPM Override: 150, Ramp: 1 Bar, Ramp Inactive, and Block Pass 1 of 2."
    elseif clean=="Right-click row explanations" then text="Show the full plain-English readout above contextual Preview-row actions; when disabled, right-click still opens the compact actions menu."
    elseif clean=="Larger text throughout app" then text="Increase all app-owned text by about 50% with a minimum six-point increase; pane spacing, row heights, wrapping, dialogs, tooltips, and syntax results adapt with it. Windows-owned title bars and file dialogs use Windows settings."
    elseif clean=="Remember last page" then text="Reopen the last selected Build, History, Settings, or Help page."
    elseif clean=="Remember history filters" or clean=="Remember Filters" then text="Restore song, status, notes, Build ID, and date filters next time."
    elseif clean=="Show plan hashes" then text="Display the validated plan hash in the Build interface."
    elseif clean=="Show workbook full path" then text="Display the complete workbook path instead of only its filename."
    elseif clean=="Developer diagnostics mode" then text="Show extra internal state and timing details for troubleshooting."
    elseif clean=="Save" and state.app_modal and state.app_modal.context=="click_frequencies" then text="Store these A/B frequencies as app defaults for future verified builds; this does not immediately change the REAPER project."
    elseif clean=="Save" then text="Save the entered value and apply it."
    elseif clean=="Search" then text="Run the Error Reference search using the entered text; a blank search lists the full catalog."
    elseif clean=="Copy Correction" then text="Confirm and copy the exact corrected cell value; the workbook is not edited."
    elseif clean=="OK" then text="Close this in-app message and return to Bildibeat Click Track Mapper."
    elseif clean=="Continue" then text="Continue the current in-app workflow."
    elseif clean=="Text (.txt)" then text="Export the validated preview as a plain-text report."
    elseif clean=="CSV (.csv)" then text="Export the validated preview as a CSV file."
    elseif clean=="Apply" then text="Apply the selected filters."
    elseif clean=="Reset Filters" then text="Clear all advanced History filters."
    elseif clean=="Cancel" then text="Close this panel without applying changes."
    elseif clean=="Open README" then text=BUTTON_HELP["Open README"]
    else text="Activate "..clean.."." end
  end
  if not enabled then text=text.." Unavailable: "..tostring(disabled_reason or control_unavailable_reason(clean)) end
  return text
end

function draw_button(label,x,y,w,h,enabled,clicked,compact,disabled_reason)
  local inside=point_inside(x,y,w,h);local hover=enabled and inside
  local focused,keyboard_activate,focus_index=register_focus_control(label,enabled)
  if inside then state.hover_context=button_help_text(label,enabled,disabled_reason) end
  if not enabled then set_color(27,33,40) elseif hover then set_ui_color("button_hover") else set_ui_color("button") end
  gfx.rect(x,y,w,h,true)
  if not enabled then set_color(48,57,67) elseif hover then set_ui_color("accent") else set_ui_color("button_border") end
  gfx.rect(x,y,w,h,false)
  draw_focus_outline(x,y,w,h,focused and enabled)
  if enabled then set_ui_color("text") else set_color(105,115,126) end
  local font_size=compact and 12 or 14;local shown=fit_text(label,math.max(8,w-16),font_size,true)
  gfx.setfont(1,UI.font_name,scaled_font_size(font_size),98)
  local tw,th=gfx.measurestr(shown);gfx.x=x+(w-tw)/2;gfx.y=y+(h-th)/2;gfx.drawstr(shown)
  local mouse_activated=consume_button_activation(enabled,hover,clicked);local activated=mouse_activated or keyboard_activate
  if mouse_activated and focus_index then state.focus_index=focus_index end
  if activated then set_status(tostring(label):gsub("✓ ","").." selected.","info") end
  return activated
end
function draw_primary_button(label,x,y,w,h,enabled,clicked,disabled_reason)
  local inside=point_inside(x,y,w,h);local hover=enabled and inside
  local focused,keyboard_activate,focus_index=register_focus_control(label,enabled)
  if inside then state.hover_context=button_help_text(label,enabled,disabled_reason) end
  if not enabled then set_color(38,47,57) elseif hover then set_ui_color("primary_hover") else set_ui_color("primary") end
  gfx.rect(x,y,w,h,true)
  if enabled then set_color(89,181,248) else set_color(60,70,82) end;gfx.rect(x,y,w,h,false)
  draw_focus_outline(x,y,w,h,focused and enabled)
  local font_size=h<46 and 15 or 18;local shown=fit_text(label,math.max(8,w-18),font_size,true)
  set_color(250,252,255);gfx.setfont(1,UI.font_name,scaled_font_size(font_size),98)
  local tw,th=gfx.measurestr(shown);gfx.x=x+(w-tw)/2;gfx.y=y+(h-th)/2;gfx.drawstr(shown)
  local mouse_activated=consume_button_activation(enabled,hover,clicked);local activated=mouse_activated or keyboard_activate
  if mouse_activated and focus_index then state.focus_index=focus_index end
  if activated then set_status(tostring(label).." selected.","info") end
  return activated
end

function draw_accent_button(label,x,y,w,h,enabled,clicked,disabled_reason)
  local inside=point_inside(x,y,w,h);local hover=enabled and inside
  local focused,keyboard_activate,focus_index=register_focus_control(label,enabled)
  if inside then state.hover_context=button_help_text(label,enabled,disabled_reason) end
  if not enabled then set_color(27,33,40) elseif hover then set_color(34,54,72) else set_ui_color("button") end
  gfx.rect(x,y,w,h,true)
  if enabled then set_ui_color("accent") else set_color(48,57,67) end;gfx.rect(x,y,w,h,false)
  draw_focus_outline(x,y,w,h,focused and enabled)
  if enabled then set_color(222,238,251) else set_color(105,115,126) end
  local shown=fit_text(label,math.max(8,w-16),14,true);gfx.setfont(1,UI.font_name,scaled_font_size(14),98)
  local tw,th=gfx.measurestr(shown);gfx.x=x+(w-tw)/2;gfx.y=y+(h-th)/2;gfx.drawstr(shown)
  local mouse_activated=consume_button_activation(enabled,hover,clicked);local activated=mouse_activated or keyboard_activate
  if mouse_activated and focus_index then state.focus_index=focus_index end
  if activated then set_status(tostring(label).." selected.","info") end
  return activated
end

function shorten_middle(text,max_chars)
  text=tostring(text or "");if #text<=max_chars then return text end;local keep=math.max(1,math.floor((max_chars-3)/2));return text:sub(1,keep).."..."..text:sub(-keep)
end
function fit_text(text,width,size,bold)
  text=tostring(text or "");gfx.setfont(1,UI.font_name,scaled_font_size(size or 13),bold and 98 or 0);if gfx.measurestr(text)<=width then return text end
  local ell="...";local lo,hi=0,#text
  while lo<hi do local mid=math.floor((lo+hi+1)/2);if gfx.measurestr(text:sub(1,mid)..ell)<=width then lo=mid else hi=mid-1 end end
  return text:sub(1,lo)..ell
end
function fit_mono_text(text,width,size)
  text=tostring(text or "");gfx.setfont(2,UI.mono_font_name,scaled_font_size(size or 13),0);if gfx.measurestr(text)<=width then return text end
  local ell="...";local lo,hi=0,#text
  while lo<hi do local mid=math.floor((lo+hi+1)/2);if gfx.measurestr(text:sub(1,mid)..ell)<=width then lo=mid else hi=mid-1 end end
  return text:sub(1,lo)..ell
end
function looks_like_syntax_text(text)
  local value=trim(text)
  if value=="" then return false end
  if value:find("SECTION NAME | BPM | PARTS",1,true)~=nil or value:find("Normalized syntax:",1,true)==1 then return true end
  if value:find(" | ",1,true) and (value:find("ENT(",1,true) or value:find("SXT{",1,true) or value:find("QNT{",1,true) or value:find("SPT{",1,true)) then return true end
  local starts_raw=value:match("^%[%d+%]")~=nil or value:match("^%(%d+%)")~=nil or value:match("^%{%d+%}")~=nil
    or value:match("^%*%d+%*")~=nil or value:sub(1,1)=="<" or value:match("^ENT%(")~=nil
    or value:match("^SXT%{")~=nil or value:match("^QNT%{")~=nil or value:match("^SPT%{")~=nil
  if not starts_raw then return false end
  for _,phrase in ipairs({" creates "," selects "," repeats "," is "," remains "," targets "," applies "," changes "," means "}) do
    if value:find(phrase,1,true) then return false end
  end
  return true
end

function help_source_line_uses_mono(text)
  local value=trim(text)
  if value=="" then return false end
  if value:find(" | ",1,true) then return true end
  local starts_raw=value:match("^[%[%(%{%*<]")~=nil
    or value:match("^ENT%(")~=nil or value:match("^SXT%{")~=nil
    or value:match("^QNT%{")~=nil or value:match("^SPT%{")~=nil
  if not starts_raw then return false end
  for _,phrase in ipairs({" creates "," selects "," repeats "," is "," remains "," targets "," applies "," changes "}) do
    if value:find(phrase,1,true) then return false end
  end
  return true
end

function help_source_line_is_heading(text)
  local value=trim(text)
  if value=="" or value:find("%l") then return false end
  return value:match("^[A-Z0-9][A-Z0-9 +,&/%-]+$")~=nil
end

function scratchpad_source_line_uses_mono(text)
  return trim(text):find("Normalized syntax:",1,true)==1
end

function wrap_styled_source_text(text,max_width,style_fn)
  local output={}
  for raw_line in (tostring(text or "").."\n"):gmatch("(.-)\n") do
    local mono=style_fn and style_fn(raw_line)==true or false
    local wrapped=wrap_text(raw_line,max_width,mono and 12 or 13,mono)
    if #wrapped==0 then wrapped={""} end
    for _,line in ipairs(wrapped) do output[#output+1]={text=line,mono=mono} end
  end
  return output
end

TEXT_KEYS={
  BACKSPACE=8,TAB=9,ENTER=13,ESCAPE=27,
  DELETE=6579564,END_KEY=6647396,HOME=1752132965,
  LEFT=1818584692,RIGHT=1919379572,UP=30064,DOWN=1685026670,SPACE=32,F1=0x6631,F10=0x663130,
  CTRL_A=1,CTRL_C=3,CTRL_F=6,CTRL_O=15,CTRL_V=22,CTRL_X=24
}

function today_iso_date()
  return os.date("%Y-%m-%d")
end

function shift_iso_date(iso,days)
  local y,m,d=tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$");if not y then return today_iso_date() end
  local stamp=os.time({year=tonumber(y),month=tonumber(m),day=tonumber(d)+(tonumber(days) or 0),hour=12})
  return os.date("%Y-%m-%d",stamp)
end

function modal_calendar_set_field(modal,iso,clear_range)
  local calendar=modal and modal.calendar;if not calendar then return end
  if clear_range then
    if modal.fields[2] then modal.fields[2].value="";modal.fields[2].cursor=0;modal.fields[2].anchor=0 end
    if modal.fields[3] then modal.fields[3].value="";modal.fields[3].cursor=0;modal.fields[3].anchor=0 end
  else
    local field=modal.fields and modal.fields[calendar.field_index]
    if field then field.value=history_display_date(iso or "");field.cursor=#field.value;field.anchor=field.cursor;field.view_start=0 end
  end
  modal.calendar=nil;local ok,err=validate_history_filter_fields(modal.fields or {});modal.error=ok and "" or err
  if modal.on_change then modal.on_change(modal.fields,calendar.field_index) end
end

function open_modal_calendar(modal,field_index)
  local field=modal and modal.fields and modal.fields[field_index];if not field then return end
  local iso=parse_history_display_date(field.value or "");if not iso or iso=="" then iso=today_iso_date() end
  local y,m=iso:match("^(%d%d%d%d)%-(%d%d)")
  modal.calendar={field_index=field_index,year=tonumber(y),month=tonumber(m),selected_iso=iso}
  modal.error="";quarantine_base_input(0.15)
end

function draw_modal_calendar(modal,clicked,key)
  local calendar=modal and modal.calendar;if not calendar then return end
  if key==TEXT_KEYS.ESCAPE then modal.calendar=nil;state.last_key=0;return end
  local delta=key==TEXT_KEYS.LEFT and -1 or key==TEXT_KEYS.RIGHT and 1 or key==TEXT_KEYS.UP and -7 or key==TEXT_KEYS.DOWN and 7 or nil
  if delta then
    calendar.selected_iso=shift_iso_date(calendar.selected_iso,delta);local y,m=calendar.selected_iso:match("^(%d%d%d%d)%-(%d%d)");calendar.year=tonumber(y);calendar.month=tonumber(m);state.last_key=0
  elseif key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE then modal_calendar_set_field(modal,calendar.selected_iso,false);state.last_key=0;return
  elseif key==TEXT_KEYS.BACKSPACE or key==TEXT_KEYS.DELETE then modal_calendar_set_field(modal,"",false);state.last_key=0;return
  elseif key==string.byte("t") or key==string.byte("T") then calendar.selected_iso=today_iso_date();local y,m=calendar.selected_iso:match("^(%d%d%d%d)%-(%d%d)");calendar.year=tonumber(y);calendar.month=tonumber(m);state.last_key=0 end

  local w,h=calendar_modal_geometry(gfx.w,gfx.h,state.larger_text);local x=(gfx.w-w)/2;local y=(gfx.h-h)/2
  set_color(0,0,0,0.62);gfx.rect(0,0,gfx.w,gfx.h,true);set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("card_border");gfx.rect(x,y,w,h,false);set_ui_color("accent");gfx.rect(x,y,5,h,true)
  local role=calendar.field_index==2 and "Date From" or "Date To";set_ui_color("text");draw_text("Choose "..role,x+22,y+16,19,true)
  local month_names={"January","February","March","April","May","June","July","August","September","October","November","December"}
  local nav_y=y+(state.larger_text and 58 or 52);local nav_w=state.larger_text and 158 or 132;local nav_h=state.larger_text and 42 or 34
  if draw_button("Previous Month",x+18,nav_y,nav_w,nav_h,true,clicked,true) then calendar.month=calendar.month-1;if calendar.month<1 then calendar.month=12;calendar.year=calendar.year-1 end end
  if draw_button("Next Month",x+w-18-nav_w,nav_y,nav_w,nav_h,true,clicked,true) then calendar.month=calendar.month+1;if calendar.month>12 then calendar.month=1;calendar.year=calendar.year+1 end end
  set_ui_color("text");local heading=month_names[calendar.month].." "..calendar.year;gfx.setfont(1,UI.font_name,scaled_font_size(16),98);local hw,hh=gfx.measurestr(heading);draw_text(heading,x+(w-hw)/2,nav_y+(nav_h-hh)/2,16,true)

  local grid_x=x+18;local grid_y=y+(state.larger_text and 118 or 104);local grid_w=w-36;local cell_w=grid_w/7;local cell_h=state.larger_text and 46 or 34;local weekdays={"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
  for col,name in ipairs(weekdays) do set_ui_color("muted");draw_text(name,grid_x+(col-1)*cell_w+8,grid_y,12,true) end
  local first_stamp=os.time({year=calendar.year,month=calendar.month,day=1,hour=12});local first_wday=os.date("*t",first_stamp).wday
  local next_stamp=os.time({year=calendar.year,month=calendar.month+1,day=1,hour=12});local days=tonumber(os.date("%d",next_stamp-24*60*60))
  local from_iso=parse_history_display_date(modal.fields[2] and modal.fields[2].value or "") or "";local to_iso=parse_history_display_date(modal.fields[3] and modal.fields[3].value or "") or "";local today=today_iso_date()
  for day=1,days do
    local slot=first_wday-1+day-1;local row=math.floor(slot/7);local col=slot%7;local dx=grid_x+col*cell_w;local dy=grid_y+24+row*cell_h;local iso=string.format("%04d-%02d-%02d",calendar.year,calendar.month,day);local hover=point_inside(dx,dy,cell_w-3,cell_h-3);if hover then state.hover_context="Choose "..history_display_date(iso).." for "..role.."; the History range is inclusive." end
    local in_range=from_iso~="" and to_iso~="" and iso>=from_iso and iso<=to_iso
    if iso==calendar.selected_iso then set_ui_color("primary");gfx.rect(dx,dy,cell_w-3,cell_h-3,true)
    elseif hover then set_ui_color("button_hover");gfx.rect(dx,dy,cell_w-3,cell_h-3,true)
    elseif in_range then set_color(41,75,104);gfx.rect(dx,dy,cell_w-3,cell_h-3,true) end
    if iso==today then set_ui_color("good") else set_ui_color("button_border") end;gfx.rect(dx,dy,cell_w-3,cell_h-3,false)
    set_ui_color("text");draw_text(tostring(day),dx+8,dy+7,13,iso==calendar.selected_iso)
    if clicked and hover and consume_button_activation(true,true,clicked) then calendar.selected_iso=iso;modal_calendar_set_field(modal,iso,false);return end
  end
  local button_y=y+h-(state.larger_text and 108 or 82);local gap=8;local bw=math.floor((w-36-gap)/2);local bh=state.larger_text and 42 or 32
  if draw_button("Today",x+18,button_y,bw,bh,true,clicked,true) then modal_calendar_set_field(modal,today_iso_date(),false);return end
  if draw_button("Clear Date",x+18+bw+gap,button_y,bw,bh,true,clicked,true) then modal_calendar_set_field(modal,"",false);return end
  if draw_button("Clear Range",x+18,button_y+bh+gap,bw,bh,true,clicked,true) then modal_calendar_set_field(modal,"",true);return end
  if draw_button("Close Calendar",x+18+bw+gap,button_y+bh+gap,bw,bh,true,clicked,true) then modal.calendar=nil;return end
  if clicked and not state.press_consumed and not point_inside(x,y,w,h) then modal.calendar=nil end
end

-- Text cursors are stored as UTF-8 byte offsets between characters. Keeping
-- them on code-point boundaries prevents navigation or deletion from splitting
-- an existing non-ASCII character, while preserving Lua's inexpensive slicing.
function clamp_text_cursor(text,cursor)
  text=tostring(text or "")
  local value=math.max(0,math.min(#text,math.floor(tonumber(cursor) or #text)))
  while value>0 and value<#text do
    local byte=text:byte(value+1)
    if not byte or byte<128 or byte>=192 then break end
    value=value-1
  end
  return value
end

function previous_text_cursor(text,cursor)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor)
  if cursor<=0 then return 0 end
  local byte_index=cursor
  while byte_index>1 do
    local byte=text:byte(byte_index)
    if not byte or byte<128 or byte>=192 then break end
    byte_index=byte_index-1
  end
  return byte_index-1
end

function next_text_cursor(text,cursor)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor)
  if cursor>=#text then return #text end
  local lead=text:byte(cursor+1) or 0
  local bytes=lead<128 and 1 or lead<224 and 2 or lead<240 and 3 or 4
  return math.min(#text,cursor+bytes)
end

function input_character_from_key(key)
  if not key then return nil end
  if key>=0x20 and key<=0xff then return utf8.char(key) end
  if (key>>24)==0x75 then return utf8.char(key&0xffffff) end
  return nil
end

function text_selection_bounds(text,cursor,anchor)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor);anchor=clamp_text_cursor(text,anchor or cursor)
  if anchor<=cursor then return anchor,cursor,anchor~=cursor end
  return cursor,anchor,true
end

function text_character_class(text,offset)
  text=tostring(text or "");offset=clamp_text_cursor(text,offset)
  if offset>=#text then return "end" end
  local following=next_text_cursor(text,offset);local char=text:sub(offset+1,following);local byte=char:byte(1) or 0
  if char:match("^%s$") then return "space" end
  if char:match("^[%w_]$") or byte>=128 then return "word" end
  return "punctuation"
end

function word_left_text_cursor(text,cursor)
  text=tostring(text or "");local pos=clamp_text_cursor(text,cursor)
  while pos>0 do local previous=previous_text_cursor(text,pos);if text_character_class(text,previous)~="space" then break end;pos=previous end
  if pos<=0 then return 0 end
  local class=text_character_class(text,previous_text_cursor(text,pos))
  while pos>0 do local previous=previous_text_cursor(text,pos);if text_character_class(text,previous)~=class then break end;pos=previous end
  return pos
end

function word_right_text_cursor(text,cursor)
  text=tostring(text or "");local pos=clamp_text_cursor(text,cursor)
  if pos<#text then
    local class=text_character_class(text,pos)
    while pos<#text and text_character_class(text,pos)==class do pos=next_text_cursor(text,pos) end
  end
  while pos<#text and text_character_class(text,pos)=="space" do pos=next_text_cursor(text,pos) end
  return pos
end

function text_word_bounds(text,cursor)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor)
  if text=="" then return 0,0 end
  local sample=cursor<#text and cursor or previous_text_cursor(text,cursor)
  local class=text_character_class(text,sample);local first=sample;local last=next_text_cursor(text,sample)
  while first>0 do local previous=previous_text_cursor(text,first);if text_character_class(text,previous)~=class then break end;first=previous end
  while last<#text and text_character_class(text,last)==class do last=next_text_cursor(text,last) end
  return first,last
end

function replace_text_selection(text,cursor,anchor,replacement)
  text=tostring(text or "");replacement=tostring(replacement or "")
  local first,last=text_selection_bounds(text,cursor,anchor)
  local value=text:sub(1,first)..replacement..text:sub(last+1)
  local next_cursor=first+#replacement
  return value,next_cursor,next_cursor,value~=text
end

function edit_text_selection(text,cursor,anchor,key,ctrl,shift)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor);anchor=clamp_text_cursor(text,anchor or cursor)
  ctrl=ctrl==true;shift=shift==true
  local first,last,selected=text_selection_bounds(text,cursor,anchor)
  if ctrl and key==TEXT_KEYS.CTRL_A then return text,#text,0,false,true end

  if key==TEXT_KEYS.LEFT or key==TEXT_KEYS.RIGHT or key==TEXT_KEYS.HOME or key==TEXT_KEYS.END_KEY then
    local moved=cursor
    if not shift and selected and key==TEXT_KEYS.LEFT then moved=first
    elseif not shift and selected and key==TEXT_KEYS.RIGHT then moved=last
    elseif key==TEXT_KEYS.LEFT then moved=ctrl and word_left_text_cursor(text,cursor) or previous_text_cursor(text,cursor)
    elseif key==TEXT_KEYS.RIGHT then moved=ctrl and word_right_text_cursor(text,cursor) or next_text_cursor(text,cursor)
    elseif key==TEXT_KEYS.HOME then moved=0
    else moved=#text end
    return text,moved,shift and anchor or moved,false,true
  end

  if key==TEXT_KEYS.BACKSPACE or key==TEXT_KEYS.DELETE then
    if selected then
      local value,next_cursor,next_anchor,changed=replace_text_selection(text,cursor,anchor,"")
      return value,next_cursor,next_anchor,changed,true
    end
    if key==TEXT_KEYS.BACKSPACE and cursor>0 then
      local previous=ctrl and word_left_text_cursor(text,cursor) or previous_text_cursor(text,cursor)
      local value=text:sub(1,previous)..text:sub(cursor+1)
      return value,previous,previous,true,true
    elseif key==TEXT_KEYS.DELETE and cursor<#text then
      local following=ctrl and word_right_text_cursor(text,cursor) or next_text_cursor(text,cursor)
      local value=text:sub(1,cursor)..text:sub(following+1)
      return value,cursor,cursor,true,true
    end
    return text,cursor,cursor,false,true
  end

  local inserted=input_character_from_key(key)
  if inserted then
    local value,next_cursor,next_anchor,changed=replace_text_selection(text,cursor,anchor,inserted)
    return value,next_cursor,next_anchor,changed,true
  end
  return text,cursor,anchor,false,false
end

function edit_text_with_clipboard(text,cursor,anchor,key,ctrl,shift)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor);anchor=clamp_text_cursor(text,anchor or cursor)
  local first,last,selected=text_selection_bounds(text,cursor,anchor)
  if ctrl and (key==TEXT_KEYS.CTRL_C or key==TEXT_KEYS.CTRL_X) then
    if not selected then return text,cursor,anchor,false,true,nil,"Select text before copying or cutting." end
    local ok,err=copy_to_clipboard(text:sub(first+1,last))
    if not ok then return text,cursor,anchor,false,true,nil,"Clipboard copy failed: "..tostring(err) end
    if key==TEXT_KEYS.CTRL_X then
      local value,next_cursor,next_anchor,changed=replace_text_selection(text,cursor,anchor,"")
      return value,next_cursor,next_anchor,changed,true,"Selected text cut.",nil
    end
    return text,cursor,anchor,false,true,"Selected text copied.",nil
  end
  if ctrl and key==TEXT_KEYS.CTRL_V then
    local pasted,err=read_from_clipboard()
    if pasted==nil then return text,cursor,anchor,false,true,nil,"Clipboard paste failed: "..tostring(err) end
    pasted=tostring(pasted):gsub("[\r\n]+"," ")
    local value,next_cursor,next_anchor,changed=replace_text_selection(text,cursor,anchor,pasted)
    return value,next_cursor,next_anchor,changed,true,"Clipboard text pasted.",nil
  end
  local value,next_cursor,next_anchor,changed,handled=edit_text_selection(text,cursor,anchor,key,ctrl,shift)
  return value,next_cursor,next_anchor,changed,handled,nil,nil
end

function edit_text_at_cursor(text,cursor,key)
  local value,next_cursor,_,changed,handled=edit_text_selection(text,cursor,cursor,key,false,false)
  return value,next_cursor,changed,handled
end

function editable_text_view(text,cursor,view_start,max_width,size,mono)
  text=tostring(text or "");cursor=clamp_text_cursor(text,cursor)
  max_width=math.max(1,tonumber(max_width) or 1);gfx.setfont(mono and 2 or 1,mono and UI.mono_font_name or UI.font_name,scaled_font_size(size or 13),0)
  local start=clamp_text_cursor(text,math.min(cursor,tonumber(view_start) or 0))
  while start<cursor and gfx.measurestr(text:sub(start+1,cursor))>max_width do start=next_text_cursor(text,start) end
  while start>0 do
    local earlier=previous_text_cursor(text,start)
    if gfx.measurestr(text:sub(earlier+1,cursor))>max_width then break end
    start=earlier
  end
  local finish=start
  while finish<#text do
    local following=next_text_cursor(text,finish)
    if gfx.measurestr(text:sub(start+1,following))>max_width then break end
    finish=following
  end
  local shown=text:sub(start+1,finish)
  local caret_x=gfx.measurestr(text:sub(start+1,cursor))
  return shown,start,finish,caret_x
end

function editable_cursor_from_x(text,view_start,view_finish,relative_x,size,mono)
  text=tostring(text or "");local start=clamp_text_cursor(text,view_start);local finish=clamp_text_cursor(text,view_finish)
  if finish<start then finish=start end
  local target=tonumber(relative_x) or 0;if target<=0 then return start end
  gfx.setfont(mono and 2 or 1,mono and UI.mono_font_name or UI.font_name,scaled_font_size(size or 13),0)
  local previous_x=0;local cursor=start
  while cursor<finish do
    local following=next_text_cursor(text,cursor)
    local next_x=gfx.measurestr(text:sub(start+1,following))
    if target<(previous_x+next_x)/2 then return cursor end
    previous_x=next_x;cursor=following
  end
  return finish
end

function draw_editable_selection(text,cursor,anchor,view_start,view_finish,x,y,height,size,mono)
  local first,last,selected=text_selection_bounds(text,cursor,anchor)
  if not selected then return end
  first=math.max(first,view_start);last=math.min(last,view_finish)
  if first>=last then return end
  gfx.setfont(mono and 2 or 1,mono and UI.mono_font_name or UI.font_name,scaled_font_size(size or 13),0)
  local left=gfx.measurestr(tostring(text or ""):sub(view_start+1,first))
  local right=gfx.measurestr(tostring(text or ""):sub(view_start+1,last))
  set_color(45,116,178,0.82);gfx.rect(x+left,y,math.max(1,right-left),height,true)
end

function split_wrapped_token(token,max_width)
  token=tostring(token or "");local pieces={};local first=0
  while first<#token do
    local last=first
    while last<#token do
      local following=next_text_cursor(token,last)
      if following<=last or gfx.measurestr(token:sub(first+1,following))>max_width then break end
      last=following
    end
    if last==first then last=next_text_cursor(token,first) end
    pieces[#pieces+1]=token:sub(first+1,last);first=last
  end
  return pieces
end

function wrap_text(text,max_width,size,use_mono_measurement)
  local font_name=use_mono_measurement and UI.mono_font_name or UI.font_name
  gfx.setfont(use_mono_measurement and 2 or 1,font_name,scaled_font_size(size or 13),0);max_width=math.max(8,tonumber(max_width) or 8);local lines={}
  for para in (tostring(text or "").."\n"):gmatch("(.-)\n") do
    if para=="" then lines[#lines+1]=""
    else
      local line=""
      for word in para:gmatch("%S+") do
        local candidate=line=="" and word or line.." "..word
        if gfx.measurestr(candidate)<=max_width then line=candidate
        else
          if line~="" then lines[#lines+1]=line;line="" end
          if gfx.measurestr(word)<=max_width then line=word
          else
            local pieces=split_wrapped_token(word,max_width)
            for index,piece in ipairs(pieces) do
              if index<#pieces then lines[#lines+1]=piece else line=piece end
            end
          end
        end
      end
      if line~="" then lines[#lines+1]=line end
    end
  end
  return lines
end
function status_color(kind)
  if kind=="error" then return 255,145,145 elseif kind=="success" then return 145,225,165 elseif kind=="warning" then return 255,205,120 else return 190,198,207 end
end

function context_bar_tag(is_selected,kind,hover_context)
  return is_selected and "SELECTED ROW" or kind=="error" and "ERROR" or kind=="warning" and "WARNING" or kind=="success" and "SUCCESS" or hover_context~="" and "TOOLTIP" or "STATUS"
end

function draw_context_bar(content_x,message,kind,rows)
  local layout=UI.layout or responsive_layout(gfx.w,gfx.h);local y=gfx.h-layout.status_height
  set_ui_color("status_bar");gfx.rect(0,y,gfx.w,layout.status_height,true)
  set_ui_color("divider");gfx.line(0,y,gfx.w,y)
  set_ui_color("divider");gfx.line(content_x,y,content_x,gfx.h)
  local selected=state.active_view=="BUILD" and state.selected_preview_row and rows and rows[state.selected_preview_row] or nil
  local selected_blurb=preview_row_blurb(selected)
  local is_selected=selected_blurb and message==selected_blurb
  local tag=context_bar_tag(is_selected,kind,state.hover_context)
  local color_name=is_selected and "accent" or kind=="error" and "bad" or kind=="warning" and "warning" or kind=="success" and "good" or "accent"
  local x=content_x+(layout.body_margin or 20);local tag_w=state.larger_text and (is_selected and 156 or tag=="WARNING" and 126 or tag=="TOOLTIP" and 120 or 104) or (is_selected and 116 or tag=="WARNING" and 88 or tag=="TOOLTIP" and 84 or 76);local tag_h=state.larger_text and 36 or layout.status_height<52 and 26 or 28;local tag_y=y+math.floor((layout.status_height-tag_h)/2)
  local c=UI.colors[color_name]
  set_color(math.floor(c[1]*0.72),math.floor(c[2]*0.72),math.floor(c[3]*0.72));gfx.rect(x,tag_y,tag_w,tag_h,true)
  set_color(c[1],c[2],c[3]);gfx.rect(x,tag_y,tag_w,tag_h,false)
  set_color(244,248,252);gfx.setfont(1,UI.font_name,scaled_font_size(11),98);local tw,th=gfx.measurestr(tag);gfx.x=x+(tag_w-tw)/2;gfx.y=tag_y+(tag_h-th)/2;gfx.drawstr(tag)
  local text_x=x+tag_w+16;local text_w=math.max(40,gfx.w-text_x-18);local lines=wrap_text(message or "",text_w,13);local line_h=state.larger_text and 26 or 17
  local visible=math.max(1,math.floor((layout.status_height-10)/line_h));local shown=math.min(#lines,visible);local text_y=y+math.max(5,math.floor((layout.status_height-shown*line_h)/2))
  set_color(220,227,234)
  for i=1,shown do draw_text(lines[i],text_x,text_y+(i-1)*line_h,13,false) end
end

function total_column_width()
  local n=0;for _,w in ipairs(state.column_widths) do n=n+w end;return n
end

function autofit_column(col)
  local key=COLUMN_KEYS[col];local mono=key=="part"
  gfx.setfont(mono and 2 or 1,mono and UI.mono_font_name or UI.font_name,scaled_font_size(13),0);local maxw=gfx.measurestr(COLUMN_HEADERS[col])+18
  for _,r in ipairs(state.preview_rows) do
    local value=r[key] or ""
    if key=="part" and state.show_syntax_badges then local tags={};for _,badge in ipairs(preview_syntax_badges(r)) do tags[#tags+1]="["..badge.."]" end;if #tags>0 then value=table.concat(tags," ").."  "..tostring(value) end end
    maxw=math.max(maxw,gfx.measurestr(tostring(value))+18)
  end
  state.column_widths[col]=math.max(45,math.min(800,maxw));if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(state.column_widths),true) end
end

function preview_display_rows()
  if state.plan then return state.preview_rows end
  local rows={}
  for i,e in ipairs(state.errors) do
    local issue=(state.validation_issues or {})[i] or validation_issue_from_error(e,i)
    local code=issue.reference and issue.reference.code or "ERROR";local title=issue.reference and issue.reference.title or "Workbook validation issue"
    rows[#rows+1]={row=issue.row and tostring(issue.row) or "-",section=code,part=code.." — "..title,bars="",meter=issue.field or "",base_bpm="",reaper_bpm="",ramp=issue.correction and "CORRECTION" or "REVIEW",start="",next="",details=validation_issue_summary(issue),issue=issue}
  end
  return rows
end

function open_row_popover(index,row,anchor_x,anchor_y)
  if not row then return end
  local first,last=selected_preview_range()
  if not first or index<first or index>last then set_preview_selection(index,false) else state.selected_preview_row=index end
  state.row_popover={row_index=index,row=row,anchor_x=anchor_x or gfx.mouse_x,anchor_y=anchor_y or gfx.mouse_y,focus=1,scroll=0,opened_at=reaper.time_precise()}
  state.scratchpad_has_focus=false
  set_status("Preview row actions opened. Press Tab or the arrow keys to move; Enter activates; Escape closes.","info")
end

function close_row_popover()
  state.row_popover=nil
  quarantine_base_input(0.20)
end

function unique_section_override_count(section)
  local seen,count={},0
  for _,part in ipairs((section and section.parts) or {}) do
    local key=tostring(part.item_index or 0)..":"..tostring(part.block_part_index or 0)
    if part.has_override and not seen[key] then seen[key]=true;count=count+1 end
  end
  return count
end

function edit_section_bpm(row)
  local section=section_for_row(state.plan,row and row.section_row)
  if not section then show_info("Edit Section BPM","The selected Preview row is not associated with an editable Section.","warning");return end
  local base_section=base_section_for_row(section.row)
  if not base_section then show_info("Edit Section BPM","The selected Section's loaded-workbook baseline is unavailable.","error");return end
  local override_count=unique_section_override_count(base_section)
  local checkbox=nil
  if override_count>0 then
    local existing=state.tempo_edits.rows[section.row]
    checkbox={
      value=existing and existing.section_shift_overrides==true or false,
      label=string.format("Shift %d explicit Part BPM override%s by the Section's numerical difference from the loaded workbook. Example: workbook Section 120 changed to 123 moves @100 to @103.",override_count,override_count==1 and "" or "s"),
      help="When checked, each workbook @BPM source Part that was not edited separately moves by the Section's total additive difference from the loaded workbook. Repeated edits are recalculated from that baseline, so they cannot accumulate drift."
    }
  end
  open_app_modal({
    title="Edit Section BPM — "..section.name,
    message="Change the Section's underlying musical BPM. Inherited Parts and calculated REAPER BPM values will update immediately in the staged Preview. The workbook and REAPER project will not change until their separate save/build actions are used.\n\nAccent behavior is preserved: a worksheet value ending in 'no accent' remains no accent.",
    kind="input",input=format_bpm(section.bpm),input_label="New Section BPM",checkbox=checkbox,
    validator=function(value) local bpm,err=parse_positive_decimal(value,"Section BPM");return bpm~=nil,err end,
    buttons={{label="Stage Section BPM",value="save",primary=true},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value,input,fields,shift_overrides)
      if value~="save" then return end
      local new_bpm=tonumber(trim(input));local candidate=clone_tempo_edits(state.tempo_edits);candidate.rows[section.row]=candidate.rows[section.row] or {part_bpms={}}
      local entry=candidate.rows[section.row];entry.part_bpms=entry.part_bpms or {}
      entry.bpm_text=format_section_bpm_cell(new_bpm,base_section.no_accent)
      entry.section_shift_overrides=shift_overrides==true
      local composed,compose_error=compose_tempo_edit_row(candidate,section.row)
      if not composed then show_info("Tempo Edit Could Not Be Applied","[EDT-002] "..tostring(compose_error),"error");return end
      normalize_tempo_edit_row(candidate,section.row)
      local baseline_delta=new_bpm-base_section.bpm
      commit_tempo_edit(candidate,string.format("Staged %s Section BPM: %s to %s.",section.name,format_bpm(section.bpm),format_bpm(new_bpm)),string.format("SECTION row %d %s: workbook %s -> staged %s; baseline numerical difference=%s; shift explicit overrides=%s; no accent preserved=%s",section.row,section.name,format_bpm(base_section.bpm),format_bpm(new_bpm),format_bpm(baseline_delta),tostring(shift_overrides),tostring(base_section.no_accent)))
    end
  })
  if state.app_modal then state.app_modal.context="edit_section_bpm" end
end

function edit_part_bpm(row)
  if not row or not row.item_index then show_info("Edit Part BPM","Select an ordinary musical Part row. COUNT IN and END use their Section/END tempo actions.","warning");return end
  local section=section_for_row(state.plan,row.section_row)
  if not section then show_info("Edit Part BPM","The selected Part's Section could not be located.","error");return end
  local base_section=base_section_for_row(section.row)
  if not base_section then show_info("Edit Part BPM","The selected Part's loaded-workbook baseline is unavailable.","error");return end
  local current=tonumber(row.base_bpm)
  open_app_modal({
    title="Edit Part BPM — "..section.name,
    message="Change this source Part's underlying musical BPM. Setting it equal to the Section BPM removes a redundant @BPM override. Every ordinary repeat and Block pass generated by this same source Part updates together. Calculated REAPER BPM remains read-only.",
    kind="input",input=format_bpm(current),input_label="New underlying Part BPM",
    validator=function(value) local bpm,err=parse_positive_decimal(value,"Part BPM");return bpm~=nil,err end,
    buttons={{label="Stage Part BPM",value="save",primary=true},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value,input)
      if value~="save" then return end
      local new_bpm=tonumber(trim(input))
      local candidate=clone_tempo_edits(state.tempo_edits);candidate.rows[section.row]=candidate.rows[section.row] or {part_bpms={}}
      local entry=candidate.rows[section.row];entry.part_bpms=entry.part_bpms or {}
      local key=tempo_part_key(row.item_index,row.block_part_index)
      local source_parts=source_parts_for_section(base_section);local base_source,source_index=nil,nil
      for index,source in ipairs(source_parts) do if source.key==key then base_source=source.part;source_index=index;break end end
      if not base_source then show_info("Tempo Edit Could Not Be Applied","[EDT-003] The selected source Part could not be found in the loaded workbook baseline.","error");return end
      local natural=natural_part_bpm_for_edit(base_section,entry,base_source,section.bpm,source_index==1)
      if nearly_equal(new_bpm,natural,1e-9) then entry.part_bpms[key]=nil else entry.part_bpms[key]=new_bpm end
      local composed,compose_error=compose_tempo_edit_row(candidate,section.row)
      if not composed then show_info("Tempo Edit Could Not Be Applied","[EDT-003] "..tostring(compose_error),"error");return end
      normalize_tempo_edit_row(candidate,section.row)
      commit_tempo_edit(candidate,string.format("Staged %s Part BPM: %s to %s.",section.name,format_bpm(current),format_bpm(new_bpm)),string.format("PART row %d item %d block part %s: %s -> %s; independent Part edit=%s; no accent preserved=%s",section.row,row.item_index,tostring(row.block_part_index or "none"),format_bpm(current),format_bpm(new_bpm),tostring(not nearly_equal(new_bpm,natural,1e-9)),tostring(base_section.no_accent)))
    end
  })
  if state.app_modal then state.app_modal.context="edit_part_bpm" end
end

function edit_end_bpm()
  local initial=state.plan and state.plan.end_bpm_entered and format_bpm(state.plan.end_bpm_entered) or ""
  open_app_modal({
    title="Edit END BPM",
    message="Set the underlying END tempo used by a legal final Ramp. Leave this field blank to restore the standard 25 BPM END behavior. END remains a zero-bar 1/4 boundary.",
    kind="input",input=initial,input_label="END BPM (blank uses 25)",
    validator=function(value) if trim(value)=="" then return true end local bpm,err=parse_positive_decimal(value,"END BPM");return bpm~=nil,err end,
    buttons={{label="Stage END BPM",value="save",primary=true},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value,input)
      if value~="save" then return end
      local candidate=clone_tempo_edits(state.tempo_edits);candidate.end_bpm_set=true;candidate.end_bpm_text=trim(input)
      local base_text=state.base_plan.end_bpm_text or ""
      if candidate.end_bpm_text==base_text then candidate.end_bpm_set=false;candidate.end_bpm_text="" end
      local old=state.plan.end_bpm_entered and format_bpm(state.plan.end_bpm_entered) or "blank (25)";local new=trim(input)~="" and trim(input) or "blank (25)"
      commit_tempo_edit(candidate,"Staged END BPM: "..old.." to "..new..".","END BPM: "..old.." -> "..new)
    end
  })
  if state.app_modal then state.app_modal.context="edit_end_bpm" end
end

function scratchpad_payload_for_preview_rows(rows,first,last,plan,fallback_row)
  local selected={}
  for index=first or 0,last or -1 do
    local row=rows[index]
    if row and not row.issue and not row.is_end then selected[#selected+1]={index=index,row=row} end
  end
  if #selected==0 and fallback_row and not fallback_row.issue and not fallback_row.is_end then selected[1]={index=0,row=fallback_row} end
  if #selected==0 then
    return nil,"Select one or more musical Preview rows. END has no playable duration and cannot be sent by itself."
  end
  local accent_mode=nil
  for _,entry in ipairs(selected) do
    local current=entry.row.is_count_in and false or entry.row.no_accent==true
    if accent_mode==nil then accent_mode=current elseif accent_mode~=current then
      return nil,"The selected rows mix accented and no-accent Sections. The Scratchpad has one Section BPM/accent setting, so send rows with the same accent behavior together."
    end
  end
  local syntax={}
  for position,entry in ipairs(selected) do
    local row=entry.row
    if row.is_count_in then
      syntax[#syntax+1]="[4]x2@"..format_bpm(tonumber(row.base_bpm) or plan.count_in_bpm)
    elseif row.part_object then
      local part={};for key,value in pairs(row.part_object) do part[key]=value end
      local next_selected=selected[position+1]
      if part.ramp_suppressed or (part.ramp and not next_selected) then part.declared_ramp_bars=0;part.ramp_bars=0;part.ramp=false end
      syntax[#syntax+1]=canonical_part_with_underlying_bpm(part,part.underlying_bpm,-1)
    end
  end
  if #syntax==0 then
    return nil,"The highlighted range contains no playable Part rows."
  end
  local bpm_value=format_bpm(tonumber(selected[1].row.base_bpm) or plan.count_in_bpm)..(accent_mode and " no accent" or "")
  return {bpm=bpm_value,parts=table.concat(syntax,", "),count=#syntax}
end

function send_selected_rows_to_scratchpad(fallback_row)
  local first,last=selected_preview_range()
  if not first or not last then first=state.selected_preview_row;last=first end
  local payload,payload_error=scratchpad_payload_for_preview_rows(state.preview_rows,first,last,state.plan,fallback_row)
  if not payload then show_info("Send to Scratchpad",payload_error,"warning");return end
  if state.audio_preview and state.audio_preview.owner=="scratchpad" then stop_audio_preview(true) end
  local bpm_value,parts_value=payload.bpm,payload.parts
  local bpm_field,parts_field=state.scratchpad_fields[1],state.scratchpad_fields[2]
  bpm_field.value=bpm_value;bpm_field.cursor=#bpm_value;bpm_field.anchor=bpm_field.cursor;bpm_field.view_start=0
  parts_field.value=parts_value;parts_field.cursor=#parts_value;parts_field.anchor=parts_field.cursor;parts_field.view_start=0
  state.scratchpad_result=evaluate_syntax_scratchpad(bpm_value,parts_value);state.scratchpad_result_scroll=0
  state.active_view="HELP";state.scratchpad_has_focus=false;state.scratchpad_focus=0
  if state.remember_last_page then reaper.SetExtState(EXTSTATE_SECTION,"active_view","HELP",true) end
  set_status(string.format("Sent %d playable Preview row%s to the Syntax Scratchpad. Choose Play Preview when ready.",payload.count,payload.count==1 and "" or "s"),"success")
end

function row_popover_actions(row)
  local actions={}
  if row and row.issue then
    actions[#actions+1]={label="Explain Error",run=function()show_validation_issue(row.issue)end}
    actions[#actions+1]={label="Search Error Reference",run=function()show_error_reference_entry(row.issue.reference)end}
    actions[#actions+1]={label="Copy Error Code",run=function()
      local code=tostring(row.issue.reference and row.issue.reference.code or "UNK-001");local ok,err=copy_to_clipboard(code);set_status(ok and ("Error code "..code.." copied.") or ("Copy failed: "..tostring(err)),ok and "success" or "error")
    end}
  elseif row then
    if row.is_end or tostring(row.source or "")=="END" then
      actions[#actions+1]={label="Edit END BPM...",run=edit_end_bpm}
    elseif row.is_count_in then
      actions[#actions+1]={label="Edit First Section BPM...",run=function()edit_section_bpm(row)end}
    elseif row.item_index then
      actions[#actions+1]={label="Edit Section BPM...",run=function()edit_section_bpm(row)end}
      actions[#actions+1]={label="Edit Part BPM...",run=function()edit_part_bpm(row)end}
    end
    local jump_label=(tostring(row.source or "")=="END" or tostring(row.part or "")=="END") and "Jump to END" or "Jump to Part"
    actions[#actions+1]={label=jump_label,run=function()jump_to_preview_row(row,false)end}
    if row.ramp_start then actions[#actions+1]={label="Jump to Ramp",run=function()jump_to_preview_row(row,true)end} end
    if not row.is_end then actions[#actions+1]={label="Send to Scratchpad",run=function()send_selected_rows_to_scratchpad(row)end} end
  end
  actions[#actions+1]={label="Copy Readout",run=function()
    local ok,err=copy_to_clipboard(preview_row_full_readout(row));set_status(ok and "Plain-English row readout copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
  end}
  local syntax=row_original_syntax(row)
  if syntax then actions[#actions+1]={label="Copy Syntax",run=function()
    local selected_syntax,count=selected_preview_syntax(row)
    local ok,err=copy_to_clipboard(selected_syntax);set_status(ok and (count==1 and "Selected row syntax copied." or (tostring(count).." selected row syntax parts copied in Preview order.")) or ("Copy failed: "..tostring(err)),ok and "success" or "error")
  end} end
  return actions
end

function run_row_popover_action(action)
  if not action or not action.run then return end
  state.row_popover=nil;quarantine_base_input(0.25)
  queue_after_mouse_release(action.run)
end

function draw_row_popover(clicked,right_clicked,key)
  local popover=state.row_popover;if not popover then return end
  local row=popover.row;local actions=row_popover_actions(row);local detailed=state.show_row_explanations
  local margin=16;local w=math.min(state.larger_text and (detailed and 680 or 480) or (detailed and 560 or 390),gfx.w-margin*2);local cols=2;local gap=8;local button_h=state.larger_text and 44 or 32;local action_rows=math.max(1,math.ceil(#actions/cols));local actions_h=action_rows*(button_h+gap)-gap
  local explanation=preview_row_full_readout(row);local text_lines=detailed and wrap_text(explanation,w-36,13) or {}
  local pop_line_h=state.larger_text and 25 or 18;local text_visible=detailed and math.min(#text_lines,8) or 0;local text_h=detailed and math.max(state.larger_text and 72 or 58,text_visible*pop_line_h+16) or 0
  local h=54+text_h+actions_h+22
  local x=(popover.anchor_x or gfx.mouse_x)+12;if x+w>gfx.w-margin then x=(popover.anchor_x or gfx.mouse_x)-w-12 end
  x=math.max(margin,math.min(gfx.w-margin-w,x))
  local y=(popover.anchor_y or gfx.mouse_y)+12;if y+h>gfx.h-(UI.layout and UI.layout.status_height or 54)-margin then y=(popover.anchor_y or gfx.mouse_y)-h-12 end
  y=math.max(margin,math.min(gfx.h-(UI.layout and UI.layout.status_height or 54)-margin-h,y))
  popover.bounds={x=x,y=y,w=w,h=h}
  if (clicked or right_clicked) and not point_inside(x,y,w,h) then close_row_popover();return end

  set_color(0,0,0,0.36);gfx.rect(x+6,y+7,w,h,true)
  set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("card_border");gfx.rect(x,y,w,h,false)
  set_ui_color("accent");gfx.rect(x,y,4,h,true)
  set_ui_color("text");draw_text(row and row.issue and "ROW VALIDATION" or "ROW EXPLANATION",x+18,y+12,16,true)
  local location=row and (trim(row.section_name or row.section)~="" and trim(row.section_name or row.section) or tostring(row.part or "Preview row")) or "Preview row"
  set_ui_color("muted");draw_text(fit_text((row and row.row and ("Row "..tostring(row.row).."  •  ") or "")..location,w-78,11),x+18,y+34,11,false)
  local close_hover=point_inside(x+w-36,y+10,24,24);if close_hover then state.hover_context="Close the Preview row actions without changing REAPER or the workbook.";set_ui_color("button_hover");gfx.rect(x+w-36,y+10,24,24,true) end
  set_color(180,192,204);gfx.line(x+w-29,y+17,x+w-19,y+27);gfx.line(x+w-19,y+17,x+w-29,y+27)
  if clicked and close_hover then close_row_popover();return end

  local action_y=y+54
  if detailed then
    set_ui_color("table_body");gfx.rect(x+12,action_y,w-24,text_h,true);set_ui_color("divider");gfx.rect(x+12,action_y,w-24,text_h,false)
    local visible=math.max(1,math.floor((text_h-12)/pop_line_h));local max_scroll=math.max(0,#text_lines-visible);popover.scroll=math.max(0,math.min(popover.scroll or 0,max_scroll))
    for i=1,visible do local line=text_lines[popover.scroll+i];if line then set_color(215,223,231);draw_text(line,x+22,action_y+7+(i-1)*pop_line_h,13,false) end end
    if max_scroll>0 then
      local sx=x+w-22;set_ui_color("scroll_track");gfx.rect(sx,action_y,8,text_h,true);local thumb=math.max(20,text_h*visible/#text_lines);local sy=action_y+(text_h-thumb)*(popover.scroll/max_scroll);set_ui_color("scroll_thumb");gfx.rect(sx+1,sy,6,thumb,true)
      if gfx.mouse_wheel~=0 and point_inside(x+12,action_y,w-24,text_h) then popover.scroll=popover.scroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
    end
    action_y=action_y+text_h+10
  end

  if key==TEXT_KEYS.ESCAPE then close_row_popover();state.last_key=0;return end
  if #actions>0 and (key==TEXT_KEYS.TAB or key==TEXT_KEYS.LEFT or key==TEXT_KEYS.RIGHT or key==TEXT_KEYS.UP or key==TEXT_KEYS.DOWN) then
    local direction=(key==TEXT_KEYS.LEFT or key==TEXT_KEYS.UP or (key==TEXT_KEYS.TAB and (gfx.mouse_cap&8)==8)) and -1 or 1
    popover.focus=((popover.focus-1+direction)%#actions)+1;state.last_key=0
  elseif #actions>0 and (key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE) then
    run_row_popover_action(actions[popover.focus]);state.last_key=0;return
  end

  local button_w=math.floor((w-24-gap)/2)
  for index,action in ipairs(actions) do
    local row_index=math.floor((index-1)/cols);local col=(index-1)%cols;local bx=x+12+col*(button_w+gap);local bw=button_w
    if index==#actions and #actions%2==1 then bx=x+12;bw=w-24 end
    local by=action_y+row_index*(button_h+gap);local hover=point_inside(bx,by,bw,button_h);if hover then state.hover_context=button_help_text(action.label,true) end
    if hover then set_ui_color("button_hover") else set_ui_color("button") end;gfx.rect(bx,by,bw,button_h,true)
    if popover.focus==index then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(bx,by,bw,button_h,false)
    set_ui_color("text");local shown=fit_text(action.label,bw-16,12,true);gfx.setfont(1,UI.font_name,scaled_font_size(12),98);local tw,th=gfx.measurestr(shown);gfx.x=bx+(bw-tw)/2;gfx.y=by+(button_h-th)/2;gfx.drawstr(shown)
    if clicked and hover and consume_button_activation(true,true,clicked) then popover.focus=index;run_row_popover_action(action);return end
  end
end

function draw_preview_table(x,y,w,h,clicked,mouse_down,right_clicked)
  local rows=preview_display_rows();local compact_accessibility=state.larger_text and UI.layout and UI.layout.compact and gfx.h<800;local accessibility_add=state.larger_text and (compact_accessibility and 4 or 10) or 0;local header_h=UI.header_height+accessibility_add;local row_h=(state.preview_density=="COMPACT" and 22 or 30)+accessibility_add;local scroll_h=compact_accessibility and 10 or 14;local body_h=h-header_h-scroll_h;local visible_rows=math.max(1,math.floor(body_h/row_h));local max_v=math.max(0,#rows-visible_rows)
  local table_focused,_,table_focus_index=register_focus_control("Validated Preview rows",#rows>0);state.preview_table_bounds={x=x,y=y,w=w,h=h,visible_rows=visible_rows,row_h=row_h,focus_index=table_focus_index}
  state.preview_vscroll=math.max(0,math.min(state.preview_vscroll,max_v))
  local total_w=total_column_width();local max_h=math.max(0,total_w-w+14);state.preview_hscroll=math.max(0,math.min(state.preview_hscroll,max_h))

  set_ui_color("table_header");gfx.rect(x,y,w,header_h,true)
  set_ui_color("table_body");gfx.rect(x,y+header_h,w,body_h,true)
  local cx=x-state.preview_hscroll
  local divider_hover=nil
  for i,header in ipairs(COLUMN_HEADERS) do
    local cw=state.column_widths[i];local left=cx;local right=cx+cw
    if right>x and left<x+w then
      local header_font=state.larger_text and UI.layout and UI.layout.compact and 10 or 13
      set_color(222,229,237);local drawx=math.max(left+10,x+6);local avail=math.min(right,x+w)-drawx-6;if avail>4 then draw_text(fit_text(header,avail,header_font),drawx,y+5,header_font,true) end
      set_ui_color("divider");gfx.line(right,y,right,y+h-scroll_h)
    end
    if right>=x and right<=x+w and math.abs(gfx.mouse_x-right)<=4 and gfx.mouse_y>=y and gfx.mouse_y<=y+header_h then divider_hover=i end
    cx=right
  end
  if divider_hover then set_ui_color("accent");gfx.line(x-state.preview_hscroll+(function() local s=0;for j=1,divider_hover do s=s+state.column_widths[j] end;return s end)(),y,x-state.preview_hscroll+(function() local s=0;for j=1,divider_hover do s=s+state.column_widths[j] end;return s end)(),y+h-scroll_h) end

  if clicked and divider_hover then
    local now=reaper.time_precise()
    if state.last_divider_click_col==divider_hover and now-state.last_divider_click_time<0.35 then autofit_column(divider_hover);state.resize_col=nil
    else state.resize_col=divider_hover;state.resize_start_x=gfx.mouse_x;state.resize_start_width=state.column_widths[divider_hover] end
    state.last_divider_click_col=divider_hover;state.last_divider_click_time=now
  end
  if state.resize_col then
    if mouse_down then state.column_widths[state.resize_col]=math.max(45,math.min(800,state.resize_start_width+(gfx.mouse_x-state.resize_start_x)))
    else if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(state.column_widths),true) end;state.resize_col=nil end
  end

  state.hover_preview_row=nil
  for vr=1,visible_rows do
    local idx=state.preview_vscroll+vr;local r=rows[idx];local ry=y+header_h+(vr-1)*row_h
    if ry+row_h<=y+header_h+body_h then
      local hover=point_inside(x,ry,w,row_h);if hover then
        state.hover_preview_row=idx
        local selected_blurb=idx==state.selected_preview_row and preview_row_blurb(r) or nil
        local staged_detail=state.staged_change_details and state.staged_change_details[idx]
        state.hover_context=staged_detail and ("Staged workbook difference: "..staged_detail) or selected_blurb or (r and r.issue and "Select this workbook-row error. Right-click for its explanation and actions." or "Select this Preview row. Double-click jumps; right-click opens its explanation and contextual actions.")
      end
      local range_start,range_end=selected_preview_range()
      local in_selection=range_start and idx>=range_start and idx<=range_end
      local staged_changed=state.staged_changed_rows and state.staged_changed_rows[idx]
      if staged_changed and in_selection then set_color(83,70,25)
      elseif staged_changed and hover then set_color(74,64,29)
      elseif staged_changed then set_color(61,54,28)
      elseif in_selection then set_ui_color("row_selected")
      elseif hover then set_ui_color("row_hover")
      elseif state.alternating_rows and vr%2==0 then set_ui_color("row_alt")
      else set_ui_color("row") end;gfx.rect(x,ry,w,row_h,true)
      if in_selection then set_ui_color("accent");gfx.rect(x,ry,4,row_h,true) end
      if state.section_emphasis and r and (idx==1 or not rows[idx-1] or rows[idx-1].section~=r.section) then set_color(47,143,234,0.72);gfx.rect(x,ry,w,1,true) end
      if r then
        local cellx=x-state.preview_hscroll
        for col,key in ipairs(COLUMN_KEYS) do
          local cw=state.column_widths[col];local left=cellx;local right=cellx+cw
          if right>x and left<x+w then
            local dx=math.max(left+10,x+6);local avail=math.min(right,x+w)-dx-6
            if avail>4 then
              if r.section=="ERROR" then set_color(244,150,150) else set_color(220,226,233) end
              local display_value=r[key] or ""
              if key=="part" and state.show_syntax_badges then
                local badges=preview_syntax_badges(r)
                if #badges>0 then local tags={};for _,badge in ipairs(badges) do tags[#tags+1]="["..badge.."]" end;display_value=table.concat(tags," ").."  "..tostring(display_value) end
              end
              local mono=key=="part"
              if mono then draw_mono_text(fit_mono_text(display_value,avail,12),dx,ry+math.max(3,math.floor((row_h-16)/2)),12,false)
              else draw_text(fit_text(display_value,avail,13),dx,ry+math.max(3,math.floor((row_h-16)/2)),13,false) end
            end
            set_ui_color("divider",0.82);gfx.line(right,ry,right,ry+row_h)
          end
          cellx=right
        end
      end
      set_ui_color("divider",0.72);gfx.line(x,ry+row_h,x+w,ry+row_h)
    end
  end

  if right_clicked and state.hover_preview_row and not divider_hover and not state.resize_col then
    local r=rows[state.hover_preview_row];open_row_popover(state.hover_preview_row,r,gfx.mouse_x,gfx.mouse_y)
  elseif clicked and state.hover_preview_row and not divider_hover and not state.resize_col then
    local now=reaper.time_precise();local extend=(gfx.mouse_cap&8)==8;set_preview_selection(state.hover_preview_row,extend);state.focus_index=table_focus_index;state.focus_view=state.active_view
    local r=rows[state.hover_preview_row];local blurb=preview_row_blurb(r)
    if blurb then set_status(blurb,"info") end
    if not extend and state.last_row_click_index==state.hover_preview_row and now-state.last_row_click_time<0.35 then if r then if r.issue then show_validation_issue(r.issue) else jump_to_preview_row(r,false) end end end
    state.last_row_click_index=state.hover_preview_row;state.last_row_click_time=now
  end

  -- Vertical scrollbar
  local vx=x+w-10;local vy=y+header_h;local vh=body_h
  set_ui_color("scroll_track");gfx.rect(vx,vy,10,vh,true)
  if #rows>visible_rows then
    local thumb=math.max(22,vh*visible_rows/#rows);local ty=vy+(vh-thumb)*(state.preview_vscroll/max_v);set_ui_color("scroll_thumb");gfx.rect(vx+2,ty,6,thumb,true)
    if clicked and point_inside(vx,vy,10,vh) then state.vscroll_drag=true end
    if state.vscroll_drag then if mouse_down then local ratio=math.max(0,math.min(1,(gfx.mouse_y-vy-thumb/2)/(vh-thumb)));state.preview_vscroll=math.floor(ratio*max_v+0.5) else state.vscroll_drag=false end end
  end

  -- Horizontal scrollbar
  local hx=x;local hy=y+h-scroll_h;local hw=w-10
  set_ui_color("scroll_track");gfx.rect(hx,hy,hw,scroll_h,true)
  if total_w>w then
    local thumb=math.max(30,hw*w/total_w);local tx=hx+(hw-thumb)*(state.preview_hscroll/max_h);set_ui_color("scroll_thumb");gfx.rect(tx,hy+4,thumb,scroll_h-8,true)
    if clicked and point_inside(hx,hy,hw,scroll_h) then state.hscroll_drag=true end
    if state.hscroll_drag then if mouse_down then local ratio=math.max(0,math.min(1,(gfx.mouse_x-hx-thumb/2)/(hw-thumb)));state.preview_hscroll=ratio*max_h else state.hscroll_drag=false;if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"preview_hscroll",tostring(state.preview_hscroll),true) end end end
  end

  if gfx.mouse_wheel~=0 and point_inside(x,y,w,h) then state.preview_vscroll=state.preview_vscroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
  draw_focus_outline(x,y,w,h,table_focused)
end

function draw_indicator(label,value,good,x,y,w)
  set_color(good and 42 or 82,good and 112 or 68,good and 65 or 68);gfx.rect(x,y,w,26,true);set_color(240,243,246);draw_text(label..": "..value,x+7,y+5,12,true)
end

function draw_history_panel(x,y,w,h,clicked,mouse_down)
  local large=state.larger_text==true;local top_button_h=large and 38 or 26;local filter_button_h=large and 34 or 24
  local top_button_y=y+(large and 42 or 32);local filter_y=y+(large and 86 or 64)
  set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("text");draw_text("ATTEMPT HISTORY",x+10,y+9,15,true)
  local song_label="All Songs"
  if state.history_song~="ALL" then for _,e in ipairs(state.history) do if workbook_identity(e.spreadsheet)==state.history_song then local n,f=workbook_display(e.spreadsheet);song_label=n.." — "..f;break end end end
  if draw_button(fit_text("Song: "..song_label,w-148,11),x+8,top_button_y,w-144,top_button_h,true,clicked,true) then queue_after_mouse_release(choose_history_song) end
  local active_count=0;if state.history_notes_search~="" then active_count=active_count+1 end;if state.history_id_search~="" then active_count=active_count+1 end;if state.history_date_from~="" or state.history_date_to~="" then active_count=active_count+1 end
  if draw_button(active_count>0 and ("Filter • "..active_count) or "Filter",x+w-128,top_button_y,120,top_button_h,true,clicked,true) then queue_after_mouse_release(open_history_search) end
  local filters={{"ALL","All"},{"SUCCESS","Success"},{"FAILURE","Failure"},{"CANCELLED","Cancelled"},{"UNDONE","Undone"}}
  local fx=x+8;local fy=filter_y
  for _,f in ipairs(filters) do local bw=(w-20)/5;if draw_button(f[2],fx,fy,bw-2,filter_button_h,true,clicked,true) then state.history_filter=f[1];state.history_selected=nil;state.history_scroll=math.huge;reaper.SetExtState(EXTSTATE_SECTION,"history_filter",f[1],true) end;fx=fx+bw end
  local summary={}
  if state.history_song~="ALL" then summary[#summary+1]="Song: "..song_label end
  if trim(state.history_notes_search)~="" then summary[#summary+1]="Notes: "..state.history_notes_search end
  if trim(state.history_id_search)~="" then summary[#summary+1]="ID: "..state.history_id_search end
  if trim(state.history_date_from)~="" or trim(state.history_date_to)~="" then summary[#summary+1]=(state.history_date_from~="" and history_display_date(state.history_date_from) or "Any").." to "..(state.history_date_to~="" and history_display_date(state.history_date_to) or "Any") end
  local entries=filtered_history();local summary_y=fy+filter_button_h+(large and 10 or 7)
  set_color(151,160,171);draw_text(fit_text(#summary>0 and table.concat(summary," • ") or "No advanced filters",w-190,11),x+10,summary_y+5,11,false)
  set_color(190,198,207);draw_text(#entries.." attempts shown",x+w-176,summary_y+5,11,true)
  if #summary>0 or state.history_filter~="ALL" then if draw_button("Clear all",x+w-(large and 108 or 84),summary_y,large and 100 or 76,large and 32 or 24,true,clicked,true) then clear_all_history_filters() end end
  local list_y=summary_y+(large and 42 or 31);local row_h=large and 82 or 56;local controls_h=large and 72 or 58
  local list_available=math.max(0,h-(list_y-y)-controls_h);local visible=math.max(0,math.floor(list_available/row_h))
  local max_scroll=math.max(0,#entries-visible);state.history_scroll=math.max(0,math.min(state.history_scroll,max_scroll))
  for i=1,visible do local idx=state.history_scroll+i;local e=entries[idx];local ry=list_y+(i-1)*row_h
    local hover=point_inside(x+7,ry,w-14,row_h-2);if idx==state.history_selected then set_ui_color("row_selected") elseif hover then set_ui_color("row_hover") elseif i%2==0 then set_ui_color("row_alt") else set_ui_color("row") end;gfx.rect(x+7,ry,w-14,row_h-2,true)
    if idx==state.history_selected then set_ui_color("accent");gfx.rect(x+7,ry,3,row_h-2,true) end
    if e then
      local n=workbook_display(e.spreadsheet)
      set_color(232,234,237);draw_text(fit_text(n,w-122,12),x+12,ry+(large and 7 or 5),12,true)
      set_color(e.status=="SUCCESS" and 145 or e.status=="FAILURE" and 255 or e.status=="CANCELLED" and 245 or 170,e.status=="SUCCESS" and 225 or e.status=="FAILURE" and 145 or e.status=="CANCELLED" and 195 or 210,e.status=="SUCCESS" and 165 or e.status=="FAILURE" and 145 or e.status=="CANCELLED" and 120 or 255);draw_text(e.status,x+w-(large and 124 or 95),ry+(large and 7 or 5),10,true)
      set_color(175,181,189);draw_text(fit_text((e.timestamp or "").."  •  "..(e.id or ""),w-28,10),x+12,ry+(large and 34 or 22),10,false)
      set_color(145,151,160);draw_text(fit_text(trim(e.notes or "")~="" and ("Note: "..e.notes) or "No build notes",w-28,10),x+12,ry+(large and 58 or 38),10,false)
    end
    if clicked and hover and e then state.history_selected=idx end
  end
  if gfx.mouse_wheel~=0 and point_inside(x,list_y,w,visible*row_h) then state.history_scroll=state.history_scroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
  local by=y+h-controls_h+5;local selected=selected_history_entry()
  local bottom_h=large and 40 or 30
  if draw_button("Open Selected Log",x+8,by,(w-20)/2,bottom_h,selected~=nil,clicked,true) then run_base_action(open_selected_log) end
  if draw_button("Copy Selected Build ID",x+12+(w-20)/2,by,(w-20)/2,bottom_h,selected~=nil,clicked,true) then run_base_action(copy_selected_history_id) end
end

function draw_current_status_panel(x,y,w,h)
  set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("text");draw_text("CURRENT ATTEMPT",x+10,y+9,15,true)
  local id=state.current_attempt and state.current_attempt.id or "None"
  set_color(190,197,205);draw_text("ID:",x+10,y+36,12,true);draw_text(fit_text(id,w-55,12),x+38,y+36,12,false)
  draw_text("Build status: "..state.build_status,x+10,y+59,12,true);draw_text("Log status: "..state.log_status,x+10,y+80,12,true)
  if state.original_build_id~="" then draw_text(fit_text("Original build: "..state.original_build_id,w-20,11),x+10,y+102,11,false) end
  local available,reason=undo_available();set_color(available and 145 or 180,available and 225 or 185,available and 165 or 190);draw_text("Undo Last Build: "..(available and "AVAILABLE" or "UNAVAILABLE"),x+10,y+h-40,12,true);set_color(160,165,172);draw_text(fit_text(available and "Exact build is the current REAPER undo action." or reason,w-20,11),x+10,y+h-21,11,false)
end

function draw_comparison_modal(clicked,mouse_down,key)
  if not state.comparison_open then return end
  local large=state.larger_text==true
  state.comparison_focus=state.comparison_focus or 1
  if key==TEXT_KEYS.TAB then state.comparison_focus=state.comparison_focus==1 and 2 or 1;state.last_key=0
  elseif key==TEXT_KEYS.ESCAPE then state.comparison_open=false;quarantine_base_input(0.35);state.last_key=0;return
  elseif key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE then
    if state.comparison_focus==1 then queue_after_mouse_release(view_current_project_comparison)
    else state.comparison_open=false;quarantine_base_input(0.35) end
    state.last_key=0;return
  end
  set_color(0,0,0,0.78);gfx.rect(0,0,gfx.w,gfx.h,true)
  local modal_margin=large and 20 or 32;local x,y=modal_margin,large and 20 or 30;local w,h=gfx.w-modal_margin*2,gfx.h-(large and 40 or 60)
  set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("card_border");gfx.rect(x,y,w,h,false)
  set_color(240,243,246);draw_text("BUILD PREVIEW - NO PROJECT CHANGES",x+18,y+14,21,true)
  set_color(168,174,183);draw_text("Read-only plan showing exactly what a build would preserve, remove, change, and create.",x+18,y+(large and 50 or 42),12,false)
  local button_y=large and y+78 or y+12;local modal_button_h=large and 42 or 32
  if draw_button("Refresh Preview",x+w-340,button_y,170,modal_button_h,true,clicked,true) then queue_after_mouse_release(view_current_project_comparison) end
  draw_focus_outline(x+w-340,button_y,170,modal_button_h,state.comparison_focus==1)
  if draw_button("Close",x+w-158,button_y,130,modal_button_h,true,clicked,true) then
    state.comparison_open=false;quarantine_base_input(0.35);return
  end
  draw_focus_outline(x+w-158,button_y,130,modal_button_h,state.comparison_focus==2)

  local area_x,area_y=x+16,y+(large and 132 or 70);local area_w,area_h=w-32,h-(large and 150 or 88)
  set_ui_color("table_body");gfx.rect(area_x,area_y,area_w,area_h,true)
  gfx.setfont(1,UI.font_name,scaled_font_size(13),0)
  local line_h=large and 27 or 18;local lines=state.comparison_lines or {};local visible=math.max(1,math.floor((area_h-14)/line_h));local max_v=math.max(0,#lines-visible)
  state.comparison_vscroll=math.max(0,math.min(state.comparison_vscroll,max_v))
  local max_text_w=0
  for _,line in ipairs(lines) do max_text_w=math.max(max_text_w,gfx.measurestr(line)) end
  local max_h=math.max(0,max_text_w-(area_w-24));state.comparison_hscroll=math.max(0,math.min(state.comparison_hscroll,max_h))
  for i=1,visible do
    local idx=state.comparison_vscroll+i;local line=lines[idx]
    if line then
      if line=="BUILD OPERATIONS" or line=="NET RESULT" or line=="SUMMARY" then set_color(145,213,255)
      elseif line:match("^[A-Z][A-Z /%-]+$") and #line<70 then set_color(205,215,225)
      elseif line:find("CHANGED:",1,true) then set_color(255,211,125)
      elseif line:find("ADDED:",1,true) then set_color(145,225,165)
      elseif line:find("REMOVED:",1,true) then set_color(255,155,155)
      elseif line:find("UNCHANGED:",1,true) then set_color(175,185,195)
      else set_color(220,224,229) end
      gfx.x=area_x+8-state.comparison_hscroll;gfx.y=area_y+5+(i-1)*line_h;gfx.drawstr(line)
    end
  end
  local vx=area_x+area_w-10;set_ui_color("scroll_track");gfx.rect(vx,area_y,10,area_h-12,true)
  if #lines>visible then
    local thumb=math.max(24,(area_h-12)*visible/#lines);local ty=area_y+(area_h-12-thumb)*(state.comparison_vscroll/max_v);set_ui_color("scroll_thumb");gfx.rect(vx+2,ty,6,thumb,true)
    if clicked and point_inside(vx,area_y,10,area_h-12) then state.comparison_vdrag=true end
    if state.comparison_vdrag then if mouse_down then local ratio=math.max(0,math.min(1,(gfx.mouse_y-area_y-thumb/2)/(area_h-12-thumb)));state.comparison_vscroll=math.floor(ratio*max_v+0.5) else state.comparison_vdrag=false end end
  end
  local hy=area_y+area_h-12;set_ui_color("scroll_track");gfx.rect(area_x,hy,area_w-10,12,true)
  if max_h>0 then
    local thumb=math.max(36,(area_w-10)*(area_w-24)/max_text_w);local tx=area_x+(area_w-10-thumb)*(state.comparison_hscroll/max_h);set_ui_color("scroll_thumb");gfx.rect(tx,hy+3,thumb,6,true)
    if clicked and point_inside(area_x,hy,area_w-10,12) then state.comparison_hdrag=true end
    if state.comparison_hdrag then if mouse_down then local ratio=math.max(0,math.min(1,(gfx.mouse_x-area_x-thumb/2)/(area_w-10-thumb)));state.comparison_hscroll=ratio*max_h else state.comparison_hdrag=false end end
  end
  if gfx.mouse_wheel~=0 and point_inside(area_x,area_y,area_w,area_h) then state.comparison_vscroll=state.comparison_vscroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
end

function draw_confirmation_modal(clicked,key)
  local modal=state.confirm_modal;if not modal then return end
  local large=state.larger_text==true
  set_color(0,0,0,0.72);gfx.rect(0,0,gfx.w,gfx.h,true)
  local w,h=confirmation_modal_geometry(gfx.w,gfx.h,large)
  local x=(gfx.w-w)/2;local y=(gfx.h-h)/2
  set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("card_border");gfx.rect(x,y,w,h,false)
  set_ui_color("text");draw_text("Final Build Confirmation",x+24,y+18,22,true)

  local a=modal.attempt;local s=a.snapshot
  local plan=a.plan
  local items={
    {label="Build ID",value=a.id},
    {text=""},
    {text="AUTOMATIC COUNT-IN AND SONG START",bold=true},
    {label="COUNT IN marker",value="Visible measure 1"},
    {label="Count-in structure",value="Exactly 2 bars of 4/4 (visible measures 1-2)"},
    {label="Count-in BPM",value=format_effective_bpm(plan.count_in_bpm).." BPM"},
    {label="BPM source",value=string.format("Spreadsheet row %d, section %s, section BPM column",plan.count_in_source_row or 0,plan.count_in_source_section or "")},
    {label="First musical part",value=tostring(plan.first_part_canonical or "")},
    {label="First part tempo",value=string.format("Underlying %.2f BPM; effective REAPER %.2f BPM",plan.first_part_underlying_bpm or plan.count_in_bpm,plan.first_part_effective_bpm or plan.count_in_bpm)},
    {label="Spreadsheet start",value="Visible measure "..START_VISIBLE_MEASURE},
    {text=""},
    {text="BUILD OPERATIONS",bold=true},
    {text="• Delete all standard project markers"},
    {text="• Leave all regions untouched"},
    {text="• Preserve tempo-map data before visible measure "..COUNT_IN.visible_measure},
    {text="• Delete tempo/time-signature markers from measure "..COUNT_IN.visible_measure.." onward"},
    {text="• Recreate COUNT IN, validated tempo/meter data, ramps, section markers, and END"},
    {text="• Enable and verify REAPER's native metronome so the generated clicks are audible"},
    {text="• Apply and verify the selected audio-handling policy inside the same undo transaction"},
    {text=""},
    {text="DRY-RUN CHANGE SUMMARY",bold=true},
    {label="Preflight",value=tostring(a.preflight_summary or "Validated immediately before confirmation")},
    {label="Musical structure",value=string.format("%d sections; %d blocks; %d expanded part occurrences; %d musical bars",#plan.sections,plan.block_count or 0,#plan.flat_parts,plan.total_bars)},
    {label="Estimated duration",value=string.format("%s musical content; %s including COUNT IN",format_duration(plan.total_duration or 0),format_duration(plan.total_duration_with_count_in or 0))},
    {label="Click frequencies",value=string.format("A %d Hz; B %d Hz",a.click_a_hz,a.click_b_hz)},
    {label="REAPER metronome",value="Enabled and verified by the build"},
    {label="END",value="Visible measure "..plan.end_visible_measure},
    {label="Markers",value=string.format("Delete %d; create %d",s.markers_to_delete,s.new_markers)},
    {label="Tempo markers",value=string.format("Delete %d; create %d",s.tempo_to_delete,s.new_tempo)},
    {label="Regions",value=tostring(s.regions_preserved).." preserved"},
    {label="Audio mode",value=a.audio_mode==AUDIO_MODE_CONFORM and "Conform Audio to New Tempo — Preserve Pitch" or "Preserve Audio Exactly"},
    {label="Audio impact",value=tostring(a.audio_analysis and a.audio_analysis.summary or "No audio analysis was recorded.")},
    {label="Audio source files",value="Never rewritten or deleted"},
    {label="MIDI/non-audio media",value=tostring(math.max(0,(s.media_items or 0)-((a.audio_analysis and a.audio_analysis.audio_items) or 0))).." item(s); governed by REAPER timebases"},
    {text=""},
    {text=a.prebuild_saved_copy and ("A separate pre-build REAPER .RPP was saved at "..tostring(a.prebuild_saved_path)..".") or "You chose to continue without writing a new pre-build REAPER .RPP copy.",warning=not a.prebuild_saved_copy},
    {text="After successful verification, Bildibeat Click Track Mapper will offer explicit completed REAPER project save choices. Closing that prompt without saving leaves the completed map only in the active in-memory project.",warning=true},
    {text="If any project-changing step or post-build verification fails, the complete undo block is rolled back and the original marker/tempo and audio signatures are checked.",bold=true}
  }

  local area_x,area_y=x+24,y+(large and 64 or 56)
  local footer_h=large and 116 or 94
  local area_w,area_h=w-48,h-(large and 64 or 56)-footer_h
  set_ui_color("table_body");gfx.rect(area_x,area_y,area_w,area_h,true);set_ui_color("divider");gfx.rect(area_x,area_y,area_w,area_h,false)

  local rendered={}
  local label_w=large and 210 or 170
  for _,item in ipairs(items) do
    if item.label then
      local item_value=tostring(item.value or "");local item_mono=looks_like_syntax_text(item_value);local wrapped=wrap_text(item_value,area_w-label_w-34,13,item_mono)
      for i,line in ipairs(wrapped) do
        rendered[#rendered+1]={pair=true,label=i==1 and item.label or "",value=line,bold=item.bold,warning=item.warning,mono=item_mono}
      end
    elseif item.text=="" then
      rendered[#rendered+1]={text="",bold=false,warning=false}
    else
      local wrapped=wrap_text(item.text,area_w-30,13)
      for _,line in ipairs(wrapped) do
        rendered[#rendered+1]={text=line,bold=item.bold,warning=item.warning}
      end
    end
  end

  local line_h=large and 27 or 18
  local visible=math.max(1,math.floor((area_h-12)/line_h))
  local max_scroll=math.max(0,#rendered-visible)
  modal.scroll=math.max(0,math.min(modal.scroll or 0,max_scroll))
  for i=1,visible do
    local row=rendered[modal.scroll+i]
    if row then
      local ry=area_y+6+(i-1)*line_h
      if row.pair then
        set_color(155,165,176);draw_text(row.label,area_x+10,ry,13,true)
        if row.warning then set_color(255,205,120) else set_color(225,230,235) end
        if row.mono then draw_mono_text(row.value,area_x+label_w,ry,12,row.bold) else draw_text(row.value,area_x+label_w,ry,13,row.bold) end
      else
        if row.warning then set_color(255,205,120) else set_color(205,210,216) end
        draw_text(row.text,area_x+10,ry,13,row.bold)
      end
    end
  end

  if #rendered>visible then
    local vx=area_x+area_w-10
    set_ui_color("scroll_track");gfx.rect(vx,area_y,10,area_h,true)
    local thumb=math.max(24,area_h*visible/#rendered)
    local ty=area_y+(area_h-thumb)*(modal.scroll/max_scroll)
    set_ui_color("scroll_thumb");gfx.rect(vx+2,ty,6,thumb,true)
    if gfx.mouse_wheel~=0 and point_inside(area_x,area_y,area_w,area_h) then
      modal.scroll=math.max(0,math.min(max_scroll,modal.scroll-math.floor(gfx.mouse_wheel/120)))
      gfx.mouse_wheel=0
    end
  elseif gfx.mouse_wheel~=0 and point_inside(area_x,area_y,area_w,area_h) then
    gfx.mouse_wheel=0
  end

  local remaining=math.max(0,modal.delay-(reaper.time_precise()-modal.started));local ready=remaining<=0
  modal.focus_slot=modal.focus_slot or 1
  if key==TEXT_KEYS.TAB then modal.focus_slot=modal.focus_slot==1 and 2 or 1;state.last_key=0
  elseif key==TEXT_KEYS.ESCAPE or ((key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE) and modal.focus_slot==1) then
    quarantine_base_input(0.35);queue_after_mouse_release(function() finalize_cancel_dialog(a,"Final destructive-build confirmation","User cancelled the final build confirmation. No project changes were made.") end);state.last_key=0;return
  elseif (key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE) and modal.focus_slot==2 and ready then
    quarantine_base_input(0.35);queue_after_mouse_release(execute_pending_build);state.last_key=0;return
  end
  set_color(ready and 150 or 255,ready and 225 or 205,ready and 165 or 120)
  draw_text(ready and "Confirmation ready." or string.format("Continue enabled in %.1f seconds...",remaining),x+26,y+h-(large and 96 or 80),13,true)
  local confirm_button_h=large and 46 or 38;local confirm_button_w=large and 150 or 120;local confirm_gap=16
  if draw_button("Cancel",x+w-confirm_button_w*2-confirm_gap-30,y+h-confirm_button_h-20,confirm_button_w,confirm_button_h,true,clicked) then
    quarantine_base_input(0.35)
    queue_after_mouse_release(function() finalize_cancel_dialog(a,"Final destructive-build confirmation","User cancelled the final build confirmation. No project changes were made.") end)
    return
  end
  draw_focus_outline(x+w-confirm_button_w*2-confirm_gap-30,y+h-confirm_button_h-20,confirm_button_w,confirm_button_h,modal.focus_slot==1)
  if draw_accent_button("Continue",x+w-confirm_button_w-30,y+h-confirm_button_h-20,confirm_button_w,confirm_button_h,ready,clicked,ready and nil or string.format("The safety delay has %.1f seconds remaining.",remaining)) then
    quarantine_base_input(0.35)
    queue_after_mouse_release(execute_pending_build)
    return
  end
  draw_focus_outline(x+w-confirm_button_w-30,y+h-confirm_button_h-20,confirm_button_w,confirm_button_h,modal.focus_slot==2)
end

function draw_app_modal(clicked,mouse_down,key)
  local modal=state.app_modal;if not modal then return end
  local calendar_clicked,calendar_key=clicked,key;local calendar_was_open=modal.calendar~=nil
  if calendar_was_open then clicked=false;key=0 end
  set_color(0,0,0,0.78);gfx.rect(0,0,gfx.w,gfx.h,true)
  local large=state.larger_text==true;local w,h=app_modal_geometry(gfx.w,gfx.h,large);local x=(gfx.w-w)/2;local y=(gfx.h-h)/2
  set_ui_color("card");gfx.rect(x,y,w,h,true);set_ui_color("card_border");gfx.rect(x,y,w,h,false)
  local accent={info={110,180,240},success={145,225,165},warning={255,205,120},error={255,145,145},input={145,205,255}}
  local c=accent[modal.kind] or accent.info
  set_color(c[1],c[2],c[3]);gfx.rect(x,y,6,h,true)
  set_ui_color("text");draw_text(modal.title,x+24,y+18,21,true)

  local modal_buttons=modal.buttons or {}
  local modal_button_cols=math.max(1,math.min(3,#modal_buttons));local modal_button_rows=math.max(1,math.ceil(#modal_buttons/modal_button_cols));local modal_button_h=large and 46 or 34
  local field_step=large and 68 or 58;local field_box_h=large and 40 or 32
  local base_input_h=modal.fields and (#modal.fields*field_step+12) or (modal.input~=nil and (large and 104 or 86) or 0)
  local checkbox_lines=modal.checkbox and wrap_text(modal.checkbox.label,w-92,12) or {}
  local checkbox_line_h=large and 23 or 17
  local checkbox_h=modal.checkbox and math.max(large and 54 or 42,#checkbox_lines*checkbox_line_h+12) or 0
  local input_h=base_input_h+checkbox_h
  local error_lines=modal.error~="" and wrap_text(modal.error,w-48,12,false) or {}
  local error_line_h=large and 24 or 16;local error_limit=large and modal.fields and #modal.fields>=3 and 3 or 6;local error_visible=math.min(error_limit,#error_lines)
  local error_h=#error_lines>0 and (error_visible*error_line_h+10) or 0
  -- Reserve an explicit gap between long wrapped checkbox/input regions and
  -- the footer buttons at minimum-height Larger Text layouts.
  local buttons_h=34+modal_button_rows*(modal_button_h+10)
  local area_x,area_y=x+24,y+(large and 64 or 58);local area_w=w-48;local area_h=math.max(64,h-(large and 64 or 58)-buttons_h-input_h-error_h)
  set_ui_color("table_body");gfx.rect(area_x,area_y,area_w,area_h,true);set_ui_color("divider");gfx.rect(area_x,area_y,area_w,area_h,false)
  local body_font_size=modal.body_font_size or 13
  local dial_size=modal.custom_dial and math.max(108,math.min(190,area_h-24,math.floor(area_w*0.34))) or 0
  local message_width=modal.custom_dial and math.max(100,area_w-dial_size-46) or area_w-36
  local lines=wrap_styled_source_text(modal.message,message_width,function(line) return not modal.plain_text and looks_like_syntax_text(line) end)
  local line_h=modal.plain_text and (large and 30 or 21) or (large and 26 or 18)
  local visible=math.max(1,math.floor((area_h-12)/line_h));local max_scroll=math.max(0,#lines-visible)
  modal.scroll=math.max(0,math.min(modal.scroll or 0,max_scroll))
  for i=1,visible do
    local line=lines[modal.scroll+i]
    if line then
      set_color(220,224,229)
      if line.mono then draw_mono_text(line.text,area_x+10,area_y+6+(i-1)*line_h,12,false)
      else draw_text(line.text,area_x+10,area_y+6+(i-1)*line_h,body_font_size,false) end
    end
  end
  if #lines>visible then
    local vx=area_x+area_w-10;set_ui_color("scroll_track");gfx.rect(vx,area_y,10,area_h,true)
    local thumb=math.max(24,area_h*visible/#lines);local ty=area_y+(area_h-thumb)*(modal.scroll/max_scroll);set_ui_color("scroll_thumb");gfx.rect(vx+2,ty,6,thumb,true)
    if clicked and point_inside(vx,area_y,10,area_h) then modal.vdrag=true end
    if modal.vdrag then if mouse_down then local ratio=math.max(0,math.min(1,(gfx.mouse_y-area_y-thumb/2)/(area_h-thumb)));modal.scroll=math.floor(ratio*max_scroll+0.5) else modal.vdrag=false end end
  end
  local dial_hover=false
  if modal.custom_dial then
    local cx=area_x+area_w-dial_size/2-14;local cy=area_y+area_h/2;local radius=dial_size/2
    local dx,dy=gfx.mouse_x-cx,gfx.mouse_y-cy;dial_hover=dx*dx+dy*dy<=radius*radius
    if clicked and dial_hover then consume_button_activation(true,true,clicked);state.tempo_dial_dragging=true;state.tempo_dial_start_y=gfx.mouse_y;state.tempo_dial_start_bpm=tonumber(modal.fields and modal.fields[1] and modal.fields[1].value) or state.tempo_audition_bpm end
    if state.tempo_dial_dragging then
      if mouse_down then
        local fine=(gfx.mouse_cap&8)==8;local delta=(state.tempo_dial_start_y-gfx.mouse_y)*(fine and 0.1 or 0.5);set_tempo_modal_bpm(modal,state.tempo_dial_start_bpm+delta)
      else state.tempo_dial_dragging=false end
    end
    if gfx.mouse_wheel~=0 and dial_hover then local fine=(gfx.mouse_cap&8)==8;set_tempo_modal_bpm(modal,(tonumber(modal.fields[1].value) or state.tempo_audition_bpm)+(gfx.mouse_wheel>0 and 1 or -1)*(fine and 0.1 or 1));gfx.mouse_wheel=0 end
    set_color(28,36,44);gfx.circle(cx,cy,radius,true,true);set_ui_color("button_border");gfx.circle(cx,cy,radius,false,true)
    local bpm=tonumber(modal.fields and modal.fields[1] and modal.fields[1].value) or state.tempo_audition_bpm;local ratio=(math.max(TEMPO_AUDITION_MIN_BPM,math.min(TEMPO_AUDITION_MAX_BPM,bpm))-TEMPO_AUDITION_MIN_BPM)/(TEMPO_AUDITION_MAX_BPM-TEMPO_AUDITION_MIN_BPM);local angle=math.rad(225-270*ratio)
    set_ui_color("accent");gfx.line(cx,cy,cx+math.cos(angle)*radius*0.72,cy-math.sin(angle)*radius*0.72)
    set_color(226,234,242);local bpm_label=format_bpm(bpm).." BPM";gfx.setfont(1,UI.font_name,scaled_font_size(14),98);local tw,th=gfx.measurestr(bpm_label);gfx.x=cx-tw/2;gfx.y=cy-th/2;gfx.drawstr(bpm_label)
    if dial_hover then state.hover_context="Tempo dial: drag upward/downward or use the mouse wheel. Hold Shift for one-tenth-BPM adjustments." end
  end
  if gfx.mouse_wheel~=0 and point_inside(area_x,area_y,area_w,area_h) and not dial_hover then modal.scroll=modal.scroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end

  local editable_slots=modal.fields and #modal.fields or (modal.input~=nil and 1 or 0)
  local checkbox_slot=modal.checkbox and (editable_slots+1) or nil
  local input_slots=editable_slots+(modal.checkbox and 1 or 0)
  local total_focus=input_slots+#modal_buttons
  modal.focus_slot=math.max(1,math.min(math.max(1,total_focus),modal.focus_slot or 1))
  if key==TEXT_KEYS.TAB and total_focus>0 then
    local shift=(gfx.mouse_cap&8)==8
    modal.focus_slot=((modal.focus_slot-1+(shift and -1 or 1))%total_focus)+1
    if modal.fields and modal.focus_slot<=#modal.fields then modal.active_field=modal.focus_slot end
    key=0;state.last_key=0
  end
  if key==TEXT_KEYS.ESCAPE then
    local cancel=modal_button_value(modal,"cancel");if cancel then finish_app_modal(cancel);state.last_key=0;return end
  end
  if checkbox_slot and modal.focus_slot==checkbox_slot and (key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE) then
    modal.checkbox.value=not modal.checkbox.value;modal.error="";state.last_key=0;key=0
  end
  local focused_button_index=modal.focus_slot-input_slots
  if focused_button_index>=1 and modal_buttons[focused_button_index] and not modal_buttons[focused_button_index].disabled and (key==TEXT_KEYS.ENTER or key==TEXT_KEYS.SPACE) then
    finish_app_modal(modal_buttons[focused_button_index].value);state.last_key=0;return
  end

  local input_y=area_y+area_h+12
  if modal.fields then
    for i,field in ipairs(modal.fields) do
      local fy=input_y+(i-1)*field_step;local box_y=fy+(large and 24 or 20)
      local box_w=field.date_picker and math.max(120,area_w-132) or area_w
      local value=tostring(field.value or "")
      field.cursor=clamp_text_cursor(value,field.cursor)
      field.anchor=clamp_text_cursor(value,field.anchor or field.cursor)
      local shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,field.view_start,box_w-18,13)
      if clicked and point_inside(area_x,box_y,box_w,field_box_h) then
        modal.active_field=i;modal.focus_slot=i
        local clicked_cursor=editable_cursor_from_x(value,view_start,view_finish,gfx.mouse_x-(area_x+8),13)
        local now=reaper.time_precise();local double_click=field.last_text_click and now-field.last_text_click<0.35 and math.abs(gfx.mouse_x-(field.last_text_click_x or gfx.mouse_x))<=6
        if double_click then
          local first,last=text_word_bounds(value,clicked_cursor);field.anchor=first;field.cursor=last;field.mouse_selecting=false
        else
          if (gfx.mouse_cap&8)~=8 then field.anchor=clicked_cursor end
          field.cursor=clicked_cursor;field.mouse_selecting=true
        end
        field.last_text_click=now;field.last_text_click_x=gfx.mouse_x
        shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,view_start,box_w-18,13)
      end
      if i==modal.active_field and field.mouse_selecting then
        if mouse_down and not clicked then
          if gfx.mouse_x<area_x+8 then field.cursor=previous_text_cursor(value,view_start)
          elseif gfx.mouse_x>area_x+box_w-8 then field.cursor=next_text_cursor(value,view_finish)
          else field.cursor=editable_cursor_from_x(value,view_start,view_finish,gfx.mouse_x-(area_x+8),13) end
          shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,view_start,box_w-18,13)
        elseif not mouse_down then field.mouse_selecting=false end
      elseif i~=modal.active_field then field.mouse_selecting=false end
      field.view_start=view_start
      set_color(205,210,216);draw_text(field.label or ("Field "..i),area_x,fy,12,true)
      set_ui_color("table_body");gfx.rect(area_x,box_y,box_w,field_box_h,true)
      if modal.focus_slot==i then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(area_x,box_y,box_w,field_box_h,false)
      local text_inset=large and 9 or 6;local caret_bottom=box_y+field_box_h-(large and 7 or 6)
      draw_editable_selection(value,field.cursor,field.anchor,view_start,view_finish,area_x+8,box_y+text_inset,field_box_h-text_inset*2,13)
      set_color(235,238,242);draw_text(shown,area_x+8,box_y+(large and 9 or 8),13,false)
      if modal.focus_slot==i and math.floor(reaper.time_precise()*2)%2==0 then set_color(235,238,242);gfx.line(area_x+9+caret_x,box_y+text_inset,area_x+9+caret_x,caret_bottom) end
      if point_inside(area_x,box_y,box_w,field_box_h) then state.hover_context=field.help or (field.date_picker and "Type a date in MM-DD-YYYY format, or open the calendar." or ("Edit "..tostring(field.label or "this field").."; click to place the caret and use standard selection/clipboard shortcuts.")) end
      if field.date_picker then
        if draw_button("Calendar...",area_x+box_w+8,box_y,124,field_box_h,true,clicked,true) then modal.active_field=i;modal.focus_slot=i;open_modal_calendar(modal,i) end
      end
    end
    if key and key~=0 and modal.focus_slot<=#modal.fields then
      local field=modal.fields[modal.active_field]
      local ctrl=(gfx.mouse_cap&4)==4;local shift=(gfx.mouse_cap&8)==8
      if key==TEXT_KEYS.ENTER then
        if field and field.date_picker then open_modal_calendar(modal,modal.active_field);state.last_key=0
        else local primary=modal_button_value(modal,"primary");if primary then finish_app_modal(primary);state.last_key=0;return end end
      elseif field then
        local value,cursor,anchor,changed,handled,clipboard_status,clipboard_error=edit_text_with_clipboard(field.value or "",field.cursor,field.anchor,key,ctrl,shift)
        if handled then
          field.value=value;field.cursor=cursor;field.anchor=anchor
          if clipboard_status then set_status(clipboard_status,"success") end
          if clipboard_error then modal.error=clipboard_error end
          if changed then modal.error="";if modal.on_change then modal.on_change(modal.fields,modal.active_field) end end
        end
      end
    end
  elseif modal.input~=nil then
    set_color(205,210,216);draw_text(modal.input_label,area_x,input_y,12,true)
    local input_box_h=large and 42 or 34;local box_y=input_y+(large and 28 or 23);set_ui_color("table_body");gfx.rect(area_x,box_y,area_w,input_box_h,true);if modal.focus_slot==1 then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(area_x,box_y,area_w,input_box_h,false)
    if point_inside(area_x,box_y,area_w,input_box_h) then state.hover_context=(modal.input_hint~="" and modal.input_hint or ("Edit "..tostring(modal.input_label~="" and modal.input_label or "this value").."; click to place the caret and use standard selection/clipboard shortcuts.")) end
    modal.input_cursor=clamp_text_cursor(modal.input,modal.input_cursor)
    modal.input_anchor=clamp_text_cursor(modal.input,modal.input_anchor or modal.input_cursor)
    local shown,view_start,view_finish,caret_x=editable_text_view(modal.input,modal.input_cursor,modal.input_view_start,area_w-18,13)
    if clicked and point_inside(area_x,box_y,area_w,input_box_h) then
      modal.focus_slot=1
      local clicked_cursor=editable_cursor_from_x(modal.input,view_start,view_finish,gfx.mouse_x-(area_x+8),13)
      local now=reaper.time_precise();local double_click=modal.last_text_click and now-modal.last_text_click<0.35 and math.abs(gfx.mouse_x-(modal.last_text_click_x or gfx.mouse_x))<=6
      if double_click then
        local first,last=text_word_bounds(modal.input,clicked_cursor);modal.input_anchor=first;modal.input_cursor=last;modal.input_mouse_selecting=false
      else
        if (gfx.mouse_cap&8)~=8 then modal.input_anchor=clicked_cursor end
        modal.input_cursor=clicked_cursor;modal.input_mouse_selecting=true
      end
      modal.last_text_click=now;modal.last_text_click_x=gfx.mouse_x
      shown,view_start,view_finish,caret_x=editable_text_view(modal.input,modal.input_cursor,view_start,area_w-18,13)
    end
    if modal.input_mouse_selecting then
      if mouse_down and not clicked then
        if gfx.mouse_x<area_x+8 then modal.input_cursor=previous_text_cursor(modal.input,view_start)
        elseif gfx.mouse_x>area_x+area_w-8 then modal.input_cursor=next_text_cursor(modal.input,view_finish)
        else modal.input_cursor=editable_cursor_from_x(modal.input,view_start,view_finish,gfx.mouse_x-(area_x+8),13) end
        shown,view_start,view_finish,caret_x=editable_text_view(modal.input,modal.input_cursor,view_start,area_w-18,13)
      elseif not mouse_down then modal.input_mouse_selecting=false end
    end
    modal.input_view_start=view_start
    local input_text_y=large and 10 or 7
    draw_editable_selection(modal.input,modal.input_cursor,modal.input_anchor,view_start,view_finish,area_x+8,box_y+input_text_y,input_box_h-input_text_y*2,13)
    set_color(235,238,242);draw_text(shown,area_x+8,box_y+(large and 10 or 9),13,false)
    if modal.focus_slot==1 and math.floor(reaper.time_precise()*2)%2==0 then set_color(235,238,242);gfx.line(area_x+9+caret_x,box_y+input_text_y,area_x+9+caret_x,box_y+input_box_h-input_text_y) end
    if key and key~=0 and modal.focus_slot==1 then
      if key==TEXT_KEYS.ENTER then
        local primary=modal_button_value(modal,"primary");if primary then finish_app_modal(primary);state.last_key=0;return end
      else
        local ctrl=(gfx.mouse_cap&4)==4;local shift=(gfx.mouse_cap&8)==8
        local value,cursor,anchor,changed,handled,clipboard_status,clipboard_error=edit_text_with_clipboard(modal.input,modal.input_cursor,modal.input_anchor,key,ctrl,shift)
        if handled then
          modal.input=value;modal.input_cursor=cursor;modal.input_anchor=anchor
          if clipboard_status then set_status(clipboard_status,"success") end
          if clipboard_error then modal.error=clipboard_error end
          if changed then modal.error="" end
        end
      end
    end
  elseif key and key~=0 and key==TEXT_KEYS.ENTER then local primary=modal_button_value(modal,"primary");if primary then finish_app_modal(primary);state.last_key=0;return end
  end

  if modal.checkbox then
    local checkbox_y=input_y+base_input_h
    local hover=point_inside(area_x,checkbox_y,area_w,checkbox_h)
    if hover then state.hover_context=modal.checkbox.help~="" and modal.checkbox.help or modal.checkbox.label end
    if hover then set_ui_color("button_hover") else set_ui_color("button") end;gfx.rect(area_x,checkbox_y,area_w,checkbox_h,true)
    if modal.focus_slot==checkbox_slot then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(area_x,checkbox_y,area_w,checkbox_h,false)
    local check_size=large and 24 or 18;local check_x=area_x+10;local check_y=checkbox_y+(checkbox_h-check_size)/2
    set_ui_color("table_body");gfx.rect(check_x,check_y,check_size,check_size,true);set_ui_color("accent");gfx.rect(check_x,check_y,check_size,check_size,false)
    if modal.checkbox.value then set_color(130,225,150);gfx.line(check_x+4,check_y+check_size*0.55,check_x+check_size*0.43,check_y+check_size-5);gfx.line(check_x+check_size*0.43,check_y+check_size-5,check_x+check_size-4,check_y+4) end
    set_color(218,225,232)
    for line_index,line in ipairs(checkbox_lines) do draw_text(line,check_x+check_size+10,checkbox_y+6+(line_index-1)*checkbox_line_h,12,false) end
    if clicked and hover then consume_button_activation(true,true,clicked);modal.focus_slot=checkbox_slot;modal.checkbox.value=not modal.checkbox.value;modal.error="" end
  end

  if #error_lines>0 then
    local max_error_scroll=math.max(0,#error_lines-error_visible);modal.error_scroll=math.max(0,math.min(modal.error_scroll or 0,max_error_scroll));set_color(255,145,145)
    local error_y=input_y+input_h-4
    for i=1,error_visible do local line=error_lines[modal.error_scroll+i];if line then draw_text(line,area_x,error_y+(i-1)*error_line_h,12,true) end end
    if max_error_scroll>0 then
      local sx=area_x+area_w-8;set_ui_color("scroll_track");gfx.rect(sx,error_y,8,error_h-6,true);local thumb=math.max(14,(error_h-6)*error_visible/#error_lines);local sy=error_y+(error_h-6-thumb)*(modal.error_scroll/max_error_scroll);set_ui_color("scroll_thumb");gfx.rect(sx+1,sy,6,thumb,true)
      if gfx.mouse_wheel~=0 and point_inside(area_x,error_y,area_w,error_h) then modal.error_scroll=modal.error_scroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
    end
  end
  local buttons=modal_buttons;local gap=12;local bw=math.floor((area_w-gap*(modal_button_cols-1))/modal_button_cols);local first_by=y+h-14-modal_button_rows*(modal_button_h+10)
  for button_index,b in ipairs(buttons) do
    local row=math.floor((button_index-1)/modal_button_cols);local col=(button_index-1)%modal_button_cols;local row_first=row*modal_button_cols+1;local row_count=math.min(modal_button_cols,#buttons-row_first+1);local row_width=row_count*bw+(row_count-1)*gap
    local bx=x+(w-row_width)/2+col*(bw+gap);local by=first_by+row*(modal_button_h+10)
    local activated
    local enabled=not b.disabled
    if b.primary then activated=draw_accent_button(b.label,bx,by,bw,modal_button_h,enabled,clicked,b.disabled_reason)
    else activated=draw_button(b.label,bx,by,bw,modal_button_h,enabled,clicked,true,b.disabled_reason) end
    draw_focus_outline(bx,by,bw,modal_button_h,modal.focus_slot==input_slots+button_index and enabled)
    if activated then finish_app_modal(b.value);return end
  end
  if modal.calendar then draw_modal_calendar(modal,calendar_clicked,calendar_was_open and calendar_key or 0) end
end

function show_help_center()
  show_info("Bildibeat Click Track Mapper Help",HELP_TEXT,"info")
end

function show_settings()
  open_app_modal({title="Settings",message="Use the Settings page for Preview Table, Logging, Workspace, and Advanced controls.",kind="info",buttons={{label="Close",value="CLOSE",primary=true,cancel=true}}})
end

function draw_card(x,y,w,h,title,subtitle,dense_header)
  set_ui_color("card");gfx.rect(x,y,w,h,true)
  set_ui_color("card_border");gfx.rect(x,y,w,h,false)
  local large=state.larger_text==true
  if title then set_ui_color("text");draw_text(title,x+18,y+(dense_header and 8 or large and 10 or 14),dense_header and 15 or 17,true) end
  if subtitle and not dense_header then
    set_ui_color("muted")
    local lines=wrap_text(subtitle,w-36,12);local max_lines=large and gfx.h>=800 and 2 or 1;local line_h=large and 20 or 17
    for index=1,math.min(max_lines,#lines) do draw_text(index==max_lines and #lines>max_lines and fit_text(lines[index].." ...",w-36,12) or lines[index],x+18,y+(large and 46 or 39)+(index-1)*line_h,12,false) end
  end
end

function draw_pill(label,x,y,w,kind)
  local color_name=kind=="good" and "good" or kind=="bad" and "bad" or kind=="warn" and "warning" or "accent"
  set_color(26,33,41);gfx.rect(x,y,w,26,true)
  set_ui_color("button_border");gfx.rect(x,y,w,26,false)
  local c=UI.colors[color_name];local cy=y+13
  set_color(c[1],c[2],c[3]);gfx.circle(x+14,cy,6,false,true)
  if kind=="good" then gfx.line(x+11,cy,x+13,cy+2);gfx.line(x+13,cy+2,x+17,cy-3)
  elseif kind=="bad" then gfx.line(x+11,cy-3,x+17,cy+3);gfx.line(x+17,cy-3,x+11,cy+3)
  elseif kind=="warn" then draw_text("!",x+12,y+5,11,true) end
  local font_size=state.larger_text and UI.layout and UI.layout.compact and 9 or 11
  local shown=fit_text(label,math.max(8,w-31),font_size,true);set_ui_color("text");gfx.setfont(1,UI.font_name,scaled_font_size(font_size),98)
  local tw,th=gfx.measurestr(shown);local tx=math.max(x+27,x+(w-tw)/2+7);gfx.x=tx;gfx.y=y+(26-th)/2;gfx.drawstr(shown)
end

function draw_nav_icon(view,cx,cy,active)
  if active then set_color(219,235,249) else set_color(150,163,176) end
  if view=="BUILD" then
    gfx.rect(cx-9,cy+2,4,8,false);gfx.rect(cx-2,cy-5,4,15,false);gfx.rect(cx+5,cy-1,4,11,false);gfx.line(cx-11,cy+10,cx+11,cy+10)
  elseif view=="HISTORY" then
    gfx.circle(cx,cy,10,false,true);gfx.line(cx,cy,cx,cy-6);gfx.line(cx,cy,cx+5,cy+3)
  elseif view=="SETTINGS" then
    gfx.line(cx-10,cy-7,cx+10,cy-7);gfx.circle(cx-3,cy-7,2,true,true)
    gfx.line(cx-10,cy,cx+10,cy);gfx.circle(cx+5,cy,2,true,true)
    gfx.line(cx-10,cy+7,cx+10,cy+7);gfx.circle(cx-6,cy+7,2,true,true)
  elseif view=="TEMPO" then
    gfx.line(cx-9,cy+9,cx-5,cy-8);gfx.line(cx-5,cy-8,cx+5,cy-8);gfx.line(cx+5,cy-8,cx+9,cy+9);gfx.line(cx-9,cy+9,cx+9,cy+9)
    gfx.line(cx,cy+5,cx+4,cy-5);gfx.circle(cx,cy+5,2,true,true)
  else
    gfx.circle(cx,cy,10,false,true);draw_text("?",cx-3,cy-8,14,true)
  end
end

function draw_nav_button(label,view,x,y,w,h,clicked)
  local active=state.active_view==view
  local hover=point_inside(x,y,w,h)
  local focused,keyboard_activate,focus_index=register_focus_control(label.." page",true)
  if hover then state.hover_context="Open the "..label.." page." end
  if active then set_color(29,39,49) elseif hover then set_color(25,33,41) else set_ui_color("sidebar") end
  gfx.rect(x,y,w,h,true)
  if active then set_ui_color("accent");gfx.rect(x,y,3,h,true) end
  draw_nav_icon(view,x+28,y+math.floor(h/2),active)
  if active then set_ui_color("text") else set_color(190,199,209) end
  gfx.setfont(1,UI.font_name,scaled_font_size(14),active and 98 or 0);local _,label_h=gfx.measurestr(label)
  draw_text(label,x+50,y+math.floor((h-label_h)/2),14,active)
  draw_focus_outline(x+4,y+4,w-8,h-8,focused)
  local mouse_activated=consume_button_activation(true,hover,clicked)
  if mouse_activated and focus_index then state.focus_index=focus_index end
  if mouse_activated or keyboard_activate then
    if view~="HELP" and state.audio_preview and state.audio_preview.owner=="scratchpad" then stop_audio_preview(true) end
    state.active_view=view;state.row_popover=nil
    if view~="HELP" then state.scratchpad_has_focus=false;state.scratchpad_focus=0 end
    if state.remember_last_page then reaper.SetExtState(EXTSTATE_SECTION,"active_view",view,true) end
    set_status("Opened "..label..".","info")
  end
end

function draw_sidebar_close(x,y,w,h,clicked)
  local hover=point_inside(x,y,w,h)
  local enabled=not state.operation_busy;local focused,keyboard_activate,focus_index=register_focus_control("Close",enabled)
  if hover then state.hover_context=button_help_text("Close",enabled,state.operation_busy and "A workbook or build operation is still running." or nil) end
  if hover and not state.operation_busy then set_color(27,35,43);gfx.rect(x,y,w,h,true) end
  if state.operation_busy then set_color(91,101,112) else set_color(174,185,196) end
  gfx.circle(x+18,y+math.floor(h/2),9,false,true)
  gfx.line(x+14,y+math.floor(h/2)-4,x+22,y+math.floor(h/2)+4);gfx.line(x+22,y+math.floor(h/2)-4,x+14,y+math.floor(h/2)+4)
  gfx.setfont(1,UI.font_name,scaled_font_size(14),0);local _,label_h=gfx.measurestr("Close")
  draw_text("Close",x+40,y+math.floor((h-label_h)/2),14,false)
  draw_focus_outline(x,y,w,h,focused and enabled)
  local mouse_activated=consume_button_activation(enabled,hover,clicked)
  if mouse_activated and focus_index then state.focus_index=focus_index end
  if mouse_activated or keyboard_activate then
    if tempo_edits_empty(state.tempo_edits) then state.close_requested=true
    else confirm_discard_staged_edits("Closing Bildibeat Click Track Mapper","Close and Discard Edits",function()intentionally_discard_tempo_recovery();state.close_requested=true end) end
  end
end

function draw_readiness_check(label,ok,x,y,w,reason,dense_height)
  local check_h=tonumber(dense_height) or (state.larger_text and 30 or 20);local cy=y+math.floor(check_h/2);local dense=dense_height~=nil
  if point_inside(x,y,w,check_h) then
    if ok and label=="REAPER project saved at least once" then state.hover_context="The active REAPER project has been saved as an .RPP file at least once. Current REAPER changes may still need to be saved."
    else state.hover_context=ok and (label.." is ready.") or (label.." is not ready: "..tostring(reason or "its prerequisite has not been met.")) end
  end
  local c=ok and UI.colors.good or UI.colors.bad
  local radius=dense and 6 or 8;set_color(c[1],c[2],c[3]);gfx.circle(x+9,cy,radius,false,true)
  if ok then gfx.line(x+6,cy,x+8,cy+2);gfx.line(x+8,cy+2,x+12,cy-3) else draw_text("!",x+7,y+math.max(0,math.floor((check_h-16)/2)),dense and 11 or 12,true) end
  if ok then set_color(214,223,231) else set_color(230,177,177) end
  local font_size=dense and 11 or 12;gfx.setfont(1,UI.font_name,scaled_font_size(font_size),0);local _,th=gfx.measurestr("Ag")
  draw_text(fit_text(label,w-28,font_size),x+28,y+(check_h-th)/2,font_size,false)
end

function draw_tempo_preview_field(x,y,w,h,clicked,mouse_down)
  local field=state.tempo_preview_field;local value=tostring(field.value or "")
  field.cursor=clamp_text_cursor(value,field.cursor);field.anchor=clamp_text_cursor(value,field.anchor or field.cursor)
  local shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,field.view_start,w-16,13,false)
  local hover=point_inside(x,y,w,h)
  if hover then state.hover_context="Enter an underlying musical BPM from 20 through 400; press Enter or choose Play to hear the looping Tempo Preview." end
  if clicked then
    if hover then
      consume_button_activation(true,true,clicked);state.tempo_preview_has_focus=true
      local clicked_cursor=editable_cursor_from_x(value,view_start,view_finish,gfx.mouse_x-(x+7),13,false)
      if (gfx.mouse_cap&8)~=8 then field.anchor=clicked_cursor end;field.cursor=clicked_cursor;field.mouse_selecting=true
      shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,view_start,w-16,13,false)
    else state.tempo_preview_has_focus=false;field.mouse_selecting=false end
  end
  if state.tempo_preview_has_focus and field.mouse_selecting then
    if mouse_down and not clicked then
      field.cursor=editable_cursor_from_x(value,view_start,view_finish,gfx.mouse_x-(x+7),13,false)
      shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,view_start,w-16,13,false)
    elseif not mouse_down then field.mouse_selecting=false end
  end
  field.view_start=view_start
  set_ui_color("table_body");gfx.rect(x,y,w,h,true);if state.tempo_preview_has_focus then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(x,y,w,h,false)
  local inset=math.max(5,math.floor((h-18)/2));draw_editable_selection(value,field.cursor,field.anchor,view_start,view_finish,x+7,y+inset,h-inset*2,13,false)
  set_ui_color("text");draw_text(shown,x+7,y+math.max(5,math.floor((h-18)/2)),13,false)
  if state.tempo_preview_has_focus and math.floor(reaper.time_precise()*2)%2==0 then set_ui_color("text");gfx.line(x+8+caret_x,y+6,x+8+caret_x,y+h-6) end
end

function draw_header(content_x,content_w,base_clicked)
  local layout=UI.layout or responsive_layout(gfx.w,gfx.h)
  set_ui_color("header");gfx.rect(content_x,0,content_w,layout.header_bar_height,true)
  set_ui_color("text");draw_text("BILDIBEAT CLICK TRACK MAPPER",content_x+20,state.larger_text and 7 or 13,23,true)
  set_ui_color("muted");draw_text("Build reliable REAPER tempo maps from XLSX or CSV",content_x+20,state.larger_text and 50 or 42,12,false)
  if SAFE_MODE then
    local safe_w=state.larger_text and 122 or 94
    draw_pill("SAFE MODE",content_x+content_w-safe_w-24,22,safe_w,"warn")
  end
end

function draw_build_view(content_x,content_y,content_w,content_h,base_clicked,mouse_down,base_right_clicked)
  local layout=UI.layout or responsive_layout(gfx.w,gfx.h);local gap=layout.card_gap
  local active=get_active_project_info();local saved=project_is_saved(active);local same_project=state.plan and state.validation_project and active and active.pointer==state.validation_project.pointer
  local ready=state.plan~=nil and not state.preview_stale and not state.project_changed and same_project and saved and state.environment_ok and state.dry_run~=nil and not state.dry_run_stale

  local workbook_h=layout.workbook_h
  draw_card(content_x,content_y,content_w,workbook_h,"Workbook")
  local badge_gap=layout.compact and 6 or 10;local badge_scale=math.max(0.78,math.min(1,content_w/900));local badge_w1,badge_w2,badge_w3=math.floor(118*badge_scale),math.floor(114*badge_scale),math.floor(104*badge_scale)
  if state.larger_text then badge_w1,badge_w2,badge_w3=132,128,124 end
  local px=content_x+content_w-18-(badge_w1+badge_w2+badge_w3+badge_gap*2)
  local workbook_name=state.file_path~="" and (state.show_full_path and state.file_path or basename(state.file_path)) or "Choose a saved XLSX or CSV workbook"
  set_ui_color("muted")
  if state.larger_text then draw_text(fit_text(workbook_name,math.max(140,px-content_x-36),12),content_x+18,content_y+48,12,false)
  else draw_text(fit_text(workbook_name,math.max(140,px-content_x-130),12),content_x+116,content_y+18,12,false) end
  draw_pill(state.file_path~="" and "FILE LOADED" or "NO FILE",px,content_y+14,badge_w1,state.file_path~="" and "good" or "bad")
  draw_pill(state.plan and "VALIDATED" or "VALIDATE",px+badge_w1+badge_gap,content_y+14,badge_w2,state.plan and "good" or "warn")
  draw_pill(ready and "READY" or "NOT READY",px+badge_w1+badge_w2+badge_gap*2,content_y+14,badge_w3,ready and "good" or "bad")
  if point_inside(px,content_y+14,badge_w1,26) then
    state.hover_context=state.file_path~="" and ("File Loaded: "..basename(state.file_path).." was found and read into the current workspace.") or "No File: choose a saved XLSX or CSV workbook."
  elseif point_inside(px+badge_w1+badge_gap,content_y+14,badge_w2,26) then
    state.hover_context=state.plan and "Validated: the current workbook contents passed parser and workbook validation." or (state.file_path=="" and "Validate: choose a workbook first." or (#state.errors>0 and "Validation did not pass. Open Validation Issues for the exact errors and fixes." or "Validate: choose Validate Only to check the current workbook."))
  elseif point_inside(px+badge_w1+badge_w2+badge_gap*2,content_y+14,badge_w3,26) then
    local missing={};if not state.plan then missing[#missing+1]="workbook validation" end;if state.preview_stale then missing[#missing+1]="current workbook validation" end;if state.project_changed or not same_project then missing[#missing+1]="matching active REAPER project" end;if not saved then missing[#missing+1]="a REAPER project saved at least once" end;if not state.dry_run or state.dry_run_stale then missing[#missing+1]="current automatic REAPER project check" end;if not state.environment_ok then missing[#missing+1]="environment checks" end
    state.hover_context=ready and "Ready: every workbook, automatic REAPER-project check, project, and environment prerequisite for Build has passed." or ("Not Ready: complete "..table.concat(missing,", ")..".")
  end
  local bx=content_x+18;local by=content_y+layout.workbook_controls_y;local control_gap=layout.compact and 7 or 10
  local controls_available=content_w-36-control_gap*4
  local browse_w=math.max(78,math.floor(controls_available*0.12));local recent_w=math.max(100,math.floor(controls_available*0.15));local validate_w=math.max(112,math.floor(controls_available*0.17));local project_compare_w=math.max(160,math.floor(controls_available*0.24))
  local reconstruct_w=math.max(150,controls_available-browse_w-recent_w-validate_w-project_compare_w)
  local browse_label=state.larger_text and layout.compact and "Browse" or "Browse..."
  local recent_label=state.larger_text and layout.compact and "Recent" or layout.compact and "Recent..." or "Recent Files..."
  local validate_label=state.larger_text and layout.compact and "Validate" or "Validate Only"
  if draw_button(browse_label,bx,by,browse_w,36,true,base_clicked) then run_base_action(choose_file) end
  local recent_x=bx+browse_w+control_gap
  if draw_button(recent_label,recent_x,by,recent_w,36,#state.recent_files>0,base_clicked) then run_base_action(choose_recent_file) end
  local validate_x=recent_x+recent_w+control_gap
  if draw_accent_button(validate_label,validate_x,by,validate_w,36,state.file_path~="" and not state.operation_busy,base_clicked) then run_base_action(validate_and_preview) end
  local project_compare_x=validate_x+validate_w+control_gap
  local project_compare_label=(not state.plan and #state.errors>0) and "Validation Issues" or (state.larger_text and layout.compact and "Project Match" or layout.compact and "Compare Open Project" or "Validate Against Open Project")
  local project_compare_ok,project_compare_reason=project_comparison_available()
  if project_compare_label=="Validation Issues" then project_compare_ok=true;project_compare_reason=nil end
  if draw_button(project_compare_label,project_compare_x,by,project_compare_w,36,project_compare_ok,base_clicked,layout.compact,project_compare_reason) then run_base_action(project_compare_label=="Validation Issues" and show_validation_issues or validate_against_open_project) end
  local reconstruct_x=project_compare_x+project_compare_w+control_gap
  local reconstruct_project=get_active_project_info()
  local reconstruct_ok=reconstruct_project and reconstruct_project.proj and not state.operation_busy
  local reconstruct_reason=reconstruct_ok and nil or (state.operation_busy and "Wait for the current workbook, export, logging, or build operation to finish." or "Open a REAPER project first.")
  local reconstruct_label=state.larger_text and layout.compact and "Create Workbook" or layout.compact and "Create From Project..." or "Create Verified Workbook From Open Project..."
  if draw_accent_button(reconstruct_label,reconstruct_x,by,reconstruct_w,36,reconstruct_ok,base_clicked,reconstruct_reason) then run_base_action(create_workbook_from_open_project) end

  local bottom_h=layout.bottom_h
  local preview_y=content_y+workbook_h+gap
  local preview_h=content_h-workbook_h-bottom_h-gap*2
  local preview_subtitle="Validate a workbook to populate the preview"
  if state.plan then
    if state.larger_text and layout.compact then preview_subtitle=string.format("COUNT IN %.2f BPM  •  Start 3  •  %d sections  •  %d parts  •  %d bars  •  END %d",state.plan.count_in_bpm,#state.plan.sections,#state.plan.flat_parts,state.plan.total_bars,state.plan.end_visible_measure)
    else preview_subtitle=string.format("COUNT IN 1-2 at %.2f BPM from row %d / %s  •  First part %.2f effective BPM  •  Song starts 3  •  %d sections  •  %d blocks  •  %d expanded parts  •  %d musical bars  •  END %d",state.plan.count_in_bpm,state.plan.count_in_source_row or 0,state.plan.count_in_source_section or "",state.plan.first_part_effective_bpm or state.plan.count_in_bpm,#state.plan.sections,state.plan.block_count or 0,#state.plan.flat_parts,state.plan.total_bars,state.plan.end_visible_measure) end
  end
  if state.plan_was_undone then preview_subtitle=preview_subtitle.."  •  DISPLAYED PLAN IS NOT CURRENTLY APPLIED TO REAPER" end
  draw_card(content_x,preview_y,content_w,preview_h,"Validated Preview",preview_subtitle)
  local tempo_modified=not tempo_edits_empty(state.tempo_edits)
  local preview_hint=state.larger_text and layout.compact and "Up/Down selects  •  Shift extends  •  Double-click jumps  •  Right-click/Enter opens actions" or state.larger_text and "Click or Up/Down: select  •  Shift-click or Shift+Up/Down: extend  •  Double-click: jump  •  Right-click or Enter: actions  •  Home/End: first/last" or "Mouse: Click selects | Shift-click selects a range | Double-click jumps | Right-click opens actions\nKeyboard: Up/Down selects | Shift+Up/Down extends | Home/End selects first/last | Enter opens actions"
  local hint_lines=wrap_text(preview_hint,content_w-48,12)
  local table_y=preview_y+layout.preview_table_top
  local footer=preview_footer_layout(preview_y,preview_h,table_y,#hint_lines,state.larger_text)
  draw_preview_table(content_x+18,table_y,content_w-36,footer.table_h,base_clicked,mouse_down,base_right_clicked)
  set_ui_color("divider");gfx.line(content_x+18,footer.footer_top,content_x+content_w-18,footer.footer_top)
  local audition_ok,audition_reason=audition_build_matches()
  local selected_first,selected_last=selected_preview_range();local has_selection=selected_first~=nil
  local control_y=footer.controls_y;local control_h=footer.controls_h;local control_gap=8;local play_w=88;local stop_w=88;local loop_w=124;local speed_w=150
  local control_x=content_x+20
  if draw_button("Play",control_x,control_y,play_w,control_h,audition_ok and has_selection and not state.operation_busy,base_clicked,true) then run_base_action(play_audition) end
  control_x=control_x+play_w+control_gap
  if draw_button("Stop",control_x,control_y,stop_w,control_h,state.audition_active or (audition_ok and has_selection),base_clicked,true) then stop_audition() end
  control_x=control_x+stop_w+control_gap
  if draw_button("Loop: "..(state.audition_loop and "On" or "Off"),control_x,control_y,loop_w,control_h,audition_ok,base_clicked,true) then
    state.audition_loop=not state.audition_loop
    if state.audition_active and state.audition_restore then reaper.GetSetRepeatEx(state.audition_restore.proj,state.audition_loop and 1 or 0) end
    set_status("Audition looping "..(state.audition_loop and "enabled." or "disabled."),"info")
  end
  control_x=control_x+loop_w+control_gap
  if draw_button("50% Speed: "..(state.audition_half_speed and "On" or "Off"),control_x,control_y,speed_w,control_h,audition_ok,base_clicked,true) then
    state.audition_half_speed=not state.audition_half_speed
    if state.audition_active and state.audition_restore then
      if state.audition_half_speed then
        if set_project_int_config(state.audition_restore.proj,"audioprshift",1) then reaper.CSurf_OnPlayRateChange(0.5)
        else state.audition_half_speed=false;show_info("50% Speed Unavailable","SWS/S&M could not enable Preserve pitch in audio items. The current audition remains at its original speed.","warning") end
      else reaper.CSurf_OnPlayRateChange(state.audition_restore.playrate);if state.audition_restore.preserve_pitch~=nil then set_project_int_config(state.audition_restore.proj,"audioprshift",state.audition_restore.preserve_pitch) end end
    end
    set_status("50% audition speed "..(state.audition_half_speed and "enabled; audio pitch will be preserved temporarily." or "disabled."),"info")
  end
  local selection_label=has_selection and (selected_first==selected_last and ("Selected row "..selected_first) or ("Selected rows "..selected_first.."-"..selected_last)) or "Select one or more Preview rows"
  if not audition_ok then
    if state.larger_text and layout.compact then selection_label=has_selection and (selection_label.."  •  Audition unavailable") or "Audition unavailable"
    else selection_label=selection_label..(layout.compact and "  •  Audition unavailable" or (" | Audition unavailable: "..tostring(audition_reason))) end
  end
  set_ui_color("muted");draw_text(fit_text(selection_label,math.max(80,content_x+content_w-20-(control_x+speed_w+14)),11),control_x+speed_w+14,control_y+math.floor((control_h-15)/2),11,false)
  set_ui_color("muted");for i,line in ipairs(hint_lines) do draw_text(line,content_x+20,footer.hint_y+(i-1)*footer.line_h,12,false) end

  local action_y=preview_y+preview_h+gap
  local left_w=math.floor((content_w-gap)*0.56)
  local has_validation_errors=not state.plan and #state.errors>0
  local action_subtitle=has_validation_errors and "Select a row, then right-click or press Enter for its complete explanation and actions" or nil
  draw_card(content_x,action_y,left_w,bottom_h,has_validation_errors and "Validation Issue Actions" or "Build & Project",action_subtitle)
  local can_build=ready and not state.operation_busy
  local can_undo=select(1,undo_available()) and not state.operation_busy
  local selected_row=state.selected_preview_row and state.preview_rows[state.selected_preview_row] or nil
  local inner_x=content_x+18;local inner_w=left_w-36
  if has_validation_errors then
    local display_rows=preview_display_rows();selected_row=state.selected_preview_row and display_rows[state.selected_preview_row] or nil
    local issue=selected_row and selected_row.issue or nil
    local issue_note=issue and preview_row_blurb(selected_row) or "Select an error row in the table above."
    local issue_lines=wrap_text(issue_note,left_w-36,12);set_ui_color("muted")
    for i=1,math.min(2,#issue_lines) do draw_text(issue_lines[i],content_x+18,action_y+layout.action_note_y+3+(i-1)*(state.larger_text and 18 or 16),12,false) end
    local major_gap=12;local major_w=math.floor((inner_w-major_gap)/2)
    local open_x=inner_x;local open_w=inner_w
    if issue and issue.correction then
      if draw_primary_button("Copy Corrected Cell",inner_x,action_y+layout.action_major_y,major_w,layout.action_major_h,not state.operation_busy,base_clicked) then run_base_action(function()confirm_copy_validation_correction(issue)end) end
      open_x=inner_x+major_w+major_gap;open_w=inner_w-major_w-major_gap
    end
    if draw_button("Open Workbook",open_x,action_y+layout.action_major_y,open_w,layout.action_major_h,state.file_path~="" and not state.operation_busy,base_clicked) then run_base_action(open_selected_workbook) end
    if draw_button("All Validation Issues",inner_x,action_y+layout.action_small_y,inner_w,layout.action_small_h,true,base_clicked,true) then run_base_action(show_validation_issues) end
  else
    local note_h=layout.compact and 28 or 32
    local action_compact=layout.compact
    local compact_side_w=state.larger_text and 112 or 120
    local note_button_w=action_compact and math.min(compact_side_w,math.floor((inner_w-24)/3)) or math.min(150,math.floor(inner_w*0.24));local open_button_w=note_button_w
    local open_button_x=inner_x+inner_w-open_button_w
    local note_button_label=state.larger_text and layout.compact and "Notes..." or "Build Notes..."
    local open_button_label=state.larger_text and layout.compact and "Workbook" or "Open Workbook"
    if draw_button(note_button_label,inner_x,action_y+layout.action_note_y,note_button_w,note_h,not state.operation_busy,base_clicked,action_compact) then run_base_action(set_build_notes) end
    if draw_button(open_button_label,open_button_x,action_y+layout.action_note_y,open_button_w,note_h,state.file_path~="" and not state.operation_busy,base_clicked,action_compact) then run_base_action(open_selected_workbook) end
    local note_text_x=inner_x+note_button_w+12;local note_text_w=math.max(40,open_button_x-note_text_x-12)
    local audio_label=state.audio_tempo_mode==AUDIO_MODE_CONFORM and "Audio: Conform" or "Audio: Preserve"
    if draw_button(audio_label,note_text_x,action_y+layout.action_note_y,note_text_w,note_h,state.plan~=nil and not state.operation_busy,base_clicked,true) then run_base_action(choose_audio_tempo_mode) end
    if point_inside(note_text_x,action_y+layout.action_note_y,note_text_w,note_h) and state.audio_tempo_analysis then state.hover_context=state.audio_tempo_analysis.summary.." Choose this control to review or change the next build's audio handling mode." end
    local major_gap=12;local build_w=math.floor(inner_w*0.58);local undo_w=inner_w-build_w-major_gap
    local build_label=tempo_modified and "Apply & Verify Tempo Edits" or "Build Click Track Map"
    if draw_primary_button(build_label,inner_x,action_y+layout.action_major_y,build_w,layout.action_major_h,can_build,base_clicked) then run_base_action(begin_build_attempt) end
    if draw_button("Undo Last Build",inner_x+build_w+major_gap,action_y+layout.action_major_y,undo_w,layout.action_major_h,can_undo,base_clicked,action_compact) then run_base_action(undo_last_build) end
    if draw_accent_button("Open User-Friendly Song Structure...",inner_x,action_y+layout.action_small_y,inner_w,layout.action_small_h,state.plan~=nil and not state.operation_busy,base_clicked) then run_base_action(open_song_structure_readout) end
    local click_package_ok,click_package_reason=click_package_available()
    local click_package_label=state.larger_text and layout.compact and "Export MIDI + MP3..." or "Export MIDI + MP3 Click..."
    if draw_accent_button(click_package_label,inner_x,action_y+layout.action_export_y,inner_w,layout.action_export_h,click_package_ok,base_clicked,click_package_reason) then run_base_action(export_click_package) end
    local edit_gap=8;local edit_w=math.floor((inner_w-edit_gap)/2);local save_copy_ok,save_copy_reason=updated_workbook_copy_available();local revert_ok,revert_reason=selected_revert_available()
    if draw_button("Revert Tempo Edit",inner_x,action_y+layout.action_edit_y,edit_w,layout.action_edit_h,revert_ok and not state.operation_busy,base_clicked,true,revert_reason) then run_base_action(revert_selected_tempo_edits) end
    local save_copy_label=state.larger_text and layout.compact and "Save Workbook Copy" or "Save Updated Workbook Copy"
    if draw_button(save_copy_label,inner_x+edit_w+edit_gap,action_y+layout.action_edit_y,inner_w-edit_w-edit_gap,layout.action_edit_h,save_copy_ok and not state.operation_busy,base_clicked,true,save_copy_reason) then run_base_action(save_updated_workbook_copy) end
  end

  local right_x=content_x+left_w+gap;local right_w=content_w-left_w-gap
  local tempo_card_h=layout.compact and 68 or (state.larger_text and 82 or 74)
  local readiness_h=bottom_h-tempo_card_h-gap
  local compact_readiness=layout.compact or readiness_h<180
  draw_card(right_x,action_y,right_w,readiness_h,"Readiness",compact_readiness and nil or "All checks must pass before Build is enabled",compact_readiness)
  local checks={
    {"Workbook validated",state.plan~=nil,"No successfully validated workbook plan is loaded."},
    {"Workbook current",state.plan~=nil and not state.preview_stale,state.plan and "The workbook changed after validation; validate it again." or "Validate a workbook first."},
    {compact_readiness and state.larger_text and "Project check current" or "REAPER project check current",state.dry_run~=nil and not state.dry_run_stale,state.dry_run and "The REAPER project changed after the automatic check; wait for it to refresh." or "The automatic REAPER project check has not been calculated for the validated plan."},
    {"REAPER project saved at least once",saved,"The active REAPER project needs an .RPP filename and location. Current changes may still be unsaved."},
    {compact_readiness and state.larger_text and "Project matched" or "Active project matched",same_project,state.plan and "The active REAPER project tab is not the project used during validation." or "Validate a workbook against the active project first."},
    {"Environment ready",state.environment_ok,table.concat(state.environment_issues or {"Environment diagnostics have not passed."},"; ")}
  }
  if compact_readiness then
    local check_gap=8;local half_w=math.floor((right_w-36-check_gap)/2);local full_w=right_w-36
    local row_gap=math.max(17,math.floor((readiness_h-30)/4));local check_h=math.min(state.larger_text and 21 or 20,row_gap)
    local packed={{1,0,0,false},{2,1,0,false},{3,0,1,false},{6,1,1,false},{4,0,2,true},{5,0,3,true}}
    for _,item in ipairs(packed) do
      local c=checks[item[1]];local full=item[4];local x=right_x+18+(full and 0 or item[2]*(half_w+check_gap));local w=full and full_w or half_w
      draw_readiness_check(c[1],c[2],x,action_y+28+item[3]*row_gap,w,c[3],check_h)
    end
  else
    local cy=action_y+layout.readiness_y;local check_gap=16;local check_w=math.floor((right_w-36-check_gap)/2)
    for i,c in ipairs(checks) do local col=i<=3 and 0 or 1;local row=(i-1)%3;draw_readiness_check(c[1],c[2],right_x+18+col*(check_w+check_gap),cy+row*layout.readiness_gap,check_w,c[3]) end
  end
  local tempo_y=action_y+readiness_h+gap
  draw_card(right_x,tempo_y,right_w,tempo_card_h,nil,nil,true)
  draw_nav_icon("TEMPO",right_x+24,tempo_y+21,false);set_ui_color("text");draw_text("Tempo Preview",right_x+44,tempo_y+9,15,true)
  local controls_y=tempo_y+34;local label_w=state.larger_text and 38 or 32;local field_w=math.max(58,math.min(86,math.floor(right_w*0.24)));local button_gap=6
  set_ui_color("muted");draw_text("BPM",right_x+14,controls_y+7,11,true)
  local field_x=right_x+14+label_w;local control_h=math.min(30,tempo_card_h-38)
  draw_tempo_preview_field(field_x,controls_y,field_w,control_h,base_clicked,mouse_down)
  local play_x=field_x+field_w+button_gap;local remaining=right_x+right_w-12-play_x;local button_w=math.max(46,math.floor((remaining-button_gap)/2))
  local playing=state.audio_preview and state.audio_preview.owner=="tempo"
  if draw_button("Play",play_x,controls_y,button_w,control_h,not state.operation_busy,base_clicked,true) then run_base_action(play_tempo_preview) end
  if point_inside(play_x,controls_y,button_w,control_h) then state.hover_context="Play the entered BPM as a looping four-beat Quarter Note Tempo Preview." end
  local stop_x=play_x+button_w+button_gap;local stop_w=right_x+right_w-12-stop_x
  if draw_button("Stop",stop_x,controls_y,stop_w,control_h,playing,base_clicked,true) then stop_audio_preview() end
  if point_inside(stop_x,controls_y,stop_w,control_h) then state.hover_context=playing and "Stop Tempo Preview." or "Stop is available while Tempo Preview is playing." end
  local footer={}
  if state.show_hashes and state.plan then footer[#footer+1]="Plan "..tostring(state.plan.plan_sha256 or "Unavailable"):sub(1,14).."..." end
  if state.developer_mode then footer[#footer+1]="rows="..#state.preview_rows.." stale="..tostring(state.preview_stale).." busy="..tostring(state.operation_busy) end
  if #footer>0 then set_ui_color("muted");draw_text(fit_text(table.concat(footer,"  /  "),right_w-36,10),right_x+18,action_y+readiness_h-18,10,false) end
end

function draw_history_view(content_x,content_y,content_w,content_h,base_clicked,mouse_down)
  draw_card(content_x,content_y,content_w,content_h,"Attempt History","Oldest attempts appear at the top; newest attempts remain at the bottom")
  local top=state.larger_text and 76 or 58
  draw_history_panel(content_x+16,content_y+top,content_w-32,content_h-top-16,base_clicked,mouse_down)
end

function toggle_setting(key)
  state[key]=not state[key];persist_bool(key,state[key])
  if key=="show_syntax_badges" and state[key] and (tonumber(state.column_widths[3]) or 0)<360 then state.column_widths[3]=DEFAULT_COLUMNS[3];if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(state.column_widths),true) end end
  if key=="remember_layout" and state[key] then
    reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(state.column_widths),true)
    reaper.SetExtState(EXTSTATE_SECTION,"preview_hscroll",tostring(state.preview_hscroll),true)
  end
  if key=="remember_history_filters" and not state[key] then
    for _,k in ipairs({"history_filter","history_song","history_notes_search","history_id_search","history_date_from","history_date_to"}) do reaper.DeleteExtState(EXTSTATE_SECTION,k,true) end
  end
  set_status(pretty_setting_name(key).." "..(state[key] and "enabled." or "disabled."),"success")
end

function clear_recent_workbooks()
  state.recent_files={};save_recent_files({});set_status("Recent workbooks cleared.","success")
end

function clear_saved_history_filters()
  clear_all_history_filters();set_status("History filters cleared.","success")
end

function restore_default_layout()
  for _,key in ipairs({"window_w","window_h","window_x","window_y","history_panel_height","side_panel_height","column_widths","preview_hscroll"}) do reaper.DeleteExtState(EXTSTATE_SECTION,key,true) end
  state.column_widths={};for index,value in ipairs(DEFAULT_COLUMNS) do state.column_widths[index]=value end
  state.preview_hscroll=0;state.preview_vscroll=0;state.history_panel_height=300;state.side_panel_height=0;state.reinit_requested=true
  set_status("Default window, panel, Preview-column, and horizontal-scroll layout restored.","success")
end

function diagnostics_text()
  local info=get_active_project_info()
  local recovery_status=SAFE_MODE and "Ignored for this Safe Mode run" or state.pending_tempo_recovery and (state.pending_tempo_recovery.load_error and "Damaged/unreadable" or "Available") or not tempo_edits_empty(state.tempo_edits) and "Staged in current session" or "None"
  return string.format(
    "Script: %s\nREAPER: %s\nOS: %s\nSafe Mode: %s\nREAPER project has .RPP path: %s\nWorkbook: %s\nValidated plan: %s\nTempo recovery: %s\nHistory entries loaded: %d",
    SCRIPT_NAME,
    reaper.GetAppVersion(),
    reaper.GetOS(),
    SAFE_MODE and "Yes" or "No",
    project_is_saved(info) and "Yes" or "No",
    state.file_path~="" and state.file_path or "None",
    state.plan and "Yes" or "No",
    recovery_status,
    #state.history
  )
end

function open_diagnostics()
  open_app_modal({
    title="Diagnostics",message=diagnostics_text(),kind="info",plain_text=true,
    buttons={
      {label="Copy Diagnostics",value="copy",primary=true,stay_open=true},
      {label="Create Support Bundle",value="bundle"},
      {label="Close",value="close",cancel=true}
    },
    on_result=function(value)
      if value=="copy" then
        local ok,err=copy_to_clipboard(diagnostics_text());set_status(ok and "Diagnostics copied." or tostring(err),ok and "success" or "error")
      elseif value=="bundle" then create_support_bundle() end
    end
  })
end

function validate_click_frequency_fields(fields)
  local a=tonumber(trim(fields[1] and fields[1].value or ""));local b=tonumber(trim(fields[2] and fields[2].value or ""))
  if not valid_click_frequency(a) then return false,"Primary A frequency must be a whole number from 20 through 20000 Hz." end
  if not valid_click_frequency(b) then return false,"Secondary B frequency must be a whole number from 20 through 20000 Hz." end
  return true,nil,a,b
end

function open_click_frequency_settings()
  open_app_modal({
    title="Click Frequencies",kind="input",
    message="Set the synthesized metronome frequencies used by future builds. A is the primary/accent sound; B is the secondary sound. These values are stored as app defaults and applied to the active REAPER project during a verified build.",
    fields={
      {label="Primary A frequency (Hz)",value=tostring(state.click_a_hz),help="Whole number from 20 through 20000 Hz. Default: 1760 Hz."},
      {label="Secondary B frequency (Hz)",value=tostring(state.click_b_hz),help="Whole number from 20 through 20000 Hz. Default: 1600 Hz."}
    },
    fields_validator=validate_click_frequency_fields,
    buttons={{label="Save",value="save",primary=true},{label="Restore Defaults",value="defaults",stay_open=true},{label="Cancel",value="cancel",cancel=true}},
    on_result=function(value,_,fields)
      if value=="save" then
        local _,_,a,b=validate_click_frequency_fields(fields);state.click_a_hz=a;state.click_b_hz=b
        reaper.SetExtState(EXTSTATE_SECTION,"click_a_hz",tostring(a),true);reaper.SetExtState(EXTSTATE_SECTION,"click_b_hz",tostring(b),true)
        set_status(string.format("Click defaults saved: A %d Hz, B %d Hz.",a,b),"success")
      elseif value=="defaults" then
        fields[1].value=tostring(DEFAULT_CLICK_A_HZ);fields[1].cursor=#fields[1].value;fields[1].anchor=fields[1].cursor
        fields[2].value=tostring(DEFAULT_CLICK_B_HZ);fields[2].cursor=#fields[2].value;fields[2].anchor=fields[2].cursor
        if state.app_modal then state.app_modal.error="" end
      end
    end
  })
  if state.app_modal then state.app_modal.context="click_frequencies" end
end
function run_parser_self_test()
  local function test_progress(label) local callback=rawget(_G,"CTM_TEST_PROGRESS");if callback then callback(label) end end
  test_progress("parser cases")
  local cases = {
    {source="[4]", section_bpm=120, valid=true},
    {source="(7)x3", section_bpm=120, valid=true},
    {source="{5}@145", section_bpm=120, valid=true},
    {source="*9*x2", section_bpm=120, valid=true},
    {source="ENT(4)x2", section_bpm=120, valid=true,
      expect={kind="eighth_triplet",numerator=4,denominator=4,multiplier=1.5,
              repeats=2,underlying_bpm=120,effective_bpm=180,
              ramp=false,ramp_bars=0,canonical="ENT(4)x2"}},
    {source="SXT{7}x3@120--", section_bpm=100, valid=true,
      expect={kind="sextuplet",numerator=7,denominator=4,multiplier=3,
              repeats=3,underlying_bpm=120,effective_bpm=360,
              ramp=true,ramp_bars=2,canonical="SXT{7}x3@120--"}},

    -- QNT field-level verification.
    {source="QNT{5}", section_bpm=120, valid=true,
      expect={kind="quintuplet", numerator=5, denominator=4, multiplier=5,
              repeats=1, underlying_bpm=120, effective_bpm=600,
              ramp=false, ramp_bars=0, canonical="QNT{5}"}},
    {source="QNT{7}x3", section_bpm=90, valid=true,
      expect={kind="quintuplet", numerator=7, denominator=4, multiplier=5,
              repeats=3, underlying_bpm=90, effective_bpm=450,
              ramp=false, ramp_bars=0, canonical="QNT{7}x3"}},
    {source="QNT{6}@120", section_bpm=80, valid=true,
      expect={kind="quintuplet", numerator=6, denominator=4, multiplier=5,
              repeats=1, underlying_bpm=120, effective_bpm=600,
              ramp=false, ramp_bars=0, canonical="QNT{6}@120"}},
    {source="QNT{5}x4@100--", section_bpm=150, valid=true,
      expect={kind="quintuplet", numerator=5, denominator=4, multiplier=5,
              repeats=4, underlying_bpm=100, effective_bpm=500,
              ramp=true, ramp_bars=2, canonical="QNT{5}x4@100--"}},
    {source=" qnt { 11 } X2 @97.25 - ", section_bpm=140, valid=true,
      expect={kind="quintuplet", numerator=11, denominator=4, multiplier=5,
              repeats=2, underlying_bpm=97.25, effective_bpm=486.25,
              ramp=true, ramp_bars=1, canonical="QNT{11}x2@97.25-"}},

    -- SPT field-level verification.
    {source="SPT{7}", section_bpm=120, valid=true,
      expect={kind="septuplet", numerator=7, denominator=4, multiplier=7,
              repeats=1, underlying_bpm=120, effective_bpm=840,
              ramp=false, ramp_bars=0, canonical="SPT{7}"}},
    {source=" spt { 9 } X2 @80 - ", section_bpm=140, valid=true,
      expect={kind="septuplet", numerator=9, denominator=4, multiplier=7,
              repeats=2, underlying_bpm=80, effective_bpm=560,
              ramp=true, ramp_bars=1, canonical="SPT{9}x2@80-"}},

    -- Malformed or disallowed QNT forms.
    {source="QNT^^", section_bpm=120, valid=false},
    {source="QNT{0}", section_bpm=120, valid=false},
    {source="QNT^-5^", section_bpm=120, valid=false},
    {source="QNT^5.5^", section_bpm=120, valid=false},
    {source="QNT[5]", section_bpm=120, valid=false},
    {source="QNT(5)", section_bpm=120, valid=false},
    {source="QNT^5", section_bpm=120, valid=false},
    {source="QNT5^", section_bpm=120, valid=false},
    {source="QNT{5}x0", section_bpm=120, valid=false},
    {source="QNT{5}x2---", section_bpm=120, valid=false},
    {source="QNT{5}@0", section_bpm=120, valid=false},
    {source="QNT{5}@1e2", section_bpm=120, valid=false},
    {source="QNT{5}@100x2", section_bpm=120, valid=false},
    {source="STP{7}", section_bpm=120, valid=false},
    {source="SPT(7)", section_bpm=120, valid=false},
    {source="SPT[7]", section_bpm=120, valid=false},
    {source="SPT{0}", section_bpm=120, valid=false},
    {source="SPT{7}x0", section_bpm=120, valid=false},

    -- Replaced delimiters and obsolete names must not validate silently.
    {source="ET(4)",section_bpm=120,valid=false},
    {source="QUINT{5}",section_bpm=120,valid=false},
    {source="QT[4]",section_bpm=120,valid=false},
    {source="ENT[4]",section_bpm=120,valid=false},
    {source="SXT(7)",section_bpm=120,valid=false},
    {source="SXT[7]",section_bpm=120,valid=false},
    {source="QNT^5^",section_bpm=120,valid=false},

    -- Existing invalid syntax tests remain represented.
    {source="[4]x1--", section_bpm=120, valid=false},
    {source="BAD", section_bpm=120, valid=false}
  }

  local passed, details = 0, {}
  local function value_matches(actual, expected)
    if type(expected) == "number" then return nearly_equal(actual, expected, 0.000001) end
    return actual == expected
  end

  for _, case in ipairs(cases) do
    local part, err = parse_part(case.source, case.section_bpm)
    local actual_valid = part ~= nil
    local case_ok = actual_valid == case.valid
    if case_ok and case.expect then
      for field, expected in pairs(case.expect) do
        local actual = part[field]
        if not value_matches(actual, expected) then
          case_ok = false
          details[#details + 1] = string.format(
            "%s: field %s expected %s, got %s",
            case.source, field, tostring(expected), tostring(actual)
          )
        end
      end
    elseif not case_ok then
      details[#details + 1] = string.format(
        "%s: expected valid=%s, got valid=%s (%s)",
        case.source, tostring(case.valid), tostring(actual_valid), tostring(err or "no error")
      )
    end
    if case_ok then passed = passed + 1 end
  end

  test_progress("map and workbook rules")

  local map_part = parse_part("QNT{5}@100",100)
  map_part.section_name = "TEST"
  local map_plan = {count_in_bpm=100,sections={{name="TEST",parts={map_part}}},end_effective_bpm=25}
  local map_events,map_end = build_expected_map(map_plan,0,2)
  local map_ok = map_end==3 and #map_events==3
    and map_events[1].measure_index==0 and map_events[1].label==COUNT_IN.name
    and map_events[1].bpm==100 and map_events[1].numerator==4 and map_events[1].denominator==4
    and map_events[2].measure_index==2 and map_events[2].bpm==500 and map_events[2].numerator==5 and map_events[2].denominator==4
    and map_events[3].measure_index==3 and map_events[3].label=="END"
  if not map_ok then details[#details+1]="Automatic COUNT IN map test failed: expected measure 1 count-in at 100 BPM, measure 3 QNT at 500 BPM, and END after one musical bar." end

  local function make_rule_test_sheet(first_part_text,section_name,bpm_cell)
    return {
      name="Rule Test",max_row=3,max_col=3,formulas={},merges={},
      cells={
        [1]={[1]={value="SECTION NAME",kind="V"},[2]={value="BPM",kind="V"},[3]={value="PARTS",kind="V"}},
        [2]={[1]={value=section_name or "INTRO",kind="V"},[2]={value=bpm_cell or "100",kind="V"},[3]={value=first_part_text,kind="V"}},
        [3]={[1]={value="END",kind="V"}}
      }
    }
  end
  local rejected_plan,rejected_errors=validate_sheets({make_rule_test_sheet("[4]@140")},"xlsx")
  local differing_override_rejected=rejected_plan==nil and rejected_errors and table.concat(rejected_errors,"\n"):find("must match the first section BPM",1,true)~=nil
  if not differing_override_rejected then details[#details+1]="First-part BPM rule test failed: [4]@140 should be rejected when the first section BPM is 100." end

  local matching_plan,matching_errors=validate_sheets({make_rule_test_sheet("QNT{5}@100")},"xlsx")
  local matching_override_allowed=matching_plan~=nil and matching_errors==nil and matching_plan.count_in_bpm==100 and matching_plan.flat_parts[1].effective_bpm==500
  if not matching_override_allowed then details[#details+1]="First-part BPM rule test failed: QNT{5}@100 should be allowed when the first section BPM is 100." end

  local reserved_plan,reserved_errors=validate_sheets({make_rule_test_sheet("[4]"," count in ")},"xlsx")
  local reserved_name_rejected=reserved_plan==nil and reserved_errors and table.concat(reserved_errors,"\n"):find("reserved for the automatic COUNT IN marker",1,true)~=nil
  if not reserved_name_rejected then details[#details+1]="Reserved-name rule test failed: spreadsheet section ' count in ' should be rejected." end

  local near_plan,near_errors=validate_sheets({make_rule_test_sheet("[4]@100.005")},"xlsx")
  local near_override_rejected=near_plan==nil and near_errors and table.concat(near_errors,"\n"):find("must match the first section BPM",1,true)~=nil
  if not near_override_rejected then details[#details+1]="First-part BPM precision test failed: @100.005 must not match a 100 BPM first section." end

  local no_accent_plan,no_accent_errors=validate_sheets({make_rule_test_sheet("[4], SPT{7}","INTRO"," 100   No Accent ")},"xlsx")
  local no_accent_ok=no_accent_plan~=nil and no_accent_errors==nil and no_accent_plan.sections[1].no_accent==true
    and no_accent_plan.flat_parts[1].no_accent==true and no_accent_plan.flat_parts[2].no_accent==true
    and click_pattern(4,no_accent_plan.flat_parts[1].no_accent)=="AAAA"
    and click_pattern(7,no_accent_plan.flat_parts[2].no_accent)=="AAAAAAA"
    and click_pattern(COUNT_IN.numerator,false)=="ABBB"
  local invalid_no_accent_plan,invalid_no_accent_errors=validate_sheets({make_rule_test_sheet("[4]","INTRO","100 accent off")},"xlsx")
  no_accent_ok=no_accent_ok and invalid_no_accent_plan==nil and invalid_no_accent_errors~=nil
  if not no_accent_ok then details[#details+1]="No-accent BPM test failed: '100 no accent' must apply all-A clicks to its musical section while COUNT IN remains normally accented." end

  local function make_map_test_sheet(first_parts,second_parts,end_bpm,end_parts,after_end)
    local cells={
      [1]={[1]={value="SECTION NAME",kind="V"},[2]={value="BPM",kind="V"},[3]={value="PARTS",kind="V"}},
      [2]={[1]={value="INTRO",kind="V"},[2]={value="100",kind="V"},[3]={value=first_parts,kind="V"}}
    }
    local last_row=3
    if second_parts then
      cells[3]={[1]={value="CHORUS",kind="V"},[2]={value="150",kind="V"},[3]={value=second_parts,kind="V"}}
      last_row=4
    end
    cells[last_row]={[1]={value="END",kind="V"},[2]={value=end_bpm or "",kind="V"},[3]={value=end_parts or "",kind="V"}}
    if after_end then
      cells[last_row+1]={[1]={value="AFTER END",kind="V"},[2]={value="120",kind="V"},[3]={value="[4]",kind="V"}}
      last_row=last_row+1
    end
    return {name="Map Test",max_row=last_row,max_col=3,formulas={},merges={},cells=cells}
  end

  local cross_plan,cross_errors=validate_sheets({make_map_test_sheet("[4]x2@100-","[4]@150","40")},"xlsx")
  local cross_events=cross_plan and select(1,build_expected_map(cross_plan,0,2)) or {}
  local cross_ramp_ok=cross_plan~=nil and cross_errors==nil
    and cross_plan.flat_parts[1].ramp_target_bpm==150
    and #cross_events==4
    and cross_events[2].measure_index==3 and cross_events[2].linear==true and cross_events[2].bpm==100
    and cross_events[3].measure_index==4 and cross_events[3].linear==false and cross_events[3].bpm==150
    and cross_events[4].label=="END" and cross_events[4].bpm==25
  if not cross_ramp_ok then details[#details+1]="Cross-section ramp test failed: the final INTRO bar must ramp from 100 BPM into CHORUS at 150 BPM, then ordinary END must use 25 BPM." end

  local final_ramp_plan,final_ramp_errors=validate_sheets({make_map_test_sheet("[4]x2@100--",nil,"40")},"xlsx")
  local final_ramp_events=final_ramp_plan and select(1,build_expected_map(final_ramp_plan,0,2)) or {}
  local final_ramp_ok=final_ramp_plan~=nil and final_ramp_errors==nil
    and final_ramp_plan.end_effective_bpm==40 and #final_ramp_events==3
    and final_ramp_events[2].measure_index==2 and final_ramp_events[2].linear==true and final_ramp_events[2].bpm==100
    and final_ramp_events[3].measure_index==4 and final_ramp_events[3].label=="END" and final_ramp_events[3].bpm==40
  if not final_ramp_ok then details[#details+1]="Final ramp test failed: a two-bar final ramp must target the explicit 40 BPM END value." end

  local ordinary_end_plan,ordinary_end_errors=validate_sheets({make_map_test_sheet("[4]",nil,"40")},"xlsx")
  local ordinary_end_ok=ordinary_end_plan~=nil and ordinary_end_errors==nil and ordinary_end_plan.end_effective_bpm==END_BPM
  if not ordinary_end_ok then details[#details+1]="Ordinary END test failed: an explicit END BPM must be ignored when the final musical part has no ramp." end

  local invalid_end_plan,invalid_end_errors=validate_sheets({make_map_test_sheet("[4]",nil,"25","[1]",true)},"xlsx")
  local invalid_end_text=invalid_end_errors and table.concat(invalid_end_errors,"\n") or ""
  local invalid_end_ok=invalid_end_plan==nil and invalid_end_text:find("PARTS: value must remain blank",1,true)~=nil and invalid_end_text:find("contains data after END",1,true)~=nil
  if not invalid_end_ok then details[#details+1]="END validation test failed: populated END PARTS and data after END must both be rejected." end

  test_progress("error reference")
  local blank_matches=search_error_reference("")
  local code_matches=search_error_reference("SYN-006")
  local title_matches=search_error_reference("Invalid QNT syntax")
  local keyword_matches=search_error_reference("QNT requires matching braces")
  local fix_matches=search_error_reference("former QUINT{N} spelling is no longer accepted")
  local sxt_matches=search_error_reference("Sextuplet syntax")
  local block_code_matches=search_error_reference("SYN-020")
  local block_fix_matches=search_error_reference("repeat the block at least twice")
  local spt_matches=search_error_reference("SYN-023")
  local no_accent_matches=search_error_reference("150 no accent")
  local search_ok=#blank_matches==#ERROR_REFERENCE and #code_matches==1 and code_matches[1].code=="SYN-006"
    and #title_matches==1 and title_matches[1].code=="SYN-006"
    and #keyword_matches==1 and keyword_matches[1].code=="SYN-006"
    and #fix_matches==1 and fix_matches[1].code=="SYN-006"
    and #sxt_matches==1 and sxt_matches[1].code=="SYN-005"
    and #block_code_matches==1 and block_code_matches[1].code=="SYN-020"
    and #block_fix_matches>=1 and block_fix_matches[1].code=="SYN-020"
    and #spt_matches==1 and spt_matches[1].code=="SYN-023"
    and #no_accent_matches>=1
  if not search_ok then
    local function codes(matches) local out={};for _,entry in ipairs(matches or {}) do out[#out+1]=entry.code end;return table.concat(out,",") end
    details[#details+1]=string.format("Error Reference search test failed: blank=%d/%d code=%s title=%s keyword=%s fix=%s sxt=%s block-code=%s block-fix=%s spt=%s no-accent=%s.",#blank_matches,#ERROR_REFERENCE,codes(code_matches),codes(title_matches),codes(keyword_matches),codes(fix_matches),codes(sxt_matches),codes(block_code_matches),codes(block_fix_matches),codes(spt_matches),codes(no_accent_matches))
  end

  local formatted_reference=format_error_reference_entry(code_matches[1] or ERROR_REFERENCE[#ERROR_REFERENCE],false)
  local reference_format_ok=formatted_reference:find("WHAT HAPPENED",1,true)~=nil
    and formatted_reference:find("MOST LIKELY FIX",1,true)~=nil
    and formatted_reference:find("ALTERNATE FIX OR NEXT STEP",1,true)~=nil
    and formatted_reference:find("INVALID EXAMPLE",1,true)~=nil
    and formatted_reference:find("CORRECTED EXAMPLE",1,true)~=nil
    and formatted_reference:find("RELATED DOCUMENTATION",1,true)~=nil
  if not reference_format_ok then details[#details+1]="Error Reference formatting test failed: a full result must include explanation, fixes, examples, and related documentation." end

  local v1018=readme_version_tuple("Bildibeat_Click_Track_Mapper_README_v10_21.txt")
  local v1011=readme_version_tuple("Bildibeat_Click_Track_Mapper_README_v10_11.txt")
  local readme_version_ok=v1018~=nil and v1011~=nil and version_tuple_greater(v1018,v1011)
    and readme_version_tuple("Bildibeat_Click_Track_Mapper_README_latest.txt")==nil
  if not readme_version_ok then details[#details+1]="README version discovery test failed: v10.21 must sort above v10.11 and non-version names must be ignored." end

  test_progress("extended suite")
  local extended={}
  test_progress("extended golden map")
  do
    local golden=serialize_expected_map(map_plan,0,2)
    local expected_golden=table.concat({
      "0|0|100.000000|4/4|false|ABBB|COUNT IN",
      "2|2|500.000000|5/4|false|ABBBB|TEST / QNT{5}@100",
      "3|3|25.000000|1/4|false|A|END",
      "END_MEASURE|3"
    },"\n")
    extended.golden=golden==expected_golden
    if not extended.golden then details[#details+1]="Golden tempo-map test failed.\nExpected:\n"..expected_golden.."\nActual:\n"..golden end
  end

  test_progress("extended stress map")
  do
    local stress_parts={}
    for i=1,500 do stress_parts[i]="[4]" end
    local stress_sheet=make_map_test_sheet(table.concat(stress_parts,","),nil,"")
    local stress_plan,stress_errors=validate_sheets({stress_sheet},"xlsx")
    local stress_preflight_ok,stress_preflight=false,nil
    if stress_plan then stress_preflight_ok,stress_preflight=preflight_build_plan(stress_plan,{count_in={measure_index=0},song={measure_index=2}},DEFAULT_CLICK_A_HZ,DEFAULT_CLICK_B_HZ) end
    extended.stress=stress_plan~=nil and stress_errors==nil and #stress_plan.flat_parts==500 and stress_plan.total_bars==500 and stress_plan.end_visible_measure==503 and stress_preflight_ok and stress_preflight.end_measure_index==502
    if not extended.stress then details[#details+1]=string.format("Large-song stress test failed: plan=%s errors=%s parts=%s bars=%s visible_END=%s preflight=%s internal_END=%s detail=%s.",tostring(stress_plan~=nil),tostring(stress_errors and table.concat(stress_errors," | ") or "none"),tostring(stress_plan and #stress_plan.flat_parts),tostring(stress_plan and stress_plan.total_bars),tostring(stress_plan and stress_plan.end_visible_measure),tostring(stress_preflight_ok),tostring(stress_preflight and stress_preflight.end_measure_index),tostring(stress_preflight)) end
  end

  test_progress("extended remaining contracts")
  do
    local block_text="<[4]x2@100, SXT{7}@100->x2, [9]@250"
    local block_plan,block_errors=validate_sheets({make_map_test_sheet(block_text,nil,"25")},"xlsx")
    local block_events=block_plan and select(1,build_expected_map(block_plan,0,2)) or {}
    local block_preview=block_plan and preview_rows(block_plan) or {}
    local variant_plan,variant_errors=validate_sheets({make_map_test_sheet("< [4] X2 @100 , sxt { 7 } @100 - > X2, [9] @250",nil,"25")},"xlsx")
    local block_ok=block_plan~=nil and block_errors==nil
      and block_plan.block_count==1 and block_plan.block_passes==2
      and #block_plan.flat_parts==5 and block_plan.total_bars==7 and block_plan.end_visible_measure==10
      and block_plan.flat_parts[2].ramp==true and block_plan.flat_parts[2].ramp_target_bpm==100
      and block_plan.flat_parts[4].ramp==false and block_plan.flat_parts[4].ramp_suppressed==true
      and block_plan.flat_parts[5].effective_bpm==250
      and #block_events==6 and block_events[2].linear==true and block_events[2].bpm==300
      and block_events[3].linear==false and block_events[3].bpm==100
      and block_events[4].linear==false and block_events[4].bpm==300
      and block_preview[2].part:find("Block 1/2",1,true)~=nil
      and block_preview[4].part:find("Block 2/2",1,true)~=nil
      and block_preview[5].ramp=="Inactive at final block boundary"
      and table.concat(preview_syntax_badges(block_preview[3]),"|")=="Block Pass 1 of 2|Sextuplet|BPM Override: 100|Ramp: 1 Bar"
      and table.concat(preview_syntax_badges(block_preview[5]),"|")=="Block Pass 2 of 2|Sextuplet|BPM Override: 100|Ramp Inactive"
      and block_plan.normalized_text:find("RAMP_SUPPRESSED:1",1,true)~=nil
      and variant_plan~=nil and variant_errors==nil and variant_plan.normalized_text==block_plan.normalized_text

    local internal_parts=select(1,parse_parts_expression("<[4]-, SXT{7}>x2",100))
    block_ok=block_ok and internal_parts and #internal_parts==4
      and internal_parts[1].ramp and not internal_parts[2].ramp
      and internal_parts[3].ramp and not internal_parts[4].ramp

    local incoming_plan,incoming_errors=validate_sheets({make_map_test_sheet("[4]x2@100-","<[4]@150, SXT{7}>x2","")},"xlsx")
    block_ok=block_ok and incoming_plan~=nil and incoming_errors==nil
      and incoming_plan.flat_parts[1].ramp_target_bpm==150
      and incoming_plan.flat_parts[2].block_repeat_index==1

    local explicit_x1=select(1,parse_parts_expression("<[4]>x1",100))
    block_ok=block_ok and explicit_x1 and #explicit_x1==1 and explicit_x1[1].block_repeat_total==1

    local invalid_blocks={
      {"<[4], <SXT{7}, [3]>x2>x2","Blocks cannot be nested"},
      {"<[4], SXT{7}","missing its closing >"},
      {"[4], SXT{7}>","closing > without"},
      {"<>x2","must contain at least one part"},
      {"<[4], SXT{7}>x0","at least 1"},
      {"<[4], SXT{7}>x1.5","block repeat must be xR"},
      {"<[4], SXT{7}>x2-","block-level ramp modifiers"},
      {"<[4], SXT{7}>x2@120","block-level @BPM overrides"},
      {"<[4], SXT{7}->","one-pass block has no legal next pass"},
      {"<[4], SXT{7}>x6000","safety limit"}
    }
    for _,invalid in ipairs(invalid_blocks) do
      local parsed,_,parse_err=parse_parts_expression(invalid[1],100)
      if parsed or not parse_err or upper(parse_err):find(upper(invalid[2]),1,true)==nil then block_ok=false;details[#details+1]="Block rejection test failed for "..invalid[1]..": "..tostring(parse_err) end
    end
    local conga_part=parse_part("[4]x16",150)
    local override_part=parse_part("[7]x4@230",150)
    local eighth_triplet_part=parse_part("ENT(4)",120);local sextuplet_part=parse_part("SXT{7}",100);local quintuplet_part=parse_part("QNT{5}",90);local septuplet_part=parse_part("SPT{7}",80)
    local conga_blurb=preview_part_plain_english(conga_part,{bpm=150},nil)
    local override_blurb=preview_part_plain_english(override_part,{bpm=150},nil)
    local eighth_triplet_blurb=preview_part_plain_english(eighth_triplet_part,{bpm=120},nil);local sextuplet_blurb=preview_part_plain_english(sextuplet_part,{bpm=100},nil);local quintuplet_blurb=preview_part_plain_english(quintuplet_part,{bpm=90},nil);local septuplet_blurb=preview_part_plain_english(septuplet_part,{bpm=80},nil)
    extended.plain_english=conga_blurb=="16 bars of 4/4 at 150 BPM."
      and override_blurb=="4 bars of 7/4 at 230 BPM. Part override; section BPM is 150."
      and eighth_triplet_blurb:find("Eighth Note Triplet: 120 underlying BPM x1.5",1,true)~=nil
      and sextuplet_blurb:find("Sextuplet: 100 underlying BPM x3",1,true)~=nil
      and quintuplet_blurb:find("Quintuplet: 90 underlying BPM x5",1,true)~=nil
      and septuplet_blurb:find("Septuplet: 80 underlying BPM x7",1,true)~=nil
      and not eighth_triplet_blurb:find("ENT:",1,true) and not sextuplet_blurb:find("SXT:",1,true) and not quintuplet_blurb:find("QNT:",1,true) and not septuplet_blurb:find("SPT:",1,true)
      and preview_row_blurb({plain_english=conga_blurb})==conga_blurb
      and preview_row_blurb({issue={row=3,reference={code="SYN-001",title="Invalid PARTS syntax"}}}):find("Row 3",1,true)~=nil
      and preview_row_blurb({issue={row=3,reference={code="SYN-001",title="Invalid PARTS syntax"}}}):find("SYN-001: Invalid PARTS syntax",1,true)~=nil
      and block_preview[1] and block_preview[1].plain_english:find("Automatic count-in",1,true)~=nil
      and block_preview[3] and block_preview[3].plain_english:find("Block pass 1 of 2, part 2 of 2",1,true)~=nil
      and block_preview[3].plain_english:find("ramps into block pass 2 at 100 BPM",1,true)~=nil
      and block_preview[5] and block_preview[5].plain_english:find("inactive at the final block boundary",1,true)~=nil
      and block_preview[#block_preview] and block_preview[#block_preview].plain_english:find("END at measure 10",1,true)~=nil
    local selected_status,selected_kind=resolve_bottom_bar_content({status="Old action",status_kind="success",status_until=1,hover_context="",selected_preview_row=1,active_view="BUILD"},2,{{plain_english=conga_blurb}})
    local temporary_status,temporary_kind=resolve_bottom_bar_content({status="Build passed",status_kind="success",status_until=3,hover_context="",selected_preview_row=1,active_view="BUILD"},2,{{plain_english=conga_blurb}})
    local settings_status,settings_kind=resolve_bottom_bar_content({status=conga_blurb,status_kind="info",status_until=1,hover_context="",selected_preview_row=1,active_view="SETTINGS"},2,{{plain_english=conga_blurb}})
    local history_hover,history_hover_kind=resolve_bottom_bar_content({status=conga_blurb,status_kind="info",status_until=1,hover_context="Open the selected attempt log.",selected_preview_row=1,active_view="HISTORY"},2,{{plain_english=conga_blurb}})
    extended.plain_english=extended.plain_english and selected_status==conga_blurb and selected_kind=="info"
      and temporary_status=="Build passed" and temporary_kind=="success"
      and settings_status==pane_default_context("SETTINGS") and settings_kind=="info" and settings_status~=conga_blurb
      and history_hover=="Open the selected attempt log." and history_hover_kind=="info"
      and pane_default_context("HELP"):find("Help:",1,true)==1
      and preview_row_full_readout({plain_english=conga_blurb,start="4",next="20",row="3",section_name="CONGA LINE",source="[4]x16"}):find("measures 4 through 19",1,true)~=nil
      and row_original_syntax({block_source="<[4], SXT{7}>x2",source="SXT{7}"})=="SXT{7}"
    if not extended.plain_english then details[#details+1]="Plain-English Preview-row test failed: uniform modifier names, ordinary/override wording, COUNT IN, END, block-pass, ramp destination, full readout, original syntax, or pane-scoped bottom-bar behavior was incorrect." end
    extended.blocks=block_ok
    if not block_ok then details[#details+1]="Block regression test failed: expansion, pass labels, internal ramp confinement, incoming cross-section ramp, explicit x1, event map, or validation rules were incorrect." end
  end

  do
    local scratch=evaluate_syntax_scratchpad(SCRATCHPAD_DEFAULT_BPM,SCRATCHPAD_DEFAULT_PARTS)
    local invalid_ent_scratch=evaluate_syntax_scratchpad("100","ENT[7]")
    local legacy_et_scratch=evaluate_syntax_scratchpad("100","ET(7)")
    local invalid_sxt_scratch=evaluate_syntax_scratchpad("100","SXT(7)")
    local invalid_spt_scratch=evaluate_syntax_scratchpad("100","STP{7}")
    local final_ramp_scratch=evaluate_syntax_scratchpad("120","[4]-")
    local scratch_wrap_width=260;local scratch_wrapped=wrap_text(scratch.readout,scratch_wrap_width,13,true);local scratch_wrap_ok=#scratch_wrapped>3
    gfx.setfont(2,UI.mono_font_name,scaled_font_size(13),0)
    for _,line in ipairs(scratch_wrapped) do if gfx.measurestr(line)>scratch_wrap_width+1 then scratch_wrap_ok=false;break end end
    extended.scratchpad=scratch.ok and scratch.normalized==SCRATCHPAD_DEFAULT_PARTS
      and #scratch.parts==12 and #scratch.blocks==1 and scratch.readout:find("Eighth Note Triplet",1,true)~=nil
      and scratch.readout:find("Sextuplet",1,true)~=nil and scratch.readout:find("Quintuplet",1,true)~=nil
      and scratch.readout:find("Septuplet",1,true)~=nil
      and scratch.readout:find("Block pass 1 of 2",1,true)~=nil and scratch.readout:find("23 musical bars",1,true)~=nil
      and not invalid_ent_scratch.ok and invalid_ent_scratch.code=="SYN-004" and invalid_ent_scratch.readout:find("Most likely fix",1,true)~=nil
      and not legacy_et_scratch.ok and legacy_et_scratch.code=="SYN-004" and legacy_et_scratch.readout:find("ENT(N)",1,true)~=nil
      and not invalid_sxt_scratch.ok and invalid_sxt_scratch.code=="SYN-005" and invalid_sxt_scratch.readout:find("Most likely fix",1,true)~=nil
      and not invalid_spt_scratch.ok and invalid_spt_scratch.code=="SYN-023" and invalid_spt_scratch.readout:find("SPT{N}",1,true)~=nil
      and final_ramp_scratch.ok and final_ramp_scratch.readout:find("destination is supplied by the following workbook row or END BPM",1,true)~=nil
      and scratch_wrap_ok
    if not extended.scratchpad then details[#details+1]="Syntax Scratchpad regression test failed: normalization, block expansion, uniform terminology, width-safe result wrapping, Error Reference routing, or context-dependent final-ramp wording was incorrect." end
  end

  do
    local standard_badges=table.concat(preview_syntax_badges({part="[4]x2@150--",ramp="Last 2 bars"}),"|")
    local note_badges={
      table.concat(preview_syntax_badges({part="(7)"}),"|"),
      table.concat(preview_syntax_badges({part="{9}"}),"|"),
      table.concat(preview_syntax_badges({part="*11*"}),"|"),
      table.concat(preview_syntax_badges({part="ENT(4)"}),"|"),
      table.concat(preview_syntax_badges({part="SXT{7}"}),"|"),
      table.concat(preview_syntax_badges({part="QNT{5}"}),"|"),
      table.concat(preview_syntax_badges({part="SPT{7}"}),"|")
    }
    extended.badges=standard_badges=="Quarter Note|Repeat x2|BPM Override: 150|Ramp: 2 Bars"
      and table.concat(note_badges,"|")=="Eighth Note|Sixteenth Note|Thirty-Second Note|Eighth Note Triplet|Sextuplet|Quintuplet|Septuplet"
    if not extended.badges then details[#details+1]="Syntax-badge regression test failed: note value, Repeat, BPM Override, Ramp, or simulated-click labels are not complete title-style English." end
  end

  do
    local valid_date=parse_history_display_date("07-16-2026")
    local invalid_date=parse_history_display_date("02-30-2026")
    local range_ok=validate_history_filter_fields({{}, {value="07-01-2026"}, {value="07-31-2026"}})
    local range_bad=validate_history_filter_fields({{}, {value="08-01-2026"}, {value="07-31-2026"}})
    extended.history_dates=valid_date=="2026-07-16" and history_display_date(valid_date)=="07-16-2026" and invalid_date==nil and range_ok==true and range_bad==false
    if not extended.history_dates then details[#details+1]="History-date regression test failed: MM-DD-YYYY conversion, calendar-date validation, or inclusive range ordering is incorrect." end
  end

  do
    local readout_plan,readout_errors=validate_sheets({make_map_test_sheet("<[4], SXT{7}>x2",nil,"")},"xlsx")
    if readout_plan then readout_plan.file_path="C:\\Songs\\MY_Song_Title.xlsx" end
    local without_measures=readout_plan and song_structure_text(readout_plan,false,false,false) or ""
    local with_measures=readout_plan and song_structure_text(readout_plan,true,false,false) or ""
    local full_bpm=readout_plan and song_structure_text(readout_plan,false,false,true) or ""
    local simplified=readout_plan and song_structure_text(readout_plan,false,true,false) or ""
    local simplified_bpm=readout_plan and song_structure_text(readout_plan,false,true,true) or ""
    local print_html=readout_plan and song_structure_print_html(readout_plan,false,false,false,false) or ""
    local generic=readout_plan and song_structure_text(readout_plan,false,false,false,true) or ""
    local saved_plan,saved_modal=state.plan,state.app_modal
    state.plan=readout_plan
    if readout_plan then open_song_structure_readout() end
    local readout_modal_style=state.app_modal and state.app_modal.context=="song_readout" and state.app_modal.plain_text==true and state.app_modal.body_font_size==14
    state.plan,state.app_modal=saved_plan,saved_modal
    local ramp_plan=select(1,validate_sheets({make_map_test_sheet("[4]@100-, SXT{7}@100",nil,"")},"xlsx"))
    local ramp_without_bpm=ramp_plan and song_structure_text(ramp_plan,false,false,false) or ""
    local ramp_with_bpm=ramp_plan and song_structure_text(ramp_plan,false,false,true) or ""
    extended.song_readout=readout_plan~=nil and readout_errors==nil and clean_workbook_title(readout_plan.file_path)=="MY Song Title"
      and without_measures:find("MY Song Title",1,true)~=nil and without_measures:find("Sextuplet click",1,true)~=nil
      and without_measures:find("Block Pass",1,true)==nil and without_measures:find("Measure 3",1,true)==nil
      and without_measures:find(" BPM",1,true)==nil
      and with_measures:find("Measure",1,true)~=nil
      and full_bpm:find("4/4 | 100 BPM | Quarter Note click",1,true)~=nil
      and ramp_without_bpm:find("Ramp -> Sextuplet click",1,true)~=nil and ramp_without_bpm:find(" BPM",1,true)==nil
      and ramp_with_bpm:find("Ramp -> 100 BPM with Sextuplet click",1,true)~=nil
      and simplified:find("(4 — Quarter Note\n7 — Sextuplet)\nx2",1,true)~=nil
      and simplified:lower():find("block",1,true)==nil and simplified:find(" BPM",1,true)==nil
      and simplified_bpm:find("4 — Quarter Note — 100 BPM",1,true)~=nil
      and simplified:find("INTRO: 00:08",1,true)~=nil
      and simplified:find("Musical Content: 00:08",1,true)~=nil
      and simplified:find("Total with Count-In: 00:12",1,true)~=nil
      and print_html:find("counter(page)",1,true)==nil and print_html:find("counter(pages)",1,true)==nil
      and generic:find("PART 1",1,true)~=nil and generic:find("INTRO",1,true)==nil
      and generic:find("PART 1: 00:08",1,true)~=nil
      and readout_modal_style
      and nearly_equal(readout_plan.total_duration,7.6,0.000001)
      and nearly_equal(readout_plan.total_duration_with_count_in,12.4,0.000001)
    if not extended.song_readout then details[#details+1]="Song Structure Readout regression test failed. Full output:\n"..without_measures.."\n--- Full BPM output ---\n"..full_bpm.."\n--- Simplified output ---\n"..simplified.."\n--- Simplified BPM output ---\n"..simplified_bpm end
  end

  do
    local fake={folder="C:\\Songs",path="C:\\Songs\\OriginalSong.RPP"}
    local pre=prebuild_backup_path(fake);local completed=completed_build_path(fake,{suffix="01FB"})
    extended.project_save_names=pre:find("OriginalSong_CTM_PREBUILD_BACKUP_",1,true)~=nil and pre:match("%.RPP$")~=nil
      and completed:find("OriginalSong_CTM_COMPLETED_BUILD_",1,true)~=nil and completed:find("_ID-01FB.RPP",1,true)~=nil
      and project_filename_stem("C:\\Songs\\OriginalSong_CTM_PREBUILD_BACKUP_2026-07-16_120000.RPP")=="OriginalSong"
      and type(save_reaper_project_as)=="function" and type(save_reaper_project_current)=="function" and type(show_postbuild_save_prompt)=="function"
    if not extended.project_save_names then details[#details+1]="REAPER save-workflow regression test failed: unique pre-build/completed filename conventions, suffix stripping, or save helpers are missing." end
  end

  do
    local action_row={source="SXT{7}-",part="SXT{7}-",ramp_start="4",plain_english="One bar.",start="3",next="4"}
    local action_labels={};for _,action in ipairs(row_popover_actions(action_row)) do action_labels[#action_labels+1]=action.label end
    local no_ramp_labels={};for _,action in ipairs(row_popover_actions({source="[4]",part="[4]",plain_english="One bar.",start="3",next="4"})) do no_ramp_labels[#no_ramp_labels+1]=action.label end
    local joined=table.concat(action_labels,"|");local no_ramp_joined=table.concat(no_ramp_labels,"|")
    extended.row_popover=joined:find("Jump to Part",1,true)~=nil and joined:find("Jump to Ramp",1,true)~=nil
      and joined:find("Copy Readout",1,true)~=nil and joined:find("Copy Syntax",1,true)~=nil
      and joined:find("Send to Scratchpad",1,true)~=nil
      and no_ramp_joined:find("Jump to Ramp",1,true)==nil and no_ramp_joined:find("Send to Scratchpad",1,true)~=nil and type(draw_row_popover)=="function" and type(open_row_popover)=="function"
    if not extended.row_popover then details[#details+1]="Preview-row popover regression test failed: contextual jump/copy/Scratchpad actions or active-ramp gating was incorrect." end
  end

  do
    local saved_rows,saved_errors=state.preview_rows,state.errors
    local saved_selected,saved_anchor=state.selected_preview_row,state.preview_selection_anchor
    local saved_start,saved_end=state.preview_selection_start,state.preview_selection_end
    state.errors={};state.preview_rows={
      {source="[4]x2",block_source="<[4]x2, ENT(7)@47>x2"},
      {source="ENT(7)@47",block_source="<[4]x2, ENT(7)@47>x2"},
      {source="END"}
    }
    state.selected_preview_row=1;state.preview_selection_anchor=1;state.preview_selection_start=1;state.preview_selection_end=1
    local single,single_count=selected_preview_syntax(state.preview_rows[1])
    state.selected_preview_row=2;state.preview_selection_start=1;state.preview_selection_end=2
    local multiple,multiple_count=selected_preview_syntax(state.preview_rows[2])
    state.selected_preview_row=3;state.preview_selection_start=3;state.preview_selection_end=3
    local ending,end_count=selected_preview_syntax(state.preview_rows[3])
    extended.selection_syntax=single=="[4]x2" and single_count==1
      and multiple=="[4]x2, ENT(7)@47" and multiple_count==2
      and ending==nil and end_count==0
    state.preview_rows,state.errors=saved_rows,saved_errors
    state.selected_preview_row,state.preview_selection_anchor=saved_selected,saved_anchor
    state.preview_selection_start,state.preview_selection_end=saved_start,saved_end
    if not extended.selection_syntax then details[#details+1]="Selection-aware Copy Syntax regression test failed: one Block row must copy only its Part, multiple selected rows must join in Preview order, and END must not emit PARTS syntax." end
  end

  do
    local captures_runtime_state=false
    for index=1,32 do
      local name,value=debug.getupvalue(selected_preview_syntax,index)
      if not name then break end
      if name=="state" and value==state then captures_runtime_state=true;break end
    end
    extended.runtime_state_scope=captures_runtime_state
    if not extended.runtime_state_scope then details[#details+1]="Runtime-state scope regression test failed: selected Preview helpers must capture the app's local state rather than an undefined global state." end
  end

  do
    local first_part=select(1,parse_part("[4]x2@120-",120))
    local second_part=select(1,parse_part("SXT{5}@110",120))
    local rows={
      {source="[4]x2@120-",part_object=first_part,base_bpm=120,no_accent=false},
      {source="SXT{5}@110",part_object=second_part,base_bpm=110,no_accent=false},
      {source="END",is_end=true}
    }
    local payload,payload_error=scratchpad_payload_for_preview_rows(rows,1,2,{count_in_bpm=120})
    local parsed=payload and select(1,parse_parts_expression(payload.parts,tonumber(payload.bpm))) or nil
    local mixed_error=select(2,scratchpad_payload_for_preview_rows({rows[1],{source="SXT{5}@110",part_object=second_part,base_bpm=110,no_accent=true}},1,2,{count_in_bpm=120}))
    local end_error=select(2,scratchpad_payload_for_preview_rows(rows,3,3,{count_in_bpm=120}))
    extended.send_to_scratchpad=payload and payload.count==2 and payload.bpm=="120"
      and payload.parts=="[4]x2@120-, SXT{5}@110" and parsed and #parsed==2
      and mixed_error and mixed_error:find("mix accented and no-accent",1,true)~=nil
      and end_error and end_error:find("END has no playable duration",1,true)~=nil
    if not extended.send_to_scratchpad then details[#details+1]="Send to Scratchpad regression test failed: selected-row order, explicit underlying BPM, retained internal Ramp, accent-mode protection, or END rejection was incorrect. "..tostring(payload_error or "") end
  end

  do
    local transport_end=audition_endpoint_times(10,14)
    local click_count=0
    for index=0,8 do if 10+index*0.5<transport_end then click_count=click_count+1 end end
    local native_state=audition_stop_at_loop_end_state()
    extended.audition_boundary=transport_end<14 and transport_end>13.95 and click_count==8
      and (native_state==0 or native_state==1)
    if not extended.audition_boundary then details[#details+1]=string.format("Audition endpoint regression test failed: [4]x2 exposed %d click boundaries; guarded transport end %.6f; native stop state %s.",click_count,transport_end,tostring(native_state)) end
  end

  do
    local native_metronome_state=metronome_enabled_state()
    extended.metronome_contract=(native_metronome_state==0 or native_metronome_state==1)
      and ACTION_TOGGLE_METRONOME==40364 and type(set_metronome_enabled)=="function"
    if not extended.metronome_contract then details[#details+1]="REAPER metronome contract test failed: the native toggle action or readable enabled state is unavailable." end
  end

  do
    local marker={measure_index=0,beatpos=0,name="COUNT IN",position_label="visible measure 1"}
    local tempo={measure_index=0,beatpos=0,bpm=100,numerator=4,denominator=4,linear=false,position_label="visible measure 1",label="COUNT IN"}
    local snapshot={existing_marker_objects={marker},planned_marker_objects={marker},existing_tempo_objects={tempo},planned_tempo_objects={tempo}}
    build_net_result(snapshot)
    local first=string.format("%d|%d|%d|%d",snapshot.net_marker_counts.unchanged,snapshot.net_marker_counts.changed,snapshot.net_tempo_counts.unchanged,snapshot.net_tempo_counts.changed)
    build_net_result(snapshot)
    local second=string.format("%d|%d|%d|%d",snapshot.net_marker_counts.unchanged,snapshot.net_marker_counts.changed,snapshot.net_tempo_counts.unchanged,snapshot.net_tempo_counts.changed)
    extended.rebuild=first=="1|0|1|0" and second==first
    if not extended.rebuild then details[#details+1]="Repeated rebuild simulation failed: an identical marker/tempo plan must remain deterministic and unchanged on every comparison pass." end
  end

  do
    extended.rollback_tolerance=transaction_signature_number(23.464663023679417,9)==transaction_signature_number(23.464663023679421,9)
      and transaction_signature_number(23.464663023679417,9)~=transaction_signature_number(23.464664023679417,9)
    if not extended.rollback_tolerance then details[#details+1]="Rollback signature normalization test failed: sub-machine floating noise should match while a one-microsecond coordinate change must remain detectable." end
  end

  do
    local legacy=normalize_preference_snapshot({preferences_schema="0",preview_density="DENSE"})
    local invalid=normalize_preference_snapshot({preferences_schema="broken",preview_density="WIDE"})
    extended.preferences=legacy.previous_schema==0 and legacy.preferences_schema==PREF_SCHEMA_VERSION and legacy.preview_density=="COMPACT" and invalid.preview_density=="COMFORTABLE"
      and valid_click_frequency(1760) and valid_click_frequency(1600) and not valid_click_frequency(19) and not valid_click_frequency(1760.5)
    if not extended.preferences then details[#details+1]="Preference migration test failed: legacy DENSE and invalid density values did not normalize safely." end
  end

  do
    local issue=validation_issue_from_error("Row 2, PARTS, part 1 ('QT^5^'): Invalid meter syntax. Use [N], (N), {N}, *N*, ENT(N), SXT{N}, or QNT{N}.",1)
    local ordered=suggested_part_correction("[4]@120x4","Modifier order is invalid")
    local legacy_ent=suggested_part_correction("ET(4)","ET syntax was replaced")
    local legacy_qnt=suggested_part_correction("QUINT{5}","QUINT syntax was replaced")
    local transposed_spt=suggested_part_correction("STP{7}","STP is not valid Septuplet syntax")
    extended.suggestions=issue.row==2 and issue.field=="PARTS" and issue.correction=="QNT{5}" and ordered=="[4]x4@120"
      and legacy_ent=="ENT(4)" and legacy_qnt=="QNT{5}" and transposed_spt=="SPT{7}"
    if not extended.suggestions then details[#details+1]="Validation suggestion test failed: row extraction, QNT correction, or modifier-order correction was incorrect." end
  end

  do
    local modal={buttons={{label="Apply",value="yes",primary=true},{label="Cancel",value="no",cancel=true}}}
    extended.modal=top_input_layer({app_modal={},confirm_modal={},comparison_open=true})=="APP_MODAL"
      and top_input_layer({confirm_modal={},comparison_open=true})=="CONFIRM_MODAL"
      and top_input_layer({comparison_open=true})=="COMPARISON_MODAL"
      and top_input_layer({row_popover={}})=="ROW_POPOVER"
      and top_input_layer({})=="BASE"
      and modal_button_value(modal,"primary")=="yes" and modal_button_value(modal,"cancel")=="no"
    if not extended.modal then details[#details+1]="Modal routing test failed: top-layer priority or Enter/Escape button-role mapping is incorrect." end
  end

  do
    local text,cursor,changed=edit_text_at_cursor("abcdef",3,TEXT_KEYS.LEFT)
    local navigation_ok=text=="abcdef" and cursor==2 and not changed
    text,cursor,changed=edit_text_at_cursor("abcdef",3,TEXT_KEYS.RIGHT)
    navigation_ok=navigation_ok and cursor==4 and not changed
    text,cursor=edit_text_at_cursor("abcdef",3,TEXT_KEYS.HOME)
    navigation_ok=navigation_ok and cursor==0
    text,cursor=edit_text_at_cursor("abcdef",3,TEXT_KEYS.END_KEY)
    navigation_ok=navigation_ok and cursor==6

    text,cursor,changed=edit_text_at_cursor("abcdef",3,TEXT_KEYS.BACKSPACE)
    local editing_ok=text=="abdef" and cursor==2 and changed
    text,cursor,changed=edit_text_at_cursor("abcdef",3,TEXT_KEYS.DELETE)
    editing_ok=editing_ok and text=="abcef" and cursor==3 and changed
    text,cursor,changed=edit_text_at_cursor("abcdef",3,string.byte("X"))
    editing_ok=editing_ok and text=="abcXdef" and cursor==4 and changed
    text,cursor,changed=edit_text_at_cursor("caf",3,233)
    editing_ok=editing_ok and text=="caf\195\169" and cursor==5 and changed

    local utf8_text="caf\195\169"
    text,cursor=edit_text_at_cursor(utf8_text,#utf8_text,TEXT_KEYS.LEFT)
    local utf8_ok=text==utf8_text and cursor==3
    text,cursor=edit_text_at_cursor(utf8_text,#utf8_text,TEXT_KEYS.BACKSPACE)
    utf8_ok=utf8_ok and text=="caf" and cursor==3

    gfx.setfont(1,UI.font_name,scaled_font_size(13),0)
    local narrow_width=gfx.measurestr("3456")
    local shown,view_start,view_finish,caret_x=editable_text_view("0123456789",10,0,narrow_width,13)
    local view_ok=view_start>0 and view_finish==10 and shown~="" and caret_x<=narrow_width+0.01
    local click_x=gfx.measurestr("ab")
    local click_ok=editable_cursor_from_x("abcdef",0,6,click_x,13)==2

    local selected_text,selected_cursor,selected_anchor,selected_changed=edit_text_selection("abcdef",4,2,string.byte("X"),false,false)
    local selection_ok=selected_text=="abXef" and selected_cursor==3 and selected_anchor==3 and selected_changed
    selected_text,selected_cursor,selected_anchor=edit_text_selection("alpha beta",10,10,TEXT_KEYS.LEFT,true,false)
    selection_ok=selection_ok and selected_text=="alpha beta" and selected_cursor==6 and selected_anchor==6
    selected_text,selected_cursor,selected_anchor=edit_text_selection("alpha beta",10,10,TEXT_KEYS.LEFT,false,true)
    local first,last,has_selection=text_selection_bounds(selected_text,selected_cursor,selected_anchor)
    selection_ok=selection_ok and selected_cursor==9 and selected_anchor==10 and has_selection and first==9 and last==10
    selected_text,selected_cursor,selected_anchor=edit_text_selection("alpha beta",4,4,TEXT_KEYS.CTRL_A,true,false)
    selection_ok=selection_ok and selected_cursor==10 and selected_anchor==0
    local word_first,word_last=text_word_bounds("alpha beta",2)
    selection_ok=selection_ok and word_first==0 and word_last==5

    extended.text_editor=navigation_ok and editing_ok and utf8_ok and view_ok and click_ok and selection_ok
      and context_bar_tag(false,"info","Hover explanation")=="TOOLTIP"
      and context_bar_tag(true,"info","")=="SELECTED ROW"
    if not extended.text_editor then details[#details+1]="Text editor regression test failed: selection replacement, Shift/Ctrl navigation, select-all, word boundaries, caret placement, insertion, deletion, UTF-8 boundaries, horizontal visibility, or TOOLTIP labeling was incorrect." end
  end

  do
    local controls={{label="Disabled",enabled=false},{label="Browse",enabled=true},{label="Help",enabled=true}}
    local focus_ok=next_enabled_focus(controls,nil,1)==2 and next_enabled_focus(controls,2,1)==3 and next_enabled_focus(controls,2,-1)==3
    local saved_path=state.file_path;state.file_path=""
    local disabled_reason=control_unavailable_reason("Validate Only")
    state.file_path=saved_path
    extended.keyboard_ui=focus_ok and disabled_reason:find("Choose a saved",1,true)~=nil
      and UI.mono_font_name=="Consolas" and looks_like_syntax_text("<[4]x2@120, SXT{7}@100->x2, SPT{7}")
      and not looks_like_syntax_text("Build reliable tempo maps")
      and not help_source_line_uses_mono("[N] creates N/4 with a Quarter Note click.")
      and not help_source_line_uses_mono("SXT{N} creates N/4 at underlying BPM x3: Sextuplet.")
      and help_source_line_uses_mono("[4]x2, SXT{7}@100-")
      and help_source_line_uses_mono("VERSE | 120 | ENT(7), [4]x2")
      and help_source_line_is_heading("IN-APP TEMPO EDITING")
      and help_source_line_is_heading("MIDI + MP3 CLICK PACKAGE")
      and help_source_line_is_heading("REAPER TIMEBASE, EXISTING AUDIO/MIDI, AND PRESERVE PITCH")
      and not help_source_line_is_heading("Syntax, editing, logging, and fixes")
      and scratchpad_source_line_uses_mono("Normalized syntax: [4]x2, ENT(7)")
      and not scratchpad_source_line_uses_mono("1. ENT(7) — 1 bar of 7/4.")
      and type(read_from_clipboard)=="function" and type(draw_focus_outline)=="function" and type(handle_base_keyboard)=="function"
    if not extended.keyboard_ui then details[#details+1]="Keyboard/UI regression test failed: focus traversal, precise disabled reason, monospace syntax detection, shortcut routing, or clipboard integration was incorrect." end
  end

  do
    extended.modern_ui=UI.nav_width==168 and UI.status_height==54 and UI.font_name=="Segoe UI" and UI.mono_font_name=="Consolas"
      and UI.colors.canvas[1]==15 and UI.colors.primary[2]==143
      and type(draw_accent_button)=="function" and type(draw_nav_icon)=="function"
      and type(draw_readiness_check)=="function" and type(draw_context_bar)=="function"
      and type(responsive_layout)=="function" and type(edit_text_at_cursor)=="function"
      and type(preview_footer_layout)=="function"
      and type(draw_syntax_scratchpad)=="function" and type(draw_row_popover)=="function"
      and type(set_preview_selection)=="function" and type(play_audition)=="function"
      and type(stop_audition)=="function" and type(update_audition_transport)=="function"
      and type(audition_endpoint_times)=="function" and type(selected_preview_syntax)=="function"
      and type(song_structure_text)=="function" and type(duration_summary_lines)=="function"
      and type(open_selected_workbook)=="function" and type(metronome_enabled_state)=="function"
      and type(set_metronome_enabled)=="function" and type(serialize_tempo_recovery)=="function"
      and type(maybe_offer_tempo_edit_recovery)=="function" and type(run_ui_visual_regression_matrix)=="function"
    if not extended.modern_ui then details[#details+1]="Modern UI contract test failed: navigation width, context-bar height, typography, palette, or required v10.21 render helpers do not match the release design." end
  end

  do
    local edit_sheet=make_map_test_sheet("[4]x2@100, <SXT{5}@135, ENT(7)>x2","[3]@110-","40")
    edit_sheet.cells[2][2].value="100 no accent"
    local base,base_errors=validate_sheets({edit_sheet},"xlsx")
    if base then
      base.source_sheets={edit_sheet};base.file_type="xlsx";base.fingerprint="SELF-TEST";base.source_sha256="SELF-TEST"
    end
    local shifted,shift_error=rewrite_section_overrides(edit_sheet.cells[2][3].value,100,103,true,true)
    local candidate={rows={[2]={bpm_text="103 no accent",parts_text=shifted}},end_bpm_set=true,end_bpm_text="55"}
    local rebuilt,rebuild_errors=base and rebuild_plan_from_tempo_edits(base,candidate) or nil
    local first=rebuilt and rebuilt.flat_parts[1]
    local block_first=rebuilt and rebuilt.flat_parts[2]
    local block_second=rebuilt and rebuilt.flat_parts[3]
    local last=rebuilt and rebuilt.flat_parts[#rebuilt.flat_parts]
    local part_rewrite,part_rewrite_error=rewrite_part_bpm_in_expression(edit_sheet.cells[2][3].value,100,2,1,160)
    local part_expanded=part_rewrite and select(1,parse_parts_expression(part_rewrite,100)) or nil
    local part_repeat_ok=part_expanded and part_expanded[2].underlying_bpm==160 and part_expanded[4].underlying_bpm==160
    local fixed_overrides=rewrite_section_overrides(edit_sheet.cells[2][3].value,100,103,false,true)
    local saved_composition_base=state.base_plan
    state.base_plan=base
    local tracked={rows={[2]={bpm_text="103 no accent",section_shift_overrides=true,part_bpms={}}},end_bpm_set=false,end_bpm_text=""}
    local tracked_composed,tracked_error=base and compose_tempo_edit_row(tracked,2) or nil
    local tracked_plan=tracked_composed and rebuild_plan_from_tempo_edits(base,tracked) or nil
    local tracked_for_selection=clone_tempo_edits(tracked)
    tracked.rows[2].bpm_text="106 no accent"
    local drift_composed,drift_error=compose_tempo_edit_row(tracked,2)
    local drift_plan=drift_composed and rebuild_plan_from_tempo_edits(base,tracked) or nil
    tracked.rows[2].part_bpms=tracked.rows[2].part_bpms or {};tracked.rows[2].part_bpms["2:1"]=160
    local manual_composed,manual_error=compose_tempo_edit_row(tracked,2)
    local manual_plan=manual_composed and rebuild_plan_from_tempo_edits(base,tracked) or nil
    local reverted_section=clone_tempo_edits(tracked)
    local section_removed,section_remove_error=remove_tempo_edit_unit(reverted_section,{kind="section",row=2,key="section:2"})
    local reverted_section_plan=section_removed and rebuild_plan_from_tempo_edits(base,reverted_section) or nil
    state.base_plan=saved_composition_base
    local tracked_first=tracked_plan and tracked_plan.flat_parts[1]
    local tracked_override=tracked_plan and tracked_plan.flat_parts[2]
    local drift_override=drift_plan and drift_plan.flat_parts[2]
    local manual_override=manual_plan and manual_plan.flat_parts[2]
    local reverted_manual=reverted_section_plan and reverted_section_plan.flat_parts[2]
    local reverted_inherited=reverted_section_plan and reverted_section_plan.flat_parts[3]
    local baseline_shift_ok=tracked_first and tracked_first.underlying_bpm==103 and tracked_first.has_override==false
      and tracked_override and tracked_override.underlying_bpm==138
      and drift_override and drift_override.underlying_bpm==141
      and manual_override and manual_override.underlying_bpm==160
      and reverted_section_plan and reverted_section_plan.sections[1].bpm==100
      and reverted_manual and reverted_manual.underlying_bpm==160
      and reverted_inherited and reverted_inherited.underlying_bpm==100
    local recovery_text=manual_plan and serialize_tempo_recovery({path="C:\\Maps\\Song.xlsx",fingerprint="123:456",source_sha256="ABCDEF",edits=tracked,log={"Section changed","Part changed"}}) or nil
    local recovery_record,recovery_parse_error=recovery_text and deserialize_tempo_recovery(recovery_text) or nil,nil
    local recovery_plan=recovery_record and rebuild_plan_from_tempo_edits(base,recovery_record.edits) or nil
    local recovery_scope=recovery_plan and tempo_edit_scope(base,recovery_plan) or nil
    local recovery_binding_ok=recovery_record and tempo_recovery_matches_plan(recovery_record,"c:/maps/song.xlsx",{fingerprint="123:456",source_sha256="ABCDEF"})
      and not tempo_recovery_matches_plan(recovery_record,"C:/Maps/Song.xlsx",{fingerprint="999:999",source_sha256="ABCDEF"})
      and not tempo_recovery_matches_plan(recovery_record,"C:/Maps/Song.xlsx",{fingerprint="123:456",source_sha256="DIFFERENT"})
    local recovery_ok=recovery_record and recovery_record.path=="C:\\Maps\\Song.xlsx" and recovery_record.fingerprint=="123:456"
      and recovery_record.source_sha256=="ABCDEF" and #recovery_record.log==2 and recovery_plan~=nil
      and recovery_scope and recovery_scope.sections==1 and recovery_scope.parts==3 and not recovery_scope.end_changed
      and recovery_record.edits.rows[2].section_shift_overrides==true and recovery_record.edits.rows[2].part_bpms["2:1"]==160 and recovery_binding_ok
    local selection_revert_ok=false
    if base and tracked_plan then
      local saved={base_plan=state.base_plan,plan=state.plan,tempo_edits=state.tempo_edits,preview_rows=state.preview_rows,changed=state.staged_changed_rows,details=state.staged_change_details,selected=state.selected_preview_row,anchor=state.preview_selection_anchor,first=state.preview_selection_start,last=state.preview_selection_end}
      state.base_plan=base;state.plan=tracked_plan;state.tempo_edits=tracked_for_selection;state.preview_rows=preview_rows(tracked_plan)
      refresh_staged_row_changes();state.selected_preview_row=2;state.preview_selection_anchor=2;state.preview_selection_start=2;state.preview_selection_end=2
      local selected_candidate,selected_plan,selected_summary=selected_revert_candidate(2,2)
      selection_revert_ok=selected_candidate and selected_plan and selected_summary and tempo_edits_empty(selected_candidate)
        and selected_summary.selected_count==1 and #selected_summary.units==1 and selected_summary.units[1].kind=="section"
        and selected_plan.sections[1].bpm==100 and selected_plan.sections[1].no_accent==true
      state.base_plan=saved.base_plan;state.plan=saved.plan;state.tempo_edits=saved.tempo_edits;state.preview_rows=saved.preview_rows;state.staged_changed_rows=saved.changed;state.staged_change_details=saved.details;state.selected_preview_row=saved.selected;state.preview_selection_anchor=saved.anchor;state.preview_selection_start=saved.first;state.preview_selection_end=saved.last
    end
    local staged_highlight_ok=false
    if base and rebuilt then
      local saved_base,saved_plan,saved_rows=state.base_plan,state.plan,state.preview_rows
      local saved_changes,saved_details=state.staged_changed_rows,state.staged_change_details
      state.base_plan=base;state.plan=rebuilt;state.preview_rows=preview_rows(rebuilt);refresh_staged_row_changes()
      local changed_count=0;for _ in pairs(state.staged_changed_rows or {}) do changed_count=changed_count+1 end
      staged_highlight_ok=changed_count>0 and next(state.staged_change_details or {})~=nil
      state.base_plan,state.plan,state.preview_rows=saved_base,saved_plan,saved_rows
      state.staged_changed_rows,state.staged_change_details=saved_changes,saved_details
    end
    extended.tempo_edit=base~=nil and base_errors==nil and shifted~=nil and shift_error==nil
      and rebuilt~=nil and rebuild_errors==nil and rebuilt.sections[1].no_accent==true
      and rebuilt.count_in_bpm==103 and first.underlying_bpm==103 and first.has_override==false
      and block_first.underlying_bpm==138 and block_first.effective_bpm==414
      and block_second.underlying_bpm==103 and last.ramp_target_bpm==55
      and part_repeat_ok and fixed_overrides and fixed_overrides:find("SXT{5}@135",1,true)~=nil
      and format_section_bpm_cell(103,true)=="103 no accent" and staged_highlight_ok and baseline_shift_ok and selection_revert_ok and recovery_ok
    if not extended.tempo_edit then
      details[#details+1]="Staged tempo-edit/recovery test failed: inherited Section BPM, No Accent, baseline-relative override shifting, selection-source reversion, recovery serialization/fingerprint metadata, changed Section/Part scope, independent Part tracking, first-Part normalization, repeated Block ownership, END destination, or calculated REAPER BPM was incorrect. "..tostring(recovery_parse_error or tracked_error or drift_error or manual_error or section_remove_error or shift_error or part_rewrite_error or (rebuild_errors and table.concat(rebuild_errors,"; ")) or "")
    end
  end

  do
    local ordinary=parse_part("[4]x2",120)
    local events,duration,audio_error=click_events_for_parts({ordinary},1)
    local half_events,half_duration=click_events_for_parts({ordinary},0.5)
    local ramped=parse_part("[4]x2@120--",120);ramped.ramp_target_bpm=60
    local ramp_events,ramp_duration=click_events_for_parts({ramped},1)
    local temp_name=make_temp_path(".wav")
    local wav_ok,wav_error=events and write_click_preview_wav(temp_name,events,duration,DEFAULT_CLICK_A_HZ,DEFAULT_CLICK_B_HZ)
    local wav=wav_ok and read_file(temp_name) or nil
    os.remove(temp_name)
    extended.audio_schedule=events and #events==8 and nearly_equal(duration,4,1e-6)
      and half_events and #half_events==8 and nearly_equal(half_duration,8,1e-6)
      and ramp_events and #ramp_events==8 and nearly_equal(ramp_duration,120*8/(120+60),1e-6)
      and wav_ok and wav and wav:sub(1,4)=="RIFF" and wav:sub(9,12)=="WAVE" and #wav>44
      and #simple_tempo_audition_parts(120)==1
      and select(1,click_events_for_parts(simple_tempo_audition_parts(120),1))~=nil
      and #select(1,click_events_for_parts(simple_tempo_audition_parts(120),1))==4
    local saved_tempo_value=state.tempo_preview_field.value;state.tempo_preview_field.value="137.5";local preview_bpm=tempo_preview_bpm();state.tempo_preview_field.value="401";local invalid_preview_bpm=tempo_preview_bpm();state.tempo_preview_field.value=saved_tempo_value
    extended.audio_schedule=extended.audio_schedule and preview_bpm==137.5 and invalid_preview_bpm==nil
    if not extended.audio_schedule then details[#details+1]="Audio-preview test failed: Quarter Note timing, 50% timing, linear-Ramp duration, finite click count, Tempo Preview BPM-field validation, or temporary PCM WAV format was incorrect. "..tostring(audio_error or wav_error or "") end
  end

  do
    local package_plan,package_errors=validate_sheets({make_map_test_sheet("[4]x2, ENT(7)@100-, SXT{5}@120",nil,"90")},"xlsx")
    if package_plan then package_plan.file_path="C:\\Songs\\Click Package Test.xlsx" end
    local package_parts=package_plan and click_package_parts(package_plan) or nil
    local package_expected_clicks,package_count_error=expected_click_count(package_parts)
    local package_events,package_duration,package_audio_error
    if package_parts then package_events,package_duration,package_audio_error=click_events_for_parts(package_parts,1,CLICK_EXPORT_MAX_SECONDS) end
    local midi_bytes,midi_model,midi_error
    if package_plan then midi_bytes,midi_model,midi_error=build_click_midi(package_plan) end
    local generic_midi_bytes,generic_midi_model,generic_midi_error
    if package_plan then generic_midi_bytes,generic_midi_model,generic_midi_error=build_click_midi(package_plan,true) end
    local midi_ok,midi_verify_error=false,"MIDI unavailable"
    if midi_bytes then midi_ok,midi_verify_error=verify_click_midi_bytes(midi_bytes,midi_model) end
    local mp3_path,midi_path=click_package_output_paths("C:\\Exports\\Song.mid")
    local batch_text=mp3_batch_job_text("C:\\Temp\\source.wav","C:\\Temp\\target.mp3")
    local transaction_probe,transaction_probe_error=run_click_package_transaction(function() return {midi="probe.mid",mp3="probe.mp3"} end)
    local failed_probe,failed_probe_error=run_click_package_transaction(function() error("intentional export transaction failure") end)
    extended.click_package=package_plan~=nil and package_errors==nil
      and package_parts and package_parts[1] and package_parts[1].canonical=="COUNT IN"
      and package_events and package_expected_clicks and #package_events==package_expected_clicks and #package_events>0 and nearly_equal(package_events[1].time,0,1e-9)
      and nearly_equal(package_duration,package_plan.total_duration_with_count_in,0.001)
      and midi_ok and midi_model and midi_model.note_count==package_expected_clicks and midi_model.note_count==#package_events
      and midi_model.note_ticks[#midi_model.note_ticks]<midi_model.end_tick
      and midi_model.tempo_event_count>#package_plan.flat_parts
      and generic_midi_bytes and generic_midi_model and generic_midi_model.generic_marker_names==true
      and generic_midi_model.marker_names[1]=="COUNT IN"
      and generic_midi_model.marker_names[2]=="PART 1"
      and generic_midi_model.marker_names[#generic_midi_model.marker_names]=="END"
      and generic_midi_model.section_marker_count==midi_model.section_marker_count
      and generic_midi_bytes:find("PART 1",1,true)~=nil
      and midi_model.marker_names[2]==package_plan.sections[1].name
      and mp3_path=="C:\\Exports\\Song.mp3" and midi_path=="C:\\Exports\\Song.mid"
      and batch_text:find("C:\\Temp\\source.wav\tC:\\Temp\\target.mp3",1,true)~=nil
      and batch_text:find(DEFAULT_MP3_RENDER_CONFIG,1,true)~=nil
      and type(transaction_probe)=="table" and transaction_probe.midi=="probe.mid" and transaction_probe.mp3=="probe.mp3" and transaction_probe_error==nil
      and failed_probe==nil and tostring(failed_probe_error):find("intentional export transaction failure",1,true)~=nil
    if not extended.click_package then
      details[#details+1]="MIDI/MP3 click-package contract failed: exact required/audio/MIDI click counts, COUNT IN origin, shared duration, type-1 MIDI verification, workbook/generic marker naming, Ramp tempo events, END boundary, output naming, REAPER MP3 job configuration, or success-result propagation was incorrect. "..tostring(package_count_error or package_audio_error or midi_error or generic_midi_error or midi_verify_error or transaction_probe_error or failed_probe_error or "")
    end
  end

  do
    local visual_ok,visual_failures=run_ui_visual_regression_matrix()
    extended.responsive_layout=visual_ok
    extended.visual_regression=visual_ok
    if not visual_ok then details[#details+1]="Automated UI visual-regression matrix failed: "..table.concat(visual_failures,"; ").."." end
  end

  do
    local modern_calls,legacy_calls=0,0
    local modern_api={
      GetUserFileName=function() modern_calls=modern_calls+1;return true,"C:\\Maps\\Modern.xlsx" end,
      GetUserFileNameForRead=function() legacy_calls=legacy_calls+1;return true,"C:\\Maps\\Wrong.csv" end
    }
    local legacy_api={
      GetUserFileNameForRead=function() legacy_calls=legacy_calls+1;return true,"C:\\Maps\\Legacy.csv" end
    }
    local invalid_api={
      GetUserFileNameForRead=function() return true,"C:\\Maps\\Unsupported.ods" end
    }
    local cancel_api={
      GetUserFileNameForRead=function() return false,"" end
    }
    local modern_path=select(1,choose_workbook_path("",modern_api))
    local legacy_path=select(1,choose_workbook_path("",legacy_api))
    local invalid_path,invalid_error,invalid_cancelled=choose_workbook_path("",invalid_api)
    local cancelled_path,cancelled_error,cancelled=choose_workbook_path("",cancel_api)
    local missing_path,missing_error,missing_cancelled=choose_workbook_path("",{})
    extended.browse_compatibility=workbook_open_dialog_kind(modern_api)=="modern"
      and workbook_open_dialog_kind(legacy_api)=="legacy" and workbook_open_dialog_kind({})==nil
      and modern_path=="C:\\Maps\\Modern.xlsx" and legacy_path=="C:\\Maps\\Legacy.csv"
      and modern_calls==1 and legacy_calls==1
      and invalid_path==nil and tostring(invalid_error):find("WB-003",1,true)~=nil and invalid_cancelled==false
      and cancelled_path==nil and cancelled_error==nil and cancelled==true
      and missing_path==nil and tostring(missing_error):find("WB-015",1,true)~=nil and missing_cancelled==false
    if not extended.browse_compatibility then
      details[#details+1]="Workbook Browse compatibility test failed: the current chooser must be preferred, the legacy GetUserFileNameForRead fallback must work, cancellation must remain silent, and non-XLSX/CSV selections must be rejected."
    end
  end

  do
    local safe_text=read_file(script_directory().."Bildibeat_Click_Track_Mapper_Safe_Mode_v10_21.lua") or ""
    local safe_contract={
      "Bildibeat_Click_Track_Mapper_v10_21.lua",
      'SetExtState(EXTSTATE_SECTION, "safe_mode_once", "1", false)',
      "pcall(dofile, main_path)",
      'DeleteExtState(EXTSTATE_SECTION, "safe_mode_once", false)',
      "Dynamic resizing","pane-scoped TOOLTIP","Larger text throughout app","wrapped and scrollable errors",
      "ENT(N)","SXT{N}","QNT{N}","SPT{N}","Eighth Note Triplet","Sextuplet","Quintuplet","Septuplet",
      "x1.5","x3","x5","x7","120 no accent","1760 Hz","1600 Hz","native metronome",
      "staged Section, Part, and END underlying-BPM editing","yellow","Revert Tempo Edit","Undo Last Build",
      "Save Updated Workbook Copy","adopted as the new","User-Friendly Song Structure","Simplified Readout",
      "Generic Part Names","MIDI marker metadata","Duration Calculator","Page numbering is left","Send to Scratchpad",
      "explicit underlying","Copy Syntax is selection-aware","following Part's first click",
      "Up/Down/Home/End/Enter","Play, Stop, Loop, and 50% Speed","Tempo Preview","Syntax Scratchpad",
      "Play Preview","Remember Layout","Restore Default Layout","Diagnostics","Unload Current Workbook",
      "Segoe UI","Consolas","pre-build and post-build prompts","SWS dependency",
      "tempo-edit recovery restoration","exact number of affected Sections","fingerprint/source-hash-bound recovery record","automated golden compact",
      "GetUserFileNameForRead","Preserve Audio Exactly","Conform Audio to New Tempo","audio signatures",
      "Create Verified Workbook From Open Project","RCN-001 through RCN-011","one-for-one"
    }
    local safe_missing={}
    for _,required in ipairs(safe_contract) do
      if safe_text:find(required,1,true)==nil then safe_missing[#safe_missing+1]=required end
    end
    extended.safe=#safe_missing==0
    if not extended.safe then
      details[#details+1]="Safe Mode integration-contract test failed. Missing: "..table.concat(safe_missing,", ").."."
    end
  end

  test_progress("project reconstruction contracts")
  do
    local inference_pieces={
      {numerator=4,denominator=4,bpm=120,repeats=2,linear=false},
      {numerator=7,denominator=4,bpm=180,repeats=1,linear=false},
      {numerator=4,denominator=4,bpm=120,repeats=2,linear=false},
      {numerator=7,denominator=4,bpm=180,repeats=1,linear=false}
    }
    local inferred_bpm=choose_reconstruction_section_bpm(inference_pieces,nil)
    local tokens={}
    for _,piece in ipairs(inference_pieces) do tokens[#tokens+1]=select(1,reconstruction_part_token(piece,inferred_bpm)) end
    local blocks=compress_reconstruction_blocks(tokens,inference_pieces)
    local ambiguous_bpm=choose_reconstruction_section_bpm({{numerator=4,denominator=4,bpm=300,repeats=1,linear=false}},nil)
    local ambiguous_token=reconstruction_part_token({numerator=4,denominator=4,bpm=300,repeats=1,linear=false},ambiguous_bpm)
    local ramp_token=reconstruction_part_token({numerator=5,denominator=4,bpm=600,repeats=2,linear=true},120)
    local generated_rows={
      {"SECTION NAME","BPM","PARTS"},
      {"INTRO","120","<[4]x2, ENT(7)>x2"},
      {"OUTRO","120 no accent",ramp_token},
      {"END","90",""}
    }
    local generated_plan,generated_errors=validate_sheets(reconstruction_sheet(generated_rows),"xlsx")
    local rcn_matches=search_error_reference("RCN-008")
    extended.reconstruction=inferred_bpm==120
      and table.concat(tokens,", ")=="[4]x2, ENT(7), [4]x2, ENT(7)"
      and #blocks==1 and blocks[1]=="<[4]x2, ENT(7)>x2"
      and ambiguous_bpm==300 and ambiguous_token=="[4]"
      and ramp_token=="QNT{5}x2--"
      and generated_plan~=nil and generated_errors==nil and generated_plan.block_count==1
      and #rcn_matches==1 and rcn_matches[1].code=="RCN-008"
    if not extended.reconstruction then details[#details+1]="Project-reconstruction contract failed: exact-ratio tuplet inference, ambiguity fallback, repeat/Block compression, ramp spelling, generated-sheet validation, or RCN Error Reference search is incorrect." end
  end

  test_progress("documentation contract")
  do
    local readme=read_file(script_directory().."Bildibeat_Click_Track_Mapper_README_v10_21.txt") or ""
    local _,latest_readme_name=find_latest_readme()
    local example_rows="SECTION NAME | BPM | PARTS\nINTRO | 120 | [4]x2, (7)x3@135--\nVERSE | 160 | {9}x2@160, *11*x2@170-\nCHORUS | 120 | ENT(4)x2@120, SXT{7}x2@100-\nBRIDGE | 90 | QNT{5}x2@90-, <[3]x2@140, SXT{5}@110->x2\nBREAKDOWN | 110 no accent | SPT{7}x2@110-\nOUTRO | 130 | [4]x2@130--\nEND | 90 |"
    extended.documentation=COMPLETE_WORKBOOK_EXAMPLE:find(example_rows,1,true)~=nil
      and HELP_TEXT:find(example_rows,1,true)~=nil and readme:find(example_rows,1,true)~=nil
      and HELP_TEXT:find("BILDIBEAT CLICK TRACK MAPPER V10.21 HELP",1,true)~=nil
      and HELP_TEXT:find("CORE TERMS",1,true)~=nil and HELP_TEXT:find("SYNTAX BADGES AND PLAIN ENGLISH",1,true)~=nil
      and HELP_TEXT:find("REAPER PROJECT SAVE WORKFLOW",1,true)~=nil and HELP_TEXT:find("HISTORY DATES",1,true)~=nil
      and HELP_TEXT:find("Larger text throughout app",1,true)~=nil and HELP_TEXT:find("There are no J or R shortcuts",1,true)~=nil
      and HELP_TEXT:find("selected [4]x2 therefore plays exactly eight clicks",1,true)~=nil and HELP_TEXT:find("selection-aware Copy Syntax",1,true)~=nil
      and HELP_TEXT:find("ENT(N) creates N/4 at underlying BPM x1.5: Eighth Note Triplet.",1,true)~=nil
      and HELP_TEXT:find("SXT{N} creates N/4 at underlying BPM x3: Sextuplet.",1,true)~=nil
      and HELP_TEXT:find("QNT{N} creates N/4 at underlying BPM x5: Quintuplet.",1,true)~=nil
      and HELP_TEXT:find("SPT{N} creates N/4 at underlying BPM x7: Septuplet.",1,true)~=nil
      and HELP_TEXT:find("IN-APP TEMPO EDITING",1,true)~=nil and HELP_TEXT:find("UPDATED WORKBOOK COPY",1,true)~=nil
      and HELP_TEXT:find("Revert Tempo Edit restores the selected yellow row",1,true)~=nil
      and HELP_TEXT:find("never a cumulative drift",1,true)~=nil
      and HELP_TEXT:find("UNSAVED EDIT PROTECTION AND SESSION RECOVERY",1,true)~=nil
      and HELP_TEXT:find("exact number of affected Sections and logical source Parts",1,true)~=nil
      and HELP_TEXT:find("AUTOMATED VISUAL REGRESSION",1,true)~=nil
      and HELP_TEXT:find("WORKBOOK BROWSE COMPATIBILITY",1,true)~=nil and HELP_TEXT:find("GetUserFileNameForRead",1,true)~=nil
      and HELP_TEXT:find("TEMPO PREVIEW",1,true)~=nil and HELP_TEXT:find("Play Preview renders and plays",1,true)~=nil
      and HELP_TEXT:find("AUDIO HANDLING FOR TEMPO-MAP BUILDS",1,true)~=nil and HELP_TEXT:find("AUD-005 through AUD-008",1,true)~=nil
      and HELP_TEXT:find("MIDI + MP3 CLICK PACKAGE",1,true)~=nil and HELP_TEXT:find("75 ms audio safety tail",1,true)~=nil and HELP_TEXT:find("subsequent MIDI click-package marker metadata",1,true)~=nil
      and HELP_TEXT:find("VALIDATE AGAINST OPEN PROJECT",1,true)~=nil and HELP_TEXT:find("retired Validation Diff button is not present",1,true)~=nil
      and HELP_TEXT:find("CREATE VERIFIED WORKBOOK FROM OPEN PROJECT",1,true)~=nil and HELP_TEXT:find("RCN-001 through RCN-011",1,true)~=nil
      and readme:find("Section names create standard REAPER markers",1,true)~=nil
      and readme:find("ENT(N)",1,true)~=nil and readme:find("SXT{N}",1,true)~=nil and readme:find("QNT{N}",1,true)~=nil
      and readme:find("SPT{N}",1,true)~=nil and readme:find("120 no accent",1,true)~=nil
      and readme:find("Eighth Note Triplet",1,true)~=nil and readme:find("Sextuplet",1,true)~=nil
      and readme:find("Repeat x2",1,true)~=nil and readme:find("BPM Override: 150",1,true)~=nil
      and readme:find("Ramp: 1 Bar",1,true)~=nil and readme:find("Block Pass 1 of 2",1,true)~=nil
      and readme:find("Reset Syntax Example restores Section BPM 120",1,true)~=nil
      and readme:find("SONG STRUCTURE READOUT",1,true)~=nil and readme:find("MM-DD-YYYY",1,true)~=nil
      and readme:find("Simplified Readout",1,true)~=nil and readme:find("Duration Calculator",1,true)~=nil
      and readme:find("Generic Part Names",1,true)~=nil and readme:find("subsequent MIDI click-package marker metadata",1,true)~=nil and readme:find("following Part's first click",1,true)~=nil
      and readme:find("about 50 percent, with a minimum six-point increase",1,true)~=nil
      and readme:find("stop playback at end of loop if repeat is disabled",1,true)~=nil
      and readme:find("selection-aware Copy Syntax",1,true)~=nil
      and readme:find("native metronome",1,true)~=nil and readme:find("Open Workbook action",1,true)~=nil
      and readme:find("Normal app typography",1,true)~=nil
      and readme:find("Segoe UI for explanations",1,true)~=nil and readme:find("Consolas only for syntax entry",1,true)~=nil
      and readme:find("Shift+Up / Shift+Down",1,true)~=nil and readme:find("50% Speed",1,true)~=nil
      and readme:find("REAPER TIMEBASE, BUILD AUDIO POLICY, AND PRESERVE PITCH",1,true)~=nil
      and readme:find("Conform Audio to New Tempo",1,true)~=nil and readme:find("AUD-008",1,true)~=nil
      and readme:find("Preserve pitch in audio items when changing master playrate",1,true)~=nil
      and readme:find("OriginalSong_CTM_PREBUILD_BACKUP_YYYY-MM-DD_HHMMSS.RPP",1,true)~=nil
      and readme:find("OriginalSong_CTM_COMPLETED_BUILD_YYYY-MM-DD_HHMMSS_ID-01FB.RPP",1,true)~=nil
      and readme:find("SYN-022: Block expansion safety limit exceeded",1,true)~=nil
      and readme:find("IN-APP TEMPO EDITING",1,true)~=nil and readme:find("UPDATED WORKBOOK COPY",1,true)~=nil
      and readme:find("TEMPO_UPDATE",1,true)~=nil and readme:find("AUD-004",1,true)~=nil
      and readme:find("Tempo Preview",1,true)~=nil and readme:find("Play Preview",1,true)~=nil
      and readme:find("Send to Scratchpad",1,true)~=nil and readme:find("yellow",1,true)~=nil
      and readme:find("Revert Tempo Edit is selection-aware",1,true)~=nil
      and readme:find("cannot accumulate numerical drift",1,true)~=nil and readme:find("EDT-005",1,true)~=nil
      and readme:find("UNSAVED TEMPO-EDIT PROTECTION AND SESSION RECOVERY",1,true)~=nil
      and readme:find("REC-001",1,true)~=nil and readme:find("REC-004",1,true)~=nil
      and readme:find("golden automated visual-regression matrix",1,true)~=nil
      and readme:find("Unload Current Workbook",1,true)~=nil and readme:find("Remember Layout",1,true)~=nil
      and readme:find("GetUserFileNameForRead",1,true)~=nil and readme:find("WB-015",1,true)~=nil
      and readme:find("MIDI + MP3 CLICK PACKAGE",1,true)~=nil and readme:find("CPX-001 through CPX-006",1,true)~=nil
      and readme:find("VALIDATE AGAINST OPEN PROJECT",1,true)~=nil and readme:find("retired Validation Diff control is absent",1,true)~=nil
      and readme:find("CREATE VERIFIED WORKBOOK FROM OPEN PROJECT",1,true)~=nil and readme:find("RCN-001 through RCN-011",1,true)~=nil
      and latest_readme_name=="Bildibeat_Click_Track_Mapper_README_v10_21.txt"
    if not extended.documentation then
      local missing={}
      local checks={
        {"copy example",COMPLETE_WORKBOOK_EXAMPLE:find(example_rows,1,true)~=nil},{"Help example",HELP_TEXT:find(example_rows,1,true)~=nil},{"README example",readme:find(example_rows,1,true)~=nil},
        {"Help title",HELP_TEXT:find("BILDIBEAT CLICK TRACK MAPPER V10.21 HELP",1,true)~=nil},{"Help SPT",HELP_TEXT:find("SPT{N} creates N/4 at underlying BPM x7: Septuplet.",1,true)~=nil},
        {"README section marker definition",readme:find("Section names create standard REAPER markers",1,true)~=nil},{"README SPT",readme:find("SPT{N}",1,true)~=nil},
        {"README no accent",readme:find("120 no accent",1,true)~=nil},{"README Simplified",readme:find("Simplified Readout",1,true)~=nil},{"README Duration",readme:find("Duration Calculator",1,true)~=nil},{"README generic names",readme:find("Generic Part Names",1,true)~=nil},
        {"README Shift arrows",readme:find("Shift+Up / Shift+Down",1,true)~=nil},{"README half speed",readme:find("50% Speed",1,true)~=nil},{"README timebase",readme:find("REAPER TIMEBASE, BUILD AUDIO POLICY, AND PRESERVE PITCH",1,true)~=nil},
        {"README preserve pitch",readme:find("Preserve pitch in audio items when changing master playrate",1,true)~=nil},{"README block code",readme:find("SYN-022: Block expansion safety limit exceeded",1,true)~=nil},
        {"Help tempo editing",HELP_TEXT:find("IN-APP TEMPO EDITING",1,true)~=nil},{"Help selection-aware revert",HELP_TEXT:find("Revert Tempo Edit restores the selected yellow row",1,true)~=nil},{"Help recovery",HELP_TEXT:find("UNSAVED EDIT PROTECTION AND SESSION RECOVERY",1,true)~=nil},{"Help visual regression",HELP_TEXT:find("AUTOMATED VISUAL REGRESSION",1,true)~=nil},{"Help workbook copy",HELP_TEXT:find("UPDATED WORKBOOK COPY",1,true)~=nil},{"Help Tempo Preview",HELP_TEXT:find("TEMPO PREVIEW",1,true)~=nil},
        {"Help Browse compatibility",HELP_TEXT:find("GetUserFileNameForRead",1,true)~=nil},{"Help build audio",HELP_TEXT:find("AUDIO HANDLING FOR TEMPO-MAP BUILDS",1,true)~=nil and HELP_TEXT:find("AUD-008",1,true)~=nil},{"Help click package",HELP_TEXT:find("MIDI + MP3 CLICK PACKAGE",1,true)~=nil and HELP_TEXT:find("75 ms audio safety tail",1,true)~=nil},{"Help project comparison",HELP_TEXT:find("VALIDATE AGAINST OPEN PROJECT",1,true)~=nil and HELP_TEXT:find("Validation Diff button is not present",1,true)~=nil and HELP_TEXT:find("can be auditioned without rebuilding",1,true)~=nil},{"Help project reconstruction",HELP_TEXT:find("CREATE VERIFIED WORKBOOK FROM OPEN PROJECT",1,true)~=nil and HELP_TEXT:find("RCN-011",1,true)~=nil},
        {"README tempo editing",readme:find("IN-APP TEMPO EDITING",1,true)~=nil},{"README selection-aware revert",readme:find("Revert Tempo Edit is selection-aware",1,true)~=nil},{"README recovery",readme:find("UNSAVED TEMPO-EDIT PROTECTION AND SESSION RECOVERY",1,true)~=nil},{"README recovery codes",readme:find("REC-004",1,true)~=nil},{"README visual regression",readme:find("golden automated visual-regression matrix",1,true)~=nil},{"README EDT-005",readme:find("EDT-005",1,true)~=nil},{"README workbook copy",readme:find("UPDATED WORKBOOK COPY",1,true)~=nil},{"README audio codes",readme:find("AUD-004",1,true)~=nil and readme:find("AUD-008",1,true)~=nil},{"README build audio",readme:find("Conform Audio to New Tempo",1,true)~=nil},{"README Scratchpad handoff",readme:find("Send to Scratchpad",1,true)~=nil},{"README staged row highlighting",readme:find("yellow",1,true)~=nil},{"README Browse compatibility",readme:find("GetUserFileNameForRead",1,true)~=nil and readme:find("WB-015",1,true)~=nil},{"README click package",readme:find("MIDI + MP3 CLICK PACKAGE",1,true)~=nil and readme:find("CPX-006",1,true)~=nil},{"README project comparison",readme:find("VALIDATE AGAINST OPEN PROJECT",1,true)~=nil and readme:find("Validation Diff control is absent",1,true)~=nil and readme:find("can therefore be auditioned without rebuilding",1,true)~=nil},{"README project reconstruction",readme:find("CREATE VERIFIED WORKBOOK FROM OPEN PROJECT",1,true)~=nil and readme:find("RCN-011",1,true)~=nil},
        {"latest README",latest_readme_name=="Bildibeat_Click_Track_Mapper_README_v10_21.txt"}
      }
      for _,check in ipairs(checks) do if not check[2] then missing[#missing+1]=check[1] end end
      details[#details+1]="Documentation synchronization test failed. Missing/mismatched: "..table.concat(missing,", ").."."
    end
  end

  do
    local seen,duplicate={},nil
    for _,entry in ipairs(ERROR_REFERENCE) do if seen[entry.code] then duplicate=entry.code;break end;seen[entry.code]=true end
    extended.reference_codes=duplicate==nil
    if duplicate then details[#details+1]="Error Reference code uniqueness test failed: duplicate "..duplicate.."." end
  end

  do
    local source=read_file(script_directory().."Bildibeat_Click_Track_Mapper_v10_21.lua") or ""
    extended.reconstruction_source=source:find("function collect_reconstruction_project_model",1,true)~=nil
      and source:find("function reconstruct_workbook_plan_from_project",1,true)~=nil
      and source:find("function write_reconstructed_xlsx",1,true)~=nil
      and source:find("function write_reconstructed_csv",1,true)~=nil
      and source:find("function create_workbook_from_open_project",1,true)~=nil
      and source:find("function reconstruction_project_still_matches",1,true)~=nil
      and source:find("changed while the save dialog was open",1,true)~=nil
      and source:find("changed while the workbook was being written",1,true)~=nil
      and source:find('"Create Verified Workbook From Open Project..."',1,true)~=nil
      and source:find('code="RCN-001"',1,true)~=nil and source:find('code="RCN-011"',1,true)~=nil
      and source:find("compare_validated_plan_to_project(verified_plan,current.proj)",1,true)~=nil
    if not extended.reconstruction_source then details[#details+1]="Project-reconstruction integration contract failed: analyzer, exact verification, XLSX/CSV writers, UI action, RCN coverage, or post-save verification is incomplete." end
  end

  do
    local source=read_file(script_directory().."Bildibeat_Click_Track_Mapper_v10_21.lua") or ""
    extended.build_audio_contract=source:find("function analyze_audio_tempo_handling",1,true)~=nil
      and source:find("function prepare_audio_for_tempo_build",1,true)~=nil
      and source:find("function finalize_audio_after_tempo_build",1,true)~=nil
      and source:find("marker/tempo and audio signatures were verified",1,true)~=nil
      and source:find('code="AUD-005"',1,true)~=nil and source:find('code="AUD-008"',1,true)~=nil
      and source:find('"Audio: Preserve"',1,true)~=nil and source:find('"Audio: Conform"',1,true)~=nil
    if not extended.build_audio_contract then details[#details+1]="Build-audio integration contract failed: Preserve/Conform analysis, transaction verification, UI controls, or AUD-005 through AUD-008 are missing." end
  end

  do
    local source=read_file(script_directory().."Bildibeat_Click_Track_Mapper_v10_21.lua") or ""
    extended.project_comparison=source:find("function compare_validated_plan_to_project",1,true)~=nil
      and source:find("function validate_against_open_project",1,true)~=nil
      and source:find('"Validate Against Open Project"',1,true)~=nil
      and source:find('code="PRJ-007"',1,true)~=nil
      and source:find("last_verified_project_match",1,true)~=nil
      and source:find("project_signature==matched.project_signature",1,true)~=nil
      and source:find("draw_button("..'"Validation Diff"',1,true)==nil
      and source:find("function show_".."validation_diff",1,true)==nil
    if not extended.project_comparison then details[#details+1]="Open-project comparison contract failed: the separate read-only comparison, audition authorization, PRJ-007 coverage, adaptive Workbook control, or Validation Diff retirement is incomplete." end
  end

  do
    local source=read_file(script_directory().."Bildibeat_Click_Track_Mapper_v10_21.lua") or ""
    local persistent_local_lines=0
    local persistent_function_lines=0
    for line in (source.."\n"):gmatch("(.-)\n") do if line:match("^local%s+") then persistent_local_lines=persistent_local_lines+1 end;if line:match("^local%s+function%s+") then persistent_function_lines=persistent_function_lines+1 end end
    extended.local_headroom=persistent_local_lines<80 and persistent_function_lines==0
    if not extended.local_headroom then details[#details+1]="Lua local-headroom test failed: the release should keep implementation functions in the App namespace and fewer than 80 top-level local declaration lines." end
  end

  local extended_ok=true
  for _,ok in pairs(extended) do if not ok then extended_ok=false;break end end

  local all_ok = passed == #cases and map_ok and differing_override_rejected and matching_override_allowed
    and reserved_name_rejected and near_override_rejected and cross_ramp_ok and final_ramp_ok
    and ordinary_end_ok and invalid_end_ok and no_accent_ok and search_ok and reference_format_ok and readme_version_ok and extended_ok
  local msg = string.format(
    "%d of %d parser cases passed. COUNT IN map: %s. First-part BPM: differing %s, matching %s, precision edge %s. Reserved COUNT IN name: %s. Cross-section ramp: %s. Final ramp to END: %s. Ordinary END: %s. END validation: %s. No-accent sections: %s. Error Reference search/format: %s/%s. README version ordering: %s. Extended v10.21 regression suite: %s (read-only open-project workbook reconstruction with exact marker-name preservation, conservative repeat/Block/tuplet inference, verified XLSX/CSV writers, RCN errors, and mandatory post-save round-trip verification; synchronized MIDI/MP3 click-package scheduling, exact click-count, and END-boundary contracts; explicit read-only open-project structural comparison with Validation Diff retirement; selection-aware workbook-baseline tempo reversion; fingerprint-bound staged-edit recovery and exact discard scope; staged Section/Part/END tempo editing; drift-free proportional override rules; verified CSV/XLSX workbook copies; Preserve/Conform build-audio contracts; Tempo Preview; Scratchpad audio scheduling; ENT(N) Eighth Note Triplet x1.5, SXT{N} Sextuplet x3, QNT{N} Quintuplet x5, SPT{N} Septuplet x7; simplified readouts; exact duration math; multi-row audition controls; native metronome enable/restore contracts; editable click frequencies; obsolete-form rejection; right-click row popover/actions; active-ramp gating; Syntax Scratchpad normalization/expansion; selection/clipboard editor contracts; keyboard Preview navigation; precise disabled reasons; Segoe UI prose with scoped Consolas syntax typography; proportional musician-readout typography; pane-scoped bottom-bar context; golden compact/standard/wide/Larger Text visual-regression layouts; synchronized Help/Copy/README/Error Reference; golden maps; 500-part stress; repeated rebuild simulation; rollback normalization; preferences; suggestions; modal routing; Safe Mode; unique reference codes; and local-limit headroom). Repeat, override, normalization, and ramp checks are included. This test did not modify the project.",
    passed, #cases, map_ok and "passed" or "FAILED", differing_override_rejected and "rejected" or "FAILED",
    matching_override_allowed and "accepted" or "FAILED", near_override_rejected and "rejected" or "FAILED",
    reserved_name_rejected and "rejected" or "FAILED", cross_ramp_ok and "passed" or "FAILED",
    final_ramp_ok and "passed" or "FAILED", ordinary_end_ok and "passed" or "FAILED",
    invalid_end_ok and "passed" or "FAILED", no_accent_ok and "passed" or "FAILED", search_ok and "passed" or "FAILED",
    reference_format_ok and "passed" or "FAILED", readme_version_ok and "passed" or "FAILED",extended_ok and "passed" or "FAILED"
  )
  if #details > 0 then msg = msg .. "\n\n" .. table.concat(details, "\n") end
  test_progress("finished")
  set_status(msg, all_ok and "success" or "error")
  show_info("Parser Self-Test", msg, all_ok and "success" or "error")
  return all_ok,msg
end

function draw_settings_view(content_x,content_y,content_w,content_h,base_clicked)
  draw_card(content_x,content_y,content_w,content_h,"Settings","Preview, row actions, logging, workspace, and advanced behavior")
  local gap=16;local outer_top=state.larger_text and 76 or 62;local col_w=(content_w-48)/2;local card_h=math.floor((content_h-outer_top-16-gap)/2)
  local x1=content_x+16;local x2=content_x+32+col_w;local y1=content_y+outer_top;local y2=y1+card_h+gap
  local card_pad=18;local control_gap=10;local control_w=math.floor((col_w-card_pad*2-control_gap)/2)
  local left1=x1+card_pad;local right1=left1+control_w+control_gap
  local left2=x2+card_pad;local right2=left2+control_w+control_gap
  local metrics=settings_grid_metrics(card_h,state.larger_text);local compact=metrics.compact;local row_start=metrics.row_start;local row_step=metrics.row_step;local button_h=metrics.button_h
  local terse=state.larger_text and compact
  local function row_y(card_y,row) return card_y+row_start+(row-1)*row_step end
  local function grid_button(label,x,y,w,h,enabled) return draw_button(label,x,y,w,h,enabled,base_clicked,compact) end
  draw_card(x1,y1,col_w,card_h,"Preview Table","Display and navigation behavior",metrics.dense_header)
  if grid_button("Density: "..(state.preview_density=="COMPACT" and "Compact" or "Comfortable"),left1,row_y(y1,1),control_w,button_h,true) then state.preview_density=state.preview_density=="COMPACT" and "COMFORTABLE" or "COMPACT";if not SAFE_MODE then reaper.SetExtState(EXTSTATE_SECTION,"preview_density",state.preview_density,true) end;set_status("Preview density set to "..state.preview_density:lower()..".","success") end
  if grid_button((state.alternating_rows and "✓ " or "")..(terse and "Alternating Rows" or "Alternating row shading"),right1,row_y(y1,1),control_w,button_h,true) then toggle_setting("alternating_rows") end
  if grid_button((state.section_emphasis and "✓ " or "")..(terse and "Section Emphasis" or "Section boundary emphasis"),left1,row_y(y1,2),control_w,button_h,true) then toggle_setting("section_emphasis") end
  if grid_button((state.show_syntax_badges and "✓ " or "").."Show syntax badges",right1,row_y(y1,2),control_w,button_h,true) then toggle_setting("show_syntax_badges") end
  if grid_button((state.show_row_explanations and "✓ " or "").."Right-click row explanations",left1,row_y(y1,3),control_w*2+control_gap,button_h,true) then toggle_setting("show_row_explanations") end

  draw_card(x2,y1,col_w,card_h,"Logging","Attempt history, logs, and support",metrics.dense_header)
  if grid_button("Copy Latest Build ID",left2,row_y(y1,1),control_w,button_h,state.current_attempt~=nil) then run_base_action(copy_current_build_id) end
  if grid_button("Open Log Folder",right2,row_y(y1,1),control_w,button_h,true) then run_base_action(open_log_folder) end
  if grid_button("Clean Up Logs...",left2,row_y(y1,2),control_w*2+control_gap,button_h,project_is_saved(get_active_project_info())) then run_base_action(clean_up_logs) end
  if grid_button(string.format("Click Frequencies: A %d Hz / B %d Hz",state.click_a_hz,state.click_b_hz),left2,row_y(y1,3),control_w*2+control_gap,button_h,true) then run_base_action(open_click_frequency_settings) end
  local info_y=row_y(y1,4)+3;set_color(165,174,185)
  if terse then
    draw_text("History: "..tostring(state.history_limit).." attempts  •  Recent workbooks: "..tostring(state.recent_limit),x2+18,info_y,11,false)
  else
    draw_text("In-app history limit: "..tostring(state.history_limit),x2+18,info_y,12,false)
    draw_text("Recent workbooks limit: "..tostring(state.recent_limit),x2+18,info_y+(compact and 20 or 24),12,false)
  end
  set_color(145,151,160)
  local log_text=terse and "Validated plans and Build Notes are logged." or "Validated Preview, workbook hash, plan hash, and Build Notes are always logged."
  local log_info=wrap_text(log_text,col_w-36,11)
  local log_y=info_y+(terse and 25 or compact and 40 or 50);local log_line_h=terse and 20 or 17
  local log_lines_that_fit=math.max(0,math.floor((y1+card_h-7-log_y)/log_line_h)+1)
  for i=1,math.min(log_lines_that_fit,#log_info) do draw_text(log_info[i],x2+18,log_y+(i-1)*log_line_h,11,false) end

  draw_card(x1,y2,col_w,card_h,"Workspace & Accessibility","Remembered app state, larger text, and cleanup",metrics.dense_header)
  if grid_button((state.remember_last_page and "✓ " or "").."Remember last page",left1,row_y(y2,1),control_w,button_h,true) then toggle_setting("remember_last_page") end
  if grid_button(terse and "Unload Workbook" or "Unload Current Workbook",right1,row_y(y2,1),control_w,button_h,not state.operation_busy) then run_base_action(clear_session) end
  if grid_button((state.remember_layout and "✓ " or "").."Remember Layout",left1,row_y(y2,2),control_w,button_h,true) then toggle_setting("remember_layout") end
  if grid_button("Clear Recent Workbooks",right1,row_y(y2,2),control_w,button_h,true) then run_base_action(clear_recent_workbooks) end
  if grid_button((state.remember_history_filters and "✓ " or "")..(terse and "Remember Filters" or "Remember history filters"),left1,row_y(y2,3),control_w,button_h,true) then toggle_setting("remember_history_filters") end
  if grid_button(terse and "Clear Saved Filters" or "Clear Saved History Filters",right1,row_y(y2,3),control_w,button_h,true) then run_base_action(clear_saved_history_filters) end
  if grid_button("Restore Default Layout",left1,row_y(y2,4),control_w*2+control_gap,button_h,true) then run_base_action(restore_default_layout) end
  if grid_button((state.larger_text and "✓ " or "").."Larger text throughout app",left1,row_y(y2,5),control_w*2+control_gap,button_h,true) then toggle_setting("larger_text") end

  draw_card(x2,y2,col_w,card_h,"Advanced","Diagnostics and technical display options",metrics.dense_header)
  local advanced_pad=18
  local advanced_gap=10
  local advanced_button_w=math.floor((col_w-advanced_pad*2-advanced_gap)/2)
  local advanced_full_w=advanced_button_w*2+advanced_gap
  local advanced_left=x2+advanced_pad
  local advanced_right=advanced_left+advanced_button_w+advanced_gap
  if grid_button("Diagnostics...",advanced_left,row_y(y2,1),advanced_full_w,button_h,true) then run_base_action(open_diagnostics) end
  if grid_button("Run Parser Self-Test",advanced_left,row_y(y2,2),advanced_full_w,button_h,true) then run_base_action(run_parser_self_test) end
  if grid_button((state.show_hashes and "✓ " or "").."Show plan hashes",advanced_left,row_y(y2,3),advanced_button_w,button_h,true) then toggle_setting("show_hashes") end
  if grid_button((state.show_full_path and "✓ " or "").."Show workbook full path",advanced_right,row_y(y2,3),advanced_button_w,button_h,true) then toggle_setting("show_full_path") end
  if grid_button((state.developer_mode and "✓ " or "").."Developer diagnostics mode",advanced_left,row_y(y2,4),advanced_full_w,button_h,true) then toggle_setting("developer_mode") end
  if grid_button("Reset App Preferences...",advanced_left,row_y(y2,5),advanced_full_w,button_h,not state.operation_busy) then run_base_action(reset_app_preferences) end
end

function readme_version_tuple(name)
  local version=name:match("Bildibeat_Click_Track_Mapper_README_v([%d_%.]+)%.txt$")
  if not version then return nil end
  local t={};for n in version:gmatch("%d+") do t[#t+1]=tonumber(n) end;return t
end
function version_tuple_greater(a,b)
  for i=1,math.max(#a,#b) do local av=a[i] or 0;local bv=b[i] or 0;if av~=bv then return av>bv end end;return false
end
function find_latest_readme()
  local dir=script_directory();local best_name,best_tuple=nil,nil;local i=0
  while true do local name=reaper.EnumerateFiles(dir,i);if not name or name=="" then break end;i=i+1;local t=readme_version_tuple(name);if t and (not best_tuple or version_tuple_greater(t,best_tuple)) then best_name,best_tuple=name,t end end
  if not best_name then return nil end
  return dir..best_name,best_name
end
function open_readme()
  local path,name=find_latest_readme()
  if path and file_exists(path) then
    show_confirm("Open README","Newest README found beside the script:\n\n"..name.."\n\nOpen this file now?","Open README","Cancel",function()
      local ok,err=shell_open(path)
      if ok then set_status("Opened "..name..".","success") else show_info("README Could Not Open",tostring(err),"error") end
    end,nil,"info")
  else
    show_info("README Unavailable","No file matching Bildibeat_Click_Track_Mapper_README_v*.txt was found beside the main script.","warning")
  end
end

function activate_scratchpad_control(index)
  if index==3 then
    if state.audio_preview and state.audio_preview.owner=="scratchpad" then stop_audio_preview(true) end
    local fields=state.scratchpad_fields or {};state.scratchpad_result=evaluate_syntax_scratchpad(fields[1] and fields[1].value or "",fields[2] and fields[2].value or "");state.scratchpad_result_scroll=0
    set_status(state.scratchpad_result.ok and "Scratchpad syntax is valid." or ("Scratchpad syntax is invalid ["..tostring(state.scratchpad_result.code or "SYN-001").."]."),state.scratchpad_result.ok and "success" or "error")
  elseif index==4 and state.scratchpad_result and state.scratchpad_result.ok then
    local ok,err=copy_to_clipboard(state.scratchpad_result.normalized or "");set_status(ok and "Normalized scratchpad syntax copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
  elseif index==5 and state.scratchpad_result then
    local ok,err=copy_to_clipboard(state.scratchpad_result.readout or state.scratchpad_result.message or "");set_status(ok and "Scratchpad readout copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error")
  elseif index==6 then
    if state.audio_preview and state.audio_preview.owner=="scratchpad" then stop_audio_preview(true) end
    local bpm=state.scratchpad_fields[1];local parts=state.scratchpad_fields[2]
    bpm.value=SCRATCHPAD_DEFAULT_BPM;bpm.cursor=#bpm.value;bpm.anchor=bpm.cursor;bpm.view_start=0;bpm.mouse_selecting=false
    parts.value=SCRATCHPAD_DEFAULT_PARTS;parts.cursor=#parts.value;parts.anchor=parts.cursor;parts.view_start=0;parts.mouse_selecting=false
    state.scratchpad_result=evaluate_syntax_scratchpad(bpm.value,parts.value);state.scratchpad_result_scroll=0
    set_status("The complete valid Syntax Scratchpad example was restored and tested.","success")
  elseif index==7 then scratchpad_play_preview()
  elseif index==8 then stop_audio_preview()
  elseif index==9 then
    state.scratchpad_preview_loop=not state.scratchpad_preview_loop
    if state.audio_preview and state.audio_preview.owner=="scratchpad" then
      state.audio_preview.looping=state.scratchpad_preview_loop
      if state.audio_preview.backend=="sws" then reaper.CF_Preview_SetValue(state.audio_preview.handle,"B_LOOP",state.scratchpad_preview_loop and 1 or 0) end
    end
    set_status("Scratchpad preview looping "..(state.scratchpad_preview_loop and "enabled." or "disabled."),"info")
  elseif index==10 then
    state.scratchpad_preview_half_speed=not state.scratchpad_preview_half_speed
    if state.audio_preview and state.audio_preview.owner=="scratchpad" then scratchpad_play_preview() end
    set_status("Scratchpad preview 50% speed "..(state.scratchpad_preview_half_speed and "enabled." or "disabled."),"info")
  end
end

function handle_scratchpad_keyboard(key,locked)
  if locked or state.active_view~="HELP" or not state.scratchpad_has_focus or not key or key==0 then return false end
  state.scratchpad_focus=math.max(1,math.min(10,state.scratchpad_focus or 1))
  if key==TEXT_KEYS.ESCAPE then state.scratchpad_has_focus=false;state.scratchpad_focus=0;return true end
  if key==TEXT_KEYS.TAB then
    local direction=(gfx.mouse_cap&8)==8 and -1 or 1;state.scratchpad_focus=((state.scratchpad_focus-1+direction)%10)+1;return true
  end
  if key==TEXT_KEYS.ENTER then
    if state.scratchpad_focus==1 then state.scratchpad_focus=2
    elseif state.scratchpad_focus==2 then activate_scratchpad_control(3)
    else activate_scratchpad_control(state.scratchpad_focus) end
    return true
  elseif key==TEXT_KEYS.SPACE and state.scratchpad_focus>=3 then
    activate_scratchpad_control(state.scratchpad_focus)
    return true
  end
  if state.scratchpad_focus<=2 then
    local field=state.scratchpad_fields[state.scratchpad_focus];if not field then return false end
    local ctrl=(gfx.mouse_cap&4)==4;local shift=(gfx.mouse_cap&8)==8
    local value,cursor,anchor,changed,handled,clipboard_status,clipboard_error=edit_text_with_clipboard(field.value or "",field.cursor,field.anchor,key,ctrl,shift)
    if handled then
      field.value=value;field.cursor=cursor;field.anchor=anchor
      if changed then if state.audio_preview and state.audio_preview.owner=="scratchpad" then stop_audio_preview(true) end;state.scratchpad_result=nil;state.scratchpad_result_scroll=0 end
      if clipboard_status then set_status(clipboard_status,"success") end
      if clipboard_error then set_status(clipboard_error,"error") end
      return true
    end
  end
  return false
end

function draw_scratchpad_field(field,index,x,y,w,clicked,mouse_down)
  local large=state.larger_text==true;local box_y=y+(large and 25 or 17);local box_h=large and 42 or 30;local value=tostring(field.value or "");local mono=index==2;field.cursor=clamp_text_cursor(value,field.cursor);field.anchor=clamp_text_cursor(value,field.anchor or field.cursor)
  if point_inside(x,box_y,w,box_h) then state.hover_context=index==1 and "Enter the underlying Section BPM used to test this PARTS expression; the workbook and REAPER project are not changed." or "Enter one PARTS expression to test with the production workbook parser; use Reset Syntax Example to restore every supported syntax family." end
  local shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,field.view_start,w-18,12,mono)
  if clicked and point_inside(x,box_y,w,box_h) then
    consume_button_activation(true,true,clicked);state.scratchpad_has_focus=true;state.scratchpad_focus=index
    local clicked_cursor=editable_cursor_from_x(value,view_start,view_finish,gfx.mouse_x-(x+8),12,mono)
    local now=reaper.time_precise();local double_click=field.last_text_click and now-field.last_text_click<0.35 and math.abs(gfx.mouse_x-(field.last_text_click_x or gfx.mouse_x))<=6
    if double_click then local first,last=text_word_bounds(value,clicked_cursor);field.anchor=first;field.cursor=last;field.mouse_selecting=false
    else if (gfx.mouse_cap&8)~=8 then field.anchor=clicked_cursor end;field.cursor=clicked_cursor;field.mouse_selecting=true end
    field.last_text_click=now;field.last_text_click_x=gfx.mouse_x
    shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,view_start,w-18,12,mono)
  end
  if state.scratchpad_has_focus and state.scratchpad_focus==index and field.mouse_selecting then
    if mouse_down and not clicked then
      if gfx.mouse_x<x+8 then field.cursor=previous_text_cursor(value,view_start)
      elseif gfx.mouse_x>x+w-8 then field.cursor=next_text_cursor(value,view_finish)
      else field.cursor=editable_cursor_from_x(value,view_start,view_finish,gfx.mouse_x-(x+8),12,mono) end
      shown,view_start,view_finish,caret_x=editable_text_view(value,field.cursor,view_start,w-18,12,mono)
    elseif not mouse_down then field.mouse_selecting=false end
  end
  field.view_start=view_start
  set_ui_color("muted");draw_text(field.label,x,y,11,true);set_ui_color("table_body");gfx.rect(x,box_y,w,box_h,true)
  if state.scratchpad_has_focus and state.scratchpad_focus==index then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(x,box_y,w,box_h,false)
  local inset=large and 10 or 5
  draw_editable_selection(value,field.cursor,field.anchor,view_start,view_finish,x+8,box_y+inset,box_h-inset*2,12,mono)
  set_color(222,231,239);if mono then draw_mono_text(shown,x+8,box_y+(large and 10 or 7),12,false) else draw_text(shown,x+8,box_y+(large and 10 or 7),13,false) end
  if state.scratchpad_has_focus and state.scratchpad_focus==index and math.floor(reaper.time_precise()*2)%2==0 then set_color(235,240,245);gfx.line(x+9+caret_x,box_y+inset,x+9+caret_x,box_y+box_h-inset) end
end

function draw_scratchpad_button(label,index,x,y,w,h,enabled,clicked)
  local hover=point_inside(x,y,w,h);if hover then state.hover_context=button_help_text(label,enabled,enabled and nil or (label=="Copy Normalized" and "Test a valid expression first." or "Test an expression first.")) end
  if not enabled then set_color(27,33,40) elseif hover then set_ui_color("button_hover") else set_ui_color("button") end;gfx.rect(x,y,w,h,true)
  if state.scratchpad_has_focus and state.scratchpad_focus==index then set_ui_color("accent") else set_ui_color("button_border") end;gfx.rect(x,y,w,h,false)
  if enabled then set_ui_color("text") else set_color(105,115,126) end;local shown=fit_text(label,w-12,11,true);gfx.setfont(1,UI.font_name,scaled_font_size(11),98);local tw,th=gfx.measurestr(shown);gfx.x=x+(w-tw)/2;gfx.y=y+(h-th)/2;gfx.drawstr(shown)
  if clicked and hover and consume_button_activation(enabled,true,clicked) then state.scratchpad_has_focus=true;state.scratchpad_focus=index;activate_scratchpad_control(index);return true end
  return false
end

function draw_syntax_scratchpad(x,y,w,h,clicked,mouse_down)
  draw_card(x,y,w,h,"Syntax Scratchpad","Test syntax without changing files or REAPER")
  local large=state.larger_text==true;local pad=16;local side_by_side=w>=700;local input_x=x+pad;local input_y=y+(large and 76 or 55);local input_w=side_by_side and math.floor((w-pad*3)*0.38) or w-pad*2
  local constrained=large and not side_by_side and h<520
  local compact_audio_row=side_by_side and h<320
  draw_scratchpad_field(state.scratchpad_fields[1],1,input_x,input_y,input_w,clicked,mouse_down)
  local field_step=constrained and 64 or large and 70 or 49;draw_scratchpad_field(state.scratchpad_fields[2],2,input_x,input_y+field_step,input_w,clicked,mouse_down)
  local gap=constrained and 4 or large and 9 or 7;local button_y=input_y+(constrained and 128 or large and 142 or 100);local scratch_button_h=constrained and 28 or large and 44 or 31;local button_w=math.floor((input_w-gap)/2)
  draw_scratchpad_button("Test Syntax",3,input_x,button_y,button_w,scratch_button_h,true,clicked)
  draw_scratchpad_button(constrained and "Reset Example" or "Reset Syntax Example",6,input_x+button_w+gap,button_y,input_w-button_w-gap,scratch_button_h,true,clicked)
  draw_scratchpad_button("Copy Normalized",4,input_x,button_y+scratch_button_h+gap,button_w,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
  draw_scratchpad_button("Copy Readout",5,input_x+button_w+gap,button_y+scratch_button_h+gap,input_w-button_w-gap,scratch_button_h,state.scratchpad_result~=nil,clicked)
  if compact_audio_row then
    local audio_y=button_y+(scratch_button_h+gap)*2;local audio_w=math.floor((input_w-gap*3)/4)
    draw_scratchpad_button("Play Preview",7,input_x,audio_y,audio_w,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
    draw_scratchpad_button("Stop",8,input_x+audio_w+gap,audio_y,audio_w,scratch_button_h,state.audio_preview and state.audio_preview.owner=="scratchpad" or false,clicked)
    draw_scratchpad_button("Loop: "..(state.scratchpad_preview_loop and "On" or "Off"),9,input_x+(audio_w+gap)*2,audio_y,audio_w,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
    draw_scratchpad_button("50% Speed: "..(state.scratchpad_preview_half_speed and "On" or "Off"),10,input_x+(audio_w+gap)*3,audio_y,input_w-(audio_w+gap)*3,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
  else
    draw_scratchpad_button("Play Preview",7,input_x,button_y+(scratch_button_h+gap)*2,button_w,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
    draw_scratchpad_button("Stop",8,input_x+button_w+gap,button_y+(scratch_button_h+gap)*2,input_w-button_w-gap,scratch_button_h,state.audio_preview and state.audio_preview.owner=="scratchpad" or false,clicked)
    draw_scratchpad_button("Loop: "..(state.scratchpad_preview_loop and "On" or "Off"),9,input_x,button_y+(scratch_button_h+gap)*3,button_w,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
    draw_scratchpad_button("50% Speed: "..(state.scratchpad_preview_half_speed and "On" or "Off"),10,input_x+button_w+gap,button_y+(scratch_button_h+gap)*3,input_w-button_w-gap,scratch_button_h,state.scratchpad_result and state.scratchpad_result.ok or false,clicked)
  end

  local result_x,result_y,result_w,result_h
  if side_by_side then result_x=input_x+input_w+pad;result_y=input_y;result_w=x+w-pad-result_x;result_h=h-(result_y-y)-pad
  else result_x=input_x;result_y=button_y+(scratch_button_h+gap)*4+3;result_w=input_w;result_h=h-(result_y-y)-12 end
  result_h=math.max(42,result_h);set_ui_color("table_body");gfx.rect(result_x,result_y,result_w,result_h,true)
  local result=state.scratchpad_result;local title=result and (result.ok and "VALID" or ("INVALID  ["..tostring(result.code or "SYN-001").."]")) or "RESULT"
  if result and result.ok then set_color(145,225,165) elseif result then set_color(255,145,145) else set_ui_color("muted") end;draw_text(title,result_x+10,result_y+7,12,true)
  set_ui_color("divider");gfx.line(result_x,result_y+29,result_x+result_w,result_y+29);gfx.rect(result_x,result_y,result_w,result_h,false)
  local result_text=result and (result.readout or result.message) or "Enter a Section BPM and PARTS expression, then choose Test Syntax."
  local lines=wrap_styled_source_text(result_text,result_w-42,scratchpad_source_line_uses_mono);local line_h=large and 28 or 19;local visible=math.max(1,math.floor((result_h-39)/line_h));local max_scroll=math.max(0,#lines-visible);state.scratchpad_result_scroll=math.max(0,math.min(state.scratchpad_result_scroll or 0,max_scroll))
  for i=1,visible do local item=lines[state.scratchpad_result_scroll+i];if item then set_color(205,216,227);if item.mono then draw_mono_text(item.text,result_x+10,result_y+35+(i-1)*line_h,12,false) else draw_text(item.text,result_x+10,result_y+35+(i-1)*line_h,13,false) end end end
  if max_scroll>0 then local sx=result_x+result_w-9;set_ui_color("scroll_track");gfx.rect(sx,result_y+30,8,result_h-31,true);local thumb=math.max(18,(result_h-31)*visible/#lines);local sy=result_y+30+(result_h-31-thumb)*(state.scratchpad_result_scroll/max_scroll);set_ui_color("scroll_thumb");gfx.rect(sx+1,sy,6,thumb,true) end
  if point_inside(result_x,result_y,result_w,result_h) then state.hover_context="Scratchpad result: complete parser output wraps here; use the mouse wheel to scroll, or Copy Readout to copy every line." end
  if gfx.mouse_wheel~=0 and point_inside(result_x,result_y,result_w,result_h) then state.scratchpad_result_scroll=state.scratchpad_result_scroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
  local control_rows=compact_audio_row and 3 or 4
  if clicked and point_inside(x,y,w,h) and not point_inside(input_x,input_y,input_w,(button_y-input_y)+(scratch_button_h+gap)*control_rows) and not point_inside(result_x,result_y,result_w,result_h) then state.scratchpad_has_focus=false;state.scratchpad_focus=0 end
end

function draw_help_guide_panel(x,y,w,h,base_clicked)
  draw_card(x,y,w,h,"Help Guide","Syntax, editing, logging, and fixes")
  local lines=wrap_styled_source_text(HELP_TEXT,w-58,help_source_line_uses_mono)
  local large=state.larger_text==true;local stacked_footer=large and w<650;local text_top=large and 78 or 56;local footer_h=stacked_footer and 150 or large and 66 or 54;local text_y=y+text_top;local viewport_h=math.max(24,h-text_top-footer_h)
  local line_h=large and 29 or 18;local visible=math.max(1,math.floor(viewport_h/line_h));local max_scroll=math.max(0,#lines-visible)
  state.help_scroll=math.max(0,math.min(state.help_scroll or 0,max_scroll))
  for i=1,visible do
    local item=lines[state.help_scroll+i]
    if item then
      local line=item.text
      if help_source_line_is_heading(line) then set_color(237,241,245);draw_text(line,x+18,text_y+(i-1)*line_h,14,true)
      elseif item.mono then set_color(188,205,220);draw_mono_text(line,x+18,text_y+(i-1)*line_h,12,false)
      else set_color(180,188,198);draw_text(line,x+18,text_y+(i-1)*line_h,13,false) end
    end
  end
  local sx=x+w-14;set_ui_color("scroll_track");gfx.rect(sx,text_y,8,viewport_h,true)
  if max_scroll>0 then
    local thumb=math.max(26,viewport_h*visible/#lines);local sy=text_y+(viewport_h-thumb)*(state.help_scroll/max_scroll);set_color(130,138,148);gfx.rect(sx+1,sy,6,thumb,true)
    if base_clicked and point_inside(sx,text_y,8,viewport_h) then local ratio=math.max(0,math.min(1,(gfx.mouse_y-text_y-thumb/2)/(viewport_h-thumb)));state.help_scroll=math.floor(ratio*max_scroll+0.5) end
  end
  if gfx.mouse_wheel~=0 and point_inside(x,text_y,w,viewport_h) then state.help_scroll=state.help_scroll-math.floor(gfx.mouse_wheel/120);gfx.mouse_wheel=0 end
  local gap=8;local button_h=large and 42 or 30
  if stacked_footer then
    local by=y+h-footer_h+10;local bw=w-36
    if draw_button("Open README",x+18,by,bw,button_h,true,base_clicked,true) then run_base_action(open_readme) end
    if draw_button("Copy Spreadsheet Example",x+18,by+button_h+gap,bw,button_h,true,base_clicked,true) then local ok,err=copy_to_clipboard(COMPLETE_WORKBOOK_EXAMPLE);set_status(ok and "Complete spreadsheet example copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error") end
    if draw_button("Search Error Reference",x+18,by+(button_h+gap)*2,bw,button_h,true,base_clicked,true) then show_error_reference_search() end
  else
    local by=y+h-button_h-12;local available=w-36-gap*2;local bw=math.floor(available/3)
    if draw_button("Open README",x+18,by,bw,button_h,true,base_clicked,true) then run_base_action(open_readme) end
    if draw_button("Copy Spreadsheet Example",x+18+bw+gap,by,bw,button_h,true,base_clicked,true) then local ok,err=copy_to_clipboard(COMPLETE_WORKBOOK_EXAMPLE);set_status(ok and "Complete spreadsheet example copied." or ("Copy failed: "..tostring(err)),ok and "success" or "error") end
    if draw_button("Search Error Reference",x+18+(bw+gap)*2,by,available-(bw+gap)*2,button_h,true,base_clicked,true) then show_error_reference_search() end
  end
end

function draw_help_view(content_x,content_y,content_w,content_h,base_clicked,mouse_down)
  draw_card(content_x,content_y,content_w,content_h,"Help Center","v10.21 guide and non-mutating Syntax Scratchpad")
  local large=state.larger_text==true;local top=large and 78 or 58;local x=content_x+16;local y=content_y+top;local w=content_w-32;local h=content_h-top-16;local gap=12
  if large and w>=700 then
    local left_w=math.floor((w-gap)/2)
    draw_syntax_scratchpad(x,y,left_w,h,base_clicked,mouse_down)
    draw_help_guide_panel(x+left_w+gap,y,w-left_w-gap,h,base_clicked)
  elseif content_w>=1200 then
    local scratch_h=math.max(270,math.min(340,math.floor(h*0.46)))
    draw_syntax_scratchpad(x,y,w,scratch_h,base_clicked,mouse_down)
    draw_help_guide_panel(x,y+scratch_h+gap,w,h-scratch_h-gap,base_clicked)
  else
    local scratch_h=math.max(280,math.min(420,math.floor(h*0.58)));local guide_h=h-scratch_h-gap
    draw_syntax_scratchpad(x,y,w,scratch_h,base_clicked,mouse_down)
    draw_help_guide_panel(x,y+scratch_h+gap,w,guide_h,base_clicked)
  end
end

function draw_ui()
  state.hover_context=""
  UI.layout=responsive_layout(gfx.w,gfx.h)
  local layout=UI.layout
  set_ui_color("canvas");gfx.rect(0,0,gfx.w,gfx.h,true)
  local now=reaper.time_precise();local mouse_down=(gfx.mouse_cap&1)==1;local right_mouse_down=(gfx.mouse_cap&2)==2;local press_started=mouse_down and not state.mouse_down_last;local right_press_started=right_mouse_down and not state.right_mouse_down_last;local press_released=(not mouse_down) and state.mouse_down_last
  state.action_consumed_this_frame=false
  if press_started then
    state.active_press_layer=top_input_layer(state)
    state.press_consumed=false
  end
  if press_released then state.active_press_layer=nil;state.press_consumed=false;state.suppress_click_until_release=false;run_after_release_queue()
  elseif state.suppress_click_until_release and not mouse_down then state.suppress_click_until_release=false end
  local clicked=press_started and not state.suppress_click_until_release
  local modal_open=state.confirm_modal or state.comparison_open or state.app_modal
  local overlay_open=modal_open or state.row_popover
  local base_input_locked=state.operation_busy or overlay_open or now < (state.base_input_block_until or 0)
  local raw_mouse_wheel=gfx.mouse_wheel
  if overlay_open then gfx.mouse_wheel=0 end
  local base_clicked=clicked and state.active_press_layer=="BASE" and not base_input_locked
  local base_right_clicked=right_press_started and not overlay_open and not base_input_locked
  local comparison_clicked=clicked and state.active_press_layer=="COMPARISON_MODAL"
  local confirmation_clicked=clicked and state.active_press_layer=="CONFIRM_MODAL"
  local app_modal_clicked=clicked and state.active_press_layer=="APP_MODAL"
  local row_popover_clicked=clicked and state.active_press_layer=="ROW_POPOVER" and not modal_open
  local row_popover_right_clicked=right_press_started and state.row_popover~=nil and not modal_open

  if not state.active_view then state.active_view="BUILD" end
  if not overlay_open and handle_scratchpad_keyboard(state.last_key,base_input_locked) then state.last_key=0
  elseif not overlay_open and handle_tempo_preview_keyboard(state.last_key,base_input_locked) then state.last_key=0
  elseif not overlay_open and handle_base_keyboard(state.last_key,base_input_locked) then state.last_key=0 end
  begin_focus_frame(not overlay_open)
  local nav_w=layout.nav_width
  set_ui_color("sidebar");gfx.rect(0,0,nav_w,gfx.h,true)
  set_ui_color("divider");gfx.line(nav_w,0,nav_w,gfx.h)
  set_ui_color("text");draw_text("BCTM",20,18,state.larger_text and 21 or 23,true)
  gfx.setfont(1,UI.font_name,scaled_font_size(state.larger_text and 21 or 23),98);local brand_w=gfx.measurestr("BCTM")
  set_ui_color("muted");draw_text("v"..SCRIPT_VERSION,math.min(nav_w-52,20+brand_w+10),state.larger_text and 29 or 27,11,false)
  set_ui_color("divider");gfx.line(20,68,nav_w-20,68)
  draw_nav_button("Build","BUILD",0,84,nav_w,50,base_clicked)
  draw_nav_button("History","HISTORY",0,138,nav_w,50,base_clicked)
  draw_nav_button("Settings","SETTINGS",0,192,nav_w,50,base_clicked)
  draw_nav_button("Help","HELP",0,246,nav_w,50,base_clicked)
  local status_y=gfx.h-layout.status_height
  set_ui_color("divider");gfx.line(20,status_y-108,nav_w-20,status_y-108)
  draw_sidebar_close(10,status_y-88,nav_w-20,40,base_clicked)
  set_color(103,114,126);draw_text("Made by Bidlibop",20,status_y-28,11,false)

  local content_x=nav_w;local content_w=gfx.w-nav_w
  draw_header(content_x,content_w,base_clicked)
  local body_x=content_x+layout.body_margin;local body_y=layout.body_y;local body_w=content_w-layout.body_margin*2;local body_h=gfx.h-body_y-layout.status_height-layout.body_bottom
  if state.active_view=="BUILD" then draw_build_view(body_x,body_y,body_w,body_h,base_clicked,mouse_down and not base_input_locked,base_right_clicked)
  elseif state.active_view=="HISTORY" then draw_history_view(body_x,body_y,body_w,body_h,base_clicked,mouse_down and not base_input_locked)
  elseif state.active_view=="SETTINGS" then draw_settings_view(body_x,body_y,body_w,body_h,base_clicked)
  else draw_help_view(body_x,body_y,body_w,body_h,base_clicked,mouse_down and not base_input_locked) end
  finish_focus_frame()
  state.base_focus_enabled=false

  if modal_open then state.hover_context="" end
  if state.row_popover and not modal_open then
    gfx.mouse_wheel=raw_mouse_wheel
    draw_row_popover(row_popover_clicked,row_popover_right_clicked,state.last_key)
  end
  if state.comparison_open then
    gfx.mouse_wheel=(not state.confirm_modal and not state.app_modal) and raw_mouse_wheel or 0
    draw_comparison_modal((state.confirm_modal or state.app_modal) and false or comparison_clicked,mouse_down,(state.confirm_modal or state.app_modal) and 0 or state.last_key)
    if state.confirm_modal or state.app_modal then state.hover_context="" end
  end
  if state.confirm_modal then
    gfx.mouse_wheel=not state.app_modal and raw_mouse_wheel or 0
    draw_confirmation_modal(state.app_modal and false or confirmation_clicked,state.app_modal and 0 or state.last_key)
    if state.app_modal then state.hover_context="" end
  end
  if state.app_modal then
    gfx.mouse_wheel=raw_mouse_wheel
    draw_app_modal(app_modal_clicked,mouse_down,state.last_key)
  end
  if overlay_open then gfx.mouse_wheel=0 end

  local display_rows=preview_display_rows()
  local display_status,display_kind=resolve_bottom_bar_content(state,reaper.time_precise(),display_rows)
  draw_context_bar(content_x,display_status,display_kind,display_rows)
  state.last_key=0;state.mouse_down_last=mouse_down;state.right_mouse_down_last=right_mouse_down;gfx.update()
end

function save_preferences()
  if SAFE_MODE then return end
  reaper.SetExtState(EXTSTATE_SECTION,"preferences_schema",tostring(PREF_SCHEMA_VERSION),true)
  if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"column_widths",serialize_number_list(state.column_widths),true) else reaper.DeleteExtState(EXTSTATE_SECTION,"column_widths",true) end
  if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"preview_hscroll",tostring(state.preview_hscroll or 0),true) else reaper.DeleteExtState(EXTSTATE_SECTION,"preview_hscroll",true) end
  reaper.SetExtState(EXTSTATE_SECTION,"preview_density",state.preview_density,true)
  reaper.SetExtState(EXTSTATE_SECTION,"click_a_hz",tostring(state.click_a_hz),true)
  reaper.SetExtState(EXTSTATE_SECTION,"click_b_hz",tostring(state.click_b_hz),true)
  for _,key in ipairs({"remember_layout","alternating_rows","section_emphasis","show_syntax_badges","show_row_explanations","remember_history_filters","remember_last_page","show_hashes","show_full_path","developer_mode","larger_text"}) do persist_bool(key,state[key]) end
  if state.remember_last_page then reaper.SetExtState(EXTSTATE_SECTION,"active_view",state.active_view or "BUILD",true) else reaper.DeleteExtState(EXTSTATE_SECTION,"active_view",true) end
  if state.remember_history_filters then
    for key,value in pairs({history_filter=state.history_filter,history_song=state.history_song,history_notes_search=state.history_notes_search,history_id_search=state.history_id_search,history_date_from=state.history_date_from,history_date_to=state.history_date_to}) do reaper.SetExtState(EXTSTATE_SECTION,key,tostring(value or ""),true) end
  else
    for _,key in ipairs({"history_filter","history_song","history_notes_search","history_id_search","history_date_from","history_date_to"}) do reaper.DeleteExtState(EXTSTATE_SECTION,key,true) end
  end
  if state.remember_layout then reaper.SetExtState(EXTSTATE_SECTION,"history_panel_height",tostring(math.floor(state.history_panel_height+0.5)),true);reaper.SetExtState(EXTSTATE_SECTION,"side_panel_height",tostring(math.floor((state.side_panel_height or 0)+0.5)),true) end
  if state.remember_layout then local ok,dock,x,y,w,h=pcall(gfx.dock,-1,0,0,0,0);if ok then reaper.SetExtState(EXTSTATE_SECTION,"window_x",tostring(x or 100),true);reaper.SetExtState(EXTSTATE_SECTION,"window_y",tostring(y or 100),true);reaper.SetExtState(EXTSTATE_SECTION,"window_w",tostring(w or gfx.w),true);reaper.SetExtState(EXTSTATE_SECTION,"window_h",tostring(h or gfx.h),true) end end
end
function initialize_project_context()
  if SAFE_MODE then set_status("SAFE MODE: persisted layout and recent workspace are ignored for this run.","warning") end
  if state.pending_tempo_recovery and not SAFE_MODE then
    if state.pending_tempo_recovery.load_error then set_status("A damaged tempo-edit recovery record was found. Validate a workbook to review the recovery warning.","warning")
    else set_status("Unsaved tempo edits are recoverable. Validate the matching unchanged workbook to restore or discard them.","warning") end
  end
  if state.remember_history_filters and not SAFE_MODE then
    state.history_filter=reaper.GetExtState(EXTSTATE_SECTION,"history_filter");if state.history_filter=="" then state.history_filter="ALL" end
    state.history_song=reaper.GetExtState(EXTSTATE_SECTION,"history_song");if state.history_song=="" then state.history_song="ALL" end
    state.history_notes_search=reaper.GetExtState(EXTSTATE_SECTION,"history_notes_search") or ""
    state.history_id_search=reaper.GetExtState(EXTSTATE_SECTION,"history_id_search") or ""
    state.history_date_from=reaper.GetExtState(EXTSTATE_SECTION,"history_date_from") or ""
    state.history_date_to=reaper.GetExtState(EXTSTATE_SECTION,"history_date_to") or ""
  else state.history_filter="ALL" end
  refresh_attempt_history(state)
  local info=get_active_project_info()
  if project_is_saved(info) then
    state.interrupted_logs=list_inprogress_logs(project_log_folder(info))
    if #state.interrupted_logs>0 then set_status(string.format("Recovery notice: %d unfinished IN_PROGRESS logfile%s found. Open the log folder to inspect them.",#state.interrupted_logs,#state.interrupted_logs==1 and " was" or "s were"),"warning") end
  end
end

function loop()
  service_click_frequency_cleanup()
  service_audio_preview()
  local key=gfx.getchar()
  state.last_key=key
  if key<0 and not state.close_requested and not tempo_edits_empty(state.tempo_edits) then
    local scope_text=tempo_edit_scope_text(state.base_plan,state.plan)
    local recovery_notice=SAFE_MODE and "Safe Mode did not create a tempo-recovery copy for these edits." or "The recovery copy will also be deleted."
    local answer=reaper.MB("Closing Bildibeat Click Track Mapper will discard staged BPM edits affecting "..scope_text..". They have not been saved to an updated workbook copy. "..recovery_notice.."\n\nClose and discard the edits?","Discard Unsaved Tempo Edits?",4)
    if answer~=6 then
      gfx.init(SCRIPT_NAME,math.max(980,gfx.w),math.max(680,gfx.h),0,100,80)
      reaper.defer(loop);return
    end
    intentionally_discard_tempo_recovery()
  end
  if key<0 or state.close_requested then
    if state.audition_active then restore_audition_state() end
    stop_audio_preview(true)
    if state.active_attempt then cancel_attempt(state,state.active_attempt,"Application window closed during build workflow","The app window was closed before the attempt completed. No unverified project changes were retained.");state.active_attempt=nil end
    end_click_frequency_session();service_click_frequency_cleanup();save_preferences();gfx.quit();return
  end
  local now=reaper.time_precise()
  if state.plan and now-state.last_workbook_check>5 then state.last_workbook_check=now;mark_file_stale_if_changed() end
  if state.plan and now-state.last_project_check>2 then
    state.last_project_check=now;local info=get_active_project_info()
    if not info or not state.validation_project or info.pointer~=state.validation_project.pointer then state.project_changed=true;state.audio_tempo_mode=AUDIO_MODE_PRESERVE;state.audio_tempo_analysis=nil
    elseif info.state_count~=state.validation_project.state_count then state.dry_run_stale=true;state.validation_project.state_count=info.state_count;refresh_dry_run() end
  end
  update_audition_transport()
  draw_ui()
  if state.reinit_requested then
    if state.audition_active then restore_audition_state() end
    state.reinit_requested=false;save_preferences();gfx.quit();gfx.init(SCRIPT_NAME,UI.default_w,UI.default_h,0,100,80)
  end
  reaper.defer(loop)
end

if rawget(_G,"CTM_TEST_PROGRESS") then _G.CTM_TEST_PROGRESS("UI definitions complete") end
modules.Parser={
  parse_part=parse_part,parse_parts_expression=parse_parts_expression,validate_sheets=validate_sheets,validate_file=validate_file,
  build_expected_map=build_expected_map,serialize_expected_map=serialize_expected_map,
  rebuild_plan_from_tempo_edits=rebuild_plan_from_tempo_edits,rewrite_part_bpm_in_expression=rewrite_part_bpm_in_expression,
  rewrite_section_overrides=rewrite_section_overrides,canonical_part_with_underlying_bpm=canonical_part_with_underlying_bpm,
  compose_tempo_edit_row=compose_tempo_edit_row,remove_tempo_edit_unit=remove_tempo_edit_unit,tempo_edit_units=tempo_edit_units,
  serialize_tempo_recovery=serialize_tempo_recovery,deserialize_tempo_recovery=deserialize_tempo_recovery,tempo_edit_scope=tempo_edit_scope,tempo_recovery_matches_plan=tempo_recovery_matches_plan,
  run_self_test=run_parser_self_test
}
modules.Build={
  collect_project_snapshot=collect_project_snapshot,preflight=preflight_build_plan,
  perform=perform_logged_build,verify=verify_build,compare_validated_plan_to_project=compare_validated_plan_to_project,
  project_comparison_available=project_comparison_available,transaction_signature=transaction_project_signature
}
modules.UI={
  open_modal=open_app_modal,top_input_layer=top_input_layer,modal_button_value=modal_button_value,
  edit_text_at_cursor=edit_text_at_cursor,edit_text_selection=edit_text_selection,text_selection_bounds=text_selection_bounds,text_word_bounds=text_word_bounds,
  editable_text_view=editable_text_view,editable_cursor_from_x=editable_cursor_from_x,next_enabled_focus=next_enabled_focus,
  control_unavailable_reason=control_unavailable_reason,looks_like_syntax_text=looks_like_syntax_text,help_source_line_is_heading=help_source_line_is_heading,
  validation_issue_from_error=validation_issue_from_error,show_validation_issue=show_validation_issue,
  preview_row_blurb=preview_row_blurb,preview_row_full_readout=preview_row_full_readout,row_original_syntax=row_original_syntax,preview_part_plain_english=preview_part_plain_english,
  evaluate_syntax_scratchpad=evaluate_syntax_scratchpad,normalized_parts_expression=normalized_parts_expression,row_popover_actions=row_popover_actions,
  selected_revert_available=selected_revert_available,selected_revert_candidate=selected_revert_candidate,revert_selected_tempo_edits=revert_selected_tempo_edits,
  scratchpad_payload_for_preview_rows=scratchpad_payload_for_preview_rows,send_selected_rows_to_scratchpad=send_selected_rows_to_scratchpad,
  pane_default_context=pane_default_context,resolve_bottom_bar_content=resolve_bottom_bar_content,context_bar_tag=context_bar_tag,responsive_layout=responsive_layout,
  visual_regression_snapshot=ui_visual_regression_snapshot,run_visual_regression_matrix=run_ui_visual_regression_matrix
}
modules.Diagnostics={
  search_error_reference=search_error_reference,identify_error_reference=identify_error_reference,
  normalize_preferences=normalize_preference_snapshot,find_latest_readme=find_latest_readme
}
modules.Audio={
  click_events_for_parts=click_events_for_parts,simple_tempo_audition_parts=simple_tempo_audition_parts,
  write_click_preview_wav=write_click_preview_wav,ramp_elapsed_for_qn=ramp_elapsed_for_qn,
  start_preview=start_click_audio_preview,stop_preview=stop_audio_preview,service_preview=service_audio_preview,
  capture_project_state=capture_audio_project_state,state_signature=audio_state_signature,restore_project_state=restore_audio_project_state,
  analyze_tempo_handling=analyze_audio_tempo_handling,prepare_tempo_build=prepare_audio_for_tempo_build,finalize_tempo_build=finalize_audio_after_tempo_build
}
modules.Export={
  click_package_parts=click_package_parts,expected_click_count=expected_click_count,midi_section_marker_name=midi_section_marker_name,build_click_midi=build_click_midi,verify_click_midi_bytes=verify_click_midi_bytes,
  output_paths=click_package_output_paths,default_filename=click_package_default_filename,available=click_package_available,
  mp3_batch_job_text=mp3_batch_job_text,render_wav_to_mp3=render_wav_to_mp3,export_click_package=export_click_package
}
modules.Workbook={
  edit_records=workbook_edit_records,write_csv_copy=write_updated_csv_copy,write_xlsx_copy=write_updated_xlsx_copy,
  copy_available=updated_workbook_copy_available,default_name=updated_workbook_default_name,
  validate_selection_path=validate_workbook_selection_path,open_dialog_kind=workbook_open_dialog_kind,choose_path=choose_workbook_path,
  reconstruction_sheet=reconstruction_sheet,choose_reconstruction_section_bpm=choose_reconstruction_section_bpm,reconstruction_part_token=reconstruction_part_token,
  compress_reconstruction_blocks=compress_reconstruction_blocks,collect_reconstruction_project_model=collect_reconstruction_project_model,
  reconstruct_from_project=reconstruct_workbook_plan_from_project,write_reconstructed_csv=write_reconstructed_csv,write_reconstructed_xlsx=write_reconstructed_xlsx
}
rawset(_G,"ClickTrackMapper_v10_21",App)
if rawget(_G,"CTM_TEST_PROGRESS") then _G.CTM_TEST_PROGRESS("module export complete") end

-- Isolated verification harnesses may load the complete release without opening
-- its long-running window. Ordinary REAPER launches never set this global.
if TEST_MODE then
  App.state=state
  if rawget(_G,"CTM_TEST_PROGRESS") then _G.CTM_TEST_PROGRESS("test-mode return") end
  return App
end

math.randomseed(os.time()+math.floor(reaper.time_precise()*100000))
win_w=(not SAFE_MODE and ext_bool("remember_layout",ext_bool("remember_window",true)) and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"window_w"))) or UI.default_w
win_h=(not SAFE_MODE and ext_bool("remember_layout",ext_bool("remember_window",true)) and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"window_h"))) or UI.default_h
win_x=(not SAFE_MODE and ext_bool("remember_layout",ext_bool("remember_window",true)) and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"window_x"))) or 100
win_y=(not SAFE_MODE and ext_bool("remember_layout",ext_bool("remember_window",true)) and tonumber(reaper.GetExtState(EXTSTATE_SECTION,"window_y"))) or 80
gfx.init(SCRIPT_NAME,math.max(980,win_w),math.max(680,win_h),0,win_x,win_y)
reaper.atexit(function() if state and state.audition_active then pcall(restore_audition_state) end;pcall(end_click_frequency_session);pcall(service_click_frequency_cleanup);pcall(persist_tempo_edit_recovery);save_preferences() end)
initialize_project_context()
loop()
