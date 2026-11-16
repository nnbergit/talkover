# `talkover` • transcribe your [Voice Memos](https://apps.apple.com/us/app/voice-memos/id1069512134) automatically

## `problem` • You need to convert your memos into texts manually
To transcribe your Voice Memos, you have to follow these steps:
1. Save memos as .m4a files.
2. Convert .m4a files to a format which can be recognized by your transcription tool.
3. Transcribe each file.
4. Save the transcription into the place it should be.
5. Delete all media files and memos you do not need anymore.

Your life might be a bit easier without all this mess, eh?

## `preparation` • Get some tools you need to automate this routine
1. Install [`Hammerspoon`](https://www.hammerspoon.org) — the native macOS environment to automate almost anything on your Apple computer.
2. Install [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) — your local speech-to-text tool. To be precise, you need `whisper-cli`, which is included.
3. Download any [whisper model](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md) your computer can afford to run. 'ggml-large-v3-turbo-q5_0.bin' works great.
4. Make sure you have [`ffmpeg`](https://www.ffmpeg.org) installed — number one tool to manage any media files. You also need `ffprobe`, which is usually included in `ffmpeg`.
5. Organize — for example, somewhere in [Obsidian](https://obsidian.md/) — the place you will keep your transcribed talks safely.

Hammerspoon — whisper & its model — ffmpeg & ffprobe — (optional) Obsidian.

Congratulations, you are smart enough to configure your automatic voice-to-text system once and forever!

## `solution` • Install and configure the TalkOver Spoon

> [!tip]
> "Spoons" in Hammerspoon is just a term for plugins and extensions. \
> Now you know.

> [!warning]
> TalkOver **deletes** all your memos immediately. \
> The reason is if you need transcriptions, you probably do not need the original recordings.
> If you want to store all your media garbage, **stop immediately**.

1. Download the last [TalkOver release](https://github.com/nnbergit/talkover/releases): TalkOver.spoon.zip-file.
2. Extract it into your `~/.hammerspoon/Spoons/` folder.
3. Now you have the `~/.hammerspoon/Spoons/TalkOver.spoon` folder, so you are halfway there.
4. With any text editor, edit the `~/.hammerspoon/Spoons/TalkOver.spoon/config.lua` file.
    - `recordsDir` • The full path to the directory you want to use for temporary storage for `.m4a` audio files. We recommend creating and using `~/data/talkover` directory.
    - `transcriptsDir` • The full path to the directory where you want to keep all your text transcriptions. We **do** recommend using a directory inside your Obsidian vault.
    - `model` • The full path to the file of whisper's model. We use 'ggml-large-v3-turbo-q5_0.bin', and it works great.
5. With any text editor, add this line to the `~/.hammerspoon/init.lua` file: `hs.loadSpoon("TalkOver"):start()`.

Theoretically, everything should work from then on.

## `check` • How to be sure everything works fine?

The way is pretty simple.
1. Write any short voice memo.
2. Wait for about two minutes.
3. Check your `transcriptsDir` directory for a new .md-file.

We hope it works like magic. Or at least like usual robust software.

## `troubles` • If something goes wrong

The product state is in deep beta. Please, if anything went wrong, drop a message immediately: olgapavlova@gmail.com.