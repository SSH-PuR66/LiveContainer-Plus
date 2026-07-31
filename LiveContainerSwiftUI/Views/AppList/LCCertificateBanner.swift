//
//  LCCertificateBanner.swift
//  LiveContainerSwiftUI
//
//  Surfaces certificate trouble at the top of the app list, before apps stop launching.
//

import SwiftUI

struct LCCertificateBanner: View {
    @ObservedObject var monitor: LCCertificateMonitor
    @ObservedObject var batchSigner: LCBatchSigner
    /// Apps to re-sign when the certificate has been replaced.
    var appsToResign: [LCAppModel]

    private var presentation: (title: String, message: String, symbol: String, tint: Color)? {
        switch monitor.health {
        case .notConfigured, .checking, .valid:
            // Nothing to say — a healthy certificate should be invisible.
            return nil
        case .expiringSoon(let days):
            return ("lc.cert.banner.expiring.title".loc,
                    "lc.cert.banner.expiring.body %lld".localizeWithFormat(days),
                    "clock.badge.exclamationmark",
                    .orange)
        case .expired:
            return ("lc.cert.banner.expired.title".loc,
                    "lc.cert.banner.expired.body".loc,
                    "xmark.seal",
                    .red)
        case .revoked:
            return ("lc.cert.banner.revoked.title".loc,
                    "lc.cert.banner.revoked.body".loc,
                    "exclamationmark.shield",
                    .red)
        case .error(let detail):
            return ("lc.cert.banner.error.title".loc,
                    detail,
                    "exclamationmark.triangle",
                    .yellow)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if batchSigner.isRunning {
                resignProgressCard
            } else if monitor.pendingBatchResign {
                renewalCard
            }

            if let presentation, !monitor.bannerDismissed {
                healthCard(presentation)
            }
        }
    }

    // MARK: - Cards

    /// Shown after the certificate was replaced: every app still carries the old signature
    /// and would otherwise stall on its next launch while it re-signs.
    private var renewalCard: some View {
        card(tint: .blue) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.title3)
                    .foregroundStyle(Color.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.cert.banner.renewed.title".loc)
                        .font(.footnote.weight(.semibold))
                    Text("lc.cert.banner.renewed.body %lld".localizeWithFormat(appsToResign.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button {
                            let apps = appsToResign
                            Task { await batchSigner.resignAll(apps: apps) }
                        } label: {
                            Text("lc.cert.banner.renewed.action".loc)
                                .font(.caption.weight(.semibold))
                        }
                        .disabled(appsToResign.isEmpty)

                        Button {
                            monitor.clearPendingBatchResign()
                        } label: {
                            Text("lc.cert.banner.renewed.later".loc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var resignProgressCard: some View {
        card(tint: .blue) {
            VStack(alignment: .leading, spacing: 6) {
                Text("lc.cert.banner.resigning %lld %lld".localizeWithFormat(
                    batchSigner.completed, batchSigner.total))
                    .font(.footnote.weight(.semibold))
                Text(batchSigner.currentAppName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: batchSigner.progressFraction)
            }
        }
    }

    private func healthCard(_ p: (title: String, message: String, symbol: String, tint: Color)) -> some View {
        card(tint: p.tint) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: p.symbol)
                    .font(.title3)
                    .foregroundStyle(p.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title)
                        .font(.footnote.weight(.semibold))
                    Text(p.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    monitor.bannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("lc.common.dismiss".loc)
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.opacity)
    }
}
