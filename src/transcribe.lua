local obj = {}

local function readTxtFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function cleanTranscript(text, language)
    if language == "auto" or not language:match("^[a-z]+$") then return text end
    local filterPath = "i18n/whisper-hallucination/" .. language .. ".txt"
    local settings = readTxtFile(hs.spoons.resourcePath(filterPath))
    if not settings then return text end

    local function phraseKey(line)
        local phrase = line:match("^%s*(.-)%s*$")
        if language == "en" then
            -- English subtitle credits can also end with an em dash.
            phrase = phrase:gsub("%s*[.!]+$", ""):gsub("%s*—$", "")
        end
        return phrase
    end

    local ignored = {}
    for line in settings:gmatch("[^\n]+") do
        local phrase = phraseKey(line)
        if phrase ~= "" then ignored[phrase] = true end
    end

    return (text:gsub("[^\n]*\n?", function(line)
        if ignored[phraseKey(line)] then return "" end
    end))
end

local function transcribe(self, name, audio, transcript, language, done)
    local config, i18n = self.config, self.i18n
    local function fail(message)
        self.logger.w(name .. " — " .. message)
        return done(false)
    end

    local tempDirTask = hs.task.new("/usr/bin/mktemp", function(code, out, err)
        if code ~= 0 then return fail(i18n("work_dir_creation_failed", {detail = err})) end

        local work = out:match("^([^\r\n]+)[\r\n]*$")
        local prefix = config.transcriptsDir .. "/.talkover."
        if not work or work:sub(1, #prefix) ~= prefix
                or hs.fs.attributes(work, "mode") ~= "directory" then
            return fail(i18n("work_dir_unverified"))
        end
        local wav = work .. "/audio.wav"
        local textPath = work .. "/whisper"
        local markdown = work .. "/transcript.md"
        local function clean()
            os.remove(wav)
            os.remove(textPath .. ".txt")
            os.remove(markdown)
            hs.fs.rmdir(work)
        end
        local function cleanAndFail(message)
            clean()
            return fail(message)
        end

        local conversionArgs = {
            "-nostdin", "-v", "error", "-i", audio, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav,
        }
        local conversionTask = hs.task.new(config.ffmpeg, function(conversion, _, conversionError)
            if conversion ~= 0 then return cleanAndFail(i18n("conversion_failed", {detail = conversionError})) end

            local whisperArgs = {
                "-m", config.model, "-f", wav, "-l", language, "-mc", "0", "-np", "-otxt", "-of", textPath,
            }
            local whisperTask = hs.task.new(config.whisper, function(recognition, _, recognitionError)
                -- Some Whisper versions report an unknown language with a successful exit code.
                if recognitionError:find("error: unknown language", 1, true) then
                    return cleanAndFail(i18n("unsupported_whisper_language", {language = language}))
                end
                if recognition ~= 0 then return cleanAndFail(i18n("recognition_failed", {detail = recognitionError})) end

                local text = readTxtFile(textPath .. ".txt")
                if not text or not text:find("%S") then return cleanAndFail(i18n("empty_transcript")) end
                local cleaned = cleanTranscript(text, language)
                if not cleaned:find("%S") then return cleanAndFail(i18n("empty_cleaned_transcript")) end

                local contents = "---\nstatus: new\n---\n" .. cleaned
                local file, openError = io.open(markdown, "wb")
                if not file then return cleanAndFail(i18n("markdown_open_failed", {detail = openError})) end
                local written = file:write(contents)
                local closed = file:close()
                if not written or not closed then return cleanAndFail(i18n("markdown_write_failed")) end

                -- The hard link publishes the complete file without replacing existing Markdown.
                local published, publishError = hs.fs.link(markdown, transcript)
                clean()
                if not published then
                    return fail(i18n("markdown_publish_failed", {detail = publishError}))
                end

                return done(true)
            end, whisperArgs)
            if not whisperTask or not whisperTask:start() then
                local detail = i18n("task_start_failed", {tool = config.whisper})
                return cleanAndFail(i18n("recognition_failed", {detail = detail}))
            end
        end, conversionArgs)
        if not conversionTask or not conversionTask:start() then
            local detail = i18n("task_start_failed", {tool = config.ffmpeg})
            return cleanAndFail(i18n("conversion_failed", {detail = detail}))
        end
    end, {"-d", config.transcriptsDir .. "/.talkover.XXXXXXXX"})
    if not tempDirTask or not tempDirTask:start() then
        local detail = i18n("task_start_failed", {tool = "/usr/bin/mktemp"})
        return fail(i18n("work_dir_creation_failed", {detail = detail}))
    end
end

function obj:init(config, logger, translate)
    self.config = config
    self.logger = logger
    self.i18n = translate
end

function obj:isRunning()
    return self.run ~= nil
end

function obj:start(language)
    if self.run then return end
    local config = self.config
    local names = {}
    local ok, err = pcall(function()
        for name in hs.fs.dir(config.recordsDir) do
            if name:lower():match("%.m4a$") then names[#names + 1] = name end
        end
    end)
    if not ok then
        self.logger.w(self.i18n("scan_failed", {detail = err}))
        return
    end

    local run = {}
    local index = 0
    local function nextRecording()
        index = index + 1
        local name = names[index]
        if not name or run.stopped then
            self.run = nil
            return
        end

        local audio = config.recordsDir .. "/" .. name
        local transcript = config.transcriptsDir .. "/" .. name:sub(1, -5) .. ".md"
        if hs.fs.symlinkAttributes(transcript, "mode") == "file" then
            local task = hs.task.new("/usr/bin/trash", nil, {audio})
            if task then task:start() end
            return nextRecording()
        end
        return transcribe(self, name, audio, transcript, language, function(saved)
            if not saved then return nextRecording() end
            self.logger.i(self.i18n("transcript_saved", {path = transcript}))
            local task = hs.task.new("/usr/bin/trash", nil, {audio})
            if task then task:start() end
            return nextRecording()
        end)
    end

    self.run = run
    nextRecording()
end

function obj:stop()
    if self.run then self.run.stopped = true end
end

return obj
