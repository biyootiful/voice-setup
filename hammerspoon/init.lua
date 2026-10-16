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
local ENG_WEEKLY    = HOME .. "/.local/bin/eng-weekly.sh"
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

-- Ctrl+Cmd+J = Jira ticket → built, verified code. Copy the ticket URL, pick the
-- product group; spins up a kitty Claude session scoped to those repos that reads
-- the ticket via the Atlassian MCP, branches off develop, writes the failing test
-- first, implements until that repo's own check passes, commits, and writes a PR
-- body. It resolves ordinary ambiguity itself and logs the assumptions instead of
-- stopping to ask. Does not push.
--   Hold SHIFT = plan only (read-only scoping, touches nothing).
local function jiraAgent()
  local clip = hs.pasteboard.getContents()
  if not clip or not clip:match("[A-Z][A-Z0-9]+%-%d+") then
    hs.alert.show("Copy a Jira ticket URL first, then ⌃⌘J"); return
  end
  local planOnly = hs.eventtap.checkKeyboardModifiers().shift
  local args = { clip }
  if planOnly then table.insert(args, "--plan") end
  hs.alert.show(planOnly and "📋  plan only — pick the repos…"
                          or "🔨  build — pick the repos…", 1.5)
  hs.task.new(JIRA_AGENT, function(code, stdout, stderr)
    local out = (stdout or ""):gsub("%s+$", "")
    if code == 0 and out:match("^OK") then
      hs.alert.show(planOnly and "🚀  session opening — agent is reading the ticket"
                              or "🚀  building — test first, then green", 2.5)
    elseif out ~= "CANCELLED" then
      hs.alert.show("Jira agent failed — see /tmp/jira-agent.log")
    end
  end, args):start()
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

-- Ctrl+Cmd+F = session finder chat. Ask the way you'd ask an agent ("find me the
-- checkout pixel session", "no, the one where we changed the code"). An agent digs
-- through the transcripts (session-chat.py) and answers with what happened there;
-- each session it names gets an Open button, or "open now" if a window already
-- has it (reopening would put two processes on one transcript). The conversation
-- persists until you press New chat, so follow-ups keep their context.
local SESSION_CHAT  = HOME .. "/.local/bin/session-chat.py"
local RESUME_SCRIPT = HOME .. "/.local/bin/claude-resume.sh"
local KITTY_BIN     = "/Applications/kitty.app/Contents/MacOS/kitty"

local finderView, finderConv, finderTask = nil, "", nil

