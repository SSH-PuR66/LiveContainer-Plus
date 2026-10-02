# Native readiness tests

The build workflow uses the selected Xcode toolchain to compile the actual Foundation helpers before archiving:

```sh
xcrun swiftc LiveContainerSwiftUI/Models/LCCertificateHealth.swift \
  LiveContainerSwiftUI/Models/LCBackupListing.swift \
  .github/tests/home/main.swift -o /tmp/livecontainer-readiness-tests
/tmp/livecontainer-readiness-tests
```

The suite checks expiry boundaries, missing/nonfinite/unrepresentable dates, stale/future timestamps, and real filesystem results for missing/empty/populated/invalid directories. It also uses the production metadata scanner and asynchronous refresh coordinator to check background execution, overlapping scans that finish out of order, obsolete success/error suppression, cancellation followed by a replacement, a caller already awaiting settlement before replacement, and current missing-folder recovery. Controlled workers use explicit start/release signals with deadlines instead of timing sleeps. Each run creates its own temporary directory and cleans it up. Test dates and files are fixtures, not product data.

This is not a SwiftUI build or a device test. Verify the archived app separately:

- Home opens in the primary instance; secondary instances and install/source/certificate deep links retain their routes.
- VoiceOver and large text can read and activate each action on iPhone/iPad, with both tab layouts.
- Actual empty lists, search/group filters and file-picker cancellation behave correctly.
- Signing setup and local backup reads reflect actual device state; errors never become successful status or zero backups.
- Existing scheduled backup still runs; create/restore and certificate renewal require real receipts before they are called verified.

Current Windows validation cannot compile the SwiftUI/iOS target.

The backup enumeration change moves work off the main actor; it does not establish a measured speed improvement. Native helper execution, the Xcode archive, and a device responsiveness trace are separate validation steps. When checking the app, refresh Home/Backups while creating or removing a backup and confirm an older list never reappears. A read error should preserve the last observed list and remain visible until a current scan succeeds.
