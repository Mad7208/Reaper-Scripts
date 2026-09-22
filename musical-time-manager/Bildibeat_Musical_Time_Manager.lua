-- @description Bildibeat Musical Time Manager
-- @version 1.6
-- @author Bildibeat / OpenAI Codex
-- @about
--   A dependency-free REAPER UI for inserting/removing musical time, resizing
--   measures, or locally retiming a fixed time selection.
--
--   Put the edit cursor exactly on a bar line, choose an operation, and apply.
--   Later project markers, regions, tempo/time-signature markers, and whole
--   media items are restored as a coherent musical block and verified. If a
--   preservation check fails, the complete operation is automatically undone.
--
--   Removing time intentionally edits media and markers inside the removed
--   span. The confirmation window reports that destructive scope separately
--   from the downstream objects that will be preserved.
--
--   Requires REAPER 7.75 or newer. No extensions are required.

local APP_NAME = "Bildibeat Musical Time Manager"
local APP_VERSION = "1.6"
local EXT_SECTION = "BildibeatMusicalTimeManager"
local INSERT_EMPTY_SPACE = 40200
local REMOVE_TIME_MOVING_LATER = 40201
local EPS_TIME = 1e-6
local EPS_BEAT = 1e-6
local EPS_BPM = 1e-7
local MAX_NUMERATOR = 64
local MAX_COUNT = 999
local MIN_BPM = 1
local MAX_BPM = 960
local DEFAULT_SEAM_FADE_MS = 3
local MAX_SEAM_FADE_MS = 50
local DENOMINATORS = {1, 2, 4, 8, 16, 32}
local COMMON_METERS = {
  {4, 4}, {3, 4}, {6, 8}, {7, 8}
}

local function approx(a, b, epsilon)
  return math.abs(a - b) <= epsilon
end

local function round(value)
  return math.floor(value + 0.5)
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function plural(value, singular, plural_form)
  return value == 1 and singular or (plural_form or singular .. "s")
end

local function alert(message, title)
  reaper.ShowMessageBox(message, title or APP_NAME, 0)
end

local function get_reaper_version()
  local text = tostring(reaper.GetAppVersion() or "")
  return tonumber(text:match("^(%d+%.%d+)")) or 0
end

local function musical_position(proj, time)
  local beat, measure = reaper.TimeMap2_timeToBeats(proj, time)
  return {measure = measure, beat = beat}
end

local function same_musical_position(a, b)
  return a and b and a.measure == b.measure and
    approx(a.beat, b.beat, EPS_BEAT * 10)
end

local function format_musical_position(position)
  return string.format("measure %d, beat %.6f", position.measure + 1,
    position.beat + 1)
end

local function measure_label(measure)
  return tostring(measure + 1)
end

local function map_time(plan, time)
  if plan.operation == "retime_selection" then return time end
  if plan.direction > 0 then
    if approx(time, plan.action_start, EPS_TIME) then return plan.action_end end
    if time > plan.action_start then return time + plan.duration end
    return time
  end
  if approx(time, plan.action_end, EPS_TIME) then return plan.action_start end
  if time < plan.action_start - EPS_TIME then return time end
  if time > plan.action_end then return time - plan.duration end
  return plan.action_start
end

local function time_is_removed(plan, time)
  if plan.operation == "retime_selection" then return false end
  return plan.direction < 0 and
    not approx(time, plan.action_end, EPS_TIME) and
    time >= plan.action_start - EPS_TIME and time < plan.action_end
end

local function map_retime_content_time(plan, time)
  if time <= plan.selection_start + EPS_TIME then return plan.selection_start end
  if time >= plan.selection_end - EPS_TIME then
    return plan.retime_content_end or (plan.selection_start +
      (plan.selection_end - plan.selection_start) / plan.retime_ratio)
  end
  for _, span in ipairs(plan.retime_spans or {}) do
    if time <= span.source_end + EPS_TIME then
      return span.target_start + (time - span.source_start) / span.ratio
    end
  end
  return plan.selection_start +
    (time - plan.selection_start) / plan.retime_ratio
end

local function retime_ratio_at_time(plan, time)
  for index, span in ipairs(plan.retime_spans or {}) do
    if time < span.source_end - EPS_TIME or index == #plan.retime_spans then
      return span.ratio
    end
  end
  return plan.retime_ratio
end

local function map_tempo_time(plan, time)
  if plan.operation == "retime_selection" and
     time > plan.selection_start + EPS_TIME and
     time < plan.selection_end - EPS_TIME then
    return map_retime_content_time(plan, time)
  end
  return map_time(plan, time)
end

local function tempo_point_is_removed(plan, time)
  if plan.operation == "retime_selection" then
    if time <= plan.selection_start + EPS_TIME or
       time >= plan.selection_end - EPS_TIME then return false end
    return map_tempo_time(plan, time) >= plan.selection_end - EPS_TIME
  end
  return time_is_removed(plan, time)
end

