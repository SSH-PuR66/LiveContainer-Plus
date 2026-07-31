# Fork changelog

Changes layered on top of the upstream `LiveContainer-main` snapshot (extracted from
`LiveContainer-main.zip`, 2026-07-31). See `COMPETITIVE-ANALYSIS.md` for the reasoning behind
each item.

> **Builds clean; not yet run on a device.** Authored on Windows and compiled by GitHub
> Actions on `macos-latest` with Xcode 26.2 — `xcodebuild archive` succeeds and the IPA is
> published to the `nightly` release. It has not been exercised on real hardware, so the
> features are unverified at runtime even though they compile.

---

## Added files

| File | Purpose |
|---|---|
| `LiveContainerSwiftUI/Models/LCAppGroupManager.swift` | App group model, persistence, membership, filtering |
| `LiveContainerSwiftUI/Views/AppList/Grouping/LCAppGroupBar.swift` | Horizontal group filter chips |
| `LiveContainerSwiftUI/Views/AppList/Grouping/LCAppGroupManagementView.swift` | Group CRUD + membership editor |
| `LiveContainerSwiftUI/Models/LCBackupManager.swift` | Backup/restore engine |
| `LiveContainerSwiftUI/Views/Settings/DataManagement/LCBackupView.swift` | Backup UI + restore confirmation sheet |
| `LiveContainerSwiftUI/Models/LCCertificateMonitor.swift` | Certificate health tracking + notifications |
| `LiveContainerSwiftUI/Views/AppList/LCCertificateBanner.swift` | Certificate warning banner |
| `COMPETITIVE-ANALYSIS.md` | Market analysis and roadmap |

New Swift files need no `project.pbxproj` edit: `LiveContainerSwiftUI` is a
`PBXFileSystemSynchronizedRootGroup`, so Xcode 16+ picks them up from the filesystem.

## Modified files

- **`LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`**
  - Group filter applied in `filteredApps` / `filteredHiddenApps`; new `groupableApps`
  - Certificate banner + group chip bar inserted at the top of the list
  - "Manage Groups" added to the sort menu; group management sheet
  - `onAppear` now prunes stale group membership, kicks off a certificate check, and runs a
    due auto-backup (both detached, so neither delays first paint)
  - `removeApp` drops the app from all groups

- **`LiveContainerSwiftUI/Views/AppList/LCAppBanner.swift`**
  - "Add to Group" submenu in the existing UIKit context menu, with checkmark state

- **`LiveContainerSwiftUI/Views/LCAltStoreSourcesView.swift`**
  - `AltStoreSourcesViewModel`: `addSources(fromBulkText:)`, `refreshSources(urls:)`
    (bounded to 4 concurrent), `exportSourcesJSON()`, `parseBulkSourceText`
  - `ManageSourcesSheet`: bulk paste area, "Add All", "Export Source List", result summary

- **`LiveContainerSwiftUI/Views/Settings/DataManagement/LCDataManagementView.swift`**
  - Navigation entry to `LCBackupView`

- **`LiveContainerSwiftUI/Utilities/LCUtils.h` / `LCUtils.m`**
  - `LCZipDirectory(NSURL*, NSURL*, NSError**)` — Swift-callable wrapper over the private
    `PKZipArchiver` that `archiveIPAWithBundleName:` already uses

- **`Resources/Localizable.xcstrings`**
  - 83 new source strings (English only; Crowdin picks up the rest). All 246 `.loc` /
    `.localizeWithFormat` references in the touched files were verified to resolve.

---

## Behavioural notes worth knowing

- **Backups exclude the signing certificate and its password by design**, so an archive is
  safe to share or move between devices.
- **Backup staging copies before zipping**, so a backup transiently needs roughly 2× its
  uncompressed size in free space. `createBackup` pre-flights this and fails with a specific
  error rather than filling the disk.
- **All blocking filesystem work (zip, extract, copy) runs off the main actor** via
  `runOffMain` / `copyOffMain`, so the progress UI stays live.
- **Certificate notifications use provisional authorization**, so they land quietly in
  Notification Center without a permission prompt, at most once per threshold per certificate.
- **Group membership is keyed on `bundleId:relativeBundlePath`**, matching
  `LCAppSortManager`, so two installs of the same app stay distinct.
- **Restore is non-destructive until confirmed**: `prepareRestore` extracts and reports a
  plan; `applyRestore` commits; `discardRestore` cleans up. Dismissing the sheet discards.

## Installing from an iPad (no Mac required)

GitHub's macOS runners do the build. Add this as an AltStore source in SideStore/AltStore:

```
https://github.com/SSH-PuR66/LiveContainer-Plus/releases/download/nightly/apps_nightly.json
```

It appears as **LiveContainer+ (fork nightly)**. Every push to `main` rebuilds and refreshes
that source, so updates arrive over the air.

The bundle identifier stays `com.kdt.livecontainer`, so this upgrades an existing
LiveContainer in place and keeps its containers and app data. That also means it *replaces*
stock LiveContainer rather than installing alongside it.

## CI fixes required to make forks work

- `update_json.py` read a hardcoded `LiveContainer/LiveContainer`; a fork would publish a
  source pointing at upstream's IPA. Now reads `GITHUB_REPOSITORY`.
- `update_json.py` ran *before* the nightly release was created, so a repo without a prior
  release published the checked-in JSON verbatim — still carrying upstream's URL. A
  post-release step now re-runs it, asserts the resulting `downloadURL` belongs to this
  repository, and overwrites the published asset.
- Source JSON now falls back to the in-repo copy when no `1.0` release exists, instead of
  failing the job on a 404.
- The archive step teed raw `xcodebuild` output; `xcpretty` was discarding every Swift
  diagnostic, so a failed build reported only `** ARCHIVE FAILED **`.

## Known gaps

- Compiles, but never launched on a device — no feature here is runtime-verified.
- `LCBackupManager.readManifest` is unused by the current UI (the restore flow goes through
  `prepareRestore`); it is kept as a utility for a future backup-detail view.
- Backups land in `Documents/Backups`. A user-chosen destination via
  `UIDocumentPickerViewController` is item 4 on the roadmap.
- Issues #722 / #729 (fullscreen multitask default, status-bar hiding) are **not** addressed;
  they live in `MultitaskSupport` UIKit internals and were left for a pass that can be tested
  on-device.
