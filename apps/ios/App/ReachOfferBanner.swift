import HermesClient
import SwiftUI

struct ReachOfferOverlay: View {
    let model: ReachOfferModel

    var body: some View {
        VStack {
            if let offer = model.current {
                ReachOfferBanner(offer: offer, open: model.accept, dismiss: model.dismiss)
                    .id(offer.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: offer.id) { await model.displayed(offer) }
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(duration: 0.35), value: model.current?.id)
        .allowsHitTesting(model.current != nil)
    }
}

private struct ReachOfferBanner: View {
    let offer: ReachOffer
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: offer.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !offer.body.isEmpty {
                        Text(verbatim: offer.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reach-offer-banner")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityIdentifier("reach-offer-dismiss")
        }
        .padding(16)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(white: 0.24), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < -24 { dismiss() }
            }
        )
        .accessibilityAction(named: Text("Dismiss"), dismiss)
    }
}
