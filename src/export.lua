local voiceID = "com.apple.VoiceMemos"
local audioType = "com.apple.m4a-audio"
local pasteboard = hs.pasteboard

local function find(element, match, depth)
    if not element or depth < 0 then return end
    if match(element) then return element end
    for _, child in ipairs(element.AXChildren or {}) do
        local result = find(child, match, depth - 1)
        if result then return result end
    end
end

local function named(element, names)
    for _, name in ipairs(names) do
        if element.AXTitle == name or element.AXDescription == name then return true end
    end
    return false
end

local function actionNamed(element, names)
    for _, action in ipairs(element:actionNames() or {}) do
        local title = action:match("^Name:([^\r\n]+)") or action
        for _, name in ipairs(names) do
            if title == name then return action end
        end
    end
end

local function press(element)
    return element and element:performAction("AXPress")
end

local function isLibraryReady(window)
    if not window then return false end
    local editing = find(window, function(element)
        local id = element.AXIdentifier
        return element.AXEnabled ~= false and (id == "RecordingView/DoneButton"
            or id == "RecordingView/ApplyButton" or id == "RecordingView/CancelButton")
    end, 10)
    if editing then return false end
    -- Обычная кнопка новой записи доступна в медиатеке, в том числе в пустой.
    return find(window, function(element)
        return element.AXRole == "AXButton" and element.AXIdentifier == "RecordButton"
            and element.AXEnabled == true
    end, 10) ~= nil
end


