-- ============================================================
--  Voice setup — dictation + text-to-speech + Slack drafting
--    Option+Space (hold) = dictate, release to type
--    Option+Esc          = stop the TTS reading
--    Ctrl+Cmd+S          = draft a reply to the highlighted message
--    Ctrl+Cmd+R          = read the highlighted text aloud (macOS `say`)
--    Ctrl+Cmd+.          = stop reading
-- ============================================================

local HOME = os.getenv("HOME")

-- find sox `rec` wherever Homebrew installed it (arm64 vs Intel prefix)
local function firstExisting(paths)
  for _, p in ipairs(paths) do
    local f = io.open(p, "r")
    if f then f:close(); return p end
  end
  return paths[1]
end

-- ---- Settings you can tweak ----
local REC_BIN  = firstExisting({ "/opt/homebrew/bin/rec", "/usr/local/bin/rec" })
local CURL_BIN = "/usr/bin/curl"
local CLIP     = "/tmp/whisper_clip.wav"
local ENDPOINT = "http://127.0.0.1:8080/inference"
local DRAFT_REPLY = HOME .. "/.local/bin/draft-reply.sh"
local PR_REVIEW   = HOME .. "/.local/bin/pr-review.sh"
-- --------------------------------

local recording = false
local recTask   = nil
local recAlert  = nil

-- Send the recorded clip to the warm whisper-server, then type the result
local function transcribeAndType()
  local curlTask = hs.task.new(CURL_BIN, function(exitCode, stdout, stderr)
    if exitCode ~= 0 or not stdout then
      hs.alert.show("dictation: transcription failed")
      return
    end
    local text = stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text == "[BLANK_AUDIO]" then return end
    hs.eventtap.keyStrokes(text .. " ")
  end, { "-s", ENDPOINT, "-F", "file=@" .. CLIP, "-F", "response_format=text" })
  curlTask:start()
end

local function startRecording()
  if recording then return end
  recording = true
  -- silence any TTS so it doesn't bleed into the mic and garble the transcript
  hs.task.new(CURL_BIN, nil, { "-s", "--max-time", "2", "http://127.0.0.1:8123/stop" }):start()
  hs.task.new("/usr/bin/killall", nil, { "say" }):start()
  recAlert = hs.alert.show("🎤  Listening…  (release Option+Space to type)", 86400)
  recTask = hs.task.new(REC_BIN, function() transcribeAndType() end,
    { "-q", "-r", "16000", "-c", "1", "-b", "16", CLIP })
  recTask:start()
end

local function stopRecording()
  if not recording then return end
  recording = false
  if recAlert then hs.alert.closeSpecific(recAlert); recAlert = nil end
  hs.alert.show("✍️  transcribing…", 0.6)
  if recTask then recTask:terminate() end
end

-- Hotkey: Option+Space held = dictate
local KC_SPACE = 49
local et = hs.eventtap.event.types
ptt = hs.eventtap.new({ et.keyDown, et.keyUp, et.flagsChanged }, function(e)
  local typ = e:getType()
  local kc  = e:getKeyCode()
  if typ == et.keyDown then
    if kc == KC_SPACE and e:getFlags().alt then
      if not recording then startRecording() end
      return true
    end
    return false
  elseif typ == et.keyUp then
    if kc == KC_SPACE and recording then stopRecording(); return true end
    return false
  elseif typ == et.flagsChanged then
    if recording and not e:getFlags().alt then stopRecording() end
    return false
  end
  return false
end)
ptt:start()

-- Watchdog: re-enable the tap if macOS disables it (e.g. after a secure field)
pttWatch = hs.timer.doEvery(3, function()
  if ptt and not ptt:isEnabled() then ptt:start() end
end)

-- Option+Esc = stop the TTS reading
local function stopReading()
  hs.task.new(CURL_BIN, nil, { "-s", "--max-time", "2", "http://127.0.0.1:8123/stop" }):start()
  hs.task.new("/usr/bin/killall", nil, { "afplay" }):start()
  hs.task.new("/usr/bin/killall", nil, { "say" }):start()
  hs.alert.show("🔇 stopped reading", 0.4)
