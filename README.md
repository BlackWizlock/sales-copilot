# Axis Copilot

A local-first macOS meeting assistant by [Axis Consult](https://axisconsult.ru).
Record meetings, transcribe locally, prepare meeting notes and sales suggestions,
and connect your own Bitrix24 account. No subscription is required for local
features. This is alpha software; review generated facts against the recording.

## Requirements and build

macOS 15 or later, Apple Silicon. Developers need Swift 6 / Command Line Tools
and Homebrew. End users use the packaged application and download models in its settings.

```sh
brew install whisper.cpp coreutils ffmpeg
bash scripts/setup-model.sh
bash scripts/setup-signing.sh
bash scripts/build-app.sh
```

The app is written to `_output/AxisCopilot.app`. Install it in Applications.
Your signing identity stays in Keychain. Source builders must configure their
own signing identity and update feed. Alpha signing is not Apple notarization.

## Meeting workflow

1. Grant microphone and screen/system-audio access when macOS asks.
2. Choose the meeting application, or explicitly capture all application audio.
3. Connect your own Bitrix24 account and select a deal or calendar event. Drop
   reference documents into Meeting materials, or click the drop zone to choose
   multiple files. Materials can be contracts, requirements, proposals, slides,
   tables or other reference documents. Joining a link does not start recording.
4. Start recording explicitly. Audio is saved in recoverable chunks and transcribed
   locally. The meeting window hides after a successful start; a draggable floating
   recording indicator shows live audio levels. Click it for the timer, both audio
   sources, Open meeting and Stop controls. A failed start keeps the error visible.
   Automatic suggestions require a downloaded local language model. New hints
   appear in the meeting view and expand the floating panel, with the client
   phrase, a verified source excerpt and the material filename.
5. Stop recording and wait for queued transcription. Review notes, transcript,
   speaker assignments and playback. Review each CRM export before sending it.

The sidebar separates Meetings and a month Calendar. Select a day to see its events,
join a verified Zoom/Telemost link, or prepare a new recording from the linked deal.
Meeting tabs are Summary, Transcript and Chat. Chat answers cite transcript phrases;
click a citation to play the recording from that point. Settings open in a separate
native window with categories, normal close/minimize controls and Escape to close.

Material import supports PDF, TXT, Markdown, CSV/TSV, JSON, DOC/DOCX, RTF,
HTML, PPTX, XLSX and PNG/JPEG/TIFF/HEIC images. Scanned PDF pages and images use
local Russian/English OCR. Import extracts text; original layout, charts and
formulas are not interpreted. Limits: 12 files, 20 MB and 60,000 characters per
file, 240,000 characters per meeting. Unsupported or unreadable files produce
an explicit error and leave existing materials intact.

Speaker names are assigned manually after local voice grouping. Browser capture
can include other tabs. Headphones are recommended; echo quality must be checked
with your devices. Updating does not repair previously recorded audio.

## Models and languages

Settings provide local ASR model selection, downloads and verification. Parakeet
TDT 0.6B v3 and multilingual Whisper models use different local engines. UI
language and recognition language are separate settings. Russian and English
resources live under `Resources/*.lproj`.

Meeting summaries, chat and live sales hints use your selected OpenRouter model.
Enable it in Settings, save your own API key, choose a model and set a daily budget.
Cloud processing sends meeting text, selected materials and deal context; enable it
only for data you are allowed to send. Audio stays local. The app never starts or
downloads a local language model. Recording and ASR work without an API key.

## Privacy and credentials

Meetings live in `~/Library/Application Support/AxisSalesCopilot/Meetings`.
Recordings, transcripts, reference documents and CRM snapshots are private runtime data.
Do not commit them. Credentials belong in macOS Keychain, not source, logs or
update archives. Build environment names are documented in [DEVELOPMENT.md](docs/DEVELOPMENT.md#environment-and-credentials).

MCP access is opt-in per meeting. A cloud agent can forward text outside the Mac.
CRM exports are explicit actions and do not silently change deal stages or amounts.
See [SECURITY.md](SECURITY.md).

## Development and releases

```sh
bash scripts/ci-local.sh
python3 scripts/check-localizations.py
```

Tests use synthetic data. File tests do not establish live Zoom/Telemost echo
quality, speaker accuracy, or permissions on your CRM account. Evidence and limits:
[docs/TESTING.md](docs/TESTING.md).

Signed archives and manifests are served over HTTPS. Clients notify users about
newer builds; installation waits until idle and requires confirmation. Read
[docs/UPDATES.md](docs/UPDATES.md), [docs/BITRIX.md](docs/BITRIX.md), and
[docs/EMPLOYEE-INSTALL.md](docs/EMPLOYEE-INSTALL.md).

## Contributing and license

Use focused branches, keep tests synthetic, run local checks, and describe what
you verified. Never upload private meeting examples to public issues.

Source code is under the [MIT license](LICENSE). Third-party runtimes, libraries
and models retain their licenses and notices. No trademark rights to the Axis
Consult name or logo are granted.
