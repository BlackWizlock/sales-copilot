# Development and release pipeline

## Ownership and stack

Axis Copilot is a native Swift/SwiftUI macOS 15+ application. Foundation owns
storage and networking, ScreenCaptureKit captures application audio, AVFoundation
captures microphone audio and plays/exports recordings. Whisper.cpp and FluidAudio
CoreML provide local ASR; FluidAudio also groups voices. Ollama supplies local
language-model inference. Bitrix24 is an optional user-configured external system.
MCP is a local read-only stdio interface with per-meeting access control.

The Mac performs recording, inference, transcription and storage. The VPS serves
public signed release archives and a small HTTPS update manifest. It does not
receive recordings, CRM credentials or model prompts. No meeting-processing
database or inference service is deployed to the VPS.

## Branches and checks

Develop in a focused branch and a worktree inside the repository's `.worktrees`.
Keep client content and model weights outside Git. Add failing regression tests
before fixing behavior; use synthetic fixtures. Run targeted checks while editing,
then the complete local CI from a clean checkout before release. A build is not
proof of live audio quality or remote CRM permissions.

```sh
timeout 180 swift run --build-system native CoreChecks
python3 scripts/check-localizations.py
bash scripts/ci-local.sh
```

No paid hosted CI is required or automatically triggered. Keep the local check
results with the release candidate. A fresh reviewer checks the branch before
merge. Publish only the candidate that passed validation, without rebuilding it
with different sources after approval.

## Versions

Use `MAJOR.MINOR.PATCH` for the human version and an always-increasing numeric
`CFBundleVersion` for installation ordering. Patch fixes compatible behavior;
minor adds compatible functionality; major changes compatibility or requires a
documented data migration. A larger major version does not justify resetting the
build number. During `0.x`, breaking changes still need migration notes.

`scripts/publish-update.py --bump patch|minor|major --plist Resources/Info.plist`
changes source metadata before building. It never changes an already signed app.
See `scripts/publish-update.py --help` and [UPDATES.md](UPDATES.md) for exact
staging and publication arguments.

## Release sequence

1. Finish source, translations, model notices, tests and release notes.
2. Select patch/minor/major and increment build. Embed the intended feed URL.
3. Build a portable Apple Silicon app including required inference runtimes and
   localization resources. Downloaded user models remain in Application Support.
4. Sign nested executables and app using the same permanent identity. Verify the
   complete bundle. Signing keys never leave Keychain or enter archives.
5. Verify the candidate on synthetic audio and the installed app. Run the whole
   local CI from a clean checkout; document the exact version and results.
6. Stage an immutable ZIP and its SHA-256 manifest with the publisher. Upload the
   archive first, verify its digest, then atomically replace `latest.json`.
7. Check HTTPS from a client Mac, metadata, digest and actual update detection.
   Exercise an installed update while idle and verify recordings and permissions.
8. A release is live only after these checks. Keep the prior archive for rollback.

## Server

The official alpha feed is
`https://updates.axisconsult.ru/copilot/alpha/latest.json`.
The dedicated route is [deploy/updates.caddy](../deploy/updates.caddy).
On the known Axis VPS, Caddy reads only static artifacts under its existing
read-only `/usr/share/caddy` mount. Files are staged under
`/home/deploy/stack/proxy/site/copilot/alpha`. No application container is joined
to client networks. The route exposes only `/copilot/*` and returns 404 elsewhere.

Validate Caddy before reloading, then check HTTPS and existing site health. DNS
and TLS issuance are checked independently of file publication. A reachable host
with a missing manifest is not a deployed app release.

## Rollback and recovery

The installer retains the previous local app and restores it when replacement
fails. Recording data is never deleted by an update. To roll back a shipped bug,
publish the corrected or prior implementation as a NEW higher build; clients
reject downgrade manifests. If a data migration is ever introduced, test restoring
the previous data version separately. Never rotate the signing identity casually:
it changes update trust and may invalidate macOS permissions.

## Environment and credentials

Supported build variables (names only; values stay outside Git):

- `AXIS_SIGNING_IDENTITY`: public certificate fingerprint, never a private key.
- `AXIS_SIGNING_KEYCHAIN`, `AXIS_SIGNING_IDENTITY_FILE`: local signing locations.
- `AXIS_APP_OUTPUT`, `AXIS_SWIFT_SCRATCH_PATH`: isolated output and build paths.
- `AXIS_SPEAKER_MODELS`, `OLLAMA_RUNTIME_ROOT`: local packaging inputs.
- `AXIS_ADHOC_DEVELOPMENT`: explicit development-only signing, never distribution.
- `AXIS_DISTRIBUTION`: distribution packaging mode.

The update URL is embedded in `Resources/Info.plist` before signing. Source builders
use their own feed and identity. No personal API keys are required to compile the application. Users configure connections inside
the app; secrets are stored in their own Keychain. Never print environment dumps,
include personal Application Support in a ZIP, or publish a credential-bearing URL.

Changing an API key or portal must not affect another user's installation.
Model downloads are public inbound files, not a route for uploading meeting data.
