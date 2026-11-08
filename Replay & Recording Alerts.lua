local obs = obslua
local ffi = require("ffi")
local IS_WINDOWS = ffi.os == "Windows"

local DEFAULT_SOUND = script_path() .. "sound_npc_scanner_scanner_photo1.wav"
-- Audio types only: the player sits on an output channel, so a video file would be drawn over the program.
local AUDIO_FILTER = "Audio files (*.wav *.mp3 *.ogg *.flac *.m4a *.opus)"
-- The bundled sound is at full level; 5% (about -26 dB) is a comfortable default.
local DEFAULT_VOLUME = 5
-- OBS itself uses output channels 0-6; a high one keeps the beep source active (needed for playback) without clashing.
local OUTPUT_CHANNEL = 63

-- "sound_file" is kept as the replay-saved key so settings from older versions carry over.
-- title = section header in the settings, label = toast text.
local EVENTS = {
  { key = "sound_file",           title = "Replay Buffer Save",  label = "Replay buffer saved",   id = obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED, enabled = true,
    last_file = "obs_frontend_get_last_replay" },
  { key = "sound_replay_started", title = "Replay Buffer Start", label = "Replay buffer started", id = obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED },
  { key = "sound_replay_stopped", title = "Replay Buffer Stop",  label = "Replay buffer stopped", id = obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED },
  { key = "sound_rec_started",    title = "Recording Start",     label = "Recording started",     id = obs.OBS_FRONTEND_EVENT_RECORDING_STARTED },
  { key = "sound_rec_stopped",    title = "Recording Stop",      label = "Recording stopped",     id = obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED,
    last_file = "obs_frontend_get_last_recording" },
  { key = "sound_stream_started", title = "Streaming Start",     label = "Streaming started",     id = obs.OBS_FRONTEND_EVENT_STREAMING_STARTED },
  { key = "sound_stream_stopped", title = "Streaming Stop",      label = "Streaming stopped",     id = obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED },
  { key = "sound_screenshot",     title = "Screenshot Save",     label = "Screenshot saved",      id = obs.OBS_FRONTEND_EVENT_SCREENSHOT_TAKEN, -- nil before OBS 29.1, then never fires
    last_file = "obs_frontend_get_last_screenshot" },
}

local paths = {}       -- event key -> chosen file ("" = no sound)
local toasts = {}      -- event key -> show a toast
local enabled = {}     -- event key -> event is switched on
local volumes = {}     -- event key -> volume in %
local sounds = {}      -- event key -> play the sound (off = toast only)
local tracks = {}      -- event key -> audio tracks to record the sound to (bit mask, 0 = none)
local beep_source = nil
local loaded_file = nil

local function play(path, volume, mixers)
  if beep_source == nil or path == nil or path == "" then return end
  obs.obs_source_set_volume(beep_source, volume / 100)
  -- No tracks = monitoring only: OBS's monitor plays the raw audio regardless of tracks.
  obs.obs_source_set_audio_mixers(beep_source, mixers)
  if path == loaded_file then
    obs.obs_source_media_restart(beep_source)
  else
    -- Changing the file on an active media source starts playing it immediately.
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "local_file", path)
    obs.obs_source_update(beep_source, s)
    obs.obs_data_release(s)
    loaded_file = path
  end
end

-- Windows toast via a hidden PowerShell. Toasts need a registered app ID: OBS's Start menu shortcut provides one,
-- and PowerShell's own is the fallback (portable OBS, no shortcut). The lookup costs ~350 ms per toast.
local POWERSHELL_APP_ID = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"
local shell32
if IS_WINDOWS then
  ffi.cdef[[
    int MultiByteToWideChar(unsigned int cp, unsigned long flags, const char *s, int n, wchar_t *w, int wn);
    void *ShellExecuteW(void *hwnd, const wchar_t *op, const wchar_t *file, const wchar_t *params, const wchar_t *dir, int show);
  ]]
  shell32 = ffi.load("shell32")
