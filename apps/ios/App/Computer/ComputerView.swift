import PalBotProfile
import PalDesign
import SwiftUI

struct ComputerView: View {
    @State private var model: ComputerModel
    let teach: TeachModel
    let title: String
    let spec: BotAvatarSpec?

    @Environment(\.dismiss) private var dismiss

    init(model: ComputerModel, teach: TeachModel, title: String, spec: BotAvatarSpec?) {
        _model = State(initialValue: model)
        self.teach = teach
        self.title = title
        self.spec = spec
    }

    var body: some View {
        ZStack {
            ComputerChrome.background
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityIdentifier("computerScreen")
            if model.phase == .live {
                ComputerSurface(
                    frames: model.frames,
                    remoteSize: model.remoteSize,
                    canControl: model.hasControl,
                    trackpad: model.trackpad,
                    keyboardShown: model.keyboardShown,
                    recenterToken: model.recenterToken,
                    model: model
                )
                .iOSOnly { $0.ignoresSafeArea(.container) }
                #if os(macOS)
                .macComputerScreenFrame()
                #endif
                .accessibilityLabel(Text("Computer screen"))
            } else {
                overlayState
            }
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("computerStatus")
                .macOnly { $0.accessibilityLabel(Text(model.statusLabel)) }
                .iOSOnly { $0.accessibilityValue(Text(model.statusLabel)) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { TeachBanner(model: teach, surface: .computer) }
        .overlay(alignment: .bottom) { bottomBar }
        #if os(macOS)
        .overlay(alignment: .topTrailing) { MacComputerCorner(help: { model.showsHelp = true }, collapse: { dismiss() }) }
        #endif
        .clearNavigationBackground()
        .darkNavigationBar()
        .toolbar { toolbar }
        .toolbarTitleDisplayMode(.inline)
        .task(id: model.attempt) { await model.run() }
        .onAppear {
            teach.control = TeachControl(
                acquire: { [model] in await model.controlForTeaching() },
                release: { [model] in await model.handBack() }
            )
        }
        .onDisappear { teach.control = nil }
        .onChange(of: model.phase == .live, initial: true) { _, live in teach.setScreenLive(live) }
        .teachPresentations(teach, surface: .computer)
        .macSheet(isPresented: $model.showsHelp, size: .flow) { ComputerHelpSheet { model.showsHelp = false } }
        .toast($model.toast)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
        #if os(iOS)
        ToolbarItem(placement: .trailingBar) {
            Button { model.showsHelp = true } label: { PalIcon("questionmark") }
                .accessibilityLabel(Text("Help"))
                .accessibilityIdentifier("computerHelpButton")
        }
        #endif
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
            DelayedReveal {
                VStack(spacing: ComputerMetrics.spinnerToText) {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Color(white: 0.45))
                    Text("Connecting…")
                        .font(.system(size: ComputerMetrics.statusSize))
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)
            }
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
                    .buttonStyle(.glass)
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
        #if os(macOS)
        MacComputerBar(model: model, teach: teach)
        #else
        HStack(spacing: ComputerMetrics.barSpacing) {
            if model.hasControl {
                controlTools
                if teach.canStart {
                    Button("Teach a skill") { Task { await teach.start() } }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("computerTeachSkill")
                }
                Spacer(minLength: 0)
                Button("I'm done") { Task { await model.handBack() } }
                    .glassButtonStyle(prominent: true)
                    .accessibilityIdentifier("computerImDone")
            } else if model.phase == .connecting || model.phase == .live {
                if teach.canStart {
                    Button("Teach a skill") { Task { await teach.start() } }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("computerTeachSkill")
                }
                Spacer(minLength: 0)
                Button("Take control") { Task { await model.takeControl() } }
                    .glassButtonStyle(prominent: true)
                    .disabled(!model.canAct || model.isTakingControl)
                    .accessibilityIdentifier("computerTakeControl")
            }
        }
        .padding(.horizontal, ComputerMetrics.barMargin)
        .padding(.bottom, ComputerMetrics.barBottom)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
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
                Button { Task { await model.copyToPhone() } } label: { Label(DeviceWording.copyToDevice, palIcon: DeviceWording.deviceSystemImage) }
                    .accessibilityIdentifier("computerCopyToPhone")
                Button { model.pasteFromPhone() } label: { Label(DeviceWording.pasteFromDevice, palIcon: "doc.on.clipboard") }
                    .accessibilityIdentifier("computerPasteFromPhone")
            } label: { ComputerToolIcon(systemName: "list.clipboard") }
                .accessibilityLabel(Text("Clipboard"))
                .accessibilityIdentifier("computerClipboardButton")
            if PlatformCapabilities.hasTouchScreen {
                Menu {
                    Toggle(isOn: $model.trackpad) { Label("Trackpad mode", palIcon: "rectangle.and.hand.point.up.left") }
                        .accessibilityIdentifier("computerTrackpadToggle")
                    if model.trackpad {
                        Button { model.recenterPointer() } label: { Label("Recenter pointer", palIcon: "scope") }
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
    static let barMargin: CGFloat = 30
    static let barBottom: CGFloat = 30
    static let barSpacing: CGFloat = 10
}

enum ComputerChrome {
    static let fill = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
    #if os(macOS)
    static let background = PalTokens.content
    #else
    static let background = Color.black
    #endif
}

struct ComputerToolIcon: View {
    let systemName: String

    var body: some View {
        PalIcon(systemName, ink: .onFill)
            .font(.system(size: 17, weight: .regular))
            .frame(width: ComputerMetrics.pillHeight + 8, height: ComputerMetrics.pillHeight)
            .background(ComputerChrome.fill, in: Capsule())
            .contentShape(Capsule())
    }
}

private extension View {
    func darkNavigationBar() -> some View {
        #if os(iOS)
        toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
