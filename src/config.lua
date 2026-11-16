--- TalkOver.config
--- Variable
--- Settings loaded from the bundled `config.lua` when TalkOver is initialized.
---
--- Notes:
---  * `locale` selects the interface language (`en` or `ru`). If omitted, TalkOver uses the preferred macOS language when available and English otherwise.
---  * `language` sets the Whisper language code or `auto`. If omitted, TalkOver uses the selected interface language.
---  * `ffmpeg`, `ffprobe`, and `whisper` optionally specify absolute executable paths. Otherwise TalkOver searches the user's shell PATH for `ffmpeg`, `ffprobe`, and `whisper-cli`.
---  * `maxBytes` sets the maximum size of a recording exported from Voice Memos, in bytes. The default is 100 MB.
---  * `recordsDir` is the folder for exported audio and other `.m4a` files to transcribe.
---  * `transcriptsDir` is the folder where TalkOver saves Markdown transcripts.
---  * `model` is the path to a local [whisper.cpp model](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md).

local home = os.getenv("HOME")

return {
    -- locale = "en", -- Omit to use the macOS language
    -- Set ffmpeg, ffprobe or whisper to an absolute path to override PATH lookup.
    -- language = "en", -- Whisper language code or "auto"; omit to use the interface language.
    maxBytes = 100 * 1000 * 1000,
    recordsDir = home .. "/data/talkover",
    transcriptsDir = home .. "/vaults/public/> transcript",
    -- Download model from https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md
    model = home .. "/data/models/whisper/ggml-large-v3-turbo-q5_0.bin",
}
