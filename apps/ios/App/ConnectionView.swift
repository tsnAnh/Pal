import PalAuth
import PalDesign
import SwiftUI

struct ConnectionView: View {
    @Bindable var model: ConnectionModel

    @FocusState private var focus: SignInField?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var tone: SignInTone { colorScheme == .dark ? .dark : .light }

    private var isCompact: Bool {
        #if os(iOS)
        focus != nil
        #else
        false
        #endif
    }

    private var errorMessage: String? {
        if case .failed(let message) = model.phase { return message }
        switch model.discovery {
        case .unreachable: return String(localized: "Pal couldn't reach this server. Check the address and that the server is running.")
        case .noMethods: return String(localized: "This server has no Pal account sign-in. Set up a username and password on it first.")
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCompact {
                heading
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                heading
                Spacer(minLength: 0)
            }
            actions
        }
        .frame(maxWidth: SignInMetrics.columnWidth)
        .padding(.horizontal, SignInMetrics.margin)
        .padding(.bottom, SignInMetrics.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .signInBackdrop(gathered: isCompact, ring: tone.background)
        .background { tone.background.ignoresSafeArea() }
        .animation(reduceMotion ? nil : .snappy, value: isCompact)
        .animation(.snappy, value: model.discovery)
        .onChange(of: model.phase) { _, phase in
            guard case .failed = phase, model.account != nil else { return }
            focus = .password
        }
        .localEngineSetup(model)
    }

    private var heading: some View {
        VStack(spacing: 0) {
            SignInLineupSlot(gathered: isCompact)
                .padding(.bottom, isCompact ? SignInMetrics.lineupToTitle : 0)
            Text(verbatim: "Pal")
                .font(.system(size: isCompact ? SignInMetrics.compactTitleSize : SignInMetrics.titleSize))
                .foregroundStyle(tone.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("signInTitle")
            Text("Your team of always-on Pals that finish the work")
                .font(.system(size: SignInMetrics.subtitleSize))
                .foregroundStyle(tone.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SignInMetrics.subtitleWidth)
                .padding(.top, isCompact ? SignInMetrics.compactTitleToSubtitle : SignInMetrics.titleToSubtitle)
        }
        .padding(.top, isCompact ? SignInMetrics.compactHeadingTop : SignInMetrics.headingLift)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            localEngineRunningCard
            card
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: SignInMetrics.errorSize))
                    .foregroundStyle(tone.errorText)
                    .multilineTextAlignment(.center)
                    .padding(.top, SignInMetrics.cardToMessage)
                    .accessibilityIdentifier("errorLabel")
            }
            primaryButton
                .padding(.top, SignInMetrics.messageToButton)
            if showsLocalEngineSetup {
                orDivider
                localEngineSetupButton
                localEngineHelper
            }
            if !isCompact {
                Text("By continuing, you connect Pal to your own server and sign in with your Pal account.")
                    .font(.system(size: SignInMetrics.footnoteSize))
                    .foregroundStyle(tone.footnoteText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: SignInMetrics.footnoteWidth)
                    .padding(.top, SignInMetrics.buttonToFootnote)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            addressRow
            if model.account != nil {
                rowDivider
                usernameRow
                rowDivider
                passwordRow
            }
        }
        .background(tone.buttonFill, in: RoundedRectangle(cornerRadius: SignInMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: SignInMetrics.cardRadius).strokeBorder(tone.buttonRim, lineWidth: 1))
        .opacity(model.isBusy ? SignInMetrics.busyOpacity : 1)
        .disabled(model.isBusy)
    }

    private var rowDivider: some View {
        Rectangle().fill(tone.buttonRim).frame(height: 1)
    }

    private func row<Field: View, Trailing: View>(
        icon: String,
        @ViewBuilder field: () -> Field,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: SignInMetrics.rowSpacing) {
            PalIcon(icon, ink: .custom(tone.secondaryText))
                .font(.system(size: SignInMetrics.rowGlyphSize))
                .frame(width: SignInMetrics.rowGlyphWidth)
            field()
                .font(.system(size: SignInMetrics.rowTextSize))
                .foregroundStyle(tone.primaryText)
            trailing()
        }
        .padding(.horizontal, SignInMetrics.rowInset)
        .frame(minHeight: SignInMetrics.rowHeight)
    }

    private var addressRow: some View {
        row(icon: "server.rack") {
            addressField
                .urlEntry()
                .focused($focus, equals: .address)
                .submitLabel(model.account == nil ? .go : .next)
                .onSubmit {
                    if model.account != nil { focus = .username } else { submit() }
                }
                .accessibilityIdentifier("baseURLField")
        } trailing: {
            switch model.discovery {
            case .checking:
                HStack(spacing: SignInMetrics.checkingSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Checking")
                }
                .font(.system(size: SignInMetrics.checkingSize))
                .foregroundStyle(tone.secondaryText)
            case .ready:
                PalIcon("checkmark", ink: .custom(tone.secondaryText))
                    .font(.system(size: SignInMetrics.checkingSize, weight: .semibold))
            default:
                EmptyView()
            }
        }
    }

    private var usernameRow: some View {
        row(icon: "person") {
            PalTextField("Username", text: $model.username, prompt: Text(verbatim: "Username"))
                .labelsHidden()
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .accessibilityIdentifier("usernameField")
        }
    }

    private var passwordRow: some View {
        row(icon: "key") {
            PalTextField("Password", text: $model.password, prompt: Text(verbatim: "Password"), isSecure: true)
                .labelsHidden()
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { submit() }
                .accessibilityIdentifier("passwordField")
        }
    }

    @ViewBuilder
    private var addressField: some View {
        Group {
            #if os(macOS)
            PalTextField("Pal address", text: $model.baseURLText, prompt: Text(verbatim: "https://your-host.tailnet.ts.net"))
                .labelsHidden()
            #else
            PalTextField("https://your-host.tailnet.ts.net", text: $model.baseURLText)
            #endif
        }
        .onChange(of: model.baseURLText, initial: true) { model.addressChanged() }
    }
}

