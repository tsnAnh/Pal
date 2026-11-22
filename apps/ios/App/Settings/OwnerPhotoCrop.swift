import CoreGraphics
import Foundation
import Observation
import PalDesign
import PalSettings
import SwiftUI

enum OwnerPhotoCopy {
    static let unusable = String(localized: "That picture couldn't be used. Try a JPEG or PNG under 10 MB.")
    static let saveFailed = String(localized: "Couldn't save your details. Check that Pal is running and try again.")
}

@MainActor
@Observable
final class OwnerPhotoCropModel {
    let image: CGImage
    let size: CGSize
    private(set) var crop = PhotoCrop()
    private(set) var isBusy = false
    private(set) var failure: String?

    @ObservationIgnored private let commit: (Data) async throws -> Void

    init(image: CGImage, commit: @escaping (Data) async throws -> Void) {
        self.image = image
        size = CGSize(width: image.width, height: image.height)
        self.commit = commit
    }

    func zoom(to value: Double) {
        crop = crop.zoomed(to: value, in: size)
    }

    func move(by translation: CGSize, circle: CGFloat) {
        crop = crop.moved(byPoints: translation, circle: circle, in: size)
    }

    func use() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        failure = nil
        defer { isBusy = false }
        let (image, crop) = (image, crop)
        do {
            let jpeg = try await Task.detached(priority: .userInitiated) { try OwnerPhotoImage.jpeg(cropping: image, to: crop) }.value
            try await commit(jpeg)
            return true
        } catch is CancellationError {
            return false
        } catch is OwnerPhotoImage.Failure {
            failure = OwnerPhotoCopy.unusable
            return false
        } catch {
            failure = SettingsFailure(error).message
            return false
        }
    }
}

struct OwnerPhotoCropBox: View {
    let model: OwnerPhotoCropModel
    var height: CGFloat = 240

    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let circle = max(1, min(proxy.size.width, height) - 40)
            let rect = model.crop.moved(byPoints: drag, circle: circle, in: model.size).sourceRect(in: model.size)
            let scale = circle / rect.width
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Image(decorative: model.image, scale: 1)
                    .resizable()
                    .frame(width: model.size.width * scale, height: model.size.height * scale)
                    .position(
                        x: center.x + (model.size.width / 2 - rect.midX) * scale,
                        y: center.y + (model.size.height / 2 - rect.midY) * scale
                    )
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addEllipse(in: CGRect(x: center.x - circle / 2, y: center.y - circle / 2, width: circle, height: circle))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Circle()
                    .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.5)
                    .frame(width: circle, height: circle)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture() // scroll-gesture: ok crop surface owns its touches; no scroll view hosts it on iPhone
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { model.move(by: $0.translation, circle: circle) }
            )
        }
        .frame(height: height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Photo position"))
        .accessibilityHint(Text("Drag to move the photo"))
        .accessibilityIdentifier("ownerPhotoCropBox")
    }
}

struct OwnerPhotoZoomRow: View {
    let model: OwnerPhotoCropModel

    var body: some View {
        HStack(spacing: 12) {
            PalIcon("photo", ink: .secondary).font(.system(size: 12))
            Slider(
                value: Binding(get: { model.crop.zoom }, set: { model.zoom(to: $0) }),
                in: PhotoCrop.zoomRange
            )
            .accessibilityLabel(Text("Zoom"))
            .accessibilityIdentifier("ownerPhotoZoom")
            PalIcon("photo", ink: .secondary).font(.system(size: 19))
        }
        .accessibilityElement(children: .contain)
    }
}

extension OwnerPhotoCropModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct OwnerPhotoCropStep: View {
    let model: OwnerPhotoCropModel
    var showsHeading = true
    var showsCancel = true
    var cropHeight: CGFloat = 240
    var done: () -> Void = {}
    let cancel: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if showsHeading {
                Text("Position your photo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("This is how it will look next to your name.")
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .padding(.top, 8)
            }
            OwnerPhotoCropBox(model: model, height: cropHeight)
                .padding(.top, showsHeading ? 16 : 0)
            OwnerPhotoZoomRow(model: model)
                .frame(maxWidth: 340)
                .padding(.top, 18)
            if let failure = model.failure {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .accessibilityIdentifier("ownerPhotoCropError")
            }
            Spacer(minLength: 16)
            Button { Task { if await model.use() { done() } } } label: {
                HStack(spacing: 8) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text("Use photo").frame(maxWidth: .infinity)
                }
                .foregroundStyle(PalTokens.inverseText)
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(PalTokens.inverseFill)
            .disabled(model.isBusy)
            .accessibilityIdentifier("ownerPhotoUse")
            if showsCancel {
                Button("Cancel", action: cancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(height: 32)
                    .padding(.top, 6)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("ownerPhotoCropCancel")
            }
        }
    }
}
