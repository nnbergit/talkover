local obj = {}
local voiceMemosDir = os.getenv("HOME") .. "/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

local function hasRecordingChange(paths, flags)
    for index, path in ipairs(paths) do
        local event = flags[index]
        -- Moving a Voice Memos recording to Trash also emits a rename event.
        if path:lower():match("%.m4a$") and event and not event.itemRemoved
                and (event.itemCreated or event.itemModified) then
            return true
        end
    end
    return false
end

function obj:init(logger, translate)
    self.logger = logger
    self.i18n = translate
    local function onFilesChanged(paths, flags)
        local onChange = self.onChange
        if not onChange then return end
        if self.running and hasRecordingChange(paths, flags) then onChange() end
    end
    self.pathWatcher = hs.pathwatcher.new(voiceMemosDir, onFilesChanged)
end

function obj:start()
    if self.running then return end
    local started, result = pcall(self.pathWatcher.start, self.pathWatcher)
    if not started or not result then
        self.logger.e(self.i18n("voice_watch_failed", {detail = result}))
        return
    end
    self.running = true
    self.logger.i(self.i18n("watching_voice_memos", {path = voiceMemosDir}))
    return true
end

function obj:stop()
    if not self.running then return end
    self.running = false
    self.pathWatcher:stop()
end

return obj
