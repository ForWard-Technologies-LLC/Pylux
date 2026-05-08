// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI
import StoreKit
import os.log

private let paywallLog = OSLog(subsystem: "com.pylux.stream", category: "DonationPaywall")

// MARK: - Colors (matching Android values/colors.xml)

private extension Color {
    static let paywallBg = Color(red: 0x0D/255, green: 0x11/255, blue: 0x17/255)           // primary_dark #0D1117
    static let headerPrimary = Color(red: 0x1A/255, green: 0x23/255, blue: 0x32/255)       // primary #1A2332
    static let pyluxBlue = Color(red: 0x00/255, green: 0x9F/255, blue: 0xE3/255)           // #009FE3
    static let tierCardBg = Color(red: 0x1A/255, green: 0x23/255, blue: 0x32/255)          // support_tier_card_bg
    static let tierCardStroke = Color(red: 0x00/255, green: 0x9F/255, blue: 0xE3/255).opacity(0.25)  // pylux_blue_border
    static let supportTextSecondary = Color(red: 0xB8/255, green: 0xC5/255, blue: 0xD6/255) // #B8C5D6
    static let accentLight = Color(red: 0x6B/255, green: 0xB6/255, blue: 0xFF/255)         // #6BB6FF
    static let divider = Color.white.opacity(0.2)                                           // #33FFFFFF
    static let taglineTint = Color(red: 0xE3/255, green: 0xEA/255, blue: 0xF2/255)         // #E3EAF2
}

// MARK: - Main Paywall View

