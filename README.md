# OpenWhisperFlow

A small macOS menu bar app for push-to-talk dictation. Hold a key, speak,
release — the text is transcribed locally and pasted into whatever you were
typing into.

Transcription runs on-device and in English. You pick the engine: macOS's own
built-in speech recognition, Whisper through CoreML, or Moonshine through ONNX
Runtime. No audio leaves the machine, there is no account, and there is no usage
limit.

## How it works

- **Hold to talk.** Hold the trigger key (Fn / Globe by default) and speak.
  Release to transcribe.
- **Double-tap to toggle.** Double-tap the trigger to keep recording hands-free;
  a single tap stops it.
- **Keeps recording across apps.** The key is watched with a session-wide event
  tap owned by this process, not by a window, so switching apps mid-sentence
  does not interrupt the recording.
- **Pastes where you were typing.** The transcript goes to the clipboard and is
  inserted with a synthetic Command-V. The app never takes keyboard focus, so
  the keystroke lands in the app you were already using.
- **Tells you what happened.** A floating pill shows a live input meter while
  recording and confirms when the text has been copied and pasted.
- **Lives in the menu bar.** A waveform icon sits with Wi-Fi and battery. It
  turns into a red microphone while recording, and its menu has just two
  entries: *Preferences…* and *Quit*. Launching the app again also reopens
  Preferences, which matters when the menu bar is full — see
  [The menu bar icon is missing](#the-menu-bar-icon-is-missing).

Everything above is configurable, including the trigger key (any key or
modifier, left and right sides told apart), the activation mode, timings, and
the model.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- A Swift toolchain. The Command Line Tools are enough to **build** the app;
  running the test suite additionally needs Xcode, because swift-testing and
  XCTest ship inside it.

## Install

```sh
brew install --cask sumitjha4321/tap/openwhisperflow
```

Apple silicon, macOS 14 or later. Then launch it, grant Microphone and
Accessibility access when asked, and download a model from
**Settings → Model**.

To remove it, including preferences and downloaded models:

```sh
brew uninstall --zap --cask openwhisperflow
```

## Build from source

```sh
./Scripts/fetch-onnxruntime.sh   # downloads the ONNX Runtime dylib into vendor/
./Scripts/make-app.sh            # builds dist/OpenWhisperFlow.app
```

Then drag `dist/OpenWhisperFlow.app` to `/Applications` and launch it.

On first launch the app asks for two permissions and opens its settings window:

| Permission | Why |
| --- | --- |
| **Microphone** | To record your voice. |
| **Accessibility** | To notice the trigger key in any app, and to send the Command-V that inserts the text. |

Finally, open **Settings → Model** and download a model. The default,
*Moonshine Base (quantized)*, is about 63 MB.

### The menu bar icon is missing

macOS decides where to put a status item, and on a display with a notch it can
place one *behind* the notch and then not draw it at all. The app has no say in
this — there is no API to request a position — and from the app's side
everything looks fine: the item reports `isVisible = true` and has a real
window, it is simply never composited.

To check whether this is what is happening, compare the item's position with the
centre of the display. On a 1728-point-wide screen the notch covers roughly
x = 764…964, so an item at x = 865 is hidden underneath it.

The cause is a full menu bar: when the right-hand side is packed, the only gap
left is the middle, which is where the notch is. Freeing a few slots in
**System Settings → Control Center** (set items you do not need to *Don't Show
in Menu Bar*) moves the icon right, out from under the notch.

Two ways in that do not depend on menu bar space:

- **Launch the app again** — double-click `OpenWhisperFlow.app`, or
  `open -a OpenWhisperFlow`. It is already running, so instead of starting a
  second copy it reopens Preferences.
- **Turn on Preferences → Appearance → "Show an icon in the Dock"**, and click
  the Dock icon.

### Signing and the Accessibility grant

macOS keys the Accessibility grant to the app's code signature, so
`Scripts/make-app.sh` signs with a `Developer ID Application` certificate if
your keychain has one, and an `Apple Development` certificate otherwise. That
makes the signature identity stable across rebuilds and the permission sticks.

Developer ID is preferred because releases are signed with it. A dev build and
the installed release share one Accessibility toggle, but the grant only
matches the certificate it was made for — so a dev build signed with a
different certificate leaves the other copy untrusted while the toggle still
reads "on".

Without a certificate the script falls back to an ad-hoc signature, which
changes on every build — macOS then forgets the grant each time. Either way, if
the toggle ever looks stuck, clear it and grant again:

```sh
tccutil reset Accessibility app.openwhisperflow
```

Both release and development builds are signed with the hardened runtime and
`Scripts/OpenWhisperFlow.entitlements`, because notarisation requires it. The
hardened runtime blocks microphone access unless the app asks for it, which is
all that file does; the Accessibility event tap needs no entitlement, only the
user's grant. Keeping dev builds identical means a permission problem the
hardened runtime causes shows up locally rather than only in a notarised build.

Set `SIGN_IDENTITY` to choose a specific certificate:

```sh
SIGN_IDENTITY="Apple Development: you@example.com (ABCDE12345)" ./Scripts/make-app.sh
```

## Speech models

Pick one in **Preferences → Model**. Each is described by how big the download
is and how accurate it is, because that is the trade-off that actually matters.

| Model | Download | Accuracy | Notes |
| --- | --- | --- | --- |
| **Apple Dictation** | None | Best | The recognition built into macOS. Nothing to download. Needs macOS 26. |
| **Whisper Small** | 480 MB | Best | Best fully-offline choice; also runs on older macOS. |
| **Whisper Base** | 145 MB | Very good | A middle ground. |
| **Moonshine Base** | 63 MB | Good | Small and quick; more mistakes on names and technical words. |
| **Moonshine Tiny** | 28 MB | Basic | Smallest and fastest. |

All of these are English models. Multilingual builds are deliberately left out:
at a given size they are larger and slightly weaker on English than an
English-only model. Apple's engine follows your region within English, so
`en_IN` or `en_GB` is used where the system has it rather than defaulting to
`en_US`.

### Measured on this machine

19 seconds of ordinary English prose, scored as word error rate against the
known text. Times are after the model is warm.

| Model | Word error rate | Transcribe time |
| --- | --- | --- |
| Apple Dictation | 0.0% | 0.30 s |
| Whisper Small | 0.0% | 1.5 s |
| Whisper Base | 1.5% | 0.65 s |
| Moonshine Base | 6.2% | 0.46 s |

Two caveats worth knowing. These figures come from synthesised speech, which is
easier than a real voice in some ways and harder in others — treat them as a
rough ordering, not a promise. And every engine tested here mis-heard unusual
proper nouns such as "Kubernetes" and "ONNX", so none of them is reliable on
jargon regardless of size.

Whisper models are downloaded from
[`argmaxinc/whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml)
and Moonshine from
[`moonshine-ai/moonshine`](https://huggingface.co/moonshine-ai/moonshine), both
into `~/Library/Application Support/OpenWhisperFlow/`. Apple's engine has no
download — macOS manages its own language assets.

Recordings longer than 24 s are split at the quietest nearby moment when using
Moonshine, whose decoder has a fixed position limit; Whisper and Apple's engine
handle long audio themselves.

## Development

```sh
swift build                      # build everything
./Scripts/test.sh                # unit tests (36 tests, 6 suites)
swift run mstest <model-dir> <audio.wav>   # transcribe a WAV, no permissions needed
```

`Scripts/test.sh` is a thin wrapper over `swift test`. It exists because
swift-testing lives inside Xcode, so the tests need the active developer
directory to point there; the script finds Xcode itself rather than making you
run `sudo xcode-select -s`. If `xcode-select -p` already points at Xcode, plain
`swift test` works.

If the trigger key or a permission is misbehaving, ask the app what it can see.
Run the binary **inside the bundle** — permissions are granted to the signed
app, so a copy under `.build` reports a different, untrusted identity:

```sh
dist/OpenWhisperFlow.app/Contents/MacOS/OpenWhisperFlow --diagnose
```

```
  accessibility       yes
  microphone          yes
  trigger key         Fn (Globe) (key code 63, modifier: yes)
  model installed     yes
  model loads         yes — Moonshine(layers: 8, heads: 8, headDim: 52)
```

`--settings` opens the settings window straight away, without going via the
menu bar item.

`--transcribe` runs a WAV through whichever engine is selected, using the same
code path as dictation — handy for checking an engine without recording:

```sh
dist/OpenWhisperFlow.app/Contents/MacOS/OpenWhisperFlow --transcribe /tmp/hello.wav
```

`mstest` does the same for Moonshine only, without needing a bundle:

```sh
say -o /tmp/hello.wav --data-format=LEI16@16000 "Testing one two three."
swift run mstest \
  ~/Library/Application\ Support/OpenWhisperFlow/models/moonshine-base-quantized \
  /tmp/hello.wav
```

### Cutting a release

`brew install --cask` only works if Apple has notarised the app: Homebrew
quarantines everything it downloads, and Gatekeeper will not open a quarantined
app it cannot verify. Notarisation needs a paid Apple Developer account and a
**Developer ID Application** certificate — the free *Apple Development*
certificate that `make-app.sh` falls back to cannot be notarised, and is only
trusted on machines enrolled for development.

Store the notarisation credentials once:

```sh
xcrun notarytool store-credentials openwhisperflow \
    --apple-id you@example.com --team-id TEAMID \
    --password <app-specific-password>   # from appleid.apple.com
```

Then each release is one command:

```sh
NOTARY_PROFILE=openwhisperflow ./Scripts/release.sh 0.2.0
```

It builds, signs with a secure timestamp, submits to Apple, staples the ticket
into the bundle, and writes two things to `dist/`: the zip a cask downloads and
`openwhisperflow.rb`, the cask itself with the url, version and checksum already
filled in. Run it without credentials and it still produces both, but says
plainly that the result will not install through a tap.

The zip is made with `ditto`, not `zip`: only `ditto` preserves the symlinks and
extended attributes inside a bundle, and a `zip(1)` archive of an `.app` can
arrive with a broken signature.

The script prints the remaining steps — tag, `gh release create`, and copying the
cask into the tap.

### The tap

Homebrew's own cask repository takes only applications with demonstrable public
interest, so this ships from its own tap: a GitHub repository named
`homebrew-tap`, which is what lets `sumitjha4321/tap` resolve.

```
homebrew-tap/
└── Casks/
    └── o/
        └── openwhisperflow.rb
```

The `o/` subdirectory is Homebrew's convention — casks are filed under their
first letter. Push a new `openwhisperflow.rb` there and every user picks it up
on their next `brew update`.

Only the app binary is arm64-only, not the source. An Intel or universal build
would mean a second artefact and `on_arm` / `on_intel` blocks in the cask, each
with its own url and `sha256`.

### Layout

| Path | Contents |
| --- | --- |
| `Sources/COnnxRuntime` | Module map exposing the ONNX Runtime C API to Swift. |
| `Sources/MoonshineKit` | Moonshine inference: ORT wrapper, decode loop, tokenizer, audio helpers, model downloader. |
| `Sources/TranscriptionEngines` | The engine protocol, the model catalog, and the Apple / Whisper / Moonshine engines. |
| `Sources/DictationCore` | Trigger timing rules and preferences. No AppKit, so it is unit testable. |
| `Sources/OpenWhisperFlow` | The app: event tap, recorder, overlay, menu bar, settings. |
| `Tools/mstest` | Command-line transcriber. |
| `Tests/` | Unit tests for the trigger rules, audio helpers, and tokenizer. |
| `Scripts/GenerateIcon.swift` | Draws the app icon; run by `make-app.sh`. |

### Notes on a few deliberate choices

**Three engines behind one protocol.** `TranscriptionEngine` takes 16 kHz mono
audio and returns text; everything model-specific (CoreML compilation, mel front
ends, tokenizers, chunking) stays inside each engine. Whisper goes through
WhisperKit rather than ONNX Runtime because CoreML puts it on the Neural Engine —
Whisper Small on the CPU would be far too slow for dictation.

**The ONNX Runtime C API, not the official Swift package.** That package exposes
only ONNX Runtime's Objective-C API, which has no Bool tensor type. Moonshine's
merged decoder selects its cache branch with a Bool `use_cache_branch` input, so
the C API is used directly through a module map.

**The cross-attention cache is captured once.** The merged decoder computes
encoder (cross-attention) key/values only on its no-cache branch, i.e. the first
decode step. Later steps return empty placeholders for those outputs, so the
first step's values are held and reused for the rest of the decode. Feeding the
placeholders back instead produces a shape error deep inside the graph.

**Decoding needs no merge table.** Moonshine's tokenizer is a LLaMA-style BPE,
but turning ids back into text only requires the id→token map plus the decode
pipeline (`▁`→space, byte fallback, fuse, strip one leading space). The 3.7 MB
`tokenizer.json` is read for its vocabulary alone.

**Model geometry is read from the model.** Layer count, head count and head
dimension come from the decoder's declared input shapes, so the same code runs
tiny (6 layers, head dim 36) and base (8 layers, head dim 52) with no
per-variant configuration.

**The settings window is sized explicitly.** `NSWindow(contentViewController:)`
does not adopt a SwiftUI hosting controller's fitting size, and a root view
constrained only in width gets a zero-height layout — which renders the tab bar
and nothing else. The root view constrains both dimensions and the window sets
its own content size.

**Preferences decode field by field.** Swift's synthesised `Decodable` treats a
missing key as an error and fails the entire decode, so the first time a new
field is added to `Preferences` every previously saved setting would be thrown
away and silently replaced by defaults. `init(from:)` reads each field with a
fallback instead, which keeps older settings files loadable and stops one
corrupted value from discarding the rest.

**The app icon is generated, not committed.** An app with no icon shows as a
blank generic item in System Settings' privacy lists, which makes it awkward to
identify when granting Accessibility.

**Audio is buffered before recording is confirmed.** The microphone opens on key
*down*, before the hold delay has decided whether this is real dictation, and a
0.3 s pre-roll is kept. That way a word spoken as the key goes down is not
clipped. A press too short to count is discarded and the microphone released.

**The trigger rules are tested on a manual clock.** `TriggerRecognizer` holds
the hold/double-tap state machine and takes its delay scheduler as an injectable
closure, so the tests drive timing directly instead of sleeping. It lives in
`DictationCore`, which has no AppKit dependency, so none of this needs a window
server or system permissions.

## Licence

The app code here is available under the MIT licence. Moonshine models are
published by Moonshine AI under the MIT licence; ONNX Runtime is MIT licensed.
