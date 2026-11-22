import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct ChatDeskCardView: View {
    let card: ChatDeskCard
    let botName: String
    let decide: (ChatDeskChoice) -> Void

    static let maxWidth: CGFloat = 520

    private var item: ChatDeskItemWire { card.item }
    private var requesterName: String { item.requester?.name.isEmpty == false ? item.requester?.name ?? "" : String(localized: "Someone") }
    private var firstName: String { requesterName.split(separator: " ").first.map(String.init) ?? requesterName }
    private var isSending: Bool { if case .sending = card.answer { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            request
            if item.state == .open, !details.isEmpty { detailRows }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                .strokeBorder(PalTokens.panelBorder, lineWidth: PalMetrics.separatorThickness)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deskCard-\(item.id)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            SlackMark().frame(width: 12, height: 12).accessibilityHidden(true)
            Text("From Slack").hermesText(.footnoteCaption).foregroundStyle(PalTokens.textTertiary)
            Spacer(minLength: 0)
            Text(Date(timeIntervalSince1970: item.createdAt), style: .time)
                .hermesText(.footnoteCaption)
                .foregroundStyle(PalTokens.textTertiary)
        }
    }

    private var request: some View {
        HStack(alignment: .top, spacing: 10) {
            PersonBadge(name: item.kind == .send ? botName : requesterName, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if item.kind == .send {
                        Text("\(botName) wants to send:")
                    } else {
                        Text("\(requesterName) asked \(botName) to:")
                    }
                }
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                Text(item.text)
                    .hermesText(.rowTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(PalTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deskCardText-\(item.id)")
            }
        }
    }

    private var details: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if !item.place.label.isEmpty { rows.append((String(localized: "Where"), item.place.label)) }
        if item.kind == .send {
            rows.append((String(localized: "Changes"), String(localized: "Sends a message as \(botName)")))
        } else if item.kind == .handoff {
            rows.append((String(localized: "Asked by"), requesterName))
        }
        if let why = item.why, !why.isEmpty { rows.append((String(localized: "Why"), why)) }
        return rows
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(details.enumerated()), id: \.offset) { offset, row in
                if offset > 0 { PalHairline() }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary).frame(width: 72, alignment: .leading)
                    Text(row.value).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var footer: some View {
        switch item.state {
        case .open:
            decision
        case .approved, .executing:
            resolved(symbol: "checkmark.circle", text: String(localized: "You allowed this once. \(botName) is on it."), busy: true)
        case .done:
            resolved(symbol: "checkmark.circle", text: String(localized: "You allowed this once. \(botName) did it and told \(firstName)."))
        case .declined:
            resolved(symbol: "xmark.circle", text: String(localized: "You said no. \(botName) let \(firstName) know."))
        case .expired, .cancelled:
            resolved(symbol: "clock", text: String(localized: "This request is no longer waiting."))
        case .failed:
            resolved(symbol: "exclamationmark.triangle", text: String(localized: "\(botName) couldn't finish this."))
        case .posting, .unknown:
            EmptyView()
        }
    }

    private var decision: some View {
        HStack(spacing: 8) {
            if card.answer == .failed {
                Label("Couldn't send your answer. Try again.", palIcon: "exclamationmark.triangle")
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("deskCardError-\(item.id)")
            } else {
                Text("Also waiting in Slack").hermesText(.footnoteCaption).foregroundStyle(PalTokens.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Deny") { decide(.decline) }
                .buttonStyle(.glass)
                .disabled(isSending)
                .accessibilityIdentifier("deskDecline-\(item.id)")
            Button { decide(.approve) } label: {
                ZStack {
                    Text("Allow once").opacity(isSending ? 0 : 1)
                    if isSending { ProgressView().controlSize(.small) }
                }
            }
            .glassButtonStyle(prominent: true)
            .disabled(isSending)
            .accessibilityIdentifier("deskApprove-\(item.id)")
        }
    }

    private func resolved(symbol: String, text: String, busy: Bool = false) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) } else { PalIcon(symbol, ink: .secondary) }
            Text(text).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("deskCardResolved-\(item.id)")
    }
}

@MainActor
@Observable
final class ChatDeskFeed {
    let desk: ChatDeskModel
    private let events: @Sendable () -> AsyncStream<ChatDeskChangedPayload>

    init(botName: String, connection: ConnectionModel) {
        let source = ChatInstallSource.make(botName: botName, connection: connection)
        desk = ChatDeskModel(client: source.members)
        events = source.deskEvents
    }

    func run() async {
        await desk.load()
        for await payload in events() { desk.receive(payload) }
    }
}
