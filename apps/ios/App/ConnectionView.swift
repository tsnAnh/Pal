import HermesDesign
import SwiftUI

struct ConnectionForm: View {
    @Bindable var model: ConnectionModel

    @Environment(\.hermesTheme) private var theme

    private var cardFill: Color { Color(theme.palette.groupedCard) }

    var body: some View {
        Form {
            if !model.isConnected {
                Section("Hermes address") {
                    addressField
                        .urlEntry()
                        .accessibilityIdentifier("baseURLField")
                        .disabled(model.isBusy)
                        .listRowBackground(cardFill)
                    if model.usesPasswordSignIn {
                        credentialFields
                    }
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        HStack {
                            Text("Sign in")
                            if model.isBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("signInButton")
                    .listRowBackground(cardFill)
                }
            }
            Section("Status") {
                statusRow
                    .listRowBackground(cardFill)
            }
            if case .connected = model.phase {
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .foregroundStyle(Color(theme.palette.destructive))
                    .accessibilityIdentifier("signOutButton")
                    .listRowBackground(cardFill)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var credentialFields: some View {
        #if os(macOS)
        TextField("Username", text: $model.username, prompt: Text(verbatim: "Username"))
            .labelsHidden()
            .textContentType(.username)
            .autocorrectionDisabled()
            .disabled(model.isBusy)
            .accessibilityIdentifier("usernameField")
            .listRowBackground(cardFill)
        SecureField("Password", text: $model.password, prompt: Text(verbatim: "Password"))
            .labelsHidden()
            .textContentType(.password)
            .disabled(model.isBusy)
            .onSubmit { Task { await model.signIn() } }
            .accessibilityIdentifier("passwordField")
            .listRowBackground(cardFill)
        #endif
    }

    @ViewBuilder
    private var addressField: some View {
        #if os(macOS)
        TextField("Hermes address", text: $model.baseURLText, prompt: Text(verbatim: "https://your-host.tailnet.ts.net"))
            .labelsHidden()
            .onChange(of: model.baseURLText) { model.addressChanged() }
        #else
        TextField("https://your-host.tailnet.ts.net", text: $model.baseURLText)
        #endif
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .signedOut:
            Text("Not signed in")
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("statusLabel")
        case .signingIn:
            Text("Signing in")
                .accessibilityIdentifier("statusLabel")
        case .connecting:
            Text("Connecting")
                .accessibilityIdentifier("statusLabel")
        case .connected(let instanceID):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("statusLabel")
                Text(instanceID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("instanceIDLabel")
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(Color(theme.palette.destructive))
                .accessibilityIdentifier("errorLabel")
        }
    }
}

struct ConnectionView: View {
    @Bindable var model: ConnectionModel

    @State private var showsOptions = false

    @Environment(\.colorScheme) private var colorScheme

    private var tone: SignInTone { colorScheme == .dark ? .dark : .light }

    private var host: String? {
        guard let host = URL(string: model.baseURLText.trimmingCharacters(in: .whitespaces))?.host(), !host.isEmpty else { return nil }
        return host
    }

    private var needsOptions: Bool { host == nil || model.usesPasswordSignIn }

    var body: some View {
        ZStack {
            tone.background.ignoresSafeArea()
            SignInBackdrop()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                heading
                Spacer(minLength: 0)
                actions
            }
            .frame(maxWidth: SignInMetrics.columnWidth)
            .padding(.horizontal, SignInMetrics.margin)
            .padding(.bottom, SignInMetrics.bottomPadding)
        }
        .sheet(isPresented: Binding(get: { showsOptions && !model.isConnected }, set: { showsOptions = $0 })) {
            SignInOptionsSheet(model: model) { showsOptions = false }
                .macSheetFrame()
        }
    }

    private var heading: some View {
        VStack(spacing: SignInMetrics.titleToSubtitle) {
            Text(verbatim: "Pal")
                .font(.system(size: SignInMetrics.titleSize))
                .foregroundStyle(tone.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("signInTitle")
            Text("Your team of always-on Pals that finish the work")
                .font(.system(size: SignInMetrics.subtitleSize))
                .foregroundStyle(tone.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SignInMetrics.subtitleWidth)
        }
        .padding(.top, SignInMetrics.headingLift)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = model.phase, !showsOptions {
                Text(message)
                    .font(.system(size: SignInMetrics.footnoteSize))
                    .foregroundStyle(tone.errorText)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, SignInMetrics.errorToButton)
                    .accessibilityIdentifier("signInErrorMessage")
            }
            continueButton
            Button("Other options") { showsOptions = true }
                .buttonStyle(.plain)
                .font(.system(size: SignInMetrics.linkSize))
                .foregroundStyle(tone.secondaryText)
                .padding(.top, SignInMetrics.buttonToLink)
                .accessibilityIdentifier("otherOptionsButton")
            Text("By continuing, you connect Pal to the Hermes you run and sign in with your Hermes account.")
                .font(.system(size: SignInMetrics.footnoteSize))
                .foregroundStyle(tone.footnoteText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SignInMetrics.footnoteWidth)
                .padding(.top, SignInMetrics.linkToFootnote)
        }
    }

    private var continueButton: some View {
        Button {
            if needsOptions {
                showsOptions = true
            } else {
                Task { await model.signIn() }
            }
        } label: {
            ZStack {
                Text(continueTitle)
                    .font(.system(size: SignInMetrics.buttonTextSize))
                    .foregroundStyle(tone.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, SignInMetrics.buttonGlyphInset * 2 + SignInMetrics.buttonGlyphSize)
                HStack {
                    Group {
                        if model.isBusy {
                            ProgressView().controlSize(.small).tint(tone.primaryText)
                        } else {
                            Image(systemName: "server.rack")
                                .font(.system(size: SignInMetrics.buttonGlyphSize - 4, weight: .medium))
                                .foregroundStyle(tone.primaryText)
                        }
                    }
                    .frame(width: SignInMetrics.buttonGlyphSize, height: SignInMetrics.buttonGlyphSize)
                    Spacer(minLength: 0)
                }
                .padding(.leading, SignInMetrics.buttonGlyphInset)
            }
            .frame(maxWidth: .infinity, minHeight: SignInMetrics.buttonHeight)
            .background(tone.buttonFill, in: Capsule())
            .overlay(Capsule().strokeBorder(tone.buttonRim, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .capsule)
        .disabled(model.isBusy)
        .accessibilityIdentifier("continueButton")
    }

    private var continueTitle: String {
        if let host, !model.usesPasswordSignIn {
            return String(localized: "Continue to \(host)")
        }
        return String(localized: "Connect to your Hermes")
    }
}

private struct SignInOptionsSheet: View {
    @Bindable var model: ConnectionModel
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            ConnectionForm(model: model)
                .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
                .navigationTitle("Sign in")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close, action: close)
                            .accessibilityIdentifier("signInOptionsClose")
                    }
                }
        }
    }
}

