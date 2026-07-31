# LiveContainer — Competitive Analysis & Gap-Driven Roadmap

*Compiled 2026-07-31 against LiveContainer `main`.*

---

## 1. The category correction

The most common framing — "LiveContainer vs Sideloadly" — is wrong, and getting it right is
what makes the roadmap obvious.

The ecosystem splits into **three** layers, not one:

| Layer | What it does | Tools |
|---|---|---|
| **Signing / delivery** | Obtains a certificate and gets an IPA onto the device | Sideloadly, AltStore, SideStore, Feather, ESign, Scarlet, KSign |
| **Signature bypass** | Removes the need for per-app signing entirely | TrollStore (CoreTrust exploit) |
| **Runtime / containerization** | Runs many apps inside one installed app slot | **LiveContainer**, (Android analogue: VirtualApp / Parallel Space) |

LiveContainer is the only meaningful occupant of layer 3 on iOS. Sideloadly and SideStore are
**complements**, not competitors — LiveContainer's JIT-less mode consumes the certificate that
SideStore/AltStore provides.

**The actual competitive threat is substitution, not replacement:** a user with 3 free app
slots who only wants 3 apps has no reason to run LiveContainer. LiveContainer wins when the
user wants *many* apps, *multiple accounts of one app*, or *both*. Every strategic move should
widen that gap.

---

## 2. Where each tool actually stands

### Direct feature comparison

| | LiveContainer | Sideloadly | AltStore / SideStore | TrollStore | Feather | ESign / Scarlet |
|---|---|---|---|---|---|---|
| App limit (free acct) | **Unlimited (1 slot)** | 3 | 3 | Unlimited | 3 | Unlimited* |
| Needs a computer | No | **Yes, every time** | Initial setup only | No | No | No |
| 7-day re-sign treadmill | Once, for LC itself | Every app | Every app | **Never** | Every app | Cert lifetime |
| Multiple instances of one app | **Yes (128 containers)** | No | No | No | No | No |
| In-app multitasking / windows | **Yes** | — | — | — | — | — |
| Tweak injection | **Yes** | Yes | No | Yes | Yes | Yes |
| Modern iOS (18 / 26+) | **Yes** | Yes | Yes | **No — capped at 17.0** | Yes | Yes |
| Open source | **Yes** | No | Yes | Yes | Yes | **No** |
| Certificate provenance | Yours (via Store) | Yours | Yours | N/A | **You supply it** | **Leaked enterprise** |

\* ESign/Scarlet's "unlimited" rests on leaked enterprise certificates, which Apple revokes
without warning. That is the single most user-hostile property in the ecosystem.

### Per-competitor read

**TrollStore** — strictly better than LiveContainer *where it works*: permanent installs, no
certificate, no expiry. But it is frozen at **iOS 14.0b2–16.6.1, 16.7 RC, and 17.0**; anything
17.0.1+ will never be supported absent a new CoreTrust bug. Its addressable market shrinks
every year as users update. **Not a growth threat.**

**SideStore** — the closest thing to a strategic partner. On-device refresh via WireGuard +
minimuxer removed the "plug into a PC weekly" tax. LiveContainer already ships a
`LiveContainer+SideStore` build. **Deepen this, don't fight it.**

**Feather** — the sharpest UX competitor. Clean SwiftUI, AltStore repo support, Ellekit tweak
injection, good certificate-detail surfacing. Its weakness is structural: it still burns one
App ID per app and makes the user source their own certificate. **Feather is what LiveContainer
looks like to a user who doesn't yet know why containerization matters.**

**ESign / Scarlet** — win purely on time-to-first-app (bundled cert, zero setup) and lose
catastrophically on reliability and trust (closed source, leaked enterprise certs, revocation
roulette). LiveContainer should never compete on their axis; it should compete on the
consequence of their axis — *"your apps stop working and you don't know why."*

---

## 3. The gaps this fork closes

Three of the four gaps below map directly to LiveContainer's own most-reacted open issues.

### Gap A — Nothing warns you before your apps die
**The single worst shared failure mode in the entire ecosystem.** Certificates expire or get
revoked, apps silently stop launching, and the user's first signal is a crash. LiveContainer
already had `LCUtils.validateCertificate` — it just never asked the question on a schedule.

→ **Shipped: `LCCertificateMonitor` + app-list banner.** Validates on a 6-hour cadence,
classifies health (valid / expiring / expired / revoked / error), and fires a *provisional*
local notification at 7, 3 and 1 days out — one per threshold per certificate, so it warns
without nagging. **No competitor does this.** It converts LiveContainer's biggest inherited
weakness into its most visible reliability feature.

### Gap B — No backup story anywhere in the ecosystem (issue #1353)
Losing a certificate, switching devices, or a bad restore means losing every container.
Sideloadly, AltStore, Feather, ESign and Scarlet all have **zero** first-class backup.

→ **Shipped: `LCBackupManager` + `LCBackupView`.** Manifest-versioned `.lcbackup` archives with
three scopes (settings / +app data / +bundles), selective per-app restore with explicit
overwrite warnings, free-space pre-flight, automatic scheduled backups with retention pruning,
and share-sheet export. Signing certificate and password are **deliberately excluded** so an
archive is safe to move or share.

### Gap C — The app list doesn't scale past ~20 apps (issue #283)
LiveContainer's core promise is "unlimited apps," and its UI was a single flat scroll. The
product's own success was the bug.

→ **Shipped: `LCAppGroupManager` + filter chips.** Named, colored, symbol-tagged groups with
multi-membership, live counts, an "Ungrouped" bucket, per-app assignment from the existing
context menu, and stale-membership pruning. Identity uses `bundleId:relativeBundlePath`, so
two installs of the same app stay distinct.

### Gap D — Adding repos one at a time (issue #1035)
Onboarding friction against Feather, which people arrive at with a list of repos in hand.

→ **Shipped: bulk source import.** Accepts newline/comma-separated URLs *or* the JSON shapes
that circulate in the community (bare array, `{"sources": [...]}`, objects keyed
`url`/`sourceURL`), validates up to 4 concurrently, dedupes against existing *and* in-paste
repeats, reports added/duplicate/invalid counts, and exports the current list back out.

---

## 4. What to build next

Ranked by (competitive value ÷ effort), highest first.

1. **Fullscreen multitask default + status-bar hiding** (issues #722, #729) — pure polish on
   the one feature no competitor has at all. Cheap, high visibility.
2. **Per-container storage insight** — extend `LCStorageManagementModel` to rank containers by
   size. "Unlimited apps" inevitably becomes "where did my 40 GB go."
3. **Certificate-aware pre-launch check** — the monitor now knows the certificate is dead;
   `LCAppModel.runApp` should say so *before* a launch fails, not after.
4. **Backup to Files / iCloud Drive destination** — archives currently land in Documents. A
   user-chosen destination via `UIDocumentPickerViewController` makes the feature survive the
   device loss it exists to protect against.
5. **Group-aware home-screen web clips** — launch a whole group. Nothing else in the ecosystem
   can express "my 6 alt accounts."
6. **Deepen SideStore integration** — surface refresh state and certificate lifetime inline.
   The partnership is the moat; make it legible.

---

## 5. Positioning

> Sideloadly and SideStore get apps **onto** your phone.
> LiveContainer decides how many you can keep, how many copies you can run, and whether you
> find out *before* they stop working.

Do not compete with ESign on setup time. Compete on the morning after.
