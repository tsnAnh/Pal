import PalDesign
import SwiftUI

struct VoiceModeView: View {
    let model: ChatModel
    let dismiss: () -> Void

    @State private var conversation: VoiceConversation
    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ChatModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _conversation = State(initialValue: VoiceConversation(
            currentTurn: { model.voiceTurn },
            submit: { await model.submitVoice($0) }
        ))
    }

    private var accent: Color { model.chatAccent?.accent ?? Color(theme.palette.chipSelectedFill) }

    private var mood: AvatarMood {
        switch conversation.phase {
        case .thinking: .think
        case .speaking: .work
        default: .idle
        }
    }

    private var statusText: String {
        switch conversation.phase {
        case .starting: String(localized: "Getting ready…")
        case .listening: String(localized: "Listening…")
        case .thinking: String(localized: "Thinking…")
        case .speaking: String(localized: "Speaking…")
        case .failed(let message): message
        }
    }

    var body: some View {
        ZStack {
            Color(theme.palette.canvas).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                orb
                Text(model.bot.displayName)
                    .hermesText(.sheetTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                Text(statusText)
                    .hermesText(.chatStatus)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("voiceModeStatus")
                Text(conversation.transcript)
                    .hermesText(.chatBody)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 32)
                    .frame(minHeight: 80, alignment: .top)
                    .accessibilityIdentifier("voiceModeTranscript")
                Spacer()
                controls
            }
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceModeScreen")
        .task { await conversation.begin() }
        .onChange(of: model.voiceReply) { _, reply in conversation.ingest(reply) }
        .onDisappear { conversation.end() }
    }

    private var orb: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let energy = conversation.phase == .listening || conversation.phase == .speaking ? 1.0 : 0.4
            let pulse = 1 + 0.06 * energy * sin(time * 3)
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 260, height: 260)
                    .scaleEffect(pulse * 1.08)
                Circle()
                    .fill(accent.opacity(0.28))
                    .frame(width: 220, height: 220)
                    .scaleEffect(pulse)
                BotAvatarView(spec: model.bot.spec, size: 160, mood: mood)
            }
        }
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 24) {
            if case .failed = conversation.phase {
                voiceButton("arrow.clockwise", label: "Try again", id: "voiceModeRetry") { conversation.retry() }
            } else {
                voiceButton("hand.raised.fill", label: "Interrupt", id: "voiceModeInterrupt") { conversation.interrupt() }
                    .opacity(conversation.phase == .speaking || conversation.phase == .thinking ? 1 : 0.35)
                    .disabled(conversation.phase != .speaking && conversation.phase != .thinking)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent == Color(theme.palette.chipSelectedFill) ? Color(theme.palette.chipSelectedText) : (model.chatAccent?.foreground ?? .white))
                    .frame(width: 64, height: 64)
                    .background(accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End voice mode"))
            .accessibilityIdentifier("voiceModeClose")
        }
    }

    private func voiceButton(_ systemName: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(width: 64, height: 64)
                .background(Color(theme.palette.circleButtonFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}
