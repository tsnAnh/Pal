import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectorDetailsScreen: View {
    @State var model: ConnectorDetailsModel
    let back: () -> Void

    @Environment(\.hermesTheme) private var theme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(model: ConnectorDetailsModel, back: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.back = back
    }

    private var margin: CGFloat {
        #if os(macOS)
        28
        #else
        sizeClass == .regular ? 40 : PalMetrics.screenMargin
        #endif
    }

    var body: some View {
        let surface = Color(theme.palette.sheetBackground)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(surface.ignoresSafeArea())
            .environment(\.detailsMargin, margin)
            .task { await model.refresh() }
            .onChange(of: model.current.state) { _, _ in Task { await model.refresh() } }
            .modifier(ConnectorDetailsChrome(back: back))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.app == nil { unavailable } else { sections }
            }
            .padding(.bottom, PalMetrics.cardGap)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        let app = model.current
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ConnectorLogoTile(app: app)
                    .scaleEffect(56 / ConnectRowMetrics.tileSize)
                    .frame(width: 56, height: 56)
                Text(app.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("connectorDetailsName")
                if model.app != nil { primaryAction }
            }
            .padding(.horizontal, margin)
            .padding(.top, 6)
            if case .catalog(let entry) = app.source, !entry.description.isEmpty {
                Text(entry.description)
                    .font(.system(size: 15))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, margin)
                    .padding(.top, 12)
                    .accessibilityIdentifier("connectorDetailsDescription")
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.isConnected {
            Button("Disconnect") { model.disconnect() }
                .glassButtonStyle()
                .disabled(model.isBusy)
                .accessibilityIdentifier("connectorDetailsDisconnect")
        } else if let title = model.rowState.actionTitle {
            Button(title) { model.connect() }
                .glassButtonStyle(prominent: true)
                .disabled(model.isBusy)
                .accessibilityIdentifier("connectorDetailsConnect")
        }
    }

    @ViewBuilder
    private var sections: some View {
        if model.isConnected {
            ConnectorAccountsCard(model: model)
            ConnectorToolsCard(model: model)
            if !model.skills.isEmpty { ConnectorSkillsCard(skills: model.skills) }
        }
        let information = ConnectorInformation.rows(for: model.current)
        if !information.isEmpty { ConnectorInformationCard(rows: information) }
        if !model.isConnected {
            ConnectorDetailsFootnote(
                text: String(localized: "Accounts, tools and skills appear after you connect."),
                identifier: "connectorDetailsNotConnectedNote", solo: true
            )
        }
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            PalIcon("exclamationmark.triangle", ink: .secondary)
                .font(.system(size: 24))
                .frame(width: 54, height: 54)
                .background(PalTokens.control, in: Circle())
            Text("Couldn't load this app")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
            Text("Check your connection to Pal and try again.")
                .font(.system(size: 15))
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await model.retryApp() } }
                .glassButtonStyle(prominent: true)
                .accessibilityIdentifier("connectorDetailsRetry")
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectorDetailsUnavailable")
    }
}

private struct ConnectorDetailsChrome: ViewModifier {
    let back: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connectorDetails")
            .padding(.top, MacMetrics.topBarHeight)
            .overlay(alignment: .topLeading) {
                SheetGlassButton(leading: .back, clear: true, accessibilityIdentifier: "connectorDetailsBack", action: back)
                    .padding(.top, PalMetrics.macPanelCloseTopInset)
                    .padding(.leading, PalMetrics.macPanelCloseLeadingInset)
            }
            .preference(key: MacPanelCloseKey.self, value: MacPanelCloseOverride(hidden: true))
        #else
        SheetChrome(leading: .back, accessibilityIdentifier: "connectorDetails", onLeading: back) { content }
        #endif
    }
}