local function tempo_chunk_lines(chunk)
  local normalized = chunk:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (normalized .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function tempo_point_time(line)
  local text = line:match("^%s*PT%s+([%+%-]?[%d%.eE]+)")
  return text and tonumber(text) or nil
end

local function replace_tempo_point_time(line, time)
  local result, count = line:gsub(
    "^(%s*PT%s+)([%+%-]?[%d%.eE]+)",
    "%1" .. string.format("%.12f", time), 1)
  if count ~= 1 then error("Could not rewrite a tempo-envelope point.") end
  return result
end

local function snapshot_tempo_envelope_chunk(proj)
  local master_track = reaper.GetMasterTrack(proj)
  local envelope = master_track and
    reaper.GetTrackEnvelopeByName(master_track, "Tempo map") or nil
  if not envelope then error("Could not access the project's tempo envelope.") end
  local ok, chunk = reaper.GetEnvelopeStateChunk(envelope, "", false)
  if not ok or not chunk or chunk == "" then
    error("Could not snapshot the project's tempo envelope.")
  end
  return envelope, chunk
end

local function metronome_pattern(proj, time)
  local _, pattern = reaper.TimeMap_GetMetronomePattern(proj, time, "EXTENDED")
  return pattern or ""
end

local function snapshot_tempo_markers(proj)
  local result = {}
  for index = 0, reaper.CountTempoTimeSigMarkers(proj) - 1 do
    local ok, time, measure, beat, bpm, numerator, denominator, linear =
      reaper.GetTempoTimeSigMarker(proj, index)
    if not ok then
      error("Could not read tempo/time-signature marker " .. tostring(index) .. ".")
    end
    result[#result + 1] = {
      index = index,
      time = time,
      measure = measure,
      beat = beat,
      bpm = bpm,
      numerator = numerator,
      denominator = denominator,
      linear = linear,
      pattern = metronome_pattern(proj, time)
    }
  end
  return result
end

local function tempo_marker_exactly_at(markers, time)
  for _, marker in ipairs(markers) do
    if approx(marker.time, time, EPS_TIME) then return marker end
  end
  return nil
end

local function tempo_ramp_overlaps(markers, start_time, end_time)
  for index = 1, #markers - 1 do
    local point = markers[index]
    local following = markers[index + 1]
    if point.linear and point.time < end_time - EPS_TIME and
       following.time > start_time + EPS_TIME then
      return true
    end
  end
  return false
end

local function transformed_tempo_chunk(original_chunk, plan)
  local prefix = {}
  local points = {}
  local suffix = {}
  local saw_point = false
  local point_count = 0
  local removed_count = 0

  for ordinal, line in ipairs(tempo_chunk_lines(original_chunk)) do
    local time = tempo_point_time(line)
    if time then
      saw_point = true
      point_count = point_count + 1
      local original_marker = plan.tempo_markers[point_count]
      if not original_marker or
         not approx(time, original_marker.time, EPS_TIME * 100) then
        error("The tempo-envelope point order did not match the public tempo map.")
      end
      local source_time = original_marker.time
      local keep = true
      local mapped_time = map_tempo_time(plan, source_time)
      if tempo_point_is_removed(plan, source_time) then
        keep = false
        removed_count = removed_count + 1
      end
      if keep then
        points[#points + 1] = {
          time = mapped_time,
          line = replace_tempo_point_time(line, mapped_time),
          ordinal = ordinal
        }
      end
    elseif not saw_point then
      prefix[#prefix + 1] = line
    else
      suffix[#suffix + 1] = line
    end
  end

  if point_count ~= #plan.tempo_markers then
    error(string.format(
      "Tempo-envelope snapshot contained %d points but the public tempo map contained %d markers.",
      point_count, #plan.tempo_markers))
  end

  -- A project with no explicit tempo markers has no PT line in this chunk.
  -- Keep the envelope's closing delimiter after any generated overlay points.
  if point_count == 0 then
    for index = #prefix, 1, -1 do
      if prefix[index]:match("^%s*>%s*$") then
        for suffix_index = index, #prefix do
          suffix[#suffix + 1] = prefix[suffix_index]
        end
        for remove_index = #prefix, index, -1 do
          table.remove(prefix, remove_index)
        end
        break
      end
    end
  end

  return prefix, points, suffix, removed_count
end

local function set_tempo_chunk(proj, envelope, chunk)
  if not reaper.SetEnvelopeStateChunk(envelope, chunk, false) then
    error("Could not restore the protected tempo envelope.")
  end
  reaper.Envelope_SortPoints(envelope)
  reaper.UpdateTimeline()
end

local function compose_tempo_chunk(prefix, points, suffix)
  table.sort(points, function(a, b)
    if approx(a.time, b.time, EPS_TIME) then return a.ordinal < b.ordinal end
    return a.time < b.time
  end)
  local output = {}
  for _, line in ipairs(prefix) do output[#output + 1] = line end
  for _, point in ipairs(points) do output[#output + 1] = point.line end
  for _, line in ipairs(suffix) do output[#output + 1] = line end
  return table.concat(output, "\n")
end

local function tempo_line_at_time(chunk, wanted_time)
  for _, line in ipairs(tempo_chunk_lines(chunk)) do
    local time = tempo_point_time(line)
    if time and approx(time, wanted_time, EPS_TIME) then return line end
  end
  return nil
end

local function find_tempo_marker_index_at_time(proj, wanted_time)
  for index = 0, reaper.CountTempoTimeSigMarkers(proj) - 1 do
    local ok, time = reaper.GetTempoTimeSigMarker(proj, index)
    if ok and approx(time, wanted_time, EPS_TIME) then return index end
  end
  return -1
end

local function find_matching_tempo_marker_index(proj, overlay, preferred_index)
  local count = reaper.CountTempoTimeSigMarkers(proj)
  local function matches(index)
    if index < 0 or index >= count then return false end
    local ok, _, _, _, bpm, numerator, denominator, linear =
      reaper.GetTempoTimeSigMarker(proj, index)
    return ok and approx(bpm, overlay.bpm, EPS_BPM * 100) and
      numerator == overlay.numerator and denominator == overlay.denominator and
      linear == overlay.linear
  end
  if preferred_index and matches(preferred_index) then return preferred_index end
  local exact = find_tempo_marker_index_at_time(proj, overlay.time)
  if exact >= 0 and matches(exact) then return exact end
  local best_index, best_distance
  for index = 0, count - 1 do
    if matches(index) then
      local _, time = reaper.GetTempoTimeSigMarker(proj, index)
      local distance = math.abs(time - overlay.time)
      if not best_distance or distance < best_distance then
        best_index, best_distance = index, distance
      end
    end
  end
  return best_index or -1
end

local function enable_partial_measure_at_overlay(proj, overlay, preferred_index)
  local marker_index = find_matching_tempo_marker_index(
    proj, overlay, preferred_index)
  if marker_index < 0 then
    error("Could not locate a required partial-measure tempo marker.")
  end
  local flags = reaper.GetSetTempoTimeSigMarkerFlag(
    proj, marker_index, 0, false)
  if not reaper.GetSetTempoTimeSigMarkerFlag(
    proj, marker_index, (flags or 0) | 1 | 4, true) then
    error("Could not enable a partial measure required by the fixed selection.")
  end
  local ok = reaper.SetTempoTimeSigMarker(
    proj, marker_index, overlay.time, -1, -1,
    overlay.bpm, overlay.numerator, overlay.denominator, overlay.linear)
  if not ok then
    error("Could not place a fixed-selection marker after enabling its partial measure.")
  end
  marker_index = find_tempo_marker_index_at_time(proj, overlay.time)
  if marker_index < 0 then
    error("A partial-measure marker would not remain at its exact clock position.")
  end
  flags = reaper.GetSetTempoTimeSigMarkerFlag(proj, marker_index, 0, false)
  if not reaper.GetSetTempoTimeSigMarkerFlag(
    proj, marker_index, (flags or 0) | 1 | 4, true) then
    error("Could not preserve a fixed-selection partial-measure flag.")
  end
  return marker_index
end

local function refresh_tempo_cache(proj)
  local last_index = reaper.CountTempoTimeSigMarkers(proj) - 1
  if last_index < 0 then
    reaper.UpdateTimeline()
    return
  end
  local ok, time, _, _, bpm, numerator, denominator, linear =
    reaper.GetTempoTimeSigMarker(proj, last_index)
  if not ok or not reaper.SetTempoTimeSigMarker(
    proj, last_index, time, -1, -1, bpm, numerator, denominator, linear) then
    error("Could not refresh REAPER's internal tempo map.")
  end
  reaper.UpdateTimeline()
end

local function apply_tempo_plan(proj, plan)
  local envelope, _ = snapshot_tempo_envelope_chunk(proj)
  local prefix, points, suffix = transformed_tempo_chunk(
    plan.tempo_envelope_chunk, plan)
  local transformed = compose_tempo_chunk(prefix, points, suffix)
  set_tempo_chunk(proj, envelope, transformed)

  for _, overlay in ipairs(plan.tempo_overlays) do
    local index = find_tempo_marker_index_at_time(proj, overlay.time)
    if overlay.partial_before and index >= 0 then
      local flags = reaper.GetSetTempoTimeSigMarkerFlag(proj, index, 0, false)
      reaper.GetSetTempoTimeSigMarkerFlag(
        proj, index, (flags or 0) | 1 | 4, true)
    end
    local ok = reaper.SetTempoTimeSigMarker(
      proj, index, overlay.time, -1, -1,
      overlay.bpm, overlay.numerator, overlay.denominator, overlay.linear)
    if not ok then
      error(string.format(
        "REAPER rejected the required %d/%d time signature at %.9f seconds.",
        overlay.numerator, overlay.denominator, overlay.time))
    end
    if overlay.partial_before then
      enable_partial_measure_at_overlay(proj, overlay, index)
    end
  end
  reaper.UpdateTimeline()

  local ok, generated = reaper.GetEnvelopeStateChunk(envelope, "", false)
  if not ok then error("Could not capture the generated meter boundaries.") end

  if #plan.tempo_markers == 0 then
    -- REAPER creates an implicit baseline point when the first explicit meter
    -- boundary is added. Keep that helper point; without it, a chunk containing
    -- only the two requested boundaries can fall back to the project default.
    set_tempo_chunk(proj, envelope, generated)
    refresh_tempo_cache(proj)
    for _, generated_overlay in ipairs(plan.tempo_overlays) do
      if generated_overlay.partial_before then
        enable_partial_measure_at_overlay(proj, generated_overlay)
      end
      if generated_overlay.pattern and generated_overlay.pattern ~= "" then
        reaper.TimeMap_GetMetronomePattern(
          proj, generated_overlay.time, "SET:" .. generated_overlay.pattern)
      end
    end
    reaper.UpdateTimeline()
    return
  end

  local overlay_lines = {}
  for _, overlay in ipairs(plan.tempo_overlays) do
    local line = tempo_line_at_time(generated, overlay.time)
    if not line then
      error("Could not capture a generated time-signature boundary.")
    end
    overlay_lines[#overlay_lines + 1] = {overlay = overlay, line = line}
  end

  for _, generated_point in ipairs(overlay_lines) do
    local overlay = generated_point.overlay
    local replaced = false
    local filtered = {}
    for _, point in ipairs(points) do
      if approx(point.time, overlay.time, EPS_TIME) then
        if not replaced then
          filtered[#filtered + 1] = {
            time = overlay.time,
            line = generated_point.line,
            ordinal = point.ordinal
          }
          replaced = true
        end
      else
        filtered[#filtered + 1] = point
      end
    end
    points = filtered
    if not replaced then
      points[#points + 1] = {
        time = overlay.time,
        line = generated_point.line,
        ordinal = 1000000 + #points
      }
    end
  end

  local final_chunk = compose_tempo_chunk(prefix, points, suffix)
  set_tempo_chunk(proj, envelope, final_chunk)
  refresh_tempo_cache(proj)

  -- Generated time-signature points use REAPER's default click pattern. Restore
  -- the pattern that belongs to each surviving musical boundary where possible.
  for _, overlay in ipairs(plan.tempo_overlays) do
    if overlay.pattern and overlay.pattern ~= "" then
      reaper.TimeMap_GetMetronomePattern(
        proj, overlay.time, "SET:" .. overlay.pattern)
    end
  end
  for _, overlay in ipairs(plan.tempo_overlays) do
    if overlay.partial_before then
      enable_partial_measure_at_overlay(proj, overlay)
      if overlay.pattern and overlay.pattern ~= "" then
        reaper.TimeMap_GetMetronomePattern(
          proj, overlay.time, "SET:" .. overlay.pattern)
      end
    end
  end
  reaper.UpdateTimeline()
end

local function marker_identity_base(marker)
  return table.concat({
    marker.is_region and "R" or "M",
    tostring(marker.id),
    marker.name,
    tostring(marker.color)
  }, "\31")
end

local function snapshot_project_markers(proj)
  local result = {}
  local occurrences = {}
  local _, marker_count, region_count = reaper.CountProjectMarkers(proj)
  local total = marker_count + region_count
  for index = 0, total - 1 do
    local ok, is_region, position, region_end, name, id, color =
      reaper.EnumProjectMarkers3(proj, index)
    if ok == 0 then
      error("Could not read project marker/region " .. tostring(index) .. ".")
    end
    local marker = {
      enum_index = index,
      is_region = is_region,
      position = position,
      region_end = region_end,
      name = name or "",
      id = id,
      color = color,
      start_musical = musical_position(proj, position),
      end_musical = is_region and musical_position(proj, region_end) or nil
    }
    local base = marker_identity_base(marker)
    occurrences[base] = (occurrences[base] or 0) + 1
    marker.identity = base .. "\31" .. tostring(occurrences[base])
    result[#result + 1] = marker
  end
  return result
end

local function mapped_musical_position(plan, original_time, original_position)
  if plan.operation == "retime_selection" then return nil end
  if plan.direction > 0 then
    if approx(original_time, plan.action_start, EPS_TIME) then
      return {
        measure = plan.cursor_measure + plan.measure_delta,
        beat = 0
      }
    end
    if original_time > plan.action_start then
      return {
        measure = original_position.measure + plan.measure_delta,
        beat = original_position.beat
      }
    end
    return original_position
  end
  if approx(original_time, plan.action_end, EPS_TIME) then
    return {measure = plan.cursor_measure, beat = 0}
  end
  if original_time > plan.action_end then
    return {
      measure = original_position.measure + plan.measure_delta,
      beat = original_position.beat
    }
  end
  if original_time < plan.action_start - EPS_TIME then return original_position end
  return nil
end

local function project_marker_is_removed(plan, marker)
  if plan.direction >= 0 or marker.is_region then return false end
  return time_is_removed(plan, marker.position)
end

local function prepare_project_marker_plan(plan)
  plan.desired_project_markers = {}
  plan.removed_project_markers = 0
  plan.adjusted_regions = 0
  for _, marker in ipairs(plan.project_markers) do
    local desired = {
      identity = marker.identity,
      is_region = marker.is_region,
      id = marker.id,
      name = marker.name,
      color = marker.color
    }
    if project_marker_is_removed(plan, marker) then
      desired.survives = false
      plan.removed_project_markers = plan.removed_project_markers + 1
    else
      desired.position = map_time(plan, marker.position)
      desired.start_musical = mapped_musical_position(
        plan, marker.position, marker.start_musical)
      if marker.is_region then
        desired.region_end = map_time(plan, marker.region_end)
        desired.end_musical = mapped_musical_position(
          plan, marker.region_end, marker.end_musical)
        if desired.region_end <= desired.position + EPS_TIME then
          desired.survives = false
          plan.removed_project_markers = plan.removed_project_markers + 1
        else
          desired.survives = true
          if not approx(desired.position, marker.position, EPS_TIME) or
             not approx(desired.region_end, marker.region_end, EPS_TIME) then
            plan.adjusted_regions = plan.adjusted_regions + 1
          end
        end
      else
        desired.region_end = 0
        desired.survives = true
      end
    end
    plan.desired_project_markers[#plan.desired_project_markers + 1] = desired
  end
end

local function marker_match_score(marker, desired)
  if marker.is_region ~= desired.is_region then return nil end
  local distance = math.abs(marker.position - (desired.position or marker.position))
  if marker.identity == desired.identity then return 1000000000 - distance end
  if marker.name ~= desired.name then return nil end
  if marker.name == "" and marker.id ~= desired.id then return nil end
  local score = 100000
  if marker.id == desired.id then score = score + 10000 end
  if marker.color == desired.color then score = score + 1000 end
  if marker.is_region and desired.region_end then
    score = score - math.abs(marker.region_end - desired.region_end)
  end
  return score - distance
end

local function find_best_marker(markers, desired, used)
  local best, best_score
  for _, marker in ipairs(markers) do
    if not used[marker.enum_index] then
      local score = marker_match_score(marker, desired)
      if score and (not best_score or score > best_score) then
        best, best_score = marker, score
      end
    end
  end
  if best then used[best.enum_index] = true end
  return best
end

local function restore_project_markers(proj, plan)
  local current = snapshot_project_markers(proj)
  local used = {}
  for _, desired in ipairs(plan.desired_project_markers) do
    if desired.survives then find_best_marker(current, desired, used) end
  end

  -- Native remove-time operations can delete or renumber a marker on the right
  -- edge. Keep every matched survivor and remove only entries that do not belong
  -- to the preflight survivor set. Missing survivors are rebuilt below.
  for index = #current, 1, -1 do
    local marker = current[index]
    if not used[marker.enum_index] then
      if not reaper.DeleteProjectMarkerByIndex(proj, marker.enum_index) then
        error("Could not remove a project marker/region inside the deleted time.")
      end
    end
  end

  current = snapshot_project_markers(proj)
  used = {}
  local missing = {}
  for _, desired in ipairs(plan.desired_project_markers) do
    if desired.survives then
      local marker = find_best_marker(current, desired, used)
      if marker then
        local flags = 2
        if desired.name == "" then flags = flags | 1 end
        if not reaper.SetProjectMarkerByIndex2(
          proj, marker.enum_index, desired.is_region,
          desired.position, desired.region_end, desired.id,
          desired.name, desired.color, flags) then
          error("Could not restore project marker/region: " ..
            (desired.name ~= "" and desired.name or "(unnamed)") .. ".")
        end
      else
        missing[#missing + 1] = desired
      end
    end
  end
  reaper.SetProjectMarkerByIndex2(proj, -1, false, 0, 0, -1, "", 0, 2)

  for _, desired in ipairs(missing) do
    local returned_id = reaper.AddProjectMarker2(
      proj, desired.is_region, desired.position, desired.region_end,
      desired.name, desired.id, desired.color)
    if returned_id < 0 then
      error("Could not recreate project marker/region: " ..
        (desired.name ~= "" and desired.name or "(unnamed)") .. ".")
    end
    if returned_id ~= desired.id then
      local refreshed = snapshot_project_markers(proj)
      local recreated = find_best_marker(refreshed, desired, {})
      local flags = desired.name == "" and 1 or 0
      if not recreated or not reaper.SetProjectMarkerByIndex2(
        proj, recreated.enum_index, desired.is_region,
        desired.position, desired.region_end, desired.id,
        desired.name, desired.color, flags) then
        error("REAPER recreated a protected marker with the wrong number: " ..
          (desired.name ~= "" and desired.name or "(unnamed)") .. ".")
      end
    end
  end
end

local function verify_project_markers(proj, plan)
  local current = snapshot_project_markers(proj)
  local used = {}
  local expected_count = 0
  for _, desired in ipairs(plan.desired_project_markers) do
    if desired.survives then
      expected_count = expected_count + 1
      local marker = find_best_marker(current, desired, used)
      if not marker then
        return false, "A protected project marker/region is missing: " ..
          (desired.name ~= "" and desired.name or "(unnamed)") .. "."
      end
      if marker.id ~= desired.id or marker.name ~= desired.name or
         marker.color ~= desired.color then
        return false, "A protected project marker/region lost its number, name, or color: " ..
          (desired.name ~= "" and desired.name or "(unnamed)") .. "."
      end
      if not approx(marker.position, desired.position, EPS_TIME * 10) or
         (desired.is_region and not approx(
           marker.region_end, desired.region_end, EPS_TIME * 10)) then
        return false, "A protected project marker/region has the wrong clock position: " ..
          (desired.name ~= "" and desired.name or "(unnamed)") .. "."
      end
      if desired.start_musical and not same_musical_position(
        desired.start_musical, marker.start_musical) then
        return false, string.format(
          "Project marker/region '%s' landed at %s instead of %s.",
          desired.name ~= "" and desired.name or "(unnamed)",
          format_musical_position(marker.start_musical),
          format_musical_position(desired.start_musical))
      end
      if desired.end_musical and not same_musical_position(
        desired.end_musical, marker.end_musical) then
        return false, "A protected region end moved to the wrong musical position: " ..
          (desired.name ~= "" and desired.name or "(unnamed)") .. "."
      end
    end
  end
  if #current ~= expected_count then
    return false, string.format(
      "Project marker/region count is %d; expected %d.", #current, expected_count)
  end
  return true
end

local function normalized_item_chunk(chunk)
  return (chunk:gsub("([\r\n]%s*POSITION%s+)[^\r\n]+", "%1<MOVED>"))
end

local function canonical_chunk(chunk)
  return (chunk or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function retime_structural_chunk(chunk)
  local kept = {}
  for line in (canonical_chunk(chunk) .. "\n"):gmatch("(.-)\n") do
    local key = line:match("^%s*([%u_]+)")
    if key ~= "POSITION" and key ~= "LENGTH" and
       key ~= "FADEIN" and key ~= "FADEOUT" and
       key ~= "PLAYRATE" and key ~= "SM" and key ~= "SLOPE" then
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept, "\n")
end

local function item_chunk_at_position(chunk, position)
  local replacement = "%1" .. string.format("%.14f", position)
  local result, count = chunk:gsub(
    "([\r\n]%s*POSITION%s+)[^\r\n]+", replacement, 1)
  if count ~= 1 then error("Could not update a media item's chunk position.") end
  return result
end

local function snapshot_items(proj, plan)
  local protected = {}
  local rollback_items = {}
  local crossing = 0
  local affected = 0
  for index = 0, reaper.CountMediaItems(proj) - 1 do
    local item = reaper.GetMediaItem(proj, index)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = position + length
    local guid_ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    local chunk_ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not guid_ok or guid == "" or not chunk_ok then
      error("Could not snapshot media item " .. tostring(index + 1) .. ".")
    end
    rollback_items[#rollback_items + 1] = {guid = guid, chunk = chunk}
    if position >= plan.downstream_boundary - EPS_TIME then
      local original_musical = musical_position(proj, position)
      local desired_position = map_time(plan, position)
      local expected_musical = mapped_musical_position(
        plan, position, original_musical)
      protected[#protected + 1] = {
        guid = guid,
        position = position,
        desired_position = desired_position,
        expected_musical = expected_musical,
        normalize_boundary = approx(
          position, plan.downstream_boundary, EPS_TIME) and
          position ~= plan.downstream_boundary,
        chunk = chunk,
        normalized_chunk = normalized_item_chunk(chunk)
      }
    elseif plan.direction > 0 and
           position < plan.action_start and
           item_end > plan.action_start then
      crossing = crossing + 1
    elseif plan.direction < 0 and
           item_end > plan.action_start and
           position < plan.action_end then
      affected = affected + 1
    end
  end
  plan.protected_items = protected
  plan.rollback_items = rollback_items
  plan.crossing_items = crossing
  plan.affected_items = affected
end

local function item_display_name(item, index)
  local track = reaper.GetMediaItem_Track(item)
  local track_name = ""
  if track then
    local ok, name = reaper.GetTrackName(track)
    if ok then track_name = name or "" end
  end
  local take = reaper.GetActiveTake(item)
  local take_name = take and (reaper.GetTakeName(take) or "") or ""
  if take_name ~= "" then return take_name end
  if track_name ~= "" then return track_name .. " item " .. tostring(index + 1) end
  return "Item " .. tostring(index + 1)
end

local function take_uses_click_source(take)
  local source = reaper.GetMediaItemTake_Source(take)
  local visited = {}
  while source and not visited[source] do
    visited[source] = true
    local source_type = tostring(reaper.GetMediaSourceType(source) or ""):upper()
    if source_type == "CLICK" then return true end
    source = reaper.GetMediaSourceParent(source)
  end
  return false
end

local function retime_take_playrate(take_snapshot, ratio)
  if take_snapshot.is_click then return take_snapshot.playrate end
  return take_snapshot.playrate * ratio
end

local function snapshot_retime_items(proj, plan)
  local rollback_items = {}
  local protected = {}
  local selected_pieces = 0
  local crossing = 0
  local clipped = 0
  local trimmed_seconds = 0
  local stretch_markers = 0
  local click_takes = 0
  local internal_crossings = 0
  local clipped_labels = {}
  for index = 0, reaper.CountMediaItems(proj) - 1 do
    local item = reaper.GetMediaItem(proj, index)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = position + length
    local guid_ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    local chunk_ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not guid_ok or guid == "" or not chunk_ok then
      error("Could not snapshot media item " .. tostring(index + 1) .. ".")
    end
    rollback_items[#rollback_items + 1] = {guid = guid, chunk = chunk}
    local overlaps = item_end > plan.selection_start + EPS_TIME and
      position < plan.selection_end - EPS_TIME
    if overlaps then
      if reaper.GetMediaItemInfo_Value(item, "C_LOCK") ~= 0 then
        error("A locked media item overlaps the selected section. Unlock it before retiming the section.")
      end
      selected_pieces = selected_pieces + 1
      local crosses_left = position < plan.selection_start - EPS_TIME
      local crosses_right = item_end > plan.selection_end + EPS_TIME
      if crosses_left then crossing = crossing + 1 end
      if crosses_right then crossing = crossing + 1 end
      local piece_start = math.max(position, plan.selection_start)
      local piece_end = math.min(item_end, plan.selection_end)
      local mapped_start = map_retime_content_time(plan, piece_start)
      local mapped_end = map_retime_content_time(plan, piece_end)
      if mapped_end > plan.selection_end + EPS_TIME then
        clipped = clipped + 1
        trimmed_seconds = trimmed_seconds + mapped_end - plan.selection_end
        clipped_labels[#clipped_labels + 1] = item_display_name(item, index)
      end
      for _, boundary in ipairs(plan.retime_rate_boundaries or {}) do
        if position < boundary - EPS_TIME and item_end > boundary + EPS_TIME then
          internal_crossings = internal_crossings + 1
        end
      end
      for take_index = 0, reaper.GetMediaItemNumTakes(item) - 1 do
        local take = reaper.GetTake(item, take_index)
        if take then
          if take_uses_click_source(take) then
            click_takes = click_takes + 1
          elseif not reaper.TakeIsMIDI(take) and
                 type(reaper.GetTakeNumStretchMarkers) == "function" then
            stretch_markers = stretch_markers +
              reaper.GetTakeNumStretchMarkers(take)
          end
        end
      end
    else
      protected[#protected + 1] = {guid = guid}
    end
  end
  plan.rollback_items = rollback_items
  plan.protected_items = protected
  plan.retime_selected_pieces = selected_pieces
  plan.crossing_items = crossing
  plan.retime_clipped_items = clipped
  plan.retime_trimmed_seconds = trimmed_seconds
  plan.retime_clipped_labels = clipped_labels
  plan.retime_existing_stretch_markers = stretch_markers
  plan.retime_click_takes = click_takes
  plan.retime_internal_crossings = internal_crossings
  plan.retime_expected_splits = crossing + internal_crossings
  plan.affected_items = selected_pieces
end

local function split_items_at_boundary(proj, boundary)
  local items = {}
  for index = 0, reaper.CountMediaItems(proj) - 1 do
    items[#items + 1] = reaper.GetMediaItem(proj, index)
  end
  local splits = 0
  for _, item in ipairs(items) do
    if reaper.ValidatePtr2(proj, item, "MediaItem*") then
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end = position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if position < boundary - EPS_TIME and item_end > boundary + EPS_TIME then
        local right = reaper.SplitMediaItem(item, boundary)
        if not right then
          error(string.format("Could not split a media item at %.9f seconds.", boundary))
        end
        splits = splits + 1
      end
    end
  end
  return splits
end

local function snapshot_stretch_markers(take)
  local markers = {}
  if type(reaper.GetTakeNumStretchMarkers) ~= "function" then return markers end
  for index = 0, reaper.GetTakeNumStretchMarkers(take) - 1 do
    local returned_index, position, source_position =
      reaper.GetTakeStretchMarker(take, index)
    if returned_index < 0 then
      error("Could not read an existing stretch marker.")
    end
    markers[#markers + 1] = {
      position = position,
      source_position = source_position,
      slope = reaper.GetTakeStretchMarkerSlope(take, index)
    }
  end
  return markers
end

local function is_retime_split_boundary(plan, time)
  if approx(time, plan.selection_start, EPS_TIME * 10) or
     approx(time, plan.selection_end, EPS_TIME * 10) then return true end
  for _, boundary in ipairs(plan.retime_rate_boundaries or {}) do
    if approx(time, boundary, EPS_TIME * 10) then return true end
  end
  return false
end

local function capture_retime_segments(proj, plan)
  local segments = {}
  local click_takes = 0
  local selected_pieces = 0
  local stretch_markers = 0
  for index = 0, reaper.CountMediaItems(proj) - 1 do
    local item = reaper.GetMediaItem(proj, index)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = position + length
    local guid_ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    local chunk_ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not guid_ok or guid == "" or not chunk_ok then
      error("Could not capture a boundary-split media item.")
    end
    if (position < plan.selection_start - EPS_TIME and
        item_end > plan.selection_start + EPS_TIME) or
       (position < plan.selection_end - EPS_TIME and
        item_end > plan.selection_end + EPS_TIME) then
      error("A media item still crosses a selected-section boundary after automatic splitting.")
    end
    for _, boundary in ipairs(plan.retime_rate_boundaries or {}) do
      if position < boundary - EPS_TIME and item_end > boundary + EPS_TIME then
        error("A media item still crosses an internal tempo-rate boundary after automatic splitting.")
      end
    end
    local inside = position >= plan.selection_start - EPS_TIME and
      item_end <= plan.selection_end + EPS_TIME and
      item_end > plan.selection_start + EPS_TIME and
      position < plan.selection_end - EPS_TIME
    if inside then selected_pieces = selected_pieces + 1 end
    local takes = {}
    for take_index = 0, reaper.GetMediaItemNumTakes(item) - 1 do
      local take = reaper.GetTake(item, take_index)
      if take then
        local take_guid_ok, take_guid = reaper.GetSetMediaItemTakeInfo_String(
          take, "GUID", "", false)
        if not take_guid_ok or take_guid == "" then
          error("Could not identify a take before selected-section stretching.")
        end
        local is_click = take_uses_click_source(take)
        local is_midi = reaper.TakeIsMIDI(take) == true
        local take_stretch_markers = (is_midi or is_click) and {} or
          snapshot_stretch_markers(take)
        if inside and is_click then click_takes = click_takes + 1 end
        if inside then
          stretch_markers = stretch_markers + #take_stretch_markers
        end
        takes[#takes + 1] = {
          index = take_index,
          guid = take_guid,
          is_midi = is_midi,
          is_click = is_click,
          playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
          startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
          pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
          pitchmode = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE"),
          ppitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH"),
          stretchflags = reaper.GetMediaItemTakeInfo_Value(take, "I_STRETCHFLAGS"),
          stretchfadesize = reaper.GetMediaItemTakeInfo_Value(take, "F_STRETCHFADESIZE"),
          stretch_markers = take_stretch_markers
        }
      end
    end
    segments[#segments + 1] = {
      item = item,
      guid = guid,
      chunk = chunk,
      structural_chunk = retime_structural_chunk(chunk),
      position = position,
      length = length,
      inside = inside,
      retime_ratio = inside and retime_ratio_at_time(
        plan, position + math.min(length / 2, EPS_TIME * 100)) or 1,
      takes = takes,
      track = reaper.GetMediaItem_Track(item),
      group_id = reaper.GetMediaItemInfo_Value(item, "I_GROUPID"),
      fixed_lane = reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"),
      fade_in = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
      fade_out = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
      touches_left = inside and is_retime_split_boundary(plan, position),
      touches_right = inside and is_retime_split_boundary(plan, item_end)
    }
    if not reaper.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 0) then
      error("Could not temporarily protect a media item from the tempo-map edit.")
    end
    reaper.SetMediaItemInfo_Value(item, "C_AUTOSTRETCH", 0)
    reaper.UpdateItemInProject(item)
  end
  plan.retime_segments = segments
  plan.retime_click_takes = click_takes
  plan.retime_selected_pieces = selected_pieces
  plan.retime_existing_stretch_markers = stretch_markers
end

local function restore_scaled_stretch_markers(take, markers, ratio)
  local existing = reaper.GetTakeNumStretchMarkers(take)
  if existing > 0 and
     reaper.DeleteTakeStretchMarkers(take, 0, existing) ~= existing then
    error("Could not clear existing stretch markers before remapping them.")
  end
  local expected = {}
  for _, marker in ipairs(markers) do
    local new_position = marker.position / ratio
    local new_index = reaper.SetTakeStretchMarker(
      take, -1, new_position, marker.source_position)
    if new_index < 0 then
      error("Could not remap an existing stretch marker.")
    end
    if not reaper.SetTakeStretchMarkerSlope(take, new_index, marker.slope) then
      error("Could not restore an existing stretch-marker slope.")
    end
    expected[#expected + 1] = {
      position = new_position,
      source_position = marker.source_position,
      slope = marker.slope
    }
  end
  return expected
end

local function transform_retime_segments(proj, plan)
  local clipped = 0
  local seam_fades = 0
  for _, segment in ipairs(plan.retime_segments or {}) do
    if not reaper.ValidatePtr2(proj, segment.item, "MediaItem*") then
      error("A media item disappeared during the selected-section tempo edit.")
    end
    if not reaper.SetItemStateChunk(segment.item, segment.chunk, false) then
      error("Could not restore a media item after protecting it from the tempo map.")
    end
    if segment.inside then
      local ratio = segment.retime_ratio
      local new_position = map_retime_content_time(plan, segment.position)
      local mapped_end = map_retime_content_time(
        plan, segment.position + segment.length)
      local requested_length = mapped_end - new_position
      local new_length = math.min(requested_length,
        math.max(EPS_TIME, plan.selection_end - new_position))
      if new_length < requested_length - EPS_TIME then clipped = clipped + 1 end
      if not reaper.SetMediaItemInfo_Value(
          segment.item, "D_POSITION", new_position) or
         not reaper.SetMediaItemInfo_Value(
          segment.item, "D_LENGTH", new_length) then
        error("Could not place retimed media inside the selected section.")
      end
      segment.expected_position = new_position
      segment.expected_length = new_length
      segment.expected_group_id = segment.group_id
      segment.expected_fixed_lane = segment.fixed_lane
      segment.expected_takes = {}
      local has_audio = false
      for _, original_take in ipairs(segment.takes) do
        local take = reaper.GetTake(segment.item, original_take.index)
        if not take then error("A take disappeared during selected-section stretching.") end
        local take_guid_ok, take_guid = reaper.GetSetMediaItemTakeInfo_String(
          take, "GUID", "", false)
        if not take_guid_ok or take_guid ~= original_take.guid then
          error("A take identity changed during selected-section stretching.")
        end
        local expected_rate = retime_take_playrate(original_take, ratio)
        if not reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", expected_rate) then
          error("Could not set the selected take playback rate.")
        end
        local expected_pitchmode = original_take.pitchmode
        local expected_markers = {}
        if not original_take.is_midi and not original_take.is_click then
          has_audio = true
          reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
          expected_pitchmode = plan.pitch_mode
          reaper.SetMediaItemTakeInfo_Value(
            take, "I_PITCHMODE", expected_pitchmode)
          expected_markers = restore_scaled_stretch_markers(
            take, original_take.stretch_markers, ratio)
        end
        segment.expected_takes[#segment.expected_takes + 1] = {
          index = original_take.index,
          guid = original_take.guid,
          is_midi = original_take.is_midi,
          is_click = original_take.is_click,
          playrate = expected_rate,
          startoffs = original_take.startoffs,
          pitch = original_take.pitch,
          pitchmode = expected_pitchmode,
          stretchflags = original_take.stretchflags,
          stretchfadesize = original_take.stretchfadesize,
          stretch_markers = expected_markers
        }
      end
      segment.expected_fade_in = segment.fade_in
      segment.expected_fade_out = segment.fade_out
      if has_audio and plan.seam_fade_ms > 0 then
        local seam = math.min(plan.seam_fade_ms / 1000, new_length / 2)
        if segment.touches_left and seam > segment.expected_fade_in + EPS_TIME then
          segment.expected_fade_in = seam
          reaper.SetMediaItemInfo_Value(segment.item, "D_FADEINLEN", seam)
          seam_fades = seam_fades + 1
        end
        if (segment.touches_right or
            new_length < requested_length - EPS_TIME) and
           seam > segment.expected_fade_out + EPS_TIME then
          segment.expected_fade_out = seam
          reaper.SetMediaItemInfo_Value(segment.item, "D_FADEOUTLEN", seam)
          seam_fades = seam_fades + 1
        end
      end
    else
      segment.expected_position = segment.position
      segment.expected_length = segment.length
      segment.expected_chunk = canonical_chunk(segment.chunk)
    end
    reaper.UpdateItemInProject(segment.item)
  end
  plan.retime_clipped_items = clipped
  plan.performed_seam_fades = seam_fades
end

local function detect_retime_collisions(plan)
  local collisions = 0
  local segments = plan.retime_segments or {}
  for left_index = 1, #segments - 1 do
    local left = segments[left_index]
    for right_index = left_index + 1, #segments do
      local right = segments[right_index]
      if left.track == right.track and left.fixed_lane == right.fixed_lane then
        local originally_overlapped =
          left.position < right.position + right.length - EPS_TIME and
          right.position < left.position + left.length - EPS_TIME
        local newly_overlaps =
          left.expected_position < right.expected_position +
            right.expected_length - EPS_TIME and
          right.expected_position < left.expected_position +
            left.expected_length - EPS_TIME
        if newly_overlaps and not originally_overlapped then
          collisions = collisions + 1
        end
      end
    end
  end
  plan.retime_new_collisions = collisions
  return collisions
end

local function verify_retime_segments(proj, plan)
  if reaper.CountMediaItems(proj) ~= #(plan.retime_segments or {}) then
    return false, "The media-item count changed after the intentional boundary splits."
  end
  for _, segment in ipairs(plan.retime_segments or {}) do
    if not reaper.ValidatePtr2(proj, segment.item, "MediaItem*") then
      return false, "A media item is missing after selected-section stretching."
    end
    local position = reaper.GetMediaItemInfo_Value(segment.item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(segment.item, "D_LENGTH")
    if not approx(position, segment.expected_position, EPS_TIME * 10) or
       not approx(length, segment.expected_length, EPS_TIME * 10) then
      return false, "A media item did not remain at its verified selected/outside position."
    end
    if segment.inside then
      if position < plan.selection_start - EPS_TIME or
         position + length > plan.selection_end + EPS_TIME then
        return false, "Retimed media escaped the selected section."
      end
      if reaper.GetMediaItemInfo_Value(segment.item, "I_GROUPID") ~=
           segment.expected_group_id or
         reaper.GetMediaItemInfo_Value(segment.item, "I_FIXEDLANE") ~=
           segment.expected_fixed_lane then
        return false, "A selected item lost its group or fixed-lane identity."
      end
      if not approx(reaper.GetMediaItemInfo_Value(
           segment.item, "D_FADEINLEN"), segment.expected_fade_in, EPS_TIME) or
         not approx(reaper.GetMediaItemInfo_Value(
           segment.item, "D_FADEOUTLEN"), segment.expected_fade_out, EPS_TIME) then
        return false, "A selected item's seam fade was not preserved or applied."
      end
      local structure_ok, current_chunk = reaper.GetItemStateChunk(
        segment.item, "", false)
      if not structure_ok or retime_structural_chunk(current_chunk) ~=
           segment.structural_chunk then
        return false, "A selected item's pooled source, take envelopes, comping, or structural metadata changed unexpectedly."
      end
      for _, expected_take in ipairs(segment.expected_takes or {}) do
        local take = reaper.GetTake(segment.item, expected_take.index)
        local guid_ok, take_guid = false, ""
        if take then
          guid_ok, take_guid = reaper.GetSetMediaItemTakeInfo_String(
            take, "GUID", "", false)
        end
        if not take or not guid_ok or take_guid ~= expected_take.guid then
          return false, "A selected take lost its identity."
        end
        if take_uses_click_source(take) ~= expected_take.is_click then
          return false, "A selected take changed its media-source type."
        end
        if not take or not approx(reaper.GetMediaItemTakeInfo_Value(
            take, "D_PLAYRATE"), expected_take.playrate, 1e-9) then
          return false, "A selected take did not receive the required playback rate."
        end
        if not expected_take.is_midi and not expected_take.is_click and
           reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH") < 0.5 then
          return false, "Pitch preservation is not enabled on stretched audio."
        end
        if not approx(reaper.GetMediaItemTakeInfo_Value(
            take, "D_STARTOFFS"), expected_take.startoffs, 1e-9) or
           not approx(reaper.GetMediaItemTakeInfo_Value(
            take, "D_PITCH"), expected_take.pitch, 1e-9) or
           reaper.GetMediaItemTakeInfo_Value(
            take, "I_PITCHMODE") ~= expected_take.pitchmode then
          return false, "A selected take changed beyond rate and pitch-preserve state."
        end
        if not expected_take.is_midi and not expected_take.is_click then
          if reaper.GetMediaItemTakeInfo_Value(take, "I_STRETCHFLAGS") ~=
               expected_take.stretchflags or
             not approx(reaper.GetMediaItemTakeInfo_Value(
               take, "F_STRETCHFADESIZE"),
               expected_take.stretchfadesize, EPS_TIME) then
            return false, "A selected take's stretch quality settings changed unexpectedly."
          end
          if reaper.GetTakeNumStretchMarkers(take) ~=
               #expected_take.stretch_markers then
            return false, "A selected take lost an existing stretch marker."
          end
          for marker_index, expected_marker in ipairs(
              expected_take.stretch_markers) do
            local returned_index, marker_position, source_position =
              reaper.GetTakeStretchMarker(take, marker_index - 1)
            if returned_index < 0 or
               not approx(marker_position, expected_marker.position, EPS_TIME) or
               not approx(source_position, expected_marker.source_position, EPS_TIME) or
               not approx(reaper.GetTakeStretchMarkerSlope(
                 take, marker_index - 1), expected_marker.slope, 1e-9) then
              return false, "An existing stretch marker was not remapped exactly."
            end
          end
        end
      end
    else
      local chunk_ok, chunk = reaper.GetItemStateChunk(segment.item, "", false)
      if not chunk_ok or canonical_chunk(chunk) ~= segment.expected_chunk then
        return false, "Audio outside the selected section changed unexpectedly."
      end
    end
  end
  return true
end

local function current_items_by_guid(proj)
  local result = {}
  for index = 0, reaper.CountMediaItems(proj) - 1 do
    local item = reaper.GetMediaItem(proj, index)
    local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    if ok and guid ~= "" then result[guid] = item end
  end
  return result
end

local function normalize_protected_item_boundaries(proj, plan)
  local items = current_items_by_guid(proj)
  for _, original in ipairs(plan.protected_items) do
    if original.normalize_boundary then
      local item = items[original.guid]
      if not item then
        error("A boundary media item disappeared before the operation: " ..
          original.guid .. ".")
      end
      if not reaper.SetMediaItemInfo_Value(
        item, "D_POSITION", plan.downstream_boundary) then
        error("Could not normalize a media item on the edit boundary: " ..
          original.guid .. ".")
      end
      reaper.UpdateItemInProject(item)
    end
  end
end

local function restore_protected_items(proj, plan)
  local items = current_items_by_guid(proj)
  for _, original in ipairs(plan.protected_items) do
    local item = items[original.guid]
    if not item then
      error("A protected downstream media item was removed: " .. original.guid .. ".")
    end
    local restored_chunk = item_chunk_at_position(
      original.chunk, original.desired_position)
    if not reaper.SetItemStateChunk(item, restored_chunk, false) then
      error("Could not restore downstream media item: " .. original.guid .. ".")
    end
    reaper.UpdateItemInProject(item)
  end
end

local function verify_protected_items(proj, plan)
  local items = current_items_by_guid(proj)
  for _, original in ipairs(plan.protected_items) do
    local item = items[original.guid]
    if not item then
      return false, "A protected downstream media item is missing: " ..
        original.guid .. "."
    end
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if not approx(position, original.desired_position, EPS_TIME * 10) then
      return false, "A protected downstream media item has the wrong clock position: " ..
        original.guid .. "."
    end
    local current_musical = musical_position(proj, position)
    if not same_musical_position(current_musical, original.expected_musical) then
      return false, string.format(
        "Media item %s landed at %s instead of %s.", original.guid,
        format_musical_position(current_musical),
        format_musical_position(original.expected_musical))
    end
    local chunk_ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not chunk_ok or normalized_item_chunk(chunk) ~= original.normalized_chunk then
      return false, "A protected media item changed beyond its timeline position: " ..
        original.guid .. "."
    end
  end
  return true
end

local function snapshot_automation_envelopes(proj, plan)
  local result = {}
  local protected_count = 0
  local removed_count = 0
  local tempo_envelope = reaper.GetTrackEnvelopeByName(
    reaper.GetMasterTrack(proj), "Tempo map")

  local function visit_track(track, track_label, is_master, track_index)
    for envelope_index = 0, reaper.CountTrackEnvelopes(track) - 1 do
      local envelope = reaper.GetTrackEnvelope(track, envelope_index)
      if envelope and envelope ~= tempo_envelope then
        local _, name = reaper.GetEnvelopeName(envelope, "")
        local guid_ok, guid = reaper.GetSetEnvelopeInfo_String(
          envelope, "GUID", "", false)
        if not guid_ok or guid == "" then
          error("Could not identify automation envelope: " ..
            (name ~= "" and name or track_label) .. ".")
        end
        local chunk_ok, chunk = reaper.GetEnvelopeStateChunk(envelope, "", false)
        if not chunk_ok then
          error("Could not snapshot automation envelope: " ..
            (name ~= "" and name or track_label) .. ".")
        end
        local points = {}
        for point_index = 0,
            reaper.CountEnvelopePointsEx(envelope, -1) - 1 do
          local ok, time, value, shape, tension, selected =
            reaper.GetEnvelopePointEx(envelope, -1, point_index)
          if not ok then
            error("Could not read an automation point in " ..
              (name ~= "" and name or track_label) .. ".")
          end
          local survives = not time_is_removed(plan, time)
          if survives then protected_count = protected_count + 1
          else removed_count = removed_count + 1 end
          points[#points + 1] = {
            time = time,
            value = value,
            shape = shape,
            tension = tension,
            selected = selected,
            survives = survives,
            desired_time = survives and map_time(plan, time) or nil,
            desired_musical = survives and mapped_musical_position(
              plan, time, musical_position(proj, time)) or nil
          }
        end
        result[#result + 1] = {
          guid = guid,
          is_master = is_master,
          track_index = track_index,
          envelope_index = envelope_index,
          name = name or "",
          track_label = track_label,
          chunk = chunk,
          points = points
        }
      end
    end
  end

  visit_track(reaper.GetMasterTrack(proj), "master track", true, -1)
  for track_index = 0, reaper.CountTracks(proj) - 1 do
    visit_track(reaper.GetTrack(proj, track_index),
      "track " .. tostring(track_index + 1), false, track_index)
  end
  plan.automation_envelopes = result
  plan.protected_automation_points = protected_count
  plan.removed_automation_points = removed_count
end

local function resolve_automation_envelope(proj, descriptor)
  local track = descriptor.is_master and reaper.GetMasterTrack(proj) or
    reaper.GetTrack(proj, descriptor.track_index)
  if not track then return nil end
  for envelope_index = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local envelope = reaper.GetTrackEnvelope(track, envelope_index)
    local ok, guid = reaper.GetSetEnvelopeInfo_String(
      envelope, "GUID", "", false)
    if ok and guid == descriptor.guid then return envelope end
  end
  return nil
end

local function restore_automation_points(proj, plan)
  for _, original_envelope in ipairs(plan.automation_envelopes or {}) do
    local envelope = resolve_automation_envelope(proj, original_envelope)
    local label = original_envelope.name ~= "" and original_envelope.name or
      original_envelope.track_label
    if not envelope or not reaper.ValidatePtr2(
      proj, envelope, "TrackEnvelope*") then
      error("A protected automation envelope is missing: " .. label .. ".")
    end
    if plan.operation == "retime_selection" then
      if not reaper.SetEnvelopeStateChunk(
          envelope, original_envelope.chunk, false) then
        error("Could not restore the complete automation envelope: " ..
          label .. ".")
      end
      reaper.Envelope_SortPointsEx(envelope, -1)
    else
      for point_index = reaper.CountEnvelopePointsEx(envelope, -1) - 1, 0, -1 do
        if not reaper.DeleteEnvelopePointEx(envelope, -1, point_index) then
          error("Could not clear automation points for restoration in " ..
            label .. ".")
        end
      end
      for _, original in ipairs(original_envelope.points) do
        if original.survives and not reaper.InsertEnvelopePointEx(
          envelope, -1, original.desired_time, original.value,
          original.shape, original.tension, original.selected, true) then
          error("Could not restore an automation point in " .. label .. ".")
        end
      end
      if not reaper.Envelope_SortPointsEx(envelope, -1) then
        error("Could not sort restored automation points in " .. label .. ".")
      end
    end
  end
end

local function verify_automation_points(proj, plan)
  for _, original_envelope in ipairs(plan.automation_envelopes or {}) do
    local envelope = resolve_automation_envelope(proj, original_envelope)
    local label = original_envelope.name ~= "" and original_envelope.name or
      original_envelope.track_label
    if not envelope or not reaper.ValidatePtr2(
      proj, envelope, "TrackEnvelope*") then
      return false, "A protected automation envelope is missing: " .. label .. "."
    end
    if plan.operation == "retime_selection" then
      local chunk_ok, chunk = reaper.GetEnvelopeStateChunk(envelope, "", false)
      if not chunk_ok or canonical_chunk(chunk) ~= canonical_chunk(
          original_envelope.chunk) then
        return false, "Automation outside/inside the selection changed unexpectedly in " ..
          label .. "."
      end
    else
      local current = {}
      for point_index = 0, reaper.CountEnvelopePointsEx(envelope, -1) - 1 do
        local ok, time, value, shape, tension, selected =
          reaper.GetEnvelopePointEx(envelope, -1, point_index)
        if ok then
          current[#current + 1] = {
            index = point_index,
            time = time,
            value = value,
            shape = shape,
            tension = tension,
            selected = selected
          }
        end
      end
      local used = {}
      local expected_count = 0
      for _, original in ipairs(original_envelope.points) do
        if original.survives then
          expected_count = expected_count + 1
          local match
          for _, candidate in ipairs(current) do
            if not used[candidate.index] and
               approx(candidate.time, original.desired_time, EPS_TIME * 10) and
               approx(candidate.value, original.value, 1e-12) and
               candidate.shape == original.shape and
               approx(candidate.tension, original.tension, 1e-12) and
               candidate.selected == original.selected then
              match = candidate
              break
            end
          end
          if not match then
            return false, "A protected automation point was removed, changed, or misplaced in " ..
              label .. "."
          end
          used[match.index] = true
          if original.desired_musical and not same_musical_position(
            musical_position(proj, match.time), original.desired_musical) then
            return false, "A protected automation point moved to the wrong musical position in " ..
              label .. "."
          end
        end
      end
      if #current ~= expected_count then
        return false, string.format(
          "Automation point count in %s is %d; expected %d.",
          label, #current, expected_count)
      end
    end
  end
  return true
end

local function tempo_marker_is_removed(plan, marker)
  return tempo_point_is_removed(plan, marker.time)
end

local function expected_tempo_musical(plan, marker)
  if plan.direction > 0 and
     marker.time >= plan.action_start - EPS_TIME then
    return {measure = marker.measure + plan.measure_delta, beat = marker.beat}
  end
  if plan.direction < 0 and
     marker.time >= plan.action_end - EPS_TIME then
    if approx(marker.time, plan.action_end, EPS_TIME) then
      return {measure = plan.cursor_measure, beat = 0}
    end
    return {measure = marker.measure + plan.measure_delta, beat = marker.beat}
  end
  return {measure = marker.measure, beat = marker.beat}
end

local function expected_tempo_meter(plan, marker)
  if plan.changed_measure and marker.measure == plan.changed_measure and
     approx(marker.beat, 0, EPS_BEAT) then
    return plan.changed_numerator, plan.changed_denominator
  end
  return marker.numerator, marker.denominator
end

local function expected_tempo_marker_count(plan)
  local times = {}
  local function add(time)
    for _, existing in ipairs(times) do
      if approx(existing, time, EPS_TIME * 10) then return end
    end
    times[#times + 1] = time
  end
  if #plan.tempo_markers == 0 then add(0) end
  for _, marker in ipairs(plan.tempo_markers) do
    if not tempo_marker_is_removed(plan, marker) then
      add(map_tempo_time(plan, marker.time))
    end
  end
  for _, point in ipairs(plan.tempo_overlays) do add(point.time) end
  return #times
end

local function verify_retime_tempo_markers(proj, plan)
  local current = snapshot_tempo_markers(proj)
  local used = {}
  local function find_expected(time, bpm, numerator, denominator, linear)
    for _, candidate in ipairs(current) do
      if not used[candidate.index] and
         approx(candidate.time, time, EPS_TIME * 20) and
         approx(candidate.bpm, bpm, EPS_BPM * 100) and
         candidate.numerator == numerator and
         candidate.denominator == denominator and
         candidate.linear == linear then
        used[candidate.index] = true
        return candidate
      end
    end
    return nil
  end

  for _, original in ipairs(plan.tempo_markers) do
    local at_start = approx(original.time, plan.selection_start, EPS_TIME)
    local at_end = approx(original.time, plan.selection_end, EPS_TIME)
    local inside = original.time > plan.selection_start + EPS_TIME and
      original.time < plan.selection_end - EPS_TIME
    if not at_start and not at_end and not inside then
      local found = find_expected(original.time, original.bpm,
        original.numerator, original.denominator, original.linear)
      if not found then
        return false, string.format(
          "A tempo/time-signature marker outside the selection moved or changed at %.9f seconds.",
          original.time)
      end
      if found.pattern ~= original.pattern then
        return false, "A metronome pattern outside the selection changed unexpectedly."
      end
    end
  end

  for _, point in ipairs(plan.tempo_overlays) do
    local found = find_expected(point.time, point.bpm, point.numerator,
      point.denominator, point.linear)
    if not found then
      return false, string.format(
        "The required selected-section tempo boundary is missing at %.9f seconds.",
        point.time)
    end
    if point.pattern ~= "" and found.pattern ~= point.pattern then
      return false, "A selected-section metronome pattern was not restored."
    end
    if point.partial_before then
      local flags = reaper.GetSetTempoTimeSigMarkerFlag(
        proj, found.index, 0, false)
      if ((flags or 0) & 4) == 0 then
        return false, "The fixed right boundary is missing its partial-measure protection."
      end
    end
  end

  local expected_count = expected_tempo_marker_count(plan)
  if #current ~= expected_count then
    return false, string.format(
      "Tempo/time-signature marker count is %d; expected %d.",
      #current, expected_count)
  end
  return true
end

local function verify_tempo_markers(proj, plan)
  if plan.operation == "retime_selection" then
    return verify_retime_tempo_markers(proj, plan)
  end
  local current = snapshot_tempo_markers(proj)
  local used = {}
  for _, original in ipairs(plan.tempo_markers) do
    if not tempo_marker_is_removed(plan, original) then
      local expected_position = expected_tempo_musical(plan, original)
      local expected_num, expected_den = expected_tempo_meter(plan, original)
      local found
      for _, candidate in ipairs(current) do
        if not used[candidate.index] and
           candidate.measure == expected_position.measure and
           approx(candidate.beat, expected_position.beat, EPS_BEAT * 10) and
           approx(candidate.bpm, original.bpm, EPS_BPM) and
           candidate.linear == original.linear and
           candidate.numerator == expected_num and
           candidate.denominator == expected_den then
          found = candidate
          break
        end
      end
      if not found then
        return false, string.format(
          "Original tempo/time-signature marker at measure %d, beat %.6f was removed, changed, or misplaced.",
          original.measure + 1, original.beat + 1)
      end
      used[found.index] = true
      local changed_meter_start = plan.changed_measure and
        original.measure == plan.changed_measure and
        approx(original.beat, 0, EPS_BEAT)
      if not changed_meter_start and found.pattern ~= original.pattern then
        return false, string.format(
          "The metronome pattern at measure %d, beat %.6f changed unexpectedly.",
          original.measure + 1, original.beat + 1)
      end
    end
  end
  local expected_count = expected_tempo_marker_count(plan)
  if #current ~= expected_count then
    return false, string.format(
      "Tempo/time-signature marker count is %d; expected %d.",
      #current, expected_count)
  end
  return true
end

local function nearest_bar_info(proj, cursor)
  local _, measure = reaper.TimeMap2_timeToBeats(proj, cursor)
  local start_time = reaper.TimeMap_GetMeasureInfo(proj, measure)
  local next_time = reaper.TimeMap_GetMeasureInfo(proj, measure + 1)
  if math.abs(cursor - next_time) < math.abs(cursor - start_time) then
    return measure + 1, next_time
  end
  return measure, start_time
end

local function barline_at_cursor(proj)
  local cursor = reaper.GetCursorPositionEx(proj)
  local beat, measure = reaper.TimeMap2_timeToBeats(proj, cursor)
  local measure_time = reaper.TimeMap_GetMeasureInfo(proj, measure)
  if approx(beat, 0, EPS_BEAT * 10) and
     approx(cursor, measure_time, EPS_TIME * 10) then
    return cursor, measure
  end
  return nil, measure
end

local function barline_at_time(proj, time)
  local beat, measure = reaper.TimeMap2_timeToBeats(proj, time)
  local measure_time = reaper.TimeMap_GetMeasureInfo(proj, measure)
  if approx(beat, 0, EPS_BEAT * 10) and
     approx(time, measure_time, EPS_TIME * 10) then
    return time, measure
  end
  local next_time = reaper.TimeMap_GetMeasureInfo(proj, measure + 1)
  if approx(time, next_time, EPS_TIME * 10) then
    return time, measure + 1
  end
  return nil, measure
end

local function effective_meter(proj, time, right_side)
  local probe = time
  if right_side then probe = time + EPS_TIME * 10
  else probe = math.max(0, time - EPS_TIME * 10) end
  return reaper.TimeMap_GetTimeSigAtTime(proj, probe)
end

local function overlay(time, bpm, numerator, denominator, linear, pattern,
    partial_before)
  return {
    time = time,
    bpm = bpm,
    numerator = numerator,
    denominator = denominator,
    linear = linear or false,
    pattern = pattern or "",
    partial_before = partial_before == true
  }
end

local function validate_environment(proj)
  if get_reaper_version() < 7.75 then
    error("This safety-focused app requires REAPER 7.75 or newer.")
  end
  if reaper.GetPlayStateEx(proj) ~= 0 then
    error("Stop playback or recording before changing musical time.")
  end
  if reaper.GetSetProjectInfo(proj, "READONLY", 0, false) ~= 0 then
    error("The active project is read-only.")
  end
end

local function validate_common(proj, state)
  validate_environment(proj)
  local cursor, measure = barline_at_cursor(proj)
  if not cursor then
    error("The edit cursor must be exactly on a bar line. Use the Snap button in the app.")
  end
  local count = clamp(round(tonumber(state.count) or 1), 1, MAX_COUNT)
  return cursor, measure, count
end

local function base_plan(proj, state)
  local cursor, cursor_measure, count = validate_common(proj, state)
  local tempo_markers = snapshot_tempo_markers(proj)
  local _, tempo_chunk = snapshot_tempo_envelope_chunk(proj)
  return {
    operation = state.operation,
    cursor = cursor,
    cursor_measure = cursor_measure,
    count = count,
    tempo_markers = tempo_markers,
    tempo_envelope_chunk = tempo_chunk,
    old_time_selection_start = select(1,
      reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)),
    old_time_selection_end = select(2,
      reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false))
  }
end

local function build_retime_selection_plan(proj, state)
  validate_environment(proj)
  local selection_start, selection_end = reaper.GetSet_LoopTimeRange2(
    proj, false, false, 0, 0, false)
  if selection_end <= selection_start + EPS_TIME then
    error("Create a time selection around the section you want to retime.")
  end
  local start_time, start_measure = barline_at_time(proj, selection_start)
  local end_time, end_measure = barline_at_time(proj, selection_end)
  if not start_time or not end_time then
    error("Both edges of the time selection must be exactly on bar lines.")
  end
  if end_measure <= start_measure then
    error("The time selection must contain at least one complete measure.")
  end

  local tempo_markers = snapshot_tempo_markers(proj)
  local _, tempo_chunk = snapshot_tempo_envelope_chunk(proj)
  if tempo_ramp_overlaps(tempo_markers, selection_start, selection_end) then
    error("The selected section contains a linear tempo ramp. Flatten that ramp before using fixed-boundary retiming.")
  end

  local source_num, source_den, source_bpm = effective_meter(
    proj, selection_start, true)
  for measure = start_measure, end_measure - 1 do
    local measure_start =
      reaper.TimeMap_GetMeasureInfo(proj, measure)
    if measure_start < selection_start - EPS_TIME or
       measure_start >= selection_end + EPS_TIME then
      error("The selected section's measure map is inconsistent.")
    end
  end

  local retime_mode = state.retime_mode == "offset" and "offset" or "target"
  local bpm_offset = tonumber(state.bpm_offset) or 0
  local target_bpm = retime_mode == "offset" and
    source_bpm + bpm_offset or (tonumber(state.bpm) or source_bpm)
  if target_bpm < MIN_BPM or target_bpm > MAX_BPM then
    error(string.format("The selected section's starting tempo would be %.3f BPM; every adjusted tempo must remain between %d and %d BPM.",
      target_bpm, MIN_BPM, MAX_BPM))
  end
  local target_num = retime_mode == "offset" and source_num or
    clamp(round(tonumber(state.numerator) or source_num), 1, MAX_NUMERATOR)
  local target_den = retime_mode == "offset" and source_den or
    (tonumber(state.denominator) or source_den)
  local valid_denominator = false
  for _, denominator in ipairs(DENOMINATORS) do
    if denominator == target_den then valid_denominator = true; break end
  end
  if not valid_denominator then
    error("Target time-signature denominator must be 1, 2, 4, 8, 16, or 32.")
  end

  local restore_num, restore_den, restore_bpm = effective_meter(
    proj, selection_end, true)
  local restore_marker = tempo_marker_exactly_at(tempo_markers, selection_end)
  local restore_linear = restore_marker and restore_marker.linear or false
  local restore_pattern = metronome_pattern(proj, selection_end + EPS_TIME * 10)
  local source_pattern = metronome_pattern(
    proj, selection_start + EPS_TIME * 10)
  local target_pattern = (target_num == source_num and target_den == source_den) and
    source_pattern or ""
  local base_ratio = target_bpm / source_bpm
  local pitch_mode = round(tonumber(state.pitch_mode) or -1)
  if pitch_mode < -1 then pitch_mode = -1 end
  local seam_fade_ms = clamp(
    tonumber(state.seam_fade_ms) or DEFAULT_SEAM_FADE_MS,
    0, MAX_SEAM_FADE_MS)
  local source_events = {{
    time = selection_start,
    bpm = source_bpm,
    numerator = source_num,
    denominator = source_den,
    pattern = source_pattern
  }}
  for _, marker in ipairs(tempo_markers) do
    if marker.time > selection_start + EPS_TIME and
       marker.time < selection_end - EPS_TIME then
      source_events[#source_events + 1] = {
        time = marker.time,
        bpm = marker.bpm,
        numerator = marker.numerator,
        denominator = marker.denominator,
        pattern = marker.pattern
      }
    end
  end
  table.sort(source_events, function(a, b) return a.time < b.time end)

  local spans = {}
  local mapped_cursor = selection_start
  local minimum_ratio, maximum_ratio
  for index, event in ipairs(source_events) do
    local source_end = source_events[index + 1] and
      source_events[index + 1].time or selection_end
    local adjusted_bpm = retime_mode == "offset" and
      event.bpm + bpm_offset or event.bpm * base_ratio
    if adjusted_bpm < MIN_BPM or adjusted_bpm > MAX_BPM then
      error(string.format(
        "Adjusting the tempo marker at %.3f seconds would produce %.3f BPM, outside the %d-%d BPM safety range.",
        event.time, adjusted_bpm, MIN_BPM, MAX_BPM))
    end
    local span_ratio = adjusted_bpm / event.bpm
    local mapped_end = mapped_cursor +
      (source_end - event.time) / span_ratio
    spans[#spans + 1] = {
      source_start = event.time,
      source_end = source_end,
      target_start = mapped_cursor,
      target_end = mapped_end,
      source_bpm = event.bpm,
      target_bpm = adjusted_bpm,
      ratio = span_ratio,
      numerator = event.numerator,
      denominator = event.denominator,
      pattern = event.pattern
    }
    event.mapped_time = mapped_cursor
    event.adjusted_bpm = adjusted_bpm
    mapped_cursor = mapped_end
    minimum_ratio = minimum_ratio and math.min(minimum_ratio, span_ratio) or
      span_ratio
    maximum_ratio = maximum_ratio and math.max(maximum_ratio, span_ratio) or
      span_ratio
  end

  local tempo_overlays = {
    overlay(selection_start, target_bpm, target_num, target_den,
      false, target_pattern)
  }
  local internal_tempo_markers = 0
  local trimmed_tempo_markers = 0
  local rate_boundaries = {}
  for index = 2, #source_events do
    local event = source_events[index]
    if event.mapped_time < selection_end - EPS_TIME then
      tempo_overlays[#tempo_overlays + 1] = overlay(
        event.mapped_time, event.adjusted_bpm,
        event.numerator, event.denominator, false, event.pattern, true)
      internal_tempo_markers = internal_tempo_markers + 1
      if not approx(spans[index - 1].ratio, spans[index].ratio, EPS_BPM) then
        rate_boundaries[#rate_boundaries + 1] = event.time
      end
    else
      trimmed_tempo_markers = trimmed_tempo_markers + 1
    end
  end
  tempo_overlays[#tempo_overlays + 1] = overlay(
    selection_end, restore_bpm, restore_num, restore_den,
    restore_linear, restore_pattern, true)
  local mapped_duration = mapped_cursor - selection_start
  local overall_ratio = (selection_end - selection_start) /
    math.max(mapped_duration, EPS_TIME)
  local plan = {
    operation = "retime_selection",
    cursor = selection_start,
    original_edit_cursor = reaper.GetCursorPositionEx(proj),
    cursor_measure = start_measure,
    count = end_measure - start_measure,
    direction = 0,
    measure_delta = 0,
    action_start = selection_start,
    action_end = selection_end,
    duration = selection_end - selection_start,
    downstream_boundary = selection_end,
    selection_start = selection_start,
    selection_end = selection_end,
    selection_start_measure = start_measure,
    selection_end_measure = end_measure,
    source_bpm = source_bpm,
    source_numerator = source_num,
    source_denominator = source_den,
    retime_mode = retime_mode,
    bpm_offset = bpm_offset,
    target_bpm = target_bpm,
    target_numerator = target_num,
    target_denominator = target_den,
    restore_bpm = restore_bpm,
    restore_numerator = restore_num,
    restore_denominator = restore_den,
    retime_ratio = overall_ratio,
    retime_ratio_min = minimum_ratio or overall_ratio,
    retime_ratio_max = maximum_ratio or overall_ratio,
    retime_spans = spans,
    retime_rate_boundaries = rate_boundaries,
    retime_content_end = mapped_cursor,
    retime_gap_seconds = math.max(0, selection_end - mapped_cursor),
    pitch_mode = pitch_mode,
    seam_fade_ms = seam_fade_ms,
    retime_internal_tempo_markers = internal_tempo_markers,
    retime_trimmed_tempo_markers = trimmed_tempo_markers,
    tempo_markers = tempo_markers,
    tempo_envelope_chunk = tempo_chunk,
    old_time_selection_start = selection_start,
    old_time_selection_end = selection_end,
    tempo_overlays = tempo_overlays
  }
  if retime_mode == "offset" then
    plan.title = string.format(
      "Adjust selected section by %+.3f BPM across %d tempo %s",
      bpm_offset, #spans, plural(#spans, "segment"))
  else
    plan.title = string.format(
      "Retime selected section from %.3f to %.3f BPM (%d/%d to %d/%d)",
      source_bpm, target_bpm, source_num, source_den, target_num, target_den)
  end
  plan.summary = plan.title
  return plan
end

local function build_insert_measures_plan(proj, state)
  local plan = base_plan(proj, state)
  local numerator = clamp(round(tonumber(state.numerator) or 4), 1, MAX_NUMERATOR)
  local denominator = tonumber(state.denominator) or 4
  local restore_num, restore_den, restore_bpm = effective_meter(proj, plan.cursor, true)
  local source_marker = tempo_marker_exactly_at(plan.tempo_markers, plan.cursor)
  local restore_linear = source_marker and source_marker.linear or false
  local restore_pattern = metronome_pattern(proj, plan.cursor + EPS_TIME * 10)

  if tempo_ramp_overlaps(
    plan.tempo_markers, plan.cursor - EPS_TIME * 20,
    plan.cursor + EPS_TIME * 20) then
    error("A linear tempo ramp crosses the insertion bar line. The app made no changes because extending that ramp requires a musical decision.")
  end

  local qn_length = plan.count * numerator * 4 / denominator
  local duration = qn_length * 60 / restore_bpm
  if duration <= EPS_TIME then error("The requested inserted duration is invalid.") end

  plan.direction = 1
  plan.measure_delta = plan.count
  plan.action_start = plan.cursor
  plan.action_end = plan.cursor + duration
  plan.duration = duration
  plan.downstream_boundary = plan.cursor
  plan.insert_numerator = numerator
  plan.insert_denominator = denominator
  plan.restore_numerator = restore_num
  plan.restore_denominator = restore_den
  plan.restore_bpm = restore_bpm
  plan.tempo_overlays = {
    overlay(plan.cursor, restore_bpm, numerator, denominator, false, ""),
    overlay(plan.cursor + duration, restore_bpm, restore_num, restore_den,
      restore_linear, restore_pattern)
  }
  plan.title = string.format("Insert %d %s of %d/%d at bar %s",
    plan.count, plural(plan.count, "measure"), numerator, denominator,
    measure_label(plan.cursor_measure))
  plan.summary = string.format(
    "Insert %d %s of %d/%d before bar %s",
    plan.count, plural(plan.count, "measure"), numerator, denominator,
    measure_label(plan.cursor_measure))
  return plan
end

local function build_remove_measures_plan(proj, state)
  local plan = base_plan(proj, state)
  local end_time = reaper.TimeMap_GetMeasureInfo(
    proj, plan.cursor_measure + plan.count)
  local duration = end_time - plan.cursor
  if duration <= EPS_TIME then error("The requested measure range is invalid.") end
  if tempo_ramp_overlaps(plan.tempo_markers, plan.cursor, end_time) then
    error("The measures to remove contain a linear tempo ramp. The app made no changes because joining the remaining ramp endpoints requires a musical decision.")
  end
  local restore_num, restore_den, restore_bpm = effective_meter(proj, end_time, true)
  local end_marker = tempo_marker_exactly_at(plan.tempo_markers, end_time)
  local restore_linear = end_marker and end_marker.linear or false
  local restore_pattern = metronome_pattern(proj, end_time + EPS_TIME * 10)

  plan.direction = -1
  plan.measure_delta = -plan.count
  plan.action_start = plan.cursor
  plan.action_end = end_time
  plan.duration = duration
  plan.downstream_boundary = end_time
  plan.restore_numerator = restore_num
  plan.restore_denominator = restore_den
  plan.restore_bpm = restore_bpm
  plan.tempo_overlays = {
    overlay(plan.cursor, restore_bpm, restore_num, restore_den,
      restore_linear, restore_pattern)
  }
  plan.title = string.format("Remove %d %s starting at bar %s",
    plan.count, plural(plan.count, "measure"),
    measure_label(plan.cursor_measure))
  plan.summary = plan.title
  return plan
end

local function build_add_beats_plan(proj, state)
  local plan = base_plan(proj, state)
  if plan.cursor_measure <= 0 then
    error("There is no preceding measure to extend at this bar line.")
  end
  local target_measure = plan.cursor_measure - 1
  local target_start, _, _, numerator, denominator, target_bpm =
    reaper.TimeMap_GetMeasureInfo(proj, target_measure)
  local new_numerator = numerator + plan.count
  if new_numerator > MAX_NUMERATOR then
    error(string.format("The resulting meter %d/%d exceeds the safety limit of %d beats.",
      new_numerator, denominator, MAX_NUMERATOR))
  end
  if tempo_ramp_overlaps(plan.tempo_markers, target_start, plan.cursor) then
    error("The measure to extend contains a linear tempo ramp. The app made no changes because extending that ramp requires a musical decision.")
  end
  local restore_num, restore_den, restore_bpm = effective_meter(proj, plan.cursor, true)
  local end_bpm = select(3, effective_meter(proj, plan.cursor, false))
  local source_marker = tempo_marker_exactly_at(plan.tempo_markers, plan.cursor)
  local restore_linear = source_marker and source_marker.linear or false
  local restore_pattern = metronome_pattern(proj, plan.cursor + EPS_TIME * 10)
  local duration = plan.count * 4 / denominator * 60 / end_bpm

  plan.direction = 1
  plan.measure_delta = 0
  plan.action_start = plan.cursor
  plan.action_end = plan.cursor + duration
  plan.duration = duration
  plan.downstream_boundary = plan.cursor
  plan.changed_measure = target_measure
  plan.changed_measure_start = target_start
  plan.changed_numerator = new_numerator
  plan.changed_denominator = denominator
  plan.restore_numerator = restore_num
  plan.restore_denominator = restore_den
  plan.tempo_overlays = {
    overlay(target_start, target_bpm, new_numerator, denominator, false, ""),
    overlay(plan.cursor + duration, restore_bpm, restore_num, restore_den,
      restore_linear, restore_pattern)
  }
  plan.title = string.format("Add %d %s to bar %s (%d/%d to %d/%d)",
    plan.count, plural(plan.count, "beat"), measure_label(target_measure),
    numerator, denominator, new_numerator, denominator)
  plan.summary = plan.title
  return plan
end

local function build_remove_beats_plan(proj, state)
  local plan = base_plan(proj, state)
  if plan.cursor_measure <= 0 then
    error("There is no preceding measure to shorten at this bar line.")
  end
  local target_measure = plan.cursor_measure - 1
  local target_start, _, qn_end, numerator, denominator, target_bpm =
    reaper.TimeMap_GetMeasureInfo(proj, target_measure)
  if plan.count >= numerator then
    error(string.format(
      "Bar %s has %d beats. Remove at most %d so at least one beat remains.",
      measure_label(target_measure), numerator, numerator - 1))
  end
  if tempo_ramp_overlaps(plan.tempo_markers, target_start, plan.cursor) then
    error("The measure to shorten contains a linear tempo ramp. The app made no changes because shortening that ramp requires a musical decision.")
  end
  local cut_qn = qn_end - plan.count * 4 / denominator
  local cut_start = reaper.TimeMap2_QNToTime(proj, cut_qn)
  local duration = plan.cursor - cut_start
  if duration <= EPS_TIME then error("The requested beat range is invalid.") end
  local restore_num, restore_den, restore_bpm = effective_meter(proj, plan.cursor, true)
  local source_marker = tempo_marker_exactly_at(plan.tempo_markers, plan.cursor)
  local restore_linear = source_marker and source_marker.linear or false
  local restore_pattern = metronome_pattern(proj, plan.cursor + EPS_TIME * 10)
  local new_numerator = numerator - plan.count

  plan.direction = -1
  plan.measure_delta = 0
  plan.action_start = cut_start
  plan.action_end = plan.cursor
  plan.duration = duration
  plan.downstream_boundary = plan.cursor
  plan.changed_measure = target_measure
  plan.changed_measure_start = target_start
  plan.changed_numerator = new_numerator
  plan.changed_denominator = denominator
  plan.restore_numerator = restore_num
  plan.restore_denominator = restore_den
  plan.tempo_overlays = {
    overlay(target_start, target_bpm, new_numerator, denominator, false, ""),
    overlay(cut_start, restore_bpm, restore_num, restore_den,
      restore_linear, restore_pattern)
  }
  plan.title = string.format("Remove %d %s from bar %s (%d/%d to %d/%d)",
    plan.count, plural(plan.count, "beat"), measure_label(target_measure),
    numerator, denominator, new_numerator, denominator)
  plan.summary = plan.title
  return plan
end

local PLAN_BUILDERS = {
  insert_measures = build_insert_measures_plan,
  remove_measures = build_remove_measures_plan,
  add_beats = build_add_beats_plan,
  remove_beats = build_remove_beats_plan,
  retime_selection = build_retime_selection_plan
}

local function build_plan(proj, state, full_snapshot)
  local builder = PLAN_BUILDERS[state.operation]
  if not builder then error("Unknown operation.") end
  local plan = builder(proj, state)
  if full_snapshot then
    plan.project_markers = snapshot_project_markers(proj)
    prepare_project_marker_plan(plan)
    if plan.operation == "retime_selection" then
      snapshot_retime_items(proj, plan)
    else
      snapshot_items(proj, plan)
    end
    snapshot_automation_envelopes(proj, plan)
    plan.removed_tempo_markers = 0
    for _, marker in ipairs(plan.tempo_markers) do
      if tempo_marker_is_removed(plan, marker) then
        plan.removed_tempo_markers = plan.removed_tempo_markers + 1
      end
    end
    plan.preflight_state_change_count = reaper.GetProjectStateChangeCount(proj)
  end
  return plan
end

local function validate_meter_result(proj, plan)
  if plan.operation == "retime_selection" then
    local numerator, denominator, bpm = reaper.TimeMap_GetTimeSigAtTime(
      proj, plan.selection_start + EPS_TIME * 10)
    if numerator ~= plan.target_numerator or
       denominator ~= plan.target_denominator or
       not approx(bpm, plan.target_bpm, EPS_BPM * 100) then
      return false, string.format(
        "The selected section is %.6f BPM %d/%d; expected %.6f BPM %d/%d.",
        bpm, numerator, denominator, plan.target_bpm,
        plan.target_numerator, plan.target_denominator)
    end
    local restore_num, restore_den, restore_bpm =
      reaper.TimeMap_GetTimeSigAtTime(
        proj, plan.selection_end + EPS_TIME * 10)
    if restore_num ~= plan.restore_numerator or
       restore_den ~= plan.restore_denominator or
       not approx(restore_bpm, plan.restore_bpm, EPS_BPM * 100) then
      return false, "The tempo/time signature after the fixed selection changed."
    end
  elseif plan.operation == "insert_measures" then
    for offset = 0, plan.count - 1 do
      local time, _, _, numerator, denominator = reaper.TimeMap_GetMeasureInfo(
        proj, plan.cursor_measure + offset)
      local expected_time = plan.cursor +
        offset * plan.duration / plan.count
      if numerator ~= plan.insert_numerator or
         denominator ~= plan.insert_denominator or
         not approx(time, expected_time, EPS_TIME * 20) then
        return false, string.format(
          "Inserted measure %d is %d/%d at %.9f s; expected %d/%d at %.9f s.",
          plan.cursor_measure + offset + 1,
          numerator, denominator, time,
          plan.insert_numerator, plan.insert_denominator, expected_time)
      end
    end
    local following_time, _, _, numerator, denominator =
      reaper.TimeMap_GetMeasureInfo(proj, plan.cursor_measure + plan.count)
    if numerator ~= plan.restore_numerator or
       denominator ~= plan.restore_denominator or
       not approx(following_time, plan.action_end, EPS_TIME * 20) then
      return false, "The meter following the inserted measures was not restored."
    end
  elseif plan.operation == "remove_measures" then
    local time, _, _, numerator, denominator =
      reaper.TimeMap_GetMeasureInfo(proj, plan.cursor_measure)
    if numerator ~= plan.restore_numerator or
       denominator ~= plan.restore_denominator or
       not approx(time, plan.cursor, EPS_TIME * 20) then
      return false, "The first remaining measure did not receive its original meter."
    end
  else
    local time, _, _, numerator, denominator =
      reaper.TimeMap_GetMeasureInfo(proj, plan.changed_measure)
    if numerator ~= plan.changed_numerator or
       denominator ~= plan.changed_denominator then
      return false, "The resized measure did not receive the requested meter."
    end
    local following_time, _, _, restore_num, restore_den =
      reaper.TimeMap_GetMeasureInfo(proj, plan.changed_measure + 1)
    local expected_following = plan.direction > 0 and plan.action_end or plan.action_start
    if restore_num ~= plan.restore_numerator or
       restore_den ~= plan.restore_denominator or
       not approx(following_time, expected_following, EPS_TIME * 20) then
      return false, "The meter following the resized measure was not restored."
    end
    if not approx(time, plan.changed_measure_start, EPS_TIME * 20) then
      return false, "The resized measure start moved unexpectedly."
    end
  end
  return true
end

local function perform_plan(proj, plan)
  if plan.operation == "retime_selection" then
    local end_splits = split_items_at_boundary(proj, plan.selection_end)
    local start_splits = split_items_at_boundary(proj, plan.selection_start)
    local tempo_splits = 0
    for _, boundary in ipairs(plan.retime_rate_boundaries or {}) do
      tempo_splits = tempo_splits + split_items_at_boundary(proj, boundary)
    end
    plan.performed_boundary_splits = end_splits + start_splits + tempo_splits
    plan.performed_tempo_splits = tempo_splits
    capture_retime_segments(proj, plan)
    apply_tempo_plan(proj, plan)
    if _G.BILDIBEAT_MTM_AFTER_NATIVE_ACTION_TEST_HOOK then
      _G.BILDIBEAT_MTM_AFTER_NATIVE_ACTION_TEST_HOOK(proj, plan)
    end
    restore_project_markers(proj, plan)
    transform_retime_segments(proj, plan)
    local collisions = detect_retime_collisions(plan)
    if collisions > 0 then
      error(string.format(
        "Retiming would create %d new same-lane item collision%s.",
        collisions, collisions == 1 and "" or "s"))
    end
    restore_automation_points(proj, plan)

    local meter_ok, meter_error = validate_meter_result(proj, plan)
    if not meter_ok then error(meter_error) end
    local marker_ok, marker_error = verify_project_markers(proj, plan)
    if not marker_ok then error(marker_error) end
    local tempo_ok, tempo_error = verify_tempo_markers(proj, plan)
    if not tempo_ok then error(tempo_error) end
    local item_ok, item_error = verify_retime_segments(proj, plan)
    if not item_ok then error(item_error) end
    local automation_ok, automation_error = verify_automation_points(proj, plan)
    if not automation_ok then error(automation_error) end

    reaper.GetSet_LoopTimeRange2(proj, true, false,
      plan.selection_start, plan.selection_end, false)
    reaper.SetEditCurPos2(proj, plan.selection_start, false, false)
    return
  end
  normalize_protected_item_boundaries(proj, plan)
  reaper.GetSet_LoopTimeRange2(
    proj, true, false, plan.action_start, plan.action_end, false)
  local action = plan.direction > 0 and INSERT_EMPTY_SPACE or
    REMOVE_TIME_MOVING_LATER
  reaper.Main_OnCommandEx(action, 0, proj)

  if _G.BILDIBEAT_MTM_AFTER_NATIVE_ACTION_TEST_HOOK then
    _G.BILDIBEAT_MTM_AFTER_NATIVE_ACTION_TEST_HOOK(proj, plan)
  end

  apply_tempo_plan(proj, plan)
  restore_project_markers(proj, plan)
  restore_protected_items(proj, plan)
  restore_automation_points(proj, plan)

  local meter_ok, meter_error = validate_meter_result(proj, plan)
  if not meter_ok then error(meter_error) end
  local marker_ok, marker_error = verify_project_markers(proj, plan)
  if not marker_ok then error(marker_error) end
  local tempo_ok, tempo_error = verify_tempo_markers(proj, plan)
  if not tempo_ok then error(tempo_error) end
  local item_ok, item_error = verify_protected_items(proj, plan)
  if not item_ok then error(item_error) end
  local automation_ok, automation_error = verify_automation_points(proj, plan)
  if not automation_ok then error(automation_error) end

  if plan.direction > 0 then
    reaper.GetSet_LoopTimeRange2(
      proj, true, false, plan.action_start, plan.action_end, false)
  else
    reaper.GetSet_LoopTimeRange2(
      proj, true, false, plan.action_start, plan.action_start, false)
  end
  reaper.SetEditCurPos2(proj, plan.action_start, false, false)
end

local function verify_rollback(proj, plan)
  local current_markers = snapshot_project_markers(proj)
  if #current_markers ~= #plan.project_markers then
    return false, string.format(
      "project marker/region count is %d instead of %d after Undo",
      #current_markers, #plan.project_markers)
  end
  local used_markers = {}
  for _, original in ipairs(plan.project_markers) do
    local marker = find_best_marker(current_markers, original, used_markers)
    if not marker or marker.id ~= original.id or marker.name ~= original.name or
       marker.color ~= original.color or
       not approx(marker.position, original.position, EPS_TIME * 10) or
       (marker.is_region and not approx(
         marker.region_end, original.region_end, EPS_TIME * 10)) then
      return false, string.format(
        "project marker/region '%s' (#%d) did not return to %.9f-%.9f after Undo%s",
        original.name ~= "" and original.name or "(unnamed)", original.id,
        original.position, original.region_end,
        marker and string.format(" (found #%d at %.9f-%.9f)",
          marker.id, marker.position, marker.region_end) or " (not found)")
    end
  end

  local _, current_tempo_chunk = snapshot_tempo_envelope_chunk(proj)
  if canonical_chunk(current_tempo_chunk) ~=
     canonical_chunk(plan.tempo_envelope_chunk) then
    return false, "the tempo envelope did not return to its preflight state"
  end

  local current_items = current_items_by_guid(proj)
  if reaper.CountMediaItems(proj) ~= #(plan.rollback_items or {}) then
    return false, "the media-item count did not return to its preflight value"
  end
  for _, original in ipairs(plan.rollback_items or {}) do
    local item = current_items[original.guid]
    if not item then
      return false, "media item " .. original.guid .. " was not restored"
    end
    local ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not ok or canonical_chunk(chunk) ~= canonical_chunk(original.chunk) then
      return false, "media item " .. original.guid ..
        " did not return to its preflight state"
    end
  end

  for _, original in ipairs(plan.automation_envelopes or {}) do
    local envelope = resolve_automation_envelope(proj, original)
    if not envelope or not reaper.ValidatePtr2(
      proj, envelope, "TrackEnvelope*") then
      return false, "an automation envelope was not restored"
    end
    local ok, chunk = reaper.GetEnvelopeStateChunk(
      envelope, "", false)
    if not ok or canonical_chunk(chunk) ~= canonical_chunk(original.chunk) then
      local label = original.name ~= "" and original.name or
        original.track_label
      return false, "automation envelope " .. label ..
        " did not return to its preflight state"
    end
  end
  return true
end

local function restore_failed_operation_ui(proj, plan)
  reaper.GetSet_LoopTimeRange2(proj, true, false,
    plan.old_time_selection_start, plan.old_time_selection_end, false)
  reaper.SetEditCurPos2(proj,
    plan.original_edit_cursor or plan.cursor, false, false)
end

local function execute_plan(proj, plan)
  local fingerprint_call_ok, fingerprint_ok = pcall(
    verify_rollback, proj, plan)
  local cursor_is_current
  if plan.operation == "retime_selection" then
    local selection_start, selection_end = reaper.GetSet_LoopTimeRange2(
      proj, false, false, 0, 0, false)
    cursor_is_current = approx(
      selection_start, plan.selection_start, EPS_TIME * 10) and
      approx(selection_end, plan.selection_end, EPS_TIME * 10)
  else
    cursor_is_current = approx(
      reaper.GetCursorPositionEx(proj), plan.cursor, EPS_TIME * 10)
  end
  if (plan.preflight_state_change_count and
      reaper.GetProjectStateChangeCount(proj) ~= plan.preflight_state_change_count) or
     not fingerprint_call_ok or not fingerprint_ok or not cursor_is_current then
    return false,
      "The project changed after preflight. Review the operation again; no changes were made.",
      "stale"
  end
  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)
  local ok, operation_error = xpcall(function()
    perform_plan(proj, plan)
  end, debug.traceback)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(proj, plan.title, -1)
  reaper.UpdateTimeline()
  reaper.UpdateArrange()
  if not ok then
    local undo_result = reaper.Undo_DoUndo2(proj)
    restore_failed_operation_ui(proj, plan)
    reaper.UpdateTimeline()
    reaper.UpdateArrange()
    if undo_result == 0 then
      return false, tostring(operation_error) ..
        "\n\nREAPER did not confirm the automatic undo. Use Undo and inspect the project before continuing.",
        "rollback_failed"
    end
    local rollback_call_ok, rollback_ok, rollback_error = pcall(
      verify_rollback, proj, plan)
    if not rollback_call_ok or not rollback_ok then
      return false, tostring(operation_error) ..
        "\n\nREAPER performed Undo, but the app could not verify complete restoration: " ..
        tostring(rollback_call_ok and rollback_error or rollback_ok),
        "rollback_failed"
    end
    return false, operation_error, "restored"
  end
  return true
end

local function confirmation_text(plan)
  if plan.operation == "retime_selection" then
    local lines = {
      plan.summary .. "?",
      "",
      string.format("Fixed selection: %.9f to %.9f seconds",
        plan.selection_start, plan.selection_end),
      string.format("Selected media pieces to retime: %d",
        plan.retime_selected_pieces or 0),
      string.format("Boundary splits to create automatically: %d",
        plan.retime_expected_splits or plan.crossing_items or 0),
      string.format("Media items wholly outside selection: %d",
        #plan.protected_items),
      string.format("Project markers/regions held at exact clock positions: %d",
        #plan.project_markers),
      string.format("Tempo/time-signature markers outside held at exact clock positions: %d",
        #plan.tempo_markers),
      string.format("Ordinary automation points held at exact clock positions: %d",
        plan.protected_automation_points or 0),
      string.format("Existing stretch markers to remap exactly: %d",
        plan.retime_existing_stretch_markers or 0),
      string.format("Native click-source takes locked to the new tempo map: %d",
        plan.retime_click_takes or 0),
      string.format("Internal step-tempo/meter markers to remap: %d",
        plan.retime_internal_tempo_markers or 0),
      string.format("Seam protection: up to %.3f ms on affected audio edges",
        plan.seam_fade_ms or 0),
      "",
      "Ordinary media inside the selection is rate-stretched; audio pitch is preserved.",
      "Native click sources follow the new tempo/meter map without changing playback rate.",
      "The right edge stays fixed and restores the original tempo/meter using a partial-measure boundary."
    }
    if plan.retime_mode == "offset" then
      lines[#lines + 1] = string.format(
        "Every tempo segment inside the selection changes by the same signed amount (%+.3f BPM); all existing time signatures are preserved.",
        plan.bpm_offset or 0)
    end
    if (plan.retime_gap_seconds or 0) > EPS_TIME then
      lines[#lines + 1] = string.format(
        "A faster tempo creates up to %.3f seconds of unused time before the fixed right edge.",
        plan.retime_gap_seconds)
    end
    if (plan.retime_trimmed_tempo_markers or 0) > 0 then
      lines[#lines + 1] = string.format(
        "%d internal tempo %s falls beyond the fixed right edge and will be removed with the trimmed portion.",
        plan.retime_trimmed_tempo_markers,
        plural(plan.retime_trimmed_tempo_markers, "marker"))
    end
    if (plan.retime_clipped_items or 0) > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format(
        "WARNING: %d slowed selected %s would extend past the locked right edge and will be trimmed there.",
        plan.retime_clipped_items,
        plural(plan.retime_clipped_items, "media piece"))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "A timestamped project backup is created before the one-step operation. Verification failure triggers automatic Undo and restoration checks."
    return table.concat(lines, "\n")
  end
  local lines = {
    plan.summary .. "?",
    "",
    string.format("Protected downstream media items: %d", #plan.protected_items),
    string.format("Protected project markers/regions: %d",
      #plan.project_markers - plan.removed_project_markers),
    string.format("Protected tempo/time-signature markers: %d",
      #plan.tempo_markers - plan.removed_tempo_markers),
    string.format("Protected ordinary automation points: %d",
      plan.protected_automation_points or 0)
  }
  if plan.direction > 0 and plan.crossing_items > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "%d %s crosses the insertion point and will be split around the new gap.",
      plan.crossing_items, plural(plan.crossing_items, "media item"))
  elseif plan.direction < 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Inside the removed span (intentional destructive scope):"
    lines[#lines + 1] = string.format("- %d overlapping %s may be trimmed or removed",
      plan.affected_items, plural(plan.affected_items, "media item"))
    lines[#lines + 1] = string.format("- %d project %s removed",
      plan.removed_project_markers,
      plural(plan.removed_project_markers, "marker/region", "markers/regions"))
    lines[#lines + 1] = string.format("- %d tempo/time-signature %s removed",
      plan.removed_tempo_markers,
      plural(plan.removed_tempo_markers, "marker"))
    lines[#lines + 1] = string.format("- %d ordinary automation %s removed",
      plan.removed_automation_points or 0,
      plural(plan.removed_automation_points or 0, "point"))
    if plan.adjusted_regions > 0 then
      lines[#lines + 1] = string.format("- %d crossing %s shortened to close the gap",
        plan.adjusted_regions, plural(plan.adjusted_regions, "region"))
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Everything after the edit moves as one musical block."
  lines[#lines + 1] = "A timestamped project backup is created before the one-step operation. Verification failure triggers automatic Undo and restoration checks."
  return table.concat(lines, "\n")
end

local function safe_filename(text)
  local cleaned = (text or ""):gsub("[<>:\"/\\|%?%*]", "_")
  cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
  return cleaned ~= "" and cleaned or "Untitled"
end

local function create_project_backup(proj)
  local active_project, project_file = reaper.EnumProjects(-1, "")
  if active_project ~= proj then
    error("The active project changed before the safety backup.")
  end
  local separator = package.config:sub(1, 1)
  local directory, filename
  if project_file and project_file ~= "" then
    directory, filename = project_file:match("^(.*)[/\\]([^/\\]+)$")
  end
  if not directory or directory == "" then
    directory = reaper.GetResourcePath() .. separator ..
      "Backups" .. separator .. "Bildibeat"
    filename = reaper.GetProjectName(proj)
  end
  -- REAPER may return 0 when the directory already exists. The saved-file
  -- open/size verification below is the authoritative success check.
  reaper.RecursiveCreateDirectory(directory, 0)
  local base = safe_filename((filename or "Untitled"):gsub("%.[Rr][Pp][Pp]$", ""))
  local timestamp = os.date("%Y%m%d-%H%M%S")
  local milliseconds = math.floor((reaper.time_precise() % 1) * 1000)
  local backup_path = directory .. separator .. base ..
    string.format(".BildibeatBackup.%s-%03d.rpp", timestamp, milliseconds)
  reaper.Main_SaveProjectEx(proj, backup_path, 0)
  local handle = io.open(backup_path, "rb")
  if not handle then error("REAPER did not create the safety backup.") end
  local size = handle:seek("end") or 0
  handle:close()
  if size <= 0 then error("The safety backup is empty.") end
  return backup_path
end

local function write_operation_report(plan, message)
  if not plan.backup_path then return nil, "No backup path was available." end
  local report_path = plan.backup_path:gsub("%.[Rr][Pp][Pp]$", ".report.txt")
  local lines = {
    APP_NAME .. " v" .. APP_VERSION,
    os.date("%Y-%m-%d %H:%M:%S"),
    "",
    plan.summary,
    message,
    "",
    "Safety backup: " .. plan.backup_path
  }
  if plan.operation == "retime_selection" then
    lines[#lines + 1] = string.format(
      "Fixed selection: %.9f to %.9f seconds",
      plan.selection_start, plan.selection_end)
    if plan.retime_mode == "offset" then
      lines[#lines + 1] = string.format(
        "Tempo adjustment: %+.6f BPM across %d segments; rate range %.9fx to %.9fx",
        plan.bpm_offset or 0, #(plan.retime_spans or {}),
        plan.retime_ratio_min, plan.retime_ratio_max)
    else
      lines[#lines + 1] = string.format(
        "Tempo: %.6f to %.6f BPM; rate %.9fx",
        plan.source_bpm, plan.target_bpm, plan.retime_ratio)
    end
    lines[#lines + 1] = string.format(
      "Selected pieces: %d; boundary splits: %d; seam fades: %d",
      plan.retime_selected_pieces or 0,
      plan.performed_boundary_splits or 0,
      plan.performed_seam_fades or 0)
    lines[#lines + 1] = string.format(
      "Existing stretch markers remapped: %d; native click-source rates preserved: %d; internal tempo markers remapped: %d",
      plan.retime_existing_stretch_markers or 0,
      plan.retime_click_takes or 0,
      plan.retime_internal_tempo_markers or 0)
    lines[#lines + 1] = string.format(
      "Theoretical fixed-window gap: %.9f seconds; trimmed pieces: %d; total trimmed overflow: %.9f seconds",
      plan.retime_gap_seconds or 0,
      plan.retime_clipped_items or 0,
      plan.retime_trimmed_seconds or 0)
    lines[#lines + 1] = string.format(
      "New same-lane collisions: %d", plan.retime_new_collisions or 0)
  end
  local handle, open_error = io.open(report_path, "w")
  if not handle then return nil, tostring(open_error) end
  handle:write(table.concat(lines, "\n"), "\n")
  handle:close()
  return report_path
end

local function run_read_only_safety_check(state)
  local proj = reaper.EnumProjects(-1, "")
  if not proj then return false, "No active REAPER project was found." end
  local ok, result = xpcall(function()
    local required = {
      "DeleteTakeStretchMarkers", "EnumPitchShiftModes",
      "GetSetTempoTimeSigMarkerFlag", "Main_SaveProjectEx",
      "SetTakeStretchMarker", "SetTakeStretchMarkerSlope"
    }
    for _, name in ipairs(required) do
      if type(reaper[name]) ~= "function" then
        error("This REAPER installation is missing the required API: " .. name)
      end
    end
    local plan = build_plan(proj, state, true)
    local unchanged, unchanged_error = verify_rollback(proj, plan)
    if not unchanged then error(unchanged_error) end
    if plan.operation == "retime_selection" then
      return string.format(
        "Safety check passed: %d selected pieces, %d boundary splits, %d existing stretch markers, %d native click-source takes, %d internal tempo markers, %.3f seconds of possible gap, and %d pieces requiring explicit trim approval.",
        plan.retime_selected_pieces or 0,
        plan.retime_expected_splits or plan.crossing_items or 0,
        plan.retime_existing_stretch_markers or 0,
        plan.retime_click_takes or 0,
        plan.retime_internal_tempo_markers or 0,
        plan.retime_gap_seconds or 0, plan.retime_clipped_items or 0)
    end
    return "Safety check passed. The project is unchanged and all protected objects were readable."
  end, debug.traceback)
  if not ok then return false, tostring(result) end
  return true, result
end

local function apply_from_ui(state)
  local proj = reaper.EnumProjects(-1, "")
  if not proj then return false, "No active REAPER project was found." end
  local ok, plan_or_error = xpcall(function()
    return build_plan(proj, state, true)
  end, debug.traceback)
  if not ok then return false, tostring(plan_or_error) end
  local plan = plan_or_error
  if reaper.ShowMessageBox(confirmation_text(plan), APP_NAME, 1) ~= 1 then
    return nil, "Cancelled."
  end
  if plan.operation == "retime_selection" and
     (plan.retime_clipped_items or 0) > 0 then
    local labels = {}
    for index = 1, math.min(#plan.retime_clipped_labels, 8) do
      labels[#labels + 1] = "- " .. plan.retime_clipped_labels[index]
    end
    if #plan.retime_clipped_labels > 8 then
      labels[#labels + 1] = string.format(
        "- ...and %d more", #plan.retime_clipped_labels - 8)
    end
    local trim_text = string.format(
      "%d slowed %s would cross the fixed right edge. Continuing will shorten those pieces by %.3f total seconds.\n\n%s\n\nContinue with this explicitly approved trim?",
      plan.retime_clipped_items,
      plural(plan.retime_clipped_items, "media piece"),
      plan.retime_trimmed_seconds or 0, table.concat(labels, "\n"))
    if reaper.ShowMessageBox(trim_text,
      APP_NAME .. " - Explicit Trim Approval", 1) ~= 1 then
      return nil, "Cancelled before any trimming or project change."
    end
  end
  local backup_ok, backup_or_error = xpcall(function()
    return create_project_backup(proj)
  end, debug.traceback)
  if not backup_ok then
    return false, "No changes were made because the safety backup failed: " ..
      tostring(backup_or_error)
  end
  plan.backup_path = backup_or_error
  plan.preflight_state_change_count = reaper.GetProjectStateChangeCount(proj)
  local success, operation_error, failure_kind = execute_plan(proj, plan)
  if not success then
    if failure_kind == "stale" then
      alert(tostring(operation_error), APP_NAME .. " - Review Again")
      return false, "Project changed after preflight; no changes made."
    elseif failure_kind == "restored" then
      alert(
        "The operation did not pass preservation checks and was automatically undone.\n" ..
        "The original markers, tempo map, items, and automation were verified after Undo.\n\n" ..
        tostring(operation_error), APP_NAME .. " - Restored")
      return false, "Verification failed; project restoration verified."
    else
      alert(
        "The operation failed and complete restoration could not be verified.\n" ..
        "Do not continue editing until you inspect the project and use Undo if needed.\n\n" ..
        tostring(operation_error), APP_NAME .. " - Check Project")
      return false, "Operation failed; inspect the project before continuing."
    end
  end
  local message
  if plan.operation == "retime_selection" then
    message = string.format(
      "%s complete. Retimed %d selected %s with ordinary audio pitch preserved, kept %d native click-source %s locked to the new tempo map, made %d verified boundary %s, remapped %d stretch %s and %d internal tempo %s, applied %d seam %s, and kept all outside markers, items, tempo points, and automation at their original clock positions.%s%s",
      plan.summary, plan.retime_selected_pieces or 0,
      plural(plan.retime_selected_pieces or 0, "media piece"),
      plan.retime_click_takes or 0,
      plural(plan.retime_click_takes or 0, "take"),
      plan.performed_boundary_splits or 0,
      plural(plan.performed_boundary_splits or 0, "split"),
      plan.retime_existing_stretch_markers or 0,
      plural(plan.retime_existing_stretch_markers or 0, "marker"),
      plan.retime_internal_tempo_markers or 0,
      plural(plan.retime_internal_tempo_markers or 0, "marker"),
      plan.performed_seam_fades or 0,
      plural(plan.performed_seam_fades or 0, "fade"),
      (plan.retime_clipped_items or 0) > 0 and string.format(
        " %d slowed %s trimmed at the locked right edge.",
        plan.retime_clipped_items,
        plural(plan.retime_clipped_items, "piece")) or "",
      (plan.retime_gap_seconds or 0) > EPS_TIME and string.format(
        " The fixed window contains up to %.3f seconds of unused time.",
        plan.retime_gap_seconds) or "")
  else
    message = string.format(
      "%s complete. Verified %d downstream %s, %d project %s, %d tempo/time-signature %s, and %d automation %s.",
      plan.summary,
      #plan.protected_items, plural(#plan.protected_items, "item"),
      #plan.project_markers - plan.removed_project_markers,
      plural(#plan.project_markers - plan.removed_project_markers,
        "marker/region", "markers/regions"),
      #plan.tempo_markers - plan.removed_tempo_markers,
      plural(#plan.tempo_markers - plan.removed_tempo_markers, "marker"),
      plan.protected_automation_points or 0,
      plural(plan.protected_automation_points or 0, "point"))
  end
  local report_path, report_error = write_operation_report(plan, message)
  if report_path then
    message = message .. " Backup and report: " ..
      plan.backup_path .. " | " .. report_path
  else
    message = message .. " Safety backup: " .. plan.backup_path ..
      ". The completion report could not be written: " .. tostring(report_error)
  end
  return true, message
end

-- Expose the engine for the integration fixture without opening the UI.
_G.BILDIBEAT_MUSICAL_TIME_MANAGER_API = {
  build_plan = build_plan,
  execute_plan = execute_plan,
  confirmation_text = confirmation_text,
  run_read_only_safety_check = run_read_only_safety_check,
  create_project_backup = create_project_backup,
  take_uses_click_source = take_uses_click_source,
  retime_take_playrate = retime_take_playrate,
  map_retime_content_time = map_retime_content_time,
  retime_ratio_at_time = retime_ratio_at_time
}
if _G.BILDIBEAT_MUSICAL_TIME_MANAGER_TEST_MODE then return end

local function enumerate_pitch_modes()
  local result = {{value = -1, name = "Project default"}}
  for mode = 0, 127 do
    local ok, mode_name = reaper.EnumPitchShiftModes(mode)
    if not ok then break end
    if mode_name and mode_name ~= "" then
      local submodes = {}
      for submode = 0, 255 do
        local submode_name = reaper.EnumPitchShiftSubModes(mode, submode)
        if not submode_name or submode_name == "" then break end
        submodes[#submodes + 1] = {
          value = (mode << 16) | submode,
          name = mode_name .. " - " .. submode_name
        }
      end
      if #submodes == 0 then
        result[#result + 1] = {value = mode << 16, name = mode_name}
      else
        for _, entry in ipairs(submodes) do result[#result + 1] = entry end
      end
    end
  end
  return result
end

local PITCH_MODES = enumerate_pitch_modes()

local function default_pitch_mode()
  for _, mode in ipairs(PITCH_MODES) do
    if mode.name:lower():find("lastique pro", 1, true) then
      return mode.value
    end
  end
  return -1
end

local function pitch_mode_name(value)
  for _, mode in ipairs(PITCH_MODES) do
    if mode.value == value then return mode.name end
  end
  return "Project default"
end

local UI = {
  operation = reaper.GetExtState(EXT_SECTION, "operation"),
  count = tonumber(reaper.GetExtState(EXT_SECTION, "count")) or 1,
  numerator = tonumber(reaper.GetExtState(EXT_SECTION, "numerator")) or 4,
  denominator = tonumber(reaper.GetExtState(EXT_SECTION, "denominator")) or 4,
  bpm = tonumber(reaper.GetExtState(EXT_SECTION, "bpm")) or 120,
  bpm_offset = tonumber(reaper.GetExtState(EXT_SECTION, "bpm_offset")) or 5,
  retime_mode = reaper.GetExtState(EXT_SECTION, "retime_mode"),
  pitch_mode = tonumber(reaper.GetExtState(EXT_SECTION, "pitch_mode")) or
    default_pitch_mode(),
  seam_fade_ms = tonumber(reaper.GetExtState(
    EXT_SECTION, "seam_fade_ms")) or DEFAULT_SEAM_FADE_MS,
  selection_signature = "",
  status = "Ready. Put the edit cursor on the bar line where the change begins.",
  status_is_error = false,
  last_mouse_down = false,
  last_right_down = false
}
if not PLAN_BUILDERS[UI.operation] then UI.operation = "insert_measures" end
do
  if UI.retime_mode ~= "offset" then UI.retime_mode = "target" end
  UI.bpm_offset = clamp(UI.bpm_offset, MIN_BPM - MAX_BPM, MAX_BPM - MIN_BPM)
  local pitch_mode_available = false
  for _, mode in ipairs(PITCH_MODES) do
    if mode.value == UI.pitch_mode then pitch_mode_available = true; break end
  end
  if not pitch_mode_available then UI.pitch_mode = default_pitch_mode() end
  UI.seam_fade_ms = clamp(UI.seam_fade_ms, 0, MAX_SEAM_FADE_MS)
end

local COLORS = {
  background = {0.035, 0.052, 0.073, 1},
  panel = {0.067, 0.095, 0.125, 1},
  panel_alt = {0.085, 0.118, 0.150, 1},
  border = {0.16, 0.23, 0.30, 1},
  text = {0.94, 0.97, 1.00, 1},
  muted = {0.62, 0.70, 0.77, 1},
  accent = {0.15, 0.56, 0.86, 1},
  accent_hover = {0.21, 0.66, 0.98, 1},
  selected = {0.10, 0.39, 0.62, 1},
  danger = {0.76, 0.24, 0.20, 1},
  danger_hover = {0.92, 0.31, 0.25, 1},
  good = {0.30, 0.78, 0.54, 1},
  warning = {0.96, 0.66, 0.25, 1}
}

local function color(name)
  local value = COLORS[name]
  gfx.set(value[1], value[2], value[3], value[4])
end

local function rect_contains(x, y, width, height)
  return gfx.mouse_x >= x and gfx.mouse_x <= x + width and
    gfx.mouse_y >= y and gfx.mouse_y <= y + height
end

local function button(x, y, width, height, label, options)
  options = options or {}
  local hovered = rect_contains(x, y, width, height)
  local disabled = options.disabled
  if disabled then color("panel")
  elseif options.danger and hovered then color("danger_hover")
  elseif options.danger then color("danger")
  elseif options.selected then color("selected")
  elseif hovered then color("accent_hover")
  else color("panel_alt") end
  gfx.rect(x, y, width, height, true)
  color("border"); gfx.rect(x, y, width, height, false)
  gfx.setfont(3, "Arial", options.font_size or 14, options.bold and 98 or 0)
  if disabled then color("muted") else color("text") end
  local tw, th = gfx.measurestr(label)
  gfx.x = x + (width - tw) / 2
  gfx.y = y + (height - th) / 2
  gfx.drawstr(label)
  local mouse_down = (gfx.mouse_cap & 1) == 1
  return not disabled and hovered and mouse_down and not UI.last_mouse_down
end

local function draw_text(text, x, y, font, color_name)
  gfx.setfont(font or 3, "Arial", font == 1 and 25 or (font == 2 and 17 or 13),
    font == 1 and 98 or 0)
  color(color_name or "text")
  gfx.x, gfx.y = x, y
  gfx.drawstr(text)
end

local function wrapped_text(text, x, y, width, line_height, color_name)
  gfx.setfont(3, "Arial", 13)
  color(color_name or "muted")
  local line = ""
  local draw_y = y
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or line .. " " .. word
    if gfx.measurestr(candidate) > width and line ~= "" then
      gfx.x, gfx.y = x, draw_y; gfx.drawstr(line)
      draw_y = draw_y + line_height
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then gfx.x, gfx.y = x, draw_y; gfx.drawstr(line) end
  return draw_y + line_height
end

local OPERATION_BUTTONS = {
  {id = "insert_measures", label = "INSERT MEASURES", detail = "Add complete bars in a chosen meter"},
  {id = "remove_measures", label = "REMOVE MEASURES", detail = "Delete complete bars and close the gap"},
  {id = "add_beats", label = "ADD BEATS", detail = "Extend the measure before the cursor"},
  {id = "remove_beats", label = "REMOVE BEATS", detail = "Shorten the measure before the cursor"},
  {id = "retime_selection", label = "RETIME SELECTED SECTION", detail = "Lock both edges; retime only selected media"}
}

local function operation_uses_meter()
  return UI.operation == "insert_measures" or
    (UI.operation == "retime_selection" and UI.retime_mode ~= "offset")
end

local function format_preview_range(text, start_time, end_time)
  return string.format("%s | %s to %s (%.3f seconds)", text,
    reaper.format_timestr_pos(start_time, "", 5),
    reaper.format_timestr_pos(end_time, "", 5),
    end_time - start_time)
end

local function preview_text(proj)
  local ok, preview_or_error = pcall(function()
    if UI.operation == "retime_selection" then
      local plan = build_retime_selection_plan(proj, UI)
      local description
      if plan.retime_mode == "offset" then
        description = string.format(
          "Fixed section: adjust every tempo by %+.3f BPM | %d tempo segments | rate range %.6fx-%.6fx | gap %.3fs | outside fixed",
          plan.bpm_offset, #(plan.retime_spans or {}),
          plan.retime_ratio_min, plan.retime_ratio_max,
          plan.retime_gap_seconds or 0)
      else
        description = string.format(
          "Fixed section: %.3f BPM %d/%d to %.3f BPM %d/%d | rate %.6fx | gap %.3fs | internal tempo points %d | outside fixed",
          plan.source_bpm, plan.source_numerator, plan.source_denominator,
          plan.target_bpm, plan.target_numerator, plan.target_denominator,
          plan.retime_ratio, plan.retime_gap_seconds or 0,
          plan.retime_internal_tempo_markers or 0)
      end
      return format_preview_range(
        description, plan.selection_start, plan.selection_end)
    end
    local cursor, cursor_measure, count = validate_common(proj, UI)
    if UI.operation == "insert_measures" then
      local _, _, bpm = effective_meter(proj, cursor, true)
      local duration = count * UI.numerator * 4 / UI.denominator * 60 / bpm
      return format_preview_range(string.format(
        "Insert %d %s of %d/%d before bar %s (new bars %s-%s)",
        count, plural(count, "measure"), UI.numerator, UI.denominator,
        measure_label(cursor_measure), measure_label(cursor_measure),
        measure_label(cursor_measure + count - 1)), cursor, cursor + duration)
    elseif UI.operation == "remove_measures" then
      local end_time = reaper.TimeMap_GetMeasureInfo(
        proj, cursor_measure + count)
      return format_preview_range(string.format(
        "Remove %d %s (bars %s-%s)", count,
        plural(count, "measure"), measure_label(cursor_measure),
        measure_label(cursor_measure + count - 1)), cursor, end_time)
    end
    if cursor_measure <= 0 then
      error("There is no preceding measure at this bar line.")
    end
    local target_measure = cursor_measure - 1
    local _, _, qn_end, numerator, denominator =
      reaper.TimeMap_GetMeasureInfo(proj, target_measure)
    if UI.operation == "add_beats" then
      if numerator + count > MAX_NUMERATOR then
        error("The requested numerator exceeds the 64-beat safety limit.")
      end
      local _, _, end_bpm = effective_meter(proj, cursor, false)
      local duration = count * 4 / denominator * 60 / end_bpm
      return format_preview_range(string.format(
        "Add %d %s to bar %s (%d/%d to %d/%d)",
        count, plural(count, "beat"), measure_label(target_measure),
        numerator, denominator, numerator + count, denominator),
        cursor, cursor + duration)
    end
    if count >= numerator then
      error(string.format("Remove at most %d; the measure must retain one beat.",
        numerator - 1))
    end
    local cut_qn = qn_end - count * 4 / denominator
    local cut_start = reaper.TimeMap2_QNToTime(proj, cut_qn)
    return format_preview_range(string.format(
      "Remove %d %s from bar %s (%d/%d to %d/%d)",
      count, plural(count, "beat"), measure_label(target_measure),
      numerator, denominator, numerator - count, denominator),
      cut_start, cursor)
  end)
  if ok then return preview_or_error, false end
  local message = tostring(preview_or_error):gsub("^.-:%d+:%s*", "")
  return message, true
end

local function prompt_integer(caption, current, minimum, maximum)
  local ok, text = reaper.GetUserInputs(APP_NAME, 1, caption .. ":", tostring(current))
  if not ok then return current end
  local value = tonumber(text)
  if not value or value ~= math.floor(value) then
    UI.status = caption .. " must be a whole number."
    UI.status_is_error = true
    return current
  end
  return clamp(value, minimum, maximum)
end

local function prompt_number(caption, current, minimum, maximum)
  local ok, text = reaper.GetUserInputs(APP_NAME, 1, caption .. ":", tostring(current))
  if not ok then return current end
  local value = tonumber(text)
  if not value then
    UI.status = caption .. " must be a number."
    UI.status_is_error = true
    return current
  end
  return clamp(value, minimum, maximum)
end

local function sync_retime_controls(proj)
  if not proj then return end
  local selection_start, selection_end = reaper.GetSet_LoopTimeRange2(
    proj, false, false, 0, 0, false)
  local signature = string.format("%.12f|%.12f", selection_start, selection_end)
  if signature == UI.selection_signature then return end
  UI.selection_signature = signature
  if selection_end > selection_start + EPS_TIME then
    local start_time = barline_at_time(proj, selection_start)
    local end_time = barline_at_time(proj, selection_end)
    if start_time and end_time then
      local numerator, denominator, bpm = effective_meter(
        proj, selection_start, true)
      UI.numerator, UI.denominator, UI.bpm = numerator, denominator, bpm
    end
  end
end

local function snap_selection_to_bars(proj)
  local selection_start, selection_end = reaper.GetSet_LoopTimeRange2(
    proj, false, false, 0, 0, false)
  if selection_end <= selection_start + EPS_TIME then
    return false, "Create a non-empty time selection before snapping it."
  end
  local start_measure, snapped_start = nearest_bar_info(proj, selection_start)
  local end_measure, snapped_end = nearest_bar_info(proj, selection_end)
  if end_measure <= start_measure or snapped_end <= snapped_start + EPS_TIME then
    end_measure = start_measure + 1
    snapped_end = reaper.TimeMap_GetMeasureInfo(proj, end_measure)
  end
  reaper.GetSet_LoopTimeRange2(
    proj, true, false, snapped_start, snapped_end, false)
  reaper.UpdateTimeline()
  return true, string.format(
    "Selection snapped to bars %s-%s (%s to %s).",
    measure_label(start_measure), measure_label(end_measure - 1),
    reaper.format_timestr_pos(snapped_start, "", 5),
    reaper.format_timestr_pos(snapped_end, "", 5))
end

local function choose_pitch_mode(current)
  local menu = {}
  for index, mode in ipairs(PITCH_MODES) do
    local name = mode.name:gsub("[|#!<>]", " ")
    if mode.value == current then
      name = "!" .. name
    end
    menu[#menu + 1] = name
  end
  local choice = gfx.showmenu(table.concat(menu, "|"))
  if choice > 0 and PITCH_MODES[choice] then
    return PITCH_MODES[choice].value
  end
  return current
end

local function save_ui_state()
  reaper.SetExtState(EXT_SECTION, "operation", UI.operation, true)
  reaper.SetExtState(EXT_SECTION, "count", tostring(UI.count), true)
  reaper.SetExtState(EXT_SECTION, "numerator", tostring(UI.numerator), true)
  reaper.SetExtState(EXT_SECTION, "denominator", tostring(UI.denominator), true)
  reaper.SetExtState(EXT_SECTION, "bpm", tostring(UI.bpm), true)
  reaper.SetExtState(EXT_SECTION, "bpm_offset", tostring(UI.bpm_offset), true)
  reaper.SetExtState(EXT_SECTION, "retime_mode", UI.retime_mode, true)
  reaper.SetExtState(EXT_SECTION, "pitch_mode", tostring(UI.pitch_mode), true)
  reaper.SetExtState(EXT_SECTION, "seam_fade_ms",
    tostring(UI.seam_fade_ms), true)
  local dock, x, y, width, height = gfx.dock(-1, 0, 0, 0, 0)
  reaper.SetExtState(EXT_SECTION, "window",
    table.concat({dock, x, y, width, height}, ","), true)
end

local function close_ui()
  gfx.quit()
end

local function draw_ui()
  local width = math.max(gfx.w, 760)
  local height = math.max(gfx.h, 900)
  color("background"); gfx.rect(0, 0, width, height, true)
  local margin = 24

  draw_text("Bildibeat Musical Time Manager", margin, 18, 1, "text")
  draw_text("Insert, remove, or locally retime musical sections safely",
    margin, 51, 3, "muted")

  local gap = 10
  local operation_width = (width - margin * 2 - gap) / 2
  for index, operation in ipairs(OPERATION_BUTTONS) do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local x = margin + column * (operation_width + gap)
    local y = 82 + row * 64
    if button(x, y, operation_width, 50, operation.label, {
      selected = UI.operation == operation.id,
      bold = true,
      font_size = 14
    }) then
      UI.operation = operation.id
      if operation.id == "retime_selection" then UI.selection_signature = "" end
      UI.status = operation.detail
      UI.status_is_error = false
    end
    draw_text(operation.detail, x + 8, y + 52, 3, "muted")
  end

  local panel_y = 290
  color("panel"); gfx.rect(margin, panel_y, width - margin * 2, 126, true)
  color("border"); gfx.rect(margin, panel_y, width - margin * 2, 126, false)
  draw_text("LOCATION", margin + 16, panel_y + 13, 3, "muted")

  local proj = reaper.EnumProjects(-1, "")
  local cursor_text = "No active project"
  local on_barline = false
  if proj then
    if UI.operation == "retime_selection" then
      sync_retime_controls(proj)
      local selection_start, selection_end = reaper.GetSet_LoopTimeRange2(
        proj, false, false, 0, 0, false)
      local left, left_measure = barline_at_time(proj, selection_start)
      local right, right_measure = barline_at_time(proj, selection_end)
      on_barline = selection_end > selection_start + EPS_TIME and
        left ~= nil and right ~= nil and right_measure > left_measure
      cursor_text = on_barline and string.format(
        "Selection: %s to %s   |   Bars %s-%s",
        reaper.format_timestr_pos(selection_start, "", 5),
        reaper.format_timestr_pos(selection_end, "", 5),
        measure_label(left_measure), measure_label(right_measure - 1)) or
        "Create a non-empty time selection with both edges on bar lines."
    else
      local cursor = reaper.GetCursorPositionEx(proj)
      local bar_cursor, measure = barline_at_cursor(proj)
      local numerator, denominator = reaper.TimeMap_GetTimeSigAtTime(proj, cursor)
      cursor_text = string.format("Edit cursor: %s   |   Bar %s   |   Meter %d/%d",
        reaper.format_timestr_pos(cursor, "", 5), measure_label(measure),
        numerator, denominator)
      on_barline = bar_cursor ~= nil
    end
  end
  draw_text(cursor_text, margin + 16, panel_y + 40, 2,
    on_barline and "text" or "warning")
  draw_text(on_barline and (UI.operation == "retime_selection" and
      "Ready: the selected section is locked to exact bar-line boundaries." or
      "Ready: cursor is exactly on a bar line.")
    or (UI.operation == "retime_selection" and
      "Snap both time-selection edges to bar lines before applying." or
      "Cursor is between bar lines. Snap it before applying."),
    margin + 16, panel_y + 73, 3,
    on_barline and "good" or "warning")
  if button(width - margin - 226, panel_y + 72, 210, 34,
    UI.operation == "retime_selection" and "SNAP SELECTION TO BARS" or
      "SNAP TO NEAREST BAR",
    {disabled = not proj, font_size = 12}) and proj then
    if UI.operation == "retime_selection" then
      local snapped, snap_message = snap_selection_to_bars(proj)
      UI.selection_signature = ""
      UI.status = snap_message
      UI.status_is_error = not snapped
    else
      local _, nearest = nearest_bar_info(proj, reaper.GetCursorPositionEx(proj))
      reaper.SetEditCurPos2(proj, nearest, true, false)
      UI.status = "Edit cursor snapped to the nearest bar line."
      UI.status_is_error = false
    end
  end

  local controls_y = 435
  local retime_offset = UI.operation == "retime_selection" and
    UI.retime_mode == "offset"
  if UI.operation == "retime_selection" then
    if button(margin, controls_y - 2, 94, 22, "SET START BPM", {
      selected = not retime_offset, font_size = 10, bold = true}) then
      UI.retime_mode = "target"
      UI.status = "Set the selected section's starting BPM; internal tempos scale proportionally."
      UI.status_is_error = false
    end
    if button(margin + 102, controls_y - 2, 98, 22, "ADJUST ALL", {
      selected = retime_offset, font_size = 10, bold = true}) then
      UI.retime_mode = "offset"
      UI.status = "Add or subtract the same BPM amount from every tempo marker in the selection."
      UI.status_is_error = false
    end
  else
    draw_text(UI.operation:find("measures") and "MEASURE COUNT" or "BEAT COUNT",
      margin, controls_y, 3, "muted")
  end
  if button(margin, controls_y + 25, 44, 40, "-", {
    disabled = UI.operation == "retime_selection" and not retime_offset and
        UI.bpm <= MIN_BPM or
      retime_offset and UI.bpm_offset <= MIN_BPM - MAX_BPM or
      UI.operation ~= "retime_selection" and UI.count <= 1,
    font_size = 20, bold = true}) then
    if UI.operation == "retime_selection" then
      if retime_offset then
        UI.bpm_offset = math.max(MIN_BPM - MAX_BPM, UI.bpm_offset - 1)
      else
        UI.bpm = math.max(MIN_BPM, UI.bpm - 1)
      end
    else UI.count = math.max(1, UI.count - 1) end
  end
  local primary_value
  if retime_offset then
    primary_value = string.format("%+.3f", UI.bpm_offset):gsub("0+$", ""):gsub("%.$", "")
  elseif UI.operation == "retime_selection" then
    primary_value = string.format("%.3f", UI.bpm):gsub("0+$", ""):gsub("%.$", "")
  else
    primary_value = tostring(UI.count)
  end
  if button(margin + 52, controls_y + 25, 96, 40, primary_value, {
    font_size = 17, bold = true}) then
    if UI.operation == "retime_selection" then
      if retime_offset then
        UI.bpm_offset = prompt_number("Tempo adjustment (BPM)", UI.bpm_offset,
          MIN_BPM - MAX_BPM, MAX_BPM - MIN_BPM)
      else
        UI.bpm = prompt_number("Target tempo (BPM)", UI.bpm, MIN_BPM, MAX_BPM)
      end
    else
      UI.count = prompt_integer(
        UI.operation:find("measures") and "Measure count" or "Beat count",
        UI.count, 1, MAX_COUNT)
    end
  end
  if button(margin + 156, controls_y + 25, 44, 40, "+", {
    disabled = UI.operation == "retime_selection" and not retime_offset and
        UI.bpm >= MAX_BPM or
      retime_offset and UI.bpm_offset >= MAX_BPM - MIN_BPM or
      UI.operation ~= "retime_selection" and UI.count >= MAX_COUNT,
    font_size = 20, bold = true}) then
    if UI.operation == "retime_selection" then
      if retime_offset then
        UI.bpm_offset = math.min(MAX_BPM - MIN_BPM, UI.bpm_offset + 1)
      else
        UI.bpm = math.min(MAX_BPM, UI.bpm + 1)
      end
    else UI.count = math.min(MAX_COUNT, UI.count + 1) end
  end

  local meter_x = margin + 242
  draw_text(retime_offset and "TIME SIGNATURES PRESERVED" or
    (UI.operation == "retime_selection" and "TARGET TIME SIGNATURE" or
      "INSERTED TIME SIGNATURE"), meter_x, controls_y, 3,
    operation_uses_meter() and "muted" or "border")
  local meter_disabled = not operation_uses_meter()
  if button(meter_x, controls_y + 25, 40, 40, "-", {
    disabled = meter_disabled or UI.numerator <= 1, font_size = 20}) then
    UI.numerator = math.max(1, UI.numerator - 1)
  end
  if button(meter_x + 48, controls_y + 25, 66, 40,
    tostring(UI.numerator), {
      disabled = meter_disabled, font_size = 17, bold = true}) then
    UI.numerator = prompt_integer(
      "Time-signature numerator", UI.numerator, 1, MAX_NUMERATOR)
  end
  if button(meter_x + 122, controls_y + 25, 40, 40, "+", {
    disabled = meter_disabled or UI.numerator >= MAX_NUMERATOR,
    font_size = 20}) then
    UI.numerator = math.min(MAX_NUMERATOR, UI.numerator + 1)
  end
  draw_text("/", meter_x + 174, controls_y + 34, 2,
    meter_disabled and "muted" or "text")
  local denom_x = meter_x + 198
  for index, denominator in ipairs(DENOMINATORS) do
    if button(denom_x + (index - 1) * 48, controls_y + 25, 42, 40,
      tostring(denominator), {
        disabled = meter_disabled,
        selected = not meter_disabled and UI.denominator == denominator,
        font_size = 13,
        bold = UI.denominator == denominator
      }) then
      UI.denominator = denominator
    end
  end

  local presets_y = controls_y + 81
  draw_text("METER PRESETS", margin, presets_y + 9, 3,
    meter_disabled and "border" or "muted")
  local preset_x = margin + 120
  for index, meter in ipairs(COMMON_METERS) do
    local label = string.format("%d/%d", meter[1], meter[2])
    if button(preset_x + (index - 1) * 72, presets_y, 64, 34, label, {
      disabled = meter_disabled,
      selected = not meter_disabled and UI.numerator == meter[1] and
        UI.denominator == meter[2],
      font_size = 13,
      bold = UI.numerator == meter[1] and UI.denominator == meter[2]
    }) then
      UI.numerator, UI.denominator = meter[1], meter[2]
    end
  end
  draw_text("Click a number to type it directly.", width - margin - 236,
    presets_y + 9, 3, "muted")

  local quality_y = 566
  draw_text("STRETCH QUALITY", margin, quality_y + 10, 3,
    UI.operation == "retime_selection" and "muted" or "border")
  if button(margin + 130, quality_y, 360, 38,
    pitch_mode_name(UI.pitch_mode), {
      disabled = UI.operation ~= "retime_selection",
      font_size = 12}) then
    UI.pitch_mode = choose_pitch_mode(UI.pitch_mode)
  end
  local fade_x = width - margin - 196
  draw_text("SEAM FADE", fade_x, quality_y - 18, 3,
    UI.operation == "retime_selection" and "muted" or "border")
  if button(fade_x, quality_y, 38, 38, "-", {
    disabled = UI.operation ~= "retime_selection" or UI.seam_fade_ms <= 0,
    font_size = 18}) then
    UI.seam_fade_ms = math.max(0, UI.seam_fade_ms - 0.5)
  end
  if button(fade_x + 44, quality_y, 104, 38,
    string.format("%.1f ms", UI.seam_fade_ms), {
      disabled = UI.operation ~= "retime_selection", font_size = 12}) then
    UI.seam_fade_ms = prompt_number(
      "Seam fade (milliseconds)", UI.seam_fade_ms, 0, MAX_SEAM_FADE_MS)
  end
  if button(fade_x + 154, quality_y, 38, 38, "+", {
    disabled = UI.operation ~= "retime_selection" or
      UI.seam_fade_ms >= MAX_SEAM_FADE_MS,
    font_size = 18}) then
    UI.seam_fade_ms = math.min(MAX_SEAM_FADE_MS, UI.seam_fade_ms + 0.5)
  end

  local safety_y = 618
  if button(margin, safety_y, width - margin * 2, 38,
    "RUN READ-ONLY SAFETY CHECK", {
      disabled = not proj or not on_barline,
      font_size = 13, bold = true}) then
    UI.status = "Running a read-only project safety check..."
    UI.status_is_error = false
    gfx.update()
    local safety_ok, safety_message = run_read_only_safety_check(UI)
    UI.status = safety_message
    UI.status_is_error = not safety_ok
  end

  local preview_y = 673
  color("panel"); gfx.rect(margin, preview_y, width - margin * 2, 105, true)
  color("border"); gfx.rect(margin, preview_y, width - margin * 2, 105, false)
  draw_text("PREVIEW", margin + 16, preview_y + 11, 3, "muted")
  local preview, preview_error
  if proj then
    preview, preview_error = preview_text(proj)
  else
    preview, preview_error = "No active REAPER project was found.", true
  end
  wrapped_text(preview, margin + 16, preview_y + 35, width - margin * 2 - 32,
    18, preview_error and "warning" or "text")

  local apply_y = 795
  local apply_label = UI.operation == "retime_selection" and
    "REVIEW SELECTED-SECTION CHANGE" or
    (UI.operation:find("remove") and "REVIEW REMOVAL" or "REVIEW INSERTION")
  if button(margin, apply_y, width - margin * 2, 48, apply_label, {
    disabled = not proj or not on_barline,
    danger = UI.operation:find("remove") ~= nil,
    selected = UI.operation:find("remove") == nil,
    font_size = 16,
    bold = true
  }) then
    UI.status = "Running preflight checks..."
    UI.status_is_error = false
    gfx.update()
    local success, message = apply_from_ui(UI)
    UI.status = message or "Ready."
    UI.status_is_error = success == false
  end

  local status_y = math.max(apply_y + 62, height - 48)
  wrapped_text(UI.status, margin, status_y, width - margin * 2, 17,
    UI.status_is_error and "warning" or "muted")
  draw_text("v" .. APP_VERSION .. "   |   Right-click to dock/undock",
    width - 235, height - 20, 3, "border")

  gfx.update()
end

local function ui_loop()
  local character = gfx.getchar()
  if character < 0 or character == 27 then close_ui(); return end

  local right_down = (gfx.mouse_cap & 2) == 2
  if right_down and not UI.last_right_down then
    local docked = gfx.dock(-1) > 0
    local choice = gfx.showmenu(docked and "Undock window" or "Dock window")
    if choice == 1 then gfx.dock(docked and 0 or 1) end
  end
  UI.last_right_down = right_down

  draw_ui()
  UI.last_mouse_down = (gfx.mouse_cap & 1) == 1
  reaper.defer(ui_loop)
end

local initial_dock, initial_x, initial_y, initial_w, initial_h =
  reaper.GetExtState(EXT_SECTION, "window"):match(
    "^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
initial_dock = tonumber(initial_dock) or 0
initial_x = tonumber(initial_x) or 100
initial_y = tonumber(initial_y) or 100
initial_w = math.max(tonumber(initial_w) or 760, 760)
initial_h = math.max(tonumber(initial_h) or 900, 900)

gfx.init(APP_NAME, initial_w, initial_h, initial_dock, initial_x, initial_y)
reaper.atexit(save_ui_state)
ui_loop()
