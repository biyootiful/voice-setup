-- ============================================================
--  Monitor input switch — ⌃⌘I hands a shared monitor to the other computer
--    Over DDC/CI with m1ddc (Apple Silicon). Stands alone: voice-setup's
--    init.lua loads it, and a Mac without voice-setup gets just this file
--    from install-monitor-input.sh. Ports live in
--    ~/.config/voice-setup/monitor-input.conf on each Mac.
--
--    Install it on every Mac sharing the monitor. Many monitors (LG among
--    them) only take DDC commands from the input they're showing, so only the
--    Mac on screen can switch away: press ⌃⌘I on that Mac's keyboard.
--
--    A press reads the current input. Showing this Mac → OTHER_INPUT.
--    Anything else → THIS_INPUT, which only works on monitors that listen on
--    an input they aren't showing.
--    `m1ddc set input` exits non-zero on a real switch (the monitor drops the
--    link before it acks), so its exit code is ignored.
-- ============================================================
local CONF = os.getenv("HOME") .. "/.config/voice-setup/monitor-input.conf"
local M1DDC = nil
for _, p in ipairs({ "/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc" }) do
  if hs.fs.attributes(p) then M1DDC = p; break end
end

local function readConf()
  local c = {}
  local f = io.open(CONF, "r")
  if not f then return c end
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*['\"]?([^'\"#%s]+)")
    if k then c[k] = v end
  end
  f:close()
  return c
end

local ddcTask = nil   -- held so the running task isn't garbage-collected

local function switchMonitorInput()
  local c = readConf()
  local here, there = tonumber(c.THIS_INPUT or ""), tonumber(c.OTHER_INPUT or "")
  if not (here and there) then
    hs.alert.show("Set THIS_INPUT + OTHER_INPUT in ~/.config/voice-setup/monitor-input.conf", 4); return
  end
  if not M1DDC then
    hs.alert.show("m1ddc not found — brew install m1ddc", 3); return
  end
  local function ddc(...)
    local args = c.DDC_DISPLAY and { "display", c.DDC_DISPLAY } or {}
    for _, a in ipairs({ ... }) do args[#args + 1] = a end
    return args
  end
  ddcTask = hs.task.new(M1DDC, function(code, out)
    local current = code == 0 and tonumber((out or ""):match("%d+")) or nil
    local target = current == here and there or here
    if target == there then
      hs.alert.show("🖥  monitor → the other computer", 1)
    elseif current then
      hs.alert.show("🖥  monitor → this Mac", 1)
    else
      hs.alert.show("🖥  monitor isn't answering this Mac — if it doesn't switch, press ⌃⌘I on the Mac it's showing", 3)
    end
    ddcTask = hs.task.new(M1DDC, nil, ddc("set", "input", tostring(target)))
    ddcTask:start()
  end, ddc("get", "input"))
  ddcTask:start()
end
hs.hotkey.bind({ "ctrl", "cmd" }, "i", switchMonitorInput)
