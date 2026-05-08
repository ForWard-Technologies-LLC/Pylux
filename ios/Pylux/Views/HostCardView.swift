// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Host card matching Android's item_display_host.xml

import SwiftUI

struct HostCardView: View {
    let host: DisplayHost
    var onTap: () -> Void = {}
    var onWakeup: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Header: gradient background, name + platform badge
                headerView
                // Content: IP, MAC, status, running app
                contentView
            }
        }
        .buttonStyle(.plain)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contextMenu {
            if host.isRegistered {
                Button { onWakeup?() } label: {
                    Label("Wake Up", systemImage: "power")
                }
            }
            if case .manual = host {
                Button { onEdit?() } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) { onDelete?() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Header (gradient + name + platform badge)

    private var headerView: some View {
        ZStack {
            // Gradient matching Android's console_card_header_gradient
            LinearGradient(
                colors: host.isPS5
                    ? [Color(red: 0.05, green: 0.15, blue: 0.35), Color(red: 0.1, green: 0.25, blue: 0.55)]
                    : [Color(red: 0.15, green: 0.1, blue: 0.35), Color(red: 0.3, green: 0.15, blue: 0.5)],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack {
                // Console name
                Text(host.name ?? "Unknown Console")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // Platform badge (4 or 5) - matches Android platformBadge
                Text(host.isPS5 ? "5" : "4")
                    .font(.system(size: 16, weight: .black))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.2))
                    )
                    .padding(.trailing, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(height: 60)
    }

    // MARK: - Content (address, MAC, status, running app)

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                // Left: connection info
                VStack(alignment: .leading, spacing: 4) {
                    if case .psn = host {
                        // PSN host: show connection type instead of IP
                        Text("Remote Connection")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if host.isRegistered {
                            Text("Registered")
                                .font(.system(size: 13))
                                .foregroundColor(.green)
                        } else {
                            Text("Not Registered")
                                .font(.system(size: 13))
                                .foregroundColor(.orange)
                        }
                    } else {
                        // Local host: IP Address
                        Text("Address: \(host.hostAddress.isEmpty ? "–" : host.hostAddress)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        // MAC address
                        if let hostId = host.hostId {
                            let formatted = formatMac(hostId)
                            Text("MAC: \(formatted)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Right: status with colored dot
                statusView
            }

            // Bottom: running app info
            if let appInfo = runningAppInfo {
                Text(appInfo)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray6))
                    )
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Status dot + text

    @ViewBuilder
    private var statusView: some View {
        if case .discovered(let dh) = host {
            let state = dh.discoveredHost.state
            if state == .ready || state == .standby {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state == .ready ? Color.green : Color.orange)
                        .frame(width: 12, height: 12)
                    Text(state == .ready ? "Ready" : "Standby")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Running app

    private var runningAppInfo: String? {
        guard case .discovered(let dh) = host else { return nil }
        let h = dh.discoveredHost
        if let name = h.runningAppName, !name.isEmpty {
            if let titleId = h.runningAppTitleId, !titleId.isEmpty {
                return "App: \(name)\nTitle ID: \(titleId)"
            }
            return "App: \(name)"
        }
        return nil
    }

    // MARK: - Helpers

    private func formatMac(_ raw: String) -> String {
        if raw.count == 12 && !raw.contains(":") {
            return stride(from: 0, to: 12, by: 2).map { i in
                let start = raw.index(raw.startIndex, offsetBy: i)
                let end = raw.index(start, offsetBy: 2)
                return String(raw[start..<end])
            }.joined(separator: ":")
        }
        return raw
    }
}
