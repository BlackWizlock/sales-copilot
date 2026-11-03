# Stable credentials implementation plan

Goal: ordinary alpha app updates must not require new Keychain authorizations. No plaintext credential files, relaxed ACLs or general-purpose secret service.

Evidence: metadata-only inspection of the exact Bitrix record showed a trusted application ACL plus ACLAuthorizationPartitionID containing eight cdhash values. The installed app has a stable designated requirement but a self-signed certificate with no Apple Team ID; the partition list changes with each binary. No credential values were read by diagnostics.

Architecture decision by implementer: install a small signed immutable credential helper in the user's private Application Support directory. Ordinary app updates validate and reuse that exact installed executable. The helper is the only owner of new versioned Bitrix/OpenRouter Keychain items. It accepts bounded JSON over inherited pipes and verifies the live parent process against the current app identifier and signing certificate before touching Keychain. Untrusted callers fail without a prompt. The app verifies the helper's signature, identifier, protocol and private non-symlink path before launching it. No network, arbitrary service names, command execution or filesystem paths in the protocol.

Protocol: version1, domain bitrix/openrouter, operation read/write/delete/migrate, no interaction flag, optional bounded base64 data. Result is a bounded JSON envelope on the private stdout pipe; no diagnostics include payloads. Errors are typed status codes. Commands, environment and logs never contain secrets. Existing items remain unchanged until a successful authorized read and successful helper write. Migration verifies the helper readback before recording only a non-secret completion marker; failure preserves the old record. Background migration never opens system authorization. Locked/denied states fail promptly.

Important limit: software cannot bypass protection on the existing record. If macOS has not authorized its read, migration requires explicit re-entry of the user's webhook. Do not claim the old record was recovered silently. The permanent helper removes per-build requests after migration; future helper replacement can migrate through the still-authorized old helper, without changing the existing item ACL.

Files: scripts/CredentialHelper.swift (bounded protocol, parent authentication, Keychain only); Sources/AxisCopilot/CredentialBridge.swift (private install, signature validation, bounded subprocess); BitrixCredentials.swift and OpenRouterClient.swift (migration and new storage); scripts/build-app.sh, sign-app.sh and package verification (helper packaging); Tests/BitrixIntegration/CredentialContinuityChecks.swift plus scripts/check-credential-continuity.sh (different parent builds, immutable helper, hostile caller, corrupted helper, locked/denied behavior). Existing custom synthetic-service credential tests remain isolated and never use real records.

Review focus: caller identity, process/pipe spoofing and signature races; unrestricted key reads; accidental overwrite of pinned helper; migration loss; quiet background access; foreign-process denial; no secret output from tests. Tests compile a fixture-only domain suffix, absent from distributed helper.

- [x] Build and run a failing two-signed-build synthetic continuity test with current direct storage.
- [x] Implement helper and verified immutable installation; prove bounded JSON and caller denial.
- [x] Migrate both credential domains without deleting old records or opening background dialogs.
- [x] Verify A/B parent cdhash differs, helper cdhash stays identical, both reads succeed silently, hostile caller fails.
- [ ] Review; full clean CI; signed package installation; actual old-record migration only if quiet authorized access succeeds; otherwise re-entry.

Owner explicitly requested this fix immediately; summary quality and deal504 acceptance remain queued.
