local obj = {}
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

local function menuCommand(root, menuID, commandID, shortcut)
    local menu = find(root.AXMenuBar, function(element)
        return element.AXIdentifier == menuID
    end, 2)
    return (commandID and find(menu, function(element)
        return element.AXRole == "AXMenuItem" and element.AXEnabled
            and element.AXIdentifier == commandID
    end, 2)) or find(menu, function(element)
        return element.AXRole == "AXMenuItem" and element.AXEnabled and shortcut(element)
    end, 2)
end

local function press(element)
    return element and element:performAction("AXPress")
end

local function foldersList(window)
    return find(window, function(element) return element.AXIdentifier == "FoldersList" end, 8)
end

local function isLibraryReady(window)
    if not window then return false end
    local editing = find(window, function(element)
        local id = element.AXIdentifier
        return element.AXEnabled ~= false and (id == "RecordingView/DoneButton"
            or id == "RecordingView/ApplyButton" or id == "RecordingView/CancelButton")
    end, 10)
    if editing then return false end
    -- The Record button is available even when the library is empty.
    return find(window, function(element)
        return element.AXRole == "AXButton" and element.AXIdentifier == "RecordButton"
            and element.AXEnabled == true
    end, 10) ~= nil
end

local function canNavigateLibrary(window)
    return isLibraryReady(window) or find(window, function(element)
        return element.AXIdentifier == "FolderView/RecoverButton"
    end, 10)
end


function obj:init(config, logger, translate)
    self.config = config
    self.logger = logger
    self.i18n = translate
end

function obj:isRunning()
    return self.run ~= nil
end