private struct SignInBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(SignInFloater.all) { floater in
                        BotAvatarView(spec: floater.spec, size: floater.diameter / SignInMetrics.bodyFill, eyeInk: SignInMetrics.backdropEyes)
                            .position(floater.position(in: proxy.size, at: reduceMotion ? 0 : time))
                            .opacity(floater.opacity(at: reduceMotion ? 0 : time))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SignInFloater: Identifiable {
    let id: Int
    let kind: String
    let color: String
    let anchor: CGPoint
    let diameter: CGFloat
    let drift: CGFloat
    let period: Double
    let fades: Bool

    var spec: BotAvatarSpec {
        BotAvatarSpec(name: "pal-\(id)", meta: BotAvatarMeta(shape: "blobatar:signin\(id):\(kind)", color: color, custom: true))
    }

    func position(in size: CGSize, at time: Double) -> CGPoint {
        let phase = Double(id) * 1.7
        let angle = time * 2 * .pi / period + phase
        return CGPoint(
            x: anchor.x * size.width + drift * cos(angle),
            y: anchor.y * size.height + drift * sin(angle * 0.8)
        )
    }

    func opacity(at time: Double) -> Double {
        guard fades else { return 1 }
        let wave = 0.5 + 0.5 * sin(time * 2 * .pi / (period * 0.6) + Double(id))
        return 0.12 + 0.88 * wave
    }

    static let all: [SignInFloater] = [
        .init(id: 0, kind: "clover", color: "#0f7a3c", anchor: CGPoint(x: 0.28, y: 0.13), diameter: 100, drift: 10, period: 23, fades: true),
        .init(id: 1, kind: "round", color: "#ff1f8f", anchor: CGPoint(x: 0.64, y: 0.15), diameter: 72, drift: 9, period: 19, fades: false),
        .init(id: 2, kind: "round", color: "#8b4bff", anchor: CGPoint(x: 0.07, y: 0.30), diameter: 58, drift: 8, period: 21, fades: false),
        .init(id: 3, kind: "round", color: "#8a5a35", anchor: CGPoint(x: 0.97, y: 0.28), diameter: 62, drift: 8, period: 25, fades: false),
        .init(id: 4, kind: "round", color: "#ff8a00", anchor: CGPoint(x: 0.01, y: 0.48), diameter: 90, drift: 10, period: 27, fades: false),
        .init(id: 5, kind: "round", color: "#ff1f3d", anchor: CGPoint(x: 1.0, y: 0.47), diameter: 76, drift: 9, period: 24, fades: false),
        .init(id: 6, kind: "round", color: "#0bb39b", anchor: CGPoint(x: 0.89, y: 0.64), diameter: 68, drift: 9, period: 20, fades: true),
        .init(id: 7, kind: "boxy", color: "#1f6bff", anchor: CGPoint(x: 0.13, y: 0.68), diameter: 80, drift: 9, period: 22, fades: true),
    ]
}

struct SignInTone {
    let background: Color
    let buttonFill: Color
    let buttonRim: Color
    let primaryText: Color
    let secondaryText: Color
    let footnoteText: Color
    let errorText: Color

