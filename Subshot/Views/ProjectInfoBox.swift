import SwiftUI
import MapKit

/// Section-scoped counterpart to ProjectInfoBox, for multi-day shoots
/// (2026-07-10): a section can optionally carry its own mini info box (own
/// shoot date/location/todo lists, same fields/behavior as the project-level
/// one) — shown inline in that section, moves with it when the section is
/// reordered (no separate drag handle of its own). Unlike the top-level
/// ProjectInfoBox, this one CAN be deleted — long-press for a Löschen menu
/// (see header's .contextMenu below), same "no icon, long-press instead"
/// convention as every other deletable tile in this screen (ShotListView's
/// sceneToDelete doc comment has the full story on why) — the original
/// project-level box can't be moved or removed, only ones added to a
/// section can.
struct SectionInfoBox: View {
    @ObservedObject var viewModel: ShotListViewModel
    let section: SceneSection
    let projectId: String

    @State private var isExpanded = false
    @State private var showingTeamSheet = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    ShootDateSection(
                        shootDate: section.shootDate,
                        onUpdate: { date in await viewModel.updateSectionShootDate(section, date: date) }
                    )
                    Divider()
                    LocationSection(
                        address: section.locationAddress, lat: section.locationLat, lng: section.locationLng,
                        onUpdate: { address, lat, lng in
                            await viewModel.updateSectionLocation(section, address: address, lat: lat, lng: lng)
                        },
                        completer: viewModel.locationCompleter
                    )
                    Divider()
                    peopleSection
                    Divider()
                    TodoListsSection(
                        lists: section.todoLists, maxLists: ShotListViewModel.maxTodoLists,
                        viewModel: viewModel,
                        onCreate: { name in await viewModel.createSectionTodoList(section: section, name: name) }
                    )
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showingTeamSheet, onDismiss: {
            Task { await viewModel.refreshMembers() }
        }) {
            TeamSheet(projectId: projectId)
        }
        .confirmationDialog("Projektinfo löschen?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task { await viewModel.removeSectionProjectInfo(section) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Datum, Ort und Todo-Listen dieser Projektinfo werden entfernt.")
        }
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Projektinfo: \(section.name)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only added info boxes get this — the original top-level
        // ProjectInfoBox has nothing to delete, by design. No icon: same
        // long-press-for-Löschen convention as every other tile here.
        .contextMenu {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    /// Same as ProjectInfoBox.peopleSection — reuses the project's member
    /// list (Team/membership is project-wide, not per shoot day) rather than
    /// duplicating the exact same list from the viewModel; only the
    /// invite-someone entry point (Team sheet) is shared too.
    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Personen", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: -8) {
                ForEach(viewModel.members) { member in
                    MemberAvatar(member: member, size: 44)
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
                Button {
                    showingTeamSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
    }
}

/// Collapsible info panel at the top of the scene overview: shoot date,
/// location (MapKit address autocomplete + a plain icon tile — deliberately
/// no rendered map, see LocationSection — tapping it opens Google Maps), and
/// the people on the project. Reminders/Notes-style disclosure — tap the
/// header to expand/collapse with a spring animation.
struct ProjectInfoBox: View {
    @ObservedObject var viewModel: ShotListViewModel
    let projectId: String

    @State private var isExpanded = false
    @State private var showingTeamSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let lastOpenedAt = viewModel.lastOpenedAt {
                deletionNotice(lastOpenedAt: lastOpenedAt)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    ShootDateSection(shootDate: viewModel.shootDate, onUpdate: viewModel.updateShootDate)
                    Divider()
                    LocationSection(
                        address: viewModel.locationAddress, lat: viewModel.locationLat, lng: viewModel.locationLng,
                        onUpdate: viewModel.updateLocation, completer: viewModel.locationCompleter
                    )
                    Divider()
                    peopleSection
                    Divider()
                    TodoListsSection(
                        lists: viewModel.todoLists, maxLists: ShotListViewModel.maxTodoLists,
                        viewModel: viewModel, onCreate: { name in await viewModel.createTodoList(name: name) }
                    )
                }
                .padding(.top, 12)
                // No .move(edge:) — sliding content in/out while the
                // container is ALSO growing/shrinking its own height at the
                // same time (Divider/DatePicker/TodoList content all
                // resizing it) compounded into a janky double-motion. A
                // plain fade + slight scale-from-top reads as one smooth
                // reveal instead, closer to how Settings/Notes disclosure
                // sections animate.
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Projektinfos")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Static info, not a countdown/timer widget — the project page
    /// explicitly doesn't need one of those (unlike scenes). Purely computed
    /// from lastOpenedAt (scripts/deletion_job.py's 30-day cutoff), no
    /// separate backend field. Shown outside the collapsible body so it's
    /// visible even while Projektinfos is collapsed (its default state).
    private func deletionNotice(lastOpenedAt: Date) -> some View {
        let deletesAt = lastOpenedAt.addingTimeInterval(30 * 24 * 3600)
        let daysLeft = max(0, Calendar.current.dateComponents([.day], from: .now, to: deletesAt).day ?? 0)
        return Label("Wird gelöscht in \(daysLeft) Tagen", systemImage: "clock")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Personen", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: -8) {
                ForEach(viewModel.members) { member in
                    initialsCircle(member)
                }
                Button {
                    showingTeamSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
    }

    /// 44pt — Apple's own minimum recommended tap target, was 32pt (too
    /// small/fiddly to tap reliably).
    private func initialsCircle(_ member: Member) -> some View {
        MemberAvatar(member: member, size: 44)
            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
    }
}

/// Generic over "where the date actually lives" via `shootDate`/`onUpdate` —
/// used by both the project-level ProjectInfoBox and a section's own
/// SectionInfoBox (multi-day shoots, 2026-07-10), same UI either way.
private struct ShootDateSection: View {
    let shootDate: Date?
    let onUpdate: (Date?) async -> Void
    @State private var hasDate = false
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Drehdatum", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            // Plain $bindings + .onChange, not a custom Binding(get:set:) with
            // side effects in the setter — the latter caused a real
            // AttributeGraph crash ("attribute failed to set an initial
            // value"), almost certainly from mutating state and kicking off
            // a Task inside a Binding's set closure, which SwiftUI calls
            // synchronously mid-transaction.
            Toggle("Datum festlegen", isOn: $hasDate.animation(.spring(response: 0.35, dampingFraction: 0.86)))
                .onChange(of: hasDate) { _, newValue in
                    Task { await onUpdate(newValue ? date : nil) }
                }
            if hasDate {
                DatePicker("Start", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: date) { _, newValue in
                        Task { await onUpdate(newValue) }
                    }
                    .transition(.opacity)
            }
        }
        .task {
            if let shootDate {
                date = shootDate
                hasDate = true
            }
        }
    }
}

