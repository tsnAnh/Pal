import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectorAccountField: View {
    let prompt: String
    @Binding var text: String
    var height: CGFloat = 40
    var failed = false
    let identifier: String
    let submit: () -> Void

    @Environment(\.hermesTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let border = failed ? Color(theme.palette.destructive) : PalTokens.fieldBorder
        PalTextField("", text: $text, prompt: Text(prompt))
            .font(.system(size: 15))
            .foregroundStyle(PalTokens.textPrimary)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(submit)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(PalTokens.control, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1.5))
            .accessibilityLabel(Text(prompt))
            .accessibilityIdentifier(identifier)
            .task { focused = true }
    }
}

struct ConnectorAccountsCard: View {
    @Bindable var model: ConnectorDetailsModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let rows = model.accountRows
        ConnectorDetailsSection(title: String(localized: "Accounts"), identifier: "connectorDetailsAccounts") {
            ConnectorDetailsCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ConnectorDetailsDivider() }
                    accountRow(row)
                }
                if model.supportsAccounts {
                    if !rows.isEmpty { ConnectorDetailsDivider() }
                    addArea
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ row: ConnectorAccountRow) -> some View {
        if let editing = model.renaming[row.name] {
            editRow(row, editing)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.system(size: 16))
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.canEdit, !row.isPending {
                        Button { model.beginRename(row.name) } label: {
                            PalIcon("pencil", ink: .tertiary).font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Rename \(row.name)"))
                        .accessibilityIdentifier("connectorAccountRename-\(row.name)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                status(row)
                if !row.isPending { menu(row) }
            }
            .padding(.leading, PalMetrics.screenMargin)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connectorAccount-\(row.name)")
        }
    }

    private func status(_ row: ConnectorAccountRow) -> some View {
        let signingIn = row.isPending || model.accountBusy.contains(row.name)
        let (title, color): (String, Color) = {
            if signingIn { return (String(localized: "Signing in…"), PalTokens.textSecondary) }
            switch row.state {
            case .connected: return (String(localized: "Connected"), Color.green)
            case .needsReconnect: return (String(localized: "Needs sign-in"), Color(theme.palette.destructive))
            case .notConnected: return (String(localized: "Not connected"), PalTokens.textSecondary)
            }
        }()
        return HStack(spacing: 6) {
            if signingIn { ProgressView().controlSize(.mini) }
            Text(title)
        }
        .font(.system(size: 14))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectorAccountStatus-\(row.name)")
    }

    private func menu(_ row: ConnectorAccountRow) -> some View {
        Menu {
            Button { model.signInAgain(row.name) } label: { Label("Sign in again", palIcon: "arrow.clockwise") }
                .accessibilityIdentifier("connectorAccountSignIn-\(row.name)")
            Button(role: .destructive) { model.remove(row.name) } label: { Label("Remove", palIcon: "trash") }
                .accessibilityIdentifier("connectorAccountRemove-\(row.name)")
        } label: {
            PalIcon("ellipsis", ink: .secondary)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(model.accountBusy.contains(row.name))
        .accessibilityLabel(Text("Options for \(row.name)"))
        .accessibilityIdentifier("connectorAccountMenu-\(row.name)")
    }

    private func editRow(_ row: ConnectorAccountRow, _ editing: ConnectorDetailsModel.Editing) -> some View {
        let problem = model.renameProblem(row.name)?.message ?? editing.problem
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ConnectorAccountField(
                    prompt: String(localized: "Account name"),
                    text: Binding(get: { editing.draft }, set: { model.updateRename(row.name, $0) }),
                    height: 36, failed: problem != nil, identifier: "connectorAccountRenameField-\(row.name)",
                    submit: { model.saveRename(row.name) }
                )
                editButton("checkmark", label: "Save", identifier: "connectorAccountRenameSave-\(row.name)", enabled: model.canSaveRename(row.name)) {
                    model.saveRename(row.name)
                }
                editButton("xmark", label: "Cancel", identifier: "connectorAccountRenameCancel-\(row.name)", enabled: true) {
                    model.cancelRename(row.name)
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: ConnectRowMetrics.captionSize))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("connectorAccountRenameProblem-\(row.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func editButton(_ icon: String, label: LocalizedStringKey, identifier: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PalIcon(icon, ink: .secondary)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .palClearGlass(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var addArea: some View {
        if let adding = model.adding {
            let problem = model.addProblem
            VStack(alignment: .leading, spacing: 8) {
                ConnectorAccountField(
                    prompt: String(localized: "Label this account, e.g. work or personal"),
                    text: Binding(get: { adding.draft }, set: { model.updateAdd($0) }),
                    failed: problem != nil, identifier: "connectorAccountAddField", submit: { model.submitAdd() }
                )
                if let problem {
                    Text(problem.message)
                        .font(.system(size: ConnectRowMetrics.captionSize))
                        .foregroundStyle(Color(theme.palette.destructive))
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("connectorAccountAddProblem")
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancelAdd() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PalTokens.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .contentShape(Capsule())
                        .accessibilityIdentifier("connectorAccountAddCancel")
                    connectButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)
        } else {
            Button { model.beginAdd() } label: {
                HStack(spacing: 10) {
                    PalIcon("plus", ink: .secondary).font(.system(size: 14))
                    Text("Add another account")
                        .font(.system(size: 16))
                        .foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PalMetrics.screenMargin)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connectorAccountAdd")
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if model.canSubmitAdd {
            Button("Connect") { model.submitAdd() }
                .glassButtonStyle(prominent: true)
                .accessibilityIdentifier("connectorAccountAddConnect")
        } else {
            Button("Connect") {}
                .glassButtonStyle()
                .disabled(true)
                .accessibilityIdentifier("connectorAccountAddConnect")
        }
    }
}
