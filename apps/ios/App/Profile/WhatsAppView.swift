import CoreImage
import CoreImage.CIFilterBuiltins
import HermesBotProfile
import HermesDesign
import SwiftUI

struct WhatsAppView: View {
    @State private var model: WhatsAppModel

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    init(model: WhatsAppModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                logoTile
                Text("Bring \(model.displayName) to WhatsApp")
                    .font(.system(size: WhatsAppMetrics.titleSize, weight: .medium))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .multilineTextAlignment(.center)
                    .padding(.top, WhatsAppMetrics.logoToTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("whatsapp.title")
                Text("Chat with \(model.displayName) in WhatsApp. It'll respond with the same plugins, context, and memories it uses here.")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .padding(.top, WhatsAppMetrics.titleToBody)
                    .accessibilityIdentifier("whatsapp.body")
                    .padding(.horizontal, WhatsAppMetrics.horizontalPadding)
                if model.status != nil, !model.pairing.isActive {
                    settings
                }
                // TODO(secure-secret-entry): WhatsApp Cloud credentials need the shared masked secret-entry component
                pairingArea
            }
            .padding(.top, WhatsAppMetrics.topPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("whatsapp.screen")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if model.pairing.isActive {
                ToolbarItem(placement: .trailingBar) {
                    Button("Cancel") { Task { await model.cancelPairing() } }
                        .accessibilityIdentifier("whatsapp.cancel")
                        .tint(.primary)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { action }
        .task { await model.load() }
        .onDisappear { model.leaveForeground() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.leaveForeground() }
        }
        .confirmationDialog(
            Text("Unpair WhatsApp?"),
            isPresented: $model.confirmsUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { Task { await model.unpair() } }
                .accessibilityIdentifier("whatsapp.unpairConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.displayName) stops responding in WhatsApp.")
        }
    }

    private var logoTile: some View {
        RoundedRectangle(cornerRadius: WhatsAppMetrics.tileRadius, style: .continuous)
            .fill(Color(theme.palette.groupedCard))
            .frame(width: WhatsAppMetrics.tileSize, height: WhatsAppMetrics.tileSize)
            .overlay {
                Image(systemName: "message.fill")
                    .font(.system(size: WhatsAppMetrics.markSize))
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            .accessibilityHidden(true)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionCaption(String(localized: "How to chat"), accessibilityIdentifier: "whatsapp.modeCaption")
                .padding(.bottom, HermesMetrics.captionToCardGap)
            Picker("How to chat", selection: $model.mode) {
                Text("Message yourself").tag(WhatsAppMode.selfChat)
                Text("Own number").tag(WhatsAppMode.bot)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, HermesMetrics.screenMargin)
            .accessibilityIdentifier("whatsapp.mode")
            SectionCaption(String(localized: "Allowed numbers"), accessibilityIdentifier: "whatsapp.allowedUsersCaption")
                .padding(.top, HermesMetrics.cardGap)
                .padding(.bottom, HermesMetrics.captionToCardGap)
            TextField("", text: $model.allowedUsers, prompt: Text("+84901234567, +14155550123"))
                .neverAutocapitalized()
                .autocorrectionDisabled()
                .padding(.horizontal, HermesMetrics.rowInset)
                .frame(height: HermesMetrics.rowMinimumHeight)
                .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
                .padding(.horizontal, HermesMetrics.screenMargin)
                .accessibilityLabel(Text("Allowed numbers"))
                .accessibilityIdentifier("whatsapp.allowedUsers")
            Text(model.normalizedAllowedUsers == nil ? "Use full phone numbers with country code, separated by commas." : "Only these numbers can chat with \(model.displayName). Leave empty to allow no one.")
                .hermesText(.footnoteCaption)
                .foregroundStyle(Color(theme.palette.sectionCaption))
                .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset)
                .padding(.top, HermesMetrics.toggleToFooter)
                .accessibilityIdentifier("whatsapp.allowedUsersFooter")
        }
        .padding(.top, WhatsAppMetrics.bodyToSettings)
    }

    @ViewBuilder
    private var pairingArea: some View {
        VStack(spacing: 14) {
            if let qr = model.pairing.qr {
                QRCodeView(payload: qr.value)
                    .frame(width: WhatsAppMetrics.qrSize, height: WhatsAppMetrics.qrSize)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Pairing code"))
                    .accessibilityIdentifier("whatsapp.qr")
            }
            if let line = statusLine {
                Label(line.text, systemImage: line.symbol)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("whatsapp.status")
            }
            if let hint = statusHint {
                Text(hint)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("whatsapp.hint")
            }
            if let notice = model.notice {
                Text(notice)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("whatsapp.notice")
            }
        }
        .padding(.horizontal, WhatsAppMetrics.horizontalPadding)
        .padding(.top, WhatsAppMetrics.settingsToStatus)
    }

    private struct StatusLine {
        let text: String
        let symbol: String
    }

    private var statusLine: StatusLine? {
        switch model.pairing {
        case .starting:
            return StatusLine(text: String(localized: "Getting your code ready…"), symbol: "ellipsis.circle")
        case .showingQR:
            return StatusLine(text: String(localized: "Scan with WhatsApp"), symbol: "qrcode")
        case .connecting:
            return StatusLine(text: String(localized: "Connecting…"), symbol: "ellipsis.circle")
        case .connected:
            return StatusLine(text: String(localized: "Connected"), symbol: "checkmark.circle.fill")
        case .failed(let failure):
            return StatusLine(text: failureText(failure), symbol: "exclamationmark.triangle")
        case .expired:
            return StatusLine(text: String(localized: "That code expired. Start again for a new one."), symbol: "clock.badge.exclamationmark")
        case .idle:
            guard let status = model.status, status.isPaired else { return nil }
            return StatusLine(text: pairedText(status), symbol: "checkmark.circle.fill")
        }
    }

    private var statusHint: String? {
        if case .showingQR = model.pairing {
            return String(localized: "On your phone, open WhatsApp, go to Linked devices, then Link a device.")
        }
        return nil
    }

    private func pairedText(_ status: WhatsAppStatus) -> String {
        let name = status.account.name ?? ""
        let phone = status.account.phone ?? ""
        switch (name.isEmpty, phone.isEmpty) {
        case (false, false): return String(localized: "Connected as \(name) (\(phone))")
        case (false, true): return String(localized: "Connected as \(name)")
        case (true, false): return String(localized: "Connected as \(phone)")
        case (true, true): return String(localized: "Connected")
        }
    }

    private func failureText(_ failure: WhatsAppFailure) -> String {
        switch failure {
        case .anotherPairingActive: String(localized: "Another pairing is already in progress. Cancel it or wait a moment.")
        case .invalidSettings: String(localized: "Check the allowed numbers and try again.")
        case .pairingFailed: String(localized: "Couldn't connect WhatsApp. Try again.")
        case .unavailable: String(localized: "Couldn't reach WhatsApp. Try again.")
        }
    }

    @ViewBuilder
    private var action: some View {
        Group {
            switch model.phase {
            case .loading:
                PillButton(String(localized: "Loading"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "whatsapp.loading") {}
            case .busy(let activity):
                PillButton(busyTitle(activity), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "whatsapp.busy") {}
            case .unavailable:
                PillButton(String(localized: "Try again"), kind: .accent, size: .large, accessibilityIdentifier: "whatsapp.retry") {
                    Task { await model.recheck() }
                }
            case .ready:
                readyAction
            }
        }
        .padding(.bottom, WhatsAppMetrics.actionBottomPadding)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var readyAction: some View {
        switch model.pairing {
        case .starting, .connecting:
            PillButton(String(localized: "Connecting…"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "whatsapp.pairing") {}
        case .showingQR:
            EmptyView()
        case .failed, .expired:
            pairButton(title: String(localized: "Try again"), reset: model.isPaired, identifier: "whatsapp.pair")
        case .idle, .connected:
            if model.isPaired {
                pairedActions
            } else {
                pairButton(title: String(localized: "Pair WhatsApp"), reset: false, identifier: "whatsapp.pair")
            }
        }
    }

    @ViewBuilder
    private var pairedActions: some View {
        VStack(spacing: 10) {
            if model.hasUnsavedSettings {
                PillButton(String(localized: "Save changes"), kind: model.normalizedAllowedUsers == nil ? .dimmed : .accent, size: .large, accessibilityIdentifier: "whatsapp.save") {
                    Task { await model.saveSettings() }
                }
            }
            PillButton(String(localized: "Pair again"), kind: .neutral, size: .large, accessibilityIdentifier: "whatsapp.repair") {
                Task { await model.startPairing(reset: true) }
            }
            PillButton(String(localized: "Unpair"), kind: .neutral, size: .large, accessibilityIdentifier: "whatsapp.unpair") {
                model.confirmsUnpair = true
            }
        }
    }

    private func pairButton(title: String, reset: Bool, identifier: String) -> some View {
        PillButton(title, kind: model.canPair ? .accent : .dimmed, size: .large, accessibilityIdentifier: identifier) {
            Task { await model.startPairing(reset: reset) }
        }
    }

    private func busyTitle(_ activity: WhatsAppModel.Activity) -> String {
        switch activity {
        case .saving: String(localized: "Saving…")
        case .unpairing: String(localized: "Unpairing…")
        case .checking: String(localized: "Loading")
        }
    }
}

private struct QRCodeView: View {
    let payload: String

    var body: some View {
        RoundedRectangle(cornerRadius: WhatsAppMetrics.qrRadius, style: .continuous)
            .fill(Color.white)
            .overlay {
                if let image = Self.render(payload) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(WhatsAppMetrics.qrInset)
                }
            }
    }

    private static func render(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: WhatsAppMetrics.qrModuleScale, y: WhatsAppMetrics.qrModuleScale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

enum WhatsAppMetrics {
    static let tileSize: CGFloat = 56
    static let tileRadius: CGFloat = 14
    static let markSize: CGFloat = 26
    static let titleSize: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let logoToTitle: CGFloat = 22
    static let titleToBody: CGFloat = 24
    static let bodyToSettings: CGFloat = 28
    static let settingsToStatus: CGFloat = 28
    static let horizontalPadding: CGFloat = 36
    static let actionBottomPadding: CGFloat = 8
    static let qrSize: CGFloat = 232
    static let qrRadius: CGFloat = 16
    static let qrInset: CGFloat = 12
    static let qrModuleScale: CGFloat = 8
}