    static let dark = SignInTone(
        background: Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255),
        buttonFill: Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255),
        buttonRim: Color.white.opacity(0.12),
        primaryText: .white,
        secondaryText: Color(white: 0.6),
        footnoteText: Color(white: 0.36),
        errorText: Color(red: 1, green: 0.42, blue: 0.4)
    )

    static let light = SignInTone(
        background: Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255),
        buttonFill: .white,
        buttonRim: Color.black.opacity(0.08),
        primaryText: Color(white: 0.08),
        secondaryText: Color(white: 0.42),
        footnoteText: Color(white: 0.6),
        errorText: Color(red: 0.8, green: 0.15, blue: 0.12)
    )
}

enum SignInMetrics {
    static let backdropEyes = AvatarColor(css: "#111111")
    static let bodyFill: CGFloat = 0.76
    static let columnWidth: CGFloat = 430
    static let margin: CGFloat = 36
    static let titleSize: CGFloat = 38
    static let subtitleSize: CGFloat = 15
    static let subtitleWidth: CGFloat = 240
    static let titleToSubtitle: CGFloat = 12
    static let headingLift: CGFloat = 40
    static let buttonHeight: CGFloat = 47
    static let buttonTextSize: CGFloat = 15
    static let buttonGlyphSize: CGFloat = 24
    static let buttonGlyphInset: CGFloat = 14
    static let buttonToLink: CGFloat = 32
    static let linkSize: CGFloat = 15
    static let linkToFootnote: CGFloat = 38
    static let footnoteSize: CGFloat = 11
    static let footnoteWidth: CGFloat = 300
    static let errorToButton: CGFloat = 12
    static let bottomPadding: CGFloat = 24
}
