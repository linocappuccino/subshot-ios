import SwiftUI

/// One-click Notion -> Subshot scene import (see app/notion_import.py for the
/// full server-side mapping/setup story). Two states: no token connected yet
/// (paste-once instructions + field), or connected (pick a shared database,
/// tap Importieren). Connecting is per Subshot ACCOUNT, not per project — so
/// once done here, every other project skips straight to the database list.
struct NotionImportSheet: View {
    let projectId: String
    /// Reloads the caller's scene list after a successful import.
    var onImported: () async -> Void

    @State private var token = ""
    @State private var databases: [NotionDatabase] = []
    @State private var isConnected = false
    @State private var selectedDatabaseId: String?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importedCount: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let importedCount {
                    ContentUnavailableView(
                        "\(importedCount) Szene\(importedCount == 1 ? "" : "n") importiert",
                        systemImage: "checkmark.circle.fill",
                        description: Text("Von Notion übernommen.")
                    )
                } else if isConnected {
                    databaseList
                } else {
                    connectForm
                }
            }
            .navigationTitle("Notion-Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importedCount != nil ? "Fertig" : "Abbrechen") { dismiss() }
                }
                if isConnected, importedCount == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Importieren") {
                            Task { await importSelected() }
                        }
                        .disabled(selectedDatabaseId == nil || isImporting)
                    }
                }
            }
        }
        .task { await loadDatabases() }
    }

    private var connectForm: some View {
        Form {
            Section {
                Text("Verbinde deinen Notion-Workspace einmalig — danach kannst du aus jedem Projekt heraus importieren.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("So geht's") {
                Label("notion.so/my-integrations → \"+ New integration\" → benennen, Submit", systemImage: "1.circle")
                Label("Das \"Internal Integration Secret\" kopieren", systemImage: "2.circle")
                Label("In der Notion-Datenbank: „...“-Menü → Connections → Integration hinzufügen", systemImage: "3.circle")
            }
            .font(.footnote)
            Section("Integration Secret") {
                SecureField("secret_... oder ntn_...", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Verbinden")
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
    }

    private var databaseList: some View {
        List {
            if databases.isEmpty {
                Section {
                    Text("Keine Datenbank gefunden — hast du sie in Notion über \"Connections\" mit der Integration geteilt?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Datenbank auswählen") {
                // Pulled out into its own explicitly-typed function — the
                // previous inline ForEach{ Button{ HStack{ ... } } } closure
                // (nested inside List/Section's own ViewBuilders) was too
                // much for the type checker to solve as one expression, and
                // it reported that failure as a misleading "databases is
                // [NotionDatabase], expected Binding<[NotionDatabase]>"
                // error instead of the real "expression too complex" one.
                // Adding `id: \.id` alone didn't fix it (verified — same
                // error, same line, after that change), confirming it
                // wasn't a ForEach-overload-ambiguity problem after all.
                ForEach(databases) { db in
                    databaseRow(db)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private func databaseRow(_ db: NotionDatabase) -> some View {
        Button {
            selectedDatabaseId = db.id
        } label: {
            HStack {
                Text(db.title).foregroundStyle(.primary)
                Spacer()
                if selectedDatabaseId == db.id {
                    Image(systemName: "checkmark").foregroundStyle(.accent)
                }
            }
        }
    }

    private func loadDatabases() async {
        isLoading = true
        defer { isLoading = false }
        do {
            databases = try await APIClient.shared.notionDatabases()
            isConnected = true
        } catch {
            // No token connected yet (or it's invalid) — fall back to the
            // connect form rather than surfacing this as a hard error.
            isConnected = false
        }
    }

    private func connect() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await APIClient.shared.setNotionToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            databases = try await APIClient.shared.notionDatabases()
            isConnected = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importSelected() async {
        guard let selectedDatabaseId else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let count = try await APIClient.shared.importNotionScenes(projectId: projectId, databaseId: selectedDatabaseId)
            importedCount = count
            await onImported()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
