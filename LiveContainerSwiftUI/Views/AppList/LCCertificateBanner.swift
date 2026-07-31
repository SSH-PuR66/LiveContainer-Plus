//
//  LCCertificateBanner.swift
//  LiveContainerSwiftUI
//
//  Surfaces certificate trouble at the top of the app list, before apps stop launching.
//

import SwiftUI

struct LCCertificateBanner: View {
    @ObservedObject var monitor: LCCertificateMonitor

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
        if let presentation, !monitor.bannerDismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: presentation.symbol)
                    .font(.title3)
                    .foregroundStyle(presentation.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.footnote.weight(.semibold))
                    Text(presentation.message)
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
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(presentation.tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(presentation.tint.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }
}
