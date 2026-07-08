import SwiftUI
import ClerkKit

struct ProjectListView: View {
    @StateObject private var viewModel = ProjectListViewModel()
    @Environment(Clerk.self) private var clerk
    @State private var isAddingNew = false
    @State private var newProjectName = ""
    @State private var path: [Project] = []
    @State private var editingProject: Project?
    @State private var showingNotifications = false
    @FocusState private var newRowFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isAddingNew {
                    TextField("Projektname", text: $newProjectName)
                        .focused($newRowFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitNewProject() } }
                }
                ForEach(viewModel.projects) { project in
                    NavigationLink(value: project) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: project.color))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Image(systemName: "film.stack")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.body)
                                Text(project.lastOpenedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingProject = project
                        } label: {
                            Label("Bearbeiten", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet { await viewModel.delete(viewModel.projects[index]) }
                    }
                }

                // Reminders-style: the empty area below the list is itself the
                // "add new" affordance, not just a small toolbar button.
                Color.clear
                    .frame(height: 80)
                    .contentShape(Rectangle())
                    .onTapGesture { startAddingNew() }
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle("Subshot")
            .navigationDestination(for: Project.self) { project in
                ShotListView(projectId: project.id, projectName: project.name)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingNotifications = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                            if !viewModel.notifications.isEmpty {
                                Text("\(viewModel.notifications.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.red)
                                    .clipShape(Circle())
                                    .offset(x: 9, y: -9)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { startAddingNew() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.projects.isEmpty {
                    ProgressView()
                } else if viewModel.projects.isEmpty && !isAddingNew {
                    ContentUnavailableView(
                        "Noch keine Projekte",
                        systemImage: "film.stack",
                        description: Text("Tippe auf + um dein erstes Projekt anzulegen.")
                    )
                }
            }
            .task { await viewModel.load() }
            .task { await viewModel.loadNotifications() }
            .refreshable {
                await viewModel.load()
                await viewModel.loadNotifications()
            }
            .sheet(item: $editingProject) { project in
                ProjectEditSheet(project: project) { name, color in
                    await viewModel.update(project, name: name, color: color)
                }
            }
            .sheet(isPresented: $showingNotifications) {
                NotificationsSheet(viewModel: viewModel) { project in
                    path.append(project)
                }
            }
        }
    }

    private func startAddingNew() {
        newProjectName = ""
        isAddingNew = true
        // Focus needs a beat after the row appears in the list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            newRowFocused = true
        }
    }

    private func commitNewProject() async {
        isAddingNew = false
        guard let project = await viewModel.create(name: newProjectName) else { return }
        path.append(project)
    }
}
