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
local COPY_DICTATION = true   -- also copy dictated text to the clipboard, so you
                              -- can press ⌃⌘E right after to revise it
local DRAFT_REPLY = HOME .. "/.local/bin/draft-reply.sh"
local PR_REVIEW   = HOME .. "/.local/bin/pr-review.sh"
local RESUME_REVIEW = HOME .. "/.local/bin/resume-review.sh"
local REVISE_TEXT   = HOME .. "/.local/bin/revise-text.sh"
local JIRA_AGENT    = HOME .. "/.local/bin/jira-agent.sh"
local JIRA_TRIAGE   = HOME .. "/.local/bin/jira-triage.sh"
local EMAIL_AGENT   = HOME .. "/.local/bin/email-agent.sh"
-- --------------------------------

local recording  = false
local recTask    = nil
local recAlert   = nil
local reviseMode = false  -- true when this dictation should be auto-revised before typing

-- Send the recorded clip to the warm whisper-server, then type the result
local function transcribeAndType()
  local curlTask = hs.task.new(CURL_BIN, function(exitCode, stdout, stderr)
    if exitCode ~= 0 or not stdout then
      hs.alert.show("dictation: transcription failed")
      return
    end
    local text = stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text == "[BLANK_AUDIO]" then return end
    if reviseMode then
      hs.alert.show("✏️  cleaning up…", 2)
      hs.task.new(REVISE_TEXT, function(c, out, err)
        local clean = (out or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if clean == "" then clean = text end
        hs.eventtap.keyStrokes(clean .. " ")
      end, { text }):start()
    else
      hs.eventtap.keyStrokes(text .. " ")
      if COPY_DICTATION then hs.pasteboard.setContents(text) end  -- so ⌃⌘E can revise it
    end
  end, { "-s", ENDPOINT, "-F", "file=@" .. CLIP, "-F", "response_format=text" })
  curlTask:start()
end

local function startRecording(revise)
  if recording then return end
  recording = true
  reviseMode = revise and true or false
  -- silence any TTS so it doesn't bleed into the mic and garble the transcript
  hs.task.new(CURL_BIN, nil, { "-s", "--max-time", "2", "http://127.0.0.1:8123/stop" }):start()
  hs.task.new("/usr/bin/killall", nil, { "say" }):start()
  recAlert = hs.alert.show(reviseMode and "🎤  Listening…  (clean dictation — auto-revise)"
                                       or "🎤  Listening…  (release Option+Space to type)", 86400)
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
      if not recording then startRecording(e:getFlags().shift) end  -- +Shift = clean dictation
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
  hs.eventtap.keyStroke({ "cmd" }, "c")            -- try to copy the highlighted message
  hs.timer.doAfter(0.2, function()
    local q = hs.pasteboard.getContents()
    if not q or q:gsub("%s", "") == "" then
      hs.alert.show("Highlight the message first (in a terminal, ⌘C it), then ⌃⌘S"); return
    end
    hs.alert.show("✍️  drafting reply…  (I'll ping you when ready)", 2)
    local task = hs.task.new(DRAFT_REPLY, function(code, stdout, stderr)
      local reply = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if code == 0 and reply ~= "" then
        hs.pasteboard.setContents(reply)
        -- Drafting takes ~1-2 min (it searches the codebase), so you may have
        -- looked away. Chime plays even if notifications are disabled.
        local chime = hs.sound.getByName("Glass"); if chime then chime:play() end
        -- Persistent + clickable: click to re-copy, since dictation/other copies
        -- may have overwritten the clipboard while you waited.
        hs.notify.new(function() hs.pasteboard.setContents(reply); hs.alert.show("✅  re-copied — ⌘V to paste", 2) end,
                      { title = "Reply ready — click to re-copy",
                        informativeText = reply:sub(1, 140),
                        soundName = "Glass", withdrawAfter = 0 }):send()
        hs.alert.show("✅  reply ready — ⌘V to paste  (backup: /tmp/draft-reply.last.txt)", 4)
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

-- Ctrl+Cmd+H = screen candidate resumes against a role spec. Asks which role
-- (from ~/.config/voice-setup/roles/), then pops a multi-select file picker
-- (defaults to ~/Downloads). Each resume is screened in its own Claude call
-- against that role's rubric, so candidates are graded against the bar rather
-- than against each other. Summary lands on the clipboard, full notes in a
-- report file. Nothing is sent anywhere — you review and paste.
local function reviewResumes()
  hs.alert.show("📄  which role, then pick the PDFs…", 1.5)
  local task = hs.task.new(RESUME_REVIEW, function(code, stdout, stderr)
    local out = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if out == "CANCELLED" or out == "" then return end
    if code == 0 then
      hs.pasteboard.setContents(out)
      hs.notify.new({ title = "Resume screen ready",
                      informativeText = "Copied — ⌘V to paste.\n" .. out:sub(1, 160),
                      soundName = "Glass" }):send()
      hs.alert.show("✅  feedback on clipboard — ⌘V to paste", 2.5)
    else
      hs.alert.show("resume review failed — see /tmp/resume-review.log")
    end
  end, {})
  task:start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "h", reviewResumes)

-- Ctrl+Cmd+J = Jira ticket → planning session. Copy the ticket URL, pick the
-- product group; spins up a kitty Claude session scoped to that group's repos,
-- reads the ticket via the Atlassian MCP, and gives a read-only plan.
local function jiraAgent()
  local clip = hs.pasteboard.getContents()
  if not clip or not clip:match("[A-Z][A-Z0-9]+%-%d+") then
    hs.alert.show("Copy a Jira ticket URL first, then ⌃⌘J"); return
  end
  hs.alert.show("🎫  pick the product group…", 1.5)
  hs.task.new(JIRA_AGENT, function(code, stdout, stderr)
    local out = (stdout or ""):gsub("%s+$", "")
    if code == 0 and out:match("^OK") then
      hs.alert.show("🚀  session opening — agent is reading the ticket", 2.5)
    elseif out ~= "CANCELLED" then
      hs.alert.show("Jira agent failed — see /tmp/jira-agent.log")
    end
  end, { clip }):start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "j", jiraAgent)

-- Ctrl+Cmd+K = Jira board triage. Pick a product group; opens a kitty Claude
-- session that cross-checks the board against git (develop = stage, main = prod)
-- and reports what's actually deployed, what drifted, and what has no code yet.
-- Read-only: JQL reads + git fetch, nothing written to Jira.
local function jiraTriage()
  hs.alert.show("📋  pick the board / product group…", 1.5)
  hs.task.new(JIRA_TRIAGE, function(code, stdout, stderr)
    local out = (stdout or ""):gsub("%s+$", "")
    if code == 0 and out:match("^OK") then
      hs.alert.show("🚀  triaging — fetching repos, then reading the board", 2.5)
    elseif out == "NO_PROJECTS" then
      hs.alert.show("Add GROUP_JIRA_PROJECTS for that group in repo-groups.conf", 3)
    elseif out ~= "CANCELLED" then
      hs.alert.show("Jira triage failed — see /tmp/jira-triage.log")
    end
  end, {}):start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "k", jiraTriage)

