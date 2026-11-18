import PalConnect
import PalDesign
import SwiftUI

enum AppBuild {
    static var label: String? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}

struct StatusBlock: View {
    let status: SetupStatus
    var isBusy = false
    var identifierPrefix = "setupStatus"
    let perform: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: status.symbol)
                .font(.system(size: 24))
                .foregroundStyle(.red)
                .frame(width: 54, height: 54)
                .background(PalTokens.control, in: Circle())
                .accessibilityHidden(true)
            Text(status.title)
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("\(identifierPrefix)Title")
            Text(status.reason)
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifierPrefix)Reason")
            details
            SetupButton(
                title: status.actionTitle, kind: .primary, isBusy: isBusy, identifier: "\(identifierPrefix)Action", action: perform
            )
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PalMetrics.screenMargin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix)Block")
    }

    private var details: some View {
        DisclosureGroup(String(localized: "Details"), isExpanded: $showsDetails) {
            VStack(spacing: 10) {
                Text(status.detailsText(appBuild: AppBuild.label))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PalTokens.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
                    .accessibilityIdentifier("\(identifierPrefix)DetailsText")
                SetupButton(
                    title: String(localized: "Copy details"), systemImage: "doc.on.doc", identifier: "\(identifierPrefix)CopyDetails"
                ) {
                    Pasteboard.string = status.detailsText(appBuild: AppBuild.label)
                }
            }
            .padding(.top, 8)
        }
        .hermesText(.rowSubtitle)
        .foregroundStyle(PalTokens.textSecondary)
        .accessibilityIdentifier("\(identifierPrefix)Details")
    }
}
