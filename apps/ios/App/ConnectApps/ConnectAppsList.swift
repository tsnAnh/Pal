import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import SwiftUI

struct ConnectAppsList: View {
    @Bindable var model: ConnectAppsModel
    #if os(macOS)
    @Environment(\.macWindowSize) var windowSize
    #endif

    var body: some View {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
    }

    @ViewBuilder
    var resumeBanner: some View {
        if model.trimmedQuery.isEmpty, let offer = model.resumeOffer {
            SetupResumeBanner(offer: offer) { model.continueSetup(offer) }
                .padding(.horizontal, PalMetrics.screenMargin)
                .padding(.bottom, PalMetrics.captionToCardGap)
        }
    }

    @ViewBuilder
    func content<Loaded: View>(@ViewBuilder loaded: () -> Loaded) -> some View {
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            DelayedProgressView().frame(maxWidth: .infinity).padding(.top, PalMetrics.cardGap).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            StatusBlock(status: SetupStatus(code: "offline"), identifierPrefix: "connectAppsUnavailable") { Task { await model.reload() } }
                .padding(.top, PalMetrics.cardGap)
        default:
            loaded()
        }
    }

    #if os(macOS)
    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous).strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .padding(.horizontal, PalMetrics.screenMargin)
    }
    #endif

    @ViewBuilder
    func sectionHeader(_ title: String, identifier: String) -> some View {
        #if os(macOS)
        ConnectSectionHeader(title, accessibilityIdentifier: identifier)
        #else
        ConnectFlatSectionHeader(title: title, identifier: identifier)
        #endif
    }

    @ViewBuilder
    func rowBlock<Data: RandomAccessCollection, Row: View>(
        _ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row
    ) -> some View where Data.Element: Identifiable {
        #if os(macOS)
        card { ForEach(data) { row($0) } }
        #else
        PalGlassContainer(spacing: 8) { ConnectFlatRows(data, row: row) }
        #endif
    }

    func skillResults(_ skills: [InstalledSkill]) -> some View {
        Group {
            sectionHeader(String(localized: "Skills"), identifier: "connectAppsSection-skills")
            rowBlock(skills) { skill in
                #if os(macOS)
                ConnectAppRow(
                    title: skill.name, summary: skill.category, accessibilityIdentifier: "skill-\(skill.id)",
                    inset: PalMetrics.screenMargin, trailing: nil
                ) { PluginGlyphTile() }
                #else
                ConnectFlatRow(
                    title: skill.name, subtitle: skill.category, identifier: "skill-\(skill.id)",
                    icon: { PluginGlyphTile() }, trailing: { EmptyView() }
                )
                #endif
            }
        }
    }

    @ViewBuilder
    var capabilitiesSection: some View {
        switch model.capabilitiesPhase {
        case .hidden:
            EmptyView()
        case .loading:
            sectionHeader(String(localized: "Capabilities"), identifier: "capabilitiesTitle")
            DelayedProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, PalMetrics.screenMargin)
                .accessibilityIdentifier("capabilitiesLoading")
        case .failed:
            sectionHeader(String(localized: "Capabilities"), identifier: "capabilitiesTitle")
            Text("Couldn't load capabilities")
                .font(.system(size: ConnectRowMetrics.captionSize))
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.horizontal, PalMetrics.screenMargin)
                .accessibilityIdentifier("capabilitiesError")
        case .ready(let rows):
            if !rows.isEmpty {
                sectionHeader(String(localized: "Capabilities"), identifier: "capabilitiesTitle")
                rowBlock(rows) { row in
                    CapabilityListRow(row: row, onSetKey: model.canSetKeys ? { model.beginKeyEntry(row, keyName: $0) } : nil)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capabilitiesList")
            }
        }
    }
}