-- Ctrl+Cmd+M = email triage. Opens a kitty Claude session that reads recent
-- inbox via the Gmail MCP, marks known automated noise as read, summarizes
-- everything, and drafts replies (never sends) for client/technical threads.
local function emailAgent()
  hs.alert.show("📧  triaging inbox…  (session opening)", 2)
  hs.task.new(EMAIL_AGENT, function(code, stdout, stderr)
    local out = (stdout or ""):gsub("%s+$", "")
    if code == 0 and out:match("^OK") then
      hs.alert.show("🚀  email triage running — check the new session", 2.5)
    else
      hs.alert.show("Email agent failed — see /tmp/email-agent.log")
    end
  end, {}):start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "m", emailAgent)

-- Ctrl+Cmd+E = revise highlighted text into concise Slack style, paste-ready.
local function reviseSelection()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.2, function()
    local t = hs.pasteboard.getContents()
    if not t or t:gsub("%s", "") == "" then
      hs.alert.show("Nothing to revise (in a terminal, ⌘C the text first)"); return
    end
    hs.alert.show("✏️  revising…", 1.5)
    local task = hs.task.new(REVISE_TEXT, function(code, stdout, stderr)
      local out = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if code == 0 and out ~= "" then
        hs.pasteboard.setContents(out)
        hs.alert.show("✅  revised — ⌘V to paste", 2)
      else
        hs.alert.show("revise failed — see /tmp/revise-text.log")
      end
    end, { t })
    task:start()
  end)
end
hs.hotkey.bind({ "ctrl", "cmd" }, "e", reviseSelection)

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
  hs.eventtap.keyStroke({ "cmd" }, "c")               -- try to copy the highlighted text
  hs.timer.doAfter(0.2, function()
    local text = hs.pasteboard.getContents()
    if not text or text:gsub("%s", "") == "" then
      hs.alert.show("nothing to read (in a terminal, ⌘C the text first)"); return
    end
    hs.alert.show("🔊 reading…  (Option+Esc or ⌃⌘. to stop)", 1)
    -- read via the Kokoro neural server — same natural voice as the auto-read
    hs.task.new(CURL_BIN, nil,
      { "-s", "--max-time", "10", "-X", "POST", "--data-binary", text, "http://127.0.0.1:8123/speak" }):start()
  end)
