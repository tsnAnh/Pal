import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectorDetailsMargin: EnvironmentKey {
    static let defaultValue = PalMetrics.screenMargin
}

extension EnvironmentValues {
    var detailsMargin: CGFloat {
        get { self[ConnectorDetailsMargin.self] }
        set { self[ConnectorDetailsMargin.self] = newValue }
    }
}

struct ConnectorDetailsCard<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.detailsMargin) private var margin

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
        VStack(spacing: 0) { content }
            .background(PalTokens.elevated, in: shape)
            .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .padding(.horizontal, margin)
    }
}

struct ConnectorDetailsSection<Content: View>: View {
    let title: String
    var count: Int?
    var identifier: String
    @ViewBuilder let content: Content

    @Environment(\.detailsMargin) private var margin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                if let count { Text("\(count)").fontWeight(.regular) }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PalTokens.textTertiary)
            .padding(.horizontal, margin + 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("\(identifier)-title")
            content
        }
        .padding(.top, 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct ConnectorDetailsFootnote: View {
    let text: String
    var identifier: String
    var solo = false

    @Environment(\.detailsMargin) private var margin

    var body: some View {
        Text(text)
            .font(.system(size: ConnectRowMetrics.captionSize))
            .foregroundStyle(PalTokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, margin + 4)
            .padding(.top, solo ? 20 : 8)
            .accessibilityIdentifier(identifier)
    }
}

struct ConnectorDetailsDivider: View {
    var inset: CGFloat = PalMetrics.screenMargin

    var body: some View {
        PalHairline().padding(.leading, inset)
    }
}

struct ConnectorProminentCapsuleStyle: ButtonStyle {
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 14

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PalTokens.inverseText)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(PalTokens.inverseFill, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

enum ConnectorDetailsStyle {
    static var capsule: PalClearCapsuleStyle {
        #if os(macOS)
        PalClearCapsuleStyle()
        #else
        PalClearCapsuleStyle(height: 30, horizontalPadding: 14)
        #endif
    }

    static var prominent: ConnectorProminentCapsuleStyle {
        #if os(macOS)
        ConnectorProminentCapsuleStyle(height: 32, horizontalPadding: 16)
        #else
        ConnectorProminentCapsuleStyle(height: 30, horizontalPadding: 14)
        #endif
    }
}

struct ConnectorInformationCard: View {
    let rows: [ConnectorInformationRow]

    var body: some View {
        ConnectorDetailsSection(title: String(localized: "Information"), identifier: "connectorDetailsInformation") {
            ConnectorDetailsCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ConnectorDetailsDivider() }
                    informationRow(row)
                }
            }
        }
    }

    private func informationRow(_ row: ConnectorInformationRow) -> some View {
        HStack(spacing: 16) {
            Text(row.title)
                .font(.system(size: 16))
                .foregroundStyle(PalTokens.textPrimary)
            Spacer(minLength: 0)
            if let link = row.link {
                Button { ExternalLink.open(link) } label: {
                    HStack(spacing: 6) {
                        Text(row.value).underline()
                        PalIcon("arrow.up.right", ink: .secondary).font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(PalTokens.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectorDetailsInfo-\(row.kind.rawValue)")
            } else {
                Text(row.value)
                    .font(.system(size: 15))
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .accessibilityIdentifier("connectorDetailsInfo-\(row.kind.rawValue)")
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .frame(minHeight: 52)
    }
}

struct ConnectorSkillsCard: View {
    let skills: [ConnectorSkill]

    var body: some View {
        ConnectorDetailsSection(title: String(localized: "Skills"), count: skills.count, identifier: "connectorDetailsSkills") {
            ConnectorDetailsCard {
                ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                    if index > 0 { ConnectorDetailsDivider() }
                    HStack(alignment: .top, spacing: 14) {
                        PalIcon("sparkles", ink: .secondary)
                            .font(.system(size: 18))
                            .frame(width: 22, height: 22)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.title)
                                .font(.system(size: 16))
                                .foregroundStyle(PalTokens.textPrimary)
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.system(size: 13))
                                    .foregroundStyle(PalTokens.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PalMetrics.screenMargin)
                    .padding(.vertical, 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("connectorDetailsSkill-\(skill.name)")
                }
            }
        }
    }
}
