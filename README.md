<p align="center">
  <img src="docs/icon.png" width="128" alt="The Refrain icon: a sound wave">
</p>

<h1 align="center">Refrain</h1>

<p align="center"><b>Every word stays on your Mac.</b><br>
An open-source speech-to-text engine for macOS. It lives in the menu bar and turns audio into text on the Neural Engine. Any app on the Mac reaches it through the API it already knows, OpenAI's <code>POST /v1/audio/transcriptions</code>.</p>

<p align="center">macOS 26 or later · English and Russian · free, MIT · 0.1</p>

Download it from [Releases](https://github.com/nikiomori/Refrain/releases/latest): open the zip and move Refrain.app to Applications. It's signed with Developer ID and notarized by Apple. Or build it from source (below).

<p align="center">
  <img src="docs/media/menu.png" width="335" alt="The Refrain menu: transcribing 12:30 of 1:02:03, its address, Copy Address, Settings and Quit">
</p>

## Focus

Refrain is not a general-purpose Whisper server. It does one job narrowly, and it is tuned first of all for [Pretype](https://github.com/nikiomori/pretype), which dictates, and [Reprise](https://github.com/nikiomori/reprise), which records calls: Pretype's live preview and spelling hints, Reprise's hour-long calls and the voices on them. Any other OpenAI-compatible client works too.

## Use it

Point any OpenAI-compatible client at `http://127.0.0.1:8178/v1`, with any model name and no key.

```sh
curl http://127.0.0.1:8178/v1/audio/transcriptions -F file=@call.m4a -F language=en
# {"text":"Hi! Yesterday I called Nikolai…"}
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8178/v1", api_key="none")
with open("call.m4a", "rb") as f:
    print(client.audio.transcriptions.create(model="auto", file=f, response_format="verbose_json").segments)
```

- **`file`**: anything AVFoundation reads: m4a, mp3, wav, caf, mp4.
- **`language`**: ISO 639-1 (`ru`, `en`). It picks the engine. Without it, Parakeet detects the language if it's downloaded, otherwise Apple's model for the system language is used. `languages[]`, as `gpt-transcribe` takes it, works too: the first one counts.
- **`prompt`** and **`keywords[]`**: the keywords, and the names and terms in the prompt (capitalized mid-sentence, or like `iPhone`, `MLX`), are passed as spelling hints to Apple's older model, the only engine that takes them. Apple's newer model spells names the same with hints or without, and Parakeet takes none.
- **`response_format`**: `json`, `text`, `srt`, `vtt` or `verbose_json`, with segment timestamps and, with `timestamp_granularities[]=word`, word timestamps. `diarized_json`, as OpenAI's `gpt-4o-transcribe-diarize` returns it, tells the voices apart: each phrase has a `speaker`, `A`, `B`… It needs the speaker model (22 MB, Settings › Models); without it the request gets a 400.
- **`model`**: `auto`, or any other name, transcribes on this Mac. A name from Settings › Services, like `groq/whisper-large-v3-turbo`, goes to that service instead ([below](#other-services)). `GET /v1/models` lists `auto` and those.

Requests run one at a time, in order; one whose client hangs up is dropped, running or waiting. The port can be changed in Settings; Refrain never moves to another one on its own, since clients have it written down.

### Connect your apps

- **[Reprise](https://github.com/nikiomori/reprise):** Settings › Transcription › Service › *Refrain (this Mac)*. When Refrain is running, Reprise offers it there itself. With each side saved on its own and the speaker model downloaded, the transcript says who spoke: you, or which of the others.
- **[Pretype](https://github.com/nikiomori/pretype):** Settings › API › *Use an API model for dictation* › Provider › *Refrain (this Mac)*. Pretype then dictates through Refrain's models instead of loading its own, with the live preview (it re-sends the take about once a second), and sends the names in the field as spelling hints.
- **Scripts on the OpenAI SDK** (Python, Node) read the server from the environment, so they run unchanged:
  ```sh
  export OPENAI_BASE_URL=http://127.0.0.1:8178/v1 OPENAI_API_KEY=refrain
  ```
  Only transcription is served: a chat request from the same script gets a 404.
- **Apps in Docker** (Open WebUI, LibreChat): base URL `http://host.docker.internal:8178/v1`.
- **Shortcuts, Spotlight and Siri:** the *Transcribe Audio File* action takes a file and gives back its text. In a shortcut that receives files from Quick Actions, it's in Finder's right-click menu.
- **Any other app** that lets you set an OpenAI-compatible or Whisper server: base URL `http://127.0.0.1:8178/v1`, any model name, any key or none. Some, like VoiceInk and Obsidian Whisper, want the full address: `http://127.0.0.1:8178/v1/audio/transcriptions`.

### Other services

Settings › Services adds another OpenAI-compatible service: OpenAI, Groq, Mistral, or any server with `POST /v1/audio/transcriptions`, with its address, key and models. Refrain then serves its models too, as `name/model`, and apps reach them through Refrain: one address for every app, and the key kept once, in the login Keychain, rather than in each of them.

```sh
curl http://127.0.0.1:8178/v1/audio/transcriptions -F file=@call.m4a -F model=groq/whisper-large-v3-turbo
```

The request goes on as it came, but for `model`, which becomes the service's own name for it, and the service's answer comes back as is, its errors included. These requests don't wait in the queue, which is for this Mac's engines, and the service's limits apply: file size, rate, formats.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/settings-general-dark.png">
  <img src="docs/media/settings-general-light.png" width="585" alt="Settings, General: open at login, the port, the address with a Copy button, and the status">
</picture>
</p>

## Engines

Picked by language, by measured error rate rather than by brand (FLEURS, Pretype's `Eval/asr`):

| Languages | Engine | Why |
|---|---|---|
| English, German, French, Spanish, Italian, Japanese, Korean, Portuguese, Chinese… | Apple SpeechTranscriber | System models, nothing to download for the app. On English it ties Parakeet (WER 7.8 vs 6.6) |
| Russian, Ukrainian, Polish, Czech and the rest of Parakeet's 25 European languages | Parakeet Ultra on the Neural Engine, 630 MB, downloaded only when you press *Download* | Russian as typed: WER 30.1 → 12.3, punctuation F1 0.02 → 0.85 |
| Every other language macOS dictates | Apple DictationTranscriber | It's there, though without punctuation: Apple's older model writes none for files, whatever it's asked |

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/settings-models-dark.png">
  <img src="docs/media/settings-models-light.png" width="585" alt="Settings, Models: Apple Speech and its languages, Parakeet downloaded with a Delete button and its languages, and Apple Dictation for the rest">
</picture>
</p>

Parakeet lives in FluidAudio's shared cache (`~/Library/Application Support/FluidAudio/Models`), so [Pretype](https://github.com/nikiomori/pretype) and Refrain download it once between them.

## Resources

Release build, MacBook Pro M4 Max:

| | CPU | Memory |
|---|---|---|
| Waiting in the menu bar | 0.005% (no timers; the socket waits) | 13.5 MB, ~15 MB after use once its engine has quit |
| An hour of Russian through Parakeet | ~340% for 8.5 s | in the engine, ~110 MB at most, ~95 MB while the model stays loaded |
| The same hour with voices told apart (`diarized_json`) | ~300% for 17 s | in the engine, ~630 MB at most, for a few seconds |
| An hour of English through Apple SpeechTranscriber | ~30% for 10 s, plus macOS's speech service | +13 MB |

Memory is the physical footprint, as Activity Monitor shows it. The app is 24 MB. The menu bar item and the windows are AppKit's own; SwiftUI draws the windows' contents, loaded when one opens. The engines run in a process of their own, RefrainEngine, which macOS starts at the first request and which quits after five idle minutes: what the models and CoreML leave behind goes with it, rather than staying in the app (25–50 MB of it otherwise), and a crash in them fails one request instead of stopping the server. The first request after it has quit takes ~0.3 s longer. Parakeet and the speaker model run on the Neural Engine, never the GPU. A long file is never read into memory whole: Apple's analyzers get it a piece at a time, as they ask for it, and Parakeet and the speaker model get it converted once to 16 kHz mono, every channel mixed in, in a temporary file. A file longer than a minute is shared among up to four of Apple's analyzers at once, cut at quiet moments: nearly four times as fast, with the same accuracy. After an update of macOS, Refrain loads Parakeet once in the background, so the first request doesn't wait the ~11 s it takes the Neural Engine to compile it.

## Privacy

- Refrain listens on `127.0.0.1` only. `Host` must be `127.0.0.1`, `localhost` or Docker's `host.docker.internal` (no DNS rebinding), a request with a web page's `Origin` is refused, and there are no CORS headers: web pages can't use it.
- The upload goes to a temporary file that is deleted once the response is sent; whatever a crash leaves behind is deleted at the next launch. No text is stored or logged: the log holds durations and processing times.
- The only network traffic is Parakeet's and the speaker model's downloads, when you ask for them, and the requests that name another service's model (Settings › Services), which go to that service with its key. Apple's language packs are downloaded by macOS.

## Build

Xcode 27:

```sh
open Refrain.xcodeproj          # or: xcodebuild -scheme Refrain build
swift test                       # server and engine tests, no models needed
```

`Package.swift` holds `RefrainKit` (engines, choice by language, timestamps) and `RefrainServer` (HTTP). The app in `Refrain/` is the menu bar and settings around them; `Engine/` is its XPC service, where the engines run. To sign with your own team, put `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in `Config/Local.xcconfig`.

## License

MIT. The app bundles FluidAudio (Apache-2.0); Parakeet's weights are CC-BY-4.0. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