end
hs.hotkey.bind({ "alt" }, "escape", stopReading)

-- Ctrl+Cmd+S = draft a reply to the highlighted message (any app)
local function draftReply()
  local saved = hs.pasteboard.getContents()
  hs.pasteboard.clearContents()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.15, function()
    local q = hs.pasteboard.getContents()
    if saved then hs.pasteboard.setContents(saved) end
    if not q or q:gsub("%s", "") == "" then
      hs.alert.show("Highlight the message first, then ⌃⌘S"); return
    end
    hs.alert.show("✍️  drafting reply…  (I'll ping you when ready)", 2)
    local task = hs.task.new(DRAFT_REPLY, function(code, stdout, stderr)
      local reply = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if code == 0 and reply ~= "" then
        hs.pasteboard.setContents(reply)
        hs.notify.new({ title = "Reply ready",
                        informativeText = "Copied — ⌘V to paste.\n" .. reply:sub(1, 140),
                        soundName = "Glass" }):send()
        hs.alert.show("✅  reply on clipboard — ⌘V to paste", 2.5)
      else
        hs.alert.show("draft failed — see /tmp/draft-reply.log")
      end
    end, { q })
    task:start()
  end)
end
hs.hotkey.bind({ "ctrl", "cmd" }, "s", draftReply)

-- Ctrl+Cmd+P = review a GitHub PR. Copy the PR link, then press it. Claude
-- reviews the diff and leaves a PENDING review (inline comments) under your
-- work gh account; you submit it on GitHub.
local function reviewPR()
  local clip = hs.pasteboard.getContents()
  if not clip or not clip:match("https?://github%.com/[^/]+/[^/]+/pull/%d+") then
    hs.alert.show("Copy text containing a GitHub PR link, then ⌃⌘P"); return
  end
  hs.alert.show("🔍  reviewing PR(s)…  (pending review when done)", 2)
  local task = hs.task.new(PR_REVIEW, function(code, stdout, stderr)
    if code == 0 then
      hs.notify.new({ title = "PR review posted (pending — you submit)",
                      informativeText = (stdout or ""):sub(1, 180), soundName = "Glass" }):send()
      hs.alert.show("✅  pending review posted — open the PR to submit", 3)
    else
      hs.alert.show("PR review failed — see /tmp/pr-review.log")
    end
  end, { clip })
  task:start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "p", reviewPR)

-- Ctrl+Cmd+R = read highlighted text aloud (macOS `say`); Ctrl+Cmd+. = stop
local TTS_VOICE = nil
local sayTask   = nil
local function stopSpeaking()
  if sayTask then sayTask:terminate(); sayTask = nil end
  hs.task.new("/usr/bin/killall", nil, { "say" }):start()
  hs.task.new(CURL_BIN, nil, { "-s", "--max-time", "2", "http://127.0.0.1:8123/stop" }):start()
  hs.alert.show("🔇 stopped", 0.4)
end
local function speakSelection()
  if sayTask then stopSpeaking(); return end
  local saved = hs.pasteboard.getContents()
  hs.pasteboard.clearContents()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.12, function()
    local text = hs.pasteboard.getContents()
    if saved then hs.pasteboard.setContents(saved) end
    if not text or text:gsub("%s", "") == "" then hs.alert.show("nothing selected to read"); return end
    hs.alert.show("🔊 reading…  (⌃⌘R or ⌃⌘. to stop)", 1)
    local args = TTS_VOICE and { "-v", TTS_VOICE, text } or { text }
    sayTask = hs.task.new("/usr/bin/say", function() sayTask = nil end, args)
    sayTask:start()
  end)
end
hs.hotkey.bind({ "ctrl", "cmd" }, "r", speakSelection)
hs.hotkey.bind({ "ctrl", "cmd" }, ".", stopSpeaking)

hs.alert.show("Voice setup ready — ⌥Space talk · ⌥Esc stop · ⌃⌘S draft · ⌃⌘P review PR")
