import Foundation

@MainActor
final class ProjectListViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.shared.listProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns the newly created project so the caller can navigate straight
    /// into it (Reminders-style: name it, hit return, you're in the list).
    func create(name: String) async -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let project = try await APIClient.shared.createProject(name: trimmed)
            projects.insert(project, at: 0)
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ project: Project) async {
        do {
            try await APIClient.shared.deleteProject(project.id)
            projects.removeAll { $0.id == project.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