local function export(talkOver, t, done)
    local destination = talkOver.recordsDir
    local transcriptDir = talkOver.transcriptsDir
    local run = {}

    local function pause(seconds)
        coroutine.yield(seconds)
    end

    local function waitFor(seconds, message, check)
        local deadline = hs.timer.secondsSinceEpoch() + seconds
        repeat
            local result = check()
            if result then return result end
            pause(0.15)
        until hs.timer.secondsSinceEpoch() >= deadline
        error(message, 0)
    end

    local function task(executable, args, timeout)
        local result
        run.task = assert(hs.task.new(executable, function(code, out, err)
            result = {code, out, err}
        end, args), t("tool_start_failed", {tool = executable}))
        assert(run.task:start(), t("tool_start_failed", {tool = executable}))
        waitFor(timeout, t("tool_timeout", {tool = executable}), function() return result end)
        run.task = nil
        return table.unpack(result)
    end

    local function frontWindow(bundleID)
        local app = hs.application.frontmostApplication()
        if app and app:bundleID() == bundleID then
            return hs.axuielement.applicationElement(app).AXFocusedWindow
        end
    end

    local function voiceWindow()
        return waitFor(10, t("voice_window_missing"), function()
            local window = frontWindow(voiceID)
            if window and window.AXIdentifier == "SceneWindow" then return window end
        end)
    end

    local function moveWindowAside(window)
        local actual = window:asHSWindow()
        if not actual or actual:isFullScreen() then return end
        if run.voiceWindow and run.voiceWindow:id() == actual:id() then return end
        local rightEdge, bottomEdge = -math.huge, -math.huge
        for _, screen in ipairs(hs.screen.allScreens()) do
            local bounds = screen:fullFrame()
            rightEdge = math.max(rightEdge, bounds.x + bounds.w)
            bottomEdge = math.max(bottomEdge, bounds.y + bounds.h)
        end
        if rightEdge == -math.huge then return end
        run.voiceWindow, run.voicePosition = actual, actual:topLeft()
        actual:setTopLeft({x = rightEdge + 16, y = bottomEdge + 16})
    end

    local function restoreDesktop()
        local active = hs.application.frontmostApplication()
        local voice = run.voiceApp or hs.application.get(voiceID)
        local tookFocus = active and active:bundleID() == voiceID
        if voice and (run.voiceApp or tookFocus) then
            if not voice:hide() then
                talkOver.logger.w(t("voice_hide_failed"))
            end
        end
        if tookFocus and run.previousApp and run.previousApp:bundleID() ~= voiceID then
            if run.previousApp:bundleID() == "org.hammerspoon.Hammerspoon" then
                hs.focus()
            end
            if run.previousWindow then run.previousWindow:focus() end
            if not run.previousApp:isFrontmost() then run.previousApp:activate() end
        end
        if run.voiceWindow and run.voicePosition then
            run.voiceWindow:setTopLeft(run.voicePosition)
        end
    end

    local function allRecordings(app, window)
        if named(window, {"Все записи", "All Recordings"}) then return end
        local root = hs.axuielement.applicationElement(app)
        local function allButton()
            return find(root.AXFocusedWindow, function(element)
                local label = element.AXDescription or ""
                return element.AXRole == "AXButton"
                    and (label:match("^Все записи,") or label:match("^All Recordings,"))
            end, 8)
        end
        if not allButton() then
            local sidebar = find(window, function(element)
                return element.AXRole == "AXButton" and named(element, {"Боковое меню", "Sidebar"})
            end, 8)
            assert(press(sidebar), t("sidebar_missing"))
        end
        local button = waitFor(4, t("all_folder_missing"), allButton)
        assert(press(button), t("all_folder_open_failed"))
        waitFor(5, t("all_folder_switch_failed"), function()
            local focused = frontWindow(voiceID)
            return focused and named(focused, {"Все записи", "All Recordings"})
        end)
    end

    local deleteNames = {"Удалить", "Delete", "AXDelete"}
    local function recordingRows()
        local window = frontWindow(voiceID)
        assert(isLibraryReady(window) and named(window, {"Все записи", "All Recordings"}),
            t("all_list_unavailable"))
        local list = find(window, function(element) return element.AXIdentifier == "RecordingsList" end, 10)
        if not list then
            local empty = find(window, function(element)
                return named(element, {"Нет записей", "No Recordings"})
                    or named(element, {"Нет записей.", "No Recordings."})
                    or element.AXValue == "Нет записей" or element.AXValue == "No Recordings"
            end, 10)
            assert(empty, t("recordings_list_missing"))
            return {}
        end

        local rows = {}
        local function visit(element, depth)
            if element.AXRole == "AXButton" and actionNamed(element, deleteNames) then
                rows[#rows + 1] = element
            elseif depth > 0 then
                for _, child in ipairs(element.AXChildren or {}) do visit(child, depth - 1) end
            end
        end
        visit(list, 6)
        return rows
    end

    local function rowKey(row)
        local description = row.AXDescription
        assert(type(description) == "string" and description ~= "", t("row_without_description"))
        return description .. "\n" .. tostring(row.AXValue or "")
    end

    local function currentRow(key)
        local rows = recordingRows()
        local result
        for _, row in ipairs(rows) do
            if rowKey(row) == key then
                assert(not result, t("duplicate_row", {name = key}))
                result = row
            end
        end
        return result
    end

    local function isSelected(row, root)
        if row.AXSelected ~= nil then return row.AXSelected == true or row.AXSelected == 1 end
        local list = row.AXParent
        for _, element in ipairs(list and list.AXSelectedChildren or {}) do
            if element == row then return true end
        end
        local focused = root.AXFocusedUIElement
        for _ = 1, 5 do
            if not focused then return false end
            if focused == row then return true end
            focused = focused.AXParent
        end
        return false
    end

    local copyMenus = {{"Правка", "Скопировать"}, {"Edit", "Copy"}}

    local function matchesRecording(title, description)
        return type(title) == "string" and title ~= ""
            and (description == title or description:sub(1, #title + 2) == title .. ", ")
    end

    local function copiedAudio(app, row, description)
        local root = hs.axuielement.applicationElement(app)
        assert(isLibraryReady(frontWindow(voiceID)), t("voice_busy"))
        assert(press(row), t("select_recording_failed"))
        local menu = waitFor(5, t("copy_unavailable"), function()
            if not frontWindow(voiceID) or not isSelected(row, root) then return end
            for _, path in ipairs(copyMenus) do
                local item = app:findMenuItem(path)
                if item and item.enabled then return path end
            end
        end)

        local before = pasteboard.changeCount()
        local saved = pasteboard.readAllData() or {}
        assert(pasteboard.changeCount() == before, t("clipboard_changed"))
        assert(app:selectMenuItem(menu), t("copy_command_failed"))
        local result = waitFor(12, t("clipboard_audio_missing"), function()
            local count = pasteboard.changeCount()
            if count == before then return end
            assert(frontWindow(voiceID) and isSelected(row, root), t("selection_changed"))
            local title = pasteboard.readDataForUTI("public.utf8-plain-text")
            if not matchesRecording(title, description) then return end
            local audio = pasteboard.readDataForUTI(audioType)
            if audio and #audio > 0 and pasteboard.changeCount() == count then
                return {count = count, audio = audio}
            end
        end)

        if pasteboard.changeCount() == result.count then
            if next(saved) then
                if not pasteboard.writeAllData(saved) then
                    talkOver.logger.w(t("clipboard_restore_failed"))
                end
            else
                pasteboard.clearContents()
            end
        end
        return result.audio
    end

    local function exportName(source)
        local code, metadata = task(talkOver.ffprobe, {
            "-v", "error", "-show_entries", "format_tags=creation_time",
            "-of", "default=noprint_wrappers=1:nokey=1", source,
        }, 5)
        local dateTime, zone
        if code == 0 then
            dateTime, zone = metadata:match("^%s*(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.?%d*([^%s]+)%s*$")
        end
        if dateTime then
            zone = zone == "Z" and "+0000" or zone:gsub(":", "")
            if zone:match("^[+-]%d%d%d%d$") then
                local status, output = task("/bin/date", {
                    "-j", "-f", "%Y-%m-%dT%H:%M:%S%z", dateTime .. zone, "+%Y%m%d %H%M%S",
                }, 5)
                local name = status == 0 and output:match("^(%d%d%d%d%d%d%d%d %d%d%d%d%d%d)%s*$")
                if name then return name .. ".m4a" end
            end
        end

        talkOver.logger.w(t("audio_creation_date_missing"))
        local created = hs.fs.attributes(source, "creation")
        return os.date("%Y%m%d %H%M%S", created) .. ".m4a"
    end

    local function publish(source, name)
        local stem = name:sub(1, -5)
        local path = destination .. "/" .. name
        local suffix = 2
        local candidate = stem
        while hs.fs.symlinkAttributes(path) or (transcriptDir and
                hs.fs.symlinkAttributes(transcriptDir .. "/" .. candidate .. ".md")) do
            candidate = string.format("%s-%d", stem, suffix)
            path = destination .. "/" .. candidate .. ".m4a"
            suffix = suffix + 1
        end
        local linked, err = hs.fs.link(source, path)
        assert(linked, t("publish_copy_failed", {detail = err}))
        return path
    end

    local function exportOne(app, row, key)
        local description = row.AXDescription
        local audio = copiedAudio(app, row, description)
        local size = #audio
        if size > talkOver.maxBytes then
            local message = t("oversize_message", {name = description, size = string.format("%.1f", size / 1000000)})
            talkOver.logger.w(message)
            hs.notify.new({title = t("oversize_title"), informativeText = message}):send()
            return false
        end

        run.staging = destination .. "/.talkover-export-" .. hs.host.uuid()
        local created, mkdirError = hs.fs.mkdir(run.staging)
        assert(created, t("staging_create_failed", {detail = mkdirError}))
        local source = run.staging .. "/audio.m4a"
        run.stagedFile = source
        local file, openError = io.open(source, "wb")
        assert(file, t("audio_open_failed", {detail = openError}))
        local written, writeError = file:write(audio)
        local closed, closeError = file:close()
        audio = nil
        assert(written and closed, t("audio_write_failed", {detail = writeError or closeError}))

        assert(hs.fs.symlinkAttributes(source, "size") == size, t("audio_write_incomplete"))

        local name = exportName(source)
        local selected = currentRow(key)
        assert(selected and selected == row and isSelected(selected, hs.axuielement.applicationElement(app)),
            t("export_selection_changed"))
        local delete = assert(actionNamed(selected, deleteNames), t("delete_action_missing"))
        local path = publish(source, name)
        talkOver.logger.i(t("recording_exported", {path = path}))
        assert(selected:performAction(delete), t("delete_action_failed"))
        waitFor(8, t("deleted_row_still_present"), function()
            return currentRow(key) == nil
        end)
        return true
    end

    local function cleanStaging()
        if run.stagedFile then os.remove(run.stagedFile) end
        if run.staging then hs.fs.rmdir(run.staging) end
        run.staging, run.stagedFile = nil, nil
    end

    local function main()
        assert(hs.accessibilityState(), t("accessibility_required"))
        assert(hs.fs.attributes(destination, "mode") == "directory", t("recordings_dir_missing", {path = destination}))
        run.previousApp = hs.application.frontmostApplication()
        local focused = hs.window.focusedWindow()
        local owner = focused and focused:application()
        if owner and run.previousApp and owner:pid() == run.previousApp:pid() then
            run.previousWindow = focused
        end
        run.voiceApp = hs.application.get(voiceID)
        if run.voiceApp then
            local root = hs.axuielement.applicationElement(run.voiceApp)
            local window = root.AXFocusedWindow or root.AXMainWindow or (root.AXWindows or {})[1]
            if window and window.AXIdentifier == "SceneWindow" then
                -- Если Диктофон уже открыт поверх других приложений, даём закончить запись или правку.
                if not isLibraryReady(window) then return "busy" end
                moveWindowAside(window)
                run.usedDesktop = true
            end
        end
        run.usedDesktop = true
        assert(hs.application.launchOrFocusByBundleID(voiceID), t("voice_launch_failed"))
        local app = waitFor(10, t("voice_launch_timeout"), function() return hs.application.get(voiceID) end)
        run.voiceApp = app
        local window = voiceWindow()
        if not isLibraryReady(window) then return "busy" end
        moveWindowAside(window)
        allRecordings(app, window)

        while true do
            local row = recordingRows()[1]
            if not row then return end
            local key = rowKey(row)
            assert(currentRow(key) == row, t("source_row_unverified"))
            if not exportOne(app, row, key) then return end
            cleanStaging()
        end
    end

    local worker = coroutine.create(main)
    local function finish(status, message)
        if run.finished then return end
        run.finished = true
        if run.timer then run.timer:stop() end
        if run.task and run.task:isRunning() then run.task:terminate() end
        cleanStaging()
        if run.usedDesktop then
            local restored, err = pcall(restoreDesktop)
            if not restored then talkOver.logger.w(t("desktop_restore_failed", {detail = err})) end
        end
        done(status, message)
    end

    local function advance()
        local ok, result = coroutine.resume(worker)
        if not ok then
            finish("error", result)
        elseif coroutine.status(worker) == "dead" then
            finish(result or "done")
        else
            run.timer = hs.timer.doAfter(result, advance)
        end
    end

    function run:cancel()
        finish("cancelled")
    end

    run.timer = hs.timer.doAfter(0, advance)
    return run
end

return export
