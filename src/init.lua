local obj = {}
obj.name = "TalkOver"
obj.version = "0.0.1"
obj.author = "Olga Pavlova"
obj.homepage = "https://github.com/nnbergit/talkover"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local function audioNames()
    local names = {}
    for name in hs.fs.dir(obj.recordsDir) do
        if name:lower():match("%.m4a$") then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

local function stamp(path)
    local a = hs.fs.symlinkAttributes(path)
    if a and a.mode == "file" and a.size > 0 then
        return table.concat({a.dev, a.ino, a.size, a.modification}, ":")
    end
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function cleanTranscript(text, language)
    if language == "auto" or not language:match("^[a-z]+$") then return text end
    local filterPath = "i18n/whisper-hallucination/" .. language .. ".txt"
    local settings = read(hs.spoons.resourcePath(filterPath))
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

local function warnRecording(name, message)
    obj.logger.w(obj.t("recording_warning", {name = name, detail = message}))
end

local function run(executable, arguments, finish)
    local task = hs.task.new(executable, function(code, out, err)
        obj.task = nil
        finish(code, out, err)
    end, arguments)
    if task and task:start() then
        obj.task = task
    else
        return finish(-1, "", obj.t("task_start_failed", {tool = executable}))
    end
end

local function trashAudio(name, audio, done)
    return run("/usr/bin/trash", {audio}, function(code, _, err)
        if code == 0 and not hs.fs.symlinkAttributes(audio) then
            obj.logger.i(obj.t("audio_trashed", {name = name}))
        else
            warnRecording(name, obj.t("trash_failed", {detail = err}))
        end
        return done()
    end)
end

