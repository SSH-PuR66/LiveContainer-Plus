import SwiftUI

/// A small overview of real local observations. Hidden app names and counts stay private.
@MainActor
struct LCHomeView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var monitor = LCCertificateMonitor.shared
    @ObservedObject private var backups = LCBackupManager.shared
    @State private var showHelp = false

    private var signingTitle: String {
        switch monitor.health {
        case .notConfigured: return "lc.home.signing.notConfigured".loc
        case .checking: return "lc.home.signing.checking".loc
        case .valid(let days):
            return "lc.home.signing.valid %lld".localizeWithFormat(days)
        case .expiringSoon(let days):
            return days == 0 ? "lc.home.signing.lessThanDay".loc
                : "lc.home.signing.expiring %lld".localizeWithFormat(days)
        case .expiryUnavailable: return "lc.home.signing.expiryUnknown".loc
        case .expired: return "lc.home.signing.expired".loc
        case .revoked: return "lc.home.signing.revoked".loc
        case .error: return "lc.home.signing.unavailable".loc
        }
    }

    private var signingSymbol: String {
        switch monitor.health {
        case .valid: return "checkmark.seal"
        case .expired, .revoked: return "exclamationmark.triangle"
        case .expiringSoon: return "clock"
        default: return "questionmark.circle"
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("lc.home.intro".loc)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("lc.home.device %@".localizeWithFormat(UIDevice.current.systemVersion))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button { sharedModel.selectedTab = .apps } label: {
                        Label("lc.home.openApps".loc, systemImage: "square.stack.3d.up")
                    }
                    Text("lc.home.apps.count %lld".localizeWithFormat(sharedModel.apps.count))
                        .foregroundStyle(.secondary)
                    if sharedModel.apps.isEmpty {
                        Text("lc.home.apps.empty".loc)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { sharedModel.selectedTab = .sources } label: {
                        Label("lc.home.browseSources".loc, systemImage: "books.vertical")
                    }
                } header: { Text("lc.home.apps".loc) }

                Section {
                    Label(signingTitle, systemImage: signingSymbol)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .checking = monitor.health {
                        ProgressView()
                            .accessibilityLabel("lc.home.signing.checking".loc)
                    }
                    if monitor.pendingBatchResign {
                        Text("lc.home.signing.updateApps".loc)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let checked = monitor.lastChecked {
                        Text("lc.home.checked %@".localizeWithFormat(checked.formatted()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("lc.home.checkAgain".loc) { Task { await monitor.refresh() } }
                        .disabled(monitor.health == .checking)
                    Button("lc.home.openSettings".loc) { sharedModel.selectedTab = .settings }
                } header: { Text("lc.home.signing".loc) }
                footer: { Text("lc.home.signing.limit".loc) }

                Section {
                    NavigationLink(destination: LCBackupView()) {
                        Label("lc.home.manageBackups".loc, systemImage: "externaldrive")
                    }
                    if backups.isBusy {
                        Text(backups.progressText).font(.footnote)
                        ProgressView(value: backups.progressFraction)
                    } else if backups.backupListError != nil {
                        Text("lc.home.backup.unavailable".loc)
                            .foregroundStyle(.secondary)
                        Button("lc.home.retry".loc) { backups.refreshBackupList() }
                    } else if backups.backups.isEmpty {
                        Text("lc.home.backup.emptyBody".loc)
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("lc.home.backup.count %lld".localizeWithFormat(backups.backups.count))
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("lc.home.backup".loc) }
                footer: { Text("lc.home.backup.limit".loc) }

                Section {
                    Button { showHelp = true } label: {
                        Label("lc.home.help".loc, systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("lc.home.title".loc)
            .refreshable { await refresh() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showHelp) { LCHelpView(isPresent: $showHelp) }
        .task { await refresh() }
        .onForeground { Task { await refresh() } }
    }

    private func refresh() async {
        backups.refreshBackupList()
        await monitor.refreshIfStale()
    }
}