function obj:start()
    if self.run then return end
    local config = self.config
    local logger, i18n = self.logger, self.i18n
    local destination = config.recordsDir
    local transcriptDir = config.transcriptsDir
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
        end, args), i18n("tool_start_failed", {tool = executable}))
        assert(run.task:start(), i18n("tool_start_failed", {tool = executable}))
        waitFor(timeout, i18n("tool_timeout", {tool = executable}), function() return result end)
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
        return waitFor(10, i18n("voice_window_missing"), function()
            local window = frontWindow(voiceID)
            if window and window.AXIdentifier == "SceneWindow" then return window end
        end)
    end

    local function toggleSidebar(root)
        return press(menuCommand(root, "com.apple.menu.view", nil, function(item)
            return item.AXMenuItemCmdChar == "S" and item.AXMenuItemCmdModifiers == 4 -- Control-Command-S
        end))
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
        if tookFocus and run.openedSidebar and foldersList(frontWindow(voiceID)) then
            toggleSidebar(hs.axuielement.applicationElement(voice))
        end
        if voice and (run.voiceApp or tookFocus) then
            if not voice:hide() then
                logger.w(i18n("voice_hide_failed"))
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
        local root = hs.axuielement.applicationElement(app)
        local list = foldersList(window)
        if not list then
            assert(toggleSidebar(root), i18n("sidebar_missing"))
            list = waitFor(4, i18n("sidebar_missing"), function() return foldersList(frontWindow(voiceID)) end)
            run.openedSidebar = true
        end
        -- Voice Memos places All Recordings first in FoldersList.
        local button
        for _, child in ipairs(list.AXChildren or {}) do
            if child.AXRole == "AXButton" then
                button = child
                break
            end
        end
        assert(button, i18n("all_folder_missing"))
        if not button.AXSelected then assert(press(button), i18n("all_folder_open_failed")) end
        waitFor(5, i18n("all_folder_switch_failed"), function()
            return button.AXSelected and isLibraryReady(frontWindow(voiceID))
        end)
        run.allFolder = button
    end

    local function recordingRows()
        local window = frontWindow(voiceID)
        assert(isLibraryReady(window) and run.allFolder.AXSelected, i18n("all_list_unavailable"))
        local list = find(window, function(element) return element.AXIdentifier == "RecordingsList" end, 10)
        if not list then return {} end

        local rows = {}
        for _, element in ipairs(list.AXChildren or {}) do
            if element.AXRole == "AXButton" then
                rows[#rows + 1] = element
            end
        end
        return rows
    end

    local function rowKey(row)
        local description = row.AXDescription
        assert(type(description) == "string" and description ~= "", i18n("row_without_description"))
        return description .. "\n" .. tostring(row.AXValue or "")
    end

    local function currentRow(key)
        local rows = recordingRows()
        local result
        for _, row in ipairs(rows) do
            if rowKey(row) == key then
                assert(not result, i18n("duplicate_row", {name = key}))
                result = row
            end
        end
        return result
    end

    local function isFocusedRecording(row, root)
        return frontWindow(voiceID) and row.AXSelected and root.AXFocusedUIElement == row
    end

    local function copiedAudio(root, row)
        assert(isLibraryReady(frontWindow(voiceID)), i18n("voice_busy"))
        if not row.AXSelected then assert(press(row), i18n("select_recording_failed")) end
        waitFor(5, i18n("select_recording_failed"), function()
            if not frontWindow(voiceID) or not row.AXSelected then return end
            if not isFocusedRecording(row, root) then row:setAttributeValue("AXFocused", true) end
            return isFocusedRecording(row, root)
        end)
        local copy = waitFor(5, i18n("copy_unavailable"), function()
            if not isFocusedRecording(row, root) then return end
            -- The active Copy command can have an identifier derived from its translated title.
            return menuCommand(root, "com.apple.menu.edit", "copy:", function(item)
                return item.AXMenuItemCmdChar == "C" and item.AXMenuItemCmdModifiers == 0 -- Command-C
            end)
        end)

        local before = pasteboard.changeCount()
        local saved = pasteboard.readAllData() or {}
        assert(pasteboard.changeCount() == before, i18n("clipboard_changed"))
        assert(isFocusedRecording(row, root), i18n("selection_changed"))
        assert(press(copy), i18n("copy_command_failed"))
        local result = waitFor(12, i18n("clipboard_audio_missing"), function()
            local count = pasteboard.changeCount()
            if count == before then return end
            assert(isFocusedRecording(row, root), i18n("selection_changed"))
            local audio = pasteboard.readDataForUTI(audioType)
            if audio and #audio > 0 and pasteboard.changeCount() == count then
                return {count = count, audio = audio}
            end
        end)

        if pasteboard.changeCount() == result.count then
            if next(saved) then
                if not pasteboard.writeAllData(saved) then
                    logger.w(i18n("clipboard_restore_failed"))
                end
            else
                pasteboard.clearContents()
            end
        end
        return result.audio
    end

    local function exportName(source)
        local code, metadata = task(config.ffprobe, {
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

        logger.w(i18n("audio_creation_date_missing"))
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
        assert(linked, i18n("publish_copy_failed", {detail = err}))
        return path
    end

    local function exportOne(app, row, key)
        local root = hs.axuielement.applicationElement(app)
        local audio = copiedAudio(root, row)
        local size = #audio
        if size > config.maxBytes then
            local message = i18n("oversize_message", {name = row.AXDescription, size = string.format("%.1f", size / 1000000)})
            logger.w(message)
            hs.notify.new({title = i18n("oversize_title"), informativeText = message}):send()
            return false
        end

        run.staging = destination .. "/.talkover-export-" .. hs.host.uuid()
        local created, mkdirError = hs.fs.mkdir(run.staging)
        assert(created, i18n("staging_create_failed", {detail = mkdirError}))
        local source = run.staging .. "/audio.m4a"
        run.stagedFile = source
        local file, openError = io.open(source, "wb")
        assert(file, i18n("audio_open_failed", {detail = openError}))
        local written, writeError = file:write(audio)
        local closed, closeError = file:close()
        audio = nil
        assert(written and closed, i18n("audio_write_failed", {detail = writeError or closeError}))

        assert(hs.fs.symlinkAttributes(source, "size") == size, i18n("audio_write_incomplete"))

        local name = exportName(source)
        local selected = currentRow(key)
        assert(selected and selected == row and isFocusedRecording(selected, root),
            i18n("export_selection_changed"))
        local delete = assert(menuCommand(root, "com.apple.menu.edit", "delete:", function(item)
            return item.AXMenuItemCmdChar == "\b" and item.AXMenuItemCmdModifiers == 8 -- Delete without Command
        end), i18n("delete_action_missing"))
        local path = publish(source, name)
        run.exported = true
        logger.i(i18n("recording_exported", {path = path}))
        assert(isFocusedRecording(selected, root), i18n("export_selection_changed"))
        assert(press(delete), i18n("delete_action_failed"))
        waitFor(8, i18n("deleted_row_still_present"), function()
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
        local session = hs.caffeinate.sessionProperties()
        if not session or session.CGSSessionScreenIsLocked or session.kCGSSessionOnConsoleKey == false then
            return "unavailable"
        end

        assert(hs.accessibilityState(), i18n("accessibility_required"))
        assert(hs.fs.attributes(destination, "mode") == "directory", i18n("recordings_dir_missing", {path = destination}))
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
            if window then
                if window.AXIdentifier ~= "SceneWindow" or not canNavigateLibrary(window) then return "busy" end
                moveWindowAside(window)
                run.usedDesktop = true
            end
        end
        run.usedDesktop = true
        assert(hs.application.launchOrFocusByBundleID(voiceID), i18n("voice_launch_failed"))
        local app = waitFor(10, i18n("voice_launch_timeout"), function() return hs.application.get(voiceID) end)
        run.voiceApp = app
        local window = voiceWindow()
        if not canNavigateLibrary(window) then return "busy" end
        moveWindowAside(window)
        allRecordings(app, window)

        while true do
            local row = recordingRows()[1]
            if not row then return end
            local key = rowKey(row)
            assert(currentRow(key) == row, i18n("source_row_unverified"))
            if not exportOne(app, row, key) then return end
            cleanStaging()
        end
    end

    local worker = coroutine.create(main)
    local function finish(status)
        if run.finished then return end
        run.finished = true
        if run.timer then run.timer:stop() end
        if run.task and run.task:isRunning() then run.task:terminate() end
        cleanStaging()
        if run.usedDesktop then
            local restored, err = pcall(restoreDesktop)
            if not restored then logger.w(i18n("desktop_restore_failed", {detail = err})) end
        end
        self.run = nil
        if self.onFinished then self.onFinished(status, run.exported == true) end
    end

    local function advance()
        local ok, result = coroutine.resume(worker)
        if not ok then
            logger.w(i18n("export_stopped", {detail = result}))
            finish("error")
        elseif coroutine.status(worker) == "dead" then
            finish(result or "done")
        else
            run.timer = hs.timer.doAfter(result, advance)
        end
    end

    function run.cancel()
        finish("cancelled")
    end

    self.run = run
    run.timer = hs.timer.doAfter(0, advance)
end

function obj:stop()
    if self.run then self.run.cancel() end
end

return obj
