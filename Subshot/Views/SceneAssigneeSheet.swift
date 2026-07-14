import SwiftUI

/// Multi-select "Zuständig" picker (2026-07-14, Lino: "mehrere Personen
/// auswählen können und auch wieder entfernen können") — a sheet instead of
/// a native Menu because SwiftUI's Menu dismisses on every Button tap with
/// no built-in way to keep it open across several picks, which a genuine
/// multi-select needs (tap several members, then explicitly close).
struct SceneAssigneeSheet: View {
    let scene: Scene
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss

    /// Looks the scene up fresh from viewModel.scenes on every render
    /// instead of using the captured `scene` parameter directly — that
    /// parameter is a value-type snapshot from whenever the sheet was
    /// presented, so checkmarks would otherwise freeze at whatever the
    /// selection was at that moment instead of updating live as this same
    /// sheet session toggles members in/out.
    private var currentAssigneeIds: [String] {
        (viewModel.scenes.first { $0.id == scene.id } ?? scene).assigneeIds
    }

    var body: some View {
        NavigationStack {
            List(viewModel.members) { member in
                Button {
                    Task { await viewModel.toggleSceneAssignee(scene, userId: member.userId) }
                } label: {
                    HStack {
                        MemberAvatar(member: member, size: 32)
                        Text(member.name?.isEmpty == false ? member.name! : member.email)
                            .foregroundStyle(.primary)
                        Spacer()
                        if currentAssigneeIds.contains(member.userId) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                }
            }
            .navigationTitle("Zuständig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