/// Generic over "where the location actually lives", same reasoning as
/// ShootDateSection above.
private struct LocationSection: View {
    let address: String?
    let lat: Double?
    let lng: Double?
    let onUpdate: (String, Double, Double) async -> Void
    @ObservedObject var completer: LocationSearchCompleter
    @State private var query = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location", systemImage: "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if let address, !isEditing {
                HStack(alignment: .top, spacing: 10) {
                    if let lat, let lng {
                        // Real map preview now (SceneMapThumbnail, same as
                        // scenes) — the earlier "crashes the Simulator"
                        // finding turned out to be the general iOS-26.5-
                        // Simulator rendering bug, not MapKit itself, see
                        // project memory. Tapping it opens Google Maps.
                        SceneMapThumbnail(lat: lat, lng: lng, size: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(address)
                            .font(.subheadline)
                            .lineLimit(3)
                        Button("Ändern") {
                            query = address
                            isEditing = true
                        }
                        .font(.footnote)
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
                                    Text(result.title).font(.subheadline)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
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
        await onUpdate(resolved.address, resolved.lat, resolved.lng)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isEditing = false
            completer.clear()
            query = ""
        }
    }
}

/// Up to 5 lists (spec limit, enforced by both the backend and `maxLists`
/// here) — generic over `lists`/`maxLists`/`onCreate` so the same view
/// serves both the project-level box (viewModel.todoLists) and a section's
/// own box (that section's own todoLists), same reasoning as
/// ShootDateSection/LocationSection above. `viewModel` is still needed
/// as-is for TodoListCard's per-item calls, which already operate on a
/// specific TodoList/TodoItem regardless of which parent owns it. Renaming
/// and adding items are inline (tap-to-edit / tap-to-add-row), matching the
/// rest of this screen's style rather than introducing sheets or native
/// alerts for such a small edit.
private struct TodoListsSection: View {
    let lists: [TodoList]
    let maxLists: Int
    @ObservedObject var viewModel: ShotListViewModel
    let onCreate: (String) async -> Void
    @State private var isAddingList = false
    @State private var newListName = ""
    @FocusState private var newListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Todo-Listen", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(lists) { list in
                TodoListCard(list: list, viewModel: viewModel)
            }

            if isAddingList {
                HStack(spacing: 10) {
                    TextField("Listenname", text: $newListName)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focused($newListFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitNewList() } }
                    Button {
                        Task { await commitNewList() }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                }
            } else if lists.count < maxLists {
                Button {
                    newListName = ""
                    isAddingList = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { newListFocused = true }
                } label: {
                    Label("Liste hinzufügen", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func commitNewList() async {
        isAddingList = false
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await onCreate(trimmed)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if isRenaming {
                    TextField("Listenname", text: $renameText)
                        .font(.title3.weight(.semibold))
                        .focused($renameFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitRename() } }
                } else {
                    Text(list.name)
                        .font(.title3.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { startRenaming() }
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await viewModel.deleteTodoList(list) }
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(sortedItems) { item in
                    TodoItemRow(item: item, viewModel: viewModel)
                }
            }

            if isAddingItem {
                HStack(spacing: 10) {
                    TextField("Neuer Punkt", text: $newItemText)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(Color(.quaternarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focused($newItemFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitNewItem() } }
                    Button {
                        Task { await commitNewItem() }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    newItemText = ""
                    isAddingItem = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { newItemFocused = true }
                } label: {
                    Label("Punkt hinzufügen", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.quaternarySystemFill))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(16)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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

    private var assignee: Member? {
        guard let id = item.assigneeId else { return nil }
        return viewModel.members.first { $0.userId == id }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await viewModel.toggleTodoItemDone(item) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundStyle(item.done ? .green : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.body)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            assigneeMenu
        }
        .padding(.vertical, 4)
        // Without this, long-pressing the Spacer's empty space between the
        // text and the assignee menu didn't register at all — .contextMenu
        // only picks up presses that land on actually-rendered content,
        // and an empty Spacer renders nothing to press on.
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: item.done)
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.deleteTodoItem(item) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    /// Tap the avatar (or the placeholder person icon) to assign — same
    /// people list as the project's Team sheet, no separate invite flow here.
    private var assigneeMenu: some View {
        Menu {
            if assignee != nil {
                Button {
                    Task { await viewModel.assignTodoItem(item, to: nil) }
                } label: {
                    Label("Niemand zugewiesen", systemImage: "xmark.circle")
                }
            }
            ForEach(viewModel.members) { member in
                Button {
                    Task { await viewModel.assignTodoItem(item, to: member.userId) }
                } label: {
                    Text(member.name?.isEmpty == false ? member.name! : member.email)
                }
            }
        } label: {
            if let assignee {
                initialsBadge(assignee)
            } else {
                // A bare icon here read as decorative rather than tappable —
                // "Zuweisen" makes it unmistakable that this is where you
                // assign someone to the item, not just a placeholder avatar.
                Label("Zuweisen", systemImage: "person.crop.circle.badge.plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .background(Color(.quaternarySystemFill))
                    .clipShape(Capsule())
                    .contentShape(Rectangle())
            }
        }
    }

    private func initialsBadge(_ member: Member) -> some View {
        MemberAvatar(member: member, size: 32)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
