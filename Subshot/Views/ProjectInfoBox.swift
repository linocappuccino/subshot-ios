import SwiftUI
import MapKit

/// Collapsible info panel at the top of the scene overview: shoot date,
/// location (MapKit address autocomplete + a plain icon tile — deliberately
/// no rendered map, see LocationSection — tapping it opens Google Maps), and
/// the people on the project. Reminders/Notes-style disclosure — tap the
/// header to expand/collapse with a spring animation.
struct ProjectInfoBox: View {
    @ObservedObject var viewModel: ShotListViewModel
    let projectId: String

    @State private var isExpanded = true
    @State private var showingTeamSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    ShootDateSection(viewModel: viewModel)
                    Divider()
                    LocationSection(viewModel: viewModel, completer: viewModel.locationCompleter)
                    Divider()
                    peopleSection
                    Divider()
                    TodoListsSection(viewModel: viewModel)
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .sheet(isPresented: $showingTeamSheet, onDismiss: {
            Task { await viewModel.refreshMembers() }
        }) {
            TeamSheet(projectId: projectId)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Projektinfos")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Personen", systemImage: "person.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: -8) {
                ForEach(viewModel.members) { member in
                    initialsCircle(member)
                }
                Button {
                    showingTeamSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
    }

    private func initialsCircle(_ member: Member) -> some View {
        let source = member.name?.isEmpty == false ? member.name! : member.email
        let initials = String(source.prefix(2)).uppercased()
        return Text(initials)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.stableColor(for: member.userId))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
    }
}

private struct ShootDateSection: View {
    @ObservedObject var viewModel: ShotListViewModel
    @State private var hasDate = false
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Drehdatum", systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // Plain $bindings + .onChange, not a custom Binding(get:set:) with
            // side effects in the setter — the latter caused a real
            // AttributeGraph crash ("attribute failed to set an initial
            // value"), almost certainly from mutating state and kicking off
            // a Task inside a Binding's set closure, which SwiftUI calls
            // synchronously mid-transaction.
            Toggle("Datum festlegen", isOn: $hasDate.animation(.spring(response: 0.35, dampingFraction: 0.8)))
                .onChange(of: hasDate) { _, newValue in
                    Task { await viewModel.updateShootDate(newValue ? date : nil) }
                }
            if hasDate {
                DatePicker("Termin", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: date) { _, newValue in
                        Task { await viewModel.updateShootDate(newValue) }
                    }
                    .transition(.opacity)
            }
        }
        .task {
            if let shootDate = viewModel.shootDate {
                date = shootDate
                hasDate = true
            }
        }
    }
}

private struct LocationSection: View {
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject var completer: LocationSearchCompleter
    @State private var query = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location", systemImage: "mappin.and.ellipse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let address = viewModel.locationAddress, !isEditing {
                HStack(alignment: .top, spacing: 10) {
                    if let lat = viewModel.locationLat, let lng = viewModel.locationLng {
                        // Deliberately NOT a Map/MKMapSnapshotter — both
                        // reliably crashed the whole Simulator (a known
                        // MapKit-rendering/Metal issue, not specific to
                        // either API). A plain icon tile has zero rendering
                        // risk; tapping it still opens Google Maps.
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { LocationSearch.openInGoogleMaps(lat: lat, lng: lng) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(address)
                            .font(.footnote)
                            .lineLimit(3)
                        Button("Ändern") {
                            query = address
                            isEditing = true
                        }
                        .font(.caption)
                    }
                }
            } else {
                TextField("Adresse eingeben", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, newValue in
                        completer.update(query: newValue)
                    }
                    .onSubmit { isEditing = false }
                if !completer.results.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(completer.results.prefix(5), id: \.self) { result in
                            Button {
                                Task { await select(result) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).font(.footnote)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            if result != completer.results.prefix(5).last { Divider() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) async {
        guard let resolved = try? await LocationSearch.resolve(completion) else { return }
        await viewModel.updateLocation(address: resolved.address, lat: resolved.lat, lng: resolved.lng)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isEditing = false
            completer.clear()
            query = ""
        }
    }
}

private extension Color {
    /// Deterministic per-person color for the initials avatars — no color
    /// field on User, so hash the id the same way projects used to (before
    /// they got a real color field).
    static func stableColor(for id: String) -> Color {
        let hash = id.unicodeScalars.reduce(into: 0) { $0 = $0 &* 31 &+ Int($1.value) }
        let hex = Color.subshotPalette[abs(hash) % Color.subshotPalette.count]
        return Color(hex: hex)
    }
}

/// Up to 5 lists per project (spec limit, enforced by both the backend and
/// `ShotListViewModel.maxTodoLists` here). Renaming and adding items are
/// inline (tap-to-edit / tap-to-add-row), matching the rest of this screen's
/// style rather than introducing sheets or native alerts for such a small edit.
private struct TodoListsSection: View {
    @ObservedObject var viewModel: ShotListViewModel
    @State private var isAddingList = false
    @State private var newListName = ""
    @FocusState private var newListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Todo-Listen", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(viewModel.todoLists) { list in
                TodoListCard(list: list, viewModel: viewModel)
            }

            if isAddingList {
                HStack {
                    TextField("Listenname", text: $newListName)
                        .font(.footnote)
                        .focused($newListFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitNewList() } }
                    Button {
                        Task { await commitNewList() }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
            } else if viewModel.todoLists.count < ShotListViewModel.maxTodoLists {
                Button {
                    newListName = ""
                    isAddingList = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { newListFocused = true }
                } label: {
                    Label("Liste hinzufügen", systemImage: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func commitNewList() async {
        isAddingList = false
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await viewModel.createTodoList(name: trimmed)
    }
}

private struct TodoListCard: View {
    let list: TodoList
    @ObservedObject var viewModel: ShotListViewModel

    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    @State private var isAddingItem = false
    @State private var newItemText = ""
    @FocusState private var newItemFocused: Bool

    private var sortedItems: [TodoItem] {
        list.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isRenaming {
                    TextField("Listenname", text: $renameText)
                        .font(.subheadline.weight(.semibold))
                        .focused($renameFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitRename() } }
                } else {
                    Text(list.name)
                        .font(.subheadline.weight(.semibold))
                        .contentShape(Rectangle())
                        .onTapGesture { startRenaming() }
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await viewModel.deleteTodoList(list) }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(sortedItems) { item in
                TodoItemRow(item: item, viewModel: viewModel)
            }

            if isAddingItem {
                TextField("Neuer Punkt", text: $newItemText)
                    .font(.footnote)
                    .focused($newItemFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await commitNewItem() } }
            } else {
                Button {
                    newItemText = ""
                    isAddingItem = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { newItemFocused = true }
                } label: {
                    Label("Punkt hinzufügen", systemImage: "plus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func startRenaming() {
        renameText = list.name
        isRenaming = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }

    private func commitRename() async {
        isRenaming = false
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != list.name else { return }
        await viewModel.renameTodoList(list, name: trimmed)
    }

    private func commitNewItem() async {
        isAddingItem = false
        await viewModel.createTodoItem(in: list, text: newItemText)
    }
}

private struct TodoItemRow: View {
    let item: TodoItem
    @ObservedObject var viewModel: ShotListViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.toggleTodoItemDone(item) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.footnote)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: item.done)
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.deleteTodoItem(item) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}
