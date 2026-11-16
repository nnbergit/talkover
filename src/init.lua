--- === TalkOver ===
---
--- Exports Voice Memos recordings and transcribes audio files to Markdown with Whisper.

local obj = {}
obj.name = "TalkOver"
obj.version = "0.0.1"
obj.author = "Olga Pavlova"
obj.homepage = "https://github.com/nnbergit/talkover"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- TalkOver:init()
--- Method
--- Loads the configuration, resolves command paths, and prepares the watcher, exporter, and transcriber.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The TalkOver object
---
--- Notes:
---  * Hammerspoon calls this method when loading the Spoon with `hs.loadSpoon("TalkOver")`.
function obj:init()
    self.config = dofile(hs.spoons.resourcePath("config.lua"))
    self.logger = hs.logger.new(self.name, "info")
    self.i18n, self.config.locale = dofile(hs.spoons.resourcePath("i18n.lua"))(self.config.locale)
    if self.config.language == nil then
        self.config.language = self.config.locale:lower():match("^[a-z]+")
    end

    for setting, executable in pairs({ffmpeg = "ffmpeg", ffprobe = "ffprobe", whisper = "whisper-cli"}) do
        if self.config[setting] == nil then
            local output, found = hs.execute("/usr/bin/which " .. executable, true)
            local path = found and output:match("([^\r\n]+)[\r\n]*$")
            if not path or path:sub(1, 1) ~= "/" then
                error(self.i18n("tool_not_found", {tool = executable}), 2)
            end
            self.config[setting] = path
        end
    end

    self.transcribe = dofile(hs.spoons.resourcePath("transcribe.lua"))
    self.transcribe:init(self.config, self.logger, self.i18n)

    self.export = dofile(hs.spoons.resourcePath("export.lua"))
    self.export:init(self.config, self.logger, self.i18n)

    self.watcher = dofile(hs.spoons.resourcePath("watcher.lua"))
    self.watcher:init(self.logger, self.i18n)

    self.watcher.onChange = function()
        if self.export:isRunning() or self.transcribe:isRunning() then return end
        self.export:start()
    end

    self.export.onFinished = function(status, exported)
        if exported and status ~= "cancelled" then
            self.transcribe:start(self.config.language:lower())
        end
    end
    return self
end

--- TalkOver:start()
--- Method
--- Watches for new or modified Voice Memos recordings and processes the audio folder after an export saves audio.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The TalkOver object
function obj:start()
    if type(self.config.language) ~= "string" or not self.config.language:find("%S") then
        self.logger.e(self.i18n("unsupported_whisper_language", {language = self.config.language}))
        return self
    end

    self.watcher:start()
    return self
end

--- TalkOver:stop()
--- Method
--- Stops watching for recordings, cancels an active export, and finishes the current transcription before stopping the folder scan.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The TalkOver object
function obj:stop()
    self.watcher:stop()
    self.export:stop()
    self.transcribe:stop()
    return self
end

return obj