end
hs.hotkey.bind({ "ctrl", "cmd" }, "r", speakSelection)
hs.hotkey.bind({ "ctrl", "cmd" }, ".", stopSpeaking)

-- ============================================================
--  Machine-local shortcuts — ~/.hammerspoon/local.lua (optional)
--    Hotkeys that name internal systems (work repos, accounts) live there, not
--    in this file, so this one stays shareable. install.sh never touches it.
-- ============================================================
local LOCAL_CONFIG = HOME .. "/.hammerspoon/local.lua"
if hs.fs.attributes(LOCAL_CONFIG) then
  local ok, err = pcall(dofile, LOCAL_CONFIG)
  if not ok then hs.alert.show("local.lua failed: " .. tostring(err), 6) end
end

-- ============================================================
--  Cheat sheet + menu bar — see every shortcut anytime.
--    Click the 🎙️ menu-bar icon, or press ⌃⌘/ for an overlay.
--  (One shared list below drives both — edit here to update both.)
-- ============================================================
local HOMEDIR = os.getenv("HOME")
local COMMANDS = {
  { "⌥ Space (hold)",     "Dictate — raw, types as you speak" },
  { "⌥ ⇧ Space (hold)",   "Clean dictation — transcribe, auto-revise, type" },
  { "⌃ ⌘ E",              "Revise highlighted text (concise, Slack style)" },
  { "⌃ ⌘ R",              "Read highlighted text aloud (Kokoro voice)" },
  { "⌥ Esc  /  ⌃ ⌘ .",    "Stop reading" },
  { "⌃ ⌘ S",              "Draft a reply to the highlighted message" },
  { "⌃ ⌘ P",              "Review GitHub PR(s) from copied link(s)" },
  { "⌃ ⌘ H",              "Screen resume PDFs against a role spec" },
  { "⌃ ⌘ J",              "Jira ticket → scoped planning session (copy URL)" },
  { "⌃ ⌘ K",              "Jira board triage — what's deployed vs what Jira claims" },
  { "⌃ ⌘ M",              "Email triage — mark noise read, summarize, draft replies" },
}

local cheatId = nil
local function toggleCheatSheet()
  if cheatId then hs.alert.closeSpecific(cheatId); cheatId = nil; return end
  local lines = { "⌨️   Voice & AI shortcuts", "" }
  for _, c in ipairs(COMMANDS) do lines[#lines + 1] = c[1] .. "      " .. c[2] end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Claude's replies are read aloud automatically."
  lines[#lines + 1] = "⌃⌘/ to hide  ·  click 🎙️ in the menu bar for config + reload"
  cheatId = hs.alert.show(table.concat(lines, "\n"),
    { textSize = 16, radius = 12 }, hs.screen.mainScreen(), 999999)
end
hs.hotkey.bind({ "ctrl", "cmd" }, "/", toggleCheatSheet)

voiceMenubar = hs.menubar.new()
if voiceMenubar then
  voiceMenubar:setTitle("🎙️")
  voiceMenubar:setTooltip("Voice & AI shortcuts")
  voiceMenubar:setMenu(function()
    local m = { { title = "Voice & AI — shortcuts", disabled = true } }
    for _, c in ipairs(COMMANDS) do m[#m + 1] = { title = c[1] .. "   " .. c[2], disabled = true } end
    m[#m + 1] = { title = "-" }
    m[#m + 1] = { title = "Show cheat sheet  (⌃⌘/)", fn = toggleCheatSheet }
    m[#m + 1] = { title = "Edit shortcuts config (init.lua)…",
                  fn = function() hs.execute("open -t '" .. HOMEDIR .. "/.hammerspoon/init.lua'") end }
    m[#m + 1] = { title = "Edit reply-repos config…",
                  fn = function() hs.execute("mkdir -p '" .. HOMEDIR .. "/.config/voice-setup'; touch '" .. HOMEDIR .. "/.config/voice-setup/reply-repos.conf'; open -t '" .. HOMEDIR .. "/.config/voice-setup/reply-repos.conf'") end }
    m[#m + 1] = { title = "-" }
    m[#m + 1] = { title = "Reload config", fn = function() hs.reload() end }
    return m
  end)
end

hs.alert.show("Voice setup ready — press ⌃⌘/ or click 🎙️ for all shortcuts", 2)