extension ConnectionView {
    private var primaryTitle: String {
        if model.isBusy { return String(localized: "Signing in") }
        switch model.discovery {
        case .unknown, .checking: return String(localized: "Continue")
        case .unreachable, .noMethods: return String(localized: "Try again")
        case .ready: return String(localized: "Sign in")
        }
    }

    private var primaryEnabled: Bool {
        if model.isBusy { return false }
        switch model.discovery {
        case .unknown, .checking: return false
        default: return true
        }
    }

    private func submit() {
        guard primaryEnabled else { return }
        switch model.discovery {
        case .ready:
            guard let account = model.account else { return }
            focus = nil
            Task { await model.signIn(with: account) }
        case .unreachable, .noMethods:
            model.retryDiscovery()
        default:
            break
        }
    }

    private var primaryButton: some View {
        Button(action: submit) {
            capsuleLabel(primaryTitle, leading: primaryLeading)
                .foregroundStyle(tone.background)
        }
        .glassButtonStyle(prominent: true, tint: tone.primaryText)
        .buttonBorderShape(.capsule)
        .disabled(!primaryEnabled)
        .accessibilityIdentifier("signInButton")
    }

    @ViewBuilder
    private var primaryLeading: some View {
        if model.isBusy {
            ProgressView().controlSize(.small).tint(tone.background)
        }
    }

    func capsuleLabel<Leading: View>(_ title: String, leading: Leading) -> some View {
        Text(title)
            .font(.system(size: SignInMetrics.buttonTextSize))
            .lineLimit(1)
            .padding(.horizontal, SignInMetrics.buttonGlyphInset * 2 + SignInMetrics.buttonGlyphSize)
            .frame(maxWidth: .infinity, minHeight: SignInMetrics.buttonHeight)
            .overlay(alignment: .leading) {
                leading
                    .font(.system(size: SignInMetrics.buttonGlyphSize - 8, weight: .medium))
                    .frame(width: SignInMetrics.buttonGlyphSize, height: SignInMetrics.buttonGlyphSize)
                    .padding(.leading, SignInMetrics.buttonGlyphInset)
            }
    }

    var orDivider: some View {
        HStack(spacing: SignInMetrics.rowSpacing) {
            Rectangle().fill(tone.buttonRim).frame(height: 1)
            Text("or")
                .font(.system(size: SignInMetrics.footnoteSize + 1))
                .foregroundStyle(tone.footnoteText)
            Rectangle().fill(tone.buttonRim).frame(height: 1)
        }
        .padding(.top, SignInMetrics.orTop)
        .padding(.bottom, SignInMetrics.secondarySpacing)
    }
}

private enum SignInField: Hashable {
    case address
    case username
    case password
}