local FINDER_HTML = [[
<!doctype html><html><head><meta charset="utf-8"><style>
:root { color-scheme: dark; }
body { margin:0; font: 14px -apple-system, system-ui; background:#1e1f22; color:#e6e6e6;
       display:flex; flex-direction:column; height:100vh; }
#log { flex:1; overflow-y:auto; padding:14px 16px; }
.msg { margin:0 0 12px; line-height:1.45; white-space:pre-wrap; }
.me { color:#9ecbff; }
.me::before { content:"you  "; color:#6b7280; }
.bot code { background:#2b2d31; padding:1px 4px; border-radius:4px; }
.card { background:#2b2d31; border:1px solid #3a3d43; border-radius:8px; padding:8px 10px;
        margin:6px 0; display:flex; gap:10px; align-items:center; }
.card .t { flex:1; min-width:0; }
.card .h { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.card .s { color:#9aa0a6; font-size:12px; margin-top:2px; }
.live { color:#7ee787; font-weight:600; }
button { background:#3b82f6; color:white; border:0; border-radius:6px; padding:5px 12px;
         font-size:13px; cursor:pointer; }
button.ghost { background:transparent; color:#9aa0a6; border:1px solid #3a3d43; }
#bar { display:flex; gap:8px; padding:10px 12px; border-top:1px solid #34363b; }
#q { flex:1; background:#2b2d31; color:#e6e6e6; border:1px solid #3a3d43; border-radius:8px;
     padding:9px 10px; font-size:14px; outline:none; }
.think { color:#9aa0a6; font-style:italic; }
</style></head><body>
<div id="log"><div class="msg bot think">Which session are you after? Ask like you'd ask the agent.</div></div>
<div id="bar"><input id="q" placeholder="e.g. find me the checkout pixel session" autofocus>
<button class="ghost" id="new">New chat</button></div>
<script>
const log = document.getElementById('log'), q = document.getElementById('q');
const post = m => webkit.messageHandlers.finder.postMessage(m);
function esc(s){ return (s||'').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function md(s){ return esc(s).replace(/\*\*(.+?)\*\*/g,'<b>$1</b>').replace(/`([^`]+)`/g,'<code>$1</code>'); }
function add(cls, html){ const d=document.createElement('div'); d.className='msg '+cls; d.innerHTML=html;
  log.appendChild(d); log.scrollTop=log.scrollHeight; return d; }
let pending=null;
function send(){ const t=q.value.trim(); if(!t||pending) return; add('me', esc(t)); q.value='';
  pending=add('bot think','digging through sessions…'); post({type:'ask', text:t}); }
q.addEventListener('keydown', e => { if(e.key==='Enter') send(); if(e.key==='Escape') post({type:'close'}); });
document.getElementById('new').onclick = () => { log.innerHTML=''; add('bot think','New chat. Which session?'); post({type:'new'}); q.focus(); };
window.addReply = r => {
  if(pending){ pending.remove(); pending=null; }
  add('bot', md(r.reply || ''));
  (Array.isArray(r.sessions) ? r.sessions : []).forEach(s => {
    const c=document.createElement('div'); c.className='card';
    c.innerHTML = '<div class="t"><div class="h">'+esc(s.title)+'</div><div class="s">'+esc(s.when)+' · '+esc(s.dir)+
      (s.live?' · <span class="live">open now</span>':'')+(s.why?' · '+esc(s.why):'')+'</div></div>';
    const b=document.createElement('button'); b.textContent = s.live ? 'Show' : 'Open';
    b.onclick = () => post({type:'open', sid:s.sid, cwd:s.cwd, live:s.live, title:s.title});
    c.appendChild(b); log.appendChild(c);
  });
  log.scrollTop=log.scrollHeight; q.focus();
};
</script></body></html>
]]

local function openFoundSession(m)
  if m.live then
    hs.alert.show("Already open in a kitty window — switching to kitty", 2)
    hs.application.launchOrFocus("kitty"); return
  end
  hs.task.new(KITTY_BIN, nil, { "--single-instance", "--directory", m.cwd,
    "--title", "↻ " .. (m.title or ""):sub(1, 40),
    "/bin/zsh", "-lc", RESUME_SCRIPT .. " " .. m.sid .. " --go" }):start()
  hs.alert.show("↻  reopening session", 1.5)
  if finderView then finderView:hide() end
end

local function onFinderMessage(msg)
  local m = msg.body
  if m.type == "close" then finderView:hide()
  elseif m.type == "new" then finderConv = ""
  elseif m.type == "open" then openFoundSession(m)
  elseif m.type == "ask" then
    local args = { SESSION_CHAT }
    if finderConv ~= "" then args[#args + 1] = "--conv"; args[#args + 1] = finderConv end
    args[#args + 1] = m.text
    finderTask = hs.task.new("/usr/bin/python3", function(code, stdout, stderr)
      local ok, r = pcall(hs.json.decode, stdout or "")
      if not ok or type(r) ~= "table" then
        r = { reply = "Search failed: " .. ((stderr or ""):sub(1, 200)), sessions = {} }
      end
      if r.conv and r.conv ~= "" then finderConv = r.conv end
      if finderView then finderView:evaluateJavaScript("addReply(" .. hs.json.encode(r) .. ")") end
    end, args)
    finderTask:start()
  end
end

local function findSession()
  if not finderView then
    local uc = hs.webview.usercontent.new("finder")
    uc:setCallback(onFinderMessage)
    local f = hs.screen.mainScreen():frame()
    local w, h = 720, 560
    finderView = hs.webview.new({ x = f.x + (f.w - w) / 2, y = f.y + (f.h - h) / 4, w = w, h = h }, {}, uc)
      :windowStyle({ "titled", "closable", "resizable" })
      :windowTitle("Find a session")
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.floating)
      :deleteOnClose(false)
      :behavior(hs.drawing.windowBehaviors.moveToActiveSpace)
      :html(FINDER_HTML)
  end
  finderView:show():bringToFront(true)
  local win = finderView:hswindow()
  if win then win:focus() end
  finderView:evaluateJavaScript("document.getElementById('q').focus()")
end
hs.hotkey.bind({ "ctrl", "cmd" }, "f", findSession)

-- Ctrl+Cmd+W = draft the Engineering Weekly email. Opens a kitty Claude session
-- that reads my last few updates from Sent (for the format), walks the
-- configured Jira boards for the window since that update, and leaves a Gmail
-- DRAFT plus a markdown copy. Never sends; nothing is written back to Jira.
local function engWeekly()
  hs.alert.show("📮  drafting the weekly update…  (session opening)", 2)
  hs.task.new(ENG_WEEKLY, function(code, stdout, stderr)
    local out = (stdout or ""):gsub("%s+$", "")
    if code == 0 and out:match("^OK") then
      hs.alert.show("🚀  reading my last updates, then the boards", 2.5)
    elseif out == "NO_CONFIG" or out == "NO_AREAS" then
      hs.alert.show("Set ENG_WEEKLY_TO + areas in ~/.config/voice-setup/eng-weekly.conf", 4)
    else
      hs.alert.show("Eng weekly failed — see /tmp/eng-weekly.log")
    end
  end, {}):start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "w", engWeekly)

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
-- ============================================================
--  Agent window wrangling — ⌃⌘T to tile, ⌃⌘1..9 to jump
--    Scoped to kitty only, so it leaves every other app alone.
--    ⌃⌘T  lays the agent sessions out in an even grid on this screen.
--    ⌃⌘N  focuses the Nth session directly — no cycling past the others,
--         which is the part that makes ⌘` jarring with 4+ windows open.
--    Order is stable (title, then window id), so ⌃⌘2 is the same session
--    every time until you open or close one.
-- ============================================================
-- Gutter between tiled windows, in points. 0 is flush: the grid math below
-- collapses cleanly to edge-to-edge, so raise this if you ever want air back.
local TILE_GAP = 0

local function kittyWindows()
  local app = hs.application.get("kitty")
  if not app then return {} end
  local ws = {}
  for _, w in ipairs(app:allWindows()) do
    if w:isStandard() and w:isVisible() then ws[#ws + 1] = w end
  end
  table.sort(ws, function(a, b)
    local ta, tb = a:title() or "", b:title() or ""
    if ta == tb then return (a:id() or 0) < (b:id() or 0) end
    return ta < tb
  end)
  return ws
end

-- Rows/cols that keep windows as square as possible. 3 becomes 2x2 rather than
-- three thin columns — the odd one out stretches across the bottom row below.
local function gridFor(n)
  if n <= 1 then return 1, 1
  elseif n == 2 then return 2, 1
  elseif n <= 4 then return 2, 2
  elseif n <= 6 then return 3, 2
  else return 3, 3 end
end

local function tileKitty()
  local ws = kittyWindows()
  local n = #ws
  if n == 0 then hs.alert.show("no kitty windows open"); return end
  local f = hs.screen.mainScreen():frame()   -- usable frame: excludes menu bar + dock
  local cols, rows = gridFor(n)
  local ch = (f.h - TILE_GAP * (rows + 1)) / rows
  local i = 1
  for r = 0, rows - 1 do
    local inRow = math.min(cols, n - r * cols)   -- last row stretches to fill
    if inRow <= 0 then break end
    local cw = (f.w - TILE_GAP * (inRow + 1)) / inRow
    for c = 0, inRow - 1 do
      ws[i]:setFrame({
        x = f.x + TILE_GAP + c * (cw + TILE_GAP),
        y = f.y + TILE_GAP + r * (ch + TILE_GAP),
        w = cw, h = ch,
      }, 0)
      i = i + 1
    end
  end
  hs.alert.show(("▦  tiled %d session%s"):format(n, n == 1 and "" or "s"), 1)
end
hs.hotkey.bind({ "ctrl", "cmd" }, "t", tileKitty)

for i = 1, 9 do
  hs.hotkey.bind({ "ctrl", "cmd" }, tostring(i), function()
    local ws = kittyWindows()
    local w = ws[i]
    if w then
      w:focus()
      hs.alert.show(("%d · %s"):format(i, w:title() or "?"), 0.7)
    else
      hs.alert.show(("no session %d  (%d open)"):format(i, #ws), 0.8)
    end
  end)
end

local COMMANDS = {
  { "⌥ Space (hold)",     "Dictate — raw, types as you speak" },
  { "⌥ ⇧ Space (hold)",   "Clean dictation — transcribe, auto-revise, type" },
  { "⌃ ⌘ E",              "Revise highlighted text (concise, Slack style)" },
  { "⌃ ⌘ R",              "Read highlighted text aloud (Kokoro voice)" },
  { "⌥ Esc  /  ⌃ ⌘ .",    "Stop reading" },
  { "⌃ ⌘ S",              "Draft a reply to the highlighted message" },
  { "⌃ ⌘ P",              "Review GitHub PR(s) from copied link(s)" },
  { "⌃ ⌘ H",              "Screen resume PDFs against a role spec" },
  { "⌃ ⌘ J  (⇧ = plan)",   "Jira ticket → built + verified code (copy URL)" },
  { "⌃ ⌘ K",              "Jira board triage — what's deployed vs what Jira claims" },
  { "⌃ ⌘ M",              "Email triage — mark noise read, summarize, draft replies" },
  { "⌃ ⌘ F",              "Find a Claude session — chat about it, reopen it" },
  { "⌃ ⌘ W",              "Draft the Engineering Weekly email from the Jira boards" },
  { "⌃ ⌘ T",              "Tile the agent terminals into an even grid" },
  { "⌃ ⌘ 1-9",            "Jump straight to the Nth agent session" },
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
