# Security

Do not publish recordings, transcripts, CRM exports, personal portal URLs,
webhook tokens, API keys, signing keys or environment files in issues or pull
requests. Use GitHub private vulnerability reporting when it is enabled, or
contact the maintainer through the contact information at https://axisconsult.ru.

Meeting audio and inference stay on the Mac by default. CRM export and MCP
access require explicit user actions. An agent receiving meeting text over MCP
may forward it to its model provider. Local MCP transport does not make an
external model private.

Credentials belong in macOS Keychain. Build signing keys stay in the builder's
Keychain and must never be bundled with the app. Update artifacts contain code,
runtime libraries and public notices only, never Application Support data.

Server updates require HTTPS, a matching archive digest, a newer numeric build,
supported architecture and macOS version, and the same application signing
certificate. HTTPS and a digest alone do not authorize replacement code.

Self-signed alpha builds are not Apple notarized. A source build has its own
signing identity and must use its own update feed; it cannot update official
Axis builds. Review code and dependencies before building.
