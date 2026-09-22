-- Bildibeat Show Track App v4.2
-- Self-contained REAPER app. Load this one Lua file only.

local function create_common()
-- Shared utilities for Bildibeat Show Track App v3.9.
local M = {}
local MASK = 0xffffffff
local EPS = 1e-20
local RATE = 48000
local BLOCK = 4096
local CHUNK_SAMPLES = 4800

function M.trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

function M.clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

function M.amp_to_db(value)
  if not value or value <= EPS then return -math.huge end
  return 20 * math.log(value, 10)
end

function M.split_path(path)
  local directory, filename = tostring(path or ""):match("^(.*[\\/])([^\\/]+)$")
  if not directory then return "", tostring(path or "") end
  return directory:gsub("[\\/]$", ""), filename
end

function M.join_path(left, right)
  local separator = package.config:sub(1, 1)
  if tostring(left):sub(-1) == "/" or tostring(left):sub(-1) == "\\" then return left .. right end
  return left .. separator .. right
end

function M.file_exists(path)
  local handle = io.open(path, "rb")
  if handle then handle:close(); return true end
  return false
end

-- ReaScript exposes the metronome pattern, but not the project's A/B sample
-- paths or relative A/B volume. Export a read-only copy of the current *live*
-- project so unsaved metronome edits are included. Option 0 deliberately does
-- not change the open project's filename (option 8 would).
function M.parse_project_metronome(text, exported_directory, project_directory)
  local in_block, samples, volume_a, volume_b = false, nil, nil, nil
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line:match("^%s*<METRONOME[%s>]" ) then
      in_block = true
    elseif in_block and line:match("^%s*>%s*$") then
      break
    elseif in_block then
      if line:match("^%s*SAMPLES%s") then
        samples = {}
        for path in line:gmatch('"([^\"]*)"') do samples[#samples + 1] = path end
      elseif line:match("^%s*VOL%s") then
        volume_a, volume_b = line:match("^%s*VOL%s+([%d%.eE%+%-]+)%s+([%d%.eE%+%-]+)")
      end
    end
  end
  if not samples or not samples[1] or samples[1] == "" or not samples[2] or samples[2] == "" then
    return nil, "Set both A and B to audio sample files in this project's Metronome and pre-roll settings, then run Build again."
  end
  if (tonumber(volume_a) or 0) <= 0 or (tonumber(volume_b) or 0) <= 0 then
    return nil, "Set the project metronome A and B volumes above silence so existing CLICK hits remain audible."
  end
  local function resolve(path)
    if path:match("^%a:[\\/]") or path:match("^[/\\][/\\]") or path:sub(1, 1) == "/" then return path end
    for _, directory in ipairs({exported_directory or "", project_directory or ""}) do
      if directory ~= "" then
        local candidate = M.join_path(directory, path)
        if M.file_exists(candidate) then return candidate end
      end
    end
    return path
  end
  return {a = resolve(samples[1]), b = resolve(samples[2]),
    volume_a = tonumber(volume_a) or 1, volume_b = tonumber(volume_b) or 1}, nil
end

function M.read_project_metronome(project)
  if not reaper.Main_SaveProjectEx or not reaper.GetResourcePath then
    return nil, "This REAPER version cannot read the current project's metronome samples."
  end
  local directory = M.join_path(reaper.GetResourcePath(), "Media")
  directory = M.join_path(directory, "Bildibeat")
  directory = M.join_path(directory, "MetronomeSnapshots")
  reaper.RecursiveCreateDirectory(directory, 0)
  local token = tostring(math.floor((reaper.time_precise and reaper.time_precise() or os.clock()) * 1000000))
  local path = M.join_path(directory, "metronome_" .. token .. ".rpp")
  if M.file_exists(path) then return nil, "Could not reserve a metronome snapshot filename." end
  local _, project_path = reaper.EnumProjects(-1, "")
  local project_directory = M.split_path(project_path)
  local ok, save_error = pcall(reaper.Main_SaveProjectEx, project, path, 0)
  if not ok or not M.file_exists(path) then
    os.remove(path)
    return nil, "Could not inspect the current project's metronome settings: " .. tostring(save_error)
  end
  local handle, open_error = io.open(path, "rb")
  if not handle then os.remove(path); return nil, "Could not read the metronome snapshot: " .. tostring(open_error) end
  local data = handle:read("*a")
  handle:close()
  os.remove(path)
  return M.parse_project_metronome(data, directory, project_directory)
end

-- CLICK ALT and ALT CLICK are interchangeable marker spellings. Keep CLICK ALT
-- as the stored slot key so existing sample assignments remain compatible.
-- Only complete documented labels are accepted; ordinary song markers cannot
-- change the rendered sample accidentally.
function M.normalize_click_alt_marker_name(value)
  local name = M.trim(value):gsub("%s+", " "):upper()
  if name == "CLICK ALT" or name:match("^CLICK ALT [1-9]%d*$") then return name end
  if name == "ALT CLICK" then return "CLICK ALT" end
  local number = name:match("^ALT CLICK ([1-9]%d*)$")
  if number then return "CLICK ALT " .. number end
  return nil
end

local function hex_encode(value)
  return (tostring(value or ""):gsub(".", function(character)
    return string.format("%02X", string.byte(character))
  end))
end

local function hex_decode(value)
  value = tostring(value or "")
  if #value % 2 ~= 0 or value:find("[^0-9A-Fa-f]") then return nil end
  return (value:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

function M.decode_click_alt_sample_paths(stored)
  local result = {}
  for line in (tostring(stored or "") .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" then
      local encoded_label, encoded_path = line:match("^([0-9A-Fa-f]+)=([0-9A-Fa-f]*)$")
      local label, path = hex_decode(encoded_label), hex_decode(encoded_path)
      label = M.normalize_click_alt_marker_name(label)
      if label and path and path ~= "" then result[label] = path end
    end
  end
  return result
end

function M.encode_click_alt_sample_paths(paths)
  local labels, lines, normalized_paths = {}, {}, {}
  for label, path in pairs(paths or {}) do
    local normalized = M.normalize_click_alt_marker_name(label)
    if normalized and M.trim(path) ~= "" and (not normalized_paths[normalized] or label == normalized) then
      normalized_paths[normalized] = path
    end
  end
  for label in pairs(normalized_paths) do labels[#labels + 1] = label end
  table.sort(labels, function(left, right)
    local left_number = tonumber(left:match("(%d+)$")) or 0
    local right_number = tonumber(right:match("(%d+)$")) or 0
    if left_number ~= right_number then return left_number < right_number end
    return left < right
  end)
  for _, label in ipairs(labels) do
    lines[#lines + 1] = hex_encode(label) .. "=" .. hex_encode(normalized_paths[label])
  end
  return table.concat(lines, "\n")
end

function M.read_click_alt_sample_paths(section, key)
  return M.decode_click_alt_sample_paths(reaper.GetExtState(section, key))
end

function M.write_click_alt_sample_paths(section, key, paths)
  reaper.SetExtState(section, key, M.encode_click_alt_sample_paths(paths), true)
end

function M.collect_click_alt_markers(project)
  local markers = {}
  if type(reaper.CountProjectMarkers) ~= "function" or type(reaper.EnumProjectMarkers3) ~= "function" then
    return markers
  end
  local total = select(1, reaper.CountProjectMarkers(project)) or 0
  for index = 0, total - 1 do
    local ok, is_region, position, _, name, marker_index = reaper.EnumProjectMarkers3(project, index)
    local label = ok and not is_region and M.normalize_click_alt_marker_name(name) or nil
    if label then
      markers[#markers + 1] = {
        label = label,
        position = tonumber(position) or 0,
        marker_index = marker_index,
      }
    end
  end
  table.sort(markers, function(left, right)
    if math.abs(left.position - right.position) > 1e-9 then return left.position < right.position end
    if left.label ~= right.label then return left.label < right.label end
    return (left.marker_index or 0) < (right.marker_index or 0)
  end)
  return markers
end

function M.read_text(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local value = handle:read("*a")
  handle:close()
  return value
end

function M.write_text(path, value)
  local handle, message = io.open(path, "wb")
  if not handle then return false, message end
  handle:write(value)
  handle:close()
  return true
end

local SHA_K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function ror(value, amount)
  return ((value >> amount) | ((value << (32 - amount)) & MASK)) & MASK
end

local function sha_compress(state, block)
  local words = {}
  for index = 1, 16 do
    local offset = (index - 1) * 4 + 1
    local a, b, c, d = block:byte(offset, offset + 3)
    words[index] = (((a << 24) | (b << 16) | (c << 8) | d) & MASK)
  end
  for index = 17, 64 do
    local x = words[index - 15]
    local y = words[index - 2]
    local s0 = (ror(x, 7) ~ ror(x, 18) ~ (x >> 3)) & MASK
    local s1 = (ror(y, 17) ~ ror(y, 19) ~ (y >> 10)) & MASK
    words[index] = (words[index - 16] + s0 + words[index - 7] + s1) & MASK
  end
  local a, b, c, d, e, f, g, h = table.unpack(state)
  for index = 1, 64 do
    local big1 = (ror(e, 6) ~ ror(e, 11) ~ ror(e, 25)) & MASK
    local choice = ((e & f) ~ ((~e) & g)) & MASK
    local temp1 = (h + big1 + choice + SHA_K[index] + words[index]) & MASK
    local big0 = (ror(a, 2) ~ ror(a, 13) ~ ror(a, 22)) & MASK
    local majority = ((a & b) ~ (a & c) ~ (b & c)) & MASK
    local temp2 = (big0 + majority) & MASK
    h, g, f, e, d, c, b, a = g, f, e, (d + temp1) & MASK, c, b, a, (temp1 + temp2) & MASK
  end
  state[1] = (state[1] + a) & MASK
  state[2] = (state[2] + b) & MASK
  state[3] = (state[3] + c) & MASK
  state[4] = (state[4] + d) & MASK
  state[5] = (state[5] + e) & MASK
  state[6] = (state[6] + f) & MASK
  state[7] = (state[7] + g) & MASK
  state[8] = (state[8] + h) & MASK
end

local function sha256_reader(reader)
  local state = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
  local carry, total = "", 0
  while true do
    local chunk = reader()
    if not chunk then break end
    total = total + #chunk
    local data = carry .. chunk
    local complete = #data - (#data % 64)
    for offset = 1, complete, 64 do sha_compress(state, data:sub(offset, offset + 63)) end
    carry = data:sub(complete + 1)
  end
  local zero_count = (56 - ((#carry + 1) % 64)) % 64
  local tail = carry .. string.char(0x80) .. string.rep(string.char(0), zero_count) .. string.pack(">I8", total * 8)
  for offset = 1, #tail, 64 do sha_compress(state, tail:sub(offset, offset + 63)) end
  local parts = {}
  for index = 1, 8 do parts[index] = string.format("%08x", state[index] & MASK) end
  return table.concat(parts)
end

function M.sha256_string(value)
  local sent = false
  return sha256_reader(function()
    if sent then return nil end
    sent = true
    return tostring(value or "")
  end)
end

function M.sha256_file(path)
  local handle, message = io.open(path, "rb")
  if not handle then return nil, message end
  local hash = sha256_reader(function() return handle:read(1024 * 1024) end)
  handle:close()
  return hash
end

function M.profile_id(profile_string, processing_version)
  return "BSP-" .. M.sha256_string("Bildibeat|" .. tostring(processing_version or "") .. "|" .. tostring(profile_string or "")):sub(1, 12):upper()
end

local function percentile(values, fraction)
  if #values == 0 then return nil end
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  table.sort(copy)
  local position = 1 + (#copy - 1) * fraction
  local lower, upper = math.floor(position), math.ceil(position)
  if lower == upper then return copy[lower] end
  return copy[lower] * (upper - position) + copy[upper] * (position - lower)
end

function M.median(values)
  return percentile(values, 0.5)
end

local function loudness_from_chunks(chunks)
  local energies, loudness = {}, {}
  for index = 4, #chunks do
    local energy = (chunks[index] + chunks[index - 1] + chunks[index - 2] + chunks[index - 3]) / 4
    energies[#energies + 1] = energy
    loudness[#loudness + 1] = energy > EPS and (-0.691 + 10 * math.log(energy, 10)) or -math.huge
  end
  local absolute, sum = {}, 0
  for index, value in ipairs(loudness) do
    if value >= -70 then absolute[#absolute + 1] = index; sum = sum + energies[index] end
  end
  if #absolute == 0 then return -math.huge, 0 end
  local gate = math.max(-70, -0.691 + 10 * math.log(math.max(sum / #absolute, EPS), 10) - 10)
  local gated, gated_sum = {}, 0
  for index, value in ipairs(loudness) do
    if value >= gate then gated[#gated + 1] = energies[index]; gated_sum = gated_sum + energies[index] end
  end
  if #gated == 0 then return -math.huge, 0 end
  local integrated = -0.691 + 10 * math.log(math.max(gated_sum / #gated, EPS), 10)
  local short = {}
  if #chunks >= 30 then
    for index = 30, #chunks, 10 do
      local energy = 0
      for offset = 0, 29 do energy = energy + chunks[index - offset] end
      local value = -0.691 + 10 * math.log(math.max(energy / 30, EPS), 10)
      if value >= integrated - 10 then short[#short + 1] = value end
    end
  end
  local range = #short >= 2 and ((percentile(short, 0.9) or 0) - (percentile(short, 0.1) or 0)) or 0
  return integrated, range
end

local function new_channel_state()
  return {
    count = 0, sum = 0, sum_sq = 0, peak = 0, true_peak = 0, clipped = 0,
    chunks = {}, chunk_sum = 0, chunk_count = 0,
    x1a = 0, x2a = 0, y1a = 0, y2a = 0, x1b = 0, x2b = 0, y1b = 0, y2b = 0,
    lp_low = 0, lp_high = 0, lp_infra = 0, low_sq = 0, mid_sq = 0, high_sq = 0, infra_sq = 0,
    p0 = nil, p1 = nil, p2 = nil, start_peak = 0, end_peak = 0,
  }
end

local function cubic(p0, p1, p2, p3, fraction)
  local f2, f3 = fraction * fraction, fraction * fraction * fraction
  return 0.5 * ((2 * p1) + (-p0 + p2) * fraction + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f2 +
    (-p0 + 3 * p1 - 3 * p2 + p3) * f3)
end

local function process_channel(state, value, sample_index, total_samples, coefficients)
  state.count = state.count + 1
  state.sum = state.sum + value
  state.sum_sq = state.sum_sq + value * value
  state.peak = math.max(state.peak, math.abs(value))
  state.true_peak = math.max(state.true_peak, math.abs(value))
  if math.abs(value) >= 0.999 then state.clipped = state.clipped + 1 end
  if sample_index <= RATE * 0.01 then state.start_peak = math.max(state.start_peak, math.abs(value)) end
  if sample_index > total_samples - RATE * 0.01 then state.end_peak = math.max(state.end_peak, math.abs(value)) end
  if state.p0 then
    for phase = 1, 3 do state.true_peak = math.max(state.true_peak, math.abs(cubic(state.p0, state.p1, state.p2, value, phase * 0.25))) end
  end
  state.p0, state.p1, state.p2 = state.p1, state.p2, value

  state.lp_low = coefficients.low * state.lp_low + (1 - coefficients.low) * value
  state.lp_high = coefficients.high * state.lp_high + (1 - coefficients.high) * value
  state.lp_infra = coefficients.infra * state.lp_infra + (1 - coefficients.infra) * value
  local low, mid, high = state.lp_low, state.lp_high - state.lp_low, value - state.lp_high
  state.low_sq = state.low_sq + low * low
  state.mid_sq = state.mid_sq + mid * mid
  state.high_sq = state.high_sq + high * high
  state.infra_sq = state.infra_sq + state.lp_infra * state.lp_infra

  local ya = 1.53512485958697 * value - 2.69169618940638 * state.x1a + 1.19839281085285 * state.x2a
    + 1.69065929318241 * state.y1a - 0.73248077421585 * state.y2a
  state.x2a, state.x1a, state.y2a, state.y1a = state.x1a, value, state.y1a, ya
  local yb = ya - 2 * state.x1b + state.x2b + 1.99004745483398 * state.y1b - 0.99007225036621 * state.y2b
  state.x2b, state.x1b, state.y2b, state.y1b = state.x1b, ya, state.y1b, yb
  state.chunk_sum = state.chunk_sum + yb * yb
  state.chunk_count = state.chunk_count + 1
  if state.chunk_count == CHUNK_SAMPLES then
    state.chunks[#state.chunks + 1] = state.chunk_sum / state.chunk_count
    state.chunk_sum, state.chunk_count = 0, 0
  end
end

local function finish_channel(state)
  if state.chunk_count > CHUNK_SAMPLES * 0.5 then state.chunks[#state.chunks + 1] = state.chunk_sum / state.chunk_count end
  local lufs, range = loudness_from_chunks(state.chunks)
  local rms = math.sqrt(state.count > 0 and state.sum_sq / state.count or 0)
  local spectral_total = state.low_sq + state.mid_sq + state.high_sq
  return {
    lufs = lufs, range_lu = range, peak = state.peak, peak_db = M.amp_to_db(state.peak),
    true_peak_db = M.amp_to_db(state.true_peak), rms = rms, rms_db = M.amp_to_db(rms),
    crest_db = state.peak > EPS and M.amp_to_db(state.peak / math.max(rms, EPS)) or 0,
    dc_db = M.amp_to_db(math.abs(state.count > 0 and state.sum / state.count or 0)),
    infra_ratio_db = M.amp_to_db(math.sqrt(state.infra_sq / math.max(state.sum_sq, EPS))),
    clipped_samples = state.clipped, start_peak_db = M.amp_to_db(state.start_peak), end_peak_db = M.amp_to_db(state.end_peak),
    low_pct = spectral_total > EPS and 100 * state.low_sq / spectral_total or 0,
    mid_pct = spectral_total > EPS and 100 * state.mid_sq / spectral_total or 0,
    high_pct = spectral_total > EPS and 100 * state.high_sq / spectral_total or 0,
    silent = state.peak < 1e-7 or lufs == -math.huge,
  }
end

function M.analyze_stereo_file(project, path, windows)
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then return nil, "Could not open audio file: " .. path end
  local length = reaper.GetMediaSourceLength(source)
  local total_samples = math.ceil(length * RATE)
  reaper.InsertTrackAtIndex(0, false)
  local track = reaper.GetTrack(project, 0)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "#BILDI ANALYSIS (temporary)", true)
  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
  reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
  reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local accessor = reaper.CreateTrackAudioAccessor(track)
  local ok, result = xpcall(function()
    local buffer = reaper.new_array(BLOCK * 2)
    local left_state, right_state = new_channel_state(), new_channel_state()
    local coefficients = {
      low = math.exp(-2 * math.pi * 250 / RATE),
      high = math.exp(-2 * math.pi * 3500 / RATE),
      infra = math.exp(-2 * math.pi * 20 / RATE),
    }
    local window_stats = {}
    for index, window in ipairs(windows or {}) do
      window_stats[index] = {name = window.name, left_sq = 0, right_sq = 0, count = 0}
    end
    local position, sample_index = 0, 0
    local sum_left, sum_right, sum_left_sq, sum_right_sq, sum_cross, sum_mono_sq = 0, 0, 0, 0, 0, 0
    while position < length - 0.5 / RATE do
      local samples = math.min(BLOCK, math.ceil((length - position) * RATE))
      buffer.clear()
      local read = reaper.GetAudioAccessorSamples(accessor, RATE, 2, position, samples, buffer)
      if read < 0 then error("Audio accessor failed for " .. path) end
      local values = buffer.table(1, samples * 2)
      for sample = 1, samples do
        sample_index = sample_index + 1
        local left = values[(sample - 1) * 2 + 1] or 0
        local right = values[(sample - 1) * 2 + 2] or 0
        process_channel(left_state, left, sample_index, total_samples, coefficients)
        process_channel(right_state, right, sample_index, total_samples, coefficients)
        sum_left, sum_right = sum_left + left, sum_right + right
        sum_left_sq, sum_right_sq = sum_left_sq + left * left, sum_right_sq + right * right
        sum_cross = sum_cross + left * right
        sum_mono_sq = sum_mono_sq + ((left + right) * 0.5) ^ 2
        local time = (sample_index - 1) / RATE
        for index, window in ipairs(windows or {}) do
          if time >= window.start_time and time < window.end_time then
            local stats = window_stats[index]
            stats.left_sq, stats.right_sq, stats.count = stats.left_sq + left * left, stats.right_sq + right * right, stats.count + 1
          end
        end
      end
      position = position + samples / RATE
    end
    local count = math.max(sample_index, 1)
    local mean_left, mean_right = sum_left / count, sum_right / count
    local variance_left = math.max(0, sum_left_sq / count - mean_left ^ 2)
    local variance_right = math.max(0, sum_right_sq / count - mean_right ^ 2)
    local covariance = sum_cross / count - mean_left * mean_right
    local correlation = variance_left > EPS and variance_right > EPS and covariance / math.sqrt(variance_left * variance_right) or nil
    local rms_left, rms_right = math.sqrt(sum_left_sq / count), math.sqrt(sum_right_sq / count)
    local mono_rms = math.sqrt(sum_mono_sq / count)
    for _, stats in ipairs(window_stats) do
      stats.left_rms = math.sqrt(stats.left_sq / math.max(stats.count, 1))
      stats.right_rms = math.sqrt(stats.right_sq / math.max(stats.count, 1))
      stats.left_db = M.amp_to_db(stats.left_rms)
      stats.right_db = M.amp_to_db(stats.right_rms)
    end
    return {
      path = path, length = length, sample_rate = reaper.GetMediaSourceSampleRate(source),
      source_type = reaper.GetMediaSourceType(source), left = finish_channel(left_state), right = finish_channel(right_state),
      correlation = correlation, mono_fold_loss_db = M.amp_to_db(mono_rms / math.max(rms_left, rms_right, EPS)), windows = window_stats,
    }
  end, debug.traceback)
  reaper.DestroyAudioAccessor(accessor)
  reaper.DeleteTrack(track)
  if not ok then return nil, result end
  return result
end

function M.read_audit(path)
  local text = M.read_text(path)
  if not text then return nil end
  local audit = {text = text, path = path}
  audit.status = text:match("Status:%s*([^\r\n]+)")
  audit.completion_policy = text:match("Completion policy:%s*([^\r\n]+)")
  audit.profile_id = text:match("Profile ID:%s*([%w%-]+)")
  audit.checksum = text:match("SHA%-256:%s*([0-9a-fA-F]+)")
  audit.left_lufs = tonumber(text:match("Actual left:%s*([%+%-]?[%d%.]+)%s+LUFS"))
  audit.right_lufs = tonumber(text:match("Actual right:%s*([%+%-]?[%d%.]+)%s+LUFS"))
  audit.left_true_peak = tonumber(text:match("Actual left:[^\r\n]-|%s*([%+%-]?[%d%.]+)%s+dBTP"))
  audit.right_true_peak = tonumber(text:match("Actual right:[^\r\n]-|%s*([%+%-]?[%d%.]+)%s+dBTP"))
  audit.left_range = tonumber(text:match("Actual left:[^\r\n]-|%s*([%+%-]?[%d%.]+)%s+LU range"))
  audit.right_range = tonumber(text:match("Actual right:[^\r\n]-|%s*([%+%-]?[%d%.]+)%s+LU range"))
  audit.iem_ceiling = tonumber(text:match("IEM target:[^\r\n]-ceiling:%s*([%+%-]?[%d%.]+)%s+dBFS"))
  audit.foh_ceiling = tonumber(text:match("FOH target:[^\r\n]-FOH ceiling:%s*([%+%-]?[%d%.]+)%s+dBFS"))
  audit.hardware_safe_ceiling = tonumber(text:match("Hardware%-safe IEM ceiling:%s*([%+%-]?[%d%.]+)%s+dBFS"))
  audit.emergency_mode = text:match("Emergency stabilization:%s*USED") ~= nil
  audit.click_ratio = tonumber(text:match("Measured click/backing advantage:%s*([%+%-]?[%d%.]+)%s+dB"))
  audit.click_sample_id = text:match("Click replacement:[^\r\n]-metronome A [^|]+|%s*(CLK%-[%w]+)")
    or text:match("Click replacement:[^\r\n]-|%s*(CLK%-[%w]+)")
  audit.click_sample_b_id = text:match("Click replacement:[^\r\n]-| B [^|]+|%s*(CLK%-[%w]+)")
  audit.content_start = tonumber(text:match("Content audio:%s*starts at%s*([%d%.]+)%s+seconds"))
  audit.content_duration = tonumber(text:match("Content audio:[^\r\n]-duration%s*([%d%.]+)%s+seconds"))
  audit.leading_silence = tonumber(text:match("Leading digital silence:%s*([%d%.]+)%s+seconds"))
  audit.trailing_silence = tonumber(text:match("Trailing digital silence:%s*([%d%.]+)%s+seconds"))
  audit.padding_verified = text:match("Leading digital silence:[^\r\n]+%(VERIFIED%)") ~= nil
    and text:match("Trailing digital silence:[^\r\n]+%(VERIFIED%)") ~= nil
  audit.left_crest = tonumber(text:match("Left spectral:[^\r\n]-crest%s+([%+%-]?[%d%.]+)%s+dB"))
  audit.right_crest = tonumber(text:match("Right spectral:[^\r\n]-crest%s+([%+%-]?[%d%.]+)%s+dB"))
  audit.left_low, audit.left_mid, audit.left_high = text:match("Left spectral:%s*low%s+([%d%.]+)%%%s*|%s*mid%s+([%d%.]+)%%%s*|%s*high%s+([%d%.]+)%%")
  audit.right_low, audit.right_mid, audit.right_high = text:match("Right spectral:%s*low%s+([%d%.]+)%%%s*|%s*mid%s+([%d%.]+)%%%s*|%s*high%s+([%d%.]+)%%")
  for _, key in ipairs({"left_low","left_mid","left_high","right_low","right_mid","right_high"}) do audit[key] = tonumber(audit[key]) end
  return audit
end

return M

end
local common = create_common()

local function run_builder(repair_mode)
--[[
  Bildibeat Show Track Builder v4.2
  Target: REAPER 7.77+

  One song per project. Track-name labels are the source of truth:
    CLICK   -> left/IEM click
    BACKING -> left/IEM music
    FOH     -> right/FOH program

  Baseline measurements are taken from REAPER track audio accessors immediately
  pre-FX after the script has neutralized item/take gain and take FX. Track
  faders, track pan, track/master FX, sends, and master state do not participate.

  The script installs one embedded JSFX in REAPER's resource Effects folder.
  Existing FX are bypassed, never deleted. Generated buses and FX are tagged so
  rerunning updates a project rather than stacking another processing system.
]]

local SCRIPT_NAME = "Bildibeat Show Track Builder v4.2"
local SCRIPT_VERSION = "4.2"
-- The A/B metronome and shared ALT click mapping changes the audible show
-- profile even when the five show targets remain the same.
local PROCESSING_PROFILE_VERSION = "4.2"
local SCRIPT_SOURCE = debug.getinfo(1, "S").source:gsub("^@", "")
local SCRIPT_DIRECTORY = SCRIPT_SOURCE:match("^(.*[\\/])") or ""
-- Shared utilities are embedded by the unified app.
local EXTSTATE_SECTION = "Bildibeat_Show_Track_Builder"
local BUS_EXT_KEY = "P_EXT:BILDI_SHOW_BUS"
local ROLE_EXT_KEY = "P_EXT:BILDI_SHOW_ROLE"
local PROCESSOR_FX_PATH = "Bildibeat/Bildibeat_Show_Processor_v4_0"
local PROCESSOR_FX_QUERY = "JS: " .. PROCESSOR_FX_PATH
local PROCESSOR_FX_NAME = "Bildibeat Show Processor"
local ANALYSIS_RATE = 48000
local ANALYSIS_BLOCK = 4096
local DOWNMIX_ANALYSIS_RATE = 24000
local DOWNMIX_BLOCK = 4096
local LOUDNESS_CHUNK_SAMPLES = 4800 -- 100 ms at 48 kHz
local RENDER_ACTION_AUTOCLOSE = 42230
local WAV_24BIT_CONFIG = "ZXZhdxgAAcw="
-- A two-LU show tolerance is a quality target, not a safety gate.  The app may
-- make one bounded constant-gain correction, but it never withholds an audible,
-- peak-safe show file merely because programme dynamics differ between songs.
-- Peak, routing, padding, CLICK, file-integrity, and audible-content checks stay
-- hard because relaxing those could create a genuinely unsafe or unusable file.
local LOUDNESS_REPAIR_THRESHOLD_LU = 0.50
local LOUDNESS_NORMAL_TOLERANCE_LU = 2.00
local LOUDNESS_EMERGENCY_TOLERANCE_LU = 2.00
local CLICK_RATIO_TOLERANCE_DB = 0.50
local INTENT_OFFSET_LIMIT_DB = 6
local TRUE_PEAK_GUARD_DB = 0.10
local SHOW_RANGE_TARGET_LU = 3.50
local SHOW_RANGE_HARD_LIMIT_LU = 5.00
local SHOW_RANGE_EMERGENCY_LIMIT_LU = 7.00
local MIN_METER_PASSES = 2
local FAST_METER_PASSES = 2
local MAX_METER_PASSES = 3
local BUS_COMPONENT_TOLERANCE_LU = 0.35
local CLICK_COMPONENT_TOLERANCE_DB = 0.50
-- Hard anti-pump policy: no detector-following gain envelopes, passage gain,
-- reactive riding, or sidechain ducking. CLICK and BACKING can use a bounded,
-- memoryless soft-knee transfer curve, fixed for the entire song. Final buses
-- retain constant gain and a separate no-release peak guard. This lowers
-- crest factor without allowing one instrument to make another path breathe.
local MAX_DYNAMIC_REPAIR_DB = 0.00
local MAX_DYNAMIC_REPAIR_STEPS = 0
local MAX_FINAL_COMPRESSION_STRENGTH = 0.00
ANTI_PUMP_MAP_SLEW_DB_PER_SECOND = 0.60
ANTI_PUMP_MAP_SMOOTH_RADIUS = 2
ANTI_PUMP_MAX_COMP_RATIO = 2.00
ANTI_PUMP_MIN_COMP_RELEASE_MS = 600
local MAX_POST_RENDER_REPAIRS = 2
local MAX_SIDE_REPAIR_ATTEMPTS = 2
local NORMAL_REPAIR_ATTEMPTS = 2
local RENDER_TIMEOUT_SECONDS = 300
local RENDER_FILE_GRACE_SECONDS = 5
BILDI_RENDER_FILE_STABLE_SECONDS = 1.00
local MAX_RENDER_RETRIES = 2
BILDI_MAX_SILENT_RENDER_RETRIES = 1
local PASSAGE_MAP_STRIDE = 4096
local PASSAGE_MAP_MAX_POINTS = PASSAGE_MAP_STRIDE - 4
local PASSAGE_MAP_GMEM = "BildibeatShowPassageV4"
local HARDWARE_CEILING_EXT_KEY = "hardware_safe_iem_ceiling_v3"
local HARDWARE_REPORT_EXT_KEY = "hardware_safe_report_v3"
local CACHE_SECTION = "Bildibeat_Show_Track_Cache_v5"
local REFERENCE_FILENAME = "BILDIBEAT_SHOW_REFERENCE.txt"
local PROFILE_EXT_KEY = "show_profile_v13"
local PROFILE_LOCK_EXT_KEY = "show_profile_locked_v13"
local CLICK_ALT_SAMPLE_EXT_KEY = "click_alt_sample_path_v42"
local CLICK_MULTI = {legacy_alt_key = "click_alt_samples_v1", epsilon = 1e-7}
local LEADING_SILENCE_SECONDS = 2.5
local TRAILING_SILENCE_SECONDS = 30
local EPS = 1e-20
local meter_registry, meter_next_slot = {}, 1
local TEST_MODE = reaper.GetExtState(EXTSTATE_SECTION, "test_mode_once") == "1"
local TEST_OUTPUT_PATH = reaper.GetExtState(EXTSTATE_SECTION, "test_output_path")
local TEST_RENDER_MODE = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_render_once") == "1"
TEST_VARIANTS_MODE = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_variants_once") == "1"
local TEST_CALIBRATION_MODE = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_calibration_once") == "1"
local TEST_METRONOME_A_PATH = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_metronome_a_path") or ""
local TEST_METRONOME_B_PATH = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_metronome_b_path") or ""
local TEST_ALT_SAMPLE_PATH = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_click_alt_sample_path") or ""
local TEST_PROFILE = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_profile_once") or ""
TEST_MIX_OFFSETS = TEST_MODE and reaper.GetExtState(EXTSTATE_SECTION, "test_mix_offsets_once") or ""
if TEST_MODE then
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_mode_once", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_render_once", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_variants_once", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_calibration_once", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_metronome_a_path", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_metronome_b_path", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_click_alt_sample_path", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_profile_once", true)
  reaper.DeleteExtState(EXTSTATE_SECTION, "test_mix_offsets_once", true)
end

local JSFX_SOURCE = [=[desc:Bildibeat Show Processor v4.0
// Installed and controlled by Bildibeat Show Track Builder v4.0.
options:gmem=BildibeatShowPassageV4

slider1:0<-60,36,0.1>Input trim (dB)
slider2:-24<-60,-6,0.1>Passage level target (dB RMS)
slider3:0<0,18,0.1>Maximum reactive correction (dB)
slider4:1200<250,5000,10>Reactive leveling time (ms)
slider5:-24<-60,0,0.1>Compressor threshold (dB)
slider6:1<1,20,0.1>Compressor ratio
slider7:20<0.1,200,0.1>Compressor attack (ms)
slider8:250<10,2000,1>Compressor release (ms)
slider9:0<-24,24,0.1>Post-compressor makeup (dB)
slider10:-3<-60,0,0.1>True-peak ceiling (dBFS)
slider11:1<0,4,1{Stereo,Mono sum,Left only,Right only,Phase-corrected fold}>Channel mode
slider12:0<0,6,0.1>Five-band priority duck maximum (dB)
slider13:-42<-60,-18,0.5>Priority key threshold (dBFS)
slider14:20<1,200,1>Priority duck attack (ms)
slider15:300<25,2000,5>Priority duck release (ms)
slider16:0<0,1,1{Off,On}>Priority sidechain
slider17:0<0,2047,1>Offline passage-map slot
slider18:1<0,1,1{Off,On}>18 Hz safety high-pass
slider19:-60<-90,-30,1>Silence/noise-floor guard (dBFS)
slider20:5<1,10,0.5>True-peak lookahead (ms)
slider21:100<25,1000,5>Limiter release (ms)
slider22:6<0,18,0.1>Memoryless compressor knee (dB)
slider23:0<0,6,0.1>Maximum source peak reduction (dB)

@init
function cubic4(p0 p1 p2 p3 f) local(f2 f3) (
  f2=f*f; f3=f2*f;
  0.5*((2*p1)+(-p0+p2)*f+(2*p0-5*p1+4*p2-p3)*f2+(-p0+3*p1-3*p2+p3)*f3);
);
env=0; slow_sq=0; slow_corr=0; lim_gain=1; lim_hold=0;
hp_x0=0; hp_x1=0; hp_y0=0; hp_y1=0;
main_lp1=0; main_lp2=0; main_lp3=0; main_lp4=0;
key_lp1=0; key_lp2=0; key_lp3=0; key_lp4=0;
duck_env1=0; duck_env2=0; duck_env3=0; duck_env4=0; duck_env5=0;
tp_l0=0; tp_l1=0; tp_l2=0; tp_r0=0; tp_r1=0; tp_r2=0;
delay_left=0; delay_right=16384; delay_gain=32768; delay_index=0; block_sample=0;

@slider
trim_gain=10^(slider1/20);
slow_coeff=exp(-1/(max(slider4,1)*0.001*srate));
slow_corr_coeff=exp(-1/(0.350*srate));
att_coeff=exp(-1/(max(slider7,0.1)*0.001*srate));
rel_coeff=exp(-1/(max(slider8,1)*0.001*srate));
lim_rel_coeff=exp(-1/(max(slider21,25)*0.001*srate));
makeup_gain=10^(slider9/20);
ceiling_amp=10^(slider10/20);
db_scale=20/log(10);
hp_coeff=exp(-2*$pi*18/srate);
cross1=exp(-2*$pi*90/srate);
cross2=exp(-2*$pi*300/srate);
cross3=exp(-2*$pi*1500/srate);
cross4=exp(-2*$pi*5000/srate);
duck_att_coeff=exp(-1/(max(slider14,1)*0.001*srate));
duck_rel_coeff=exp(-1/(max(slider15,25)*0.001*srate));
lookahead_samples=min(8190,max(1,ceil(slider20*0.001*srate)));
pdc_delay=lookahead_samples; pdc_bot_ch=0; pdc_top_ch=2;

@block
block_position=play_position;
block_sample=0;

@sample
x0=spl0;
x1=spl1;

slider18>=0.5 ? (
  hp_new0=hp_coeff*(hp_y0+x0-hp_x0); hp_x0=x0; hp_y0=hp_new0; x0=hp_new0;
  hp_new1=hp_coeff*(hp_y1+x1-hp_x1); hp_x1=x1; hp_y1=hp_new1; x1=hp_new1;
);

// The passage-map slider is retained only so old projects load without a
// parameter-layout mismatch. v4.0 never reads it: musical trim is constant for
// the entire render, which makes programme-level pumping impossible.
map_gain=1;

slider11>=0.5 ? (
  slider11<1.5 ? mono=(x0+x1)*0.5
  : slider11<2.5 ? mono=x0
  : slider11<3.5 ? mono=x1
  : mono=(x0-x1)*0.5;
  x0=mono; x1=mono;
);

// Reactive level riding and passage-dependent gain are structurally disabled.
// Source compression is a bounded static input/output curve before trim: no
// detector envelope, attack/release recovery, or cross-track gain modulation.
slow_corr=0;

det=max(abs(x0),abs(x1));
// Memoryless stereo-linked peak curve. Because gain depends only on the
// current sample magnitude, it has no attack/release envelope that can breathe.
level_db=db_scale*log(max(det,0.00000000000000000001));
comp_db=0;
slider6>1 && slider23>0 ? (
  over=level_db-slider5;
  knee=max(slider22,0);
  slope=1-1/slider6;
  over>=knee*0.5 ? comp_db=-slope*over
  : over> -knee*0.5 && knee>0 ? (
    knee_position=over+knee*0.5;
    comp_db=-slope*knee_position*knee_position/(2*knee);
  );
  comp_db=max(comp_db,-slider23);
);
comp_gain=10^(comp_db/20)*makeup_gain;
y0=x0*comp_gain*trim_gain; y1=x1*comp_gain*trim_gain;

// Dynamic priority ducking is structurally disabled. LEAD/RHYTHM/BED spacing
// is set statically by the builder, so another stem cannot modulate this one.

tp_est=max(abs(y0),abs(y1));
tp_est=max(tp_est,abs(cubic4(tp_l0,tp_l1,tp_l2,y0,0.25)));
tp_est=max(tp_est,abs(cubic4(tp_l0,tp_l1,tp_l2,y0,0.50)));
tp_est=max(tp_est,abs(cubic4(tp_l0,tp_l1,tp_l2,y0,0.75)));
tp_est=max(tp_est,abs(cubic4(tp_r0,tp_r1,tp_r2,y1,0.25)));
tp_est=max(tp_est,abs(cubic4(tp_r0,tp_r1,tp_r2,y1,0.50)));
tp_est=max(tp_est,abs(cubic4(tp_r0,tp_r1,tp_r2,y1,0.75)));
tp_l0=tp_l1; tp_l1=tp_l2; tp_l2=y0; tp_r0=tp_r1; tp_r1=tp_r2; tp_r2=y1;
target_lim=tp_est>ceiling_amp ? ceiling_amp/max(tp_est,0.00000000000000000001) : 1;
// Store the peak correction with the corresponding delayed sample. There is no
// programme-following release envelope, hence no limiter recovery swell.
delayed0=delay_left[delay_index]; delayed1=delay_right[delay_index];
delayed_gain=delay_gain[delay_index];
delay_left[delay_index]=y0; delay_right[delay_index]=y1;
delay_gain[delay_index]=target_lim;
delay_index+=1; delay_index>=lookahead_samples ? delay_index=0;
spl0=delayed0*delayed_gain; spl1=delayed1*delayed_gain;
block_sample+=1;
]=]

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function amp_to_db(value)
  if not value or value <= EPS then return -math.huge end
  return 20 * math.log(value, 10)
end

local function db_to_amp(value)
  return 10 ^ (value / 20)
end

local function finite(value)
  return type(value) == "number" and value == value
    and value > -math.huge and value < math.huge
end

local function format_db(value, suffix)
  if not finite(value) then return "-inf" .. (suffix or "") end
  return string.format("%.2f%s", value, suffix or "")
end

local function path_separator()
  return package.config:sub(1, 1)
end

local function join_path(left, right)
  local sep = path_separator()
  if left:sub(-1) == "/" or left:sub(-1) == "\\" then return left .. right end
  return left .. sep .. right
end

local function split_path(path)
  local directory, filename = path:match("^(.*[\\/])([^\\/]+)$")
  if not directory then return "", path end
  directory = directory:gsub("[\\/]$", "")
  return directory, filename
end

local function strip_wav_extension(filename)
  return filename:gsub("%.[Ww][Aa][Vv]$", "")
end

local function ensure_wav_extension(path)
  if path:lower():sub(-4) == ".wav" then return path end
  return path .. ".wav"
end

local function file_exists(path)
  local handle = io.open(path, "rb")
  if handle then handle:close(); return true end
  return false
end

function copy_file(path, destination)
  local input, input_error = io.open(path, "rb")
  if not input then return false, input_error end
  local output, output_error = io.open(destination, "wb")
  if not output then input:close(); return false, output_error end
  local ok, problem = xpcall(function()
    while true do
      local block = input:read(1024 * 1024)
      if not block then break end
      local written, write_error = output:write(block)
      if not written then error(write_error or "unknown write error") end
    end
  end, debug.traceback)
  input:close()
  output:close()
  if not ok then os.remove(destination); return false, problem end
  return true
end

local function read_text(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local value = handle:read("*a")
  handle:close()
  return value
end

local function write_text(path, value)
  local handle, message = io.open(path, "wb")
  if not handle then return false, message end
  local written, write_error = handle:write(value)
  local closed, close_error = handle:close()
  if not written or not closed then
    os.remove(path)
    return false, write_error or close_error or "The text file could not be saved completely."
  end
  return true
end

local function copy_binary_file(source_path, destination_path)
  local input, input_error = io.open(source_path, "rb")
  if not input then return false, input_error end
  local output, output_error = io.open(destination_path, "wb")
  if not output then input:close(); return false, output_error end
  local ok, result = xpcall(function()
    while true do
      local block = input:read(1024 * 1024)
      if not block then break end
      local written, write_error = output:write(block)
      if not written then error(write_error) end
    end
    return true
  end, debug.traceback)
  input:close(); output:close()
  if not ok then os.remove(destination_path); return false, result end
  return true
end

local function console(message)
  reaper.ShowConsoleMsg(tostring(message) .. "\n")
end

local function compact_detail(value, maximum_lines, maximum_characters)
  local text = tostring(value or ""):gsub("\r", "")
  local lines, limit = {}, maximum_lines or 6
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      lines[#lines + 1] = line
      if #lines >= limit then break end
    end
  end
  local result = table.concat(lines, "\n")
  local characters = maximum_characters or 700
  if #result > characters then result = result:sub(1, characters) .. "..." end
  if result == "" then result = "No additional detail was returned." end
  return result
end

local function compact_list(values, maximum)
  local lines, count = {}, #(values or {})
  for index = 1, math.min(count, maximum or 5) do lines[#lines + 1] = tostring(values[index]) end
  if count > #lines then lines[#lines + 1] = string.format("...and %d more. See the REAPER console/audit.", count - #lines) end
  return table.concat(lines, "\n")
end

local progress_state = {
  active = false, cancel_requested = false, previous_mouse_down = false,
  stage = "Preparing", detail = "", fraction = 0, safe_to_cancel = true,
}

local function progress_wrapped_lines(value, width)
  local lines, current = {}, ""
  for word in tostring(value or ""):gmatch("%S+") do
    if #current > 0 and #current + #word + 1 > width then
      lines[#lines + 1], current = current, word
    else
      current = current == "" and word or (current .. " " .. word)
    end
  end
  if current ~= "" then lines[#lines + 1] = current end
  return lines
end

local function progress_draw()
  if not progress_state.active or TEST_MODE then return end
  local width, height = math.max(gfx.w or 560, 420), math.max(gfx.h or 260, 220)
  local margin, bar_y, bar_height = 26, math.floor(height * 0.57), 20
  gfx.set(0.035, 0.055, 0.078, 1); gfx.rect(0, 0, width, height, true)
  gfx.set(0.96, 0.98, 1, 1); gfx.setfont(1, "Arial", 22, 98)
  gfx.x, gfx.y = margin, 20; gfx.drawstr(progress_state.stage)
  gfx.set(0.70, 0.78, 0.86, 1); gfx.setfont(2, "Arial", 13)
  local detail_y = 58
  for index, line in ipairs(progress_wrapped_lines(progress_state.detail, math.max(40, math.floor((width - margin * 2) / 7.2)))) do
    if index > 3 then break end
    gfx.x, gfx.y = margin, detail_y + (index - 1) * 18; gfx.drawstr(line)
  end
  gfx.set(0.11, 0.16, 0.22, 1); gfx.rect(margin, bar_y, width - margin * 2, bar_height, true)
  gfx.set(0.18, 0.56, 0.82, 1)
  gfx.rect(margin, bar_y, (width - margin * 2) * clamp(progress_state.fraction or 0, 0, 1), bar_height, true)
  gfx.set(0.92, 0.95, 0.98, 1); gfx.setfont(2, "Arial", 12)
  gfx.x, gfx.y = margin, bar_y + 27; gfx.drawstr(string.format("%d%%", math.floor(clamp(progress_state.fraction or 0, 0, 1) * 100 + 0.5)))

  local button_width, button_height = math.min(180, width - margin * 2), 36
  local button_x, button_y = width - margin - button_width, height - 50
  local hovered = gfx.mouse_x >= button_x and gfx.mouse_x <= button_x + button_width
    and gfx.mouse_y >= button_y and gfx.mouse_y <= button_y + button_height
  if progress_state.cancel_requested then gfx.set(0.36, 0.20, 0.12, 1)
  elseif hovered then gfx.set(0.72, 0.25, 0.22, 1)
  else gfx.set(0.48, 0.18, 0.17, 1) end
  gfx.rect(button_x, button_y, button_width, button_height, true)
  gfx.set(1, 1, 1, 1); gfx.setfont(2, "Arial", 13, 98)
  local label = progress_state.cancel_requested and "Cancel requested"
    or (progress_state.safe_to_cancel and "Cancel safely" or "Cancel after this render")
  gfx.x, gfx.y = button_x + 14, button_y + 9; gfx.drawstr(label)
  gfx.update()

  local character = gfx.getchar()
  local mouse_down = (gfx.mouse_cap & 1) == 1
  if character < 0 or character == 27
      or (mouse_down and not progress_state.previous_mouse_down and hovered) then
    progress_state.cancel_requested = true
  end
  progress_state.previous_mouse_down = mouse_down
end

local function progress_open(stage, detail, fraction)
  if TEST_MODE then return end
  if progress_state.active then gfx.quit() end
  progress_state.active, progress_state.cancel_requested = true, false
  progress_state.previous_mouse_down = false
  progress_state.stage, progress_state.detail = stage or "Working", detail or "", fraction or 0
  progress_state.safe_to_cancel = true
  gfx.init(SCRIPT_NAME .. " - Progress", 560, 260, 0)
  progress_draw()
end

local function progress_update(stage, detail, fraction, safe_to_cancel)
  if TEST_MODE or not progress_state.active then return false end
  progress_state.stage = stage or progress_state.stage
  progress_state.detail = detail or progress_state.detail
  progress_state.fraction = fraction or progress_state.fraction
  progress_state.safe_to_cancel = safe_to_cancel ~= false
  progress_draw()
  return progress_state.cancel_requested
end

local function progress_cancel_pending()
  return not TEST_MODE and progress_state.active and progress_state.cancel_requested
end

local function progress_abort_if_requested()
  if progress_cancel_pending() then error("BILDI_USER_CANCELLED", 0) end
end

local function progress_close()
  if not TEST_MODE and progress_state.active then gfx.quit() end
  progress_state.active = false
end

local function store_test_result(message)
  local encoded = tostring(message or ""):gsub("\r", ""):gsub("\n", "\\n")
  reaper.SetExtState(EXTSTATE_SECTION, "test_result", encoded, true)
end

local function track_name(track)
  local _, name = reaper.GetTrackName(track)
  return name or ""
end

local function track_ext(track, key)
  local _, value = reaper.GetSetMediaTrackInfo_String(track, key, "", false)
  return value or ""
end

local function set_track_ext(track, key, value)
  reaper.GetSetMediaTrackInfo_String(track, key, value or "", true)
end

local function has_word_label(name, label)
  local normalized = tostring(name or ""):upper()
  return normalized:find("%f[%w]" .. label .. "%f[%W]") ~= nil
end

local function classify_name(name)
  local matches = {}
  for _, role in ipairs({"CLICK", "BACKING", "FOH"}) do
    if has_word_label(name, role) then matches[#matches + 1] = role end
  end
  if #matches == 0 then return nil end
  if #matches > 1 then return nil, table.concat(matches, "+") end
  return matches[1]
end

local function classify_foh_priority(name)
  local matches = {}
  for _, priority in ipairs({"LEAD", "RHYTHM", "BED"}) do
    if has_word_label(name, priority) then matches[#matches + 1] = priority end
  end
  if #matches > 1 then return nil, table.concat(matches, "+") end
  return matches[1] or "RHYTHM"
end

-- An explicit signed number in a track name is a small mix-intent offset.
-- Examples: "Guitar - FOH LEAD +2" and "Pads BACKING -1.5 dB".  A sign
-- touching a word/number is ignored so dates and model numbers are not parsed.
local function classify_intent_offset(name)
  local text = tostring(name or "")
  local matches, cursor = {}, 1
  while cursor <= #text do
    local first, last, token = text:find("([+-]%d+%.?%d*)", cursor)
    if not first then break end
    local previous = first > 1 and text:sub(first - 1, first - 1) or ""
    local following = last < #text and text:sub(last + 1, last + 1) or ""
    if not previous:match("[%w%.]") and not following:match("[%d%.]") then
      matches[#matches + 1] = tonumber(token)
    end
    cursor = last + 1
  end
  if #matches > 1 then return nil, "multiple signed intent offsets" end
  if #matches == 0 then return 0 end
  if math.abs(matches[1]) > INTENT_OFFSET_LIMIT_DB then
    return nil, string.format("intent offset %+.1f dB exceeds the +/-%.1f dB guard", matches[1], INTENT_OFFSET_LIMIT_DB)
  end
  return matches[1]
end

local function count_track_items(track)
  return reaper.CountTrackMediaItems(track)
end

local function inspect_source_media(record)
  local formats, rates, lossy = {}, {}, {}
  for index = 0, reaper.CountTrackMediaItems(record.track) - 1 do
    local item = reaper.GetTrackMediaItem(record.track, index)
    local take = reaper.GetActiveTake(item)
    if take then
      local source = reaper.GetMediaItemTake_Source(take)
      if source then
        local source_type = tostring(reaper.GetMediaSourceType(source) or "UNKNOWN"):upper()
        formats[source_type] = true
        local rate = reaper.GetMediaSourceSampleRate(source)
        if rate and rate > 0 then rates[math.floor(rate + 0.5)] = true end
        local filename = tostring(reaper.GetMediaSourceFileName(source) or "")
        local extension = filename:lower():match("%.([%w%d]+)$") or source_type:lower()
        if extension == "mp3" or extension == "aac" or extension == "m4a" or extension == "ogg" or extension == "opus" then
          lossy[#lossy + 1] = filename ~= "" and filename or source_type
        end
      end
    end
  end
  local format_list, rate_list = {}, {}
  for value in pairs(formats) do format_list[#format_list + 1] = value end
  for value in pairs(rates) do rate_list[#rate_list + 1] = value end
  table.sort(format_list); table.sort(rate_list)
  record.media_formats, record.media_rates, record.lossy_sources = format_list, rate_list, lossy
end

local function source_file_size(path)
  local handle = path and path ~= "" and io.open(path, "rb") or nil
  if not handle then return 0 end
  local size = handle:seek("end") or 0
  handle:close()
  return size
end

-- A fast content identity reads the beginning, middle, and end of a media
-- file. It catches stale same-size cache entries and incomplete external-drive
-- copies without hashing an entire multitrack session on every song build.
local BILDI_FILE_PROBE_CACHE = {}
function file_probe_fingerprint(path, refresh)
  local size = source_file_size(path)
  if size <= 0 then return nil, "file is missing or empty" end
  local cache_key = tostring(path):lower() .. "|" .. tostring(size)
  if not refresh and BILDI_FILE_PROBE_CACHE[cache_key] then return BILDI_FILE_PROBE_CACHE[cache_key] end
  local handle, open_error = io.open(path, "rb")
  if not handle then return nil, open_error end
  local probe_bytes = math.min(65536, size)
  local offsets = {0, math.max(0, math.floor((size - probe_bytes) / 2)), math.max(0, size - probe_bytes)}
  local parts = {tostring(size)}
  for _, offset in ipairs(offsets) do
    handle:seek("set", offset)
    local block = handle:read(probe_bytes)
    if not block or #block ~= probe_bytes then
      handle:close()
      return nil, "could not read a complete media identity probe"
    end
    parts[#parts + 1] = tostring(offset)
    parts[#parts + 1] = block
  end
  handle:close()
  local fingerprint = common.sha256_string(table.concat(parts, "|"))
  BILDI_FILE_PROBE_CACHE[cache_key] = fingerprint
  return fingerprint
end

-- On Windows, REAPER can itself be portable and live on a removable drive.
-- LOCALAPPDATA is therefore preferred for staging and temporary renders; the
-- REAPER resource directory remains the cross-platform fallback.
function local_work_root()
  local root = os.getenv("LOCALAPPDATA")
  if not root or root == "" then root = reaper.GetResourcePath() end
  root = join_path(root, "BildibeatShowTrack")
  reaper.RecursiveCreateDirectory(root, 0)
  return root
end

local function analysis_cache_key(record, start_time, end_time)
  if not reaper.GetTrackGUID then return nil end
  local fields = {"v5", reaper.GetTrackGUID(record.track), tostring(record.downmix and record.downmix.mode or "mono"),
    string.format("%.9f", start_time), string.format("%.9f", end_time)}
  for index = 0, reaper.CountTrackMediaItems(record.track) - 1 do
    local item = reaper.GetTrackMediaItem(record.track, index)
    local take = reaper.GetActiveTake(item)
    fields[#fields + 1] = string.format("I%.9f/%.9f/%.9f/%.9f", reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
      reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), reaper.GetMediaItemInfo_Value(item, "D_VOL"),
      reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN") + reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"))
    if take then
      local source = reaper.GetMediaItemTake_Source(take)
      local filename = source and tostring(reaper.GetMediaSourceFileName(source) or "") or ""
      local fingerprint = file_probe_fingerprint(filename)
      fields[#fields + 1] = table.concat({filename, source_file_size(filename), fingerprint or "UNREADABLE",
        reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
        reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
        reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
        reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH"),
        reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")}, "/")
    end
  end
  return common.sha256_string(table.concat(fields, "|"))
end

local ANALYSIS_CACHE_FIELDS = {"lufs", "active_lufs", "range_lu", "peak", "peak_db", "rms_db", "crest_db",
  "clipped_samples", "dc_db", "infra_ratio_db", "start_peak_db", "end_peak_db", "low_pct", "mid_pct", "high_pct"}

local function encode_analysis_cache(raw)
  local values = {"BILDI_ANALYSIS_V5"}
  for _, key in ipairs(ANALYSIS_CACHE_FIELDS) do
    local value = raw[key]
    values[#values + 1] = finite(value) and string.format("%.12g", value) or "-1e300"
  end
  local map = raw.passage_map or {}
  values[#values + 1] = string.format("%.12g", map.start_time or 0)
  values[#values + 1] = string.format("%.12g", map.step_seconds or 1)
  values[#values + 1] = string.format("%.12g", finite(map.target_lufs) and map.target_lufs or -1e300)
  local gains, flags = {}, {}
  for index, gain in ipairs(map.gains or {}) do
    gains[index] = string.format("%.5f", gain)
    flags[index] = map.active and map.active[index] and "1" or "0"
  end
  values[#values + 1] = table.concat(gains, ",")
  values[#values + 1] = table.concat(flags, "")
  return table.concat(values, "|")
end

local function decode_analysis_cache(value)
  if not value or value == "" then return nil end
  local parts = {}
  for part in (value .. "|"):gmatch("(.-)|") do parts[#parts + 1] = part end
  if parts[1] ~= "BILDI_ANALYSIS_V5" then return nil end
  local raw, cursor = {}, 2
  for _, key in ipairs(ANALYSIS_CACHE_FIELDS) do
    local number = tonumber(parts[cursor]); cursor = cursor + 1
    if not number then return nil end
    raw[key] = number <= -1e299 and -math.huge or number
  end
  local map = {start_time = tonumber(parts[cursor]), step_seconds = tonumber(parts[cursor + 1]),
    target_lufs = tonumber(parts[cursor + 2]), gains = {}, active = {}}
  cursor = cursor + 3
  if not map.start_time or not map.step_seconds then return nil end
  if map.target_lufs and map.target_lufs <= -1e299 then map.target_lufs = -math.huge end
  for gain in (tostring(parts[cursor] or "") .. ","):gmatch("(.-),") do
    if gain ~= "" then map.gains[#map.gains + 1] = tonumber(gain) or 0 end
  end
  local flags = tostring(parts[cursor + 1] or "")
  map.active_points, map.corrected_points = 0, 0
  for index = 1, #map.gains do
    map.active[index] = flags:sub(index, index) == "1"
    if map.active[index] then map.active_points = map.active_points + 1 end
    if map.active[index] and math.abs(map.gains[index]) >= 0.25 then map.corrected_points = map.corrected_points + 1 end
  end
  raw.passage_map = map
  raw.silent = raw.peak < 1e-7 or not finite(raw.lufs)
  raw.cache_hit = true
  return raw
end

local function cached_track_analysis(project, record, start_time, end_time)
  if record.role == "CLICK" or not reaper.GetProjExtState or not reaper.SetProjExtState then return nil end
  local key = analysis_cache_key(record, start_time, end_time)
  if not key then return nil end
  local found, value = reaper.GetProjExtState(project, CACHE_SECTION, key)
  if found and found > 0 then
    local decoded = decode_analysis_cache(value)
    if decoded then record.analysis_cache_key = key; return decoded end
  end
  record.analysis_cache_key = key
  return nil
end

local function save_cached_track_analysis(project, record)
  if record.analysis_cache_key and record.raw and reaper.SetProjExtState then
    reaper.SetProjExtState(project, CACHE_SECTION, record.analysis_cache_key, encode_analysis_cache(record.raw))
  end
end

local function analyze_source_with_sws(record, start_time, end_time)
  if record.role == "CLICK" or not reaper.APIExists
      or not reaper.APIExists("NF_AnalyzeTakeLoudness2") then return nil end
  local result = {items = 0, failed = 0, max_range_lu = 0,
    loudest_short_term = -math.huge, loudest_short_term_time = nil}
  for index = 0, reaper.CountTrackMediaItems(record.track) - 1 do
    local item = reaper.GetTrackMediaItem(record.track, index)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_end > start_time and position < end_time then
      local take = reaper.GetActiveTake(item)
      if take and (not reaper.TakeIsMIDI or not reaper.TakeIsMIDI(take)) then
        local call_ok, analyzed, _lufs, range_lu, _true_peak, _true_peak_pos,
          short_term_max, _momentary_max, short_term_pos, _momentary_pos =
          pcall(reaper.NF_AnalyzeTakeLoudness2, take, true)
        if call_ok and analyzed then
          result.items = result.items + 1
          if finite(range_lu) then result.max_range_lu = math.max(result.max_range_lu, range_lu) end
          if finite(short_term_max) and short_term_max > result.loudest_short_term then
            result.loudest_short_term = short_term_max
            result.loudest_short_term_time = finite(short_term_pos) and short_term_pos or nil
          end
        else
          result.failed = result.failed + 1
        end
      end
    end
  end
  return result
end

local function project_identity(project)
  local _, filename = reaper.EnumProjects(-1, "")
  if filename and filename ~= "" then
    local directory, leaf = split_path(filename)
    local stem = leaf:gsub("%.[Rr][Pp][Pp]$", "")
    return directory, stem
  end
  local directory = reaper.GetProjectPath("") or ""
  return directory, "Untitled"
end

local function sanitize_filename(value)
  local name = trim(value):gsub('[<>:"/\\|%?%*]', "_")
  name = name:gsub("[%s%.]+$", "")
  if name == "" then name = "Untitled" end
  return name
end

local function install_processor_jsfx()
  local resource = reaper.GetResourcePath()
  local effects = join_path(resource, "Effects")
  local directory = join_path(effects, "Bildibeat")
  reaper.RecursiveCreateDirectory(directory, 0)
  local path = join_path(directory, "Bildibeat_Show_Processor_v4_0")
  if read_text(path) ~= JSFX_SOURCE then
    local ok, message = write_text(path, JSFX_SOURCE)
    if not ok then error("Could not install the required JSFX:\n" .. tostring(message)) end
  end
  return path
end

local function settings_from_profile(value)
  local fields = {}
  for field in (tostring(value or "") .. ","):gmatch("(.-),") do fields[#fields + 1] = tonumber(trim(field)) end
  if #fields ~= 5 then return nil end
  for index = 1, 5 do if not fields[index] then return nil end end
  return {
    iem_ceiling = fields[1],
    iem_target = fields[2],
    click_advantage = fields[3],
    foh_target = fields[4],
    foh_ceiling = fields[5],
    click_peak_target = fields[1] - 3,
    backing_stem_target = -24,
    foh_stem_target = -20,
  }
end

local function profile_string(settings)
  return string.format("%.2f,%.2f,%.2f,%.2f,%.2f", settings.iem_ceiling, settings.iem_target,
    settings.click_advantage, settings.foh_target, settings.foh_ceiling)
end

local function profile_description(settings)
  return string.format("IEM %.1f LUFS / %.1f dBFS | click +%.1f dB | FOH %.1f LUFS / %.1f dBFS",
    settings.iem_target, settings.iem_ceiling, settings.click_advantage, settings.foh_target, settings.foh_ceiling)
end

local function validate_settings(settings)
  if settings.iem_ceiling < -30 or settings.iem_ceiling > -6 then return "IEM ceiling must be between -30 and -6 dBFS." end
  if settings.iem_target < -40 or settings.iem_target > -20 then return "IEM target must be between -40 and -20 LUFS." end
  if settings.iem_target > settings.iem_ceiling - 3 then return "IEM target must be at least 3 dB below the IEM ceiling." end
  if settings.click_advantage < 3 or settings.click_advantage > 15 then return "Click advantage must be between 3 and 15 dB." end
  if settings.foh_target < -24 or settings.foh_target > -10 then return "FOH target must be between -24 and -10 LUFS." end
  if settings.foh_ceiling < -12 or settings.foh_ceiling > -1 then return "FOH ceiling must be between -12 and -1 dBFS." end
  return nil
end

local function choose_settings()
  if TEST_MODE then
    local settings = settings_from_profile(TEST_PROFILE ~= "" and TEST_PROFILE or "-18,-28,8,-16,-3")
    settings.profile_locked = true
    settings.create_calibration = TEST_CALIBRATION_MODE
    return settings
  end

  local stored = reaper.GetExtState(EXTSTATE_SECTION, PROFILE_EXT_KEY)
  local locked = reaper.GetExtState(EXTSTATE_SECTION, PROFILE_LOCK_EXT_KEY) == "1"
  local stored_settings = settings_from_profile(stored)
  if locked and stored_settings and not validate_settings(stored_settings) then
    local answer = reaper.ShowMessageBox(
      "LOCKED SHOW PROFILE\n\n" .. profile_description(stored_settings) ..
      "\n\nYes: use this exact profile\nNo: unlock and edit\nCancel: stop",
      SCRIPT_NAME,
      3
    )
    if answer == 6 then
      stored_settings.profile_locked = true
      return stored_settings
    elseif answer == 2 then
      return nil
    end
  end

  local defaults = stored_settings and profile_string(stored_settings) or "-18,-28,8,-16,-3"
  local ok, values = reaper.GetUserInputs(
    SCRIPT_NAME,
    6,
    "IEM ceiling dBFS,IEM target LUFS,Click over backing dB,FOH target LUFS,FOH ceiling dBFS,Lock profile 1=yes 0=no,extrawidth=280",
    defaults .. ",1"
  )
  if not ok then return nil end
  local fields = {}
  for field in (values .. ","):gmatch("(.-),") do fields[#fields + 1] = tonumber(trim(field)) end
  if #fields ~= 6 then
    reaper.ShowMessageBox("Enter six valid numbers.", SCRIPT_NAME, 0)
    return nil
  end
  for index = 1, 6 do
    if fields[index] == nil then reaper.ShowMessageBox("Enter six valid numbers.", SCRIPT_NAME, 0); return nil end
  end
  if fields[6] ~= 0 and fields[6] ~= 1 then
    reaper.ShowMessageBox("Profile lock must be 1 (locked) or 0 (editable next run).", SCRIPT_NAME, 0)
    return nil
  end
  local settings = settings_from_profile(table.concat({fields[1], fields[2], fields[3], fields[4], fields[5]}, ","))
  local problem = validate_settings(settings)
  if problem then reaper.ShowMessageBox(problem, SCRIPT_NAME, 0); return nil end
  settings.profile_locked = fields[6] == 1
  reaper.SetExtState(EXTSTATE_SECTION, PROFILE_EXT_KEY, profile_string(settings), true)
  reaper.SetExtState(EXTSTATE_SECTION, PROFILE_LOCK_EXT_KEY, settings.profile_locked and "1" or "0", true)
  return settings
end

local function apply_hardware_safe_ceiling(settings)
  local measured = tonumber(reaper.GetExtState(EXTSTATE_SECTION, HARDWARE_CEILING_EXT_KEY))
  if not measured or not finite(measured) then
    settings.hardware_safe_ceiling = nil
    return
  end
  settings.requested_iem_ceiling = settings.iem_ceiling
  settings.hardware_safe_ceiling = measured
  settings.hardware_report_path = reaper.GetExtState(EXTSTATE_SECTION, HARDWARE_REPORT_EXT_KEY)
  if measured < -57 then
    settings.hardware_chain_unsafe = true
    return
  end
  if measured < settings.iem_ceiling then
    settings.iem_ceiling = measured
    settings.click_peak_target = measured - 3
    settings.hardware_ceiling_applied = true
  end
end

local function unique_output_path(path)
  if not file_exists(path) then return path end
  local base = path:gsub("%.[Ww][Aa][Vv]$", "")
  for index = 2, 999 do
    local candidate = string.format("%s_%02d.wav", base, index)
    if not file_exists(candidate) then return candidate end
  end
  return nil
end

function bildi_signed_offset_label(value)
  value = tonumber(value) or 0
  if math.abs(value) < 0.05 then value = 0 end
  if math.abs(value - math.floor(value + 0.5)) < 0.05 then
    return string.format("%+d", math.floor(value + 0.5))
  end
  return string.format("%+.1f", value)
end

-- The filename records both the requested change and the resulting assigned
-- CLICK offset. For example, an assigned +3 dB becomes +6 dB and 0 dB.
function bildi_click_variant_output_path(base_path, assigned_offset_db, change_db)
  local stem = base_path:gsub("%.[Ww][Aa][Vv]$", "")
  return unique_output_path(string.format("%s_CLICK_%sdB_delta%sdB.wav", stem,
    bildi_signed_offset_label((assigned_offset_db or 0) + change_db), bildi_signed_offset_label(change_db)))
end

local function choose_output_path(project)
  if TEST_MODE and TEST_OUTPUT_PATH ~= "" then return TEST_OUTPUT_PATH end
  local project_directory, project_name = project_identity(project)
  local last_directory = reaper.GetExtState(EXTSTATE_SECTION, "last_output_directory")
  local directory = last_directory ~= "" and last_directory or project_directory
  local initial = join_path(directory, sanitize_filename(project_name) .. "_SHOWTRACK.wav")
  local ok, selected = reaper.GetUserFileName(
    0,
    "Choose stereo show-track WAV destination",
    initial,
    "WAV audio|*.wav|All files|*.*"
  )
  if not ok then return nil end
  selected = ensure_wav_extension(selected)
  local _, selected_leaf = split_path(selected)
  if selected_leaf:find("$", 1, true) then
    reaper.ShowMessageBox("The output filename cannot contain '$' because REAPER treats it as a render wildcard.", SCRIPT_NAME, 0)
    return nil
  end
  if file_exists(selected) then
    local answer = reaper.ShowMessageBox(
      "That file already exists.\n\nChoose Yes to create the next numbered filename.\nChoose No to cancel.",
      SCRIPT_NAME,
      4
    )
    if answer ~= 6 then return nil end
    selected = unique_output_path(selected)
    if not selected then
      reaper.ShowMessageBox("Could not find an available numbered filename.", SCRIPT_NAME, 0)
      return nil
    end
  end
  local output_directory = split_path(selected)
  reaper.SetExtState(EXTSTATE_SECTION, "last_output_directory", output_directory, true)
  return selected
end

local function temporary_render_path(output_path)
  local temp_directory = join_path(local_work_root(), "Renders")
  reaper.RecursiveCreateDirectory(temp_directory, 0)
  local _, output_leaf = split_path(output_path)
  local base = sanitize_filename(output_leaf:gsub("%.[Ww][Aa][Vv]$", ""))
  local identity = common.sha256_string(tostring(output_path) .. "|" .. tostring(reaper.time_precise())):sub(1, 12)
  local path = unique_output_path(join_path(temp_directory,
    base .. "." .. identity .. ".bildibeat_render_tmp.wav"))
  if not path then error("Could not reserve a temporary render filename on REAPER's local drive.") end
  return path
end

local function preflight_output(project, output_path, content_duration)
  local errors, warnings = {}, {}
  local directory = split_path(output_path)
  local probe_path = join_path(directory, ".bildibeat_write_probe_" .. tostring(math.floor(reaper.time_precise() * 1000)) .. ".tmp")
  local probe, probe_error = io.open(probe_path, "wb")
  if not probe then
    errors[#errors + 1] = "E_OUTPUT_PERMISSION: The selected output folder is not writable: " .. tostring(probe_error)
  else
    probe:write("BILDI")
    probe:close()
    os.remove(probe_path)
  end
  local project_path = reaper.GetProjectPath and reaper.GetProjectPath("") or ""
  local same_volume = directory:sub(1, 2):lower() == project_path:sub(1, 2):lower()
  if reaper.GetFreeDiskSpaceForRecordPath and same_volume then
    local free_mb = reaper.GetFreeDiskSpaceForRecordPath(project, 0)
    if free_mb and free_mb >= 0 then
      local expected_mb = ((content_duration + LEADING_SILENCE_SECONDS + TRAILING_SILENCE_SECONDS)
        * 48000 * 2 * 3) / (1024 * 1024)
      local required_mb = math.max(256, expected_mb * 4)
      if free_mb < required_mb then
        errors[#errors + 1] = string.format(
          "E_DISK_SPACE: %.0f MB is free, but at least %.0f MB is required for render, repair, and rollback files.",
          free_mb, required_mb)
      elseif free_mb < required_mb * 2 then
        warnings[#warnings + 1] = string.format("Only %.0f MB is free in the render destination.", free_mb)
      end
    end
  elseif not same_volume then
    warnings[#warnings + 1] = "The output is on a different volume from the project; folder write access passed, but REAPER cannot report that volume's free space through this API."
  end
  return errors, warnings
end

local function create_project_backup(project, output_path)
  if TEST_MODE or not reaper.Main_SaveProjectEx then return nil end
  local base = output_path:gsub("%.[Ww][Aa][Vv]$", "")
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local backup_path = base .. "_PREBUILD_BACKUP_" .. timestamp .. ".rpp"
  reaper.Main_SaveProjectEx(project, backup_path, 0)
  return file_exists(backup_path) and backup_path or nil
end

local function checkpoint_path_for_output(output_path)
  return output_path:gsub("%.[Ww][Aa][Vv]$", "") .. ".bildibeat_checkpoint.txt"
end

function checkpoint_hex_encode(value)
  return (tostring(value or ""):gsub(".", function(character)
    return string.format("%02X", string.byte(character))
  end))
end

function checkpoint_hex_decode(value)
  if not value or #value % 2 ~= 0 or value:find("[^0-9A-Fa-f]") then return nil end
  return (value:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

function checkpoint_resume_payload(settings)
  if not settings.resume_ready or not settings.resume_report or not settings.render_output_path then return nil end
  local hit_times = {}
  for _, value in ipairs(settings.click_hit_times or {}) do
    hit_times[#hit_times + 1] = string.format("%.9f", value)
  end
  return table.concat({
    "schema=1",
    "output=" .. checkpoint_hex_encode(settings.final_output_path),
    "render=" .. checkpoint_hex_encode(settings.render_output_path),
    "profile=" .. tostring(settings.profile_id or ""),
    "selection_start=" .. string.format("%.9f", settings.selection_start),
    "selection_duration=" .. string.format("%.9f", settings.selection_duration),
    "iem_target=" .. string.format("%.9f", settings.iem_target),
    "iem_ceiling=" .. string.format("%.9f", settings.iem_ceiling),
    "foh_target=" .. string.format("%.9f", settings.foh_target),
    "foh_ceiling=" .. string.format("%.9f", settings.foh_ceiling),
    "has_foh=" .. (settings.resume_has_foh and "1" or "0"),
    "dynamics=" .. (settings.source_dynamics_applied and "1" or "0"),
    "calibration=" .. (settings.create_calibration and "1" or "0"),
    "click_floor=" .. string.format("%.9f", settings.click_audibility_floor_db or 5),
    "click_hits=" .. table.concat(hit_times, ","),
    "report=" .. checkpoint_hex_encode(settings.resume_report),
    "warnings=" .. checkpoint_hex_encode(table.concat(settings.resume_warnings or {}, "\n")),
  }, "\n")
end

function parse_resume_checkpoint(text)
  local encoded = tostring(text or ""):match("\nResume payload:%s*([0-9A-Fa-f]+)")
  local expected = tostring(text or ""):match("\nResume SHA%-256:%s*([0-9A-Fa-f]+)")
  local payload = checkpoint_hex_decode(encoded)
  if not payload or not expected or #expected ~= 64
      or common.sha256_string(payload):lower() ~= expected:lower() then
    return nil, "The checkpoint has no complete, checksum-verified resume metadata."
  end
  local fields = {}
  for line in payload:gmatch("[^\n]+") do
    local key, value = line:match("^([%a_]+)=(.*)$")
    if key then fields[key] = value end
  end
  if fields.schema ~= "1" then return nil, "This checkpoint uses an unsupported resume format." end
  local output_path = checkpoint_hex_decode(fields.output)
  local render_path = checkpoint_hex_decode(fields.render)
  local report = checkpoint_hex_decode(fields.report)
  local warnings_text = checkpoint_hex_decode(fields.warnings)
  local values = {}
  for _, key in ipairs({"selection_start", "selection_duration", "iem_target", "iem_ceiling",
      "foh_target", "foh_ceiling", "click_floor"}) do
    values[key] = tonumber(fields[key])
    if not values[key] or not finite(values[key]) then
      return nil, "The checkpoint has an invalid " .. key .. " value."
    end
  end
  if not output_path or output_path == "" or not render_path or render_path == ""
      or not report or report == "" or warnings_text == nil
      or not fields.profile or fields.profile == ""
      or (fields.has_foh ~= "0" and fields.has_foh ~= "1")
      or (fields.calibration ~= "0" and fields.calibration ~= "1")
      or values.selection_duration <= 0 then
    return nil, "The checkpoint's song verification metadata is incomplete."
  end
  local hits = {}
  for token in (fields.click_hits or ""):gmatch("[^,]+") do
    local value = tonumber(token)
    if not value or not finite(value)
        or value < values.selection_start - 0.001
        or value >= values.selection_start + values.selection_duration + 0.001 then
      return nil, "The checkpoint contains an invalid CLICK hit time."
    end
    hits[#hits + 1] = value
  end
  local warnings = {}
  for line in warnings_text:gmatch("[^\n]+") do warnings[#warnings + 1] = line end
  return {output_path = output_path, render_path = render_path,
    profile_id = fields.profile, report = report, warnings = warnings,
    selection_start = values.selection_start, selection_duration = values.selection_duration,
    iem_target = values.iem_target, iem_ceiling = values.iem_ceiling,
    foh_target = values.foh_target, foh_ceiling = values.foh_ceiling,
    has_foh = fields.has_foh == "1", create_calibration = fields.calibration == "1",
    source_dynamics_applied = fields.dynamics == "1",
    click_audibility_floor_db = values.click_floor,
    click_hit_times = hits}
end

local function write_checkpoint(settings, stage, detail)
  if not settings.checkpoint_path then return end
  local lines = {
    "BILDIBEAT CHECKPOINT v" .. SCRIPT_VERSION,
    "Stage: " .. tostring(stage),
    "Updated: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "Output: " .. tostring(settings.final_output_path or ""),
    "Temporary render: " .. tostring(settings.render_output_path or ""),
    "Profile ID: " .. tostring(settings.profile_id or ""),
    "Detail: " .. tostring(detail or ""),
  }
  local payload = checkpoint_resume_payload(settings)
  if payload then
    lines[#lines + 1] = "Resume SHA-256: " .. common.sha256_string(payload)
    lines[#lines + 1] = "Resume payload: " .. checkpoint_hex_encode(payload)
  end
  write_text(settings.checkpoint_path, table.concat(lines, "\n"))
end

local function write_diagnostic(settings, code, detail)
  local output = settings and settings.final_output_path or ""
  if output == "" then return nil end
  local path = output:gsub("%.[Ww][Aa][Vv]$", "") .. "_DIAGNOSTIC.txt"
  local lines = {
    "BILDIBEAT DIAGNOSTIC v" .. SCRIPT_VERSION,
    "Code: " .. tostring(code or "E_UNKNOWN"),
    "Created: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "REAPER: " .. tostring(reaper.GetAppVersion and reaper.GetAppVersion() or "unknown"),
    "Profile ID: " .. tostring(settings and settings.profile_id or "unknown"),
    "Time selection: " .. tostring(settings and settings.selection_start or "?") .. " to " ..
      tostring(settings and settings.selection_end or "?"),
    "Checkpoint: " .. tostring(settings and settings.checkpoint_path or "none"),
    "Detail:",
    tostring(detail or ""),
  }
  if settings and settings.repair_log and #settings.repair_log > 0 then
    lines[#lines + 1] = "\nRepair history:"
    for _, repair in ipairs(settings.repair_log) do lines[#lines + 1] = "- " .. repair end
  end
  local ok = write_text(path, table.concat(lines, "\n"))
  return ok and path or nil
end

local function processor_self_test(project)
  reaper.InsertTrackAtIndex(0, false)
  local track = reaper.GetTrack(project, 0)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "#SHOW PROCESSOR SELF-TEST (temporary)", true)
  local fx = reaper.TrackFX_AddByName(track, PROCESSOR_FX_QUERY, false, 1)
  local count = fx >= 0 and reaper.TrackFX_GetNumParams and reaper.TrackFX_GetNumParams(track, fx) or 23
  local parameter_ok, downmix_ok, limiter_release_ok, dynamics_ok = true, true, true, true
  if fx >= 0 and reaper.TrackFX_GetParam then
    reaper.TrackFX_SetParam(track, fx, 17, 1)
    local value = reaper.TrackFX_GetParam(track, fx, 17)
    parameter_ok = value and value >= 0.5
    reaper.TrackFX_SetParam(track, fx, 10, 4)
    local downmix_value = reaper.TrackFX_GetParam(track, fx, 10)
    downmix_ok = downmix_value and downmix_value >= 3.5
    reaper.TrackFX_SetParam(track, fx, 20, 100)
    local limiter_release = reaper.TrackFX_GetParam(track, fx, 20)
    limiter_release_ok = limiter_release and limiter_release >= 99
    reaper.TrackFX_SetParam(track, fx, 21, 6)
    reaper.TrackFX_SetParam(track, fx, 22, 3)
    local knee = reaper.TrackFX_GetParam(track, fx, 21)
    local maximum = reaper.TrackFX_GetParam(track, fx, 22)
    dynamics_ok = knee and maximum and knee >= 5.9 and maximum >= 2.9
  end
  reaper.DeleteTrack(track)
  if fx < 0 then return false, "E_PROCESSOR_LOAD: REAPER could not load the embedded v4.0 bounded-dynamics processor." end
  if count < 23 then return false, "E_PROCESSOR_VERSION: REAPER loaded an outdated processor definition." end
  if not parameter_ok then return false, "E_PROCESSOR_CONTROL: The embedded processor did not accept its safety high-pass setting." end
  if not downmix_ok then return false, "E_PROCESSOR_DOWNMIX: The embedded processor did not accept its phase-safe channel mode." end
  if not limiter_release_ok then return false, "E_PROCESSOR_LIMITER: The embedded processor did not accept its independent limiter-release setting." end
  if not dynamics_ok then return false, "E_PROCESSOR_DYNAMICS: The embedded processor did not accept its bounded-compression controls." end
  return true
end

local function failed_inspection_path(output_path)
  local base = output_path:gsub("%.[Ww][Aa][Vv]$", "")
  return unique_output_path(base .. "_FAILED_INSPECTION.wav")
end

-- The WAV is the final commit. Stage and verify both files, move the audit
-- first, then expose the WAV only after its matching audit is already present.
-- A failed copy/rename/hash leaves the locally verified source available for
-- retry and never reports an unaudited WAV as a completed show track.
function publish_verified_pair(temporary_path, output_path, audit_text, expected_checksum)
  local audit_path = output_path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
  if file_exists(output_path) or file_exists(audit_path) then
    return false, "The final WAV or audit filename already exists. Choose an unused destination."
  end
  if not expected_checksum or #expected_checksum ~= 64
      or not tostring(audit_text):find("SHA-256: " .. expected_checksum, 1, true)
      or not tostring(audit_text):find("\nStatus: PASS", 1, true) then
    return false, "The verified WAV and passing audit are not a matching pair."
  end
  local tag = common.sha256_string(output_path .. "|" .. tostring(reaper.time_precise())):sub(1, 12)
  local wav_stage = output_path .. ".bildibeat_" .. tag .. ".wavpart"
  local audit_stage = audit_path .. ".bildibeat_" .. tag .. ".part"
  if file_exists(wav_stage) or file_exists(audit_stage) then
    return false, "A publication staging filename unexpectedly exists."
  end
  local copied, copy_error = copy_file(temporary_path, wav_stage)
  if not copied then return false, "Could not stage the verified WAV: " .. tostring(copy_error) end
  local stage_checksum, stage_error = common.sha256_file(wav_stage)
  if not stage_checksum or stage_checksum:lower() ~= expected_checksum:lower() then
    os.remove(wav_stage)
    return false, "Destination WAV staging failed full-file SHA-256 verification: " .. tostring(stage_error or "content changed")
  end
  local saved, save_error = write_text(audit_stage, audit_text)
  if not saved or read_text(audit_stage) ~= audit_text then
    os.remove(wav_stage)
    os.remove(audit_stage)
    return false, "The matching audit could not be staged and verified: " .. tostring(save_error or "content changed")
  end
  if file_exists(output_path) or file_exists(audit_path) then
    os.remove(wav_stage)
    os.remove(audit_stage)
    return false, "The final filename became occupied while staging the pair."
  end
  local audit_moved, audit_error = os.rename(audit_stage, audit_path)
  if not audit_moved then
    os.remove(wav_stage)
    os.remove(audit_stage)
    return false, "Could not commit the audit before the WAV: " .. tostring(audit_error)
  end
  local wav_moved, move_error = os.rename(wav_stage, output_path)
  if not wav_moved then
    os.remove(audit_path)
    os.remove(wav_stage)
    return false, "Could not commit the WAV after its audit: " .. tostring(move_error)
  end
  -- The rename is within one destination volume, so these are the same fully
  -- hashed staged bytes under their final filename. Do not run a third slow
  -- pure-Lua SHA pass over a whole song just to verify a metadata rename.
  os.remove(temporary_path)
  return true, audit_path
end

local function validate_click_sample_path(path)
  if not path or path == "" or not file_exists(path) then return nil, "The configured click sample file does not exist." end
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then return nil, "REAPER could not open the configured click sample." end
  local length = reaper.GetMediaSourceLength(source)
  local rate = reaper.GetMediaSourceSampleRate(source)
  if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(source) end
  if not length or length < 0.003 then return nil, "The click sample is shorter than 3 ms." end
  if length > 2 then return nil, "The click sample is longer than 2 seconds; choose a single-hit sample." end
  if not rate or rate <= 0 then return nil, "The click sample has no valid sample rate." end
  return {length = length, sample_rate = rate}
end

function CLICK_MULTI.collect_ranges(project, start_time, end_time)
  local grouped = {}
  for _, marker in ipairs(common.collect_click_alt_markers(project)) do
    grouped[marker.label] = grouped[marker.label] or {}
    grouped[marker.label][#grouped[marker.label] + 1] = marker
  end

  local ranges, labels = {}, {}
  for label, markers in pairs(grouped) do
    if #markers % 2 ~= 0 then
      return nil, string.format(
        "Marker '%s' occurs %d time(s). Each alternate-click section needs an opening and closing marker with the same name.",
        label, #markers)
    end
    for index = 1, #markers, 2 do
      local opening, closing = markers[index], markers[index + 1]
      if closing.position <= opening.position + CLICK_MULTI.epsilon then
        return nil, string.format("The paired '%s' markers must be at different times.", label)
      end
      local clipped_start = math.max(opening.position, start_time)
      local clipped_end = math.min(closing.position, end_time)
      if clipped_end > clipped_start + CLICK_MULTI.epsilon then
        ranges[#ranges + 1] = {
          label = label,
          start_time = clipped_start,
          end_time = clipped_end,
          marker_start = opening.position,
          marker_end = closing.position,
        }
      end
    end
  end
  table.sort(ranges, function(left, right)
    if math.abs(left.start_time - right.start_time) > CLICK_MULTI.epsilon then
      return left.start_time < right.start_time
    end
    return left.end_time < right.end_time
  end)
  for index = 2, #ranges do
    local previous, current = ranges[index - 1], ranges[index]
    if current.start_time < previous.end_time - CLICK_MULTI.epsilon then
      return nil, string.format(
        "Alternate-click ranges overlap: '%s' (%.3f-%.3f) and '%s' (%.3f-%.3f). Move one marker pair so each click has exactly one sample.",
        previous.label, previous.marker_start, previous.marker_end,
        current.label, current.marker_start, current.marker_end)
    end
  end
  local seen = {}
  for _, range in ipairs(ranges) do
    if not seen[range.label] then labels[#labels + 1] = range.label; seen[range.label] = true end
  end
  table.sort(labels, function(left, right)
    local left_number = tonumber(left:match("(%d+)$")) or 0
    local right_number = tonumber(right:match("(%d+)$")) or 0
    if left_number ~= right_number then return left_number < right_number end
    return left < right
  end)
  return ranges, labels
end

function CLICK_MULTI.prepare_sample(path, label, allow_prompt)
  local details, problem = validate_click_sample_path(path)
  local display_label = label or "DEFAULT"
  if not details and TEST_MODE and not allow_prompt then
    error("A valid test click sample is required for " .. display_label .. ": " .. tostring(problem))
  end
  if not details then
    if path ~= "" then
      reaper.ShowMessageBox(tostring(problem) .. "\n\nChoose the replacement sample for " .. display_label .. " again.", SCRIPT_NAME, 0)
    end
    local ok
    ok, path = reaper.GetUserFileName(0, "Choose the single-hit sample for " .. display_label, "",
      "Audio files|*.wav;*.aif;*.aiff;*.flac|All files|*.*")
    if not ok then return nil end
    details, problem = validate_click_sample_path(path)
    if not details then
      reaper.ShowMessageBox(tostring(problem), SCRIPT_NAME, 0)
      return nil
    end
  end
  local checksum, checksum_error = common.sha256_file(path)
  if not checksum then
    reaper.ShowMessageBox("Could not checksum the click sample:\n\n" .. tostring(checksum_error), SCRIPT_NAME, 0)
    return nil
  end
  details.path = path
  details.checksum = checksum
  details.id = "CLK-" .. checksum:sub(1, 12):upper()
  details.filename = select(2, split_path(path))
  details.label = display_label
  if not TEST_MODE then
    local extension = path:match("(%.[^%.\\/]+)$") or ".wav"
    local cache_directory = join_path(join_path(join_path(reaper.GetResourcePath(), "Media"), "Bildibeat"), "ClickSamples")
    reaper.RecursiveCreateDirectory(cache_directory, 0)
    local cached_path = join_path(cache_directory, details.id .. extension:lower())
    if not file_exists(cached_path) then
      local copied, copy_error = copy_binary_file(path, cached_path)
      if not copied then
        reaper.ShowMessageBox("Could not create the durable click-sample cache:\n\n" .. tostring(copy_error), SCRIPT_NAME, 0)
        return nil
      end
    end
    local cached_checksum = common.sha256_file(cached_path)
    if cached_checksum ~= checksum then
      reaper.ShowMessageBox("The cached click sample failed its checksum verification.", SCRIPT_NAME, 0)
      return nil
    end
    details.original_path = path
    details.path = cached_path
  end
  return details
end

function CLICK_MULTI.choose_samples(project, start_time, end_time)
  local ranges, labels_or_problem = CLICK_MULTI.collect_ranges(project, start_time, end_time)
  if not ranges then
    reaper.ShowMessageBox("Alternate click markers are invalid.\n\n" .. tostring(labels_or_problem), SCRIPT_NAME, 0)
    return nil
  end
  local metronome, problem
  if TEST_MODE and TEST_METRONOME_A_PATH ~= "" and TEST_METRONOME_B_PATH ~= "" then
    metronome = {a = TEST_METRONOME_A_PATH, b = TEST_METRONOME_B_PATH, volume_a = 1, volume_b = 0.5}
  else
    metronome, problem = common.read_project_metronome(project)
  end
  if not metronome then
    reaper.ShowMessageBox("Could not read normal click samples.\n\n" .. tostring(problem), SCRIPT_NAME, 0)
    return nil
  end
  local a = CLICK_MULTI.prepare_sample(metronome.a, "METRONOME A", false)
  local b = CLICK_MULTI.prepare_sample(metronome.b, "METRONOME B", false)
  if not a or not b then
    reaper.ShowMessageBox("Both A and B in this project's Metronome and pre-roll settings must point to valid single-hit audio files. No show track was rendered.", SCRIPT_NAME, 0)
    return nil
  end
  local relative = (metronome.volume_a or 0) > 0 and (metronome.volume_b or 0) > 0
    and amp_to_db(metronome.volume_b / metronome.volume_a) or 0
  local alt
  if #ranges > 0 then
    local alt_path = TEST_ALT_SAMPLE_PATH ~= "" and TEST_ALT_SAMPLE_PATH
      or reaper.GetExtState(EXTSTATE_SECTION, CLICK_ALT_SAMPLE_EXT_KEY)
    if alt_path == "" and not TEST_MODE then
      -- Previous versions had one assignment per marker name. A unique old
      -- assignment can be migrated without guessing; conflicting ones cannot.
      local old = common.read_click_alt_sample_paths(EXTSTATE_SECTION, CLICK_MULTI.legacy_alt_key)
      local unique = {}
      for _, path in pairs(old) do
        if path ~= "" then unique[path] = true end
      end
      local count = 0
      for path in pairs(unique) do count = count + 1; alt_path = path end
      if count ~= 1 then alt_path = "" end
    end
    alt = CLICK_MULTI.prepare_sample(alt_path, "ALT", not TEST_MODE)
    if not alt then return nil end
    if not TEST_MODE then reaper.SetExtState(EXTSTATE_SECTION, CLICK_ALT_SAMPLE_EXT_KEY, alt.original_path or alt.path, true) end
  end
  return {a = a, b = b, alt = alt, ranges = ranges, labels = labels_or_problem,
    relative_b_db = clamp(relative, -24, 24)}
end

function CLICK_MULTI.normal_beat_type(project, hit_time)
  local beat = reaper.TimeMap2_timeToBeats(project, hit_time)
  local _, raw_pattern = reaper.TimeMap_GetMetronomePattern(project, hit_time, "EXTENDED")
  local pattern = tostring(raw_pattern or ""):upper():gsub("[^ABCD1234]", "")
  if pattern == "" then error("REAPER did not return a metronome A/B pattern for a detected CLICK hit.") end
  local index = (math.floor((tonumber(beat) or 0) + 0.5) % #pattern) + 1
  local kind = pattern:sub(index, index)
  return (kind == "A" or kind == "1") and "A" or "B", pattern, index
end

function CLICK_MULTI.sample_for_hit(settings, hit_time, project)
  for _, range in ipairs(settings.click_alt_ranges or {}) do
    if hit_time < range.start_time - CLICK_MULTI.epsilon then break end
    if hit_time >= range.start_time - CLICK_MULTI.epsilon
        and hit_time < range.end_time - CLICK_MULTI.epsilon then
      return settings.click_alt_sample, "ALT"
    end
  end
  local beat_type = CLICK_MULTI.normal_beat_type(project, hit_time)
  return beat_type == "A" and settings.click_sample_a or settings.click_sample_b,
    "METRONOME " .. beat_type
end

local function load_show_reference(output_path, profile_id)
  local directory = split_path(output_path)
  local path = join_path(directory, REFERENCE_FILENAME)
  local text = read_text(path)
  if not text then return nil end
  local reference = {
    path = path,
    source = text:match("Source:%s*([^\r\n]+)"),
    reference_id = text:match("Reference ID:%s*([%w%-]+)"),
    profile_id = text:match("Profile ID:%s*([%w%-]+)"),
    click_ratio = tonumber(text:match("Click advantage:%s*([%+%-]?[%d%.]+)")),
    left_crest = tonumber(text:match("Left crest:%s*([%+%-]?[%d%.]+)")),
    right_crest = tonumber(text:match("Right crest:%s*([%+%-]?[%d%.]+)")),
  }
  reference.left_low, reference.left_mid, reference.left_high = text:match("Left spectral:%s*low%s+([%d%.]+)%%%s*|%s*mid%s+([%d%.]+)%%%s*|%s*high%s+([%d%.]+)%%")
  reference.right_low, reference.right_mid, reference.right_high = text:match("Right spectral:%s*low%s+([%d%.]+)%%%s*|%s*mid%s+([%d%.]+)%%%s*|%s*high%s+([%d%.]+)%%")
  for _, key in ipairs({"left_low","left_mid","left_high","right_low","right_mid","right_high"}) do reference[key] = tonumber(reference[key]) end
  reference.compatible = not reference.profile_id or reference.profile_id == "UNKNOWN" or reference.profile_id == profile_id
  return reference
end

local function spectral_difference_db(current, reference)
  if not current or not reference or reference <= 0 then return nil end
  return 10 * math.log(math.max(current, 0.0001) / math.max(reference, 0.0001), 10)
end

local function reference_match_warnings(analysis, settings)
  local reference = settings.reference
  if not reference then return {} end
  local warnings = {}
  if not reference.compatible then
    warnings[#warnings + 1] = string.format("Reference profile %s does not match render profile %s; tonal comparison was skipped.", reference.profile_id or "UNKNOWN", settings.profile_id)
    return warnings
  end
  local comparisons = {
    {"left low", analysis.left.low_pct, reference.left_low}, {"left mid", analysis.left.mid_pct, reference.left_mid},
    {"left high", analysis.left.high_pct, reference.left_high}, {"right low", analysis.right.low_pct, reference.right_low},
    {"right mid", analysis.right.mid_pct, reference.right_mid}, {"right high", analysis.right.high_pct, reference.right_high},
  }
  for _, comparison in ipairs(comparisons) do
    if not (analysis.right.silent and comparison[1]:find("right", 1, true)) then
      local difference = spectral_difference_db(comparison[2], comparison[3])
      if difference and math.abs(difference) > 4 then
        warnings[#warnings + 1] = string.format("Reference spectral deviation: %s is %+.1f dB from the approved reference.", comparison[1], difference)
      end
    end
  end
  if reference.left_crest and math.abs((analysis.left.crest_db or 0) - reference.left_crest) > 4 then
    warnings[#warnings + 1] = string.format("Left crest factor differs from the approved reference by %+.1f dB.", analysis.left.crest_db - reference.left_crest)
  end
  if not analysis.right.silent and reference.right_crest and math.abs((analysis.right.crest_db or 0) - reference.right_crest) > 4 then
    warnings[#warnings + 1] = string.format("Right crest factor differs from the approved reference by %+.1f dB.", analysis.right.crest_db - reference.right_crest)
  end
  if reference.click_ratio and settings.final_click_ratio and math.abs(settings.final_click_ratio - reference.click_ratio) > 0.75 then
    warnings[#warnings + 1] = string.format("Click/backing ratio differs from the approved reference by %+.2f dB.", settings.final_click_ratio - reference.click_ratio)
  end
  return warnings
end

local function scan_project(project)
  local candidates = {}
  local by_role = {CLICK = {}, BACKING = {}, FOH = {}}
  local conflict_candidates = {}
  local unlabeled_audio = {}
  for index = 0, reaper.CountTracks(project) - 1 do
    local track = reaper.GetTrack(project, index)
    if track_ext(track, BUS_EXT_KEY) == "" then
      local name = track_name(track)
      local role, conflict = classify_name(name)
      if conflict then
        conflict_candidates[#conflict_candidates + 1] = {
          message = string.format("Track %d: %s (%s)", index + 1, name, conflict),
          soloed = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0,
        }
      elseif role then
        local priority, priority_conflict
        if role == "FOH" then priority, priority_conflict = classify_foh_priority(name) end
        local intent_offset, offset_conflict = classify_intent_offset(name)
        if role == "CLICK" and intent_offset and math.abs(intent_offset) > EPS then
          offset_conflict = "signed intent offsets apply only to BACKING and FOH tracks"
        end
        if priority_conflict or offset_conflict then
          conflict_candidates[#conflict_candidates + 1] = {
            message = string.format("Track %d: %s (%s)", index + 1, name,
              priority_conflict and ("FOH priority conflict: " .. priority_conflict) or offset_conflict),
            soloed = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0,
          }
        else
          candidates[#candidates + 1] = {
            track = track,
            name = name,
            role = role,
            priority = priority,
            intent_offset = intent_offset or 0,
            index = index + 1,
            soloed = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0,
          }
        end
      elseif count_track_items(track) > 0 then
        unlabeled_audio[#unlabeled_audio + 1] = string.format("Track %d: %s", index + 1, name)
      end
    end
  end

  local solo_filter = false
  for _, record in ipairs(candidates) do solo_filter = solo_filter or record.soloed end
  for _, conflict in ipairs(conflict_candidates) do solo_filter = solo_filter or conflict.soloed end

  local records, conflicts, excluded_labeled, excluded_clicks = {}, {}, {}, {}
  for _, record in ipairs(candidates) do
    if not solo_filter or record.soloed then
      records[#records + 1] = record
      by_role[record.role][#by_role[record.role] + 1] = record
    else
      excluded_labeled[#excluded_labeled + 1] = string.format("Track %d: %s", record.index, record.name)
      if record.role == "CLICK" then
        excluded_clicks[#excluded_clicks + 1] = string.format("Track %d: %s", record.index, record.name)
      end
    end
  end
  for _, conflict in ipairs(conflict_candidates) do
    if not solo_filter or conflict.soloed then conflicts[#conflicts + 1] = conflict.message end
  end
  return records, by_role, conflicts, unlabeled_audio, solo_filter, excluded_labeled, excluded_clicks
end

local function selected_time_bounds(project)
  local start_time, end_time = reaper.GetSet_LoopTimeRange2(project, false, false, 0, 0, false)
  if not start_time or not end_time or end_time <= start_time then return nil end
  return math.max(0, start_time), end_time
end

local function disable_envelopes(track)
  for index = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local envelope = reaper.GetTrackEnvelope(track, index)
    reaper.GetSetEnvelopeInfo_String(envelope, "ACTIVE", "0", true)
    reaper.GetSetEnvelopeInfo_String(envelope, "ARM", "0", true)
  end
end

local function disable_take_envelopes(take)
  for index = 0, reaper.CountTakeEnvelopes(take) - 1 do
    local envelope = reaper.GetTakeEnvelope(take, index)
    reaper.GetSetEnvelopeInfo_String(envelope, "ACTIVE", "0", true)
    reaper.GetSetEnvelopeInfo_String(envelope, "ARM", "0", true)
  end
end

local function is_processor_fx(track, index)
  local _, name = reaper.TrackFX_GetFXName(track, index, "")
  name = tostring(name or "")
  return name:find("[BILDI]", 1, true) ~= nil
      or name:find(PROCESSOR_FX_NAME, 1, true) ~= nil
      or name:find("Bildibeat_Show_Processor_v1", 1, true) ~= nil
end

local function remove_generated_processors(track)
  for index = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
    if is_processor_fx(track, index) then reaper.TrackFX_Delete(track, index) end
  end
end

local function bypass_existing_fx(track)
  remove_generated_processors(track)
  for index = 0, reaper.TrackFX_GetCount(track) - 1 do
    reaper.TrackFX_SetEnabled(track, index, false)
  end
end

local function remove_track_sends(track)
  for _, category in ipairs({0, 1}) do
    for index = reaper.GetTrackNumSends(track, category) - 1, 0, -1 do
      reaper.RemoveTrackSend(track, category, index)
    end
  end
end

local function delete_generated_buses(project)
  for index = reaper.CountTracks(project) - 1, 0, -1 do
    local track = reaper.GetTrack(project, index)
    if track_ext(track, BUS_EXT_KEY) ~= "" then reaper.DeleteTrack(track) end
  end
end

-- The processing graph is intentionally temporary.  Capture every original
-- track as a complete REAPER state chunk before touching faders, sends, FX,
-- items, envelopes, or take sources.  Restoring chunks is substantially safer
-- than trying to reverse dozens of individual mutations and remains correct if
-- a render is cancelled or a later verification step throws an exception.
PROJECT_NUMBER_FIELDS = {
  "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS",
  "RENDER_CHANNELS", "RENDER_SRATE", "RENDER_NORMALIZE", "RENDER_DITHER",
  "RENDER_ADDTOPROJ", "RENDER_TAILFLAG",
}
PROJECT_STRING_FIELDS = {
  "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2",
  "RENDER_METADATA",
}

function capture_project_snapshot(project)
  if not reaper.GetTrackStateChunk or not reaper.SetTrackStateChunk then
    return nil, "This REAPER build cannot snapshot and restore track routing safely."
  end
  local snapshot = {tracks = {}, numbers = {}, strings = {}}
  for index = 0, reaper.CountTracks(project) - 1 do
    local track = reaper.GetTrack(project, index)
    local ok, chunk = reaper.GetTrackStateChunk(track, "", false)
    if not ok or not chunk or chunk == "" then
      return nil, string.format("Could not snapshot original track %d before processing.", index + 1)
    end
    local entry = {
      track = track,
      chunk = chunk,
      index = index,
      fx_chain_enabled = reaper.GetMediaTrackInfo_Value(track, "I_FXEN"),
      fx_enabled = {},
      fx_offline = {},
      fx_guid_set = {},
    }
    for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
      entry.fx_enabled[fx + 1] = reaper.TrackFX_GetEnabled(track, fx)
      if reaper.TrackFX_GetOffline then entry.fx_offline[fx + 1] = reaper.TrackFX_GetOffline(track, fx) end
      if reaper.TrackFX_GetFXGUID then
        local guid = reaper.TrackFX_GetFXGUID(track, fx)
        if guid and guid ~= "" then entry.fx_guid_set[guid] = true end
      end
    end
    snapshot.tracks[#snapshot.tracks + 1] = entry
  end
  local master = reaper.GetMasterTrack(project)
  if master then
    local ok, chunk = reaper.GetTrackStateChunk(master, "", false)
    if ok and chunk and chunk ~= "" then snapshot.master = {track = master, chunk = chunk} end
  end
  for _, key in ipairs(PROJECT_NUMBER_FIELDS) do
    snapshot.numbers[key] = reaper.GetSetProjectInfo(project, key, 0, false)
  end
  for _, key in ipairs(PROJECT_STRING_FIELDS) do
    local _, value = reaper.GetSetProjectInfo_String(project, key, "", false)
    snapshot.strings[key] = value or ""
  end
  snapshot.time_start, snapshot.time_end =
    reaper.GetSet_LoopTimeRange2(project, false, false, 0, 0, false)
  snapshot.edit_cursor = reaper.GetCursorPosition and reaper.GetCursorPosition() or nil
  return snapshot
end

function restore_project_snapshot(project, settings)
  local snapshot = settings and settings.project_snapshot
  if not snapshot or settings.project_snapshot_restored then return true end
  local problems = {}
  reaper.PreventUIRefresh(1)

  -- Generated tracks must disappear before the original chunks re-establish
  -- their old send indexes and folder topology.
  delete_generated_buses(project)
  for _, entry in ipairs(snapshot.tracks or {}) do
    if reaper.ValidatePtr2(project, entry.track, "MediaTrack*") then
      -- Remove every FX instance created during this transaction while its
      -- live GUID is still intact. REAPER may otherwise retain added FX when
      -- a saved state chunk is applied to the existing track object.
      local original_fx_count = #(entry.fx_enabled or {})
      for fx = reaper.TrackFX_GetCount(entry.track) - 1, 0, -1 do
        local guid = (reaper.TrackFX_GetFXGUID and reaper.TrackFX_GetFXGUID(entry.track, fx)) or ""
        local is_new = guid ~= "" and not entry.fx_guid_set[guid]
        if guid == "" then is_new = fx >= original_fx_count end
        if is_new then reaper.TrackFX_Delete(entry.track, fx) end
      end
      local ok = reaper.SetTrackStateChunk(entry.track, entry.chunk, false)
      if not ok then problems[#problems + 1] = string.format("track %d", entry.index + 1) end
      -- REAPER can retain the live bypass/offline cache after replacing a
      -- track chunk.  Reassert those flags explicitly so the restored chain
      -- behaves exactly as it did before the app ran.
      reaper.SetMediaTrackInfo_Value(entry.track, "I_FXEN", entry.fx_chain_enabled or 0)
      local restored_fx_count = reaper.TrackFX_GetCount(entry.track)
      for fx = 0, math.min(restored_fx_count, #(entry.fx_enabled or {})) - 1 do
        reaper.TrackFX_SetEnabled(entry.track, fx, entry.fx_enabled[fx + 1])
        if reaper.TrackFX_SetOffline and entry.fx_offline[fx + 1] ~= nil then
          reaper.TrackFX_SetOffline(entry.track, fx, entry.fx_offline[fx + 1])
        end
      end
    else
      problems[#problems + 1] = string.format("missing original track %d", entry.index + 1)
    end
  end
  if snapshot.master and reaper.ValidatePtr2(project, snapshot.master.track, "MediaTrack*") then
    if not reaper.SetTrackStateChunk(snapshot.master.track, snapshot.master.chunk, false) then
      problems[#problems + 1] = "master track"
    end
  end
  for _, key in ipairs(PROJECT_NUMBER_FIELDS) do
    if snapshot.numbers[key] ~= nil then
      reaper.GetSetProjectInfo(project, key, snapshot.numbers[key], true)
    end
  end
  for _, key in ipairs(PROJECT_STRING_FIELDS) do
    if snapshot.strings[key] ~= nil then
      reaper.GetSetProjectInfo_String(project, key, snapshot.strings[key], true)
    end
  end
  if snapshot.time_start and snapshot.time_end then
    reaper.GetSet_LoopTimeRange2(project, true, false, snapshot.time_start, snapshot.time_end, false)
  end
  if snapshot.edit_cursor and reaper.SetEditCurPos then
    reaper.SetEditCurPos(snapshot.edit_cursor, false, false)
  end

  settings.project_snapshot_restored = true
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  if #problems > 0 then
    return false, "Original project restoration was incomplete: " .. table.concat(problems, ", ")
  end
  return true
end

function finish_project_transaction(project, settings)
  local ok, problem = restore_project_snapshot(project, settings)
  if not ok then
    console("PROJECT RESTORE WARNING: " .. tostring(problem))
    return false, problem
  end
  return true
end

local function sanitize_source_track(record)
  local track = record.track
  bypass_existing_fx(track)
  remove_track_sends(track)
  disable_envelopes(track)
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", 1)
  reaper.SetMediaTrackInfo_Value(track, "D_WIDTH", 1)
  -- Keep the source centered while its raw L/R phase relationship is measured.
  -- Routing is pre-pan, and the visible role pan is restored after analysis.
  reaper.SetMediaTrackInfo_Value(track, "D_PAN", 0)
  reaper.SetMediaTrackInfo_Value(track, "D_PANLAW", 1)
  reaper.SetMediaTrackInfo_Value(track, "I_PANMODE", 3)
  reaper.SetMediaTrackInfo_Value(track, "B_PHASE", 0)
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
  reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
  reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 0)
  reaper.SetMediaTrackInfo_Value(track, "I_FXEN", 1)
  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
  reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", record.role == "FOH" and 4 or 2)
  set_track_ext(track, ROLE_EXT_KEY, record.role)

  for item_index = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, item_index)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", 1)
    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
    for take_index = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, take_index)
      if take then
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 1)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", 0)
        reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", 0)
        for fx = 0, reaper.TakeFX_GetCount(take) - 1 do reaper.TakeFX_SetEnabled(take, fx, false) end
        disable_take_envelopes(take)
      end
    end
  end
end

-- Copy labeled media from removable/network volumes into REAPER's durable local
-- media cache and repoint the in-memory takes before any analysis. This makes
-- the complete build independent of an external drive after preparation and
-- prevents a mid-render disconnect from becoming a silent WAV.
function stage_external_source_media(project, records, settings)
  local work_root = local_work_root()
  local local_volume = work_root:match("^([A-Za-z]:)")
  local stage_directory = join_path(join_path(work_root, "Media"), "ShowStage")
  reaper.RecursiveCreateDirectory(stage_directory, 0)
  local staged_by_source, staged_count, staged_bytes, staged_takes = {}, 0, 0, 0

  for record_index, record in ipairs(records) do
    progress_update("Staging show media locally",
      string.format("%d of %d: %s", record_index, #records, record.name),
      0.025 + 0.025 * record_index / math.max(1, #records), true)
    progress_abort_if_requested()
    for item_index = 0, reaper.CountTrackMediaItems(record.track) - 1 do
      local item = reaper.GetTrackMediaItem(record.track, item_index)
      for take_index = 0, reaper.CountTakes(item) - 1 do
        local take = reaper.GetTake(item, take_index)
        if take and (not reaper.TakeIsMIDI or not reaper.TakeIsMIDI(take)) then
          local source = reaper.GetMediaItemTake_Source(take)
          local source_path = source and tostring(reaper.GetMediaSourceFileName(source) or "") or ""
          local source_volume = source_path:match("^([A-Za-z]:)")
          local external = source_path ~= "" and (not local_volume or not source_volume
            or source_volume:lower() ~= local_volume:lower())
          if external then
            local staged_path = staged_by_source[source_path]
            if not staged_path then
              local size = source_file_size(source_path)
              if size <= 0 then
                error(string.format(
                  "E_SOURCE_OFFLINE: %s needs media on an unavailable external/network volume:\n%s\n\nReconnect the volume and rerun. The app stopped before rendering silence.",
                  record.name, source_path))
              end
              local source_fingerprint, fingerprint_error = file_probe_fingerprint(source_path, true)
              if not source_fingerprint then
                error(string.format(
                  "E_SOURCE_UNSTABLE: %s could not be read consistently from its source volume:\n%s\n\n%s",
                  record.name, source_path, tostring(fingerprint_error)))
              end
              local _, leaf = split_path(source_path)
              local extension = leaf:match("(%.[^%.\\/]+)$") or ".media"
              local key = common.sha256_string(source_path:lower() .. "|" .. tostring(size) .. "|" ..
                source_fingerprint):sub(1, 20):upper()
              staged_path = join_path(stage_directory, "SRC-" .. key .. extension:lower())
              local staged_fingerprint = source_file_size(staged_path) == size
                and file_probe_fingerprint(staged_path, true) or nil
              if staged_fingerprint ~= source_fingerprint then
                os.remove(staged_path)
                local copied, copy_error = copy_file(source_path, staged_path)
                local verified_fingerprint = copied and source_file_size(staged_path) == size
                  and file_probe_fingerprint(staged_path, true) or nil
                if not copied or verified_fingerprint ~= source_fingerprint then
                  os.remove(staged_path)
                  error(string.format(
                    "E_SOURCE_STAGE: Could not make a complete local working copy for %s:\n%s\n\n%s",
                    record.name, source_path, tostring(copy_error or "copied content fingerprint did not match")))
                end
                staged_count = staged_count + 1
                staged_bytes = staged_bytes + size
              end
              staged_by_source[source_path] = staged_path
            end
            local staged_source = reaper.PCM_Source_CreateFromFile(staged_path)
            if not staged_source or (reaper.GetMediaSourceLength(staged_source) or 0) <= 0 then
              error("E_SOURCE_STAGE_OPEN: REAPER could not open the local staged copy:\n" .. staged_path)
            end
            reaper.SetMediaItemTake_Source(take, staged_source)
            reaper.UpdateItemInProject(item)
            record.staged_media = (record.staged_media or 0) + 1
            staged_takes = staged_takes + 1
          end
        end
      end
    end
  end
  settings.staged_media_files = staged_count
  settings.staged_media_bytes = staged_bytes
  settings.staged_media_takes = staged_takes
  settings.staged_media_directory = stage_directory
  if next(staged_by_source) then
    append_repair(settings, string.format(
      "External-volume protection repointed labeled takes to local staged media (%d new file(s), %.1f MB copied); final rendering no longer depends on the external source drive.",
      staged_count, staged_bytes / 1048576))
  end
  return true
end

local function apply_role_pan(record)
  reaper.SetMediaTrackInfo_Value(record.track, "D_PAN", record.role == "FOH" and 1 or -1)
end

local function sanitize_master(project)
  local master = reaper.GetMasterTrack(project)
  bypass_existing_fx(master)
  disable_envelopes(master)
  reaper.SetMediaTrackInfo_Value(master, "D_VOL", 1)
  reaper.SetMediaTrackInfo_Value(master, "D_PAN", 0)
  reaper.SetMediaTrackInfo_Value(master, "D_WIDTH", 1)
  reaper.SetMediaTrackInfo_Value(master, "I_AUTOMODE", 0)
  reaper.SetMediaTrackInfo_Value(master, "I_FXEN", 1)
end

local function isolate_labeled_sources(project, records)
  local labeled = {}
  for _, record in ipairs(records) do labeled[record.track] = true end
  for index = 0, reaper.CountTracks(project) - 1 do
    local track = reaper.GetTrack(project, index)
    -- Solo has already been translated into an inclusion filter by scan_project.
    -- Clear the live solo state so the rebuilt buses cannot be muted by it.
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
    if not labeled[track] and track_ext(track, BUS_EXT_KEY) == "" then
      reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
    end
  end
  -- Remove every pre-existing send whose destination is a labeled source.
  for source_index = 0, reaper.CountTracks(project) - 1 do
    local source = reaper.GetTrack(project, source_index)
    for send_index = reaper.GetTrackNumSends(source, 0) - 1, 0, -1 do
      local destination = reaper.GetTrackSendInfo_Value(source, 0, send_index, "P_DESTTRACK")
      if labeled[destination] then reaper.RemoveTrackSend(source, 0, send_index) end
    end
  end
end

local function percentile(values, fraction)
  if #values == 0 then return nil end
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  table.sort(copy)
  local position = 1 + (#copy - 1) * fraction
  local lower = math.floor(position)
  local upper = math.ceil(position)
  if lower == upper then return copy[lower] end
  local mix = position - lower
  return copy[lower] * (1 - mix) + copy[upper] * mix
end

local DOWNMIX_MODES = {
  sum = {id = 1, analysis_mode = "mono", label = "normal L+R mono"},
  left = {id = 2, analysis_mode = "left", label = "left-channel safety fallback"},
  right = {id = 3, analysis_mode = "right", label = "right-channel safety fallback"},
  difference = {id = 4, analysis_mode = "difference", label = "phase-corrected L-R fold"},
}

-- Choose one stable mono path for a complete BACKING or FOH source. Normal
-- L+R remains preferred for ordinary stereo. A one-channel fallback is safer
-- than trying to repair complex, changing phase relationships. The L-R mode
-- is reserved for nearly pure polarity inversion, where it is deterministic
-- and cannot unpredictably remove normal centre information.
local function select_downmix_mode(profile)
  profile = profile or {}
  local left_rms = math.max(0, profile.left_rms or 0)
  local right_rms = math.max(0, profile.right_rms or 0)
  local sum_rms = math.max(0, profile.sum_rms or 0)
  local difference_rms = math.max(0, profile.difference_rms or 0)
  local reference = math.max(left_rms, right_rms)
  local correlation = profile.correlation
  local risk_fraction = clamp(profile.risk_fraction or 0, 0, 1)
  local fold_loss_db = reference > EPS and amp_to_db(sum_rms / reference) or -math.huge
  local difference_loss_db = reference > EPS and amp_to_db(difference_rms / reference) or -math.huge
  local balance_db = left_rms > EPS and right_rms > EPS
    and math.abs(amp_to_db(left_rms / right_rms)) or math.huge
  local mode, reason

  if reference < 1e-7 then
    mode, reason = "sum", "source is below the measurable downmix floor"
  elseif left_rms < reference * 0.001 then
    mode, reason = "right", "left source channel is effectively silent"
  elseif right_rms < reference * 0.001 then
    mode, reason = "left", "right source channel is effectively silent"
  else
    local global_cancellation = correlation and correlation < -0.25 and fold_loss_db < -6
    local repeated_cancellation = risk_fraction >= 0.15
    if not global_cancellation and not repeated_cancellation then
      mode, reason = "sum", "normal stereo fold is phase-safe"
    elseif correlation and correlation <= -0.90 and fold_loss_db <= -12
        and risk_fraction >= 0.75 and balance_db <= 1.5 and difference_loss_db >= -0.75 then
      mode, reason = "difference", "channels are consistently balanced and polarity-inverted"
    else
      local left_coverage = clamp(profile.left_coverage or 0, 0, 1)
      local right_coverage = clamp(profile.right_coverage or 0, 0, 1)
      local left_clipped = clamp(profile.left_clip_fraction or 0, 0, 1)
      local right_clipped = clamp(profile.right_clip_fraction or 0, 0, 1)
      local left_db = amp_to_db(left_rms)
      local right_db = amp_to_db(right_rms)
      if left_clipped < right_clipped * 0.25 and left_db >= right_db - 6 then
        mode, reason = "left", "left channel has materially less clipping"
      elseif right_clipped < left_clipped * 0.25 and right_db >= left_db - 6 then
        mode, reason = "right", "right channel has materially less clipping"
      elseif left_coverage > right_coverage + 0.05 then
        mode, reason = "left", "left channel preserves more active passages"
      elseif right_coverage > left_coverage + 0.05 then
        mode, reason = "right", "right channel preserves more active passages"
      elseif right_rms > left_rms then
        mode, reason = "right", "right channel is the stronger complete fallback"
      else
        mode, reason = "left", "left channel is the stronger complete fallback"
      end
    end
  end

  local definition = DOWNMIX_MODES[mode]
  return {
    mode = mode,
    mode_id = definition.id,
    analysis_mode = definition.analysis_mode,
    label = definition.label,
    reason = reason,
    correlation = correlation,
    fold_loss_db = fold_loss_db,
    difference_loss_db = difference_loss_db,
    channel_balance_db = balance_db,
    risk_fraction = risk_fraction,
    active_windows = profile.active_windows or 0,
    risk_windows = profile.risk_windows or 0,
    left_coverage = profile.left_coverage or 0,
    right_coverage = profile.right_coverage or 0,
  }
end

-- This is a deliberately light, single-pass phase preflight. It runs at
-- 24 kHz and stores only block statistics; the full 48 kHz loudness/spectrum
-- analyzer then runs once using the selected mono path.
local function analyze_downmix_profile(track, start_time, end_time)
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then error("Could not create a phase-analysis accessor for " .. track_name(track)) end
  local buffer = reaper.new_array(DOWNMIX_BLOCK * 2)
  local blocks = {}
  local total = {count = 0, left = 0, right = 0, sum = 0, difference = 0,
    cross = 0, left_sum = 0, right_sum = 0, left_clipped = 0, right_clipped = 0}
  local position = start_time
  while position < end_time - 0.5 / DOWNMIX_ANALYSIS_RATE do
    local samples = math.min(DOWNMIX_BLOCK, math.ceil((end_time - position) * DOWNMIX_ANALYSIS_RATE))
    buffer.clear()
    local result = reaper.GetAudioAccessorSamples(accessor, DOWNMIX_ANALYSIS_RATE, 2, position, samples, buffer)
    if result < 0 then
      reaper.DestroyAudioAccessor(accessor)
      error("Phase-aware downmix analysis failed for " .. track_name(track))
    end
    local values = buffer.table(1, samples * 2)
    local block = {count = samples, left = 0, right = 0, sum = 0, difference = 0,
      cross = 0, left_sum = 0, right_sum = 0}
    for sample = 1, samples do
      local left = values[(sample - 1) * 2 + 1] or 0
      local right = values[(sample - 1) * 2 + 2] or 0
      local sum = (left + right) * 0.5
      local difference = (left - right) * 0.5
      block.left = block.left + left * left
      block.right = block.right + right * right
      block.sum = block.sum + sum * sum
      block.difference = block.difference + difference * difference
      block.cross = block.cross + left * right
      block.left_sum = block.left_sum + left
      block.right_sum = block.right_sum + right
      if math.abs(left) >= 0.999 then total.left_clipped = total.left_clipped + 1 end
      if math.abs(right) >= 0.999 then total.right_clipped = total.right_clipped + 1 end
    end
    blocks[#blocks + 1] = block
    for _, key in ipairs({"left", "right", "sum", "difference", "cross", "left_sum", "right_sum"}) do
      total[key] = total[key] + block[key]
    end
    total.count = total.count + samples
    position = position + samples / DOWNMIX_ANALYSIS_RATE
  end
  reaper.DestroyAudioAccessor(accessor)

  local count = math.max(total.count, 1)
  local left_rms = math.sqrt(total.left / count)
  local right_rms = math.sqrt(total.right / count)
  local sum_rms = math.sqrt(total.sum / count)
  local difference_rms = math.sqrt(total.difference / count)
  local left_mean, right_mean = total.left_sum / count, total.right_sum / count
  local left_variance = math.max(0, total.left / count - left_mean * left_mean)
  local right_variance = math.max(0, total.right / count - right_mean * right_mean)
  local covariance = total.cross / count - left_mean * right_mean
  local correlation = left_variance > EPS and right_variance > EPS
    and clamp(covariance / math.sqrt(left_variance * right_variance), -1, 1) or nil
  local reference = math.max(left_rms, right_rms)
  local activity_floor = math.max(1e-7, reference * 0.001)
  local active_windows, risk_windows, left_coverage, right_coverage = 0, 0, 0, 0
  for _, block in ipairs(blocks) do
    local block_count = math.max(block.count, 1)
    local block_left = math.sqrt(block.left / block_count)
    local block_right = math.sqrt(block.right / block_count)
    local block_reference = math.max(block_left, block_right)
    if block_reference >= activity_floor then
      active_windows = active_windows + 1
      if block_left >= block_reference * 0.25 then left_coverage = left_coverage + 1 end
      if block_right >= block_reference * 0.25 then right_coverage = right_coverage + 1 end
      local block_sum = math.sqrt(block.sum / block_count)
      local block_left_mean, block_right_mean = block.left_sum / block_count, block.right_sum / block_count
      local block_left_variance = math.max(0, block.left / block_count - block_left_mean * block_left_mean)
      local block_right_variance = math.max(0, block.right / block_count - block_right_mean * block_right_mean)
      local block_covariance = block.cross / block_count - block_left_mean * block_right_mean
      local block_correlation = block_left_variance > EPS and block_right_variance > EPS
        and block_covariance / math.sqrt(block_left_variance * block_right_variance) or nil
      local block_fold_loss = amp_to_db(block_sum / math.max(block_reference, EPS))
      if block_correlation and block_correlation < -0.25 and block_fold_loss < -6 then
        risk_windows = risk_windows + 1
      end
    end
  end
  return {
    left_rms = left_rms,
    right_rms = right_rms,
    sum_rms = sum_rms,
    difference_rms = difference_rms,
    correlation = correlation,
    active_windows = active_windows,
    risk_windows = risk_windows,
    risk_fraction = active_windows > 0 and risk_windows / active_windows or 0,
    left_coverage = active_windows > 0 and left_coverage / active_windows or 0,
    right_coverage = active_windows > 0 and right_coverage / active_windows or 0,
    left_clip_fraction = total.left_clipped / count,
    right_clip_fraction = total.right_clipped / count,
  }
end

local function loudness_from_chunks(chunks)
  local block_energies, block_loudness = {}, {}
  for index = 4, #chunks do
    local energy = (chunks[index] + chunks[index - 1] + chunks[index - 2] + chunks[index - 3]) / 4
    local loudness = energy > EPS and (-0.691 + 10 * math.log(energy, 10)) or -math.huge
    block_energies[#block_energies + 1] = energy
    block_loudness[#block_loudness + 1] = loudness
  end
  local absolute = {}
  local absolute_sum = 0
  for index, value in ipairs(block_loudness) do
    if value >= -70 then absolute[#absolute + 1] = index; absolute_sum = absolute_sum + block_energies[index] end
  end
  if #absolute == 0 then return -math.huge, -math.huge, 0 end
  local absolute_mean = absolute_sum / #absolute
  local relative_gate = -0.691 + 10 * math.log(math.max(absolute_mean, EPS), 10) - 10
  local gate = math.max(-70, relative_gate)
  local gated_energy, gated_loudness, gated_sum = {}, {}, 0
  for index, value in ipairs(block_loudness) do
    if value >= gate then
      gated_energy[#gated_energy + 1] = block_energies[index]
      gated_loudness[#gated_loudness + 1] = value
      gated_sum = gated_sum + block_energies[index]
    end
  end
  if #gated_energy == 0 then return -math.huge, -math.huge, 0 end
  local integrated = -0.691 + 10 * math.log(math.max(gated_sum / #gated_energy, EPS), 10)
  local active = percentile(gated_loudness, 0.50) or integrated

  local short_values = {}
  if #chunks >= 30 then
    for index = 30, #chunks, 10 do
      local sum = 0
      for offset = 0, 29 do sum = sum + chunks[index - offset] end
      local energy = sum / 30
      local value = energy > EPS and (-0.691 + 10 * math.log(energy, 10)) or -math.huge
      if value >= integrated - 10 then short_values[#short_values + 1] = value end
    end
  end
  local range = 0
  if #short_values >= 2 then
    range = (percentile(short_values, 0.90) or 0) - (percentile(short_values, 0.10) or 0)
  end
  return integrated, active, range
end

-- Smooth and slew-limit every contiguous active passage in both directions.
-- The resulting curve cannot chase drums or syllables: at the default
-- one-second map resolution it may move no faster than 0.60 dB per second.
-- Inactive/silent points remain exactly unity and split independent passages.
function stabilize_passage_gains(gains, active, step_seconds, maximum_absolute)
  local smoothed, result = {}, {}
  local radius = ANTI_PUMP_MAP_SMOOTH_RADIUS
  for index = 1, #gains do
    if active[index] then
      local sum, weight_sum = 0, 0
      for neighbour = math.max(1, index - radius), math.min(#gains, index + radius) do
        local contiguous = active[neighbour]
        if contiguous then
          local first, last = math.min(index, neighbour), math.max(index, neighbour)
          for cursor = first, last do
            if not active[cursor] then contiguous = false; break end
          end
        end
        if contiguous then
          local weight = radius + 1 - math.abs(neighbour - index)
          sum, weight_sum = sum + (gains[neighbour] or 0) * weight, weight_sum + weight
        end
      end
      smoothed[index] = clamp(weight_sum > 0 and sum / weight_sum or gains[index] or 0,
        -maximum_absolute, maximum_absolute)
    else
      smoothed[index] = 0
    end
  end
  for index = 1, #smoothed do result[index] = smoothed[index] end
  local allowed = ANTI_PUMP_MAP_SLEW_DB_PER_SECOND * math.max(step_seconds or 1, 0.1)
  for _ = 1, 2 do
    local previous
    for index = 1, #result do
      if active[index] then
        if previous then result[index] = clamp(result[index], previous - allowed, previous + allowed) end
        previous = result[index]
      else
        result[index], previous = 0, nil
      end
    end
    local following
    for index = #result, 1, -1 do
      if active[index] then
        if following then result[index] = clamp(result[index], following - allowed, following + allowed) end
        following = result[index]
      else
        result[index], following = 0, nil
      end
    end
  end
  return result
end

-- Build a deterministic offline gain map from the raw, pre-FX analysis.  Each
-- point represents at least one second.  A point below both the programme gate
-- and the fixed noise-floor gate receives exactly 0 dB: intentional rests are
-- neither boosted nor classified as faults.  Active-point gain changes are
-- smoothed and slew-limited so the map cannot create audible gain jumps.
local function build_passage_map(chunks, start_time, end_time, integrated_lufs)
  local duration = math.max(0.001, end_time - start_time)
  local chunks_per_point = math.max(10, math.ceil(#chunks / math.max(PASSAGE_MAP_MAX_POINTS, 1)))
  local step_seconds = chunks_per_point * 0.1
  local points, active_values = {}, {}
  local gate = finite(integrated_lufs) and math.max(-60, integrated_lufs - 18) or -60
  local cursor = 1
  while cursor <= #chunks do
    local finish = math.min(#chunks, cursor + chunks_per_point - 1)
    local sum = 0
    for index = cursor, finish do sum = sum + (chunks[index] or 0) end
    local energy = sum / math.max(1, finish - cursor + 1)
    local lufs = energy > EPS and (-0.691 + 10 * math.log(energy, 10)) or -math.huge
    local active = finite(lufs) and lufs >= gate
    points[#points + 1] = {lufs = lufs, active = active, gain_db = 0}
    if active then active_values[#active_values + 1] = lufs end
    cursor = finish + 1
  end
  if #points == 0 then points[1] = {lufs = -math.huge, active = false, gain_db = 0} end
  local target = percentile(active_values, 0.50) or integrated_lufs
  if finite(target) then
    for _, point in ipairs(points) do
      if point.active then point.gain_db = clamp(target - point.lufs, -6, 9) end
    end
    local raw_gains, active = {}, {}
    for index, point in ipairs(points) do
      raw_gains[index], active[index] = point.gain_db, point.active
    end
    local stable = stabilize_passage_gains(raw_gains, active, step_seconds, 9)
    for index, point in ipairs(points) do point.gain_db = stable[index] end
  end
  local gains, active_flags, corrected = {}, {}, 0
  for index, point in ipairs(points) do
    gains[index] = point.gain_db
    active_flags[index] = point.active
    if point.active and math.abs(point.gain_db) >= 0.25 then corrected = corrected + 1 end
  end
  return {
    start_time = start_time,
    step_seconds = step_seconds,
    gains = gains,
    active = active_flags,
    active_points = #active_values,
    corrected_points = corrected,
    target_lufs = target,
    duration = duration,
  }
end

local function analyze_track(track, start_time, end_time, mode)
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then error("Could not create an audio accessor for " .. track_name(track)) end
  local buffer = reaper.new_array(ANALYSIS_BLOCK * 2)
  local chunks, chunk_sum, chunk_count = {}, 0, 0
  local peak = 0
  local sample_count, sample_sum, sample_sum_sq, clipped_samples = 0, 0, 0, 0
  local start_peak, end_peak = 0, 0
  local low_state, high_state, infra_state = 0, 0, 0
  local low_sq, mid_sq, high_sq, infra_sq = 0, 0, 0, 0
  local low_coeff = math.exp(-2 * math.pi * 250 / ANALYSIS_RATE)
  local high_coeff = math.exp(-2 * math.pi * 3500 / ANALYSIS_RATE)
  local infra_coeff = math.exp(-2 * math.pi * 20 / ANALYSIS_RATE)
  local position = start_time
  local b0a, b1a, b2a = 1.53512485958697, -2.69169618940638, 1.19839281085285
  local a1a, a2a = -1.69065929318241, 0.73248077421585
  local b0b, b1b, b2b = 1, -2, 1
  local a1b, a2b = -1.99004745483398, 0.99007225036621
  local x1a, x2a, y1a, y2a = 0, 0, 0, 0
  local x1b, x2b, y1b, y2b = 0, 0, 0, 0

  while position < end_time - 0.5 / ANALYSIS_RATE do
    local samples = math.min(ANALYSIS_BLOCK, math.ceil((end_time - position) * ANALYSIS_RATE))
    buffer.clear()
    local result = reaper.GetAudioAccessorSamples(accessor, ANALYSIS_RATE, 2, position, samples, buffer)
    if result < 0 then reaper.DestroyAudioAccessor(accessor); error("Audio analysis failed for " .. track_name(track)) end
    local values = buffer.table(1, samples * 2)
    for sample = 1, samples do
      local left = values[(sample - 1) * 2 + 1] or 0
      local right = values[(sample - 1) * 2 + 2] or 0
      local value
      if mode == "left" then value = left
      elseif mode == "right" then value = right
      elseif mode == "difference" then value = (left - right) * 0.5
      else value = (left + right) * 0.5 end
      peak = math.max(peak, math.abs(value))
      sample_count = sample_count + 1
      sample_sum = sample_sum + value
      sample_sum_sq = sample_sum_sq + value * value
      if math.abs(value) >= 0.999 then clipped_samples = clipped_samples + 1 end
      local sample_time = position + (sample - 1) / ANALYSIS_RATE
      if sample_time < start_time + 0.01 then start_peak = math.max(start_peak, math.abs(value)) end
      if sample_time >= end_time - 0.01 then end_peak = math.max(end_peak, math.abs(value)) end

      low_state = low_coeff * low_state + (1 - low_coeff) * value
      high_state = high_coeff * high_state + (1 - high_coeff) * value
      infra_state = infra_coeff * infra_state + (1 - infra_coeff) * value
      local low_band, mid_band, high_band = low_state, high_state - low_state, value - high_state
      low_sq, mid_sq, high_sq = low_sq + low_band * low_band, mid_sq + mid_band * mid_band, high_sq + high_band * high_band
      infra_sq = infra_sq + infra_state * infra_state

      local ya = b0a * value + b1a * x1a + b2a * x2a - a1a * y1a - a2a * y2a
      x2a, x1a, y2a, y1a = x1a, value, y1a, ya
      local yb = b0b * ya + b1b * x1b + b2b * x2b - a1b * y1b - a2b * y2b
      x2b, x1b, y2b, y1b = x1b, ya, y1b, yb
      chunk_sum = chunk_sum + yb * yb
      chunk_count = chunk_count + 1
      if chunk_count == LOUDNESS_CHUNK_SAMPLES then
        chunks[#chunks + 1] = chunk_sum / chunk_count
        chunk_sum, chunk_count = 0, 0
      end
    end
    position = position + samples / ANALYSIS_RATE
  end
  reaper.DestroyAudioAccessor(accessor)
  if chunk_count > LOUDNESS_CHUNK_SAMPLES * 0.5 then chunks[#chunks + 1] = chunk_sum / chunk_count end
  -- BS.1770-style absolute/relative gating in loudness_from_chunks excludes
  -- silent windows. Silence inside the selected song is intentional content:
  -- it is not classified as a dropout, warning, failure, or repair target.
  local lufs, active_lufs, range_lu = loudness_from_chunks(chunks)
  local passage_map = build_passage_map(chunks, start_time, end_time, lufs)
  local spectral_total = low_sq + mid_sq + high_sq
  local rms = math.sqrt(sample_sum_sq / math.max(sample_count, 1))
  return {
    lufs = lufs,
    active_lufs = active_lufs,
    range_lu = range_lu,
    peak = peak,
    peak_db = amp_to_db(peak),
    rms_db = amp_to_db(rms),
    crest_db = peak > EPS and amp_to_db(peak / math.max(rms, EPS)) or 0,
    clipped_samples = clipped_samples,
    dc_db = amp_to_db(math.abs(sample_sum / math.max(sample_count, 1))),
    infra_ratio_db = amp_to_db(math.sqrt(infra_sq / math.max(sample_sum_sq, EPS))),
    start_peak_db = amp_to_db(start_peak),
    end_peak_db = amp_to_db(end_peak),
    low_pct = spectral_total > EPS and 100 * low_sq / spectral_total or 0,
    mid_pct = spectral_total > EPS and 100 * mid_sq / spectral_total or 0,
    high_pct = spectral_total > EPS and 100 * high_sq / spectral_total or 0,
    passage_map = passage_map,
    silent = peak < 1e-7 or not finite(lufs),
  }
end

local function detect_click_hits_at_factor(track, start_time, end_time, threshold_factor)
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then error("Could not read the CLICK timing track.") end
  local buffer = reaper.new_array(ANALYSIS_BLOCK * 2)
  local peak, position = 0, start_time
  while position < end_time - 0.5 / ANALYSIS_RATE do
    local samples = math.min(ANALYSIS_BLOCK, math.ceil((end_time - position) * ANALYSIS_RATE))
    buffer.clear()
    local result = reaper.GetAudioAccessorSamples(accessor, ANALYSIS_RATE, 2, position, samples, buffer)
    if result < 0 then reaper.DestroyAudioAccessor(accessor); error("CLICK transient scan failed.") end
    local values = buffer.table(1, samples * 2)
    for sample = 1, samples do
      peak = math.max(peak, math.abs(values[(sample - 1) * 2 + 1] or 0), math.abs(values[(sample - 1) * 2 + 2] or 0))
    end
    position = position + samples / ANALYSIS_RATE
  end
  if peak < 1e-7 then reaper.DestroyAudioAccessor(accessor); error("The CLICK timing track has no measurable audio in the time selection.") end

  local threshold = math.max(db_to_amp(-60), peak * threshold_factor)
  local release_threshold = threshold * 0.35
  local minimum_spacing = 0.04
  local search_window = 0.015
  local quiet_required = math.floor(ANALYSIS_RATE * 0.004 + 0.5)
  local hits, candidate, armed, quiet_samples = {}, nil, true, 0
  local last_hit = -math.huge
  position = start_time
  while position < end_time - 0.5 / ANALYSIS_RATE do
    local samples = math.min(ANALYSIS_BLOCK, math.ceil((end_time - position) * ANALYSIS_RATE))
    buffer.clear()
    local result = reaper.GetAudioAccessorSamples(accessor, ANALYSIS_RATE, 2, position, samples, buffer)
    if result < 0 then reaper.DestroyAudioAccessor(accessor); error("CLICK transient detection failed.") end
    local values = buffer.table(1, samples * 2)
    for sample = 1, samples do
      local sample_time = position + (sample - 1) / ANALYSIS_RATE
      local amplitude = math.max(math.abs(values[(sample - 1) * 2 + 1] or 0), math.abs(values[(sample - 1) * 2 + 2] or 0))
      if candidate then
        if amplitude > candidate.peak then candidate.peak, candidate.time = amplitude, sample_time end
        if sample_time >= candidate.deadline then
          hits[#hits + 1] = candidate.time
          last_hit = candidate.time
          candidate, armed, quiet_samples = nil, false, 0
        end
      elseif armed and amplitude >= threshold and sample_time - last_hit >= minimum_spacing then
        candidate = {peak = amplitude, time = sample_time, deadline = sample_time + search_window}
      elseif not armed then
        if amplitude < release_threshold then quiet_samples = quiet_samples + 1 else quiet_samples = 0 end
        if quiet_samples >= quiet_required and sample_time - last_hit >= minimum_spacing then armed = true end
      end
    end
    position = position + samples / ANALYSIS_RATE
  end
  if candidate then hits[#hits + 1] = candidate.time end
  reaper.DestroyAudioAccessor(accessor)
  if #hits == 0 then error("No click hits were detected on the CLICK timing track.") end
  local maximum_reasonable = math.ceil((end_time - start_time) / 0.035) + 2
  if #hits > maximum_reasonable then error("CLICK transient detection produced an unsafe number of hits.") end
  return hits, amp_to_db(threshold)
end

local function click_grid_score(project, hits)
  if #hits < 2 or not reaper.TimeMap2_timeToQN then return 0.25, nil end
  local candidates = {0.125, 1 / 6, 0.25, 1 / 3, 0.5, 2 / 3, 1}
  local origin = reaper.TimeMap2_timeToQN(project, hits[1])
  local best_score, best_step = math.huge, nil
  for _, step in ipairs(candidates) do
    local residual_sum, backwards = 0, 0
    local previous_index = -math.huge
    for _, hit in ipairs(hits) do
      local qn = reaper.TimeMap2_timeToQN(project, hit)
      local position = (qn - origin) / step
      local nearest = math.floor(position + 0.5)
      residual_sum = residual_sum + math.abs(position - nearest)
      if nearest <= previous_index then backwards = backwards + 1 end
      previous_index = nearest
    end
    local score = residual_sum / #hits + backwards * 0.5
    if score < best_score then best_score, best_step = score, step end
  end
  return best_score, best_step
end

-- A single fixed transient threshold is brittle with accented clicks.  Scan a
-- bounded family of thresholds and retain the detection that fits REAPER's
-- tempo grid best.  This changes only detection confidence; it never adds or
-- deletes beats and therefore cannot invent a click during an intentional rest.
local function choose_click_detection(candidates)
  if not candidates or #candidates == 0 then return nil end
  -- Sparse accented beats can fit the tempo grid perfectly and used to beat a
  -- fuller detection. Use the median candidate count as a robust coverage
  -- reference, reject candidates that lose more than 20% of it, then select the
  -- cleanest grid fit. One noisy low threshold cannot force invented beats.
  local counts = {}
  for _, candidate in ipairs(candidates) do counts[#counts + 1] = #candidate.hits end
  table.sort(counts)
  local median_count = counts[math.floor((#counts + 1) / 2)]
  local minimum_coverage = math.max(1, math.floor(median_count * 0.80 + 0.5))
  local best
  for _, candidate in ipairs(candidates) do
    if #candidate.hits >= minimum_coverage and (not best or candidate.score < best.score
        or (math.abs(candidate.score - best.score) < 0.001 and #candidate.hits > #best.hits)
        or (math.abs(candidate.score - best.score) < 0.001 and #candidate.hits == #best.hits
          and candidate.factor > best.factor)) then
      best = candidate
    end
  end
  return best
end

local function detect_click_hits(project, track, start_time, end_time)
  local factors = {0.04, 0.0283, 0.0566, 0.02, 0.08}
  local candidates, failures = {}, {}
  for _, factor in ipairs(factors) do
    local ok, hits, threshold_db = pcall(detect_click_hits_at_factor, track, start_time, end_time, factor)
    if ok and hits and #hits > 0 then
      local grid_score, grid_step = click_grid_score(project, hits)
      local density = #hits / math.max(0.001, end_time - start_time)
      local density_penalty = density > 12 and (density - 12) * 0.05 or 0
      candidates[#candidates + 1] = {hits = hits, threshold_db = threshold_db,
        score = grid_score + density_penalty, grid_score = grid_score,
        grid_step = grid_step, factor = factor, density = density}
    else
      failures[#failures + 1] = tostring(hits)
    end
  end
  if #candidates == 0 then
    error("CLICK transient detection failed at every safe threshold: " .. table.concat(failures, " | "))
  end
  local best = choose_click_detection(candidates)
  if not best then error("CLICK transient detection could not retain a safe full-coverage candidate.") end
  return best.hits, best.threshold_db, best.grid_score, best.grid_step, #factors
end

-- Choose one fixed, bounded transfer curve from the raw source. No compressor
-- detector follows the song, and an already-flat stem needs no distortion.
function source_dynamics_settings(record)
  local raw = record.raw or {}
  if record.role == "CLICK" then
    return {threshold = clamp((raw.peak_db or -12) - 6, -60, 0),
      ratio = 1.35, knee = 4, max_reduction = 1.5}
  end
  if record.role ~= "BACKING" then return nil end
  local baseline = finite(raw.rms_db) and raw.rms_db
    or (finite(raw.lufs) and raw.lufs) or -30
  local crest = (finite(raw.peak_db) and raw.peak_db or baseline + 7) - baseline
  local need = clamp((crest - 7) / 10, 0, 1)
  return {
    threshold = clamp(baseline + clamp(crest * 0.55, 7, 10), -60, 0),
    ratio = 1 + 0.75 * need,
    knee = 6,
    max_reduction = 3.5 * need,
    crest_db = crest,
  }
end

local function processor_parameters(role, input_trim, settings, priority, channel_mode, dynamics)
  channel_mode = channel_mode or 1
  local values
  if role == "CLICK" then
    -- A gentle static curve evens accent-to-accent peak differences without
    -- allowing the music to modulate the click or rounding off its attack.
    values = {input_trim, -30, 0, 5000, 0, 1, 0.1, 80, 0, settings.click_peak_target, 1,
      0, -42, 20, 300, 0, 0, 1, -60, 5, 80}
  elseif role == "BACKING" then
    values = {input_trim, -24, 0, 5000, 0, 1, 25, 600, 0, -12, channel_mode,
      0, -42, 20, 800, 0, 0, 1, -60, 5, 100}
  elseif role == "FOH" then
    -- LEAD/RHYTHM/BED hierarchy is static in v4.0. Dynamic sidechain ducking
    -- was intentionally removed because it can audibly pump simultaneous FOH
    -- stems even when every individual loudness measurement is correct.
    values = {input_trim, -20, 0, 5000, 0, 1, 25, 600, 0, -9, channel_mode,
      0, -42, 20, 800, 0, 0, 1, -60, 5, 100}
  elseif role == "CLICK_BUS" then
    values = {input_trim, -30, 0, 5000, 0, 1, 0.1, 80, 0, settings.iem_ceiling - 1.0, 1,
      0, -42, 20, 800, 0, 0, 0, -60, 5, 80}
  elseif role == "IEM_BUS" then
    values = {input_trim, -24, 0, 5000, 0, 1, 20, 800, 0, settings.iem_ceiling - 0.5, 1,
      0, -42, 20, 800, 0, 0, 0, -60, 5, 100}
  elseif role == "FOH_BUS" then
    values = {input_trim, -20, 0, 5000, 0, 1, 20, 800, 0, settings.foh_ceiling - 0.5, 1,
      0, -42, 20, 800, 0, 0, 0, -60, 5, 100}
  else
    values = {input_trim, -24, 0, 5000, 0, 1, 20, 800, 0, 0, 1,
      0, -42, 20, 800, 0, 0, 0, -60, 5, 100}
  end
  if dynamics then
    values[5] = dynamics.threshold
    values[6] = dynamics.ratio
  end
  values[22] = dynamics and dynamics.knee or 6
  values[23] = dynamics and dynamics.max_reduction or 0
  return values
end

local function write_passage_map(map, slot)
  if not map or not map.gains or #map.gains == 0 or not slot or slot < 1 or slot > 2047
      or not reaper.gmem_attach or not reaper.gmem_write then
    return false
  end
  reaper.gmem_attach(PASSAGE_MAP_GMEM)
  local base = slot * PASSAGE_MAP_STRIDE
  reaper.gmem_write(base, map.start_time or 0)
  reaper.gmem_write(base + 1, map.step_seconds or 1)
  reaper.gmem_write(base + 2, math.min(#map.gains, PASSAGE_MAP_MAX_POINTS))
  for index = 1, math.min(#map.gains, PASSAGE_MAP_MAX_POINTS) do
    reaper.gmem_write(base + 2 + index, map.gains[index] or 0)
  end
  return true
end

local function clone_passage_map(map)
  if not map then return nil end
  local copy = {
    start_time = map.start_time, step_seconds = map.step_seconds,
    target_lufs = map.target_lufs, gains = {}, active = {},
    active_points = map.active_points, corrected_points = map.corrected_points,
  }
  for index, gain in ipairs(map.gains or {}) do copy.gains[index] = gain end
  for index, active in ipairs(map.active or {}) do copy.active[index] = active end
  return copy
end

local function apply_surgical_passage_map(side, measured_map, selection_start)
  if not side or not side.meter_slot or not measured_map or not measured_map.gains then return nil end
  local existing = side.passage_map
  local map = {
    start_time = selection_start,
    step_seconds = measured_map.step_seconds or 1,
    target_lufs = measured_map.target_lufs,
    gains = {}, active = {}, active_points = 0, corrected_points = 0,
  }
  local corrected, maximum = 0, 0
  for index, measured_gain in ipairs(measured_map.gains) do
    local active = measured_map.active and measured_map.active[index] or false
    map.active[index] = active
    if active then
      map.active_points = map.active_points + 1
      local previous = existing and existing.gains and existing.gains[index] or 0
      local surgical = clamp((measured_gain or 0) * 0.75, -3, 4.5)
      map.gains[index] = clamp(previous + surgical, -12, 12)
    else
      map.gains[index] = 0
    end
  end
  local unsmoothed = map.gains
  map.gains = stabilize_passage_gains(unsmoothed, map.active, map.step_seconds, 12)
  for index, gain in ipairs(map.gains) do
    if map.active[index] then
      local previous = existing and existing.gains and existing.gains[index] or 0
      local applied = gain - previous
      maximum = math.max(maximum, math.abs(applied))
      if math.abs(applied) >= 0.20 then corrected = corrected + 1 end
    end
  end
  map.corrected_points = corrected
  if corrected == 0 or not write_passage_map(map, side.meter_slot) then return nil end
  reaper.TrackFX_SetParam(side.track, side.fx, 16, clamp(side.meter_slot, 0, 2047))
  side.passage_map = map
  side.passage_revision = (side.passage_revision or 0) + 1
  return corrected, maximum
end

local function add_processor(track, role, input_trim, settings, priority, channel_mode, dynamics)
  local index = reaper.TrackFX_AddByName(track, PROCESSOR_FX_QUERY, false, 1)
  if index < 0 then error("REAPER could not load " .. PROCESSOR_FX_QUERY) end
  local values = processor_parameters(role, input_trim, settings, priority, channel_mode, dynamics)
  for parameter = 0, #values - 1 do reaper.TrackFX_SetParam(track, index, parameter, values[parameter + 1]) end
  local slot = meter_next_slot
  meter_next_slot = meter_next_slot + 1
  reaper.TrackFX_SetEnabled(track, index, true)
  reaper.TrackFX_SetOffline(track, index, false)
  if reaper.TrackFX_SetNamedConfigParm then
    reaper.TrackFX_SetNamedConfigParm(track, index, "renamed_name", "[BILDI] " .. role .. (priority and (" " .. priority) or ""))
  end
  meter_registry[#meter_registry + 1] = {
    track = track,
    fx = index,
    slot = slot,
    role = role .. (priority and (" " .. priority) or ""),
    source = role == "CLICK" or role == "BACKING" or role == "FOH",
  }
  return index, slot
end

local function set_processor_input(track, fx, value)
  reaper.TrackFX_SetParam(track, fx, 0, clamp(value, -60, 36))
end

local function set_processor_ceiling(track, fx, value)
  -- JSFX slider 10 is zero-based parameter 9. This is adjusted only from
  -- measured post-routing peaks, providing a second safety loop around any
  -- project-specific gain introduced after the processor itself.
  reaper.TrackFX_SetParam(track, fx, 9, clamp(value, -60, 0))
end

local function set_processor_leveler(track, fx, target_rms_db, maximum_correction_db)
  reaper.TrackFX_SetParam(track, fx, 1, clamp(target_rms_db, -60, -6))
  -- Reactive whole-track gain riding is forbidden by the anti-pump policy.
  -- This setter remains for rollback compatibility with older project states,
  -- but always resolves to zero correction and a very slow detector.
  reaper.TrackFX_SetParam(track, fx, 2, 0)
  reaper.TrackFX_SetParam(track, fx, 3, 5000)
end

local function set_processor_compression(track, fx, ceiling_db, strength)
  strength = clamp(strength or 0, 0, MAX_FINAL_COMPRESSION_STRENGTH)
  if strength <= EPS then
    reaper.TrackFX_SetParam(track, fx, 4, 0)
    reaper.TrackFX_SetParam(track, fx, 5, 1)
  else
    -- Only the narrow band immediately below the safety ceiling is compressed.
    -- Kept for state compatibility; final bus strength is fixed at zero and
    -- source dynamics use their own independent bounded settings.
    reaper.TrackFX_SetParam(track, fx, 4, clamp(ceiling_db - 4, -60, 0))
    reaper.TrackFX_SetParam(track, fx, 5,
      math.min(ANTI_PUMP_MAX_COMP_RATIO, 1 + strength * 0.25))
    reaper.TrackFX_SetParam(track, fx, 6, 20)
    reaper.TrackFX_SetParam(track, fx, 7, math.max(ANTI_PUMP_MIN_COMP_RELEASE_MS, 800))
  end
  reaper.TrackFX_SetParam(track, fx, 2, 0)
  reaper.TrackFX_SetParam(track, fx, 11, 0)
  reaper.TrackFX_SetParam(track, fx, 15, 0)
  reaper.TrackFX_SetParam(track, fx, 20, 100)
end

local function set_processor_makeup(track, fx, value)
  reaper.TrackFX_SetParam(track, fx, 8, clamp(value, -24, 24))
end

local function set_processor_passage_slot(track, fx, slot)
  reaper.TrackFX_SetParam(track, fx, 16, clamp(slot or 0, 0, 2047))
end

function append_repair(settings, message)
  settings.repair_log = settings.repair_log or {}
  local text = tostring(message or "")
  if settings.repair_log[#settings.repair_log] ~= text then
    settings.repair_log[#settings.repair_log + 1] = text
    console("AUTO-REPAIR: " .. text)
  end
end

local function reset_solver(solver)
  solver.previous_trim = nil
  solver.previous_lufs = nil
  solver.previous_error = nil
end

local function solve_loudness_correction(solver, trim_value, measured_lufs, target_lufs, fallback_mode)
  local error_value = target_lufs - measured_lufs
  local correction = error_value
  if solver.previous_trim and math.abs(trim_value - solver.previous_trim) >= 0.05 then
    local slope = (measured_lufs - solver.previous_lufs) / (trim_value - solver.previous_trim)
    if slope >= 0.20 and slope <= 1.40 then correction = error_value / slope end
  end
  if solver.previous_error and error_value * solver.previous_error < 0
      and math.abs(error_value) >= math.abs(solver.previous_error) * 0.80 then
    correction = correction * 0.50
  end
  if fallback_mode then correction = correction * 0.70 end
  solver.previous_trim = trim_value
  solver.previous_lufs = measured_lufs
  solver.previous_error = error_value
  return clamp(correction, -6, 6)
end

local function create_bus(project, name, kind, master_send, pan, hidden)
  -- Insert generated buses at project root. Appending after an unclosed or
  -- unusual folder structure could make a bus feed a parent instead of Master.
  local index = 0
  reaper.InsertTrackAtIndex(index, true)
  local track = reaper.GetTrack(project, index)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  set_track_ext(track, BUS_EXT_KEY, kind)
  bypass_existing_fx(track)
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", 1)
  reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan or 0)
  reaper.SetMediaTrackInfo_Value(track, "D_PANLAW", 1)
  reaper.SetMediaTrackInfo_Value(track, "I_PANMODE", 3)
  reaper.SetMediaTrackInfo_Value(track, "D_WIDTH", 1)
  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", master_send and 1 or 0)
  reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 2)
  reaper.SetMediaTrackInfo_Value(track, "I_FXEN", 1)
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
  reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
  if hidden then
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
  end
  return track
end

function CLICK_MULTI.analyze_sample_level(project, sample)
  local analysis, problem = common.analyze_stereo_file(project, sample.path)
  if not analysis then error("Could not analyze click sample " .. sample.label .. ": " .. tostring(problem)) end
  local left_rms = analysis.left and analysis.left.rms or 0
  local right_rms = analysis.right and analysis.right.rms or 0
  local stronger_rms = math.max(left_rms, right_rms)
  if stronger_rms < db_to_amp(-80) then
    error("Click sample " .. sample.label .. " contains no usable audible hit: " .. sample.path)
  end
  local weaker_rms = math.min(left_rms, right_rms)
  local fold_loss = analysis.mono_fold_loss_db
  local channel_mode, effective_rms, downmix_label = 0, nil, "stereo mono-sum"
  if weaker_rms < stronger_rms * 0.03 or not finite(fold_loss) or fold_loss < -9 then
    if left_rms >= right_rms then
      channel_mode, effective_rms, downmix_label = 3, left_rms, "left-channel mono"
    else
      channel_mode, effective_rms, downmix_label = 4, right_rms, "right-channel mono"
    end
  else
    effective_rms = stronger_rms * db_to_amp(fold_loss)
  end
  if effective_rms < db_to_amp(-80) then error("Click sample " .. sample.label .. " cancels when converted to mono.") end
  sample.take_channel_mode = channel_mode
  sample.effective_rms = effective_rms
  sample.effective_rms_db = amp_to_db(effective_rms)
  sample.downmix_label = downmix_label
end

function CLICK_MULTI.calibrate_samples(project, settings)
  local ordered = {settings.click_sample_a, settings.click_sample_b}
  if settings.click_alt_sample then ordered[#ordered + 1] = settings.click_alt_sample end
  local analyzed = {}
  for _, sample in ipairs(ordered) do
    local prior = analyzed[sample.id]
    if prior then
      sample.take_channel_mode = prior.take_channel_mode
      sample.effective_rms = prior.effective_rms
      sample.effective_rms_db = prior.effective_rms_db
      sample.downmix_label = prior.downmix_label
    else
      CLICK_MULTI.analyze_sample_level(project, sample)
      analyzed[sample.id] = sample
    end
  end
  local reference_rms = settings.click_sample_a.effective_rms
  settings.click_sample_level_notes = {}
  for _, sample in ipairs(ordered) do
    local accent_db = sample == settings.click_sample_b and (settings.click_b_relative_db or 0) or 0
    local requested = amp_to_db(reference_rms / math.max(sample.effective_rms, EPS)) + accent_db
    sample.calibration_gain_db = clamp(requested, -24, 24)
    sample.calibration_gain = db_to_amp(sample.calibration_gain_db)
    if math.abs(sample.calibration_gain_db - requested) > 0.01 then
      settings.click_sample_level_notes[#settings.click_sample_level_notes + 1] = string.format(
        "%s required %+.2f dB to preserve the metronome A/B balance and was safely limited to %+.2f dB.",
        sample.label, requested, sample.calibration_gain_db)
    end
  end
end

function CLICK_MULTI.insert_hit_item(track, settings, hit_time, end_time)
  local sample, label = CLICK_MULTI.sample_for_hit(settings, hit_time, settings.project)
  if not sample then error("No click sample is assigned to marker range " .. tostring(label) .. ".") end
  local source = reaper.PCM_Source_CreateFromFile(sample.path)
  if not source then error("Could not create a CLICK replacement item from " .. sample.path) end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", label .. " - " .. sample.filename, true)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", hit_time)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.min(sample.length, end_time - hit_time))
  reaper.SetMediaItemInfo_Value(item, "D_VOL", 1)
  reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", sample.calibration_gain)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", 0)
  if sample.take_channel_mode ~= 0 then
    reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", sample.take_channel_mode)
  end
  return item, sample, label
end

local function create_click_replacement(project, record, settings, start_time, end_time)
  local hits, threshold_db, grid_score, grid_step, thresholds_tested =
    detect_click_hits(project, record.track, start_time, end_time)
  CLICK_MULTI.calibrate_samples(project, settings)
  local replacement_name = #(settings.click_alt_ranges or {}) > 0
    and "#SHOW CLICK REPLACEMENT - METRONOME A/B + ALT"
    or "#SHOW CLICK REPLACEMENT - METRONOME A/B"
  local track = create_bus(project, replacement_name,
    "CLICK_REPLACEMENT", false, -1, true)
  set_track_ext(track, ROLE_EXT_KEY, "CLICK")
  local usage = {}
  for _, hit_time in ipairs(hits) do
    local _, sample, label = CLICK_MULTI.insert_hit_item(track, settings, hit_time, end_time)
    local entry = usage[label] or {label = label, sample = sample, hits = 0}
    entry.hits = entry.hits + 1
    usage[label] = entry
  end
  if reaper.CountTrackMediaItems(track) ~= #hits then
    error(string.format("CLICK replacement created %d item(s) for %d detected hit(s).",
      reaper.CountTrackMediaItems(track), #hits))
  end
  record.timing_track = record.track
  record.track = track
  record.click_hits = #hits
  record.click_hit_times = hits
  record.click_detection_threshold_db = threshold_db
  record.click_grid_score = grid_score
  record.click_grid_step_qn = grid_step
  record.click_thresholds_tested = thresholds_tested
  record.click_replacement_items = reaper.CountTrackMediaItems(track)
  record.click_sample_path = settings.click_sample_a.path
  record.click_sample_id = settings.click_sample_a.id
  record.click_sample_usage = usage
  return track
end

local function create_send(source, destination)
  local index = reaper.CreateTrackSend(source, destination)
  if index < 0 then error("Could not create routing from " .. track_name(source) .. " to " .. track_name(destination)) end
  reaper.SetTrackSendInfo_Value(source, 0, index, "I_SENDMODE", 3) -- pre-fader, post-FX, pre-pan
  reaper.SetTrackSendInfo_Value(source, 0, index, "D_VOL", 1)
  reaper.SetTrackSendInfo_Value(source, 0, index, "D_PAN", 0)
  reaper.SetTrackSendInfo_Value(source, 0, index, "I_SRCCHAN", 0)
  reaper.SetTrackSendInfo_Value(source, 0, index, "I_DSTCHAN", 0)
  reaper.SetTrackSendInfo_Value(source, 0, index, "I_MIDIFLAGS", 31)
  return index
end

function valid_track(project, track)
  return track and (not reaper.ValidatePtr2 or reaper.ValidatePtr2(project, track, "MediaTrack*"))
end

function ensure_audio_send(project, source, destination)
  if not valid_track(project, source) or not valid_track(project, destination) then return false end
  local send_index
  for index = 0, reaper.GetTrackNumSends(source, 0) - 1 do
    if reaper.GetTrackSendInfo_Value(source, 0, index, "P_DESTTRACK") == destination then
      send_index = index
      break
    end
  end
  if not send_index then send_index = create_send(source, destination) end
  reaper.SetTrackSendInfo_Value(source, 0, send_index, "I_SENDMODE", 3)
  reaper.SetTrackSendInfo_Value(source, 0, send_index, "D_VOL", 1)
  reaper.SetTrackSendInfo_Value(source, 0, send_index, "D_PAN", 0)
  reaper.SetTrackSendInfo_Value(source, 0, send_index, "I_SRCCHAN", 0)
  reaper.SetTrackSendInfo_Value(source, 0, send_index, "I_DSTCHAN", 0)
  return true
end

-- Reassert the complete final graph immediately before every verification
-- render. Temporary stem renders, project-tab changes, and failed repair passes
-- must never be able to leave a source, bus, processor, or master send inactive.
function ensure_final_render_graph(project, settings, has_foh)
  local runtime = settings and settings.runtime
  if not runtime or not runtime.iem or not runtime.backing then return false, "Runtime routing is unavailable." end
  local function activate(track, master_send, processor_fx, dynamics)
    if not valid_track(project, track) then return false end
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
    reaper.SetMediaTrackInfo_Value(track, "I_FXEN", 1)
    reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", master_send and 1 or 0)
    -- Only reactivate the processor installed by this build. Existing user FX
    -- were deliberately bypassed during sanitization and must stay bypassed.
    if processor_fx ~= nil and processor_fx >= 0 then
      reaper.TrackFX_SetEnabled(track, processor_fx, true)
      reaper.TrackFX_SetOffline(track, processor_fx, false)
      -- Restore only app-owned bounded source dynamics. Buses never compress;
      -- saved user FX and prior app parameter edits cannot enter the render.
      reaper.TrackFX_SetParam(track, processor_fx, 2, 0)   -- reactive leveling off
      reaper.TrackFX_SetParam(track, processor_fx, 3, 5000)
      reaper.TrackFX_SetParam(track, processor_fx, 7, 800)
      reaper.TrackFX_SetParam(track, processor_fx, 11, 0)  -- duck depth zero
      reaper.TrackFX_SetParam(track, processor_fx, 15, 0)  -- sidechain off
      reaper.TrackFX_SetParam(track, processor_fx, 16, 0)  -- passage maps off
      reaper.TrackFX_SetParam(track, processor_fx, 4, dynamics and dynamics.threshold or 0)
      reaper.TrackFX_SetParam(track, processor_fx, 5, dynamics and dynamics.ratio or 1)
      reaper.TrackFX_SetParam(track, processor_fx, 8, 0)   -- makeup off
      reaper.TrackFX_SetParam(track, processor_fx, 20, 100)
      reaper.TrackFX_SetParam(track, processor_fx, 21, dynamics and dynamics.knee or 6)
      reaper.TrackFX_SetParam(track, processor_fx, 22, dynamics and dynamics.max_reduction or 0)
    end
    return true
  end

  if not activate(runtime.iem.track, true, runtime.iem.fx)
      or not activate(runtime.backing.track, false, runtime.backing.fx) then
    return false, "A required IEM bus is no longer valid."
  end
  if runtime.click and not activate(runtime.click.track, false, runtime.click.fx) then
    return false, "The CLICK bus is no longer valid."
  end
  if has_foh and (not runtime.foh or not activate(runtime.foh.track, true, runtime.foh.fx)) then
    return false, "The FOH bus is no longer valid."
  end

  local sources = runtime.sources or {}
  for _, record in ipairs(sources.CLICK or {}) do
    if not activate(record.track, false, record.fx, record.dynamics) or not ensure_audio_send(project, record.track, runtime.click.track) then
      return false, "CLICK source routing could not be restored."
    end
  end
  for _, record in ipairs(sources.BACKING or {}) do
    if not activate(record.track, false, record.fx, record.dynamics) or not ensure_audio_send(project, record.track, runtime.backing.track) then
      return false, "BACKING source routing could not be restored."
    end
  end
  for _, record in ipairs(sources.FOH or {}) do
    if not activate(record.track, false, record.fx, record.dynamics) or not ensure_audio_send(project, record.track, runtime.foh.track) then
      return false, "FOH source routing could not be restored."
    end
  end
  if runtime.click and not ensure_audio_send(project, runtime.click.track, runtime.iem.track) then
    return false, "CLICK-to-IEM routing could not be restored."
  end
  if not ensure_audio_send(project, runtime.backing.track, runtime.iem.track) then
    return false, "BACKING-to-IEM routing could not be restored."
  end
  -- Optional companion renders apply their relative CLICK/BACKING difference
  -- on app-owned post-FX sends. Raising a CLICK processor that is already at
  -- its peak guard would make a misleading +3 dB file with almost no audible
  -- difference. Lowering the opposite component instead is constant gain,
  -- preserves the requested relative balance, and cannot introduce pumping.
  local variant = settings.variant_mix
  if variant then
    local function set_bus_send_gain(source, destination, gain_db)
      for index = 0, reaper.GetTrackNumSends(source, 0) - 1 do
        if reaper.GetTrackSendInfo_Value(source, 0, index, "P_DESTTRACK") == destination then
          reaper.SetTrackSendInfo_Value(source, 0, index, "D_VOL", 10 ^ ((gain_db or 0) / 20))
          return true
        end
      end
      return false
    end
    if not set_bus_send_gain(runtime.click.track, runtime.iem.track, variant.click_db)
        or not set_bus_send_gain(runtime.backing.track, runtime.iem.track, variant.backing_db) then
      return false, "The optional CLICK/BACKING balance sends could not be configured."
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return true
end

-- The mixer presents a bounded artistic offset on top of the level calculated
-- from the raw source measurement. The same processor parameter is used for
-- preview and render, so the audition cannot silently differ from the WAV.
function apply_manual_track_offset(record, offset_db)
  offset_db = clamp(tonumber(offset_db) or 0, -INTENT_OFFSET_LIMIT_DB, INTENT_OFFSET_LIMIT_DB)
  if record.mix_ui_base_trim == nil then
    record.mix_ui_base_trim = record.input_trim or 0
    record.mix_ui_base_offset = record.intent_offset or 0
    record.mix_ui_base_target = record.target
  end
  local delta = offset_db - (record.mix_ui_base_offset or 0)
  record.mix_offset_db = offset_db
  record.intent_offset = offset_db
  record.input_trim = clamp(record.mix_ui_base_trim + delta, -60, 36)
  if record.mix_ui_base_target then record.target = record.mix_ui_base_target + delta end
  set_processor_input(record.track, record.fx, record.input_trim)
  return record.input_trim
end

function manual_mix_report(records)
  local lines = {"", "MANUAL MIX OFFSETS (preview and final render)",
    "----------------------------------------------"}
  for _, record in ipairs(records or {}) do
    lines[#lines + 1] = string.format("%s [%s]  %+.1f dB", record.name, record.role, record.mix_offset_db or record.intent_offset or 0)
  end
  lines[#lines + 1] = "Preview contract: CLICK + BACKING summed to mono, left output only; FOH excluded."
  return table.concat(lines, "\n")
end

-- Measure the user's live mixer choices once, then correct only the complete
-- IEM/FOH side. This keeps every chosen inter-track balance intact while the
-- finished file still approaches the locked show loudness targets.
function finalize_manual_mix(project, records, settings, start_time, end_time, has_foh)
  local runtime = settings.runtime
  local ok, problem = ensure_final_render_graph(project, settings, has_foh)
  if not ok then error(problem) end
  -- Track audio accessors do not reliably include receives on every REAPER
  -- installation. Render the generated component buses as temporary stems so
  -- manual-mix measurements hear exactly the same receives and processors as
  -- playback and the final WAV.
  local file_analysis = create_bus(project, "#SHOW MANUAL MIX ANALYSIS (temporary)", "ANALYSIS", false, 0, true)
  local meters = run_meter_render(project, start_time, end_time, file_analysis, {})
  reaper.DeleteTrack(file_analysis)
  local backing = meters[runtime.backing.meter_slot]
  local click = runtime.click and meters[runtime.click.meter_slot] or nil
  local left = meters[runtime.iem.meter_slot]
  local right = has_foh and runtime.foh and meters[runtime.foh.meter_slot] or nil
  if not backing or not left or (has_foh and not right) then error("The manual mix meter render did not return every required bus.") end
  if backing.silent then error("The manual mix contains no measurable BACKING audio.") end
  if click and not click.silent then
    local requested_ratio = click.active_lufs - backing.active_lufs
    settings.manual_click_ratio_requested = requested_ratio
    settings.click_advantage = clamp(requested_ratio, 3, 15)
    settings.final_click_ratio = settings.click_advantage
    settings.click_audibility_floor_db = math.max(5, settings.click_advantage - 1)
    if math.abs(settings.click_advantage - requested_ratio) > 0.01 then
      append_repair(settings, string.format(
        "Manual CLICK/BACKING ratio %.2f dB was constrained to the safe %.2f dB range.",
        requested_ratio, settings.click_advantage))
    end
  end

  if left.silent then error("The mono IEM preview path is silent after applying the manual mix.") end
  local left_correction = clamp(settings.iem_target - left.lufs, -12, 12)
  runtime.iem.trim = clamp((runtime.iem.trim or 0) + left_correction, -30, 36)
  set_processor_input(runtime.iem.track, runtime.iem.fx, runtime.iem.trim)
  append_repair(settings, string.format(
    "Manual IEM mix was normalized with one fixed whole-side correction of %+.2f dB; individual track offsets were preserved.",
    left_correction))

  if has_foh and runtime.foh then
    if right.silent then error("The manual FOH mix is silent after applying the selected levels.") end
    local right_correction = clamp(settings.foh_target - right.lufs, -12, 12)
    runtime.foh.trim = clamp((runtime.foh.trim or 0) + right_correction, -30, 36)
    set_processor_input(runtime.foh.track, runtime.foh.fx, runtime.foh.trim)
    append_repair(settings, string.format(
      "Manual FOH mix was normalized with one fixed whole-side correction of %+.2f dB; individual track offsets were preserved.",
      right_correction))
  end
  settings.manual_mix_used = true
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return manual_mix_report(records)
end

-- This is the last normal user decision before setup. With preview unchecked,
-- the analysis hands off directly to rendering without opening the mixer.
function open_build_options_ui(summary, output_path, has_click, on_continue, on_cancel)
  local preview, variants = false, false
  local previous_mouse_down, done = false, false
  local width, height = 760, 390
  local function inside(x, y, w, h)
    return gfx.mouse_x >= x and gfx.mouse_x <= x + w
      and gfx.mouse_y >= y and gfx.mouse_y <= y + h
  end
  local function button(x, y, w, h, label, active)
    local hovered = inside(x, y, w, h)
    gfx.set(active and 0.11 or 0.12, hovered and 0.50 or 0.32, active and 0.34 or 0.51, 1)
    gfx.rect(x, y, w, h, true)
    gfx.set(0.97, 0.98, 1, 1); gfx.setfont(2, "Arial", 15, 98)
    gfx.x, gfx.y = x + 14, y + 10; gfx.drawstr(label)
    return hovered
  end
  local function checkbox(y, checked, label, detail, enabled)
    local hovered = enabled and inside(22, y, math.max(100, gfx.w - 44), 48)
    gfx.set(enabled and (hovered and 0.14 or 0.10) or 0.07, enabled and 0.21 or 0.10,
      enabled and 0.28 or 0.13, 1)
    gfx.rect(20, y, math.max(100, gfx.w - 40), 48, true)
    gfx.set(enabled and 0.72 or 0.31, enabled and 0.83 or 0.37, enabled and 0.92 or 0.42, 1)
    gfx.rect(30, y + 9, 23, 23, false)
    if checked then gfx.set(0.24, 0.90, 0.60, 1); gfx.rect(34, y + 13, 15, 15, true) end
    gfx.set(enabled and 0.96 or 0.45, enabled and 0.98 or 0.51, enabled and 1 or 0.55, 1)
    gfx.setfont(2, "Arial", 15, 98); gfx.x, gfx.y = 66, y + 5; gfx.drawstr(label)
    gfx.setfont(3, "Arial", 11); gfx.x, gfx.y = 66, y + 27; gfx.drawstr(detail)
    return hovered
  end
  local function draw()
    local w, h = math.max(gfx.w or width, 610), math.max(gfx.h or height, 355)
    gfx.set(0.035, 0.055, 0.078, 1); gfx.rect(0, 0, w, h, true)
    gfx.set(0.97, 0.98, 1, 1); gfx.setfont(1, "Arial", 23, 98)
    gfx.x, gfx.y = 22, 17; gfx.drawstr("Build show track")
    gfx.set(0.71, 0.79, 0.87, 1); gfx.setfont(3, "Arial", 12)
    local shown = 0
    for _, line in ipairs(summary or {}) do
      if line ~= "" and line ~= "Output:" and not line:find("Continue with setup", 1, true)
          and not line:find("Excluded unlabeled", 1, true)
          and not line:find("Hardware-safe", 1, true) and shown < 5 then
        if #line > 100 then line = line:sub(1, 97) .. "..." end
        gfx.x, gfx.y = 24, 55 + shown * 19; gfx.drawstr(line)
        shown = shown + 1
      end
    end
    local output_display = tostring(output_path or "")
    if #output_display > 76 then output_display = "..." .. output_display:sub(-73) end
    gfx.set(0.44, 0.80, 0.96, 1); gfx.x, gfx.y = 24, 164
    gfx.drawstr("Output: " .. output_display)
    local preview_hover = checkbox(190, preview, "Preview mono IEM mix before render",
      "Checked: open the track-level mixer and play CLICK + BACKING in mono.", true)
    local variant_hover = checkbox(248, variants, "Also render CLICK +3 dB and -3 dB versions",
      has_click and "Relative to the assigned CLICK offset; each extra WAV is independently verified."
        or "Unavailable because this song has no CLICK track.", has_click)
    local cancel_hover = button(22, h - 55, 120, 39, "Cancel", false)
    local continue_hover = button(w - 234, h - 55, 212, 39,
      preview and "Continue to preview" or "Build without preview", true)
    gfx.update()
    return preview_hover, variant_hover, cancel_hover, continue_hover
  end
  local function finish(accepted)
    if done then return end
    done = true
    gfx.quit()
    if accepted then
      reaper.defer(function() on_continue({preview = preview, variants = has_click and variants}) end)
    elseif on_cancel then on_cancel() end
  end
  local function loop()
    if done then return end
    local character = gfx.getchar()
    if character < 0 or character == 27 then finish(false); return end
    local preview_hover, variant_hover, cancel_hover, continue_hover = draw()
    if character == 13 then finish(true); return end
    local mouse_down = (gfx.mouse_cap & 1) == 1
    if mouse_down and not previous_mouse_down then
      if preview_hover then preview = not preview
      elseif variant_hover then variants = not variants
      elseif cancel_hover then finish(false); return
      elseif continue_hover then finish(true); return end
    end
    previous_mouse_down = mouse_down
    reaper.defer(loop)
  end
  gfx.init(SCRIPT_NAME .. " - Build options", width, height, 0)
  draw()
  loop()
end

-- Resizable native gfx mixer. Preview is deliberately the real mono IEM feed:
-- CLICK plus every BACKING source, hard-left only, with the FOH bus muted.
function open_mix_preview_ui(project, records, by_role, settings, start_time, end_time, on_render, on_cancel)
  local runtime = settings.runtime
  local has_foh = runtime and runtime.foh ~= nil
  local window_width = 900
  local window_height = math.min(780, math.max(540, 270 + #records * 42))
  local row_height, scroll_rows = 40, 0
  local previous_mouse_down, dragging, previewing, loop_preview = false, nil, false, true
  local done, handed_off = false, false
  local status = "Ready. Preview is MONO, LEFT output only; FOH is muted."
  local edit_cursor = reaper.GetCursorPosition and reaper.GetCursorPosition() or start_time

  for _, record in ipairs(records) do
    record.mix_ui_base_trim = record.input_trim or 0
    record.mix_ui_base_offset = record.intent_offset or 0
    record.mix_ui_base_target = record.target
    record.mix_offset_db = record.intent_offset or 0
  end

  local function stop_preview()
    if previewing and reaper.GetPlayState and (reaper.GetPlayState() & 1) == 1 then reaper.OnStopButton() end
    previewing = false
    if runtime.foh and valid_track(project, runtime.foh.track) then
      reaper.SetMediaTrackInfo_Value(runtime.foh.track, "B_MUTE", 0)
    end
  end

  local function start_preview()
    stop_preview()
    local graph_ok, graph_error = ensure_final_render_graph(project, settings, has_foh)
    if not graph_ok then status = "Preview unavailable: " .. tostring(graph_error); return end
    if runtime.foh then reaper.SetMediaTrackInfo_Value(runtime.foh.track, "B_MUTE", 1) end
    reaper.SetMediaTrackInfo_Value(runtime.iem.track, "D_PAN", -1)
    reaper.SetMediaTrackInfo_Value(runtime.iem.track, "B_MAINSEND", 1)
    reaper.SetEditCurPos(start_time, false, false)
    reaper.OnPlayButton()
    previewing = true
    status = "Playing exact mono CLICK + BACKING preview on LEFT only. FOH is muted."
  end

  local function restore_cursor()
    if reaper.SetEditCurPos then reaper.SetEditCurPos(edit_cursor, false, false) end
  end

  local function cancel_mixer(reason)
    if done then return end
    done = true
    stop_preview()
    restore_cursor()
    gfx.quit()
    local restored, restore_error = finish_project_transaction(project, settings)
    if on_cancel then on_cancel(reason or "Mixer closed", restored, restore_error) end
  end

  local function handoff_render()
    if done then return end
    done, handed_off = true, true
    stop_preview()
    restore_cursor()
    gfx.quit()
    reaper.defer(function() on_render() end)
  end

  local function set_offset(index, value)
    local record = records[index]
    if not record then return end
    apply_manual_track_offset(record, math.floor(clamp(value, -INTENT_OFFSET_LIMIT_DB, INTENT_OFFSET_LIMIT_DB) * 2 + 0.5) / 2)
    status = string.format("%s set to %+.1f dB. Preview and render now use this exact offset.",
      record.name, record.mix_offset_db)
  end

  local function button(x, y, width, height, label, active, danger)
    local hovered = gfx.mouse_x >= x and gfx.mouse_x <= x + width and gfx.mouse_y >= y and gfx.mouse_y <= y + height
    if danger then gfx.set(hovered and 0.72 or 0.52, 0.18, 0.18, 1)
    elseif active then gfx.set(0.12, hovered and 0.65 or 0.53, 0.34, 1)
    else gfx.set(hovered and 0.20 or 0.12, hovered and 0.48 or 0.30, hovered and 0.72 or 0.46, 1) end
    gfx.rect(x, y, width, height, true)
    gfx.set(0.96, 0.98, 1, 1); gfx.setfont(3, "Arial", 14, 98)
    local text_width, text_height = gfx.measurestr(label)
    gfx.x, gfx.y = x + (width - text_width) / 2, y + (height - text_height) / 2
    gfx.drawstr(label)
    return hovered
  end

  local function layout()
    local width, height = math.max(gfx.w or window_width, 680), math.max(gfx.h or window_height, 480)
    local top, bottom = 160, 82
    local visible = math.max(1, math.floor((height - top - bottom) / row_height))
    scroll_rows = clamp(scroll_rows, 0, math.max(0, #records - visible))
    return width, height, top, bottom, visible
  end

  local function draw()
    local width, height, top, bottom, visible = layout()
    gfx.set(0.032, 0.050, 0.072, 1); gfx.rect(0, 0, width, height, true)
    gfx.set(0.96, 0.98, 1, 1); gfx.setfont(1, "Arial", 25, 98)
    gfx.x, gfx.y = 22, 17; gfx.drawstr("Show Track Mix & Mono IEM Preview")
    gfx.set(0.56, 0.74, 0.91, 1); gfx.setfont(2, "Arial", 13)
    gfx.x, gfx.y = 24, 52
    gfx.drawstr(string.format("IEM %.1f LUFS / %.1f dBFS | CLICK +%.1f dB | FOH %.1f LUFS / %.1f dBFS",
      settings.iem_target, settings.iem_ceiling, settings.click_advantage, settings.foh_target, settings.foh_ceiling))
    gfx.set(0.92, 0.72, 0.28, 1); gfx.x, gfx.y = 24, 75
    gfx.drawstr("Preview = CLICK + BACKING summed to MONO on LEFT only. FOH is never heard in preview.")

    local preview_hover = button(22, 103, 170, 38, previewing and "Restart Preview" or "Play Mono Preview", previewing, false)
    local stop_hover = button(202, 103, 88, 38, "Stop", false, true)
    local loop_hover = button(300, 103, 110, 38, loop_preview and "Loop: ON" or "Loop: OFF", loop_preview, false)
    local reset_hover = button(420, 103, 132, 38, "Reset to 0 dB", false, false)
    local render_hover = button(width - 202, 103, 180, 38, "Render Show Track", true, false)

    for visible_index = 1, visible do
      local index = scroll_rows + visible_index
      local record = records[index]
      if record then
        local y = top + (visible_index - 1) * row_height
        if visible_index % 2 == 0 then gfx.set(0.050, 0.078, 0.108, 1) else gfx.set(0.042, 0.065, 0.092, 1) end
        gfx.rect(14, y, width - 28, row_height - 2, true)
        if record.role == "CLICK" then gfx.set(0.95, 0.66, 0.24, 1)
        elseif record.role == "BACKING" then gfx.set(0.26, 0.78, 0.56, 1)
        else gfx.set(0.53, 0.61, 0.70, 1) end
        gfx.setfont(3, "Arial", 12, 98); gfx.x, gfx.y = 24, y + 12; gfx.drawstr(record.role)
        gfx.set(record.role == "FOH" and 0.62 or 0.92, record.role == "FOH" and 0.68 or 0.94, record.role == "FOH" and 0.74 or 0.97, 1)
        gfx.setfont(3, "Arial", 14); gfx.x, gfx.y = 100, y + 10
        local display_name = #record.name > 28 and (record.name:sub(1, 27) .. "...") or record.name
        gfx.drawstr(display_name)
        if record.role == "FOH" then
          gfx.set(0.52, 0.58, 0.64, 1); gfx.setfont(4, "Arial", 10)
          gfx.x, gfx.y = 100, y + 26; gfx.drawstr("final render only")
        end

        local slider_x, slider_width = math.max(340, math.floor(width * 0.43)), math.max(180, width - math.max(340, math.floor(width * 0.43)) - 150)
        local slider_y = y + 15
        gfx.set(0.12, 0.18, 0.24, 1); gfx.rect(slider_x, slider_y, slider_width, 8, true)
        local zero_x = slider_x + slider_width / 2
        gfx.set(0.33, 0.42, 0.50, 1); gfx.rect(zero_x - 1, slider_y - 4, 2, 16, true)
        local normalized = ((record.mix_offset_db or 0) + INTENT_OFFSET_LIMIT_DB) / (INTENT_OFFSET_LIMIT_DB * 2)
        local knob_x = slider_x + clamp(normalized, 0, 1) * slider_width
        gfx.set(record.role == "FOH" and 0.45 or 0.22, record.role == "FOH" and 0.54 or 0.68, record.role == "FOH" and 0.63 or 0.91, 1)
        gfx.circle(knob_x, slider_y + 4, 8, true, true)
        button(slider_x - 34, y + 7, 26, 26, "-", false, false)
        button(slider_x + slider_width + 8, y + 7, 26, 26, "+", false, false)
        gfx.set(0.94, 0.96, 0.98, 1); gfx.setfont(3, "Arial", 13, 98)
        gfx.x, gfx.y = width - 72, y + 11; gfx.drawstr(string.format("%+.1f", record.mix_offset_db or 0))
      end
    end

    gfx.set(0.62, 0.70, 0.78, 1); gfx.setfont(4, "Arial", 12)
    gfx.x, gfx.y = 22, height - bottom + 12; gfx.drawstr(status)
    gfx.x, gfx.y = 22, height - 28
    gfx.drawstr("Drag a level, use +/- for 0.5 dB steps, mouse wheel to scroll. ESC closes and restores the project.")
    gfx.update()
    return preview_hover, stop_hover, loop_hover, reset_hover, render_hover, width, height, top, visible
  end

  local function loop()
    if done then return end
    local character = gfx.getchar()
    if character < 0 or character == 27 then cancel_mixer("Mixer closed"); return end
    if character == 32 then if previewing then stop_preview() else start_preview() end end
    if previewing and reaper.GetPlayState and (reaper.GetPlayState() & 1) == 1
        and reaper.GetPlayPosition and reaper.GetPlayPosition() >= end_time - 0.01 then
      if loop_preview then start_preview() else stop_preview(); status = "Preview finished." end
    elseif previewing and reaper.GetPlayState and (reaper.GetPlayState() & 1) == 0 then
      previewing = false
    end

    local preview_hover, stop_hover, loop_hover, reset_hover, render_hover, width, _, top, visible = draw()
    if gfx.mouse_wheel ~= 0 then
      scroll_rows = clamp(scroll_rows - math.floor(gfx.mouse_wheel / 120), 0, math.max(0, #records - visible))
      gfx.mouse_wheel = 0
    end
    local mouse_down = (gfx.mouse_cap & 1) == 1
    if mouse_down and not previous_mouse_down then
      if preview_hover then start_preview()
      elseif stop_hover then stop_preview(); status = "Preview stopped."
      elseif loop_hover then loop_preview = not loop_preview
      elseif reset_hover then
        for index = 1, #records do set_offset(index, 0) end
        status = "All manual track offsets reset to 0.0 dB."
      elseif render_hover then handoff_render(); return
      else
        for visible_index = 1, visible do
          local index = scroll_rows + visible_index
          if records[index] then
            local y = top + (visible_index - 1) * row_height
            local slider_x = math.max(340, math.floor(width * 0.43))
            local slider_width = math.max(180, width - slider_x - 150)
            if gfx.mouse_y >= y + 5 and gfx.mouse_y <= y + 35 then
              if gfx.mouse_x >= slider_x - 34 and gfx.mouse_x <= slider_x - 8 then
                set_offset(index, (records[index].mix_offset_db or 0) - 0.5)
              elseif gfx.mouse_x >= slider_x + slider_width + 8 and gfx.mouse_x <= slider_x + slider_width + 34 then
                set_offset(index, (records[index].mix_offset_db or 0) + 0.5)
              elseif gfx.mouse_x >= slider_x and gfx.mouse_x <= slider_x + slider_width then
                dragging = index
                set_offset(index, -INTENT_OFFSET_LIMIT_DB + (gfx.mouse_x - slider_x) / slider_width * INTENT_OFFSET_LIMIT_DB * 2)
              end
            end
          end
        end
      end
    elseif mouse_down and dragging then
      local slider_x = math.max(340, math.floor(width * 0.43))
      local slider_width = math.max(180, width - slider_x - 150)
      set_offset(dragging, -INTENT_OFFSET_LIMIT_DB + (gfx.mouse_x - slider_x) / slider_width * INTENT_OFFSET_LIMIT_DB * 2)
    elseif not mouse_down then dragging = nil end
    previous_mouse_down = mouse_down
    reaper.defer(loop)
  end

  reaper.atexit(function()
    if not done and not handed_off then
      stop_preview()
      restore_cursor()
      finish_project_transaction(project, settings)
    end
  end)
  gfx.init(SCRIPT_NAME .. " - Mix & Mono Preview", window_width, window_height, 0)
  start_preview()
  draw()
  loop()
end

local function allocate_simultaneous_tracks(records, role, settings)
  local selected = {}
  for _, record in ipairs(records) do
    if record.role == role and record.raw and record.raw.passage_map then selected[#selected + 1] = record end
  end
  for _, record in ipairs(selected) do
    local map = record.raw.passage_map
    local concurrency_sum, active_count, maximum = 0, 0, 1
    for index, active in ipairs(map.active or {}) do
      if active then
        local count = 0
        for _, other in ipairs(selected) do
          if other.raw.passage_map.active[index] then count = count + 1 end
        end
        count = math.max(1, count)
        concurrency_sum, active_count = concurrency_sum + count, active_count + 1
        maximum = math.max(maximum, count)
      end
    end
    local average = active_count > 0 and concurrency_sum / active_count or 1
    record.average_concurrency = average
    record.maximum_concurrency = maximum
    record.concurrency_allocation_db = -10 * math.log(math.max(1, average), 10)
    if average > 1.05 then
      append_repair(settings, string.format(
        "%s allocation accounts for %.2f simultaneously active %s tracks on average (maximum %d; %+.2f dB stem allocation).",
        record.name, average, role, maximum, record.concurrency_allocation_db))
    end
  end
end

local function prepare_source_processor(record, settings)
  local raw = record.raw
  local target, initial
  if record.role == "CLICK" then
    target = settings.click_peak_target
    initial = target - raw.peak_db
  elseif record.role == "BACKING" then
    target = settings.backing_stem_target + (record.concurrency_allocation_db or 0) + (record.intent_offset or 0)
    initial = target - raw.lufs
  else
    local priority_offset = record.priority == "LEAD" and 1.0 or (record.priority == "BED" and -1.5 or 0)
    record.priority_static_offset = priority_offset
    target = settings.foh_stem_target + (record.concurrency_allocation_db or 0) +
      (record.intent_offset or 0) + priority_offset
    initial = target - raw.lufs
  end
  record.requested_initial_trim = initial
  local bounded_initial = clamp(initial, -60, 36)
  if math.abs(bounded_initial - initial) > 0.01 then
    append_repair(settings, string.format(
      "%s requested %+.2f dB of initial correction; the source processor used its %+.2f dB boundary and downstream leveling will complete the repair.",
      record.name, initial, bounded_initial))
  end
  initial = bounded_initial
  record.input_trim = initial
  record.dynamics = source_dynamics_settings(record)
  record.fx, record.meter_slot = add_processor(record.track, record.role, initial, settings, record.priority,
    record.downmix and record.downmix.mode_id or 1, record.dynamics)
  -- No passage-dependent envelope: each source keeps a fixed gain and a fixed
  -- transfer curve throughout the song; no musical release can pump.
  set_processor_passage_slot(record.track, record.fx, 0)
  record.passage_map_enabled = false
  record.target = target
  local sws_range = record.sws and record.sws.max_range_lu or 0
  record.dynamic_strength = 0
  record.dynamic_steps = 0
  if record.role ~= "CLICK" and sws_range > SHOW_RANGE_TARGET_LU then
    append_repair(settings, string.format(
      "SWS measured %.2f LU of natural programme range on %s; it was preserved because time-varying gain is forbidden by the hard anti-pump policy.",
      sws_range, record.name))
  end
end

local function configure_render(project, output_path, start_time, end_time, settings)
  local directory, filename = split_path(output_path)
  local pattern = strip_wav_extension(filename)
  reaper.GetSetProjectInfo_String(project, "RENDER_FILE", directory, true)
  reaper.GetSetProjectInfo_String(project, "RENDER_PATTERN", pattern, true)
  reaper.GetSetProjectInfo_String(project, "RENDER_FORMAT", WAV_24BIT_CONFIG, true)
  reaper.GetSetProjectInfo_String(project, "RENDER_FORMAT2", "", true)
  reaper.GetSetProjectInfo(project, "RENDER_SETTINGS", settings and 512 or 0, true)
  if settings then
    local comment = string.format("Bildibeat Show Track | Profile %s | %s", settings.profile_id, profile_description(settings))
    reaper.GetSetProjectInfo_String(project, "RENDER_METADATA", "INFO:ISFT|" .. SCRIPT_NAME, true)
    reaper.GetSetProjectInfo_String(project, "RENDER_METADATA", "INFO:ICMT|" .. comment, true)
    reaper.GetSetProjectInfo_String(project, "RENDER_METADATA", "BWF:Description|" .. comment, true)
  end
  reaper.GetSetProjectInfo(project, "RENDER_BOUNDSFLAG", 0, true)
  reaper.GetSetProjectInfo(project, "RENDER_STARTPOS", start_time, true)
  reaper.GetSetProjectInfo(project, "RENDER_ENDPOS", end_time, true)
  reaper.GetSetProjectInfo(project, "RENDER_CHANNELS", 2, true)
  reaper.GetSetProjectInfo(project, "RENDER_SRATE", 0, true)
  reaper.GetSetProjectInfo(project, "RENDER_NORMALIZE", 4 << 16, true)
  reaper.GetSetProjectInfo(project, "RENDER_DITHER", 16, true)
  reaper.GetSetProjectInfo(project, "RENDER_ADDTOPROJ", 0, true)
  reaper.GetSetProjectInfo(project, "RENDER_TAILFLAG", 0, true)
end

function start_project_render(project)
  -- REAPER can change the active project tab while a deferred verification or
  -- repair is pending. Main_OnCommandEx does not make every render action obey
  -- its project argument, so explicitly reselect the song immediately before
  -- invoking the render engine.
  if reaper.SelectProjectInstance then reaper.SelectProjectInstance(project) end
  reaper.Main_OnCommandEx(RENDER_ACTION_AUTOCLOSE, 0, project)
end

local function split_semicolon_list(value)
  local results = {}
  for field in (tostring(value or "") .. ";"):gmatch("(.-);") do
    if field ~= "" then results[#results + 1] = field end
  end
  return results
end

local function analyze_rendered_file(track, path)
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then error("Could not open temporary stem: " .. path) end
  local length = reaper.GetMediaSourceLength(source)
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local result = analyze_track(track, 0, length, "mono")
  reaper.DeleteTrackMediaItem(track, item)
  return result
end

function run_meter_render(project, start_time, end_time, file_analysis_track, source_selection)
  local temp_directory = join_path(reaper.GetResourcePath(), "Temp")
  reaper.RecursiveCreateDirectory(temp_directory, 0)
  local prefix = "BILDI_METER_" .. tostring(math.floor(reaper.time_precise() * 1000)) .. "_"
  local saved = {}
  for index = 0, reaper.CountTracks(project) - 1 do
    local track = reaper.GetTrack(project, index)
    saved[track] = {
      selected = reaper.IsTrackSelected(track),
      pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN"),
      name = track_name(track),
    }
    reaper.SetTrackSelected(track, false)
  end
  local selected_meters = {}
  for _, meter in ipairs(meter_registry) do
    local include_source = source_selection == true
      or (type(source_selection) == "table" and source_selection[meter.slot])
    if include_source or not meter.source then selected_meters[#selected_meters + 1] = meter end
  end
  for index, meter in ipairs(selected_meters) do
    meter.temp_name = prefix .. string.format("%03d", index)
    reaper.GetSetMediaTrackInfo_String(meter.track, "P_NAME", meter.temp_name, true)
    reaper.SetMediaTrackInfo_Value(meter.track, "D_PAN", 0)
    reaper.SetTrackSelected(meter.track, true)
  end

  local placeholder = join_path(temp_directory, prefix .. "placeholder.wav")
  configure_render(project, placeholder, start_time, end_time)
  reaper.GetSetProjectInfo_String(project, "RENDER_FILE", temp_directory, true)
  reaper.GetSetProjectInfo_String(project, "RENDER_PATTERN", prefix .. "$track", true)
  -- REAPER 7.x exposes direct selected-track stems through the stems+master
  -- source.  The stems-only flag returns no targets on some installations, so
  -- render the disposable master alongside the selected stems and ignore it.
  reaper.GetSetProjectInfo(project, "RENDER_SETTINGS", 1, true)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  local _, target_string = reaper.GetSetProjectInfo_String(project, "RENDER_TARGETS", "", false)
  local targets = split_semicolon_list(target_string)
  for _, path in ipairs(targets) do if file_exists(path) then os.remove(path) end end
  start_project_render(project)

  for track, values in pairs(saved) do
    reaper.SetTrackSelected(track, values.selected)
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", values.pan)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", values.name, true)
  end
  reaper.TrackList_AdjustWindows(false)

  local by_slot = {}
  for _, meter in ipairs(selected_meters) do
    local match
    for _, path in ipairs(targets) do
      if path:find(meter.temp_name, 1, true) then match = path; break end
    end
    if not match or not file_exists(match) then
      error("REAPER did not create the expected temporary stem for " .. meter.role)
    end
    by_slot[meter.slot] = analyze_rendered_file(file_analysis_track, match)
  end
  for _, path in ipairs(targets) do if file_exists(path) then os.remove(path) end end
  return by_slot
end

local function build_report(records, settings, final_left, final_right, ratio, output_path)
  local priorities = {LEAD = 0, RHYTHM = 0, BED = 0}
  local click_record
  for _, record in ipairs(records) do
    if record.role == "FOH" then priorities[record.priority] = priorities[record.priority] + 1 end
    if record.role == "CLICK" then click_record = record end
  end
  local lines = {
    SCRIPT_NAME,
    string.rep("=", #SCRIPT_NAME),
    "Output: " .. output_path,
    ratio and string.format("IEM target: %.1f LUFS | ceiling: %.1f dBFS | Click advantage: %.1f dB", settings.iem_target, settings.iem_ceiling, settings.click_advantage)
          or string.format("IEM target: %.1f LUFS | ceiling: %.1f dBFS | CLICK absent", settings.iem_target, settings.iem_ceiling),
    final_right.silent and "FOH absent: right channel will be digital silence"
                       or string.format("FOH target: %.1f LUFS | FOH ceiling: %.1f dBFS", settings.foh_target, settings.foh_ceiling),
    "Show profile: " .. (settings.profile_locked and "LOCKED | " or "editable | ") .. profile_description(settings),
    "Profile ID: " .. tostring(settings.profile_id or "unavailable"),
    string.format("Local render protection: temporary WAV in fixed LOCALAPPDATA work area | %d external take(s) staged locally (%d new cache file(s))",
      settings.staged_media_takes or 0, settings.staged_media_files or 0),
    settings.adaptive_foh_limiter_ceiling and string.format(
      "Adaptive limiter calibration: IEM %.2f dBFS internal | FOH %.2f dBFS internal",
      settings.adaptive_iem_limiter_ceiling, settings.adaptive_foh_limiter_ceiling)
      or string.format("Adaptive limiter calibration: IEM %.2f dBFS internal | FOH not applicable",
        settings.adaptive_iem_limiter_ceiling),
    string.format("Content time selection: %.3f to %.3f seconds (%.3f seconds)", settings.selection_start, settings.selection_end, settings.selection_duration),
    string.format("Output padding: %.3f seconds digital silence before | %.3f seconds after | expected file %.3f seconds",
      LEADING_SILENCE_SECONDS, TRAILING_SILENCE_SECONDS, settings.selection_duration + LEADING_SILENCE_SECONDS + TRAILING_SILENCE_SECONDS),
    click_record and string.format("Click replacement: metronome A %s | %s | B %s | %s | %d detected hit(s) / %d replacement item(s) | detector %.1f dBFS | %d thresholds | grid residual %.4f",
      settings.click_sample_a.filename, settings.click_sample_a.id,
      settings.click_sample_b.filename, settings.click_sample_b.id, click_record.click_hits or 0,
      click_record.click_replacement_items or 0, click_record.click_detection_threshold_db or -math.huge,
      click_record.click_thresholds_tested or 1,
      click_record.click_grid_score or 0)
      or "Click replacement: not applicable (no CLICK track)",
    settings.sws_loudness_available
      and "SWS extension: active as an item-loudness cross-check and passage-repair preflight"
      or "SWS extension: loudness API unavailable; embedded analysis used",
    string.format("Phase-aware mono preflight: %d BACKING/FOH safety fallback(s); every source decision audited",
      settings.downmix_fallbacks or 0),
    string.format("Adaptive meter passes: %d", settings.meter_passes or 0),
    "Approved reference: " .. (settings.reference and (settings.reference.source or settings.reference.reference_id or "configured") or "not configured"),
    not final_right.silent and string.format("FOH priority map: LEAD %d | RHYTHM %d | BED %d", priorities.LEAD, priorities.RHYTHM, priorities.BED) or "FOH priority map: not applicable",
    settings.hardware_safe_ceiling and string.format("Hardware-safe IEM ceiling: %.2f dBFS%s | report %s",
      settings.hardware_safe_ceiling, settings.hardware_ceiling_applied and " APPLIED" or " (profile already safer)",
      settings.hardware_report_path ~= "" and settings.hardware_report_path or "unavailable")
      or "Hardware-safe IEM ceiling: no stored loopback measurement",
    settings.project_backup_path and ("Pre-build project backup: " .. settings.project_backup_path)
      or "Pre-build project backup: not created",
  }
  if click_record then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "CLICK SAMPLE MAP"
    local ordered_labels = {"METRONOME A", "METRONOME B"}
    if settings.click_alt_sample then ordered_labels[#ordered_labels + 1] = "ALT" end
    for _, label in ipairs(ordered_labels) do
      local sample = label == "METRONOME A" and settings.click_sample_a
        or label == "METRONOME B" and settings.click_sample_b or settings.click_alt_sample
      local usage = click_record.click_sample_usage and click_record.click_sample_usage[label]
      lines[#lines + 1] = string.format(
        "%s: %s | %s | %d hit(s) | level match %+.2f dB | %s | source RMS %.2f dBFS",
        label, sample.filename, sample.id, usage and usage.hits or 0,
        sample.calibration_gain_db or 0, sample.downmix_label or "mono", sample.effective_rms_db or -math.huge)
    end
    lines[#lines + 1] = string.format("Metronome B relative to A: %+.2f dB (from project metronome settings)", settings.click_b_relative_db or 0)
    lines[#lines + 1] = string.format("ALT marker ranges: %d (all use the same ALT sample and no A/B accent)", #(settings.click_alt_ranges or {}))
    lines[#lines + 1] = "CLICK timing: only transients present on the source CLICK track are replaced; intentional gaps stay silent."
    for _, note in ipairs(settings.click_sample_level_notes or {}) do lines[#lines + 1] = "Level-match guard: " .. note end
    lines[#lines + 1] = "Boundary rule: opening CLICK ALT / ALT CLICK marker included; matching closing marker excluded."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "TRACK ANALYSIS (raw pre-FX -> script processed)"
  for _, record in ipairs(records) do
    lines[#lines + 1] = string.format(
      "%s [%s]  raw %s LUFS / %s dBFS  ->  %s LUFS / %s dBFS  constant trim %+.2f dB  intent %+.1f dB  natural range %.2f LU",
      record.name,
      record.role .. (record.priority and ("/" .. record.priority) or ""),
      format_db(record.raw.lufs),
      format_db(record.raw.peak_db),
      format_db(record.processed.lufs),
      format_db(record.processed.peak_db),
      record.input_trim,
      record.intent_offset or 0,
      record.processed.range_lu or 0
    )
    if record.dynamics then
      lines[#lines + 1] = string.format(
        "  App-owned source compression: threshold %.2f dBFS | %.2f:1 | %.1f dB soft knee | maximum %.2f dB peak reduction | no attack/release envelope",
        record.dynamics.threshold, record.dynamics.ratio,
        record.dynamics.knee, record.dynamics.max_reduction)
    else
      lines[#lines + 1] = "  App-owned source compression: OFF; fixed gain and peak guard only"
    end
    if record.downmix then
      lines[#lines + 1] = string.format(
        "  Phase-aware mono: %s | correlation %s | normal L+R fold %s dB | risky windows %d/%d (%.0f%%) | %s",
        record.downmix.label,
        finite(record.downmix.correlation) and string.format("%.3f", record.downmix.correlation) or "n/a",
        format_db(record.downmix.fold_loss_db), record.downmix.risk_windows or 0,
        record.downmix.active_windows or 0, 100 * (record.downmix.risk_fraction or 0),
        record.downmix.reason or "deterministic selection")
    end
    if record.sws and record.sws.items > 0 then
      lines[#lines + 1] = string.format(
        "  SWS cross-check: %d overlapping item(s), maximum item range %.2f LU%s",
        record.sws.items, record.sws.max_range_lu or 0,
        record.sws.loudest_short_term_time and string.format(", loudest short-term passage begins at %.3f s", record.sws.loudest_short_term_time) or "")
    end
    if record.sws and record.sws.failed > 0 then
      lines[#lines + 1] = string.format(
        "  SWS cross-check: %d item analysis call(s) failed; embedded selected-range measurements remained active",
        record.sws.failed)
    end
    if record.role ~= "CLICK" and record.raw.passage_map then
      lines[#lines + 1] = string.format(
        "  Dynamics scan (audit only): %d active point(s), %.2f s spacing; source analysis %s; average concurrency %.2f (max %d); passage gain DISABLED",
        record.raw.passage_map.active_points or 0,
        record.raw.passage_map.step_seconds or 0, record.raw.cache_hit and "CACHE HIT" or "fresh",
        record.average_concurrency or 1, record.maximum_concurrency or 1)
    end
  end
  if settings.repair_log and #settings.repair_log > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "AUTOMATIC CORRECTIONS"
    for _, repair in ipairs(settings.repair_log) do lines[#lines + 1] = "- " .. repair end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "SOURCE HEALTH"
  for _, record in ipairs(records) do
    lines[#lines + 1] = string.format(
      "%s  formats %s  rates %s Hz  clipped %d  DC %s dBFS  sub20 %s dB",
      record.name,
      record.media_formats and table.concat(record.media_formats, "/") or "unknown",
      record.media_rates and table.concat(record.media_rates, "/") or "unknown",
      record.raw.clipped_samples or 0,
      format_db(record.raw.dc_db),
      format_db(record.raw.infra_ratio_db)
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ratio and string.format("Measured click/backing advantage: %.2f dB", ratio)
                              or "Measured click/backing advantage: not applicable (no CLICK track)"
  lines[#lines + 1] = string.format("Final left:  %s LUFS / %s dBFS / %.2f LU short-term range", format_db(final_left.lufs), format_db(final_left.peak_db), final_left.range_lu or 0)
  lines[#lines + 1] = final_right.silent and "Final right: digital silence (no FOH track)"
                                            or string.format("Final right: %s LUFS / %s dBFS / %.2f LU short-term range", format_db(final_right.lufs), format_db(final_right.peak_db), final_right.range_lu or 0)
  return table.concat(lines, "\n")
end

local function validation_errors(records, settings, final_left, final_right, ratio)
  local errors, warnings = {}, {}
  local function loudness_failure(side_name, measured, target, ceiling, runtime_side)
    local difference = target - measured.lufs
    if difference > 0 and measured.peak_db > ceiling - 0.75 then
      return string.format(
        "%s remained %.2f LU too quiet because more constant gain would violate the %.2f dBFS peak ceiling.",
        side_name, difference, ceiling)
    end
    local active_gain = runtime_side and runtime_side.compression_strength > EPS
      and runtime_side.makeup or (runtime_side and runtime_side.trim)
    local upper_guard = runtime_side and runtime_side.compression_strength > EPS and 23.9 or 35.9
    local lower_guard = runtime_side and runtime_side.compression_strength > EPS and -23.9 or -29.9
    if runtime_side and ((difference > 0 and active_gain >= upper_guard) or (difference < 0 and active_gain <= lower_guard)) then
      return string.format(
        "%s remained %.2f LU from target after automatic gain reached its safe guard; inspect the source level and routing.",
        side_name, math.abs(difference))
    end
    return string.format(
      "%s loudness %.2f LUFS remained %.2f LU from the %.2f LUFS target after bounded automatic correction.",
      side_name, measured.lufs, math.abs(difference), target)
  end
  if final_left.peak_db > settings.iem_ceiling + 0.10 then
    errors[#errors + 1] = string.format(
      "Left peak %.2f dBFS still exceeds the %.2f dBFS ceiling after automatic limiter calibration.",
      final_left.peak_db, settings.iem_ceiling)
  end
  if math.abs(final_left.lufs - settings.iem_target) > LOUDNESS_REPAIR_THRESHOLD_LU then
    errors[#errors + 1] = loudness_failure(
      "Left", final_left, settings.iem_target, settings.iem_ceiling, settings.runtime and settings.runtime.iem)
  end
  if (final_left.range_lu or 0) > SHOW_RANGE_HARD_LIMIT_LU then
    warnings[#warnings + 1] = string.format(
      "Left natural programme range %.2f LU exceeds the %.2f LU preference; it was preserved to prevent pumping.",
      final_left.range_lu, SHOW_RANGE_HARD_LIMIT_LU)
  elseif (final_left.range_lu or 0) > SHOW_RANGE_TARGET_LU then
    warnings[#warnings + 1] = string.format(
      "Left short-term loudness range %.2f LU is slightly above the %.2f LU show target; rendered because peaks and integrated loudness are safe.",
      final_left.range_lu, SHOW_RANGE_TARGET_LU)
  end
  if not final_right.silent then
    if final_right.peak_db > settings.foh_ceiling + 0.10 then
      errors[#errors + 1] = string.format(
        "Right peak %.2f dBFS still exceeds the %.2f dBFS ceiling after automatic limiter calibration.",
        final_right.peak_db, settings.foh_ceiling)
    end
    if math.abs(final_right.lufs - settings.foh_target) > LOUDNESS_REPAIR_THRESHOLD_LU then
      errors[#errors + 1] = loudness_failure(
        "Right", final_right, settings.foh_target, settings.foh_ceiling, settings.runtime and settings.runtime.foh)
    end
    if (final_right.range_lu or 0) > SHOW_RANGE_HARD_LIMIT_LU then
      warnings[#warnings + 1] = string.format(
        "Right natural programme range %.2f LU exceeds the %.2f LU preference; it was preserved to prevent pumping.",
        final_right.range_lu, SHOW_RANGE_HARD_LIMIT_LU)
    elseif (final_right.range_lu or 0) > SHOW_RANGE_TARGET_LU then
      warnings[#warnings + 1] = string.format(
        "Right short-term loudness range %.2f LU is slightly above the %.2f LU show target; rendered because peaks and integrated loudness are safe.",
        final_right.range_lu, SHOW_RANGE_TARGET_LU)
    end
  end
  if ratio and math.abs(ratio - settings.click_advantage) > CLICK_RATIO_TOLERANCE_DB then
    errors[#errors + 1] = string.format(
      "Click/backing advantage %.2f dB remained %.2f dB from target after isolated click-bus correction.",
      ratio, math.abs(ratio - settings.click_advantage))
  end
  for _, record in ipairs(records) do
    if record.sws and record.sws.failed > 0 then
      warnings[#warnings + 1] = string.format(
        "%s had %d failed SWS item scan(s); embedded selected-range analysis and actual-WAV verification were used.",
        record.name, record.sws.failed)
    end
    if record.processed.range_lu > SHOW_RANGE_TARGET_LU then
      warnings[#warnings + 1] = string.format("%s retains %.2f LU of short-term range.", record.name, record.processed.range_lu)
    end
    if record.input_trim >= 18 then
      warnings[#warnings + 1] = record.name .. " required at least +18 dB of gain; check its source noise floor."
    end
    if record.input_trim >= 35.9 then
      warnings[#warnings + 1] = record.name .. " reached the +36 dB source-gain boundary; the constant bus trim supplied only correction allowed by peak headroom."
    end
    if (record.raw.clipped_samples or 0) > 0 then
      warnings[#warnings + 1] = string.format("%s contains %d near-full-scale sample(s); embedded clipping cannot be repaired by limiting.", record.name, record.raw.clipped_samples)
    end
    if finite(record.raw.dc_db) and record.raw.dc_db > -50 then
      warnings[#warnings + 1] = string.format("%s has measurable DC offset at %.1f dBFS.", record.name, record.raw.dc_db)
    end
    if finite(record.raw.infra_ratio_db) and record.raw.infra_ratio_db > -18 then
      warnings[#warnings + 1] = string.format("%s has unusually strong sub-20 Hz energy (%.1f dB relative to total RMS).", record.name, record.raw.infra_ratio_db)
    end
    if record.role ~= "CLICK" and finite(record.raw.start_peak_db) and record.raw.start_peak_db > -24 then
      warnings[#warnings + 1] = string.format("%s begins abruptly at %.1f dBFS; inspect the leading edit/fade.", record.name, record.raw.start_peak_db)
    end
    if record.role ~= "CLICK" and finite(record.raw.end_peak_db) and record.raw.end_peak_db > -24 then
      warnings[#warnings + 1] = string.format("%s ends abruptly at %.1f dBFS; inspect the trailing edit/fade.", record.name, record.raw.end_peak_db)
    end
    if record.lossy_sources and #record.lossy_sources > 0 then
      warnings[#warnings + 1] = string.format("%s uses %d lossy source file(s); use PCM WAV when possible.", record.name, #record.lossy_sources)
    end
    if record.media_rates and #record.media_rates > 1 then
      warnings[#warnings + 1] = string.format("%s mixes source sample rates (%s Hz).", record.name, table.concat(record.media_rates, ", "))
    end
  end
  return errors, warnings
end

local function run_build(project, records, by_role, settings, output_path, start_time, end_time)
  settings.source_dynamics_applied = true
  local has_click = #by_role.CLICK == 1
  local has_foh = #by_role.FOH > 0
  local backing_bus_target = has_click and (settings.iem_target - settings.click_advantage) or settings.iem_target
  settings.sws_loudness_available = reaper.APIExists
    and reaper.APIExists("NF_AnalyzeTakeLoudness2") or false
  meter_registry, meter_next_slot = {}, 1
  progress_update("Preparing project", "Removing prior generated buses and neutralizing labeled sources.", 0.03, true)
  progress_abort_if_requested()
  delete_generated_buses(project)
  stage_external_source_media(project, records, settings)
  sanitize_master(project)
  for _, record in ipairs(records) do sanitize_source_track(record) end
  isolate_labeled_sources(project, records)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  console("Analyzing raw labeled tracks at unity, pre-FX...")
  console(settings.sws_loudness_available
    and "SWS loudness preflight is available as an independent measurement cross-check."
    or "SWS loudness preflight is unavailable; continuing with the embedded analyzer.")
  for record_index, record in ipairs(records) do
    progress_update("Analyzing source audio", string.format("%d of %d: %s", record_index, #records, record.name),
      0.06 + 0.16 * record_index / math.max(#records, 1), true)
    progress_abort_if_requested()
    if record.role == "CLICK" then
      record.timing_raw = analyze_track(record.track, start_time, end_time, "mono")
      create_click_replacement(project, record, settings, start_time, end_time)
      inspect_source_media(record)
      record.raw = analyze_track(record.track, start_time, end_time, "mono")
    else
      inspect_source_media(record)
      record.downmix_profile = analyze_downmix_profile(record.track, start_time, end_time)
      record.downmix = select_downmix_mode(record.downmix_profile)
      record.raw = cached_track_analysis(project, record, start_time, end_time)
        or analyze_track(record.track, start_time, end_time, record.downmix.analysis_mode)
      if not record.raw.cache_hit then save_cached_track_analysis(project, record) end
      console(string.format("%s phase-aware mono: %s (correlation %s, normal fold %s dB, cancellation windows %d/%d).",
        record.name, record.downmix.label,
        finite(record.downmix.correlation) and string.format("%.3f", record.downmix.correlation) or "n/a",
        format_db(record.downmix.fold_loss_db), record.downmix.risk_windows, record.downmix.active_windows))
      if record.downmix.mode ~= "sum" then
        settings.downmix_fallbacks = (settings.downmix_fallbacks or 0) + 1
        append_repair(settings, string.format(
          "%s used %s because %s; normal L+R measured %s dB relative to the stronger source channel with %.0f%% risky active windows.",
          record.name, record.downmix.label, record.downmix.reason, format_db(record.downmix.fold_loss_db),
          100 * record.downmix.risk_fraction))
      end
    end
    record.sws = analyze_source_with_sws(record, start_time, end_time)
    if record.raw.silent then
      error(record.name .. " has no measurable raw audio. MIDI instruments and take-FX-generated audio are intentionally excluded by the pre-FX source measurement contract.")
    end
    apply_role_pan(record)
  end

  allocate_simultaneous_tracks(records, "BACKING", settings)
  allocate_simultaneous_tracks(records, "FOH", settings)

  console("Preparing independent CLICK, BACKING, and FOH processors...")
  progress_update("Building processors", "Creating independent constant-gain CLICK, BACKING, and FOH paths.", 0.24, true)
  progress_abort_if_requested()
  for _, record in ipairs(records) do prepare_source_processor(record, settings) end

  local backing_bus = create_bus(project, "#SHOW BACKING BUS", "BACKING", false, 0, false)
  local iem_bus = create_bus(project, "#SHOW IEM LEFT", "IEM", true, -1, false)
  local click_bus = has_click and create_bus(project, "#SHOW CLICK BUS", "CLICK", false, 0, false) or nil
  local foh_bus = has_foh and create_bus(project, "#SHOW FOH RIGHT", "FOH", true, 1, false) or nil

  if has_click then
    for _, record in ipairs(by_role.CLICK) do create_send(record.track, click_bus) end
  end
  for _, record in ipairs(by_role.BACKING) do create_send(record.track, backing_bus) end
  if has_foh then
    for _, record in ipairs(by_role.FOH) do create_send(record.track, foh_bus) end
  end

  local click_trim, click_fx, click_slot = 0, nil, nil
  if has_click then click_fx, click_slot = add_processor(click_bus, "CLICK_BUS", click_trim, settings) end
  local backing_trim = 0
  local backing_fx, backing_slot = add_processor(backing_bus, "BACKING_BUS", backing_trim, settings)
  local foh_trim, foh_fx, foh_slot = 0, nil, nil
  if has_foh then foh_fx, foh_slot = add_processor(foh_bus, "FOH_BUS", foh_trim, settings) end

  if has_click then create_send(click_bus, iem_bus) end
  create_send(backing_bus, iem_bus)
  local iem_trim = 0
  local iem_fx, iem_slot = add_processor(iem_bus, "IEM_BUS", iem_trim, settings)
  local iem_limiter_ceiling = settings.iem_ceiling - 0.5
  local foh_limiter_ceiling = settings.foh_ceiling - 0.5
  local file_analysis = create_bus(project, "#SHOW FILE ANALYSIS (temporary)", "ANALYSIS", false, 0, true)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  local click_measure, backing_measure, final_left, final_right, ratio
  local iem_dynamic_strength, foh_dynamic_strength = 0, 0
  local iem_dynamic_steps, foh_dynamic_steps = 0, 0
  local iem_compression_strength, foh_compression_strength = 0, 0
  local iem_makeup, foh_makeup = 0, 0
  local iem_solver, foh_solver = {}, {}
  local fallback_logged = false
  local source_selection = true
  console(string.format("Running %d-%d adaptive offline meter passes through REAPER's render engine...", MIN_METER_PASSES, MAX_METER_PASSES))
  for pass = 1, MAX_METER_PASSES do
    progress_update("Measuring and correcting", string.format("Offline meter pass %d of at most %d", pass, MAX_METER_PASSES),
      0.30 + 0.58 * pass / MAX_METER_PASSES, true)
    progress_abort_if_requested()
    local next_source_selection = {}
    -- FOH hierarchy is expressed as static target offsets. Dynamic priority
    -- sends are deliberately not engaged: sidechain ducking is a direct source
    -- of audible breathing when several FOH stems play together.
    if pass == 3 and has_foh then
      local lead_count, rhythm_count, bed_count = 0, 0, 0
      for _, record in ipairs(by_role.FOH) do
        if record.priority == "LEAD" then lead_count = lead_count + 1
        elseif record.priority == "BED" then bed_count = bed_count + 1
        else rhythm_count = rhythm_count + 1 end
      end
      console(string.format(
        "Anti-pump static FOH priority: %d LEAD (+1.0 dB), %d RHYTHM, %d BED (-1.5 dB); dynamic ducking disabled.",
        lead_count, rhythm_count, bed_count))
    end
    local meters = run_meter_render(project, start_time, end_time, file_analysis, source_selection)
    for _, record in ipairs(records) do
      if meters[record.meter_slot] then
        record.processed = meters[record.meter_slot]
        if record.processed.silent then error(record.name .. " is silent after processing.") end
      end
    end
    click_measure = has_click and meters[click_slot] or nil
    backing_measure = meters[backing_slot]
    final_left = meters[iem_slot]
    final_right = has_foh and meters[foh_slot] or {
      lufs = -math.huge, active_lufs = -math.huge, range_lu = 0,
      peak = 0, peak_db = -math.huge, silent = true,
    }
    if (has_click and click_measure.silent) or backing_measure.silent or final_left.silent or (has_foh and final_right.silent) then
      error("A generated output bus is unexpectedly silent during the meter render.")
    end
    ratio = has_click and (click_measure.active_lufs - backing_measure.active_lufs) or nil

    -- A limiter ceiling set inside the FX can still be followed by project- or
    -- routing-specific gain. Close the safety loop around the measured bus:
    -- lower the internal ceiling by the exact measured overshoot, then require
    -- another offline render before convergence is allowed.
    local iem_structure_changed, foh_structure_changed = false, false
    local iem_component_stale, iem_final_stale, foh_final_stale = false, false, false
    local iem_upstream_changed = false
    local iem_measured_peak_target = settings.iem_ceiling - 0.35
    if pass < MAX_METER_PASSES and final_left.peak_db > settings.iem_ceiling - 0.10 then
      local correction = final_left.peak_db - iem_measured_peak_target
      iem_limiter_ceiling = clamp(iem_limiter_ceiling - correction, -60, settings.iem_ceiling - 0.5)
      set_processor_ceiling(iem_bus, iem_fx, iem_limiter_ceiling)
      iem_structure_changed = true
      reset_solver(iem_solver)
      append_repair(settings, string.format(
        "Pass %d: lowered the IEM limiter by %.2f dB after the measured peak approached its ceiling.", pass, correction))
    end
    if has_foh then
      local foh_measured_peak_target = settings.foh_ceiling - 0.35
      if pass < MAX_METER_PASSES and final_right.peak_db > settings.foh_ceiling - 0.10 then
        local correction = final_right.peak_db - foh_measured_peak_target
        foh_limiter_ceiling = clamp(foh_limiter_ceiling - correction, -60, settings.foh_ceiling - 0.5)
        set_processor_ceiling(foh_bus, foh_fx, foh_limiter_ceiling)
        foh_structure_changed = true
        reset_solver(foh_solver)
        append_repair(settings, string.format(
          "Pass %d: lowered the FOH limiter by %.2f dB after the measured peak approached its ceiling.", pass, correction))
      end
    end

    -- Lock the component buses first, then use the final IEM bus to close the
    -- last fraction of a LU. This prevents BACKING and IEM corrections from
    -- chasing each other in sparse or backing-only projects.
    local backing_error = backing_bus_target - backing_measure.lufs
    local backing_ready = math.abs(backing_error) <= BUS_COMPONENT_TOLERANCE_LU
    local click_error = has_click and (settings.click_advantage - ratio) or 0
    local click_ready = not has_click or math.abs(click_error) <= CLICK_COMPONENT_TOLERANCE_DB

    -- Repair uneven passages on every musical source independently. This keeps
    -- one unstable stem from making the other simultaneous stems disappear.
    -- CLICK uses transient-specific peak control instead, preserving its attack.
    if pass >= MIN_METER_PASSES and pass < MAX_METER_PASSES then
      for _, record in ipairs(records) do
        if record.role ~= "CLICK" and (record.processed.range_lu or 0) > SHOW_RANGE_TARGET_LU + 0.05
            and record.dynamic_strength < MAX_DYNAMIC_REPAIR_DB
            and record.dynamic_steps < MAX_DYNAMIC_REPAIR_STEPS then
          local desired = clamp(6 + ((record.processed.range_lu or 0) - SHOW_RANGE_TARGET_LU) * 2,
            6, MAX_DYNAMIC_REPAIR_DB)
          record.dynamic_strength = math.max(record.dynamic_strength, desired)
          record.dynamic_steps = record.dynamic_steps + 1
          record.level_target_rms = record.level_target_rms or record.processed.rms_db or record.processed.lufs
          set_processor_leveler(record.track, record.fx, record.level_target_rms, record.dynamic_strength)
          next_source_selection[record.meter_slot] = true
          if record.role == "BACKING" then
            iem_structure_changed = true
            iem_component_stale, iem_final_stale = true, true
          else
            foh_structure_changed, foh_final_stale = true, true
          end
          append_repair(settings, string.format(
            "Pass %d: increased passage-specific leveling on %s to %.2f dB because that track varied by %.2f LU.",
            pass, record.name, record.dynamic_strength, record.processed.range_lu or 0))
        end
      end
    end

    -- Then repair any remaining wide variation on the combined musical bus.
    -- CLICK remains on its own bus so its advantage is corrected independently.
    if pass >= MIN_METER_PASSES and pass < MAX_METER_PASSES
        and (final_left.range_lu or 0) > SHOW_RANGE_TARGET_LU + 0.05
        and not iem_component_stale
        and iem_dynamic_strength < MAX_DYNAMIC_REPAIR_DB and iem_dynamic_steps < MAX_DYNAMIC_REPAIR_STEPS then
      local desired = clamp(6 + ((final_left.range_lu or 0) - SHOW_RANGE_TARGET_LU) * 2,
        6, MAX_DYNAMIC_REPAIR_DB)
      iem_dynamic_strength = math.max(iem_dynamic_strength, desired)
      iem_dynamic_steps = iem_dynamic_steps + 1
      set_processor_leveler(backing_bus, backing_fx, backing_measure.rms_db or backing_measure.lufs, iem_dynamic_strength)
      iem_structure_changed = true
      iem_component_stale, iem_final_stale = true, true
      reset_solver(iem_solver)
      append_repair(settings, string.format(
        "Pass %d: increased IEM musical-bed leveling to %.2f dB because short-term range measured %.2f LU.",
        pass, iem_dynamic_strength, final_left.range_lu or 0))
    end
    if has_foh and pass >= MIN_METER_PASSES and pass < MAX_METER_PASSES
        and (final_right.range_lu or 0) > SHOW_RANGE_TARGET_LU + 0.05
        and not foh_final_stale
        and foh_dynamic_strength < MAX_DYNAMIC_REPAIR_DB and foh_dynamic_steps < MAX_DYNAMIC_REPAIR_STEPS then
      local desired = clamp(6 + ((final_right.range_lu or 0) - SHOW_RANGE_TARGET_LU) * 2,
        6, MAX_DYNAMIC_REPAIR_DB)
      foh_dynamic_strength = math.max(foh_dynamic_strength, desired)
      foh_dynamic_steps = foh_dynamic_steps + 1
      set_processor_leveler(foh_bus, foh_fx, final_right.rms_db or final_right.lufs, foh_dynamic_strength)
      foh_structure_changed = true
      foh_final_stale = true
      reset_solver(foh_solver)
      append_repair(settings, string.format(
        "Pass %d: increased FOH bus leveling to %.2f dB because short-term range measured %.2f LU.",
        pass, foh_dynamic_strength, final_right.range_lu or 0))
    end

    -- Large IEM loudness misses are corrected before the click and backing are
    -- summed. Applying the same gain to both component buses preserves their
    -- measured ratio while the dedicated click limiter contains click peaks.
    -- This avoids asking one sharp click transient to set the gain for the
    -- entire IEM mix.
    local iem_loudness_error = settings.iem_target - final_left.lufs
    if has_click and pass >= MIN_METER_PASSES and pass < MAX_METER_PASSES and backing_ready and click_ready
        and math.abs(iem_loudness_error) > 0.75
        and final_left.peak_db < settings.iem_ceiling - 1.50
        and not iem_component_stale and not iem_final_stale then
      local common_correction = clamp(iem_loudness_error, -6, 6)
      backing_bus_target = backing_bus_target + common_correction
      backing_trim = clamp(backing_trim + common_correction, -30, 36)
      click_trim = clamp(click_trim + common_correction, -30, 36)
      set_processor_input(backing_bus, backing_fx, backing_trim)
      set_processor_input(click_bus, click_fx, click_trim)
      iem_structure_changed = true
      iem_component_stale, iem_final_stale = true, true
      iem_upstream_changed = true
      reset_solver(iem_solver)
      append_repair(settings, string.format(
        "Pass %d: moved %+.2f dB of IEM correction upstream to CLICK and BACKING together, preserving their ratio while containing click peaks separately.",
        pass, common_correction))
    end

    -- If a side is still too quiet while already near its ceiling, plain gain
    -- cannot solve both requirements. Increase bus compression decisively to
    -- create usable headroom, then let a measured pass add the exact gain.
    local iem_peak_headroom = settings.iem_ceiling - final_left.peak_db
    local iem_headroom_deficit = iem_loudness_error - math.max(0, iem_peak_headroom - 0.50)
    if pass >= MIN_METER_PASSES and pass < MAX_METER_PASSES
        and iem_loudness_error > LOUDNESS_NORMAL_TOLERANCE_LU
        and iem_headroom_deficit > 0.20
        and not iem_upstream_changed
        and iem_compression_strength < MAX_FINAL_COMPRESSION_STRENGTH then
      local compression_increment = clamp(iem_headroom_deficit * 1.75, 1, 12)
      iem_compression_strength = clamp(iem_compression_strength + compression_increment, 0, MAX_FINAL_COMPRESSION_STRENGTH)
      set_processor_compression(iem_bus, iem_fx, settings.iem_ceiling, iem_compression_strength)
      iem_structure_changed = true
      iem_final_stale = true
      reset_solver(iem_solver)
      append_repair(settings, string.format(
        "Pass %d: increased final IEM compression because the side was %.2f LU quiet with only %.2f dB of peak headroom.",
        pass, iem_loudness_error, settings.iem_ceiling - final_left.peak_db))
    end
    local foh_loudness_error = has_foh and (settings.foh_target - final_right.lufs) or 0
    local foh_peak_headroom = has_foh and (settings.foh_ceiling - final_right.peak_db) or math.huge
    local foh_headroom_deficit = foh_loudness_error - math.max(0, foh_peak_headroom - 0.50)
    if has_foh and pass >= MIN_METER_PASSES and pass < MAX_METER_PASSES
        and foh_loudness_error > LOUDNESS_NORMAL_TOLERANCE_LU
        and foh_headroom_deficit > 0.20
        and foh_compression_strength < MAX_FINAL_COMPRESSION_STRENGTH then
      local compression_increment = clamp(foh_headroom_deficit * 1.75, 1, 12)
      foh_compression_strength = clamp(foh_compression_strength + compression_increment, 0, MAX_FINAL_COMPRESSION_STRENGTH)
      set_processor_compression(foh_bus, foh_fx, settings.foh_ceiling, foh_compression_strength)
      foh_structure_changed = true
      foh_final_stale = true
      reset_solver(foh_solver)
      append_repair(settings, string.format(
        "Pass %d: increased final FOH compression because the side was %.2f LU quiet with only %.2f dB of peak headroom.",
        pass, foh_loudness_error, settings.foh_ceiling - final_right.peak_db))
    end

    local iem_range_resolved = (final_left.range_lu or 0) <= SHOW_RANGE_TARGET_LU + 0.05
      or iem_dynamic_strength >= MAX_DYNAMIC_REPAIR_DB or iem_dynamic_steps >= MAX_DYNAMIC_REPAIR_STEPS
    local foh_range_resolved = not has_foh or (final_right.range_lu or 0) <= SHOW_RANGE_TARGET_LU + 0.05
      or foh_dynamic_strength >= MAX_DYNAMIC_REPAIR_DB or foh_dynamic_steps >= MAX_DYNAMIC_REPAIR_STEPS

    local converged = pass >= MIN_METER_PASSES
      and not iem_structure_changed
      and not foh_structure_changed
      and backing_ready
      and click_ready
      and iem_range_resolved
      and foh_range_resolved
      and math.abs(final_left.lufs - settings.iem_target) <= LOUDNESS_REPAIR_THRESHOLD_LU
      and (not has_click or math.abs(ratio - settings.click_advantage) <= CLICK_RATIO_TOLERANCE_DB)
      and (not has_foh or math.abs(final_right.lufs - settings.foh_target) <= LOUDNESS_REPAIR_THRESHOLD_LU)
      and final_left.peak_db <= settings.iem_ceiling + 0.05
      and (not has_foh or final_right.peak_db <= settings.foh_ceiling + 0.05)
    settings.meter_passes = pass
    if converged then
      console(string.format("Meter convergence confirmed after %d passes.", pass))
      break
    end

    if pass >= FAST_METER_PASSES and not fallback_logged then
      fallback_logged = true
      append_repair(settings, string.format(
        "Pass %d: fast convergence was not complete; switched to smaller fallback corrections.", pass))
    end

    if pass < MAX_METER_PASSES then
      if pass <= 2 then
        for _, record in ipairs(records) do
          local correction
          if record.role == "CLICK" then correction = record.target - record.processed.peak_db
          else correction = record.target - record.processed.lufs end
          correction = clamp(correction, -6, 6)
          record.input_trim = clamp(record.input_trim + correction, -60, 36)
          set_processor_input(record.track, record.fx, record.input_trim)
          next_source_selection[record.meter_slot] = true
        end
      end

      if not iem_component_stale and not backing_ready then
        backing_trim = clamp(backing_trim + clamp(backing_error, -8, 8), -30, 36)
        set_processor_input(backing_bus, backing_fx, backing_trim)
      end
      if not iem_component_stale and has_click and not click_ready then
        click_trim = clamp(click_trim + clamp(click_error, -8, 8), -30, 36)
        set_processor_input(click_bus, click_fx, click_trim)
      end
      if has_foh and not foh_final_stale and math.abs(foh_loudness_error) > 0.05 then
        if foh_compression_strength > EPS then
          local foh_correction = clamp(foh_loudness_error, -6, 6)
          foh_makeup = clamp(foh_makeup + foh_correction, -24, 24)
          set_processor_makeup(foh_bus, foh_fx, foh_makeup)
        else
          local foh_correction = solve_loudness_correction(
            foh_solver, foh_trim, final_right.lufs, settings.foh_target, pass >= FAST_METER_PASSES)
          foh_trim = clamp(foh_trim + foh_correction, -30, 36)
          set_processor_input(foh_bus, foh_fx, foh_trim)
        end
      end
      if not iem_final_stale and not iem_upstream_changed and pass >= 3 and backing_ready and click_ready
          and math.abs(iem_loudness_error) > 0.05 then
        if iem_compression_strength > EPS then
          local iem_correction = clamp(iem_loudness_error, -6, 6)
          iem_makeup = clamp(iem_makeup + iem_correction, -24, 24)
          set_processor_makeup(iem_bus, iem_fx, iem_makeup)
        else
          local iem_correction = solve_loudness_correction(
            iem_solver, iem_trim, final_left.lufs, settings.iem_target, pass >= FAST_METER_PASSES)
          iem_trim = clamp(iem_trim + iem_correction, -30, 36)
          set_processor_input(iem_bus, iem_fx, iem_trim)
        end
      end
    end
    source_selection = next_source_selection
  end

  reaper.DeleteTrack(file_analysis)

  progress_update("Preparing render", "Meter convergence is complete. Building the compact verification summary.", 0.91, true)
  progress_abort_if_requested()

  settings.final_click_ratio = ratio
  if has_click then
    settings.click_hit_times = by_role.CLICK[1].click_hit_times
    settings.click_audibility_floor_db = math.max(5, settings.click_advantage - 1)
  end
  settings.meter_final_left = final_left
  settings.meter_final_right = final_right
  settings.adaptive_iem_limiter_ceiling = iem_limiter_ceiling
  settings.adaptive_foh_limiter_ceiling = has_foh and foh_limiter_ceiling or nil
  settings.runtime = {
    -- Keep the exact source-to-bus graph so every final render can verify and
    -- restore it instead of trusting mutable REAPER render state.
    sources = {CLICK = by_role.CLICK, BACKING = by_role.BACKING, FOH = by_role.FOH},
    iem = {track = iem_bus, fx = iem_fx, trim = iem_trim, limiter_ceiling = iem_limiter_ceiling,
      meter_slot = iem_slot,
      compression_strength = iem_compression_strength, makeup = iem_makeup,
      dynamic_strength = iem_dynamic_strength,
      -- Post-render passage repair is applied to the complete left bus so it
      -- cannot change the already verified CLICK/BACKING ratio.
      level_track = iem_bus, level_fx = iem_fx,
      level_target_rms = final_left.rms_db or final_left.lufs},
    foh = has_foh and {track = foh_bus, fx = foh_fx, trim = foh_trim, limiter_ceiling = foh_limiter_ceiling,
      meter_slot = foh_slot,
      compression_strength = foh_compression_strength, makeup = foh_makeup,
      dynamic_strength = foh_dynamic_strength,
      level_track = foh_bus, level_fx = foh_fx,
      level_target_rms = final_right.rms_db or final_right.lufs} or nil,
    backing = {track = backing_bus, fx = backing_fx, trim = backing_trim, meter_slot = backing_slot},
    click = has_click and {track = click_bus, fx = click_fx, trim = click_trim, meter_slot = click_slot} or nil,
  }
  configure_render(project, settings.render_output_path or output_path, start_time, end_time, settings)
  local report = build_report(records, settings, final_left, final_right, ratio, output_path)
  local errors, warnings = validation_errors(records, settings, final_left, final_right, ratio)
  return report, errors, warnings
end

local function wav_layout(path)
  local handle, open_error = io.open(path, "rb")
  if not handle then return nil, open_error end
  local file_size = handle:seek("end")
  handle:seek("set", 0)
  local header = handle:read(12)
  if not header or #header ~= 12 or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
    handle:close()
    return nil, "The rendered file is not a standard RIFF/WAVE file."
  end
  local layout = {file_size = file_size}
  local position = 12
  while position + 8 <= file_size do
    handle:seek("set", position)
    local chunk_header = handle:read(8)
    if not chunk_header or #chunk_header < 8 then break end
    local chunk_id, chunk_size = string.unpack("<c4I4", chunk_header)
    local payload = position + 8
    if chunk_id == "fmt " and not layout.sample_rate then
      handle:seek("set", payload)
      local format = handle:read(math.min(chunk_size, 40))
      if not format or #format < 16 then handle:close(); return nil, "The WAV format chunk is incomplete." end
      layout.audio_format, layout.channels, layout.sample_rate, layout.byte_rate, layout.block_align, layout.bits_per_sample =
        string.unpack("<I2I2I4I4I2I2", format)
    elseif chunk_id == "data" and not layout.data_offset then
      layout.data_header_offset = position
      layout.data_offset = payload
      layout.data_size = chunk_size
    end
    position = payload + chunk_size + (chunk_size % 2)
  end
  handle:close()
  if not layout.data_offset or not layout.sample_rate then return nil, "The WAV is missing its format or audio-data chunk." end
  if layout.channels ~= 2 or layout.bits_per_sample ~= 24 or layout.block_align ~= 6 then
    return nil, string.format("Expected stereo 24-bit PCM WAV; received %d channel(s), %d-bit, block align %d.",
      layout.channels or 0, layout.bits_per_sample or 0, layout.block_align or 0)
  end
  if layout.audio_format ~= 1 and layout.audio_format ~= 0xFFFE then
    return nil, string.format("Expected PCM WAV format; received format code %d.", layout.audio_format or -1)
  end
  if layout.data_offset + layout.data_size > file_size then return nil, "The WAV audio-data chunk exceeds the file size." end
  return layout
end

-- REAPER's audio accessor is fixed at 48 kHz, but the published WAV may be
-- 44.1 kHz. Scan its actual 24-bit PCM words at the file rate so resampling
-- cannot hide a sample peak. Keep the more conservative of this native result,
-- REAPER's intersample estimate, and SWS's independent true-peak cross-check.
function wav_native_peaks(path, content_start, content_duration)
  local layout, problem = wav_layout(path)
  if not layout then return nil, problem end
  local total_frames = math.floor(layout.data_size / layout.block_align)
  local first = math.max(0, math.floor((content_start or 0) * layout.sample_rate + 0.5))
  local wanted = math.max(0, math.floor((content_duration or 0) * layout.sample_rate + 0.5))
  local frames = math.min(wanted, math.max(0, total_frames - first))
  if frames <= 0 then return nil, "The WAV has no selected-content frames to scan." end
  local input, open_error = io.open(path, "rb")
  if not input then return nil, open_error end
  input:seek("set", layout.data_offset + first * layout.block_align)
  local sample_left, sample_right, true_left, true_right = 0, 0, 0, 0
  local l0, l1, l2, r0, r1, r2
  local remaining = frames
  while remaining > 0 do
    local count = math.min(8192, remaining)
    local bytes = input:read(count * 6)
    if not bytes or #bytes ~= count * 6 then
      input:close()
      return nil, "The native-rate PCM scan reached an incomplete audio frame."
    end
    local position = 1
    for _ = 1, count do
      local left, right
      left, right, position = string.unpack("<i3i3", bytes, position)
      left, right = left / 8388608, right / 8388608
      sample_left = math.max(sample_left, math.abs(left))
      sample_right = math.max(sample_right, math.abs(right))
      true_left = math.max(true_left, math.abs(left))
      true_right = math.max(true_right, math.abs(right))
      if l0 then
        for phase = 1, 3 do
          local fraction = phase * 0.25
          local square, cube = fraction * fraction, fraction * fraction * fraction
          local left_between = 0.5 * (2 * l1 + (-l0 + l2) * fraction
            + (2 * l0 - 5 * l1 + 4 * l2 - left) * square
            + (-l0 + 3 * l1 - 3 * l2 + left) * cube)
          local right_between = 0.5 * (2 * r1 + (-r0 + r2) * fraction
            + (2 * r0 - 5 * r1 + 4 * r2 - right) * square
            + (-r0 + 3 * r1 - 3 * r2 + right) * cube)
          true_left = math.max(true_left, math.abs(left_between))
          true_right = math.max(true_right, math.abs(right_between))
        end
      end
      l0, l1, l2 = l1, l2, left
      r0, r1, r2 = r1, r2, right
    end
    remaining = remaining - count
  end
  input:close()
  return {sample_peak_left_db = amp_to_db(sample_left), sample_peak_right_db = amp_to_db(sample_right),
    true_peak_left_db = amp_to_db(true_left), true_peak_right_db = amp_to_db(true_right),
    sample_rate = layout.sample_rate, frames = frames}
end

local function copy_file_bytes(input, output, source_offset, byte_count)
  input:seek("set", source_offset)
  local remaining = byte_count
  while remaining > 0 do
    local block = input:read(math.min(1024 * 1024, remaining))
    if not block or #block == 0 then error("Unexpected end of WAV while applying silence padding.") end
    local ok, write_error = output:write(block)
    if not ok then error("Could not write padded WAV: " .. tostring(write_error)) end
    remaining = remaining - #block
  end
end

-- A single fixed gain per physical breakout channel cannot pump. Write to a
-- separate candidate, preserving the source WAV and every non-audio chunk.
-- No existing file is overwritten, and unchanged channel samples stay exact.
function scale_wav_channels(input_path, output_path, left_db, right_db)
  if input_path == output_path or file_exists(output_path) then
    return nil, "The constant-gain candidate path is not safely available."
  end
  if not finite(left_db) or not finite(right_db) or left_db > 0 or right_db > 0 then
    return nil, "WAV safety correction only permits finite channel attenuation."
  end
  local layout, problem = wav_layout(input_path)
  if not layout then return nil, problem end
  local input, open_error = io.open(input_path, "rb")
  if not input then return nil, open_error end
  local output, write_error = io.open(output_path, "wb")
  if not output then input:close(); return nil, write_error end
  local left_gain, right_gain = db_to_amp(left_db), db_to_amp(right_db)
  local function scale_sample(value, gain)
    if gain == 1 then return value end
    local scaled = value * gain
    if scaled >= 0 then scaled = math.floor(scaled + 0.5)
    else scaled = math.ceil(scaled - 0.5) end
    return clamp(scaled, -8388608, 8388607)
  end
  local ok, result = xpcall(function()
    copy_file_bytes(input, output, 0, layout.data_offset)
    input:seek("set", layout.data_offset)
    local remaining = layout.data_size
    while remaining > 0 do
      local size = math.min(4096 * 6, remaining)
      local bytes = input:read(size)
      if not bytes or #bytes ~= size or size % 6 ~= 0 then error("Incomplete 24-bit PCM frame during static safety correction.") end
      local block, position = {}, 1
      for _ = 1, size / 6 do
        local left, right
        left, right, position = string.unpack("<i3i3", bytes, position)
        block[#block + 1] = string.pack("<i3i3", scale_sample(left, left_gain), scale_sample(right, right_gain))
      end
      local written, problem = output:write(table.concat(block))
      if not written then error("Could not write constant-gain WAV: " .. tostring(problem)) end
      remaining = remaining - size
    end
    local after_audio = layout.data_offset + layout.data_size
    copy_file_bytes(input, output, after_audio, layout.file_size - after_audio)
    return true
  end, debug.traceback)
  input:close()
  output:close()
  if not ok then os.remove(output_path); return nil, result end
  if source_file_size(output_path) ~= layout.file_size then
    os.remove(output_path)
    return nil, "The constant-gain WAV size changed unexpectedly."
  end
  return {path = output_path, left_db = left_db, right_db = right_db}
end

local function write_zero_bytes(handle, byte_count)
  local zero_block = string.rep("\0", 65536)
  local remaining = byte_count
  while remaining > 0 do
    local bytes = math.min(#zero_block, remaining)
    local ok, write_error = handle:write(bytes == #zero_block and zero_block or zero_block:sub(1, bytes))
    if not ok then error("Could not write digital silence: " .. tostring(write_error)) end
    remaining = remaining - bytes
  end
end

local function wav_region_is_zero(path, offset, byte_count)
  local handle, open_error = io.open(path, "rb")
  if not handle then return false, open_error end
  handle:seek("set", offset)
  local remaining = byte_count
  while remaining > 0 do
    local block = handle:read(math.min(65536, remaining))
    if not block or #block == 0 then handle:close(); return false, "Unexpected end of padded WAV." end
    if block ~= string.rep("\0", #block) then handle:close(); return false, "A padding region contains non-zero audio bytes." end
    remaining = remaining - #block
  end
  handle:close()
  return true
end

local function pad_rendered_wav(path, leading_seconds, trailing_seconds)
  local layout, layout_error = wav_layout(path)
  if not layout then return nil, layout_error end
  local leading_frames = math.floor(leading_seconds * layout.sample_rate + 0.5)
  local trailing_frames = math.floor(trailing_seconds * layout.sample_rate + 0.5)
  local leading_bytes = leading_frames * layout.block_align
  local trailing_bytes = trailing_frames * layout.block_align
  local added_bytes = leading_bytes + trailing_bytes
  local new_data_size = layout.data_size + added_bytes
  local new_file_size = layout.file_size + added_bytes
  if new_data_size >= 0xFFFFFFFF or new_file_size - 8 >= 0xFFFFFFFF then
    return nil, "The padded WAV would exceed the standard RIFF 4 GB size limit."
  end

  local temp_path = path .. ".bildi_padding_tmp"
  local backup_path = path .. ".bildi_unpadded_backup"
  os.remove(temp_path)
  os.remove(backup_path)
  local input, input_error = io.open(path, "rb")
  if not input then return nil, input_error end
  local output, output_error = io.open(temp_path, "w+b")
  if not output then input:close(); return nil, output_error end
  local ok, result = xpcall(function()
    copy_file_bytes(input, output, 0, layout.data_offset)
    output:seek("set", 4)
    output:write(string.pack("<I4", new_file_size - 8))
    output:seek("set", layout.data_header_offset + 4)
    output:write(string.pack("<I4", new_data_size))
    output:seek("set", layout.data_offset)
    write_zero_bytes(output, leading_bytes)
    copy_file_bytes(input, output, layout.data_offset, layout.data_size)
    write_zero_bytes(output, trailing_bytes)
    if new_data_size % 2 == 1 then output:write("\0") end
    local after_original_data = layout.data_offset + layout.data_size + (layout.data_size % 2)
    copy_file_bytes(input, output, after_original_data, layout.file_size - after_original_data)
    return true
  end, debug.traceback)
  input:close()
  output:close()
  if not ok then os.remove(temp_path); return nil, result end

  local moved, move_error = os.rename(path, backup_path)
  if not moved then os.remove(temp_path); return nil, "Could not preserve the unpadded render: " .. tostring(move_error) end
  local replaced, replace_error = os.rename(temp_path, path)
  if not replaced then
    os.rename(backup_path, path)
    os.remove(temp_path)
    return nil, "Could not install the padded render: " .. tostring(replace_error)
  end
  os.remove(backup_path)

  local final_layout, final_error = wav_layout(path)
  if not final_layout then return nil, final_error end
  local leading_ok, leading_error = wav_region_is_zero(path, final_layout.data_offset, leading_bytes)
  if not leading_ok then return nil, "Leading-silence verification failed: " .. tostring(leading_error) end
  local trailing_offset = final_layout.data_offset + leading_bytes + layout.data_size
  local trailing_ok, trailing_error = wav_region_is_zero(path, trailing_offset, trailing_bytes)
  if not trailing_ok then return nil, "Trailing-silence verification failed: " .. tostring(trailing_error) end
  return {
    leading_seconds = leading_frames / layout.sample_rate,
    trailing_seconds = trailing_frames / layout.sample_rate,
    leading_frames = leading_frames,
    trailing_frames = trailing_frames,
    content_frames = layout.data_size / layout.block_align,
    content_seconds = layout.data_size / layout.block_align / layout.sample_rate,
    total_seconds = new_data_size / layout.block_align / layout.sample_rate,
    sample_rate = layout.sample_rate,
    verified = true,
  }
end

function verify_existing_padding(path, expected_content_seconds)
  local layout, problem = wav_layout(path)
  if not layout then return nil, problem end
  local leading_frames = math.floor(LEADING_SILENCE_SECONDS * layout.sample_rate + 0.5)
  local trailing_frames = math.floor(TRAILING_SILENCE_SECONDS * layout.sample_rate + 0.5)
  local total_frames = math.floor(layout.data_size / layout.block_align)
  local content_frames = total_frames - leading_frames - trailing_frames
  if content_frames <= 0 then return nil, "The WAV is too short for the required 2.5/30-second padding." end
  local content_seconds = content_frames / layout.sample_rate
  if expected_content_seconds and math.abs(content_seconds - expected_content_seconds) > 0.001 then
    return nil, "The WAV content duration differs from its prior audit."
  end
  local leading_ok, leading_error = wav_region_is_zero(path, layout.data_offset, leading_frames * layout.block_align)
  if not leading_ok then return nil, "Leading padding is not digital silence: " .. tostring(leading_error) end
  local trailing_offset = layout.data_offset + (leading_frames + content_frames) * layout.block_align
  local trailing_ok, trailing_error = wav_region_is_zero(path, trailing_offset, trailing_frames * layout.block_align)
  if not trailing_ok then return nil, "Trailing padding is not digital silence: " .. tostring(trailing_error) end
  return {leading_seconds = leading_frames / layout.sample_rate,
    trailing_seconds = trailing_frames / layout.sample_rate,
    leading_frames = leading_frames, trailing_frames = trailing_frames,
    content_frames = content_frames, content_seconds = content_seconds,
    total_seconds = total_frames / layout.sample_rate,
    sample_rate = layout.sample_rate, verified = true}
end

-- LUFS analyzers are not allowed to decide whether a WAV physically contains
-- audio. Inspect the 24-bit PCM words themselves so an analyzer error can never
-- be mistaken for an extremely quiet signal and sent into a gain-repair loop.
function wav_content_activity(path, content_start, content_duration)
  local layout, layout_error = wav_layout(path)
  if not layout then return nil, layout_error end
  if layout.channels ~= 2 or layout.bits_per_sample ~= 24 or layout.block_align ~= 6 then
    return nil, "PCM activity verification requires stereo 24-bit WAV audio."
  end
  local start_frame = math.max(0, math.floor((content_start or 0) * layout.sample_rate + 0.5))
  local requested_frames = math.max(0, math.floor((content_duration or 0) * layout.sample_rate + 0.5))
  local available_frames = math.floor(layout.data_size / layout.block_align)
  local frames = math.min(requested_frames, math.max(0, available_frames - start_frame))
  local handle, open_error = io.open(path, "rb")
  if not handle then return nil, open_error end
  handle:seek("set", layout.data_offset + start_frame * layout.block_align)
  local remaining = frames * layout.block_align
  local left_nonzero, right_nonzero = false, false
  while remaining > 0 and not (left_nonzero and right_nonzero) do
    local wanted = math.min(65532, remaining)
    wanted = wanted - (wanted % layout.block_align)
    local block = handle:read(wanted)
    if not block or #block == 0 then handle:close(); return nil, "Unexpected end of PCM data." end
    for offset = 1, #block - 5, 6 do
      if not left_nonzero and (block:byte(offset) ~= 0 or block:byte(offset + 1) ~= 0 or block:byte(offset + 2) ~= 0) then
        left_nonzero = true
      end
      if not right_nonzero and (block:byte(offset + 3) ~= 0 or block:byte(offset + 4) ~= 0 or block:byte(offset + 5) ~= 0) then
        right_nonzero = true
      end
      if left_nonzero and right_nonzero then break end
    end
    remaining = remaining - #block
  end
  handle:close()
  return {left_nonzero = left_nonzero, right_nonzero = right_nonzero, frames_checked = frames}
end

local function cubic_interpolate(p0, p1, p2, p3, fraction)
  local f2 = fraction * fraction
  local f3 = f2 * fraction
  return 0.5 * ((2 * p1) + (-p0 + p2) * fraction +
    (2 * p0 - 5 * p1 + 4 * p2 - p3) * f2 + (-p0 + 3 * p1 - 3 * p2 + p3) * f3)
end

local function analyze_stereo_statistics(track, start_time, end_time)
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then error("Could not create the post-render stereo analyzer.") end
  local buffer = reaper.new_array(ANALYSIS_BLOCK * 2)
  local position, count = start_time, 0
  local sum_left, sum_right, sum_left_sq, sum_right_sq, sum_cross, sum_mono_sq = 0, 0, 0, 0, 0, 0
  local sample_peak_left, sample_peak_right = 0, 0
  local true_peak_left, true_peak_right = 0, 0
  local l0, l1, l2, r0, r1, r2

  while position < end_time - 0.5 / ANALYSIS_RATE do
    local samples = math.min(ANALYSIS_BLOCK, math.ceil((end_time - position) * ANALYSIS_RATE))
    buffer.clear()
    local result = reaper.GetAudioAccessorSamples(accessor, ANALYSIS_RATE, 2, position, samples, buffer)
    if result < 0 then reaper.DestroyAudioAccessor(accessor); error("Post-render stereo analysis failed.") end
    local values = buffer.table(1, samples * 2)
    for sample = 1, samples do
      local left = values[(sample - 1) * 2 + 1] or 0
      local right = values[(sample - 1) * 2 + 2] or 0
      count = count + 1
      sum_left = sum_left + left
      sum_right = sum_right + right
      sum_left_sq = sum_left_sq + left * left
      sum_right_sq = sum_right_sq + right * right
      sum_cross = sum_cross + left * right
      local mono = (left + right) * 0.5
      sum_mono_sq = sum_mono_sq + mono * mono
      sample_peak_left = math.max(sample_peak_left, math.abs(left))
      sample_peak_right = math.max(sample_peak_right, math.abs(right))
      true_peak_left = math.max(true_peak_left, math.abs(left))
      true_peak_right = math.max(true_peak_right, math.abs(right))
      if l0 then
        for phase = 1, 3 do
          local fraction = phase * 0.25
          true_peak_left = math.max(true_peak_left, math.abs(cubic_interpolate(l0, l1, l2, left, fraction)))
          true_peak_right = math.max(true_peak_right, math.abs(cubic_interpolate(r0, r1, r2, right, fraction)))
        end
      end
      l0, l1, l2 = l1, l2, left
      r0, r1, r2 = r1, r2, right
    end
    position = position + samples / ANALYSIS_RATE
  end
  reaper.DestroyAudioAccessor(accessor)

  local mean_left = count > 0 and sum_left / count or 0
  local mean_right = count > 0 and sum_right / count or 0
  local variance_left = math.max(0, count > 0 and sum_left_sq / count - mean_left * mean_left or 0)
  local variance_right = math.max(0, count > 0 and sum_right_sq / count - mean_right * mean_right or 0)
  local covariance = count > 0 and sum_cross / count - mean_left * mean_right or 0
  local correlation = variance_left > EPS and variance_right > EPS and covariance / math.sqrt(variance_left * variance_right) or nil
  local rms_left = math.sqrt(count > 0 and sum_left_sq / count or 0)
  local rms_right = math.sqrt(count > 0 and sum_right_sq / count or 0)
  local mono_rms = math.sqrt(count > 0 and sum_mono_sq / count or 0)
  local fold_reference = math.max(rms_left, rms_right)
  return {
    sample_peak_left_db = amp_to_db(sample_peak_left),
    sample_peak_right_db = amp_to_db(sample_peak_right),
    true_peak_left_db = amp_to_db(true_peak_left),
    true_peak_right_db = amp_to_db(true_peak_right),
    correlation = correlation,
    mono_fold_loss_db = fold_reference > EPS and amp_to_db(mono_rms / fold_reference) or -math.huge,
  }
end

local function analyze_click_audibility(track, content_start, content_end, settings, retried_accessor)
  if not settings or not settings.click_hit_times or #settings.click_hit_times == 0 then return nil end
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then return nil end
  local windows = {}
  for _, project_hit in ipairs(settings.click_hit_times) do
    local hit_time = content_start + (project_hit - settings.selection_start)
    if hit_time >= content_start and hit_time < content_end then
      windows[#windows + 1] = {
        hit_time = hit_time,
        start_time = math.max(content_start, hit_time - 0.12),
        end_time = math.min(content_end, hit_time + 0.22),
        hit_sq = 0, hit_count = 0, hit_peak = 0, bed_sq = 0, bed_count = 0,
      }
    end
  end
  if #windows == 0 then reaper.DestroyAudioAccessor(accessor); return nil end

  -- Read the actual WAV once in chronological blocks. REAPER can return empty
  -- data for some small overlapping accessor requests; one sequential pass is
  -- faster and prevents those false "missing click" measurements.
  local buffer = reaper.new_array(ANALYSIS_BLOCK * 2)
  local position, first_window, read_failures = content_start, 1, 0
  while position < content_end - 0.5 / ANALYSIS_RATE do
    local samples = math.min(ANALYSIS_BLOCK, math.ceil((content_end - position) * ANALYSIS_RATE))
    buffer.clear()
    local result = reaper.GetAudioAccessorSamples(accessor, ANALYSIS_RATE, 2, position, samples, buffer)
    -- REAPER returns 0 for a legitimately silent block and -1 for an error.
    -- Song rests are not read failures; only a genuine accessor error retries.
    if result < 0 then
      read_failures = #windows
      break
    end
    local values = buffer.table(1, samples * 2)
    for sample = 1, samples do
      local time = position + (sample - 1) / ANALYSIS_RATE
      while first_window <= #windows and windows[first_window].end_time < time do
        first_window = first_window + 1
      end
      for index = first_window, #windows do
        local window = windows[index]
        if window.start_time > time then break end
        if time <= window.end_time then
          local relative = time - window.hit_time
          local value = values[(sample - 1) * 2 + 1] or 0
          if relative >= -0.012 and relative <= 0.070 then
            window.hit_sq = window.hit_sq + value * value
            window.hit_count = window.hit_count + 1
            window.hit_peak = math.max(window.hit_peak, math.abs(value))
          elseif (relative >= -0.12 and relative <= -0.030)
              or (relative >= 0.10 and relative <= 0.22) then
            window.bed_sq = window.bed_sq + value * value
            window.bed_count = window.bed_count + 1
          end
        end
      end
    end
    position = position + samples / ANALYSIS_RATE
  end
  reaper.DestroyAudioAccessor(accessor)
  if read_failures > 0 and not retried_accessor then
    return analyze_click_audibility(track, content_start, content_end, settings, true)
  end

  local prominences, peak_prominences, hit_details, missing_hits = {}, {}, {}, 0
  for _, window in ipairs(windows) do
    if window.hit_count > 0 and window.bed_count > 0 and window.hit_peak >= db_to_amp(-90) then
      local hit_rms_sq = window.hit_sq / window.hit_count
      local bed_rms = math.sqrt(window.bed_sq / window.bed_count)
      local estimated_click_rms = math.sqrt(math.max(EPS, hit_rms_sq - bed_rms * bed_rms))
      local energy_prominence = amp_to_db(estimated_click_rms / math.max(bed_rms, db_to_amp(-90)))
      local peak_prominence = amp_to_db(window.hit_peak / math.max(bed_rms, db_to_amp(-90)))
      if finite(energy_prominence) then prominences[#prominences + 1] = energy_prominence end
      if finite(peak_prominence) then
        peak_prominences[#peak_prominences + 1] = peak_prominence
        hit_details[#hit_details + 1] = {
          file_time = window.hit_time,
          project_time = settings.selection_start + window.hit_time - content_start,
          prominence_db = peak_prominence,
        }
      else
        missing_hits = missing_hits + 1
        hit_details[#hit_details + 1] = {file_time = window.hit_time,
          project_time = settings.selection_start + window.hit_time - content_start,
          prominence_db = -math.huge}
      end
    else
      missing_hits = missing_hits + 1
      hit_details[#hit_details + 1] = {file_time = window.hit_time,
        project_time = settings.selection_start + window.hit_time - content_start,
        prominence_db = -math.huge}
    end
  end
  table.sort(hit_details, function(left, right)
    if left.prominence_db ~= right.prominence_db then return left.prominence_db < right.prominence_db end
    return left.file_time < right.file_time
  end)
  return {
    hits_expected = #windows,
    hits_measured = #peak_prominences,
    coverage = #peak_prominences / #windows,
    missing_hits = missing_hits,
    read_failures = read_failures,
    -- Peak prominence is the dependable perceptual marker for a short click;
    -- subtracting bed energy from a compressed musical window is unstable.
    median_db = percentile(peak_prominences, 0.50),
    p10_db = percentile(peak_prominences, 0.10),
    minimum_db = percentile(peak_prominences, 0),
    weakest_hits = hit_details,
    median_energy_db = #prominences > 0 and percentile(prominences, 0.50) or nil,
    target_floor_db = settings.click_audibility_floor_db,
  }
end

local function analyze_stereo_output(project, path, content_start, content_duration, settings)
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then error("Could not open the rendered WAV for verification: " .. path) end
  local length = reaper.GetMediaSourceLength(source)
  content_start = content_start or 0
  content_duration = content_duration or length
  local content_end = math.min(length, content_start + content_duration)
  if content_end <= content_start then error("The rendered WAV has no measurable selected-content region.") end
  local pcm_activity, pcm_error = wav_content_activity(path, content_start, content_end - content_start)
  if not pcm_activity then error("Could not verify rendered PCM activity: " .. tostring(pcm_error)) end
  local native_peaks, native_error = wav_native_peaks(path, content_start, content_end - content_start)
  if not native_peaks then error("Could not scan the WAV's native-rate PCM peaks: " .. tostring(native_error)) end
  reaper.InsertTrackAtIndex(0, false)
  local track = reaper.GetTrack(project, 0)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "#SHOW POST-RENDER ANALYSIS (temporary)", true)
  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
  reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
  reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local ok, left, right, stereo, sws, click_audibility = xpcall(function()
    local embedded_left = analyze_track(track, content_start, content_end, "left")
    local embedded_right = analyze_track(track, content_start, content_end, "right")
    local statistics = analyze_stereo_statistics(track, content_start, content_end)
    local crosscheck
    if reaper.APIExists and reaper.APIExists("NF_AnalyzeTakeLoudness2") then
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", content_end - content_start)
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", content_start)
      crosscheck = {}
      -- REAPER take channel modes: 3 = mono left, 4 = mono right.
      for _, side in ipairs({{name = "left", mode = 3}, {name = "right", mode = 4}}) do
        reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", side.mode)
        local call_ok, analyzed, lufs, range_lu, true_peak =
          pcall(reaper.NF_AnalyzeTakeLoudness2, take, true)
        if call_ok and analyzed and finite(lufs) then
          -- Mono-left/right take modes feed the selected channel to both track
          -- channels. SWS correctly counts that dual-mono pair as +3.0103 LU;
          -- subtract it to obtain the loudness of the one physical breakout
          -- channel that will actually be heard.
          crosscheck[side.name] = {lufs = lufs - 10 * math.log(2, 10),
            range_lu = range_lu, true_peak_db = true_peak}
        end
      end
      reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", 0)
      -- The SWS side checks temporarily crop/offset this analysis item. Put
      -- the complete WAV back before checking CLICK positions; otherwise the
      -- final 2.5 seconds of musical content would be read beyond the cropped
      -- item and falsely reported as missing clicks.
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0)
    end
    local audibility = analyze_click_audibility(track, content_start, content_end, settings)
    return embedded_left, embedded_right, statistics, crosscheck, audibility
  end, debug.traceback)
  reaper.DeleteTrack(track)
  if not ok then error(left) end
  if sws then
    for _, entry in ipairs({{embedded = left, checked = sws.left, side = "left"},
        {embedded = right, checked = sws.right, side = "right"}}) do
      if entry.checked and finite(entry.checked.lufs) and finite(entry.embedded.lufs) then
        entry.embedded.embedded_lufs = entry.embedded.lufs
        entry.embedded.sws_lufs = entry.checked.lufs
        entry.embedded.sws_difference_lu = entry.checked.lufs - entry.embedded.lufs
        entry.embedded.lufs = entry.checked.lufs
        if finite(entry.checked.range_lu) then
          entry.embedded.embedded_range_lu = entry.embedded.range_lu
          entry.embedded.range_lu = math.max(entry.embedded.range_lu or 0, entry.checked.range_lu)
        end
        if finite(entry.checked.true_peak_db) then
          local key = entry.side == "left" and "true_peak_left_db" or "true_peak_right_db"
          stereo[key] = math.max(stereo[key], entry.checked.true_peak_db)
        end
      end
    end
  end
  for _, field in ipairs({"sample_peak_left_db", "sample_peak_right_db",
      "true_peak_left_db", "true_peak_right_db"}) do
    stereo[field] = math.max(stereo[field] or -math.huge, native_peaks[field])
  end
  return {left = left, right = right, stereo = stereo, sws = sws,
    pcm_activity = pcm_activity, native_peaks = native_peaks,
    click_audibility = click_audibility, length = length,
    content_start = content_start, content_end = content_end, content_duration = content_end - content_start}
end

local function post_render_validation(analysis, settings, has_foh, padding, validation_policy)
  validation_policy = validation_policy or "repair"
  local safety_only = validation_policy == "safety"
  local loudness_tolerance = validation_policy == "emergency" and LOUDNESS_EMERGENCY_TOLERANCE_LU
    or safety_only and LOUDNESS_EMERGENCY_TOLERANCE_LU
    or validation_policy == "normal" and LOUDNESS_NORMAL_TOLERANCE_LU
    or LOUDNESS_REPAIR_THRESHOLD_LU
  local range_limit = (validation_policy == "emergency" or safety_only) and SHOW_RANGE_EMERGENCY_LIMIT_LU
    or SHOW_RANGE_HARD_LIMIT_LU
  local errors, warnings = {}, {}
  local policy_info = {name = validation_policy, loudness_tolerance = loudness_tolerance,
    range_limit = range_limit, relaxed = false}
  local left, right, stereo = analysis.left, analysis.right, analysis.stereo
  if left.sws_difference_lu and math.abs(left.sws_difference_lu) > 0.50 then
    warnings[#warnings + 1] = string.format(
      "SWS and embedded left loudness differed by %.2f LU after dual-mono correction; the independent SWS result was used.", left.sws_difference_lu)
  end
  if has_foh and right.sws_difference_lu and math.abs(right.sws_difference_lu) > 0.50 then
    warnings[#warnings + 1] = string.format(
      "SWS and embedded right loudness differed by %.2f LU after dual-mono correction; the independent SWS result was used.", right.sws_difference_lu)
  end
  if not padding or not padding.verified then
    errors[#errors + 1] = "Digital-silence padding was not verified."
  else
    local sample_tolerance = 2 / math.max(padding.sample_rate or 1, 1)
    -- REAPER rounds custom render endpoints to its internal audio block/sample
    -- boundary. Up to 1 ms is harmless and still far tighter than an audible
    -- timing error; exact silence padding remains sample-verified separately.
    local content_tolerance = math.max(sample_tolerance, 0.001)
    if math.abs(padding.leading_seconds - LEADING_SILENCE_SECONDS) > sample_tolerance then
      errors[#errors + 1] = string.format("Leading silence is %.6f seconds instead of %.3f.", padding.leading_seconds, LEADING_SILENCE_SECONDS)
    end
    if math.abs(padding.trailing_seconds - TRAILING_SILENCE_SECONDS) > sample_tolerance then
      errors[#errors + 1] = string.format("Trailing silence is %.6f seconds instead of %.3f.", padding.trailing_seconds, TRAILING_SILENCE_SECONDS)
    end
    if math.abs(padding.content_seconds - settings.selection_duration) > content_tolerance then
      errors[#errors + 1] = string.format("Rendered content is %.6f seconds but the time selection is %.6f seconds.",
        padding.content_seconds, settings.selection_duration)
    end
    if math.abs(analysis.length - padding.total_seconds) > content_tolerance then
      errors[#errors + 1] = string.format("Padded WAV duration %.6f seconds does not match expected %.6f seconds.", analysis.length, padding.total_seconds)
    end
  end
  local pcm = analysis.pcm_activity
  local left_has_pcm = pcm and pcm.left_nonzero or (not left.silent and finite(left.peak) and left.peak >= 1e-7)
  local right_has_pcm = pcm and pcm.right_nonzero or (not right.silent and finite(right.peak) and right.peak >= 1e-7)
  if not left_has_pcm then
    errors[#errors + 1] = "Rendered left/IEM content is silent; a silent show file can never be published."
  elseif not finite(left.lufs) or not finite(left.peak) then
    errors[#errors + 1] = "Rendered left/IEM PCM contains audio, but its loudness measurement was invalid. No gain repair will be attempted from invalid data."
  else
    local left_delta = math.abs(left.lufs - settings.iem_target)
    if left_delta > loudness_tolerance then
      local message = string.format(
        "Rendered left loudness %.2f LUFS is %.2f LU from target (%.2f LU allowed by %s policy).",
        left.lufs, left_delta, loudness_tolerance, validation_policy)
      if safety_only then
        warnings[#warnings + 1] = message .. " The audible hardware-safe WAV was retained rather than withholding the song."
        policy_info.relaxed = true
      else
        errors[#errors + 1] = message
      end
    elseif left_delta > LOUDNESS_REPAIR_THRESHOLD_LU then
      policy_info.relaxed = true
      warnings[#warnings + 1] = string.format(
        "%s completion tolerance accepted left loudness %.2f LU from target after safe correction.",
        validation_policy == "emergency" and "Emergency" or "Normal", left_delta)
    end
  end
  if not finite(stereo.true_peak_left_db) then
    errors[#errors + 1] = "Rendered left true peak could not be measured."
  elseif stereo.true_peak_left_db > settings.iem_ceiling + TRUE_PEAK_GUARD_DB then
    errors[#errors + 1] = string.format("Rendered left estimated true peak %.2f dBTP exceeds ceiling %.2f dBFS.", stereo.true_peak_left_db, settings.iem_ceiling)
  end
  if not finite(left.range_lu) then
    warnings[#warnings + 1] = "Rendered left short-term range could not be measured; peak and integrated-loudness safety checks still passed."
  elseif (left.range_lu or 0) > SHOW_RANGE_TARGET_LU then
    warnings[#warnings + 1] = string.format(
      "Rendered left natural programme range is %.2f LU (%.2f LU preferred). It was not flattened because time-varying gain could pump.",
      left.range_lu, SHOW_RANGE_TARGET_LU)
  end
  if has_foh then
    if not right_has_pcm then
      errors[#errors + 1] = "FOH tracks were included but the rendered right/FOH content is silent."
    elseif not finite(right.lufs) or not finite(right.peak) then
      errors[#errors + 1] = "Rendered right/FOH PCM contains audio, but its loudness measurement was invalid. No gain repair will be attempted from invalid data."
    else
      local right_delta = math.abs(right.lufs - settings.foh_target)
      if right_delta > loudness_tolerance then
        local message = string.format(
          "Rendered right loudness %.2f LUFS is %.2f LU from target (%.2f LU allowed by %s policy).",
          right.lufs, right_delta, loudness_tolerance, validation_policy)
        if safety_only then
          warnings[#warnings + 1] = message .. " The audible hardware-safe WAV was retained rather than withholding the song."
          policy_info.relaxed = true
        else
          errors[#errors + 1] = message
        end
      elseif right_delta > LOUDNESS_REPAIR_THRESHOLD_LU then
        policy_info.relaxed = true
        warnings[#warnings + 1] = string.format(
          "%s completion tolerance accepted right loudness %.2f LU from target after safe correction.",
          validation_policy == "emergency" and "Emergency" or "Normal", right_delta)
      end
    end
    if not finite(stereo.true_peak_right_db) then
      errors[#errors + 1] = "Rendered right true peak could not be measured."
    elseif stereo.true_peak_right_db > settings.foh_ceiling + TRUE_PEAK_GUARD_DB then
      errors[#errors + 1] = string.format("Rendered right estimated true peak %.2f dBTP exceeds ceiling %.2f dBFS.", stereo.true_peak_right_db, settings.foh_ceiling)
    end
    if not finite(right.range_lu) then
      warnings[#warnings + 1] = "Rendered right short-term range could not be measured; peak and integrated-loudness safety checks still passed."
    elseif (right.range_lu or 0) > SHOW_RANGE_TARGET_LU then
      warnings[#warnings + 1] = string.format(
        "Rendered right natural programme range is %.2f LU (%.2f LU preferred). It was not flattened because time-varying gain could pump.",
        right.range_lu, SHOW_RANGE_TARGET_LU)
    end
  elseif right_has_pcm then
    errors[#errors + 1] = string.format("FOH is absent but rendered right is not digital silence (%.2f dBFS).", right.peak_db)
  end
  if stereo.correlation and stereo.correlation < -0.35 and stereo.mono_fold_loss_db < -9 then
    warnings[#warnings + 1] = string.format("Mono fold-down cancellation risk: correlation %.3f, fold-down %.2f dB relative to the louder channel.",
      stereo.correlation, stereo.mono_fold_loss_db)
  end
  if (settings.click_hit_times and #settings.click_hit_times > 0)
      or settings.inherited_click_audibility then
    local audibility = analysis.click_audibility
    local measured_floor = audibility and finite(audibility.p10_db) and audibility.p10_db
      or (audibility and audibility.median_db)
    local coverage = audibility and (audibility.coverage
      or ((audibility.hits_measured or 0) / math.max(1, audibility.hits_expected or audibility.hits_measured or 1))) or 0
    if not audibility or not finite(measured_floor) then
      errors[#errors + 1] = "Rendered CLICK audibility could not be measured at the detected beat positions."
    elseif coverage < 1 or (audibility.missing_hits or 0) > 0
        or (audibility.read_failures or 0) > 0 then
      local message = string.format(
        "Rendered CLICK verification measured %d of %d detected beat positions (%.0f%% coverage).",
        audibility.hits_measured or 0, audibility.hits_expected or 0, coverage * 100)
      errors[#errors + 1] = message ..
        " Every expected CLICK hit must be measurable; missing beats and accessor read failures are never a fallback pass."
    elseif measured_floor < (settings.click_audibility_floor_db or 5) then
      local message = string.format(
        "Rendered CLICK quiet-hit prominence %.2f dB is below the preferred %.2f dB floor (median %.2f dB).",
        measured_floor, settings.click_audibility_floor_db or 5, audibility.median_db)
      if safety_only and measured_floor >= 3 then
        warnings[#warnings + 1] = message .. " It remained measurably louder than the music and was retained after bounded correction."
      else
        errors[#errors + 1] = message
      end
    elseif audibility.minimum_db and audibility.minimum_db < (settings.click_audibility_floor_db or 5) - 2 then
      warnings[#warnings + 1] = string.format(
        "The single weakest rendered CLICK hit measured %.2f dB of prominence; the quiet-hit percentile passed at %.2f dB.",
        audibility.minimum_db, measured_floor)
    end
  end
  return errors, warnings
end

-- Repair a modest final peak miss directly in the finished WAV. This is a
-- uniform gain for an entire physical channel, never an envelope, duck, or
-- passage edit. A candidate is independently remeasured before publication.
function static_peak_gain_db(true_peak_db, ceiling_db)
  if not finite(true_peak_db) or not finite(ceiling_db) then return nil end
  if true_peak_db <= ceiling_db + TRUE_PEAK_GUARD_DB then return 0 end
  return math.min(0, ceiling_db - true_peak_db - 0.25)
end

function attempt_static_peak_repair(project, render_path, padding, analysis, settings, has_foh)
  local left_db = static_peak_gain_db(analysis.stereo.true_peak_left_db, settings.iem_ceiling)
  local right_db = has_foh and static_peak_gain_db(analysis.stereo.true_peak_right_db, settings.foh_ceiling) or 0
  if not left_db or not right_db then return nil, "A finite true-peak measurement is required." end
  if left_db == 0 and right_db == 0 then return nil, "No final-channel peak attenuation is needed." end
  if left_db < -3 or right_db < -3 then
    return nil, "The required constant attenuation exceeds the automatic 3 dB safety budget."
  end
  if finite(analysis.left.lufs) and math.abs(analysis.left.lufs + left_db - settings.iem_target) > LOUDNESS_NORMAL_TOLERANCE_LU then
    return nil, "Left peak attenuation would move the IEM more than 2 LU from its show target."
  end
  if has_foh and finite(analysis.right.lufs)
      and math.abs(analysis.right.lufs + right_db - settings.foh_target) > LOUDNESS_NORMAL_TOLERANCE_LU then
    return nil, "Right peak attenuation would move FOH more than 2 LU from its show target."
  end
  local candidate_path = unique_output_path(render_path:gsub("%.[Ww][Aa][Vv]$", "") .. ".bildibeat_static_peak.wav")
  if not candidate_path then return nil, "No free candidate WAV path is available." end
  local scaled, scale_error = scale_wav_channels(render_path, candidate_path, left_db, right_db)
  if not scaled then return nil, scale_error end
  local ok, verified_padding, verified_analysis = xpcall(function()
    local candidate_padding, padding_error = verify_existing_padding(candidate_path, padding.content_seconds)
    if not candidate_padding then error(padding_error) end
    local candidate_analysis = analyze_stereo_output(project, candidate_path,
      candidate_padding.leading_seconds, candidate_padding.content_seconds, settings)
    if settings.inherited_click_audibility then
      candidate_analysis.click_audibility = settings.inherited_click_audibility
    end
    return candidate_padding, candidate_analysis
  end, debug.traceback)
  if not ok then os.remove(candidate_path); return nil, tostring(verified_padding) end
  local normal_errors, normal_warnings = post_render_validation(
    verified_analysis, settings, has_foh, verified_padding, "normal")
  local policy = "NORMAL (+/-2.00 LU)"
  local errors, warnings = normal_errors, normal_warnings
  if #errors > 0 then
    errors, warnings = post_render_validation(
      verified_analysis, settings, has_foh, verified_padding, "safety")
    policy = "SAFE AUDIBLE FALLBACK (preferred CLICK target audited)"
  end
  if #errors > 0 then
    os.remove(candidate_path)
    return nil, "The separately verified constant-gain candidate still failed: " .. table.concat(errors, " | ")
  end
  return {path = candidate_path, padding = verified_padding, analysis = verified_analysis,
    warnings = warnings, policy = policy, left_db = left_db, right_db = right_db}
end

function repair_missing_click_items(analysis, settings, actions)
  local runtime = settings.runtime
  local record = runtime and runtime.sources and runtime.sources.CLICK and runtime.sources.CLICK[1]
  local audibility = analysis and analysis.click_audibility
  if not record or not record.track or not audibility then return false end
  local state = runtime.click_hit_repair or {attempts = 0, rollbacks = 0}
  runtime.click_hit_repair = state
  if state.pending then
    local improved = (audibility.missing_hits or 0) < state.pending.missing_before
      and (audibility.hits_measured or 0) > state.pending.measured_before
    if not improved then
      for _, entry in ipairs(state.pending.items) do
        if entry.created then
          reaper.DeleteTrackMediaItem(record.track, entry.item)
        else
          reaper.SetMediaItemInfo_Value(entry.item, "D_VOL", entry.volume)
          reaper.SetMediaItemInfo_Value(entry.item, "B_MUTE", entry.mute)
        end
      end
      state.rollbacks = state.rollbacks + 1
      state.disabled = true
      actions[#actions + 1] = "Expected-hit CLICK item repairs did not improve verified coverage; individual changes were rolled back."
      state.pending = nil
      return true
    end
    actions[#actions + 1] = string.format(
      "Expected-hit CLICK item repair improved coverage from %d to %d measured beats.",
      state.pending.measured_before, audibility.hits_measured or 0)
    state.pending = nil
  end
  local missing = audibility.missing_hits or 0
  if missing <= 0 or (audibility.read_failures or 0) > 0
      or state.attempts >= 2 or state.disabled then return false end
  local maximum_surgical = math.max(8, math.floor((audibility.hits_expected or 0) * 0.15))
  if missing > maximum_surgical then
    if (state.bulk_retries or 0) < 1 then
      state.bulk_retries = 1
      actions[#actions + 1] = string.format(
        "%d expected CLICK hits are missing; reasserted the complete render graph for one clean retry instead of changing hundreds of beats.", missing)
      return true
    end
    actions[#actions + 1] = string.format(
      "%d expected CLICK hits remain missing after a clean graph retry; the WAV cannot safely pass.", missing)
    return false
  end
  local edits = {}
  for _, hit in ipairs(audibility.weakest_hits or {}) do
    if not finite(hit.prominence_db) then
      local item
      for index = 0, reaper.CountTrackMediaItems(record.track) - 1 do
        local candidate = reaper.GetTrackMediaItem(record.track, index)
        if math.abs(reaper.GetMediaItemInfo_Value(candidate, "D_POSITION") - hit.project_time) <= 0.002 then
          item = candidate
          break
        end
      end
      if item then
        local original_volume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
        local original_mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
        edits[#edits + 1] = {item = item, volume = original_volume, mute = original_mute}
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
        reaper.SetMediaItemInfo_Value(item, "D_VOL", math.min(4, math.max(1, original_volume) * db_to_amp(6)))
      else
        local before_count = reaper.CountTrackMediaItems(record.track)
        local inserted, new_item = pcall(CLICK_MULTI.insert_hit_item,
          record.track, settings, hit.project_time, settings.selection_end)
        if inserted and new_item then
          edits[#edits + 1] = {item = new_item, created = true}
        else
          for index = reaper.CountTrackMediaItems(record.track) - 1, before_count, -1 do
            reaper.DeleteTrackMediaItem(record.track, reaper.GetTrackMediaItem(record.track, index))
          end
          for _, entry in ipairs(edits) do
            if entry.created then reaper.DeleteTrackMediaItem(record.track, entry.item)
            else
              reaper.SetMediaItemInfo_Value(entry.item, "D_VOL", entry.volume)
              reaper.SetMediaItemInfo_Value(entry.item, "B_MUTE", entry.mute)
            end
          end
          state.disabled = true
          actions[#actions + 1] = "A missing CLICK item could not be safely recreated: " .. tostring(new_item)
          return false
        end
      end
    end
  end
  if #edits == 0 then return false end
  state.pending = {items = edits, missing_before = missing,
    measured_before = audibility.hits_measured or 0}
  state.attempts = state.attempts + 1
  actions[#actions + 1] = string.format(
    "Repaired %d specific expected CLICK item(s) without changing continuous music gain; the next render must prove all beats audible.", #edits)
  return true
end

local function apply_post_render_repair(analysis, settings, has_foh, repair_number)
  local runtime = settings.runtime
  if not runtime or not runtime.iem then return false, {"Runtime bus controls are unavailable."} end
  local actions, changed = {}, false

  local function side_snapshot(side)
    return {trim = side.trim, limiter_ceiling = side.limiter_ceiling,
      compression_strength = side.compression_strength, makeup = side.makeup,
      dynamic_strength = side.dynamic_strength, passage_map = clone_passage_map(side.passage_map),
      passage_revision = side.passage_revision or 0, map_attempts = side.map_attempts or 0,
      surgical_failed = side.surgical_failed or false}
  end

  local function restore_side(side, snapshot, ceiling_db)
    side.trim = snapshot.trim
    side.limiter_ceiling = snapshot.limiter_ceiling
    side.compression_strength = snapshot.compression_strength
    side.makeup = snapshot.makeup
    side.dynamic_strength = snapshot.dynamic_strength
    side.passage_map = clone_passage_map(snapshot.passage_map)
    side.passage_revision = snapshot.passage_revision or 0
    side.map_attempts = snapshot.map_attempts or 0
    side.surgical_failed = snapshot.surgical_failed or false
    set_processor_input(side.track, side.fx, side.trim)
    set_processor_ceiling(side.track, side.fx, side.limiter_ceiling)
    set_processor_compression(side.track, side.fx, ceiling_db, side.compression_strength)
    set_processor_makeup(side.track, side.fx, side.makeup or 0)
    if side.level_track and side.level_fx then
      set_processor_leveler(side.level_track, side.level_fx,
        side.level_target_rms or -24, side.dynamic_strength or 0)
    end
    if side.passage_map and side.meter_slot and write_passage_map(side.passage_map, side.meter_slot) then
      reaper.TrackFX_SetParam(side.track, side.fx, 16, side.meter_slot)
    else
      reaper.TrackFX_SetParam(side.track, side.fx, 16, 0)
    end
  end

  local function repair_score(measured, true_peak_db, target_lufs, ceiling_db)
    if not measured or not finite(measured.lufs) or not finite(measured.range_lu)
        or not finite(true_peak_db) then return math.huge end
    return math.abs(target_lufs - measured.lufs) / LOUDNESS_REPAIR_THRESHOLD_LU
      + math.max(0, (measured.range_lu or 0) - SHOW_RANGE_TARGET_LU) / 1.5
      + math.max(0, true_peak_db - ceiling_db) * 2
  end

  local function measurement_usable(measured, true_peak_db, pcm_nonzero)
    local physical_audio = pcm_nonzero
    if physical_audio == nil then
      physical_audio = measured and not measured.silent and finite(measured.peak) and measured.peak >= 1e-7
    end
    return physical_audio and measured and finite(measured.peak) and finite(measured.lufs)
      and finite(measured.range_lu) and finite(true_peak_db)
  end

  local pcm = analysis.pcm_activity or {}
  local left_usable = measurement_usable(analysis.left, analysis.stereo.true_peak_left_db,
    analysis.pcm_activity and pcm.left_nonzero or nil)
  local right_usable = not has_foh or measurement_usable(analysis.right, analysis.stereo.true_peak_right_db,
    analysis.pcm_activity and pcm.right_nonzero or nil)
  if not left_usable or not right_usable then
    local invalid = {}
    if not left_usable then invalid[#invalid + 1] = "IEM/left" end
    if not right_usable then invalid[#invalid + 1] = "FOH/right" end

    local balance = runtime.click_balance
    if balance and balance.pending and runtime.click and runtime.backing then
      runtime.click.trim = balance.pending.click_trim
      runtime.backing.trim = balance.pending.backing_trim
      set_processor_input(runtime.click.track, runtime.click.fx, runtime.click.trim)
      set_processor_input(runtime.backing.track, runtime.backing.fx, runtime.backing.trim)
      balance.pending = nil
      balance.rollbacks = (balance.rollbacks or 0) + 1
      changed = true
      actions[#actions + 1] = "CLICK/BACKING controls were rolled back because the resulting WAV did not contain a valid measurable signal."
    end

    for _, entry in ipairs({{side = runtime.iem, ceiling = settings.iem_ceiling, label = "IEM/left"},
        {side = has_foh and runtime.foh or nil, ceiling = settings.foh_ceiling, label = "FOH/right"}}) do
      local side = entry.side
      if side and side.pending_snapshot then
        local changed_map = (side.passage_revision or 0) ~= (side.pending_snapshot.state.passage_revision or 0)
        restore_side(side, side.pending_snapshot.state, entry.ceiling)
        side.pending_snapshot = nil
        side.response = nil
        side.rollbacks = (side.rollbacks or 0) + 1
        if changed_map then
          side.surgical_failed = true
          side.map_attempts = math.max(side.map_attempts or 0, 2)
        end
        changed = true
        actions[#actions + 1] = entry.label .. " controls were restored to the last measurable state after a silent/invalid render."
      end
    end
    actions[#actions + 1] = table.concat(invalid, " and ") ..
      " returned silence or invalid measurements; loudness gain was explicitly refused."
    if changed then
      settings.post_render_repairs = repair_number
      for _, action in ipairs(actions) do
        append_repair(settings, string.format("Post-render recovery %d: %s", repair_number, action))
      end
    end
    return changed, actions
  end

  local function repair_click_balance()
    local audibility = analysis.click_audibility
    if not audibility or not runtime.click or not runtime.backing then return false end
    local measured_db = finite(audibility.p10_db) and audibility.p10_db or audibility.median_db
    if not finite(measured_db) then return false end
    settings.final_click_audibility_db = measured_db
    local target = settings.click_audibility_floor_db or 5
    local state = runtime.click_balance or {attempts = 0, rollbacks = 0}
    runtime.click_balance = state
    if state.pending then
      if measured_db < state.pending.before_db + 0.05 then
        runtime.click.trim, runtime.backing.trim = state.pending.click_trim, state.pending.backing_trim
        set_processor_input(runtime.click.track, runtime.click.fx, runtime.click.trim)
        set_processor_input(runtime.backing.track, runtime.backing.fx, runtime.backing.trim)
        state.rollbacks = state.rollbacks + 1
        state.disabled = true
        actions[#actions + 1] = string.format(
          "CLICK balance did not improve (%.2f to %.2f dB); component trims were rolled back and this ineffective strategy was retired.",
          state.pending.before_db, measured_db)
        state.pending = nil
        changed = true
        return true
      end
      state.pending = nil
    end
    if measured_db >= target or state.attempts >= 2 or state.disabled then return false end
    local error_db = target - measured_db
    local correction = clamp(error_db, 0.50, 3.00)
    state.pending = {before_db = measured_db,
      click_trim = runtime.click.trim, backing_trim = runtime.backing.trim}
    -- Split the correction across the two independently measured components.
    -- Lowering BACKING is dependable even when the click limiter is already
    -- catching peaks; a smaller CLICK lift preserves musical-bed loudness.
    local click_change = correction * 0.35
    local backing_change = -correction * 0.65
    runtime.click.trim = clamp(runtime.click.trim + click_change, -30, 36)
    runtime.backing.trim = clamp(runtime.backing.trim + backing_change, -30, 36)
    set_processor_input(runtime.click.track, runtime.click.fx, runtime.click.trim)
    set_processor_input(runtime.backing.track, runtime.backing.fx, runtime.backing.trim)
    state.attempts = state.attempts + 1
    actions[#actions + 1] = string.format(
      "CLICK prominence was %.2f dB; applied a surgical component rebalance (CLICK %+.2f dB, BACKING %+.2f dB) toward the %.2f dB floor.",
      measured_db, click_change, backing_change, target)
    changed = true
    return true
  end

  local function repair_side(label, measured, true_peak_db, target_lufs, ceiling_db, side)
    if not measurement_usable(measured, true_peak_db, nil) then
      actions[#actions + 1] = label .. " repair was skipped because its measurement was not finite and audible."
      return
    end
    side.attempts = side.attempts or 0
    side.rollbacks = side.rollbacks or 0
    local current_score = repair_score(measured, true_peak_db, target_lufs, ceiling_db)
    if side.pending_snapshot then
      if current_score > side.pending_snapshot.before_score + 0.20 then
        local surgical_worsened = (side.passage_revision or 0)
          ~= (side.pending_snapshot.state.passage_revision or 0)
        restore_side(side, side.pending_snapshot.state, ceiling_db)
        if surgical_worsened then
          -- Do not keep retrying a local map that made the verified WAV worse.
          -- Preserve the previous known-good map. Reactive gain riding is not
          -- an allowed fallback under the anti-pump policy.
          side.surgical_failed = true
          side.map_attempts = math.max(side.map_attempts or 0, 3)
        end
        side.rollbacks = side.rollbacks + 1
        actions[#actions + 1] = string.format(
          "%s repair response worsened its score (%.2f to %.2f); controls were rolled back before trying another strategy.",
          label, side.pending_snapshot.before_score, current_score)
        if surgical_worsened then
          actions[#actions + 1] = string.format(
            "%s surgical map was retired after the failed verification; no reactive leveling will replace it.", label)
        end
        side.pending_snapshot = nil
        changed = true
        return
      end
      side.pending_snapshot = nil
    end
    if side.attempts >= MAX_SIDE_REPAIR_ATTEMPTS then
      actions[#actions + 1] = string.format("%s exhausted its independent %d-attempt repair budget.",
        label, MAX_SIDE_REPAIR_ATTEMPTS)
      return
    end
    local before = side_snapshot(side)
    local measured_control = (side.compression_strength or 0) > EPS and (side.makeup or 0) or (side.trim or 0)
    local response_slope
    if side.response and math.abs(measured_control - side.response.control) >= 0.05 then
      local slope = (measured.lufs - side.response.lufs) / (measured_control - side.response.control)
      if slope >= 0.15 and slope <= 1.60 then response_slope = slope end
    end
    side.response = {control = measured_control, lufs = measured.lufs}
    local loudness_error = target_lufs - measured.lufs
    local peak_overshoot = true_peak_db - ceiling_db
    local structure_changed, compression_changed = false, false

    if side.attempts >= NORMAL_REPAIR_ATTEMPTS and not side.emergency_mode then
      side.emergency_mode = true
      settings.emergency_mode_used = true
      side.dynamic_strength = 0
      side.compression_strength = 0
      set_processor_compression(side.track, side.fx, ceiling_db, side.compression_strength)
      actions[#actions + 1] = string.format(
        "%s retained constant-gain fallback after %d verified attempts; no passage riding or compression was enabled.",
        label, side.attempts)
      changed, structure_changed = true, true
    end

    if peak_overshoot > TRUE_PEAK_GUARD_DB then
      -- The actual WAV's oversampled true peak is authoritative. Tighten the
      -- memoryless peak guard by the measured overshoot plus margin; lowering
      -- input trim can be ineffective while samples are already pinned to the
      -- old guard ceiling.
      local correction = peak_overshoot + 0.25
      local new_ceiling = clamp(side.limiter_ceiling - correction, -60, ceiling_db - 0.5)
      if new_ceiling < side.limiter_ceiling - 0.01 then
        side.limiter_ceiling = new_ceiling
        set_processor_ceiling(side.track, side.fx, side.limiter_ceiling)
        actions[#actions + 1] = string.format(
          "%s memoryless peak-guard ceiling lowered %.2f dB after the actual WAV measured %.2f dBTP; no recovery envelope was used.",
          label, correction, true_peak_db)
        changed, structure_changed = true, true
      end
    end

    if math.abs(loudness_error) > LOUDNESS_REPAIR_THRESHOLD_LU then
      local peak_headroom = ceiling_db - true_peak_db
      if not structure_changed then
        local response_factor = response_slope and (1 / response_slope) or 1
        local requested = clamp(loudness_error * response_factor, -12, 12)
        -- Loudness is corrected with one constant gain. Peaks that cross the
        -- ceiling are caught by the memoryless delayed-sample peak guard: no
        -- attack/release envelope exists, so this cannot create pumping.
        local correction = requested
        local new_trim = clamp(side.trim + correction, -30, 36)
        if math.abs(new_trim - side.trim) >= 0.01 then
          side.trim = new_trim
          set_processor_input(side.track, side.fx, side.trim)
          actions[#actions + 1] = string.format(
            "%s constant gain corrected by %+.2f dB from the actual WAV measurement%s.",
            label, correction, correction > peak_headroom - 0.50 and " (memoryless peak guard active)" or "")
          changed = true
        end
      end
    end
    local after = side_snapshot(side)
    local side_changed = math.abs((after.trim or 0) - (before.trim or 0)) > 0.001
      or math.abs((after.limiter_ceiling or 0) - (before.limiter_ceiling or 0)) > 0.001
      or math.abs((after.compression_strength or 0) - (before.compression_strength or 0)) > 0.001
      or math.abs((after.makeup or 0) - (before.makeup or 0)) > 0.001
      or math.abs((after.dynamic_strength or 0) - (before.dynamic_strength or 0)) > 0.001
      or (after.passage_revision or 0) ~= (before.passage_revision or 0)
    if side_changed then
      side.attempts = side.attempts + 1
      side.pending_snapshot = {state = before, before_score = current_score}
    end
  end

  local hit_repair_changed = repair_missing_click_items(analysis, settings, actions)
  if hit_repair_changed then changed = true end
  if not hit_repair_changed and not (analysis.click_audibility
      and (analysis.click_audibility.missing_hits or 0) > 0) then
    repair_click_balance()
  end
  -- A preferred CLICK correction must never postpone a hard IEM peak fix.
  -- These controls have independent budgets and may change in the same render.
  repair_side("IEM/left", analysis.left, analysis.stereo.true_peak_left_db,
    settings.iem_target, settings.iem_ceiling, runtime.iem)
  if has_foh and runtime.foh then
    repair_side("FOH/right", analysis.right, analysis.stereo.true_peak_right_db,
      settings.foh_target, settings.foh_ceiling, runtime.foh)
  end

  if changed then
    settings.adaptive_iem_limiter_ceiling = runtime.iem.limiter_ceiling
    settings.adaptive_foh_limiter_ceiling = runtime.foh and runtime.foh.limiter_ceiling or nil
    settings.post_render_repairs = repair_number
    for _, action in ipairs(actions) do
      append_repair(settings, string.format("Post-render repair %d: %s", repair_number, action))
    end
  end
  return changed, actions
end

local function pcm24(value)
  local scaled = math.floor(clamp(value, -1, 0.9999999) * 8388607 + (value >= 0 and 0.5 or -0.5))
  if scaled < 0 then scaled = scaled + 16777216 end
  return string.char(scaled % 256, math.floor(scaled / 256) % 256, math.floor(scaled / 65536) % 256)
end

local function create_calibration_wav(output_path, settings)
  local base = output_path:gsub("%.[Ww][Aa][Vv]$", "")
  local path = unique_output_path(base .. "_BREAKOUT_CAL.wav")
  if not path then error("Could not find an available calibration filename.") end
  local rate, duration = 48000, 9
  local total_samples = rate * duration
  local data_size = total_samples * 2 * 3
  local handle, message = io.open(path, "wb")
  if not handle then error("Could not create calibration WAV: " .. tostring(message)) end
  handle:write(string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", "RIFF", 36 + data_size, "WAVE", "fmt ", 16,
    1, 2, rate, rate * 6, 6, 24, "data", data_size))
  local left_level = db_to_amp(math.min(-30, settings.iem_ceiling - 6))
  local right_level = db_to_amp(math.min(-18, settings.foh_ceiling - 12))
  local block = {}
  for sample = 0, total_samples - 1 do
    local time = sample / rate
    local left, right = 0, 0
    local section_time
    if time >= 1 and time < 4 then
      section_time = time - 1
      left = math.sin(2 * math.pi * 1000 * section_time) * left_level
    elseif time >= 5 and time < 8 then
      section_time = time - 5
      right = math.sin(2 * math.pi * 1000 * section_time) * right_level
    end
    if section_time then
      local fade = math.min(1, section_time / 0.02, (3 - section_time) / 0.02)
      left, right = left * fade, right * fade
    end
    block[#block + 1] = pcm24(left) .. pcm24(right)
    if #block == 4096 then handle:write(table.concat(block)); block = {} end
  end
  if #block > 0 then handle:write(table.concat(block)) end
  handle:close()
  return path
end

local function build_audit(report, analysis, settings, errors, warnings, calibration_path, checksum, padding)
  local stereo = analysis.stereo
  local lines = {
    report,
    "",
    "POST-RENDER FILE VERIFICATION",
    "-----------------------------",
    "Status: " .. (#errors > 0 and "FAIL" or (#warnings > 0 and "PASS WITH WARNINGS" or "PASS")),
    "Verified: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "Profile ID: " .. tostring(settings.profile_id or "UNKNOWN"),
    "SHA-256: " .. tostring(checksum or "UNAVAILABLE"),
    padding and string.format("Content audio: starts at %.6f seconds | duration %.6f seconds", padding.leading_seconds, padding.content_seconds)
      or "Content audio: padding information unavailable",
    padding and string.format("Leading digital silence: %.6f seconds (%s)", padding.leading_seconds, padding.verified and "VERIFIED" or "NOT VERIFIED")
      or "Leading digital silence: NOT VERIFIED",
    padding and string.format("Trailing digital silence: %.6f seconds (%s)", padding.trailing_seconds, padding.verified and "VERIFIED" or "NOT VERIFIED")
      or "Trailing digital silence: NOT VERIFIED",
    padding and string.format("Total file duration: %.6f seconds", padding.total_seconds) or "Total file duration: unavailable",
    string.format("Actual left:  %.2f LUFS | %.2f dBFS sample peak | %.2f dBTP verified peak | %.2f LU range",
      analysis.left.lufs, stereo.sample_peak_left_db, stereo.true_peak_left_db, analysis.left.range_lu or 0),
    analysis.right.silent and "Actual right: digital silence" or string.format(
      "Actual right: %.2f LUFS | %.2f dBFS sample peak | %.2f dBTP verified peak | %.2f LU range",
      analysis.right.lufs, stereo.sample_peak_right_db, stereo.true_peak_right_db, analysis.right.range_lu or 0),
    string.format("Left spectral: low %.2f%% | mid %.2f%% | high %.2f%% | crest %.2f dB",
      analysis.left.low_pct or 0, analysis.left.mid_pct or 0, analysis.left.high_pct or 0, analysis.left.crest_db or 0),
    analysis.right.silent and "Right spectral: digital silence" or string.format(
      "Right spectral: low %.2f%% | mid %.2f%% | high %.2f%% | crest %.2f dB",
      analysis.right.low_pct or 0, analysis.right.mid_pct or 0, analysis.right.high_pct or 0, analysis.right.crest_db or 0),
    settings.reference and ("Reference ID: " .. tostring(settings.reference.reference_id or "UNKNOWN") .. " | " .. (settings.reference.compatible and "profile compatible" or "PROFILE MISMATCH"))
      or "Reference ID: not configured",
    stereo.correlation and string.format("L/R correlation: %.3f | mono fold-down: %.2f dB relative to louder channel",
      stereo.correlation, stereo.mono_fold_loss_db) or "L/R correlation: not applicable (one side is silent)",
    calibration_path and "Breakout calibration: " .. calibration_path or "Breakout calibration: not requested",
    string.format("Post-render automatic repairs: %d", settings.post_render_repairs or 0),
    "Completion policy: " .. tostring(settings.completion_policy or "NORMAL (+/-2.00 LU)"),
    settings.source_dynamics_applied
      and "Anti-pump safeguards: CONFIGURED | bounded memoryless CLICK/BACKING source compression | constant trim | bus compression OFF | passage maps OFF | reactive leveling OFF | dynamic ducking OFF | release envelopes OFF"
      or "Anti-pump safeguards: CONFIGURED | constant musical gain | passage maps OFF | reactive leveling OFF | compression 1:1 | dynamic ducking OFF | release envelopes OFF",
    "Emergency quality acceptance: " .. (settings.emergency_acceptance_used and "USED (hard safety checks still passed)" or "not needed"),
    analysis.click_audibility and string.format(
      "Final CLICK audibility: median %s dB prominence | quietest 10%% %s dB | %d/%d detected hit(s) measured | %d missing | floor %.2f dB",
      format_db(analysis.click_audibility.median_db),
      format_db(analysis.click_audibility.p10_db),
      analysis.click_audibility.hits_measured or 0,
      analysis.click_audibility.hits_expected or analysis.click_audibility.hits_measured or 0,
      analysis.click_audibility.missing_hits or 0,
      settings.click_audibility_floor_db or 5)
      or "Final CLICK audibility: not applicable (no CLICK track)",
    "Emergency stabilization: " .. (settings.emergency_mode_used and "USED" or "not needed"),
    string.format("Independent repair budgets: IEM %d/%d attempt(s), %d rollback(s) | FOH %s",
      settings.runtime and settings.runtime.iem and settings.runtime.iem.attempts or 0, MAX_SIDE_REPAIR_ATTEMPTS,
      settings.runtime and settings.runtime.iem and settings.runtime.iem.rollbacks or 0,
      settings.runtime and settings.runtime.foh and string.format("%d/%d attempt(s), %d rollback(s)",
        settings.runtime.foh.attempts or 0, MAX_SIDE_REPAIR_ATTEMPTS, settings.runtime.foh.rollbacks or 0) or "not applicable"),
    "Passage-dependent repair: DISABLED by hard anti-pump policy",
    settings.runtime and settings.runtime.click_balance and string.format(
      "Independent CLICK/BACKING repair: %d attempt(s), %d rollback(s)",
      settings.runtime.click_balance.attempts or 0, settings.runtime.click_balance.rollbacks or 0)
      or "Independent CLICK/BACKING repair: not needed",
    settings.hardware_safe_ceiling and string.format("Hardware-safe ceiling source: %.2f dBFS | %s",
      settings.hardware_safe_ceiling, settings.hardware_report_path ~= "" and settings.hardware_report_path or "report unavailable")
      or "Hardware-safe ceiling source: no stored loopback measurement",
    "Hardware note: analog crosstalk cannot be measured from the WAV; test the calibration file through the exact iPad, adapter, and breakout chain.",
  }
  if analysis.native_peaks then
    lines[#lines + 1] = string.format(
      "Native WAV PCM cross-check: %d Hz | left sample peak %s dBFS | right sample peak %s dBFS",
      analysis.native_peaks.sample_rate or 0,
      format_db(analysis.native_peaks.sample_peak_left_db),
      format_db(analysis.native_peaks.sample_peak_right_db))
  end
  if analysis.click_audibility and analysis.click_audibility.weakest_hits then
    local hits = analysis.click_audibility.weakest_hits
    local details = {string.format(
      "\nWEAKEST CLICK HITS (lowest %d of %d; file time includes 2.5-second lead-in)",
      math.min(10, #hits), #hits)}
    for index = 1, math.min(10, #hits) do
      local hit = hits[index]
      details[#details + 1] = string.format(
        "#%d project %.3f s | WAV %.3f s | prominence %s dB",
        index, hit.project_time or 0, hit.file_time or 0, format_db(hit.prominence_db))
    end
    lines[#lines + 1] = table.concat(details, "\n")
  end
  if settings.repair_log and #settings.repair_log > 0 then
    local post = {}
    for _, repair in ipairs(settings.repair_log) do
      if repair:find("Post-render repair", 1, true) or repair:find("Static WAV", 1, true) then
        post[#post + 1] = "- " .. repair
      end
    end
    if #post > 0 then lines[#lines + 1] = "\nPOST-RENDER AUTO-REPAIR\n" .. table.concat(post, "\n") end
  end
  if #errors > 0 then lines[#lines + 1] = "\nERRORS\n" .. table.concat(errors, "\n") end
  if #warnings > 0 then lines[#lines + 1] = "\nWARNINGS\n" .. table.concat(warnings, "\n") end
  return table.concat(lines, "\n")
end

function start_verified_render(project, render_path, settings, has_foh)
  local graph_ok, graph_error = ensure_final_render_graph(project, settings, has_foh)
  if not graph_ok then return false, graph_error end
  configure_render(project, render_path, settings.selection_start, settings.selection_end, settings)
  settings.render_ready_state = nil
  if reaper.SelectProjectInstance then reaper.SelectProjectInstance(project) end
  start_project_render(project)
  return true
end

function rendered_file_ready(settings, render_path, key)
  local size = source_file_size(render_path)
  if size <= 44 then return false, "WAV header/data is not complete" end
  local now = reaper.time_precise()
  local state = settings.render_ready_state
  if not state or state.path ~= render_path or state.key ~= key or state.size ~= size then
    settings.render_ready_state = {path = render_path, key = key, size = size, stable_since = now}
    return false, "waiting for file size to settle"
  end
  if now - state.stable_since < BILDI_RENDER_FILE_STABLE_SECONDS then
    return false, "waiting for external-drive write buffers"
  end
  local layout, layout_error = wav_layout(render_path)
  if not layout then return false, layout_error end
  if not layout.data_size or layout.data_size <= 0 then return false, "WAV contains no data frames" end
  return true
end

function required_output_is_measurable(analysis, has_foh)
  local pcm = analysis and analysis.pcm_activity
  local left = analysis and analysis.left
  local right = analysis and analysis.right
  local stereo = analysis and analysis.stereo
  local left_pcm = pcm and pcm.left_nonzero or (left and not left.silent and finite(left.peak) and left.peak >= 1e-7)
  local right_pcm = pcm and pcm.right_nonzero or (right and not right.silent and finite(right.peak) and right.peak >= 1e-7)
  local left_ok = left_pcm and left and finite(left.lufs) and finite(left.peak)
    and stereo and finite(stereo.true_peak_left_db)
  local right_ok = not has_foh or (right_pcm and right and finite(right.lufs) and finite(right.peak)
    and stereo and finite(stereo.true_peak_right_db))
  return left_ok and right_ok
end

function preserve_last_audible_render(render_path, analysis, padding, settings, has_foh)
  if not required_output_is_measurable(analysis, has_foh) then return false end
  local backup_path = render_path .. ".bildibeat_last_audible"
  os.remove(backup_path)
  local copied, copy_error = copy_file(render_path, backup_path)
  if not copied then
    append_repair(settings, "Could not preserve the last audible render snapshot: " .. tostring(copy_error))
    return false
  end
  settings.last_audible_render = {path = backup_path, analysis = analysis, padding = padding}
  return true
end

function restore_last_audible_render(render_path, settings)
  local snapshot = settings.last_audible_render
  if not snapshot or not file_exists(snapshot.path) then return nil end
  os.remove(render_path)
  local moved, move_error = os.rename(snapshot.path, render_path)
  if not moved then
    local copied, copy_error = copy_file(snapshot.path, render_path)
    if not copied then return nil, tostring(move_error) .. " | " .. tostring(copy_error) end
    os.remove(snapshot.path)
  end
  settings.last_audible_render = nil
  return snapshot
end

function restore_when_renderer_stops(project, settings)
  if reaper.EnumProjects(0x40000000, "") then
    reaper.defer(function() restore_when_renderer_stops(project, settings) end)
    return
  end
  finish_project_transaction(project, settings)
end

-- Optional CLICK variants are separate safety-verified renders of the same
-- graph. The normal approved WAV is published first. Their post-FX, pre-IEM
-- sends change the relative CLICK/BACKING balance by exactly +/-3 dB without
-- rerunning source normalization, following a detector envelope, or altering FOH.
function bildi_render_click_variants(project, base_path, base_audit, base_audit_path,
    base_analysis, report, settings, has_foh)
  local runtime = settings.runtime or {}
  local click = runtime.click
  local iem = runtime.iem
  if not click or not iem then return false end
  local base_trim = click.trim or 0
  local base_ceiling = iem.limiter_ceiling
  local base_checkpoint = settings.checkpoint_path
  local base_assigned = settings.assigned_click_offset_db or 0
  local base_prominence = base_analysis and base_analysis.click_audibility
    and base_analysis.click_audibility.p10_db
  local results = {"Base: " .. base_path}
  local folder, base_filename = split_path(base_path)
  local display_results = {"Normal: " .. base_filename}
  local failures = {}
  local offsets = {3, -3}
  local function restore_base_controls()
    settings.variant_mix = nil
    click.trim = base_trim
    set_processor_input(click.track, click.fx, base_trim)
    iem.limiter_ceiling = base_ceiling
    set_processor_ceiling(iem.track, iem.fx, base_ceiling)
    settings.final_output_path = base_path
    settings.checkpoint_path = base_checkpoint
  end
  local function complete()
    restore_base_controls()
    if base_checkpoint and file_exists(base_checkpoint) then os.remove(base_checkpoint) end
    progress_close()
    local restored, restore_error = finish_project_transaction(project, settings)
    local detail = table.concat(results, "\n")
    if #failures > 0 then detail = detail .. "\n\nVariant problems:\n" .. table.concat(failures, "\n") end
    if TEST_MODE then
      store_test_result((#failures == 0 and "OK POST-RENDER\n" or "POST-RENDER VARIANT ERROR\n") ..
        base_audit .. "\n\nVARIANT RESULTS\n" .. detail ..
        (restored and "\nPROJECT RESTORE: PASS" or ("\nPROJECT RESTORE: FAIL " .. tostring(restore_error))))
      return
    end
    local folder_display = #folder > 95 and ("..." .. folder:sub(-92)) or folder
    local message = (#failures == 0 and "All three show tracks rendered and verified:\n\n"
      or "The normal show track was verified; one or more optional CLICK variants did not pass:\n\n") ..
      "Folder: " .. folder_display .. "\n" .. table.concat(display_results, "\n")
    if #failures > 0 then message = message .. "\n\nVariant problems: " .. compact_list(failures, 2) end
    message = message .. (restored and "\n\nThe original project routing was restored."
      or ("\n\nRestore warning: " .. tostring(restore_error)))
    message = message .. "\n\nEach WAV has an audit in the same folder."
    reaper.ShowMessageBox(message, SCRIPT_NAME, 0)
  end
  local function variant_report(path, change_db)
    local marker = "Output: " .. base_path
    local pos = report:find(marker, 1, true)
    local revised = pos and (report:sub(1, pos - 1) .. "Output: " .. path ..
      report:sub(pos + #marker)) or report
    return revised .. string.format(
      "\nCLICK VARIANT: assigned offset %s dB | requested change %s dB | resulting offset %s dB. " ..
      "The relative CLICK/BACKING balance changes by fixed post-FX gain before the unchanged IEM peak guard; actual quiet-hit prominence is independently measured.",
      bildi_signed_offset_label(base_assigned), bildi_signed_offset_label(change_db),
      bildi_signed_offset_label(base_assigned + change_db))
  end
  local next_variant
  next_variant = function(index)
    if index > #offsets or progress_cancel_pending() then
      if progress_cancel_pending() then failures[#failures + 1] = "Remaining optional variants were cancelled; the verified base file remains available." end
      complete()
      return
    end
    local change_db = offsets[index]
    local label = string.format("CLICK %s dB (assigned offset %s dB)",
      bildi_signed_offset_label(change_db), bildi_signed_offset_label(base_assigned + change_db))
    local path = bildi_click_variant_output_path(base_path, base_assigned, change_db)
    if not path then
      failures[#failures + 1] = label .. ": no unused output filename is available."
      next_variant(index + 1)
      return
    end
    local preflight_errors = preflight_output(project, path, settings.selection_duration)
    if #preflight_errors > 0 then
      failures[#failures + 1] = label .. ": " .. table.concat(preflight_errors, " | ")
      next_variant(index + 1)
      return
    end
    local path_ok, temp_path = pcall(temporary_render_path, path)
    if not path_ok then
      failures[#failures + 1] = label .. ": " .. tostring(temp_path)
      next_variant(index + 1)
      return
    end
    click.trim = base_trim
    set_processor_input(click.track, click.fx, base_trim)
    settings.variant_mix = change_db > 0
      and {click_db = 0, backing_db = -change_db}
      or {click_db = change_db, backing_db = 0}
    iem.limiter_ceiling = base_ceiling
    set_processor_ceiling(iem.track, iem.fx, base_ceiling)
    settings.final_output_path = path
    settings.render_output_path = temp_path
    settings.checkpoint_path = checkpoint_path_for_output(path)
    settings.completion_policy = "CLICK VARIANT (hard safety; loudness differences audited)"
    settings.post_render_repairs = 0
    local item_report = variant_report(path, change_db)
    local attempts, peak_retries, balance_retries = 0, 0, 0
    local function fail(message, retained)
      local diagnostic = retained and failed_inspection_path(path) or nil
      if diagnostic then
        local moved = os.rename(temp_path, diagnostic)
        if moved then temp_path = diagnostic end
      end
      failures[#failures + 1] = label .. ": " .. tostring(message) ..
        (diagnostic and file_exists(diagnostic) and (" [inspect " .. diagnostic .. "]") or "")
      write_checkpoint(settings, "VARIANT_FAILED", tostring(message))
      next_variant(index + 1)
    end
    local poll
    local function launch()
      attempts = attempts + 1
      local started, problem = start_verified_render(project, temp_path, settings, has_foh)
      if not started then fail("E_RENDER_GRAPH: " .. tostring(problem), false); return end
      write_checkpoint(settings, "RENDERING_CLICK_VARIANT", label .. " attempt " .. attempts)
      progress_update("Rendering " .. label, "No user input is needed; this extra file will be checked before publication.", 0.93, false)
      local started_at = reaper.time_precise()
      reaper.defer(function() poll(started_at) end)
    end
    poll = function(started_at)
      local rendering = reaper.EnumProjects(0x40000000, "")
      local elapsed = reaper.time_precise() - started_at
      if rendering then
        if elapsed >= RENDER_TIMEOUT_SECONDS then
          progress_update("Waiting for REAPER", "The variant render exceeded its timeout; no overlapping render will start.", 0.93, true)
        end
        reaper.defer(function() poll(started_at) end)
        return
      end
      if not file_exists(temp_path) then
        if elapsed < RENDER_FILE_GRACE_SECONDS then
          reaper.defer(function() poll(started_at) end)
        elseif attempts <= MAX_RENDER_RETRIES then
          append_repair(settings, label .. ": REAPER produced no file; automatic retry " .. attempts .. ".")
          launch()
        else fail("REAPER did not create the temporary variant WAV.", false) end
        return
      end
      local ready = rendered_file_ready(settings, temp_path, "variant:" .. index .. ":" .. attempts)
      if not ready and elapsed < RENDER_TIMEOUT_SECONDS then
        reaper.defer(function() poll(started_at) end)
        return
      end
      local inspect_ok, padding, analysis = xpcall(function()
        local padded, problem = pad_rendered_wav(temp_path, LEADING_SILENCE_SECONDS, TRAILING_SILENCE_SECONDS)
        if not padded then error("Could not pad the CLICK variant: " .. tostring(problem)) end
        return padded, analyze_stereo_output(project, temp_path, padded.leading_seconds, padded.content_seconds, settings)
      end, debug.traceback)
      if not inspect_ok then fail("WAV inspection failed: " .. tostring(padding), true); return end
      local errors, warnings = post_render_validation(analysis, settings, has_foh, padding, "safety")
      local peak = analysis.stereo and analysis.stereo.true_peak_left_db
      if finite(peak) and peak > settings.iem_ceiling + TRUE_PEAK_GUARD_DB and peak_retries < 2 then
        peak_retries = peak_retries + 1
        local correction = peak - settings.iem_ceiling + 0.25
        iem.limiter_ceiling = clamp(iem.limiter_ceiling - correction, -60, settings.iem_ceiling - 0.5)
        set_processor_ceiling(iem.track, iem.fx, iem.limiter_ceiling)
        append_repair(settings, string.format(
          "%s: lowered the memoryless IEM peak guard %.2f dB after independent WAV measurement; rerendering to verify.",
          label, correction))
        os.remove(temp_path)
        launch()
        return
      end
      local measured_prominence = analysis.click_audibility and analysis.click_audibility.p10_db
      if #errors == 0 and finite(base_prominence) and finite(measured_prominence) then
        local discrepancy = base_prominence + change_db - measured_prominence
        if math.abs(discrepancy) > 0.75 and balance_retries < 2 then
          local current = change_db > 0 and settings.variant_mix.backing_db
            or settings.variant_mix.click_db
          local corrected = change_db > 0 and clamp(current - discrepancy, -9, 0)
            or clamp(current + discrepancy, -12, 0)
          if math.abs(corrected - current) >= 0.25 then
            balance_retries = balance_retries + 1
            if change_db > 0 then settings.variant_mix.backing_db = corrected
            else settings.variant_mix.click_db = corrected end
            append_repair(settings, string.format(
              "%s: measured quiet-hit prominence changed %+.2f dB versus requested %+.2f dB; refined one fixed post-FX send to %+.2f dB and will reverify the entire WAV.",
              label, measured_prominence - base_prominence, change_db, corrected))
            os.remove(temp_path)
            launch()
            return
          end
        end
        local actual_change = measured_prominence - base_prominence
        if math.abs(actual_change - change_db) > 1.0 then
          warnings[#warnings + 1] = string.format(
            "Requested quiet-hit CLICK/BACKING change was %+.2f dB; the independently measured change was %+.2f dB after bounded constant-gain calibration and peak safety. The actual result is reported rather than hidden.",
            change_db, actual_change)
        end
        item_report = item_report .. string.format(
          "\nVerified quiet-hit prominence: base %.2f dB | variant %.2f dB | actual change %+.2f dB. " ..
          "Fixed send controls: CLICK %+.2f dB | BACKING %+.2f dB.",
          base_prominence, measured_prominence, actual_change,
          settings.variant_mix.click_db, settings.variant_mix.backing_db)
      end
      local checksum, hash_error = common.sha256_file(temp_path)
      if not checksum then errors[#errors + 1] = "E_CHECKSUM: " .. tostring(hash_error) end
      local audit = build_audit(item_report, analysis, settings, errors, warnings, nil, checksum, padding)
      if #errors > 0 then
        local diagnostic = failed_inspection_path(path)
        if diagnostic and os.rename(temp_path, diagnostic) then
          local failed_audit = diagnostic:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
          write_text(failed_audit, audit)
          temp_path = diagnostic
        end
        fail(table.concat(errors, " | "), false)
        return
      end
      local published, audit_path = publish_verified_pair(temp_path, path, audit, checksum)
      if not published then fail("Verified WAV could not be published: " .. tostring(audit_path), true); return end
      if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
      results[#results + 1] = label .. ": " .. path .. " | audit: " .. tostring(audit_path)
      local _, filename = split_path(path)
      display_results[#display_results + 1] = label .. ": " .. filename
      next_variant(index + 1)
    end
    launch()
  end
  next_variant(1)
  return true
end

local function wait_for_render(project, render_path, output_path, started_at, report, settings, has_foh, build_warnings, repair_attempt, render_retry)
  repair_attempt = repair_attempt or 0
  render_retry = render_retry or 0
  local rendering_project = reaper.EnumProjects(0x40000000, "")
  local elapsed = reaper.time_precise() - started_at
  progress_update(rendering_project and "Rendering show track" or "Render stage complete",
    rendering_project and string.format("REAPER is rendering attempt %d. A requested cancel will take effect when this render finishes safely.", render_retry + 1)
      or "The current render engine operation has finished.",
    rendering_project and 0.93 or 0.95, not rendering_project)
  if progress_cancel_pending() and not rendering_project then
    if file_exists(render_path) then os.remove(render_path) end
    write_checkpoint(settings, "CANCELLED_AFTER_RENDER", "Temporary render removed before verification")
    if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
    progress_close()
    local restored, restore_error = finish_project_transaction(project, settings)
    if TEST_MODE then store_test_result("CANCELLED"); return end
    reaper.ShowMessageBox("Cancelled safely after the current render finished. No final WAV was published." ..
      (restored and "\n\nThe original project routing was restored."
        or ("\n\nRestore warning: " .. tostring(restore_error))), SCRIPT_NAME, 0)
    return
  end
  if rendering_project and elapsed < RENDER_TIMEOUT_SECONDS then
    reaper.defer(function()
      wait_for_render(project, render_path, output_path, started_at, report, settings, has_foh,
        build_warnings, repair_attempt, render_retry)
    end)
    return
  end
  if not rendering_project and not file_exists(render_path) and elapsed < RENDER_FILE_GRACE_SECONDS then
    reaper.defer(function()
      wait_for_render(project, render_path, output_path, started_at, report, settings, has_foh,
        build_warnings, repair_attempt, render_retry)
    end)
    return
  end
  if not rendering_project and file_exists(render_path) then
    local ready = rendered_file_ready(settings, render_path,
      tostring(repair_attempt) .. ":" .. tostring(render_retry))
    if not ready and elapsed < RENDER_TIMEOUT_SECONDS then
      progress_update("Finalizing rendered WAV",
        "Waiting for the WAV header and external-drive write buffers to become stable before analysis.", 0.95, true)
      reaper.defer(function()
        wait_for_render(project, render_path, output_path, started_at, report, settings, has_foh,
          build_warnings, repair_attempt, render_retry)
      end)
      return
    end
  end
  if rendering_project and elapsed >= RENDER_TIMEOUT_SECONDS then
    progress_close()
    write_checkpoint(settings, "RENDER_TIMEOUT", "REAPER still reports an active render")
    local diagnostic_path = write_diagnostic(settings, "E_RENDER_TIMEOUT", "REAPER still reports an active render")
    local message = string.format(
      "E_RENDER_TIMEOUT: REAPER still reports an active render after %d seconds. The app did not start a second overlapping render. Original routing will be restored automatically as soon as REAPER releases the renderer.\n\nCheckpoint:\n%s",
      RENDER_TIMEOUT_SECONDS, tostring(settings.checkpoint_path or "")) ..
      (diagnostic_path and ("\n\nDiagnostic:\n" .. diagnostic_path) or "")
    restore_when_renderer_stops(project, settings)
    if TEST_MODE then store_test_result("POST-RENDER ERROR\n" .. message); return end
    reaper.ShowMessageBox(message, SCRIPT_NAME, 0)
    return
  end
  if not file_exists(render_path) and render_retry < MAX_RENDER_RETRIES then
    render_retry = render_retry + 1
    append_repair(settings, string.format(
      "Render engine produced no file; automatic render retry %d of %d started.", render_retry, MAX_RENDER_RETRIES))
    write_checkpoint(settings, "RENDER_RETRY", "Retry " .. tostring(render_retry))
    progress_update("Retrying render", string.format("Automatic render retry %d of %d", render_retry, MAX_RENDER_RETRIES), 0.92, false)
    local retry_started = reaper.time_precise()
    local started, start_error = start_verified_render(project, render_path, settings, has_foh)
    if not started then
      progress_close()
      local message = "E_RENDER_GRAPH: " .. tostring(start_error)
      write_checkpoint(settings, "RENDER_GRAPH_FAILED", message)
      local restored, restore_error = finish_project_transaction(project, settings)
      if restored then message = message .. "\n\nOriginal project routing was restored."
      else message = message .. "\n\nRestore warning: " .. tostring(restore_error) end
      if TEST_MODE then store_test_result("POST-RENDER ERROR\n" .. message); return end
      reaper.ShowMessageBox(message, SCRIPT_NAME, 0)
      return
    end
    reaper.defer(function()
      wait_for_render(project, render_path, output_path, retry_started, report, settings, has_foh,
        build_warnings, repair_attempt, render_retry)
    end)
    return
  end
  if file_exists(render_path) then
    write_checkpoint(settings, "VERIFYING_WAV", "Repair attempt " .. tostring(repair_attempt))
    progress_update("Verifying rendered WAV", "Adding exact silence padding and measuring the actual stereo file.", 0.96, true)
    if progress_cancel_pending() then
      os.remove(render_path)
      if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
      progress_close()
      local restored, restore_error = finish_project_transaction(project, settings)
      if not TEST_MODE then reaper.ShowMessageBox("Verification cancelled safely. The temporary WAV was removed." ..
        (restored and "\n\nThe original project routing was restored."
          or ("\n\nRestore warning: " .. tostring(restore_error))), SCRIPT_NAME, 0) end
      return
    end
    reaper.PreventUIRefresh(1)
    local ok, padding, analysis = xpcall(function()
      local padded, padding_error = pad_rendered_wav(render_path, LEADING_SILENCE_SECONDS, TRAILING_SILENCE_SECONDS)
      if not padded then error("Could not add verified digital-silence padding: " .. tostring(padding_error)) end
      return padded, analyze_stereo_output(project, render_path, padded.leading_seconds, padded.content_seconds, settings)
    end, debug.traceback)
    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    if not ok then
      progress_close()
      local diagnostic_path = write_diagnostic(settings, "E_WAV_VERIFY", padding)
      local restored, restore_error = finish_project_transaction(project, settings)
      if TEST_MODE then store_test_result("POST-RENDER ERROR\n" .. tostring(padding)); return end
      reaper.ShowMessageBox("WAV verification failed. The temporary file was retained.\n\n" .. compact_detail(padding, 6, 650) ..
        "\n\nTemporary file retained for inspection:\n" .. render_path ..
        (restored and "\n\nThe original project routing was restored."
          or ("\n\nRestore warning: " .. tostring(restore_error))) ..
        (diagnostic_path and ("\n\nDiagnostic:\n" .. diagnostic_path) or ""), SCRIPT_NAME, 0)
      return
    end
    -- The actual rendered WAV is authoritative. A sub-2-LU difference is a
    -- normal, usable pass and does not trigger another expensive rerender.
    local errors, post_warnings =
      post_render_validation(analysis, settings, has_foh, padding, "normal")
    local operational_errors = {}
    settings.completion_policy = "NORMAL (+/-2.00 LU)"
    preserve_last_audible_render(render_path, analysis, padding, settings, has_foh)

    if #errors > 0 and finite(analysis.stereo.true_peak_left_db)
        and (analysis.stereo.true_peak_left_db > settings.iem_ceiling + TRUE_PEAK_GUARD_DB
          or (has_foh and finite(analysis.stereo.true_peak_right_db)
            and analysis.stereo.true_peak_right_db > settings.foh_ceiling + TRUE_PEAK_GUARD_DB)) then
      progress_update("Correcting finished WAV", "Applying fixed channel gain and independently checking the candidate; no full rerender or gain envelope.", 0.97, true)
      local repair_ok, candidate, reason = pcall(attempt_static_peak_repair,
        project, render_path, padding, analysis, settings, has_foh)
      if repair_ok and candidate then
        local original_render_path = render_path
        render_path, padding, analysis = candidate.path, candidate.padding, candidate.analysis
        settings.render_output_path = render_path
        write_checkpoint(settings, "STATIC_WAV_VERIFIED", "Completed candidate awaits pair publication")
        errors, post_warnings = {}, candidate.warnings
        settings.completion_policy = candidate.policy
        settings.static_wav_repairs = (settings.static_wav_repairs or 0) + 1
        if candidate.policy:find("FALLBACK", 1, true) then settings.safe_audible_fallback_used = true end
        append_repair(settings, string.format(
          "Static WAV safety correction: left %+.2f dB, right %+.2f dB; native PCM, true peak, loudness, padding, routing, and CLICK were rechecked without a full rerender.",
          candidate.left_db, candidate.right_db))
        os.remove(original_render_path)
      else
        append_repair(settings, "Static WAV safety correction was unavailable: " .. tostring(repair_ok and reason or candidate))
      end
    end

    if #errors > 0 and repair_attempt < MAX_POST_RENDER_REPAIRS then
      local repair_number = repair_attempt + 1
      reaper.Undo_BeginBlock2(project)
      local repaired, actions = apply_post_render_repair(analysis, settings, has_foh, repair_number)
      reaper.Undo_EndBlock2(project, SCRIPT_NAME .. string.format(" post-render repair %d", repair_number), -1)
      if repaired then
        local removed, remove_error = os.remove(render_path)
        if not removed and file_exists(render_path) then
          local message = "Could not remove the temporary failed attempt before rerendering: " .. tostring(remove_error)
          errors[#errors + 1] = message
          operational_errors[#operational_errors + 1] = message
        else
          append_repair(settings, string.format(
            "Post-render repair %d will be rendered and verified again before publication.", repair_number))
          local retry_started = reaper.time_precise()
          write_checkpoint(settings, "POST_RENDER_REPAIR", "Repair " .. tostring(repair_number))
          progress_update("Applying verified repair", string.format("Repair %d was applied; rerendering only to verify its measured response.", repair_number),
            0.96, false)
          local started, start_error = start_verified_render(project, render_path, settings, has_foh)
          if not started then
            errors[#errors + 1] = "E_RENDER_GRAPH: " .. tostring(start_error)
            operational_errors[#operational_errors + 1] = "E_RENDER_GRAPH: " .. tostring(start_error)
          else
          reaper.defer(function()
            wait_for_render(project, render_path, output_path, retry_started, report, settings,
              has_foh, build_warnings, repair_number, 0)
          end)
          return
          end
        end
      end
    end

    -- A first silent/invalid render with no pending control change can be a
    -- transient render graph or external-drive failure. Reassert the graph and
    -- retry once. Unlike the old behavior, no gain is ever added to silence.
    if #errors > 0 and not required_output_is_measurable(analysis, has_foh)
        and (settings.silent_render_retries or 0) < BILDI_MAX_SILENT_RENDER_RETRIES then
      settings.silent_render_retries = (settings.silent_render_retries or 0) + 1
      os.remove(render_path)
      append_repair(settings, string.format(
        "Silent/invalid render recovery %d of %d reasserted every source, send, bus, processor, and master route without changing gain.",
        settings.silent_render_retries, BILDI_MAX_SILENT_RENDER_RETRIES))
      local retry_started = reaper.time_precise()
      local started, start_error = start_verified_render(project, render_path, settings, has_foh)
      if started then
        reaper.defer(function()
          wait_for_render(project, render_path, output_path, retry_started, report, settings,
            has_foh, build_warnings, repair_attempt, 0)
        end)
        return
      end
      errors[#errors + 1] = "E_RENDER_GRAPH: " .. tostring(start_error)
      operational_errors[#operational_errors + 1] = "E_RENDER_GRAPH: " .. tostring(start_error)
    end

    -- Never allow a later failed repair to replace a previously measured,
    -- audible WAV with silence. Restore the last audible file and judge that
    -- known signal under the final safety-only completion policy.
    if #errors > 0 and not required_output_is_measurable(analysis, has_foh) then
      local snapshot, restore_error = restore_last_audible_render(render_path, settings)
      if snapshot then
        analysis, padding = snapshot.analysis, snapshot.padding
        errors, post_warnings = post_render_validation(analysis, settings, has_foh, padding, "emergency")
        append_repair(settings,
          "A silent/invalid repair result was discarded and the last independently measured audible WAV was restored.")
      elseif restore_error then
        errors[#errors + 1] = "E_AUDIBLE_ROLLBACK: " .. tostring(restore_error)
      end
    end

    -- Only quality tolerances relax here. The emergency validator repeats all
    -- hard peak, audible-content, channel-isolation, padding, duration, and
    -- CLICK-audibility checks unchanged. It can therefore never turn silence,
    -- clipping, bleed, missing click, or a malformed file into a pass.
    if #errors > 0 then
      local emergency_errors, emergency_warnings =
        post_render_validation(analysis, settings, has_foh, padding, "emergency")
      for _, message in ipairs(operational_errors) do emergency_errors[#emergency_errors + 1] = message end
      if #emergency_errors == 0 then
        errors, post_warnings = emergency_errors, emergency_warnings
        settings.completion_policy = "EMERGENCY (+/-2.00 LU; range <=7.00 LU)"
        settings.emergency_acceptance_used = true
        append_repair(settings,
          "Automatic repair exhausted its useful corrections; the safe WAV was published under the documented emergency quality tolerance. Hard safety and CLICK checks still passed.")
      else
        errors, post_warnings = emergency_errors, emergency_warnings
      end
    end

    -- Loudness and dynamic-range targets remain correction goals, but they no
    -- longer withhold an otherwise valid song forever. This final policy still
    -- repeats every hard PCM-audibility, peak, routing, padding, duration, and
    -- CLICK check. Only quality-distance errors become explicit audit warnings.
    if #errors > 0 then
      local safety_errors, safety_warnings =
        post_render_validation(analysis, settings, has_foh, padding, "safety")
      for _, message in ipairs(operational_errors) do safety_errors[#safety_errors + 1] = message end
      if #safety_errors == 0 then
        errors, post_warnings = safety_errors, safety_warnings
        settings.completion_policy = "SAFE AUDIBLE FALLBACK (quality exceptions audited)"
        settings.safe_audible_fallback_used = true
        append_repair(settings,
          "Bounded target correction ended with a hardware-safe audible WAV; remaining loudness/range differences were documented instead of failing the song.")
      end
    end

    local warnings = {}
    for _, warning in ipairs(build_warnings or {}) do warnings[#warnings + 1] = warning end
    for _, warning in ipairs(post_warnings) do warnings[#warnings + 1] = warning end
    for _, warning in ipairs(reference_match_warnings(analysis, settings)) do warnings[#warnings + 1] = warning end

    local verified_path, audit_path, audit_ok = render_path, nil, false
    local checksum, checksum_error = common.sha256_file(render_path)
    if not checksum then
      errors[#errors + 1] = "E_CHECKSUM: The inspected WAV could not be fully checksummed: " .. tostring(checksum_error)
    end
    local calibration_path
    if #errors == 0 and settings.create_calibration then
      local cal_ok, cal_result = pcall(create_calibration_wav, output_path, settings)
      if cal_ok then calibration_path = cal_result else warnings[#warnings + 1] = "Calibration WAV failed: " .. tostring(cal_result) end
    end
    local audit = build_audit(report, analysis, settings, errors, warnings, calibration_path, checksum, padding)
    if #errors == 0 then
      local published, result = publish_verified_pair(render_path, output_path, audit, checksum)
      if published then
        verified_path, audit_path, audit_ok = output_path, result, true
      else
        local publish_error = result
        if file_exists(output_path) then
          publish_error = tostring(publish_error) ..
            " | An unverified final WAV still occupies the destination; it must be inspected before any alternate is called successful."
        elseif not TEST_MODE then
          local choose, alternate = reaper.GetUserFileName(0,
            "Final publish failed - choose an alternate WAV destination", output_path, "WAV audio|*.wav")
          if choose then
            alternate = ensure_wav_extension(alternate)
            local alternate_report = report .. "\nFinal publication destination: " .. alternate
            local alternate_audit = build_audit(alternate_report, analysis, settings,
              errors, warnings, calibration_path, checksum, padding)
            local moved, alternate_result = publish_verified_pair(render_path, alternate,
              alternate_audit, checksum)
            if moved then
              verified_path, output_path, audit_path, audit, audit_ok = alternate,
                alternate, alternate_result, alternate_audit, true
              settings.final_output_path = alternate
              append_repair(settings, "Verified WAV and matching audit were published together to an alternate destination.")
            else
              publish_error = tostring(publish_error) .. " | Alternate destination: " .. tostring(alternate_result)
            end
          end
        end
        if not audit_ok then errors[#errors + 1] = "E_PUBLISH_PAIR: " .. tostring(publish_error) end
      end
    end
    if #errors > 0 then
      if verified_path == render_path then
        local failed_path = failed_inspection_path(output_path)
        if failed_path then
          local retained = os.rename(render_path, failed_path)
          if retained then verified_path = failed_path end
        end
      end
      if file_exists(verified_path) then
        reaper.SetExtState(EXTSTATE_SECTION, "last_failed_wav_v39", verified_path, true)
      end
      checksum, checksum_error = common.sha256_file(verified_path)
      if not checksum then warnings[#warnings + 1] = "SHA-256 calculation failed: " .. tostring(checksum_error) end
      audit = build_audit(report, analysis, settings, errors, warnings, calibration_path, checksum, padding)
      audit_path = verified_path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
      local audit_error
      audit_ok, audit_error = write_text(audit_path, audit)
      if not audit_ok then warnings[#warnings + 1] = "Could not write failed-inspection audit: " .. tostring(audit_error) end
    end
    console("\n" .. audit)
    -- The rollback copy is only an in-run safety net. Once the inspected WAV
    -- and its audit exist, retaining that private duplicate just accumulates
    -- stale files in REAPER's local render cache.
    if settings.last_audible_render and settings.last_audible_render.path then
      os.remove(settings.last_audible_render.path)
      settings.last_audible_render = nil
    end
    if #errors == 0 and audit_ok and settings.click_variants_enabled then
      if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
      if bildi_render_click_variants(project, verified_path, audit, audit_path,
          analysis, report, settings, has_foh) then return end
    end
    if TEST_MODE then
      progress_close()
      finish_project_transaction(project, settings)
      store_test_result((#errors == 0 and "OK POST-RENDER\n" or "POST-RENDER VALIDATION ERROR\n") .. audit)
      return
    end
    local restored, restore_error = finish_project_transaction(project, settings)
    if #errors > 0 then
      progress_close()
      write_checkpoint(settings, "FAILED_VERIFICATION", table.concat(errors, " | "))
      reaper.ShowMessageBox("Automatic repair could not safely correct the WAV.\n\n" ..
        compact_list(errors, 4) .. "\n\nFailed file:\n" .. verified_path ..
        (restored and "\n\nThe original project routing was restored."
          or ("\n\nRestore warning: " .. tostring(restore_error))) ..
        "\n\nFull details are in its audit and the REAPER console.", SCRIPT_NAME, 0)
    else
      write_checkpoint(settings, "COMPLETE", verified_path)
      if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
      progress_update("Complete", "The verified WAV and audit were published successfully.", 1.0, true)
      progress_close()
      local message = "Show track rendered and verified successfully:\n\n" .. verified_path
      message = message .. (restored and "\n\nThe original project routing was restored and all temporary app tracks were removed."
        or ("\n\nRestore warning: " .. tostring(restore_error)))
      if (settings.post_render_repairs or 0) > 0 then
        message = message .. string.format("\n\nAutomatically corrected and rerendered %d time(s).", settings.post_render_repairs)
      end
      if audit_ok then message = message .. "\n\nAudit:\n" .. audit_path end
      if calibration_path then message = message .. "\n\nCalibration:\n" .. calibration_path end
      if #warnings > 0 then message = message .. "\n\nWarnings were written to the audit." end
      reaper.ShowMessageBox(message, SCRIPT_NAME, 0)
    end
  else
    progress_close()
    write_checkpoint(settings, "RENDER_FILE_MISSING", render_path)
    local restored, restore_error = finish_project_transaction(project, settings)
    if TEST_MODE then store_test_result("POST-RENDER ERROR\nExpected temporary WAV was not created: " .. render_path); return end
    reaper.ShowMessageBox("REAPER finished without creating the expected temporary WAV:\n\n" .. render_path ..
      (restored and "\n\nThe original project routing was restored."
        or ("\n\nRestore warning: " .. tostring(restore_error))), SCRIPT_NAME, 0)
  end
end

function click_summary_from_audit(text)
  local line = text:match("Final CLICK audibility:%s*([^\r\n]+)")
  if not line then return nil, "The failed audit has no CLICK verification result." end
  if line:find("not applicable", 1, true) then return false end
  local median = tonumber(line:match("median%s+([%+%-]?[%d%.]+)"))
  local p10 = tonumber(line:match("quietest 10%%%s+([%+%-]?[%d%.]+)"))
  local measured, expected = line:match("(%d+)%s*/%s*(%d+)%s+detected")
  local missing = tonumber(line:match("(%d+)%s+missing"))
  local floor = tonumber(line:match("floor%s+([%+%-]?[%d%.]+)"))
  if not median or not p10 or not measured or not expected or not missing or not floor then
    return nil, "The failed audit's CLICK verification could not be read safely."
  end
  measured, expected = tonumber(measured), tonumber(expected)
  if measured == 0 or measured ~= expected or missing ~= 0 or p10 < 3 then
    return nil, "The failed WAV did not prove complete, sufficiently audible CLICK hits; constant gain cannot repair that."
  end
  return {median_db = median, p10_db = p10, hits_measured = measured,
    hits_expected = expected, missing_hits = missing, coverage = measured / expected,
    floor_db = floor}
end

-- A recovered WAV is a *new* file; the failed source and its audit remain
-- untouched. Only peak/preferred-click failures from a checksum-matched prior
-- app render are eligible, because static channel gain cannot repair routing,
-- silence, missing hits, malformed padding, or other hard defects.
function repair_last_failed_wav()
  local suggested = reaper.GetExtState(EXTSTATE_SECTION, "last_failed_wav_v39")
  if suggested == "" then suggested = reaper.GetExtState(EXTSTATE_SECTION, "last_failed_wav_v38") end
  if suggested == "" then suggested = reaper.GetExtState(EXTSTATE_SECTION, "last_output_directory") end
  local selected, failed_path = reaper.GetUserFileName(0,
    "Choose a Bildibeat _FAILED_INSPECTION WAV to recover", suggested, "WAV audio|*.wav")
  if not selected then return end
  local function refuse(message)
    reaper.ShowMessageBox("The failed WAV was not changed.\n\n" .. tostring(message), SCRIPT_NAME, 0)
  end
  if not failed_path:upper():find("_FAILED_INSPECTION", 1, true) or not file_exists(failed_path) then
    refuse("Choose an existing Bildibeat _FAILED_INSPECTION.wav file.")
    return
  end
  local audit_path = failed_path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
  local old_audit = common.read_audit(audit_path)
  if not old_audit or not old_audit.status or not old_audit.status:upper():find("FAIL", 1, true)
      or not old_audit.checksum or not old_audit.profile_id or not old_audit.content_duration then
    refuse("Its failed-inspection audit is missing or incomplete: " .. audit_path)
    return
  end
  local checksum, hash_error = common.sha256_file(failed_path)
  if not checksum or checksum:lower() ~= old_audit.checksum:lower() then
    refuse("The failed WAV no longer matches its audit SHA-256: " .. tostring(hash_error or "content changed"))
    return
  end
  local error_body = old_audit.text:match("\nERRORS\n(.-)\nWARNINGS\n")
    or old_audit.text:match("\nERRORS\n(.*)")
  if not error_body then refuse("The audit has no readable failure list."); return end
  local peak_failure = false
  for line in error_body:gmatch("[^\r\n]+") do
    if line:find("Rendered left estimated true peak", 1, true)
        or line:find("Rendered right estimated true peak", 1, true) then
      peak_failure = true
    elseif line:find("Rendered CLICK quiet-hit prominence", 1, true) then
      -- A fixed gain preserves the click/music ratio; only the existing
      -- audited safe-audible fallback may accept this preferred-target miss.
    elseif trim(line) ~= "" then
      refuse("This failure is not correctable by constant WAV gain: " .. line)
      return
    end
  end
  if not peak_failure then refuse("There is no peak failure for static gain to correct."); return end
  local click_summary, click_problem = click_summary_from_audit(old_audit.text)
  if click_summary == nil then refuse(click_problem); return end
  local iem_target = tonumber(old_audit.text:match("IEM target:%s*([%+%-]?[%d%.]+)%s+LUFS"))
  local foh_target = tonumber(old_audit.text:match("FOH target:%s*([%+%-]?[%d%.]+)%s+LUFS"))
  local has_foh = old_audit.right_lufs ~= nil
  if not iem_target or not old_audit.iem_ceiling
      or (has_foh and (not foh_target or not old_audit.foh_ceiling)) then
    refuse("The failed audit has no complete IEM/FOH show profile.")
    return
  end
  local report = old_audit.text:match("^(.-)\nPOST%-RENDER FILE VERIFICATION\n")
  if not report then refuse("The original build report is incomplete."); return end
  local recovered_base = failed_path:gsub("%.[Ww][Aa][Vv]$", ""):gsub("_FAILED_INSPECTION", "")
  local output_path = unique_output_path(recovered_base .. "_RECOVERED.wav")
  if not output_path then refuse("No unused recovered WAV filename is available."); return end
  local project = reaper.EnumProjects(-1, "")
  local preflight_errors = preflight_output(project, output_path, old_audit.content_duration)
  if #preflight_errors > 0 then refuse(table.concat(preflight_errors, "\n")); return end
  local padding, padding_error = verify_existing_padding(failed_path, old_audit.content_duration)
  if not padding then refuse(padding_error); return end
  local settings = {iem_target = iem_target, iem_ceiling = old_audit.iem_ceiling,
    foh_target = foh_target, foh_ceiling = old_audit.foh_ceiling,
    selection_duration = padding.content_seconds, profile_id = old_audit.profile_id,
    source_dynamics_applied = old_audit.text:find("App-owned source compression:", 1, true) ~= nil,
    click_audibility_floor_db = click_summary and click_summary.floor_db or 5,
    inherited_click_audibility = click_summary or nil,
    hardware_safe_ceiling = old_audit.hardware_safe_ceiling,
    hardware_report_path = "",
    repair_log = {}, completion_policy = "NORMAL (+/-2.00 LU)"}
  local local_path = temporary_render_path(output_path)
  local copied, copy_error = copy_file(failed_path, local_path)
  if not copied then refuse("Could not stage the failed WAV locally: " .. tostring(copy_error)); return end
  local local_hash = common.sha256_file(local_path)
  if not local_hash or local_hash:lower() ~= checksum:lower() then
    os.remove(local_path)
    refuse("The local recovery copy did not match the failed WAV checksum.")
    return
  end
  local analyzed, analysis = pcall(analyze_stereo_output, project, local_path,
    padding.leading_seconds, padding.content_seconds, settings)
  if not analyzed then os.remove(local_path); refuse("Could not analyze the failed WAV: " .. tostring(analysis)); return end
  if click_summary then analysis.click_audibility = click_summary end
  local repair_ok, candidate, reason = pcall(attempt_static_peak_repair,
    project, local_path, padding, analysis, settings, has_foh)
  if not repair_ok or not candidate then
    os.remove(local_path)
    refuse(repair_ok and reason or candidate)
    return
  end
  settings.completion_policy = candidate.policy
  settings.static_wav_repairs = 1
  if candidate.policy:find("FALLBACK", 1, true) then settings.safe_audible_fallback_used = true end
  append_repair(settings, string.format(
    "Static WAV recovery: SHA-256 matched the failed file; left %+.2f dB, right %+.2f dB fixed gain; separately verified without rerendering.",
    candidate.left_db, candidate.right_db))
  local candidate_checksum, candidate_hash_error = common.sha256_file(candidate.path)
  if not candidate_checksum then
    os.remove(candidate.path)
    os.remove(local_path)
    refuse("The verified candidate could not be checksummed: " .. tostring(candidate_hash_error))
    return
  end
  local warnings = {"Recovered from a checksum-matched failed WAV; CLICK prominence was inherited from the original audit because uniform channel gain preserves its ratio."}
  for _, warning in ipairs(candidate.warnings) do warnings[#warnings + 1] = warning end
  local recovered_report = report .. "\n\nRecovery source: " .. failed_path ..
    "\nRecovery method: constant physical-channel attenuation; original failed WAV and audit preserved."
  local recovered_audit = build_audit(recovered_report, candidate.analysis, settings,
    {}, warnings, nil, candidate_checksum, candidate.padding)
  local published, new_audit_path = publish_verified_pair(candidate.path,
    output_path, recovered_audit, candidate_checksum)
  if not published then
    os.remove(local_path)
    refuse("The verified recovery WAV and audit could not be published together: " ..
      tostring(new_audit_path) .. "\nCandidate retained at: " .. candidate.path)
    return
  end
  os.remove(local_path)
  reaper.ShowMessageBox("Recovered show track verified and saved:\n\n" .. output_path ..
    "\n\nOriginal failed WAV was left unchanged.\nAudit: " .. new_audit_path ..
    "\n\nConstant gain was used; no pumping or dynamic ducking was introduced.", SCRIPT_NAME, 0)
end

-- Recover a fully written local render after REAPER or the host exits before
-- final verification. The old temporary WAV is never edited; a checksum-
-- matched copy is padded (if needed), measured, and pair-published.
function prepare_interrupted_wav(path, selection_duration)
  local layout, layout_error = wav_layout(path)
  if not layout then return nil, "The temporary WAV is not complete: " .. tostring(layout_error) end
  local padding = verify_existing_padding(path, selection_duration)
  if padding then return padding, "already padded" end
  local raw_duration = layout.data_size / layout.block_align / layout.sample_rate
  if math.abs(raw_duration - selection_duration) > 0.001 then
    return nil, "The temporary WAV is neither a complete song-length render nor a verified padded render."
  end
  local padded, pad_error = pad_rendered_wav(path, LEADING_SILENCE_SECONDS, TRAILING_SILENCE_SECONDS)
  if not padded then return nil, "Padding could not be safely restored: " .. tostring(pad_error) end
  return padded, "padding added"
end

function recover_interrupted_render()
  local chosen, checkpoint_path = reaper.GetUserFileName(0,
    "Choose the prior SONG_SHOWTRACK.bildibeat_checkpoint.txt",
    reaper.GetExtState(EXTSTATE_SECTION, "last_output_directory"), "Text files|*.txt")
  if not chosen then return end
  local function refuse(message)
    reaper.ShowMessageBox("No interrupted render was published.\n\n" .. tostring(message) ..
      "\n\nThe original temporary WAV and checkpoint were left intact.", SCRIPT_NAME, 0)
  end
  local checkpoint_text = read_text(checkpoint_path)
  local meta, meta_error = parse_resume_checkpoint(checkpoint_text)
  if not meta then refuse(meta_error); return end
  if checkpoint_path_for_output(meta.output_path):lower() ~= checkpoint_path:lower() then
    refuse("This checkpoint does not belong to its recorded output filename.")
    return
  end
  local prior_audit_path = meta.output_path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
  if file_exists(meta.output_path) and file_exists(prior_audit_path) then
    local prior = common.read_audit(prior_audit_path)
    local final_hash = common.sha256_file(meta.output_path)
    if prior and prior.status and prior.status:find("PASS", 1, true)
        and prior.checksum and final_hash
        and prior.checksum:lower() == final_hash:lower() then
      os.remove(checkpoint_path)
      reaper.ShowMessageBox("The previous show track was already published as a verified WAV/audit pair:\n\n" ..
        meta.output_path .. "\n\nNo rerender or recovery was needed.", SCRIPT_NAME, 0)
      return
    end
  end
  local safe_root = join_path(local_work_root(), "Renders"):gsub("/", "\\"):lower() .. "\\"
  local render_name = meta.render_path:gsub("/", "\\"):lower()
  if render_name:sub(1, #safe_root) ~= safe_root or render_name:find("%.%.")
      or (not render_name:find("%.bildibeat_render_tmp%.wav$")
        and not render_name:find("%.bildibeat_static_peak%.wav$")) then
    refuse("The checkpoint's render path is not an app-created local temporary WAV.")
    return
  end
  if not file_exists(meta.render_path) then
    refuse("The checkpoint's temporary WAV no longer exists: " .. meta.render_path)
    return
  end
  if reaper.EnumProjects(0x40000000, "") then
    refuse("REAPER is still rendering. Wait until its current render finishes before recovery.")
    return
  end
  local output_path = meta.output_path
  local expected_audit = output_path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
  if file_exists(output_path) or file_exists(expected_audit) then
    local selected, alternate = reaper.GetUserFileName(0,
      "Choose an unused destination for the recovered show track", output_path,
      "WAV audio|*.wav")
    if not selected then return end
    output_path = ensure_wav_extension(alternate)
  end
  local project = reaper.EnumProjects(-1, "")
  local preflight_errors = preflight_output(project, output_path, meta.selection_duration)
  if #preflight_errors > 0 then refuse(table.concat(preflight_errors, "\n")); return end
  local original_layout, layout_error = wav_layout(meta.render_path)
  if not original_layout then refuse("The temporary WAV is not complete: " .. tostring(layout_error)); return end
  local original_hash, original_hash_error = common.sha256_file(meta.render_path)
  if not original_hash then refuse("Could not checksum the temporary WAV: " .. tostring(original_hash_error)); return end
  local stage_path = temporary_render_path(output_path)
  local copied, copy_error = copy_file(meta.render_path, stage_path)
  if not copied then refuse("Could not stage the temporary WAV: " .. tostring(copy_error)); return end
  local staged_hash = common.sha256_file(stage_path)
  if not staged_hash or staged_hash:lower() ~= original_hash:lower() then
    os.remove(stage_path)
    refuse("The temporary WAV copy did not match its original full-file checksum; wait for all writes to finish.")
    return
  end
  local padding, pad_error = prepare_interrupted_wav(stage_path, meta.selection_duration)
  if not padding then os.remove(stage_path); refuse(pad_error); return end
  local settings = {
    selection_start = meta.selection_start, selection_duration = meta.selection_duration,
    iem_target = meta.iem_target, iem_ceiling = meta.iem_ceiling,
    foh_target = meta.foh_target, foh_ceiling = meta.foh_ceiling,
    click_hit_times = meta.click_hit_times,
    click_audibility_floor_db = meta.click_audibility_floor_db,
    profile_id = meta.profile_id, completion_policy = "NORMAL (+/-2.00 LU)",
    source_dynamics_applied = meta.source_dynamics_applied,
    repair_log = {}, hardware_report_path = "",
  }
  local analyzed, analysis = pcall(analyze_stereo_output, project, stage_path,
    padding.leading_seconds, padding.content_seconds, settings)
  if not analyzed then os.remove(stage_path); refuse("The completed WAV could not be analyzed: " .. tostring(analysis)); return end
  local errors, warnings = post_render_validation(analysis, settings, meta.has_foh, padding, "normal")
  if #errors > 0 and finite(analysis.stereo.true_peak_left_db)
      and (analysis.stereo.true_peak_left_db > settings.iem_ceiling + TRUE_PEAK_GUARD_DB
        or (meta.has_foh and finite(analysis.stereo.true_peak_right_db)
          and analysis.stereo.true_peak_right_db > settings.foh_ceiling + TRUE_PEAK_GUARD_DB)) then
    local repair_ok, candidate, reason = pcall(attempt_static_peak_repair,
      project, stage_path, padding, analysis, settings, meta.has_foh)
    if repair_ok and candidate then
      os.remove(stage_path)
      stage_path, padding, analysis = candidate.path, candidate.padding, candidate.analysis
      errors, warnings = {}, candidate.warnings
      settings.completion_policy = candidate.policy
      append_repair(settings, string.format(
        "Static WAV interrupted-render recovery: left %+.2f dB, right %+.2f dB fixed gain.",
        candidate.left_db, candidate.right_db))
    else
      append_repair(settings, "Static WAV recovery was unavailable: " .. tostring(repair_ok and reason or candidate))
    end
  end
  if #errors > 0 then
    errors, warnings = post_render_validation(analysis, settings, meta.has_foh, padding, "safety")
    if #errors == 0 then settings.completion_policy = "SAFE AUDIBLE FALLBACK (quality exceptions audited)" end
  end
  if #errors > 0 then
    os.remove(stage_path)
    refuse("The interrupted WAV failed hard output checks: " .. compact_list(errors, 4))
    return
  end
  local calibration_path
  if meta.create_calibration then
    local cal_ok, cal_result = pcall(create_calibration_wav, output_path, settings)
    if cal_ok then calibration_path = cal_result
    else warnings[#warnings + 1] = "Calibration WAV failed during recovery: " .. tostring(cal_result) end
  end
  for _, warning in ipairs(meta.warnings) do warnings[#warnings + 1] = warning end
  local checksum, checksum_error = common.sha256_file(stage_path)
  if not checksum then os.remove(stage_path); refuse("Recovered WAV checksum failed: " .. tostring(checksum_error)); return end
  local report = meta.report .. "\nInterrupted-render recovery source: " .. meta.render_path ..
    "\nThe finished temporary WAV was remeasured; the original source project was not rerendered."
  local audit = build_audit(report, analysis, settings, {}, warnings, calibration_path, checksum, padding)
  local published, audit_path = publish_verified_pair(stage_path, output_path, audit, checksum)
  if not published then
    os.remove(stage_path)
    refuse("The verified WAV/audit pair could not be published: " .. tostring(audit_path))
    return
  end
  os.remove(meta.render_path)
  os.remove(checkpoint_path)
  reaper.ShowMessageBox("Interrupted show track recovered and verified:\n\n" .. output_path ..
    "\n\nMatching audit: " .. audit_path ..
    "\n\nNo new song render or pumping gain was used.", SCRIPT_NAME, 0)
end

local function main()
  if repair_mode == "resume" then recover_interrupted_render(); return end
  if repair_mode then repair_last_failed_wav(); return end
  if not reaper.GetUserFileName or not reaper.CreateTrackAudioAccessor then
    reaper.ShowMessageBox("This script requires a current REAPER 7 installation.", SCRIPT_NAME, 0)
    return
  end
  local project = reaper.EnumProjects(-1, "")
  local records, by_role, conflicts, unlabeled_audio, solo_filter, excluded_labeled, excluded_clicks = scan_project(project)
  if #conflicts > 0 then
    reaper.ShowMessageBox("Conflicting track labels:\n\n" .. compact_list(conflicts, 8), SCRIPT_NAME, 0)
    return
  end
  local solo_note = solo_filter and "\n\nSolo filtering is active. Only soloed labeled tracks are being considered." or ""
  if #by_role.CLICK > 1 then
    reaper.ShowMessageBox("At most one track labeled CLICK is allowed. Found: " .. #by_role.CLICK .. solo_note, SCRIPT_NAME, 0)
    return
  end
  if #by_role.BACKING == 0 then
    reaper.ShowMessageBox("At least one track labeled BACKING is required." .. solo_note, SCRIPT_NAME, 0)
    return
  end
  if #by_role.CLICK == 0 and #excluded_clicks > 0 then
    reaper.ShowMessageBox(
      "A track labeled CLICK exists, but solo filtering excluded it:\n\n" ..
      compact_list(excluded_clicks, 4) ..
      "\n\nBecause another labeled track is soloed, the app respects REAPER solo state and will not silently omit the click. Solo the CLICK track too, or clear the other solos, then run the app again.",
      SCRIPT_NAME, 0)
    return
  end
  local start_time, end_time = selected_time_bounds(project)
  if not start_time then
    reaper.ShowMessageBox("Create a non-empty REAPER time selection for the exact show-track mixdown range, then run the script again.", SCRIPT_NAME, 0)
    return
  end
  local click_samples
  if #by_role.CLICK > 0 then
    click_samples = CLICK_MULTI.choose_samples(project, start_time, end_time)
    if not click_samples then return end
  end
  local settings = choose_settings()
  if not settings then return end
  apply_hardware_safe_ceiling(settings)
  if settings.hardware_chain_unsafe then
    reaper.ShowMessageBox(string.format(
      "E_HARDWARE_CROSSTALK: The latest loopback test requires an IEM ceiling of %.2f dBFS, below the app's safe controllable range. Replace or isolate the adapter/breakout chain and rerun the loopback test.\n\nReport:\n%s",
      settings.hardware_safe_ceiling, settings.hardware_report_path ~= "" and settings.hardware_report_path or "unavailable"),
      SCRIPT_NAME, 0)
    return
  end
  settings.project = project
  settings.click_sample_a = click_samples and click_samples.a or nil
  settings.click_sample_b = click_samples and click_samples.b or nil
  settings.click_alt_sample = click_samples and click_samples.alt or nil
  settings.click_b_relative_db = click_samples and click_samples.relative_b_db or 0
  settings.click_alt_ranges = click_samples and click_samples.ranges or {}
  settings.click_alt_labels = click_samples and click_samples.labels or {}
  settings.selection_start = start_time
  settings.selection_end = end_time
  settings.selection_duration = end_time - start_time
  settings.profile_id = common.profile_id(profile_string(settings), PROCESSING_PROFILE_VERSION)
  local output_path = choose_output_path(project)
  if not output_path then return end
  local temp_ok, render_path = pcall(temporary_render_path, output_path)
  if not temp_ok then
    reaper.ShowMessageBox(tostring(render_path), SCRIPT_NAME, 0)
    return
  end
  settings.final_output_path = output_path
  settings.render_output_path = render_path
  settings.checkpoint_path = checkpoint_path_for_output(output_path)
  settings.recovery_checkpoint_found = file_exists(settings.checkpoint_path)
  local preflight_errors, preflight_warnings = preflight_output(project, output_path, end_time - start_time)
  if #preflight_errors > 0 then
    reaper.ShowMessageBox(table.concat(preflight_errors, "\n"), SCRIPT_NAME, 0)
    return
  end
  settings.reference = load_show_reference(output_path, settings.profile_id)
  if not TEST_MODE then
    local calibration_answer = reaper.ShowMessageBox(
      "Create a 9-second left-only/right-only breakout calibration WAV beside the show track?\n\n" ..
      "Use it to test the exact iPad, adapter, breakout cable, DI, IEM, and FOH chain.\n" ..
      "Start with downstream volume low.\n\nYes: create it   No: show track only   Cancel: stop",
      SCRIPT_NAME,
      3
    )
    if calibration_answer == 2 then return end
    settings.create_calibration = calibration_answer == 6
  end

  local priorities = {LEAD = 0, RHYTHM = 0, BED = 0}
  local offset_count = 0
  for _, record in ipairs(records) do
    if record.role == "FOH" then priorities[record.priority] = priorities[record.priority] + 1 end
    if math.abs(record.intent_offset or 0) > EPS then offset_count = offset_count + 1 end
  end

  local summary = {
    string.format("CLICK: %d   BACKING: %d   FOH: %d", #by_role.CLICK, #by_role.BACKING, #by_role.FOH),
    #by_role.FOH > 0 and string.format("FOH priorities: LEAD %d   RHYTHM %d   BED %d", priorities.LEAD, priorities.RHYTHM, priorities.BED)
                     or "FOH priorities: not applicable",
    string.format("Intent offsets: %d track(s)", offset_count),
    string.format("Time-selection mixdown: %.3f to %.3f seconds (%.3f seconds)", start_time, end_time, end_time - start_time),
    string.format("Generated file: %.1f seconds silence + selected content + %.1f seconds silence (%.3f seconds total)",
      LEADING_SILENCE_SECONDS, TRAILING_SILENCE_SECONDS, end_time - start_time + LEADING_SILENCE_SECONDS + TRAILING_SILENCE_SECONDS),
    click_samples and ("CLICK audio replacement: metronome A " .. click_samples.a.filename ..
      " | B " .. click_samples.b.filename ..
      (click_samples.alt and (" | ALT " .. click_samples.alt.filename) or ""))
                 or "CLICK audio replacement: not applicable",
    #by_role.CLICK > 0 and string.format("Left target %.1f LUFS; ceiling %.1f dBFS; click advantage %.1f dB", settings.iem_target, settings.iem_ceiling, settings.click_advantage)
                       or string.format("Left target %.1f LUFS; ceiling %.1f dBFS; no CLICK track", settings.iem_target, settings.iem_ceiling),
    #by_role.FOH > 0 and string.format("Right target %.1f LUFS; ceiling %.1f dBFS", settings.foh_target, settings.foh_ceiling)
                     or "Right channel: digital silence (no FOH track)",
    "Profile: " .. (settings.profile_locked and "LOCKED" or "editable next run"),
    "Profile ID: " .. settings.profile_id,
    "Approved reference: " .. (settings.reference and ((settings.reference.source or "configured") .. (settings.reference.compatible and "" or " (PROFILE MISMATCH)")) or "none in output folder"),
    "Breakout calibration: " .. (settings.create_calibration and "create companion WAV" or "not requested"),
    settings.hardware_safe_ceiling and string.format(
      "Hardware loopback ceiling: %.1f dBFS%s", settings.hardware_safe_ceiling,
      settings.hardware_ceiling_applied and " (automatically applied)" or " (configured profile is already safer)")
      or "Hardware loopback ceiling: not measured; calibration is strongly recommended",
    "Output: " .. output_path,
    "",
    "The script will set labeled-track faders to 0 dB, reset item/take gain, bypass existing FX and envelopes, rebuild routing, and exclude unlabeled tracks from the master.",
  }
  for _, warning in ipairs(preflight_warnings) do summary[#summary + 1] = "Preflight warning: " .. warning end
  if settings.recovery_checkpoint_found then
    summary[#summary + 1] = "Recovery: an incomplete prior build checkpoint was found; this run will restart cleanly and replace it."
  end
  if solo_filter then
    summary[#summary + 1] = ""
    summary[#summary + 1] = string.format(
      "Solo filter active: only the %d soloed labeled source track(s) above will be included; %d non-soloed labeled track(s) will be excluded.",
      #records,
      #excluded_labeled
    )
  end
  if #unlabeled_audio > 0 then
    summary[#summary + 1] = ""
    summary[#summary + 1] = string.format("%d unlabeled audio track(s) will be excluded from the render.", #unlabeled_audio)
  end
  summary[#summary + 1] = ""
  summary[#summary + 1] = "Continue? Initial setup is one Undo; each automatic post-render repair is recorded as its own Undo step."
  if not TEST_MODE then
    local compact_summary = {
      string.format("Sources: CLICK %d | BACKING %d | FOH %d", #by_role.CLICK, #by_role.BACKING, #by_role.FOH),
      string.format("Selected content: %.3f seconds", end_time - start_time),
      string.format("Final duration: %.3f seconds (includes %.1f s before and %.1f s after)",
        end_time - start_time + LEADING_SILENCE_SECONDS + TRAILING_SILENCE_SECONDS,
        LEADING_SILENCE_SECONDS, TRAILING_SILENCE_SECONDS),
      #by_role.CLICK > 0 and string.format("IEM: %.1f LUFS | ceiling %.1f dBFS | click +%.1f dB",
        settings.iem_target, settings.iem_ceiling, settings.click_advantage)
        or string.format("IEM: %.1f LUFS | ceiling %.1f dBFS | no CLICK", settings.iem_target, settings.iem_ceiling),
      #by_role.FOH > 0 and string.format("FOH: %.1f LUFS | ceiling %.1f dBFS", settings.foh_target, settings.foh_ceiling)
        or "FOH: absent; right channel will be digital silence",
      solo_filter and string.format("Solo filter: ON (%d labeled source track(s) included)", #records) or "Solo filter: off",
      string.format("Excluded unlabeled audio tracks: %d", #unlabeled_audio),
      settings.hardware_safe_ceiling and string.format("Hardware-safe IEM ceiling: %.1f dBFS%s",
        settings.hardware_safe_ceiling, settings.hardware_ceiling_applied and " (applied)" or "")
        or "Hardware-safe IEM ceiling: not measured",
      "",
      "Output:", output_path,
      "",
      "Continue with setup and analysis?",
    }
    settings.build_options_summary = compact_summary
  end

  local function execute_build()
  progress_open("Starting build", "Installing and self-testing the embedded processor.", 0.01)
  local processor_call_ok, processor_ok, processor_error = xpcall(function()
    install_processor_jsfx()
    return processor_self_test(project)
  end, debug.traceback)
  if not processor_call_ok then
    progress_close()
    write_checkpoint(settings, "PROCESSOR_INSTALL_FAILED", tostring(processor_ok))
    local diagnostic_path = write_diagnostic(settings, "E_PROCESSOR_INSTALL", processor_ok)
    if TEST_MODE then
      store_test_result("ERROR\nE_PROCESSOR_INSTALL\n" .. tostring(processor_ok))
      return
    end
    reaper.ShowMessageBox("The embedded processor could not be installed or self-tested. No project processing was started.\n\n" ..
      compact_detail(processor_ok, 5, 600) ..
      (diagnostic_path and ("\n\nDiagnostic:\n" .. diagnostic_path) or ""), SCRIPT_NAME, 0)
    return
  end
  if not processor_ok then
    progress_close()
    write_checkpoint(settings, "PROCESSOR_SELF_TEST_FAILED", tostring(processor_error))
    local diagnostic_path = write_diagnostic(settings, "E_PROCESSOR_SELF_TEST", processor_error)
    if TEST_MODE then
      store_test_result("ERROR\nE_PROCESSOR_SELF_TEST\n" .. tostring(processor_error))
      return
    end
    reaper.ShowMessageBox(processor_error ..
      (diagnostic_path and ("\n\nDiagnostic:\n" .. diagnostic_path) or ""), SCRIPT_NAME, 0)
    return
  end
  settings.project_backup_path = create_project_backup(project, output_path)
  local snapshot, snapshot_error = capture_project_snapshot(project)
  if not snapshot then
    progress_close()
    reaper.ShowMessageBox(
      "The app stopped before changing the project because it could not create a complete routing snapshot.\n\n" ..
      tostring(snapshot_error), SCRIPT_NAME, 0)
    return
  end
  settings.project_snapshot = snapshot
  write_checkpoint(settings, "PREPARING", settings.project_backup_path and ("Backup: " .. settings.project_backup_path) or "")
  reaper.ClearConsole()
  console(SCRIPT_NAME .. " - build started")
  reaper.Undo_BeginBlock2(project)
  reaper.PreventUIRefresh(1)
  local ok, report, errors, warnings = xpcall(function()
    return run_build(project, records, by_role, settings, output_path, start_time, end_time)
  end, debug.traceback)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  if not ok then
    progress_close()
    write_checkpoint(settings, "FAILED_SETUP", tostring(report))
    local cancelled = tostring(report):find("BILDI_USER_CANCELLED", 1, true) ~= nil
    local diagnostic_path = not cancelled and write_diagnostic(settings, "E_BUILD_SETUP", report) or nil
    reaper.Undo_EndBlock2(project, SCRIPT_NAME .. " (failed)", -1)
    if TEST_MODE then
      store_test_result("ERROR\n" .. tostring(report))
      return
    end
    local restored, restore_error = finish_project_transaction(project, settings)
    if cancelled then
      if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
      reaper.ShowMessageBox("Build cancelled safely. The original project routing was restored." ..
        (restored and "" or ("\n\nRestore warning: " .. tostring(restore_error))), SCRIPT_NAME, 0)
    else
      reaper.ShowMessageBox("Build failed and the original project routing was restored.\n\n" .. compact_detail(report, 6, 650) ..
        (restored and "" or ("\n\nRestore warning: " .. tostring(restore_error))) ..
        (diagnostic_path and ("\n\nDiagnostic:\n" .. diagnostic_path) or ""), SCRIPT_NAME, 0)
    end
    return
  end
  reaper.Undo_EndBlock2(project, SCRIPT_NAME, -1)
  write_checkpoint(settings, "METER_COMPLETE", string.format("Meter passes: %d", settings.meter_passes or 0))
  console("\n" .. report)
  for _, warning in ipairs(preflight_warnings) do warnings[#warnings + 1] = warning end

  -- Offline meter passes are guidance, not a reason to withhold a render.
  -- Numerical misses continue into the actual-WAV verification loop, which can
  -- measure, repair, rerender, and recheck the file itself. Structural setup
  -- problems have already stopped safely above via explicit errors.
  if #errors > 0 then
    local preliminary = {}
    for _, problem in ipairs(errors) do
      preliminary[#preliminary + 1] = "Pre-render meter miss handed to actual-WAV auto-repair: " .. problem
    end
    for _, message in ipairs(preliminary) do warnings[#warnings + 1] = message end
    append_repair(settings, string.format(
      "%d preliminary numerical miss(es) were passed to the actual-WAV repair loop instead of stopping the render.", #errors))
    errors = {}
  end
  if #warnings > 0 then console("\nWARNINGS\n" .. table.concat(warnings, "\n")) end

  progress_close()

  if TEST_MODE and not TEST_RENDER_MODE then
    finish_project_transaction(project, settings)
    store_test_result("OK\n" .. report)
    return
  end

  local function begin_render()
    settings.assigned_click_offset_db = by_role.CLICK[1] and (by_role.CLICK[1].intent_offset or 0) or 0
    local started_at = reaper.time_precise()
    progress_open("Rendering show track", "REAPER is creating the temporary stereo WAV. Cancel waits for the current render to finish safely.", 0.92)
    progress_update(nil, nil, 0.92, false)
    settings.resume_report = report
    settings.resume_warnings = warnings
    settings.resume_has_foh = #by_role.FOH > 0
    settings.resume_ready = true
    write_checkpoint(settings, "RENDERING", "Render attempt 1")
    local render_started, render_start_error = start_verified_render(project, render_path, settings, #by_role.FOH > 0)
    if not render_started then
      progress_close()
      write_checkpoint(settings, "RENDER_GRAPH_FAILED", tostring(render_start_error))
      local restored, restore_error = finish_project_transaction(project, settings)
      if TEST_MODE then store_test_result("POST-RENDER ERROR\nE_RENDER_GRAPH: " .. tostring(render_start_error)); return end
      reaper.ShowMessageBox("E_RENDER_GRAPH: " .. tostring(render_start_error) ..
        (restored and "\n\nOriginal project routing was restored."
          or ("\n\nRestore warning: " .. tostring(restore_error))), SCRIPT_NAME, 0)
      return
    end
    wait_for_render(project, render_path, output_path, started_at, report, settings, #by_role.FOH > 0, warnings, 0, 0)
  end

  if TEST_MODE then
    if TEST_MIX_OFFSETS ~= "" then
      local index = 1
      for token in (TEST_MIX_OFFSETS .. ","):gmatch("(.-),") do
        if records[index] then apply_manual_track_offset(records[index], tonumber(trim(token)) or 0) end
        index = index + 1
      end
      local mix_detail = finalize_manual_mix(project, records, settings, start_time, end_time, #by_role.FOH > 0)
      report = report .. "\n" .. mix_detail
    end
    begin_render()
    return
  end

  if not settings.preview_enabled then
    begin_render()
    return
  end

  open_mix_preview_ui(project, records, by_role, settings, start_time, end_time,
    function()
      progress_open("Applying mixer choices", "Measuring the manual balance and preserving it during final normalization.", 0.90)
      local mix_ok, mix_detail = xpcall(function()
        return finalize_manual_mix(project, records, settings, start_time, end_time, #by_role.FOH > 0)
      end, debug.traceback)
      progress_close()
      if not mix_ok then
        write_checkpoint(settings, "FAILED_MANUAL_MIX", tostring(mix_detail))
        local restored, restore_error = finish_project_transaction(project, settings)
        reaper.ShowMessageBox("The manual mix could not be finalized. The original project was restored.\n\n" ..
          compact_detail(mix_detail, 6, 650) ..
          (restored and "" or ("\n\nRestore warning: " .. tostring(restore_error))), SCRIPT_NAME, 0)
        return
      end
      report = report .. "\n" .. mix_detail
      console("\n" .. mix_detail)
      begin_render()
    end,
    function(reason, restored, restore_error)
      write_checkpoint(settings, "CANCELLED_BEFORE_RENDER", tostring(reason or "Mixer closed"))
      if settings.checkpoint_path then os.remove(settings.checkpoint_path) end
      local message = "Mix/preview closed. No file was rendered."
      if restored then message = message .. "\n\nThe original project routing and levels were restored."
      else message = message .. "\n\nRestore warning: " .. tostring(restore_error) end
      console(message)
      reaper.ShowMessageBox(message, SCRIPT_NAME, 0)
    end)
  end

  if TEST_MODE then
    settings.preview_enabled = false
    settings.click_variants_enabled = TEST_VARIANTS_MODE and #by_role.CLICK > 0
    execute_build()
  else
    open_build_options_ui(settings.build_options_summary, output_path, #by_role.CLICK > 0,
      function(options)
        settings.preview_enabled = options.preview
        settings.click_variants_enabled = options.variants
        execute_build()
      end)
  end
end

main()

end

local function run_click_setter()
-- Manage one ALT sample. Normal A/B samples always come from the current
-- project's Metronome and pre-roll settings, including unsaved changes.
local SCRIPT_NAME = "Bildibeat Show Track App v4.2 - Click Samples"
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local script_directory = source_path:match("^(.*[\\/])") or ""
-- Shared utilities are embedded by the unified app.
local section = "Bildibeat_Show_Track_Builder"
local alt_key = "click_alt_sample_path_v42"

local function validate_sample(path)
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then return nil, "REAPER could not open that ALT click sample." end
  local length = reaper.GetMediaSourceLength(source)
  local rate = reaper.GetMediaSourceSampleRate(source)
  if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(source) end
  if not length or length < 0.003 or length > 2 or not rate or rate <= 0 then
    return nil, "Choose a valid single-hit audio sample between 3 ms and 2 seconds long."
  end
  local checksum, checksum_error = common.sha256_file(path)
  if not checksum then return nil, "Could not checksum the ALT sample:\n\n" .. tostring(checksum_error) end
  return {path = path, id = "CLK-" .. checksum:sub(1, 12):upper()}
end

local test_path = reaper.GetExtState(section, "click_sample_set_test_path")
if test_path ~= "" then
  reaper.DeleteExtState(section, "click_sample_set_test_path", true)
  reaper.DeleteExtState(section, "click_sample_set_test_slot", true)
  local details, problem = validate_sample(test_path)
  if not details then
    reaper.SetExtState(section, "click_sample_set_test_result", "FAIL|" .. tostring(problem), false)
  else
    reaper.SetExtState(section, alt_key, test_path, true)
    reaper.SetExtState(section, "click_sample_set_test_result", "PASS|ALT|" .. details.id .. "|" .. test_path, false)
  end
  return
end

local project = reaper.EnumProjects(-1, "")
local metronome, metronome_problem = common.read_project_metronome(project)
local alt_path = reaper.GetExtState(section, alt_key)
local width, height, previous_mouse_down = 780, 300, false
local status = metronome and "Only this ALT sample is selected here; A/B always come from the current project."
  or ("Metronome A/B unavailable: " .. tostring(metronome_problem))

local function shorten(value, maximum)
  value = tostring(value or "")
  if value == "" then return "Not assigned" end
  if #value <= maximum then return value end
  return "..." .. value:sub(-(maximum - 3))
end

local function button(x, y, w, h, label, hovered)
  if hovered then gfx.set(0.18, 0.46, 0.72, 1) else gfx.set(0.12, 0.25, 0.38, 1) end
  gfx.rect(x, y, w, h, true)
  gfx.set(0.96, 0.98, 1, 1); gfx.setfont(3, "Arial", 13, 98)
  local tw, th = gfx.measurestr(label)
  gfx.x, gfx.y = x + (w - tw) / 2, y + (h - th) / 2
  gfx.drawstr(label)
end

local function draw()
  local w, h = math.max(gfx.w, 560), math.max(gfx.h, 270)
  gfx.set(0.035, 0.055, 0.078, 1); gfx.rect(0, 0, w, h, true)
  gfx.set(0.96, 0.98, 1, 1); gfx.setfont(1, "Arial", 25, 98)
  gfx.x, gfx.y = 22, 15; gfx.drawstr("Click Samples")
  gfx.setfont(2, "Arial", 15, 98)
  gfx.x, gfx.y = 24, 63; gfx.drawstr("Normal A: " .. shorten(metronome and metronome.a, 80))
  gfx.x, gfx.y = 24, 91; gfx.drawstr("Normal B: " .. shorten(metronome and metronome.b, 80))
  gfx.x, gfx.y = 24, 127; gfx.drawstr("ALT sample: " .. shorten(alt_path, 70))
  gfx.set(0.62, 0.75, 0.87, 1); gfx.setfont(3, "Arial", 12)
  gfx.x, gfx.y = 24, 159
  gfx.drawstr("One ALT sample is used for every CLICK ALT / ALT CLICK marker pair, numbered or not.")
  local browse_x, clear_x, done_x = 24, 130, w - 115
  local button_y = h - 82
  button(browse_x, button_y, 96, 38, "Browse ALT", gfx.mouse_x >= browse_x and gfx.mouse_x <= browse_x + 96 and gfx.mouse_y >= button_y and gfx.mouse_y <= button_y + 38)
  button(clear_x, button_y, 90, 38, "Clear ALT", gfx.mouse_x >= clear_x and gfx.mouse_x <= clear_x + 90 and gfx.mouse_y >= button_y and gfx.mouse_y <= button_y + 38)
  button(done_x, button_y, 90, 38, "Done", gfx.mouse_x >= done_x and gfx.mouse_x <= done_x + 90 and gfx.mouse_y >= button_y and gfx.mouse_y <= button_y + 38)
  gfx.set(0.60, 0.68, 0.75, 1); gfx.setfont(3, "Arial", 11)
  gfx.x, gfx.y = 24, h - 28; gfx.drawstr(shorten(status, math.max(50, math.floor((w - 40) / 7))))
  gfx.update()
end

local function loop()
  local character = gfx.getchar()
  if character < 0 or character == 27 then gfx.quit(); return end
  local w, h = math.max(gfx.w, 560), math.max(gfx.h, 270)
  local mouse_down = (gfx.mouse_cap & 1) == 1
  if mouse_down and not previous_mouse_down then
    local y = h - 82
    if gfx.mouse_y >= y and gfx.mouse_y <= y + 38 then
      if gfx.mouse_x >= w - 115 and gfx.mouse_x <= w - 25 then gfx.quit(); return end
      if gfx.mouse_x >= 24 and gfx.mouse_x <= 120 then
        local ok, selected = reaper.GetUserFileName(0, "Choose one ALT click sample", alt_path or "",
          "Audio files|*.wav;*.aif;*.aiff;*.flac|All files|*.*")
        if ok then
          local details, problem = validate_sample(selected)
          if details then
            alt_path = selected
            reaper.SetExtState(section, alt_key, alt_path, true)
            status = "ALT sample saved: " .. details.id
          else
            status = tostring(problem)
            reaper.ShowMessageBox(status, SCRIPT_NAME, 0)
          end
        end
      elseif gfx.mouse_x >= 130 and gfx.mouse_x <= 220 then
        alt_path = ""
        reaper.SetExtState(section, alt_key, "", true)
        status = "ALT sample cleared. Build will ask only if an ALT range is used."
      end
    end
  end
  previous_mouse_down = mouse_down
  draw()
  reaper.defer(loop)
end

gfx.init(SCRIPT_NAME, width, height, 0)
draw()
loop()

end

local function run_reference_manager()
-- Bildibeat: capture an approved show-track reference for v3.9 builders.
local SCRIPT_NAME = "Bildibeat Show Track App v3.9 - Approved Reference"
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local script_directory = source_path:match("^(.*[\\/])") or ""
-- Shared utilities are embedded by the unified app.
local section = "Bildibeat_Show_Track_Builder"

local test_path = reaper.GetExtState(section, "reference_test_path")
if test_path ~= "" then reaper.DeleteExtState(section, "reference_test_path", true) end
local selected = test_path
if selected == "" then
  local ok
  ok, selected = reaper.GetUserFileName(0, "Choose an approved stereo show-track WAV", "", "WAV audio|*.wav")
  if not ok then return end
end

local project = reaper.EnumProjects(-1, "")
reaper.PreventUIRefresh(1)
local analysis, analysis_error = common.analyze_stereo_file(project, selected)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
if not analysis then
  reaper.ShowMessageBox("Reference analysis failed:\n\n" .. tostring(analysis_error), SCRIPT_NAME, 0)
  return
end

local directory, filename = common.split_path(selected)
local audit_path = selected:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
local audit = common.read_audit(audit_path)
local checksum, checksum_error = common.sha256_file(selected)
if not checksum then
  reaper.ShowMessageBox("Could not checksum the reference:\n\n" .. tostring(checksum_error), SCRIPT_NAME, 0)
  return
end
local reference_id = "REF-" .. checksum:sub(1, 12):upper()
local left_lufs = audit and audit.left_lufs or analysis.left.lufs
local left_crest = audit and audit.left_crest or analysis.left.crest_db
local left_low = audit and audit.left_low or analysis.left.low_pct
local left_mid = audit and audit.left_mid or analysis.left.mid_pct
local left_high = audit and audit.left_high or analysis.left.high_pct
local right_lufs = audit and audit.right_lufs or (not analysis.right.silent and analysis.right.lufs or nil)
local right_crest = audit and audit.right_crest or analysis.right.crest_db
local right_low = audit and audit.right_low or analysis.right.low_pct
local right_mid = audit and audit.right_mid or analysis.right.mid_pct
local right_high = audit and audit.right_high or analysis.right.high_pct
local output_path = common.join_path(directory, "BILDIBEAT_SHOW_REFERENCE.txt")
if common.file_exists(output_path) and test_path == "" then
  if reaper.ShowMessageBox("Replace the approved reference already stored in this folder?", SCRIPT_NAME, 4) ~= 6 then return end
end

local lines = {
  "BILDIBEAT SHOW REFERENCE v3.9",
  "==============================",
  "Source: " .. filename,
  "Reference ID: " .. reference_id,
  "Profile ID: " .. (audit and audit.profile_id or "UNKNOWN"),
  "SHA-256: " .. checksum,
  audit and audit.click_ratio and string.format("Click advantage: %.2f dB", audit.click_ratio) or "Click advantage: unavailable (no compatible audit)",
  string.format("Left loudness: %.2f LUFS", left_lufs),
  string.format("Left crest: %.2f dB", left_crest),
  string.format("Left spectral: low %.2f%% | mid %.2f%% | high %.2f%%", left_low, left_mid, left_high),
  not right_lufs and "Right: digital silence" or string.format("Right loudness: %.2f LUFS", right_lufs),
  not right_lufs and "Right crest: unavailable" or string.format("Right crest: %.2f dB", right_crest),
  not right_lufs and "Right spectral: digital silence" or string.format("Right spectral: low %.2f%% | mid %.2f%% | high %.2f%%",
    right_low, right_mid, right_high),
  "Created: " .. os.date("%Y-%m-%d %H:%M:%S"),
  "",
  "Place new show-track renders in this folder. Builder v3.9 and the Show Set Validator will compare them with this approved reference.",
}
local ok, write_error = common.write_text(output_path, table.concat(lines, "\n"))
if not ok then
  reaper.ShowMessageBox("Could not write the reference file:\n\n" .. tostring(write_error), SCRIPT_NAME, 0)
  return
end
reaper.SetExtState(section, "reference_test_result", output_path, false)
if test_path == "" then
  reaper.ShowMessageBox("Approved reference saved:\n\n" .. output_path .. "\n\nReference ID: " .. reference_id, SCRIPT_NAME, 0)
end

end

local function run_show_set_validator()
-- Validate every audited show-track WAV in one folder.
local SCRIPT_NAME = "Bildibeat Show Track App v3.9 - Show Set Validator"
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local script_directory = source_path:match("^(.*[\\/])") or ""
-- Shared utilities are embedded by the unified app.
local section = "Bildibeat_Show_Track_Builder"

local test_path = reaper.GetExtState(section, "validator_test_path")
if test_path ~= "" then reaper.DeleteExtState(section, "validator_test_path", true) end
local selected = test_path
if selected == "" then
  local ok
  ok, selected = reaper.GetUserFileName(0, "Choose any show-track WAV in the folder to validate", "", "WAV audio|*.wav")
  if not ok then return end
end
local directory = selected
if selected:lower():match("%.wav$") then directory = common.split_path(selected) end

local function list_wavs(path)
  local files, ignored, index = {}, {}, 0
  while true do
    local name = reaper.EnumerateFiles(path, index)
    if not name then break end
    local upper = name:upper()
    if upper:match("%.WAV$") then
      local wav_path = common.join_path(path, name)
      local audit_path = wav_path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
      local generated_candidate = common.file_exists(audit_path) or upper:find("SHOWTRACK", 1, true)
      local diagnostic_artifact = upper:find("_BREAKOUT_CAL", 1, true)
        or upper:find("_FAILED_INSPECTION", 1, true)
        or upper:find("_LOOPBACK", 1, true)
        or upper:find(".BILDIBEAT_", 1, true)
      if generated_candidate and not diagnostic_artifact then
        files[#files + 1] = name
      else
        ignored[#ignored + 1] = name
      end
    end
    index = index + 1
  end
  table.sort(files, function(a, b) return a:lower() < b:lower() end)
  return files, ignored
end

local function load_reference(path)
  local text = common.read_text(common.join_path(path, "BILDIBEAT_SHOW_REFERENCE.txt"))
  if not text then return nil end
  local reference = {
    id = text:match("Reference ID:%s*([%w%-]+)"),
    profile_id = text:match("Profile ID:%s*([%w%-]+)"),
  }
  reference.left_low, reference.left_mid, reference.left_high = text:match("Left spectral:%s*low%s+([%d%.]+)%%%s*|%s*mid%s+([%d%.]+)%%%s*|%s*high%s+([%d%.]+)%%")
  reference.right_low, reference.right_mid, reference.right_high = text:match("Right spectral:%s*low%s+([%d%.]+)%%%s*|%s*mid%s+([%d%.]+)%%%s*|%s*high%s+([%d%.]+)%%")
  for _, key in ipairs({"left_low","left_mid","left_high","right_low","right_mid","right_high"}) do reference[key] = tonumber(reference[key]) end
  return reference
end

local function difference_db(value, reference)
  if not value or not reference or reference <= 0 then return nil end
  return 10 * math.log(math.max(value, 0.0001) / math.max(reference, 0.0001), 10)
end

local wavs, ignored_wavs = list_wavs(directory)
if #wavs == 0 then
  reaper.ShowMessageBox("No WAV files were found in:\n\n" .. directory, SCRIPT_NAME, 0)
  return
end

reaper.ClearConsole()
reaper.ShowConsoleMsg(SCRIPT_NAME .. "\nChecking " .. #wavs .. " WAV file(s)...\n")
local reference = load_reference(directory)
local entries, profile_counts, click_sample_counts = {}, {}, {}
local left_values, right_values = {}, {}
for index, filename in ipairs(wavs) do
  reaper.ShowConsoleMsg(string.format("[%d/%d] %s\n", index, #wavs, filename))
  local path = common.join_path(directory, filename)
  local audit_path = path:gsub("%.[Ww][Aa][Vv]$", "") .. "_AUDIT.txt"
  local audit = common.read_audit(audit_path)
  local entry = {filename = filename, path = path, audit = audit, errors = {}, warnings = {}}
  if not audit then
    entry.errors[#entry.errors + 1] = "missing audit file"
  else
    if not audit.profile_id then entry.errors[#entry.errors + 1] = "audit has no profile ID"
    else profile_counts[audit.profile_id] = (profile_counts[audit.profile_id] or 0) + 1 end
    if not audit.status or audit.status:upper():find("FAIL", 1, true) then entry.errors[#entry.errors + 1] = "audit status is " .. tostring(audit.status or "missing") end
    if audit.status and audit.status:upper():find("WARNING", 1, true) then entry.warnings[#entry.warnings + 1] = "source audit contains warnings" end
    if audit.completion_policy and audit.completion_policy:upper():find("FALLBACK", 1, true) then
      entry.warnings[#entry.warnings + 1] = "builder used its safe-audible quality fallback: " .. audit.completion_policy
    elseif audit.completion_policy and audit.completion_policy:upper():find("EMERGENCY", 1, true) then
      entry.warnings[#entry.warnings + 1] = "builder used its bounded emergency tolerance: " .. audit.completion_policy
    end
    if not audit.checksum then
      entry.errors[#entry.errors + 1] = "audit has no SHA-256"
    else
      local checksum, checksum_error = common.sha256_file(path)
      entry.actual_checksum = checksum
      if not checksum then entry.errors[#entry.errors + 1] = "checksum failed: " .. tostring(checksum_error)
      elseif checksum:lower() ~= audit.checksum:lower() then entry.errors[#entry.errors + 1] = "WAV checksum does not match its approved audit" end
    end
    if not audit.padding_verified then entry.errors[#entry.errors + 1] = "2.5/30-second digital-silence padding is not verified" end
    if not audit.leading_silence or math.abs(audit.leading_silence - 2.5) > 0.001 then
      entry.errors[#entry.errors + 1] = "leading digital silence is not exactly 2.5 seconds"
    end
    if not audit.trailing_silence or math.abs(audit.trailing_silence - 30) > 0.001 then
      entry.errors[#entry.errors + 1] = "trailing digital silence is not exactly 30 seconds"
    end
    if audit.click_ratio and not audit.click_sample_id then
      entry.errors[#entry.errors + 1] = "CLICK is present but the audit has no replacement-sample ID"
    elseif audit.click_sample_id then
      local pair_id = audit.click_sample_id .. "/" .. (audit.click_sample_b_id or "LEGACY")
      click_sample_counts[pair_id] = (click_sample_counts[pair_id] or 0) + 1
    end
    if audit.left_lufs then left_values[#left_values + 1] = audit.left_lufs end
    if audit.right_lufs then right_values[#right_values + 1] = audit.right_lufs end
    if audit.left_true_peak and audit.iem_ceiling and audit.left_true_peak > audit.iem_ceiling + 0.10 then
      entry.errors[#entry.errors + 1] = string.format("left true peak %.2f dBTP exceeds its %.2f dBFS ceiling", audit.left_true_peak, audit.iem_ceiling)
    end
    if audit.right_true_peak and audit.foh_ceiling and audit.right_true_peak > audit.foh_ceiling + 0.10 then
      entry.errors[#entry.errors + 1] = string.format("right true peak %.2f dBTP exceeds its %.2f dBFS ceiling", audit.right_true_peak, audit.foh_ceiling)
    end
    if audit.left_range and audit.left_range > 5.0 then
      entry.warnings[#entry.warnings + 1] = string.format(
        "left short-term range %.2f LU is above the preferred 5.00 LU set target; the builder's passed safety decision is retained",
        audit.left_range)
    end
    if audit.right_range and audit.right_range > 5.0 then
      entry.warnings[#entry.warnings + 1] = string.format(
        "right short-term range %.2f LU is above the preferred 5.00 LU set target; the builder's passed safety decision is retained",
        audit.right_range)
    end
    if audit.hardware_safe_ceiling and audit.iem_ceiling and audit.iem_ceiling > audit.hardware_safe_ceiling + 0.01 then
      entry.errors[#entry.errors + 1] = "IEM profile ceiling exceeds the stored hardware-safe ceiling"
    end
    if audit.emergency_mode then entry.warnings[#entry.warnings + 1] = "bounded emergency stabilization was used" end
  end
  entries[#entries + 1] = entry
end

local expected_profile, expected_count
for profile, count in pairs(profile_counts) do
  if not expected_count or count > expected_count then expected_profile, expected_count = profile, count end
end
if reference and reference.profile_id and reference.profile_id ~= "UNKNOWN" then expected_profile = reference.profile_id end
local expected_click_sample, expected_click_count
for sample_id, count in pairs(click_sample_counts) do
  if not expected_click_count or count > expected_click_count then expected_click_sample, expected_click_count = sample_id, count end
end
local left_median, right_median = common.median(left_values), common.median(right_values)

local spectral_keys = {"left_low","left_mid","left_high","right_low","right_mid","right_high"}
local spectral_medians = {}
if not reference then
  for _, key in ipairs(spectral_keys) do
    local values = {}
    for _, entry in ipairs(entries) do if entry.audit and entry.audit[key] then values[#values + 1] = entry.audit[key] end end
    spectral_medians[key] = common.median(values)
  end
end

for _, entry in ipairs(entries) do
  local audit = entry.audit
  if audit then
    if expected_profile and audit.profile_id ~= expected_profile then
      entry.errors[#entry.errors + 1] = string.format("profile %s differs from expected %s", tostring(audit.profile_id), expected_profile)
    end
    local pair_id = audit.click_sample_id and (audit.click_sample_id .. "/" .. (audit.click_sample_b_id or "LEGACY"))
    if pair_id and expected_click_sample and pair_id ~= expected_click_sample then
      entry.errors[#entry.errors + 1] = string.format("metronome click sample pair %s differs from expected %s", pair_id, expected_click_sample)
    end
    if audit.left_lufs and left_median and math.abs(audit.left_lufs - left_median) > 1.0 then
      entry.warnings[#entry.warnings + 1] = string.format(
        "left loudness %.2f LUFS is %+.2f LU from show median", audit.left_lufs, audit.left_lufs - left_median)
    end
    if audit.right_lufs and right_median and math.abs(audit.right_lufs - right_median) > 1.0 then
      entry.warnings[#entry.warnings + 1] = string.format(
        "right loudness %.2f LUFS is %+.2f LU from show median", audit.right_lufs, audit.right_lufs - right_median)
    end
    for _, key in ipairs(spectral_keys) do
      if not (key:find("right", 1, true) and not audit.right_lufs) then
        local target = reference and reference[key] or spectral_medians[key]
        local delta = difference_db(audit[key], target)
        if delta and math.abs(delta) > 6 then
          entry.warnings[#entry.warnings + 1] = string.format("%s spectral share is %+.1f dB from %s", key:gsub("_", " "), delta, reference and "reference" or "show median")
        end
      end
    end
  end
end

local failed, warned = 0, 0
for _, entry in ipairs(entries) do
  if #entry.errors > 0 then failed = failed + 1 elseif #entry.warnings > 0 then warned = warned + 1 end
end
local lines = {
  "BILDIBEAT SHOW SET VALIDATION v3.9",
  "==================================",
  "Folder: " .. directory,
  "Created: " .. os.date("%Y-%m-%d %H:%M:%S"),
  "Status: " .. (failed == 0 and "PASS" or "FAIL"),
  string.format("Show tracks: %d | failed: %d | warnings only: %d | unrelated/diagnostic WAVs ignored: %d",
    #entries, failed, warned, #ignored_wavs),
  "Expected profile: " .. tostring(expected_profile or "UNKNOWN"),
  "Expected click sample: " .. tostring(expected_click_sample or "none in files containing CLICK"),
  "Reference: " .. (reference and (reference.id or "configured") or "none; spectral comparisons use show medians"),
  left_median and string.format("Show median left: %.2f LUFS", left_median) or "Show median left: unavailable",
  right_median and string.format("Show median right: %.2f LUFS", right_median) or "Show median right: no FOH files",
  "",
}
for _, entry in ipairs(entries) do
  local status = #entry.errors > 0 and "FAIL" or (#entry.warnings > 0 and "WARN" or "PASS")
  lines[#lines + 1] = string.format("[%s] %s | profile %s | L %s LUFS | R %s",
    status, entry.filename, entry.audit and tostring(entry.audit.profile_id) or "NO AUDIT",
    entry.audit and tostring(entry.audit.left_lufs or "n/a") or "n/a",
    entry.audit and (entry.audit.right_lufs and (tostring(entry.audit.right_lufs) .. " LUFS") or "silence") or "n/a")
  for _, value in ipairs(entry.errors) do lines[#lines + 1] = "  ERROR: " .. value end
  for _, value in ipairs(entry.warnings) do lines[#lines + 1] = "  WARNING: " .. value end
end
local report_path = common.join_path(directory, "BILDIBEAT_SHOW_SET_REPORT.txt")
local ok, write_error = common.write_text(report_path, table.concat(lines, "\n"))
if not ok then
  reaper.ShowMessageBox("Validation completed but the report could not be written:\n\n" .. tostring(write_error), SCRIPT_NAME, 0)
  return
end
reaper.SetExtState(section, "validator_test_result", (failed == 0 and "PASS|" or "FAIL|") .. report_path, false)
if test_path == "" then
  reaper.ShowMessageBox(string.format("Show-set validation %s.\n\n%d WAV(s), %d failure(s), %d warning-only.\n\nReport:\n%s",
    failed == 0 and "PASSED" or "FAILED", #entries, failed, warned, report_path), SCRIPT_NAME, 0)
end

end

local function run_loopback_analyzer()
-- Analyze a stereo recording of the generated breakout calibration WAV.
local SCRIPT_NAME = "Bildibeat Show Track App v3.9 - Breakout Loopback"
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local script_directory = source_path:match("^(.*[\\/])") or ""
-- Shared utilities are embedded by the unified app.
local section = "Bildibeat_Show_Track_Builder"

local test_path = reaper.GetExtState(section, "loopback_test_path")
local test_target = tonumber(reaper.GetExtState(section, "loopback_test_target"))
if test_path ~= "" then
  reaper.DeleteExtState(section, "loopback_test_path", true)
  reaper.DeleteExtState(section, "loopback_test_target", true)
end
local selected = test_path
if selected == "" then
  local ok
  ok, selected = reaper.GetUserFileName(0, "Choose the recorded breakout-loopback WAV", "", "WAV audio|*.wav")
  if not ok then return end
end
local leak_target = test_target
if not leak_target then
  local ok, value = reaper.GetUserInputs(SCRIPT_NAME, 1, "Maximum acceptable leaked click at FOH dBFS", "-60")
  if not ok then return end
  leak_target = tonumber(common.trim(value))
  if not leak_target or leak_target < -100 or leak_target > -30 then
    reaper.ShowMessageBox("Enter a leakage target between -100 and -30 dBFS.", SCRIPT_NAME, 0)
    return
  end
end

local profile = reaper.GetExtState(section, "show_profile_v13")
local iem_ceiling = tonumber(profile:match("^([^,]+)")) or -18
local project = reaper.EnumProjects(-1, "")
local windows = {
  {name = "left tone", start_time = 1.20, end_time = 3.80},
  {name = "right tone", start_time = 5.20, end_time = 7.80},
}
reaper.PreventUIRefresh(1)
local analysis, analysis_error = common.analyze_stereo_file(project, selected, windows)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
if not analysis then
  reaper.ShowMessageBox("Loopback analysis failed:\n\n" .. tostring(analysis_error), SCRIPT_NAME, 0)
  return
end
if analysis.length < 8 then
  reaper.ShowMessageBox("The recording is shorter than 8 seconds. Record the complete generated calibration WAV without trimming it.", SCRIPT_NAME, 0)
  return
end
local left_window, right_window = analysis.windows[1], analysis.windows[2]
if left_window.left_db < -70 or right_window.right_db < -70 then
  reaper.ShowMessageBox("The expected calibration tones were not detected on the correct channels. Check recording alignment and channel assignment.", SCRIPT_NAME, 0)
  return
end

local left_leak_silent = left_window.right_rms <= 1e-12
local right_leak_silent = right_window.left_rms <= 1e-12
local left_to_right = left_leak_silent and -180 or (left_window.right_db - left_window.left_db)
local right_to_left = right_leak_silent and -180 or (right_window.left_db - right_window.right_db)
local projected_foh_leak = iem_ceiling + left_to_right
local maximum_iem_ceiling
if not left_leak_silent then
  maximum_iem_ceiling = leak_target - left_to_right
end
local pass = projected_foh_leak <= leak_target
-- Preserve 0.5 dB of margin beyond the measured threshold.  The main builder
-- reads this persistent value and can only lower (never raise) its configured
-- IEM ceiling.  A digitally silent leak path keeps the current ceiling.
local safe_iem_ceiling = left_leak_silent and iem_ceiling
  or math.min(iem_ceiling, maximum_iem_ceiling - 0.5)
local function grade(value)
  if value <= -60 then return "excellent" end
  if value <= -50 then return "good" end
  if value <= -40 then return "caution" end
  return "poor"
end
local checksum = common.sha256_file(selected)
local lines = {
  "BILDIBEAT BREAKOUT LOOPBACK REPORT v3.9",
  "=======================================",
  "Recording: " .. selected,
  "Created: " .. os.date("%Y-%m-%d %H:%M:%S"),
  "Status: " .. (pass and "PASS" or "FAIL"),
  "Recording SHA-256: " .. tostring(checksum or "UNAVAILABLE"),
  "",
  left_leak_silent and "Left -> right crosstalk: below digital measurement floor (excellent)" or string.format("Left -> right crosstalk: %.2f dB (%s)", left_to_right, grade(left_to_right)),
  right_leak_silent and "Right -> left crosstalk: below digital measurement floor (excellent)" or string.format("Right -> left crosstalk: %.2f dB (%s)", right_to_left, grade(right_to_left)),
  string.format("Locked/current IEM ceiling: %.2f dBFS", iem_ceiling),
  left_leak_silent and "Projected click leakage at FOH: below digital measurement floor" or string.format("Projected click leakage at FOH: %.2f dBFS", projected_foh_leak),
  string.format("Selected maximum acceptable FOH leakage: %.2f dBFS", leak_target),
  maximum_iem_ceiling and string.format("Maximum calculated IEM ceiling for that leakage target: %.2f dBFS", maximum_iem_ceiling)
    or "Maximum calculated IEM ceiling: not constrained by measurable digital crosstalk",
  string.format("Builder hardware-safe IEM ceiling (includes 0.5 dB margin): %.2f dBFS", safe_iem_ceiling),
  "",
  "This measures the complete recorded playback path. Repeat the test after changing the iPad, adapter, breakout cable, DI, interface gain, or playback application.",
  "Listening safety still requires setting downstream IEM gain at a safe level.",
}
local report_path = selected:gsub("%.[Ww][Aa][Vv]$", "") .. "_LOOPBACK_REPORT.txt"
local ok, write_error = common.write_text(report_path, table.concat(lines, "\n"))
if not ok then
  reaper.ShowMessageBox("Could not write the loopback report:\n\n" .. tostring(write_error), SCRIPT_NAME, 0)
  return
end
reaper.SetExtState(section, "loopback_test_result", (pass and "PASS|" or "FAIL|") .. report_path, false)
reaper.SetExtState(section, "hardware_safe_iem_ceiling_v3", string.format("%.6f", safe_iem_ceiling), true)
reaper.SetExtState(section, "hardware_safe_report_v3", report_path, true)
if test_path == "" then
  local left_summary = left_leak_silent and "below measurement floor" or string.format("%.2f dB", left_to_right)
  local leak_summary = left_leak_silent and "below measurement floor" or string.format("%.2f dBFS", projected_foh_leak)
  reaper.ShowMessageBox(string.format("Loopback test %s.\n\nLeft -> right: %s\nProjected FOH click leakage: %s\n\nReport:\n%s",
    pass and "PASSED" or "FAILED", left_summary, leak_summary, report_path), SCRIPT_NAME, 0)
end

end

local APP_NAME = "Bildibeat Show Track App v4.2"
local APP_SECTION = "Bildibeat_Show_Track_Builder"

local actions = {
  {id = "build", label = "Build Show Track", detail = "Optional mono preview and optional CLICK +/-3 dB companion renders.", run = run_builder},
  {id = "recover", label = "Repair Last Failed WAV", detail = "Check a failed render and apply verified fixed channel gain without rerendering.", run = function() run_builder(true) end},
  {id = "resume", label = "Recover Interrupted Render", detail = "Verify a complete local WAV from a prior crash; no new song render.", run = function() run_builder("resume") end},
  {id = "set_click", label = "Manage ALT Click Sample", detail = "Normal A/B come from REAPER metronome; choose one ALT sample here.", run = run_click_setter},
  {id = "reference", label = "Set Approved Reference", detail = "Approve a known-good rendered show track for comparison.", run = run_reference_manager},
  {id = "validate", label = "Validate Complete Show Folder", detail = "Check checksums, profiles, sample IDs, padding, and song consistency.", run = run_show_set_validator},
  {id = "loopback", label = "Analyze Breakout Loopback", detail = "Measure physical left/right crosstalk from a recorded calibration pass.", run = run_loopback_analyzer},
}

local function dispatch(action_id)
  for _, action in ipairs(actions) do
    if action.id == action_id then action.run(); return true end
  end
  return false
end

local test_action = reaper.GetExtState(APP_SECTION, "app_test_action")
if test_action ~= "" then
  reaper.DeleteExtState(APP_SECTION, "app_test_action", true)
  if not dispatch(test_action) then error("Unknown app test action: " .. test_action) end
  return
end

local width, height = 650, 550
local button_x, button_width, button_height, button_gap = 28, 544, 56, 8
local first_button_y = 92
local previous_mouse_down = false

local function update_layout()
  local window_width = math.max(gfx.w or width, 460)
  local window_height = math.max(gfx.h or height, 390)
  button_x = math.max(18, math.floor(window_width * 0.045))
  button_width = window_width - button_x * 2
  first_button_y = math.max(82, math.floor(window_height * 0.19))
  button_gap = math.max(5, math.floor(window_height * 0.014))
  button_height = math.floor((window_height - first_button_y - 48 - button_gap * (#actions - 1)) / #actions)
  button_height = math.max(46, math.min(62, button_height))
end

local function shorten_path(path, maximum)
  path = tostring(path or "")
  if path == "" then return "not set (Build asks only if an ALT range is used)" end
  if #path <= maximum then return path end
  return "..." .. path:sub(-(maximum - 3))
end

local function draw_button(index, action, hovered)
  local y = first_button_y + (index - 1) * (button_height + button_gap)
  if hovered then gfx.set(0.18, 0.46, 0.72, 1) else gfx.set(0.12, 0.25, 0.38, 1) end
  gfx.rect(button_x, y, button_width, button_height, true)
  gfx.set(0.95, 0.97, 1, 1)
  gfx.setfont(2, "Arial", 19, 98)
  gfx.x, gfx.y = button_x + 18, y + 9
  gfx.drawstr(action.label)
  gfx.set(0.76, 0.82, 0.88, 1)
  gfx.setfont(3, "Arial", 13)
  gfx.x, gfx.y = button_x + 18, y + 35
  gfx.drawstr(action.detail)
end

local function draw()
  update_layout()
  local window_width, window_height = gfx.w or width, gfx.h or height
  gfx.set(0.035, 0.055, 0.078, 1)
  gfx.rect(0, 0, window_width, window_height, true)
  gfx.set(0.96, 0.98, 1, 1)
  gfx.setfont(1, "Arial", 27, 98)
  gfx.x, gfx.y = button_x, 18
  gfx.drawstr("Bildibeat Show Track App")
  gfx.set(0.55, 0.72, 0.89, 1)
  gfx.setfont(3, "Arial", 14)
  gfx.x, gfx.y = button_x + 2, 55
  gfx.drawstr("One app for building, metronome A/B clicks, ALT sections, validation, and hardware tests")

  for index, action in ipairs(actions) do
    local y = first_button_y + (index - 1) * (button_height + button_gap)
    local hovered = gfx.mouse_x >= button_x and gfx.mouse_x <= button_x + button_width
      and gfx.mouse_y >= y and gfx.mouse_y <= y + button_height
    draw_button(index, action, hovered)
  end

  local sample = reaper.GetExtState(APP_SECTION, "click_alt_sample_path_v42")
  gfx.set(0.60, 0.68, 0.75, 1)
  gfx.setfont(3, "Arial", 12)
  gfx.x, gfx.y = button_x, math.max(0, window_height - 25)
  gfx.drawstr(string.format("Normal: project metronome A/B | ALT: %s", shorten_path(sample, 65)))
  gfx.update()
end

local function loop()
  local character = gfx.getchar()
  if character < 0 or character == 27 then gfx.quit(); return end
  update_layout()
  local mouse_down = (gfx.mouse_cap & 1) == 1
  if mouse_down and not previous_mouse_down then
    for index, action in ipairs(actions) do
      local y = first_button_y + (index - 1) * (button_height + button_gap)
      if gfx.mouse_x >= button_x and gfx.mouse_x <= button_x + button_width
          and gfx.mouse_y >= y and gfx.mouse_y <= y + button_height then
        gfx.quit()
        reaper.defer(action.run)
        return
      end
    end
  end
  previous_mouse_down = mouse_down
  draw()
  reaper.defer(loop)
end

gfx.init(APP_NAME, width, height, 0)
draw()
loop()