end

local function wide(s)
  local n = ffi.C.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
  local w = ffi.new("wchar_t[?]", n)
  ffi.C.MultiByteToWideChar(65001, 0, s, -1, w, n)
  return w
end

-- For a PowerShell '...' literal: double every kind of single quote PowerShell accepts; drop " so the command line stays intact.
local function ps_quote(s)
  for _, q in ipairs({ "'", "\226\128\152", "\226\128\153", "\226\128\154", "\226\128\155" }) do
    s = s:gsub(q, "''")
  end
  return "'" .. s:gsub('"', "") .. "'"
end
assert(ps_quote("it's") == "'it''s'")
assert(ps_quote('a"b\226\128\153c') == "'ab''c'")

-- For a POSIX shell '...' literal and an AppleScript "..." literal.
local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function as_quote(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end
assert(sh_quote("it's") == [['it'\''s']])
assert(as_quote([[a"b\c]]) == [["a\"b\\c"]])

-- Toasts run in a separate process, so their errors go to this file. Each toast moves it into OBS's log 5 s later;
-- an error written after that is picked up by the next toast or at load.
-- shortcut: Lua's io.open can't open non-ASCII paths on Windows, so errors are lost there; use a wide-char open if that bites.
local TOAST_ERRORS = script_path() .. "toast-errors.txt"
local function report_toast_errors()
  local f = io.open(TOAST_ERRORS, "r")
  if not f then return end
  local text = f:read("*a"):gsub("^\239\187\191", "") -- Windows PowerShell writes a UTF-8 BOM
  f:close()
  os.remove(TOAST_ERRORS)
  if text ~= "" then print("A previous toast failed:\n" .. text) end
end

local function toast(e)
  local getter = e.last_file and obs[e.last_file]
  local file = getter and getter() or ""
  file = file:match("[^/\\]+$") or ""
  -- Pick up this toast's errors soon, so a log uploaded right after reproducing a problem contains them.
  obs.timer_add(function() obs.remove_current_callback(); report_toast_errors() end, 5000)

  -- Trailing & so OBS doesn't wait for the notifier.
  if ffi.os == "OSX" then
    -- Shows as coming from Script Editor, which macOS must be allowed to notify for.
    os.execute("osascript -e " .. sh_quote("display notification " .. as_quote(file)
      .. ' with title "OBS Studio" subtitle ' .. as_quote(e.label)) .. " >/dev/null 2>>" .. sh_quote(TOAST_ERRORS) .. " &")
    return
  elseif not IS_WINDOWS then
    -- shortcut: needs notify-send (libnotify), which the Flatpak OBS lacks; switch to gdbus if Flatpak users ask.
    os.execute("notify-send -a 'OBS Studio' -i com.obsproject.Studio -h boolean:suppress-sound:true -- "
      .. sh_quote(e.label) .. " " .. sh_quote(file) .. " >/dev/null 2>>" .. sh_quote(TOAST_ERRORS) .. " &")
    return
  end

  local N = "[Windows.UI.Notifications.ToastNotificationManager]"
  local script = table.concat({
    "$ErrorActionPreference='Stop'",
    "$h=" .. ps_quote(e.label),
    "$id=(Get-StartApps|?{$_.AppID -like '*\\obs64.exe'}|select -First 1).AppID",
    -- Under PowerShell's ID the header says "Windows PowerShell", so name OBS in the title instead.
    "if(!$id){$id='" .. POWERSHELL_APP_ID .. "';$h='OBS Studio: '+$h}",
    "[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]>$null",
    "$t=" .. N .. "::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)",
    "$x=$t.GetElementsByTagName('text')",
    "$x.Item(0).AppendChild($t.CreateTextNode($h))>$null",
    "$x.Item(1).AppendChild($t.CreateTextNode(" .. ps_quote(file) .. "))>$null",
    -- The script plays its own sound, so mute Windows' notification sound.
    "$a=$t.CreateElement('audio');$a.SetAttribute('silent','true');$t.SelectSingleNode('/toast').AppendChild($a)>$null",
    "$n=[Windows.UI.Notifications.ToastNotification]::new($t)",
    -- Dismiss the previous toast first so this one shows at once instead of queuing behind it.
    -- (Just reusing the tag sometimes swaps it silently, with no banner.)
    "$n.Tag='alert';$n.Group='replay-recording-alerts'",
    -- Give the old banner a moment to leave; showing right away sometimes drops the new one.
    "if(" .. N .. "::History.GetHistory($id)|?{$_.Tag -eq 'alert'}){"
      .. N .. "::History.Remove('alert','replay-recording-alerts',$id);Start-Sleep -m 150}",
    N .. "::CreateToastNotifier($id).Show($n)",
  }, ";")
  script = "try{" .. script .. "}catch{$_|Out-File -Append -Encoding utf8 -LiteralPath " .. ps_quote(TOAST_ERRORS) .. "}"
  local r = tonumber(ffi.cast("intptr_t", shell32.ShellExecuteW(nil, wide("open"), wide("powershell.exe"),
    wide('-NoProfile -NonInteractive -WindowStyle Hidden -Command "' .. script .. '"'), nil, 0))) -- 0 = SW_HIDE
  if r <= 32 then print("Toast failed: PowerShell didn't start (ShellExecute error " .. r .. ")") end
end

-- Desktop Audio records whatever plays on its device, so monitoring on that same device puts the sounds back into recordings.
-- Recent OBS detects this itself (resolving "Default" too) and signals each change; nil on older OBS.
local dedup = nil
local function on_dedup(cd)
  dedup = obs.calldata_source(cd, "source") ~= nil
  print("Desktop Audio captures the Monitoring Device: " .. (dedup and "yes" or "no"))
end

-- OBS only signals on changes, so after a mid-session (re)load ask it to check the current state.
-- Re-running OBS's own check is harmless: it is what OBS does on every device change.
local function recheck_dedup()
  if not (obs.obs_source_audio_output_capture_device_changed and obs.OBS_SOURCE_DO_NOT_SELF_MONITOR) then return end
  dedup = false
  local sources = obs.obs_enum_sources()
  for _, src in ipairs(sources or {}) do
    if bit.band(obs.obs_source_get_output_flags(src), obs.OBS_SOURCE_DO_NOT_SELF_MONITOR) ~= 0 then
      local s = obs.obs_source_get_settings(src)
      obs.obs_source_audio_output_capture_device_changed(src, obs.obs_data_get_string(s, "device_id"))
      obs.obs_data_release(s)
    end
  end
  obs.source_list_release(sources)
end

-- shortcut: on OBS without its own detection, compares IDs only, so "Default" vs. the same device picked by name is missed.
local function monitor_is_recorded()
  if dedup ~= nil then return dedup end
  if not IS_WINDOWS then return false end -- the fallback only knows WASAPI capture
  local monitor = obs.config_get_string(obs.obs_frontend_get_profile_config(), "Audio", "MonitoringDeviceId") or "default"
  local hit = false
  local sources = obs.obs_enum_sources()
  for _, src in ipairs(sources or {}) do
    if obs.obs_source_get_unversioned_id(src) == "wasapi_output_capture" and obs.obs_source_enabled(src) then
      local s = obs.obs_source_get_settings(src)
      if (obs.obs_data_get_string(s, "device_id") or "default") == monitor then hit = true end
      obs.obs_data_release(s)
    end
  end
  obs.source_list_release(sources)
  return hit
end

-- Line breaks are manual: OBS sizes word-wrapped info text for a narrow column, leaving empty space around it.
local RECORDED_WARNING = "<b>⚠ Alert sounds will be recorded.</b><br>"
  .. "Desktop Audio captures your Monitoring Device, so it records them too.<br>"
  .. "To fix: Settings → Audio → Advanced → pick another Monitoring Device,<br>"
  .. "then reload this script. Be aware that alerts will then play on that<br>"
  .. "device instead of your main one (e.g. speakers instead of headphones)."

-- OBS gives scripts no way to redraw their settings, so the warning is re-checked whenever the user touches a setting.
local warning_prop = nil
local recorded = false
local function refresh_warning()
  recorded = monitor_is_recorded()
  obs.obs_property_set_visible(warning_prop, recorded)
end

local TRACKS_HINT = "Record this sound to an audio track, even if the Monitoring Device is different.\n"
  .. "Most video players only play track 1, so another track keeps a separate copy you can mix in later."

local function fire(e)
  -- Desktop Audio already records the sound then, so the track choice is hidden and ignored.
  local by_desktop = monitor_is_recorded()
  local mixers = by_desktop and 0 or tracks[e.key]
  print(("%s: sound=%s volume=%d%% tracks=0x%X recorded_by_desktop_audio=%s toast=%s"):format(e.title,
    sounds[e.key] and (paths[e.key] ~= "" and paths[e.key] or "none") or "off",
    volumes[e.key], mixers, tostring(by_desktop), tostring(toasts[e.key])))
  if sounds[e.key] then play(paths[e.key], volumes[e.key], mixers) end
  if toasts[e.key] then toast(e) end
end

function script_description()
  return [[<h2>Replay &amp; Recording Alerts</h2>
<p>Plays a sound or shows a toast on OBS events.</p>
<p>Sounds play on the <b>Monitoring Device</b> (Settings → Audio → Advanced).</p>]]
end

function script_properties()
  local props = obs.obs_properties_create()
  warning_prop = obs.obs_properties_add_text(props, "recorded_warning", RECORDED_WARNING, obs.OBS_TEXT_INFO)
  obs.obs_property_text_set_info_type(warning_prop, obs.OBS_TEXT_INFO_WARNING)
  obs.obs_property_text_set_info_word_wrap(warning_prop, false)
  refresh_warning()

  -- One framed section per event; its settings show only while Enabled is ticked,
  -- and the sound file and volume only while Play sound is ticked too.
  for _, e in ipairs(EVENTS) do
    if e.id ~= nil then
      local box = obs.obs_properties_create()
      local toggle = obs.obs_properties_add_bool(box, e.key .. "_enabled", "Enabled")
      local sound_toggle = obs.obs_properties_add_bool(box, e.key .. "_sound", "Play sound")
      local sound_props = {
        obs.obs_properties_add_path(box, e.key, "Sound", obs.OBS_PATH_FILE, AUDIO_FILTER, script_path()),
        obs.obs_properties_add_int_slider(box, e.key .. "_volume", "Volume (%)", 0, 100, 1),
      }
      local other_props = { sound_toggle }
      table.insert(other_props, obs.obs_properties_add_bool(box, e.key .. "_toast", "Show toast notification"))
      local rec
      local function set_shown(on, sound_on)
        for _, p in ipairs(other_props) do obs.obs_property_set_visible(p, on) end
        for _, p in ipairs(sound_props) do obs.obs_property_set_visible(p, on and sound_on) end
        obs.obs_property_set_visible(rec, on and sound_on and not recorded)
      end
      rec = obs.obs_properties_add_list(box, e.key .. "_tracks", "Record to", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
      obs.obs_property_list_add_int(rec, "Not recorded", 0)
      for t = 1, 6 do obs.obs_property_list_add_int(rec, "Track " .. t, bit.lshift(1, t - 1)) end
      obs.obs_property_list_add_int(rec, "All tracks", 0x3F)
      obs.obs_property_set_long_description(rec, TRACKS_HINT)
      table.insert(other_props, obs.obs_properties_add_button(box, e.key .. "_test", "Test", function()
        fire(e)
        refresh_warning()
        set_shown(enabled[e.key] == true, sounds[e.key] ~= false)
        return true
      end))
      local function on_toggle(_, _, settings)
        refresh_warning()
        set_shown(obs.obs_data_get_bool(settings, e.key .. "_enabled"), obs.obs_data_get_bool(settings, e.key .. "_sound"))
        return true
      end
      obs.obs_property_set_modified_callback(toggle, on_toggle)
      obs.obs_property_set_modified_callback(sound_toggle, on_toggle)
      -- The callbacks don't run when the script is refreshed, so set the starting state here too.
      set_shown(enabled[e.key] == true, sounds[e.key] ~= false)
      obs.obs_properties_add_group(props, e.key .. "_group", e.title, obs.OBS_GROUP_NORMAL, box)
    end
  end
  return props
end

function script_defaults(settings)
  for _, e in ipairs(EVENTS) do
    obs.obs_data_set_default_string(settings, e.key, DEFAULT_SOUND)
    obs.obs_data_set_default_int(settings, e.key .. "_volume", DEFAULT_VOLUME)
    obs.obs_data_set_default_bool(settings, e.key .. "_sound", true)
    obs.obs_data_set_default_bool(settings, e.key .. "_enabled", e.enabled == true)
  end
end

function script_update(settings)
  for _, e in ipairs(EVENTS) do
    paths[e.key] = obs.obs_data_get_string(settings, e.key)
    toasts[e.key] = obs.obs_data_get_bool(settings, e.key .. "_toast")
    enabled[e.key] = obs.obs_data_get_bool(settings, e.key .. "_enabled")
    volumes[e.key] = obs.obs_data_get_int(settings, e.key .. "_volume")
    sounds[e.key] = obs.obs_data_get_bool(settings, e.key .. "_sound")
    tracks[e.key] = obs.obs_data_get_int(settings, e.key .. "_tracks")
  end
end

function on_event(event)
  for _, e in ipairs(EVENTS) do
    if e.id ~= nil and event == e.id and enabled[e.key] then fire(e) end
  end
end

function script_load(settings)
  local s = obs.obs_data_create()
  obs.obs_data_set_bool(s, "is_local_file", true)
  obs.obs_data_set_bool(s, "looping", false)
  obs.obs_data_set_bool(s, "close_when_inactive", false)
  beep_source = obs.obs_source_create_private("ffmpeg_source", "Event beep", s)
  obs.obs_data_release(s)
  -- OBS 33 dropped "monitor only" (it now means monitor and output), so monitoring is always on and
  -- play() keeps the sounds out of recordings by clearing the source's audio tracks instead.
  if obs.obs_source_set_monitoring_enabled then
    obs.obs_source_set_monitoring_enabled(beep_source, true)
  else
    obs.obs_source_set_monitoring_type(beep_source, obs.OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT)
  end
  obs.obs_set_output_source(OUTPUT_CHANNEL, beep_source)

  obs.signal_handler_connect(obs.obs_get_signal_handler(), "deduplication_changed", on_dedup)
  recheck_dedup()
  obs.obs_frontend_add_event_callback(on_event)
  print(("Loaded on OBS %s (%s). Desktop Audio detection: %s. Recorded by Desktop Audio: %s."):format(
    obs.obs_get_version_string(), ffi.os, dedup ~= nil and "OBS" or (IS_WINDOWS and "device ID comparison" or "none"),
    tostring(monitor_is_recorded())))
  report_toast_errors()
end

function script_unload()
  obs.signal_handler_disconnect(obs.obs_get_signal_handler(), "deduplication_changed", on_dedup)
  if beep_source ~= nil then
    obs.obs_set_output_source(OUTPUT_CHANNEL, nil)
    obs.obs_source_release(beep_source)
    beep_source = nil
  end
end

-- Based on the "Beep on replay buffer save" script downloaded from https://gist.github.com/snakecase/e816384a071cec31efbb4b9e429c108d
