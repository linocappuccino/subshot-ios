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

    @ObservedObject private var language = AppLanguage.shared
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
                        language.t("notionImportSheet.importedTitleTemplate")
                            .replacingOccurrences(of: "{count}", with: "\(importedCount)")
                            .replacingOccurrences(of: "{noun}", with: importedCount == 1
                                ? language.t("notionImportSheet.sceneSingular")
                                : language.t("notionImportSheet.scenePlural")),
                        systemImage: "checkmark.circle.fill",
                        description: Text(language.t("notionImportSheet.importedDescription"))
                    )
                } else if isConnected {
                    databaseList
                } else {
                    connectForm
                }
            }
            .navigationTitle(language.t("notionImportSheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importedCount != nil ? language.t("notionImportSheet.doneButton") : language.t("notionImportSheet.cancelButton")) { dismiss() }
                }
                if isConnected, importedCount == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(language.t("notionImportSheet.importButton")) {
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
                Text(language.t("notionImportSheet.connectIntro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(language.t("notionImportSheet.howToTitle")) {
                Label(language.t("notionImportSheet.step1"), systemImage: "1.circle")
                Label(language.t("notionImportSheet.step2"), systemImage: "2.circle")
                Label(language.t("notionImportSheet.step3"), systemImage: "3.circle")
            }
            .font(.footnote)
            Section(language.t("notionImportSheet.integrationSecretLabel")) {
                SecureField(language.t("notionImportSheet.secretPlaceholder"), text: $token)
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
                        Text(language.t("notionImportSheet.connectButton"))
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
                    Text(language.t("notionImportSheet.noDatabasesFound"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section(language.t("notionImportSheet.chooseDatabaseLabel")) {
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
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
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
