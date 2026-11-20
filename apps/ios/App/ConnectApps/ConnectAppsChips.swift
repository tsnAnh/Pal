import PalConnect
import PalDesign
import SwiftUI

struct ConnectAppsChips: View {
    @Bindable var model: ConnectAppsModel
    let bar: ConnectChipBar

    private var isSearching: Bool { !model.trimmedQuery.isEmpty }

    var body: some View {
        #if os(macOS)
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                chips
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsChips")
        #else
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) { chips }
            }
        }
        .contentMargins(.horizontal, PalMetrics.screenMargin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsChips")
        #endif
    }

    @ViewBuilder
    private var chips: some View {
        chip(String(localized: "All"), .all, identifier: "all")
        chip(model.devices.thisDevice.title, .thisDevice, identifier: "device")
        ForEach(bar.leading, id: \.self) { name in chip(name, .category(name), identifier: name) }
        if !bar.more.isEmpty { moreMenu }
    }

    private func isSelected(_ value: ConnectChip) -> Bool { !isSearching && model.chip == value }

    private func chip(_ title: String, _ value: ConnectChip, identifier: String) -> some View {
        Button { model.selectChip(value) } label: { Text(title) }
            .buttonStyle(.palClearChip(selected: isSelected(value)))
            .accessibilityAddTraits(isSelected(value) ? .isSelected : [])
            .accessibilityIdentifier("connectAppsChip-\(identifier)")
    }

    private var moreSelected: Bool { !isSearching && bar.moreIsSelected(model.chip) }

    private var moreTitle: String {
        if moreSelected, case .category(let name) = model.chip { name } else { String(localized: "More") }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(bar.more, id: \.self) { name in
                Button(name) { model.selectChip(.category(name)) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(moreTitle)
                PalIcon("chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .buttonStyle(.palClearChip(selected: moreSelected))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("connectAppsChip-more")
    }
}
