#if os(macOS)
import PalDesign
import SwiftUI

enum MacComputerMetrics {
    static let screenInset: CGFloat = 32
    static let screenTop: CGFloat = 52
    static let screenRadius: CGFloat = 8
    static let collapseTop: CGFloat = MacMetrics.topBarCenter - 33 / 2
    static let collapseTrailing: CGFloat = 12
    static let barHeight: CGFloat = 40
    static let barPadding: CGFloat = 4
    static let barBottom: CGFloat = 12
    static let screenBottom: CGFloat = barHeight + barBottom * 2
    static let segmentPadding: CGFloat = 14
    static let textSize: CGFloat = 13
}

struct MacComputerBar: View {
    let model: ComputerModel
    let teach: TeachModel

    private var isActive: Bool { model.phase == .connecting || model.phase == .live }

    var body: some View {
        if isActive {
            HStack(spacing: 2) {
                status
                if model.hasControl {
                    clipboard
                }
                if teach.canStart {
                    Button("Teach a skill") { Task { await teach.start() } }
                        .glassButtonStyle()
                        .accessibilityIdentifier("computerTeachSkill")
                }
                primary
            }
            .padding(MacComputerMetrics.barPadding)
            .palClearGlass(Capsule(), interactive: false)
            .padding(.bottom, MacComputerMetrics.barBottom)
        }
    }

    private var status: some View {
        Label {
            Text(model.hasControl ? "In control" : "Watching")
        } icon: {
            PalIcon(model.hasControl ? "cursorarrow" : "eye", ink: .secondary)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .font(.system(size: MacComputerMetrics.textSize))
        .foregroundStyle(PalTokens.textSecondary)
        .padding(.horizontal, MacComputerMetrics.segmentPadding)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("computerMode")
    }

    private var clipboard: some View {
        Menu {
            Button { Task { await model.copyToPhone() } } label: { Label(DeviceWording.copyToDevice, palIcon: DeviceWording.deviceSystemImage) }
                .accessibilityIdentifier("computerCopyToPhone")
            Button { model.pasteFromPhone() } label: { Label(DeviceWording.pasteFromDevice, palIcon: "doc.on.clipboard") }
                .accessibilityIdentifier("computerPasteFromPhone")
        } label: {
            PalIcon("list.clipboard")
                .font(.system(size: MacComputerMetrics.textSize))
        }
        .menuStyle(.button)
        .glassButtonStyle()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Clipboard"))
        .accessibilityIdentifier("computerClipboardButton")
    }

    @ViewBuilder
    private var primary: some View {
        if model.hasControl {
            Button("I'm done") { Task { await model.handBack() } }
                .glassButtonStyle(prominent: true)
                .accessibilityIdentifier("computerImDone")
        } else {
            Button("Take control") { Task { await model.takeControl() } }
                .glassButtonStyle(prominent: true)
                .disabled(!model.canAct || model.isTakingControl)
                .accessibilityIdentifier("computerTakeControl")
        }
    }
}

struct MacComputerCorner: View {
    let help: () -> Void
    let collapse: () -> Void

    var body: some View {
        PalGlassContainer {
            HStack(spacing: 8) {
                MacIconButton(systemName: "questionmark", label: String(localized: "Help"), identifier: "computerHelpButton", action: help)
                MacIconButton(
                    systemName: "arrow.down.right.and.arrow.up.left", label: String(localized: "Collapse"),
                    identifier: "computerCollapse", action: collapse
                )
            }
        }
        .padding(.top, MacComputerMetrics.collapseTop)
        .padding(.trailing, MacComputerMetrics.collapseTrailing)
    }
}

extension View {
    func macComputerScreenFrame() -> some View {
        clipShape(RoundedRectangle(cornerRadius: MacComputerMetrics.screenRadius, style: .continuous))
            .padding(.horizontal, MacComputerMetrics.screenInset)
            .padding(.top, MacComputerMetrics.screenTop)
            .padding(.bottom, MacComputerMetrics.screenBottom)
    }
}
#endif
