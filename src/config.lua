local home = os.getenv("HOME")

return {
    -- locale = "en", -- "ru" or "en"; omit to use the macOS language.
    voiceMemosDir = home .. "/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
    maxBytes = 100 * 1000 * 1000,
    exportDelay = 4,
    scanDelay = 1,
    scanInterval = 60 * 60, -- Scheduled audio-folder scan, in seconds.
    ffmpeg = "/opt/homebrew/bin/ffmpeg",
    ffprobe = "/opt/homebrew/bin/ffprobe",
    whisper = "/opt/homebrew/bin/whisper-cli",
    language = "ru", -- Whisper language code (e.g. "ru", "en", "de") or "auto".
    recordsDir = home .. "/data/talkover",
    transcriptsDir = home .. "/vaults/public/> transcript",
    model = home .. "/data/models/whisper/ggml-large-v3-turbo-q5_0.bin",
}
