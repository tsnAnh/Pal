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
            Color.black.ignoresSafeArea()
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
                .ignoresSafeArea(.container)
                .accessibilityLabel(Text("Computer screen"))
            } else {
                overlayState
            }
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("computerStatus")
                .accessibilityValue(Text(model.statusLabel))
        }
        .overlay(alignment: .bottom) { bottomBar }
        .accessibilityIdentifier("computerScreen")
        .navigationBarBackButtonHidden()
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        .toolbarTitleDisplayMode(.inline)
        .task(id: model.attempt) { await model.run() }
        .sheet(isPresented: $model.showsHelp) { ComputerHelpSheet { model.showsHelp = false } }
        .toast($model.toast)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { ComputerChromeCircle(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))
                .accessibilityIdentifier("computerBackButton")
        }
        .sharedBackgroundVisibility(.hidden)
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
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.showsHelp = true } label: { ComputerChromeCircle(systemName: "questionmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Help"))
                .accessibilityIdentifier("computerHelpButton")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ViewBuilder
    private var overlayState: some View {
        switch model.phase {
        case .connecting, .live:
            VStack(spacing: ComputerMetrics.spinnerToText) {
                ProgressView()
                    .controlSize(.large)
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
            Button { model.keyboardShown.toggle() } label: { ComputerToolIcon(systemName: "keyboard") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Keyboard"))
                .accessibilityIdentifier("computerKeyboardButton")
            Menu {
                Button("Copy to Phone", systemImage: "iphone") { Task { await model.copyToPhone() } }
                    .accessibilityIdentifier("computerCopyToPhone")
                Button("Paste from Phone", systemImage: "doc.on.clipboard") { model.pasteFromPhone() }
                    .accessibilityIdentifier("computerPasteFromPhone")
            } label: { ComputerToolIcon(systemName: "list.clipboard") }
                .accessibilityLabel(Text("Clipboard"))
                .accessibilityIdentifier("computerClipboardButton")
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

enum ComputerMetrics {
    static let avatarSize: CGFloat = 26
    static let avatarToName: CGFloat = 9
    static let titleSize: CGFloat = 17
    static let statusSize: CGFloat = 16
    static let spinnerToText: CGFloat = 14
    static let chromeDiameter: CGFloat = 44
    static let pillHeight: CGFloat = 38
    static let pillPadding: CGFloat = 14
    static let barMargin: CGFloat = 30
    static let barBottom: CGFloat = 30
    static let barSpacing: CGFloat = 10
}

enum ComputerChrome {
    static let fill = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
}

struct ComputerChromeCircle: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: ComputerMetrics.chromeDiameter, height: ComputerMetrics.chromeDiameter)
            .background(ComputerChrome.fill, in: Circle())
            .contentShape(Circle())
    }
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.5))
            .padding(.horizontal, ComputerMetrics.pillPadding)
            .frame(height: ComputerMetrics.pillHeight)
            .background(ComputerChrome.fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
