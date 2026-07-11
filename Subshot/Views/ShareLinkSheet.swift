subshoimport SwiftUI

/// Manage the project's public share link: fetch/create it, optionally
/// password-protect it (2026-07-10, for client-facing previews where
/// nothing should be public even with the link), and hand off to the OS
/// share sheet. Replaces the old one-tap "share immediately" toolbar button
/// — password protection needs a place to live, and this is that place.
struct ShareLinkSheet: View {
    let projectId: String
    /// Called when the user taps "Teilen" with the current link URL — the
    /// caller (ShotListView) presents the actual OS share sheet, since that
    /// needs to live at the screen level, not inside this sheet.
    var onShare: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var hasPassword = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var isProtecting = false
    @State private var passwordText = ""
    @State private var isSavingPassword = false
    /// Both "Link kopieren" and "Passwort setzen" gave zero visible feedback
    /// on success before — the state change (clipboard contents, hasPassword
    /// flipping) isn't itself visible, so both read as doing nothing
    /// ("passiert nichts", 2026-07-11: "man muss eine Bestätigung kriegen
    /// wenn man auf 'Link kopieren' drückt"). A transient inline confirmation
    /// (not a native alert — this app avoids those for anything short of an
    /// error, see feedback_no_native_popups) auto-clears itself after 2s.
    @State private var showCopiedConfirmation = false
    @State private var showPasswordSavedConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if let url {
                        Text(url.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                            withAnimation(.easeInOut(duration: 0.2)) { showCopiedConfirmation = true }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(.easeInOut(duration: 0.2)) { showCopiedConfirmation = false }
                            }
                        } label: {
                            if showCopiedConfirmation {
                                Label("Kopiert", systemImage: "checkmark")
                                    .foregroundStyle(.green)
                            } else {
                                Label("Link kopieren", systemImage: "doc.on.doc")
                            }
                        }
                        Button {
                            onShare(url)
                            dismiss()
                        } label: {
                            Label("Teilen", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Öffentlicher Link")
                } footer: {
                    Text("Jeder mit diesem Link kann die Vorschau ansehen, auch ohne Subshot-Account. Läuft nach 7 Tagen ab.")
                }

                Section {
                    // The switch alone now fully controls protection — turning it off
                    // while a password is active clears it immediately (see onChange
                    // below). Previously there was ALSO a separate "Passwortschutz
                    // entfernen" button further down that did the same thing, which
                    // read as two different controls for one setting ("die kann man
                    // mit einem Switch an oder ausmachen, darunter ist aber nochmal
                    // eine Passwort-Meldung mit einem Schloss") — removed in favor of
                    // just this one.
                    Toggle("Mit Passwort schützen", isOn: $isProtecting.animation())
                        .disabled(isLoading)
                        .onChange(of: isProtecting) { _, newValue in
                            if !newValue && hasPassword {
                                Task { await clearPassword() }
                            }
                        }
                    if isProtecting {
                        SecureField(hasPassword ? "Neues Passwort (optional)" : "Passwort", text: $passwordText)
                        Button {
                            Task { await savePassword() }
                        } label: {
                            if isSavingPassword {
                                ProgressView()
                            } else if showPasswordSavedConfirmation {
                                Label("Gespeichert", systemImage: "checkmark")
                                    .foregroundStyle(.green)
                            } else {
                                Text(hasPassword ? "Passwort ändern" : "Passwort setzen")
                            }
                        }
                        .disabled(passwordText.isEmpty || isSavingPassword)
                    }
                } header: {
                    Text("Passwortschutz")
                } footer: {
                    if hasPassword {
                        Text("Aktiv — Besucher müssen das Passwort eingeben, bevor sie die Vorschau sehen.")
                    } else {
                        Text("Sinnvoll für Projekte/Kunden, wo nichts öffentlich einsehbar sein soll, auch nicht mit dem Link.")
                    }
                }
            }
            .navigationTitle("Link teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .alert("Fehler", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.projectShareLink(projectId)
            url = URL(string: result.url)
            hasPassword = result.has_password
            isProtecting = result.has_password
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func savePassword() async {
        let trimmed = passwordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSavingPassword = true
        defer { isSavingPassword = false }
        do {
            let result = try await APIClient.shared.projectShareLink(projectId, password: trimmed)
            url = URL(string: result.url)
            hasPassword = result.has_password
            passwordText = ""
            withAnimation(.easeInOut(duration: 0.2)) { showPasswordSavedConfirmation = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeInOut(duration: 0.2)) { showPasswordSavedConfirmation = false }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearPassword() async {
        do {
            let result = try await APIClient.shared.projectShareLink(projectId, clearPassword: true)
            url = URL(string: result.url)
            hasPassword = result.has_password
            isProtecting = false
            passwordText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
