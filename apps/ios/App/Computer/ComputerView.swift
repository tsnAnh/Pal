import HermesBotProfile
import HermesDesign
import SwiftUI

struct ComputerView: View {
    @State private var model: ComputerModel
    let title: String
    let spec: BotAvatarSpec?

    @Environment(\.dismiss) private var dismiss

    init(model: ComputerModel, title: String, spec: BotAvatarSpec?) {
        _model = State(initialValue: model)
        self.title = title
        self.spec = spec
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityIdentifier("computerScreen")
            if model.phase == .live {
                ComputerSurface(
                    image: model.frame,
                    remoteSize: model.remoteSize,
                    canControl: model.hasControl,
                    trackpad: model.trackpad,
                    keyboardShown: model.keyboardShown,
                    recenterToken: model.recenterToken,
                    model: model
                )
                #if os(iOS)
                .ignoresSafeArea(.container)
                #endif
                .accessibilityLabel(Text("Computer screen"))
            } else {
                overlayState
            }
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("computerStatus")
                #if os(macOS)
                .accessibilityLabel(Text(model.statusLabel))
                #else
                .accessibilityValue(Text(model.statusLabel))
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { bottomBar }
        .navigationBarBackButtonHidden()
        .clearNavigationBackground()
        .toolbar { toolbar }
        .toolbarTitleDisplayMode(.inline)
        .task(id: model.attempt) { await model.run() }
        .sheet(isPresented: $model.showsHelp) { ComputerHelpSheet { model.showsHelp = false } }
        .toast($model.toast)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .leadingBar) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(Text("Back"))
                .accessibilityIdentifier("computerBackButton")
                .tint(.primary)
        }
        #endif
        ToolbarItem(placement: .principal) {
            HStack(spacing: ComputerMetrics.avatarToName) {
                if let spec { BotAvatarView(spec: spec, size: ComputerMetrics.avatarSize) }
                Text(title)
                    .font(.system(size: ComputerMetrics.titleSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier("computerTitle")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .trailingBar) {
            Button { model.showsHelp = true } label: { Image(systemName: "questionmark") }
                .accessibilityLabel(Text("Help"))
                .accessibilityIdentifier("computerHelpButton")
                .tint(.primary)
        }
    }

    private var overlayState: some View {
        stateContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.phase {
        case .connecting, .live:
            VStack(spacing: ComputerMetrics.spinnerToText) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Color(white: 0.45))
                Text("Connecting…")
                    .font(.system(size: ComputerMetrics.statusSize))
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("computerConnecting")
        case .unavailable(let failure):
            failureState(message: Self.message(for: failure), retry: failure != .unavailable && failure != .notSetUp)
        case .lost:
            failureState(message: String(localized: "Lost the connection to this computer"), retry: true)
        }
    }

    private func failureState(message: String, retry: Bool) -> some View {
        VStack(spacing: 18) {
            Text(message)
                .font(.system(size: ComputerMetrics.statusSize))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("computerFailureMessage")
            if retry {
                Button("Try again") { model.retry() }
                    .buttonStyle(ComputerPillStyle())
                    .accessibilityIdentifier("computerRetry")
            }
        }
        .padding(.horizontal, 40)
    }

    private static func message(for failure: ComputerFailure) -> String {
        switch failure {
        case .unavailable: String(localized: "This computer isn't available right now")
        case .notSetUp: String(localized: "This computer isn't set up yet")
        case .lowMemory: String(localized: "There isn't enough memory to start this computer right now")
        case .notAllowed: String(localized: "You can't view this computer")
        case .staleViewer, .offline: String(localized: "Couldn't reach this computer")
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: ComputerMetrics.barSpacing) {
            if model.hasControl {
                controlTools
                Spacer(minLength: 0)
                Button("I'm done") { Task { await model.handBack() } }
                    .buttonStyle(ComputerPillStyle())
                    .accessibilityIdentifier("computerImDone")
            } else if model.phase == .connecting || model.phase == .live {
                Spacer(minLength: 0)
                Button("Take control") { Task { await model.takeControl() } }
                    .buttonStyle(ComputerPillStyle())
                    .disabled(!model.canAct || model.isTakingControl)
                    .accessibilityIdentifier("computerTakeControl")
            }
        }
        .padding(.horizontal, ComputerMetrics.barMargin)
        .padding(.bottom, ComputerMetrics.barBottom)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var controlTools: some View {
        HStack(spacing: ComputerMetrics.barSpacing) {
            if PlatformCapabilities.hasTouchScreen {
                Button { model.keyboardShown.toggle() } label: { ComputerToolIcon(systemName: "keyboard") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Keyboard"))
                    .accessibilityIdentifier("computerKeyboardButton")
            }
            Menu {
                Button(DeviceWording.copyToDevice, systemImage: DeviceWording.deviceSystemImage) { Task { await model.copyToPhone() } }
                    .accessibilityIdentifier("computerCopyToPhone")
                Button(DeviceWording.pasteFromDevice, systemImage: "doc.on.clipboard") { model.pasteFromPhone() }
                    .accessibilityIdentifier("computerPasteFromPhone")
            } label: { ComputerToolIcon(systemName: "list.clipboard") }
                .accessibilityLabel(Text("Clipboard"))
                .accessibilityIdentifier("computerClipboardButton")
            if PlatformCapabilities.hasTouchScreen {
                Menu {
                    Toggle("Trackpad mode", systemImage: "rectangle.and.hand.point.up.left", isOn: $model.trackpad)
                        .accessibilityIdentifier("computerTrackpadToggle")
                    if model.trackpad {
                        Button("Recenter pointer", systemImage: "scope") { model.recenterPointer() }
                            .accessibilityIdentifier("computerRecenter")
                    }
                } label: { ComputerToolIcon(systemName: "ellipsis") }
                    .accessibilityLabel(Text("More"))
                    .accessibilityIdentifier("computerMoreButton")
            }
        }
    }
}

enum ComputerMetrics {
    static let avatarSize: CGFloat = 26
    static let avatarToName: CGFloat = 9
    static let titleSize: CGFloat = 15
    static let statusSize: CGFloat = 12.5
    static let spinnerToText: CGFloat = 14
    static let pillHeight: CGFloat = 38
    static let pillTextSize: CGFloat = 12
    static let pillPadding: CGFloat = 13
    static let barMargin: CGFloat = 30
    static let barBottom: CGFloat = 30
    static let barSpacing: CGFloat = 10
}

enum ComputerChrome {
    static let fill = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
}

struct ComputerToolIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: ComputerMetrics.pillHeight + 8, height: ComputerMetrics.pillHeight)
            .background(ComputerChrome.fill, in: Capsule())
            .contentShape(Capsule())
    }
}

struct ComputerPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ComputerMetrics.pillTextSize))
            .foregroundStyle(.white)
            .padding(.horizontal, ComputerMetrics.pillPadding)
            .frame(height: ComputerMetrics.pillHeight)
            .background(ComputerChrome.fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
