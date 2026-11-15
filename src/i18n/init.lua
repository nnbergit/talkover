return function(directory, primaryLanguage, configuredLocale)
    local function loadCatalog(locale)
        if type(locale) == "string" and locale:match("^[A-Za-z][A-Za-z0-9%-]*$") then
            return loadfile(directory .. locale .. ".lua", "t")
        end
    end

    local fallback = dofile(directory .. "en.lua")
    local catalog = fallback

    local function translate(key, values)
        local message = assert(catalog[key] or fallback[key], "Missing TalkOver message: " .. key)
        if not values then return message end
        return (message:gsub("%%{([%w_]+)}", function(name)
            return tostring(values[name])
        end))
    end

    local locale = configuredLocale
    if locale == nil and primaryLanguage then
        locale = primaryLanguage:lower():match("^[a-z]+")
    end
    if locale ~= nil and locale ~= "en" then
        local chunk, detail = loadCatalog(locale)
        local messages = chunk and chunk()
        if type(messages) == "table" then
            catalog = messages
        elseif configuredLocale ~= nil then
            error(translate("locale_unavailable", {locale = locale, detail = detail or "—"}), 2)
        end
    end

    return translate
end
