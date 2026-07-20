import SwiftUI

struct TeamSheet: View {
    let projectId: String
    @Environment(\.dismiss) private var dismiss

    @State private var members: [Member] = []
    @State private var knownCollaborators: [Member] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var newEmail = ""
    @State private var newRole = "editor"
    @State private var lastInviteLink: String?

    /// People the caller has worked with on other projects, minus anyone
    /// already a member here — no point suggesting someone who's already in.
    private var collaboratorSuggestions: [Member] {
        let existingEmails = Set(members.map(\.email))
        return knownCollaborators.filter { !existingEmails.contains($0.email) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mitglieder") {
                    if isLoading && members.isEmpty {
                        ProgressView()
                    }
                    ForEach(members) { member in
                        HStack(spacing: 12) {
                            MemberAvatar(member: member, size: 36)
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
                    if !collaboratorSuggestions.isEmpty {
                        Menu {
                            ForEach(collaboratorSuggestions) { person in
                                Button {
                                    newEmail = person.email
                                } label: {
                                    if person.name?.isEmpty == false {
                                        Text("\(person.name!) (\(person.email))")
                                    } else {
                                        Text(person.email)
                                    }
                                }
                            }
                        } label: {
                            Label("Person auswählen", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    TextField("E-Mail-Adresse", text: $newEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Rolle", selection: $newRole) {
                        Text("Projektleiter").tag("projektleiter")
                        Text("Editor").tag("editor")
                    }
                    .pickerStyle(.segmented)
                    Button("Einladen") { Task { await sendInvite() } }
                        .disabled(newEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // The invited person also gets a real email now (Resend) — this
                // link is just a manual-share fallback (e.g. sharing over Slack).
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
        case "projektleiter": return "Projektleiter"
        case "editor": return "Editor"
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
        // Best-effort, separate from the main load — no suggestions dropdown
        // is a minor inconvenience, not worth failing the whole sheet over.
        knownCollaborators = (try? await APIClient.shared.knownCollaborators()) ?? []
    }

    private func sendInvite() async {
        do {
            let invite = try await APIClient.shared.invite(
                projectId: projectId,
                email: newEmail.trimmingCharacters(in: .whitespaces),
                role: newRole
            )
            // Derived from APIClient.baseURL (single source of truth for the
            // domain — see its TODO) instead of a second hardcoded string, so
            // switching to Subshot's own domain later is a one-line change.
            // Still needs a corresponding "accept invite" deep link / web page
            // to land on — the backend endpoint alone isn't clickable.
            lastInviteLink = APIClient.shared.baseURL
                .appendingPathComponent("invites/\(invite.token)/accept")
                .absoluteString
            newEmail = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
