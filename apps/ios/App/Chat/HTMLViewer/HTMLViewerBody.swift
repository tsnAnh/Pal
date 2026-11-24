import PalChat
import PalDesign
import SwiftUI

struct HTMLViewerBody: View {
    let session: HTMLViewerSession

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if session.pageURL != nil {
                HTMLViewerBar(session: session)
            }
        }
        .background(PalTokens.content)
        .accessibilityIdentifier("htmlViewer")
    }

    @ViewBuilder
    private var stage: some View {
        switch session.fetch {
        case .fetching(let fraction):
            VStack(spacing: 10) {
                if let fraction {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                } else {
                    DelayedProgressView()
                }
            }
            .accessibilityIdentifier("htmlViewerLoading")
        case .tooLarge(let size):
            MediaTooLargePanel(
                icon: "globe", name: session.file.name, line: MediaStateText.tooLarge(size: size, playable: false),
                transfer: session.transfer, idPrefix: "htmlViewer", download: session.downloadWhole
            )
        case .failed(let message, let retryable):
            MediaFailedPanel(icon: "globe", reason: message, retryable: retryable, idPrefix: "htmlViewer", retry: session.retryFetch)
        case .ready(let page):
            ZStack {
                HTMLWebSurface(session: session, page: page, generation: session.render.generation)
                    .accessibilityIdentifier("htmlViewerPage")
                renderOverlay
            }
        }
    }

    @ViewBuilder
    private var renderOverlay: some View {
        switch session.render.phase {
        case .failed(let failure):
            MediaFailedPanel(
                icon: "globe", reason: failure.message, retryable: true, idPrefix: "htmlViewer", retry: session.retryRender
            )
            .background(PalTokens.content)
        case .idle, .loading, .ready:
            EmptyView()
        }
    }
}

private struct HTMLViewerBar: View {
    let session: HTMLViewerSession

    var body: some View {
        VStack(spacing: 0) {
            if let confirmation = session.confirmation {
                confirmRow(confirmation)
            } else if let notice = session.notice {
                noticeRow(notice)
            }
            onlineRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PalTokens.content)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("htmlViewerBar")
    }

    private var onlineRow: some View {
        HStack(spacing: 8) {
            PalIcon(session.render.online ? "wifi" : "wifi.slash", ink: .secondary)
            Text(session.render.onlineLabel)
                .font(.subheadline)
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityIdentifier("htmlViewerOnlineState")
            Spacer(minLength: 8)
            toggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var toggle: some View {
        let button = Button(session.render.onlineActionLabel) { session.toggleOnline() }
            .glassButtonStyle()
            .accessibilityIdentifier("htmlViewerOnlineToggle")
        #if os(macOS)
        button
            .focusable()
            .onKeyPress(.return) {
                session.toggleOnline()
                return .handled
            }
        #else
        button
        #endif
    }

    private func confirmRow(_ confirmation: HTMLExternalOpen) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(confirmation.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PalTokens.textPrimary)
            Text(confirmation.detail)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button("Open") { session.confirmOpen() }
                    .glassButtonStyle(prominent: true)
                    .accessibilityIdentifier("htmlViewerConfirmOpen")
                Button("Cancel") { session.dismissConfirmation() }
                    .glassButtonStyle()
                    .accessibilityIdentifier("htmlViewerConfirmCancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("htmlViewerConfirm")
    }

    private func noticeRow(_ action: HTMLBlockedAction) -> some View {
        HStack(spacing: 8) {
            Text(action.notice)
                .font(.subheadline)
                .foregroundStyle(PalTokens.textSecondary)
            Spacer(minLength: 8)
            Button("Dismiss") { session.dismissNotice() }
                .glassButtonStyle()
                .accessibilityIdentifier("htmlViewerNoticeDismiss")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityIdentifier("htmlViewerNotice")
    }
}
