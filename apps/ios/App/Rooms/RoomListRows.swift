import PalBotProfile
import PalDesign
import SwiftUI

private struct RoomFace: View {
    let room: Room
    let roster: RosterModel
    let diameter: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(room.members.prefix(2).enumerated()), id: \.offset) { index, member in
                RoomMemberAvatar(member: member, roster: roster, size: diameter * 0.64)
                    .offset(x: index == 0 ? -diameter * 0.18 : diameter * 0.18, y: index == 0 ? -diameter * 0.14 : diameter * 0.14)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

private func memberLine(_ room: Room) -> String {
    room.members.map(\.displayName).formatted(.list(type: .and, width: .narrow))
}

struct RoomsHomeSection: View {
    let rooms: RoomsModel
    let roster: RosterModel
    let router: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rooms.rooms) { room in
                RouteLink(
                    value: AppRoute.room(roomID: room.roomID),
                    isSelected: router.path.first == .room(roomID: room.roomID),
                    select: { router.openRoom(id: room.roomID) }
                ) {
                    HStack(spacing: 12) {
                        RoomFace(room: room, roster: roster, diameter: PalMetrics.homeRowAvatarSlot)
                        VStack(alignment: .leading, spacing: PalMetrics.homeRowTextGap) {
                            Text(room.name)
                                .hermesText(.botName)
                                .foregroundStyle(PalTokens.textPrimary)
                                .lineLimit(1)
                            Text(memberLine(room))
                                .hermesText(.botPreview)
                                .foregroundStyle(PalTokens.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PalMetrics.homeRowInset - 8)
                    .frame(height: PalMetrics.homeRowPitch)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(room.name), group chat with \(memberLine(room))"))
                }
                .buttonStyle(HomeRowButtonStyle(radius: 10))
                .accessibilityIdentifier("roomRow-\(room.roomID)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("roomsList")
    }
}

#if os(macOS)
struct MacRoomRows: View {
    let rooms: RoomsModel
    let roster: RosterModel
    let router: AppRouter

    var body: some View {
        ForEach(rooms.rooms) { room in
            MacRoomRow(room: room, roster: roster, router: router)
        }
    }
}

private struct MacRoomRow: View {
    let room: Room
    let roster: RosterModel
    let router: AppRouter

    @State private var hovering = false

    private var isSelected: Bool { router.path.first == .room(roomID: room.roomID) }

    var body: some View {
        Button { router.openRoom(id: room.roomID) } label: {
            HStack(spacing: 8.5) {
                RoomFace(room: room, roster: roster, diameter: 33)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name)
                        .hermesText(.botName)
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                    Text(memberLine(room))
                        .hermesText(.botPreview)
                        .foregroundStyle(PalTokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8.5)
            .padding(.trailing, 8)
            .frame(height: 50)
            .background(
                isSelected ? PalTokens.selected : hovering ? PalTokens.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(room.name), group chat with \(memberLine(room))"))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("roomRow-\(room.roomID)")
    }
}
#endif