local function transcribe(name, audio, transcript, originalStamp, language, done)
    local function warnAndContinue(message)
        warnRecording(name, message)
        return done()
    end

    return run("/usr/bin/mktemp", {"-d", obj.transcriptsDir .. "/.talkover.XXXXXXXX"}, function(code, out, err)
        if code ~= 0 then return warnAndContinue(obj.t("work_dir_creation_failed", {detail = err})) end

        local work = out:match("^([^\r\n]+)[\r\n]*$")
        local prefix = obj.transcriptsDir .. "/.talkover."
        if not work or work:sub(1, #prefix) ~= prefix
                or hs.fs.attributes(work, "mode") ~= "directory" then
            return warnAndContinue(obj.t("work_dir_unverified"))
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
        local function fail(message)
            clean()
            return warnAndContinue(message)
        end

        return run(obj.ffmpeg, {
            "-nostdin", "-v", "error", "-i", audio, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav,
        }, function(conversion, _, conversionError)
            if conversion ~= 0 then return fail(obj.t("conversion_failed", {detail = conversionError})) end

            return run(obj.whisper, {
                "-m", obj.model, "-f", wav, "-l", language, "-mc", "0", "-np", "-otxt", "-of", textPath,
            }, function(recognition, _, recognitionError)
                -- Some Whisper versions report an unknown language with a successful exit code.
                if recognitionError:find("error: unknown language", 1, true) then
                    return fail(obj.t("unsupported_whisper_language", {language = language}))
                end
                if recognition ~= 0 then return fail(obj.t("recognition_failed", {detail = recognitionError})) end

                local text = read(textPath .. ".txt")
                if not text or not text:find("%S") then return fail(obj.t("empty_transcript")) end
                local cleaned = cleanTranscript(text, language)
                if not cleaned:find("%S") then return fail(obj.t("empty_cleaned_transcript")) end
                if stamp(audio) ~= originalStamp then return fail(obj.t("audio_changed")) end

                local contents = "---\nstatus: new\n---\n" .. cleaned
                local file, openError = io.open(markdown, "wb")
                if not file then return fail(obj.t("markdown_open_failed", {detail = openError})) end
                local written = file:write(contents)
                local closed = file:close()
                if not written or not closed then return fail(obj.t("markdown_write_failed")) end

                -- Жёсткая ссылка публикует целый файл и никогда не заменяет существующий .md.
                local published, publishError = hs.fs.link(markdown, transcript)
                clean()
                if not published then
                    return warnAndContinue(obj.t("markdown_publish_failed", {detail = publishError}))
                end

                obj.logger.i(obj.t("transcript_saved", {path = transcript}))
                return trashAudio(name, audio, done)
            end)
        end)
    end)
end

local function scan(language)
    if not obj.watcher or obj.task or obj.exportRun then return end
    local ok, names = pcall(audioNames)
    if not ok then obj.logger.w(obj.t("scan_failed", {detail = names})); return end

    local index = 0
    local function nextRecording()
        if not obj.watcher or obj.exportRun then return end
        while index < #names do
            index = index + 1
            local name = names[index]
            local audio = obj.recordsDir .. "/" .. name
            local originalStamp = stamp(audio)
            if originalStamp then
                local transcript = obj.transcriptsDir .. "/" .. name:sub(1, -5) .. ".md"
                if hs.fs.symlinkAttributes(transcript, "mode") == "file" then
                    return trashAudio(name, audio, nextRecording)
                end
                return transcribe(name, audio, transcript, originalStamp, language, nextRecording)
            end
        end
    end
    nextRecording()
end

local function audioFilesChanged(paths, flags)
    for i, path in ipairs(paths) do
        local flag = flags[i]
        if path:lower():match("%.m4a$") and flag and not flag.itemRemoved
                and (flag.itemCreated or flag.itemModified or flag.itemRenamed) and stamp(path) then
            obj.scanTimer:start()
            return
        end
    end
end

local function runExport()
    if not obj.voiceWatcher or obj.exportRun then return end
    local session = hs.caffeinate.sessionProperties() or {}
    if session.CGSSessionScreenIsLocked or session.kCGSSessionOnConsoleKey == false
            or hs.host.idleTime() < 3 then
        obj.exportTimer:start(5)
        return
    end

    obj.exportRun = obj.export(obj, obj.t, function(status, message)
        obj.exportRun = nil
        if obj.scanTimer then obj.scanTimer:start() end
        if not obj.voiceWatcher then return end
        if status == "busy" then
            if not obj.exportTimer:running() then obj.exportTimer:start(10) end
        elseif status == "error" then
            obj.logger.w(obj.t("export_stopped", {detail = message}))
        end
    end)
end

local function voiceFilesChanged(paths, flags)
    for i, path in ipairs(paths) do
        local flag = flags[i]
        -- Удаления и переносы в корзину Диктофона также дают события переименования.
        -- Для повторного запуска нужно создание или изменение содержимого записи.
        if path:lower():match("%.m4a$") and flag and not flag.itemRemoved
                and (flag.itemCreated or flag.itemModified) then
            obj:exportNow()
            return
        end
    end
end

function obj:exportNow()
    if not self.voiceWatcher or self.exportRun then return false end
    self.exportTimer:start()
    return true
end

--- TalkOver:init()
--- Method
--- Load the bundled defaults and prepare resources. Called by hs.loadSpoon().
function obj:init()
    local defaults = dofile(hs.spoons.resourcePath("config.lua"))
    for key, value in pairs(defaults) do
        self[key] = value
    end

    self.logger = hs.logger.new(self.name, "info")
    self.export = dofile(hs.spoons.resourcePath("export.lua"))
    self.t = dofile(hs.spoons.resourcePath("i18n.lua"))(defaults.locale)
    return self
end

function obj:start()
    if self.watcher then return self end
    local language = self.language
    if type(language) ~= "string" or not language:find("%S") then
        self.logger.e(self.t("unsupported_whisper_language", {language = language}))
        return self
    end

    local ok, err = pcall(audioNames)
    if not ok then self.logger.e(self.t("scan_failed", {detail = err})); return self end

    language = language:lower()
    local function scanQueue() scan(language) end
    self.scanTimer = hs.timer.delayed.new(self.scanDelay, scanQueue)
    self.watcher = hs.pathwatcher.new(self.recordsDir, audioFilesChanged):start()
    self.retryTimer = hs.timer.doEvery(self.scanInterval, scanQueue)
    self.scanTimer:start()
    self.logger.i(self.t("watching_audio", {path = self.recordsDir}))

    self.exportTimer = hs.timer.delayed.new(self.exportDelay, runExport)
    local started, watcher = pcall(function()
        return hs.pathwatcher.new(self.voiceMemosDir, voiceFilesChanged):start()
    end)
    if started and watcher then
        self.voiceWatcher = watcher
        self.logger.i(self.t("watching_voice_memos", {path = self.voiceMemosDir}))
    else
        self.logger.e(self.t("voice_watch_failed", {detail = watcher}))
    end
    return self
end

function obj:stop()
    if self.voiceWatcher then
        self.voiceWatcher:stop()
        self.voiceWatcher = nil
    end
    if self.exportTimer then
        self.exportTimer:stop()
        self.exportTimer = nil
    end
    if self.exportRun then self.exportRun:cancel() end
    if self.watcher then
        self.watcher:stop()
        self.scanTimer:stop()
        self.retryTimer:stop()
        self.watcher, self.scanTimer, self.retryTimer = nil, nil, nil
    end
    return self
end

return obj