struct DonationPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var store = DonationStore.shared
    @State private var tierAppeared: Set<String> = []
    @State private var borderSweepProductId: String?
    @State private var borderSweepProgress: CGFloat = 0
    @State private var borderSweepOpacity: Double = 1
    @State private var framePulseProgress: CGFloat = 0
    @State private var framePulseOpacity: Double = 1
    @State private var phraseRevealFraction: CGFloat = 0
    @State private var purchasingProductId: String?
    @State private var restoreMessage: String?
    @State private var showRestoreToast = false

    private let paywallShowCount: Int
    private let rotatingPhrase: String?

    init() {
        let count = SecureStore.shared.incrementDonationPaywallShowCount()
        paywallShowCount = count
        rotatingPhrase = DonationPhrasePicker.phrase(forPaywallShowCount: count)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.paywallBg.ignoresSafeArea()

                if geo.size.width > geo.size.height {
                    landscapeLayout
                } else {
                    portraitLayout
                }

                framePulseOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            startFramePulse()
            if rotatingPhrase != nil {
                startPhraseReveal()
            }
        }
        .task {
            if store.tiers.isEmpty && !store.loadFailed {
                await store.loadProducts()
            }
            startTierRevealSequence()
        }
        .overlay(alignment: .bottom) {
            if showRestoreToast, let msg = restoreMessage {
                toastView(msg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Portrait Layout

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            headerPortrait
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    storySection(compact: false)
                    if !store.loadFailed {
                        pickSection
                        tierList
                    } else {
                        paypalFallback
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            Divider().background(Color.divider)
            footer(compact: false)
        }
    }

    // MARK: - Landscape Layout

    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            headerLandscape
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            storySection(compact: true)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .frame(width: geo.size.width * 0.43)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                        .padding(.vertical, 12)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !store.loadFailed {
                                tierList
                            } else {
                                paypalFallback
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .frame(width: geo.size.width * 0.57)
                }
            }
            Divider().background(Color.divider)
            footer(compact: true)
        }
    }

    // MARK: - Header (Portrait)

    private var headerPortrait: some View {
        HStack(spacing: 12) {
            pyluxLogo(size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Keep Pylux alive")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                Text("Open source and community-maintained.")
                    .font(.system(size: 13))
                    .foregroundColor(.taglineTint)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [.pyluxBlue, .headerPrimary, .paywallBg],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Header (Landscape)

    private var headerLandscape: some View {
        HStack(spacing: 10) {
            pyluxLogo(size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keep Pylux alive")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("Open source and community-maintained.")
                    .font(.system(size: 11))
                    .foregroundColor(.taglineTint)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.pyluxBlue, .headerPrimary, .paywallBg],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Logo

    private func pyluxLogo(size: CGFloat) -> some View {
        Image("AppIconImage")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityLabel("Pylux")
    }

    // MARK: - Story Section

    private func storySection(compact: Bool) -> some View {
        let fontSize: CGFloat = compact ? 13 : 14
        let titleSize: CGFloat = compact ? 14 : 15
        let bulletSpacing: CGFloat = compact ? 6 : 8

        return VStack(alignment: .leading, spacing: 0) {
            Text("Enjoying Pylux?")
                .font(.system(size: titleSize, weight: .bold))
                .foregroundColor(.white)

            Text(compact
                 ? "Open source, community-maintained. Please consider supporting the project. Donations go to the developers who ship updates."
                 : "It\u{2019}s open source and maintained by the community. Please consider supporting the project. Donations go to the developers who maintain it.")
                .font(.system(size: fontSize))
                .foregroundColor(.supportTextSecondary)
                .lineSpacing(3)
                .padding(.top, compact ? 8 : 10)

            if let phrase = rotatingPhrase {
                phraseView(phrase, fontSize: fontSize)
                    .padding(.top, compact ? 12 : 14)
            } else {
                bulletList(compact: compact, fontSize: fontSize, spacing: bulletSpacing)
                    .padding(.top, compact ? 12 : 14)
            }
        }
    }

    // MARK: - Bullets

    private func bulletList(compact: Bool, fontSize: CGFloat, spacing: CGFloat) -> some View {
        let b1 = compact
            ? "It all goes to the developers."
            : "Your donation goes to the people who build and maintain Pylux."
        let b2 = compact
            ? "One payment in the App Store. No subscription."
            : "Single payment in the App Store. No subscription."
        let b3 = compact
            ? "Optional. Full app either way."
            : "Optional. You get the full app either way."

        return VStack(alignment: .leading, spacing: spacing) {
            bulletRow(b1, fontSize: fontSize)
            bulletRow(b2, fontSize: fontSize)
            bulletRow(b3, fontSize: fontSize)
        }
    }

    private func bulletRow(_ text: String, fontSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\u{2022}")
                .font(.system(size: fontSize))
                .foregroundColor(.supportTextSecondary)
                .padding(.top, 2)
                .padding(.trailing, compact(fontSize) ? 8 : 10)

            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(.supportTextSecondary)
                .lineSpacing(2)
        }
    }

    private func compact(_ fontSize: CGFloat) -> Bool { fontSize <= 13 }

    // MARK: - Rotating Phrase (typewriter reveal)

    private func phraseView(_ phrase: String, fontSize: CGFloat) -> some View {
        let charCount = phrase.count
        let visibleCount = Int(CGFloat(charCount) * phraseRevealFraction)
        let visibleText = String(phrase.prefix(visibleCount))
        let alpha = 0.2 + 0.8 * Double(phraseRevealFraction)

        return Text(visibleText)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(.supportTextSecondary)
            .lineSpacing(3)
            .opacity(alpha)
    }

    private func startPhraseReveal() {
        guard let phrase = rotatingPhrase, !phrase.isEmpty else { return }
        let len = phrase.count
        let durationMs = min(720, max(320, 320 + len * 16))
        let duration = Double(durationMs) / 1000.0

        phraseRevealFraction = 0
        withAnimation(.linear(duration: duration)) {
            phraseRevealFraction = 1
        }
    }

    // MARK: - Pick Section (portrait only)

    private var pickSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose an amount")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Text("Pick a tier below. You only pay once.")
                .font(.system(size: 13))
                .foregroundColor(.supportTextSecondary)
                .lineSpacing(2)
        }
        .padding(.top, 20)
    }

    // MARK: - Tier List

    private var tierList: some View {
        VStack(spacing: 8) {
            ForEach(Array(store.tiers.enumerated()), id: \.element.id) { index, product in
                tierCard(product: product, index: index)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Tier Card

    private func tierCard(product: Product, index: Int) -> some View {
        let appeared = tierAppeared.contains(product.id)
        let isSweeping = borderSweepProductId == product.id

        let isBuying = purchasingProductId == product.id
        let anyBuying = purchasingProductId != nil

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DonationStore.tierDisplayName(for: product.id))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(DonationStore.tierBlurb(for: product.id))
                    .font(.system(size: 11))
                    .foregroundColor(.supportTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isBuying {
                ProgressView()
                    .tint(.pyluxBlue)
                    .frame(width: 56, alignment: .center)
            } else {
                HStack(spacing: 6) {
                    Text(product.displayPrice)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.pyluxBlue)
                        .frame(minWidth: 56, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.supportTextSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .opacity(anyBuying && !isBuying ? 0.4 : 1)
        .background(Color.tierCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            guard purchasingProductId == nil else { return }
            purchasingProductId = product.id
            Task {
                let success = await DonationStore.shared.purchase(product)
                purchasingProductId = nil
                if success {
                    dismiss()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(appeared ? Color.tierCardStroke : Color.pyluxBlue, lineWidth: appeared ? 1 : 2.5)
        )
        .overlay(
            GeometryReader { geo in
                if isSweeping {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.pyluxBlue, lineWidth: 2)
                        .mask(
                            Rectangle()
                                .frame(width: geo.size.width * borderSweepProgress)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                        .opacity(borderSweepOpacity)
                }
            }
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .accessibilityLabel("\(DonationStore.tierDisplayName(for: product.id)), \(product.displayPrice). Double-tap to donate once with the App Store.")
    }

    // MARK: - Tier Reveal Animation

    private func startTierRevealSequence() {
        let tiers = store.tiers
        for (index, product) in tiers.enumerated() {
            let delayNs = UInt64(Double(index) * 0.09 * 1_000_000_000)
            let pid = product.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delayNs)
                withAnimation(.easeOut(duration: 0.42)) {
                    tierAppeared.insert(pid)
                }
            }
        }

        let allFadesDoneNs = UInt64((Double(max(0, tiers.count - 1)) * 0.09 + 0.42) * 1_000_000_000)
        if !tiers.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: allFadesDoneNs)
                startBorderSweepCycle(startIndex: 0)
            }
        }
    }

    private func startBorderSweepCycle(startIndex: Int) {
        let tiers = store.tiers
        guard !tiers.isEmpty else { return }
        let idx = startIndex % tiers.count
        let pid = tiers[idx].id

        borderSweepProductId = pid
        borderSweepProgress = 0
        borderSweepOpacity = 1

        withAnimation(.linear(duration: 1.0)) {
            borderSweepProgress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(.linear(duration: 0.4)) {
                borderSweepOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            borderSweepProductId = nil
            borderSweepProgress = 0
            borderSweepOpacity = 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            startBorderSweepCycle(startIndex: idx + 1)
        }
    }

    // MARK: - Frame Pulse

    private var framePulseOverlay: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.pyluxBlue, lineWidth: 3)
                .mask(
                    Rectangle()
                        .frame(width: geo.size.width * framePulseProgress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                )
                .opacity(framePulseOpacity)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func startFramePulse() {
        framePulseProgress = 0
        framePulseOpacity = 1

        withAnimation(.linear(duration: 0.72)) {
            framePulseProgress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 720_000_000)
            withAnimation(.linear(duration: 0.48)) {
                framePulseOpacity = 0
            }
        }
    }

    // MARK: - PayPal Fallback

    private var paypalFallback: some View {
        VStack(spacing: 0) {
            Text("Support via PayPal")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)

            Text("App Store billing is not available here. Use the link below to open PayPal.")
                .font(.system(size: 14))
                .foregroundColor(.supportTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)

            if let url = URL(string: "https://www.paypal.com/ncp/payment/AGV5G9KZAPJX6") {
                Link("Open PayPal link", destination: url)
                    .font(.system(size: 15))
                    .foregroundColor(.accentLight)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Footer

    private func footer(compact: Bool) -> some View {
        let trustText = store.loadFailed
            ? "Donate via PayPal in your browser."
            : "One payment in the App Store. No subscription."

        return Group {
            if compact {
                HStack {
                    Text(trustText)
                        .font(.system(size: 10))
                        .foregroundColor(.supportTextSecondary)
                        .lineLimit(1)

                    Spacer()

                    if !store.loadFailed {
                        restoreButton(fontSize: 12)
                    }
                    dismissButton(fontSize: 12)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    Text(trustText)
                        .font(.system(size: 11))
                        .foregroundColor(.supportTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if !store.loadFailed {
                            restoreButton(fontSize: 13)
                        }
                        dismissButton(fontSize: 13)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .background(Color.paywallBg)
    }

    private func restoreButton(fontSize: CGFloat) -> some View {
        Button {
            Task {
                let result = await DonationStore.shared.restorePurchases()
                switch result {
                case .none:
                    showToast("No support purchases found for this Apple account.")
                case .alreadyOnDevice:
                    showToast("Your support purchase is already on this device.")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        dismiss()
                    }
                case .restored:
                    showToast("Purchases restored. Thank you for supporting Pylux!")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        dismiss()
                    }
                case .unavailable:
                    showToast("Couldn\u{2019}t reach the App Store. Try again in a moment.")
                }
            }
        } label: {
            Text("Restore purchases")
                .font(.system(size: fontSize))
                .foregroundColor(.accentLight)
                .frame(minHeight: fontSize > 12 ? 40 : 36)
                .padding(.horizontal, fontSize > 12 ? 10 : 8)
        }
    }

    private func dismissButton(fontSize: CGFloat) -> some View {
        Button {
            dismiss()
        } label: {
            Text("Maybe later")
                .font(.system(size: fontSize))
                .foregroundColor(.accentLight)
                .frame(minHeight: fontSize > 12 ? 40 : 36)
                .padding(.horizontal, fontSize > 12 ? 10 : 8)
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        restoreMessage = message
        withAnimation { showRestoreToast = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { showRestoreToast = false }
        }
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.2).cornerRadius(10))
            .padding(.bottom, 20)
    }
}

