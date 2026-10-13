<p align="center">
  <img src="docs/icon.png" width="128" alt="The Refrain icon: the breath mark from sheet music">
</p>

<h1 align="center">Refrain</h1>

<p align="center"><b>Every word stays on your Mac.</b><br>
An open-source speech-to-text engine for macOS. It lives in the menu bar and turns audio into text on the Neural Engine. Any app on the Mac reaches it through the API it already knows, OpenAI's <code>POST /v1/audio/transcriptions</code>.</p>

<p align="center">macOS 26 or later · English and Russian · free, MIT · 0.1, see <a href="docs/PLAN.md">the plan</a></p>

There is no signed release yet: build it from source (below). Signed releases and Homebrew come with 1.0.

<p align="center">
  <img src="docs/media/menu.png" width="335" alt="The Refrain menu: transcribing 12:30 of 1:02:03, its address, Copy Address, Settings and Quit">
</p>

## Use it

Point any OpenAI-compatible client at `http://127.0.0.1:8178/v1`, with any model name and no key.

```sh
curl http://127.0.0.1:8178/v1/audio/transcriptions -F file=@call.m4a -F language=ru
# {"text":"Привет! Вчера я созвонился с Николаем…"}
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8178/v1", api_key="none")
with open("call.m4a", "rb") as f:
    print(client.audio.transcriptions.create(model="auto", file=f, response_format="verbose_json").segments)
```

- **`file`**: anything AVFoundation reads: m4a, mp3, wav, caf, mp4.
- **`language`**: ISO 639-1 (`ru`, `en`). It picks the engine. Without it, Parakeet detects the language if it's downloaded, otherwise Apple's model for the system language is used.
- **`prompt`**: names and terms in it (capitalized mid-sentence, or like `iPhone`, `MLX`) are passed to Apple's models as hints.
- **`response_format`**: `json`, `text` or `verbose_json` with segment timestamps.
- **`model`** is accepted and ignored. `GET /v1/models` lists one model, `auto`.

Requests run one at a time, in order. In **Reprise**, choose *Refrain (this Mac)* under Settings › Transcription. The port can be changed in Settings; Refrain never moves to another one on its own, since clients have it written down.

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
| Waiting in the menu bar | 0.07% (no timers; the socket waits) | 20 MB, 63 MB once Parakeet has been used |
| An hour of Russian through Parakeet | ~330% for 9 s | ~700 MB as the model loads, ~90 MB while it stays loaded |
| An hour of English through Apple SpeechTranscriber | ~17% for 38 s, plus macOS's speech service | +13 MB |

Memory is the physical footprint, as Activity Monitor shows it. The app is 13 MB. Parakeet stays loaded for five minutes after a request, then unloads. A long file is never read into memory whole: Apple's analyzer reads it a piece at a time, and FluidAudio converts it to 16 kHz into a temporary file.

## Privacy

- Refrain listens on `127.0.0.1` only. `Host` must be `127.0.0.1` or `localhost` (no DNS rebinding), a request with a web page's `Origin` is refused, and there are no CORS headers: web pages can't use it.
- The upload goes to a temporary file that is deleted once the response is sent; whatever a crash leaves behind is deleted at the next launch. No text is stored or logged: the log holds durations and processing times.
- The only network traffic is Parakeet's download, when you ask for it. Apple's language packs are downloaded by macOS.

## Build

Xcode 27:

```sh
open Refrain.xcodeproj          # or: xcodebuild -scheme Refrain build
swift test                       # server and engine tests, no models needed
xcodegen generate                # after editing project.yml (brew install xcodegen)
```

`Package.swift` holds `RefrainKit` (engines, choice by language, timestamps) and `RefrainServer` (HTTP). The app in `Refrain/` is the menu bar and settings around them. To sign with your own team, put `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in `Config/Local.xcconfig`. The README's screenshots come from a Debug build: `open --env REFRAIN_SNAPSHOTS=<folder> Refrain.app` shows each window and the menu in light and dark mode, captures them and quits (it needs the Screen Recording permission).

## License

MIT. The app bundles FluidAudio (Apache-2.0); Parakeet's weights are CC-BY-4.0. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
