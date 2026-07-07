import SwiftUI

struct TeamSheet: View {
    let projectId: String
    @Environment(\.dismiss) private var dismiss

    @State private var members: [Member] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var newEmail = ""
    @State private var newRole = "editor"
    @State private var lastInviteLink: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mitglieder") {
                    if isLoading && members.isEmpty {
                        ProgressView()
                    }
                    ForEach(members) { member in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(member.name?.isEmpty == false ? member.name! : member.email)
                                if member.name?.isEmpty == false {
                                    Text(member.email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(roleLabel(member.role))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Person einladen") {
                    TextField("E-Mail-Adresse", text: $newEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Rolle", selection: $newRole) {
                        Text("Editor").tag("editor")
                        Text("Betrachter").tag("viewer")
                    }
                    .pickerStyle(.segmented)
                    Button("Einladen") { Task { await sendInvite() } }
                        .disabled(newEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // No transactional email is sent yet (see backend TODO) — the
                // invite link has to be shared manually until that's wired up.
                if let lastInviteLink {
                    Section("Einladungslink (manuell teilen)") {
                        Text(lastInviteLink)
                            .font(.caption)
                            .textSelection(.enabled)
                        ShareLink(item: lastInviteLink)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle("Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "owner": return "Besitzer"
        case "editor": return "Editor"
        case "viewer": return "Betrachter"
        default: return role
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await APIClient.shared.members(projectId: projectId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendInvite() async {
        do {
            let invite = try await APIClient.shared.invite(
                projectId: projectId,
                email: newEmail.trimmingCharacters(in: .whitespaces),
                role: newRole
            )
            // TODO: replace with the real production domain once it exists
            // (see APIClient.baseURL comment) — this link format needs a
            // corresponding "accept invite" deep link / web page to land on.
            lastInviteLink = "https://dev.subli.ch/subshot-test/invites/\(invite.token)/accept"
            newEmail = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
