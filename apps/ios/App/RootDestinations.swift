import PalBotProfile
import PalClient
import PalConnect
import SwiftUI

extension RootView {
    @ViewBuilder
    func destination(_ route: AppRoute) -> some View {
        switch route {
        case .chat(let name):
            if let bot = roster.bot(named: name) {
                ModelHost {
                    ChatModel(bot: bot, links: links, roster: roster)
                } content: {
                    ChatView(model: $0, teach: bots.teach(for: name, displayName: bot.displayName), router: router)
                }
            }
        case .room(let roomID):
            if let room = rooms.room(id: roomID), let service = rooms.service {
                ModelHost {
                    RoomModel(room: room, service: service, rooms: rooms)
                } content: {
                    RoomView(model: $0, roster: roster, router: router)
                }
            }
        case .botProfile(let name):
            ModelHost {
                BotProfileModel(botName: name, services: bots.services, roster: roster, sharer: bots.sharer)
            } content: { profile in
                ModelHost {
                    ConnectedServicesModel(botName: name, services: bots.services)
                } content: {
                    BotProfileView(model: profile, services: $0, router: router)
                }
            }
        case .botThread(let thread):
            ModelHost {
                BotThreadModel(route: thread, connection: model, roster: roster)
            } content: {
                BotThreadView(model: $0)
            }
        default:
            toolDestination(route)
        }
    }

    @ViewBuilder
    func toolDestination(_ route: AppRoute) -> some View {
        switch route {
        case .library(let name):
            ModelHost {
                LibraryModel(botName: name, services: bots.services)
            } content: {
                LibraryView(model: $0)
            }
        case .routines(let name):
            ModelHost {
                RoutinesModel(botName: name, services: bots.services)
            } content: {
                RoutinesView(model: $0)
            }
        case .computer(let name):
            let bot = roster.bot(named: name)
            ModelHost {
                ComputerModel(botName: name, service: bots.services.computer, openStream: bots.services.openDisplayStream)
            } content: {
                ComputerView(
                    model: $0,
                    teach: bots.teach(for: name, displayName: bot?.displayName ?? name),
                    title: bot?.displayName ?? name,
                    spec: bot?.spec
                )
            }
        default:
            channelDestination(route)
        }
    }

    @ViewBuilder
    func channelDestination(_ route: AppRoute) -> some View {
        switch route {
        case .slack(let name):
            SlackEntryView(
                botName: name,
                displayName: roster.bot(named: name)?.displayName ?? name,
                spec: roster.bot(named: name)?.spec,
                services: bots.services,
                source: ChatInstallSource.make(botName: name, connection: model)
            )
        case .telegram(let name):
            let displayName = roster.bot(named: name)?.displayName ?? name
            ModelHost {
                TelegramModel(botName: name, displayName: displayName, services: bots.services)
            } content: {
                TelegramView(model: $0)
            }
        case .botModel(let name):
            let displayName = roster.bot(named: name)?.displayName ?? name
            ModelHost {
                BotModelsModel(client: bots.services.models(name), profile: name, surfaces: bots.services.surfaces)
            } content: {
                BotModelView(model: $0, displayName: displayName)
            }
        case .botKeys(let name):
            let displayName = roster.bot(named: name)?.displayName ?? name
            ModelHost {
                BotKeysModel(service: bots.services.keys, profile: name, surfaces: bots.services.surfaces)
            } content: {
                BotKeysScreen(model: $0, displayName: displayName)
            }
        case .botVault(let name):
            VaultScreen(hub: hub, profile: name, back: router.pop)
                .environment(\.sheetChromeHostedInNavigation, true)
        case .messagingSettings(let name):
            let displayName = roster.bot(named: name)?.displayName ?? name
            ModelHost {
                MessagingSettingsModel(botName: name, displayName: displayName, services: bots.services)
            } content: {
                MessagingSettingsView(model: $0)
            }
        case .kanban:
            KanbanPushedSurface(connection: model, roster: roster, back: router.pop)
        default:
            EmptyView()
        }
    }
}
