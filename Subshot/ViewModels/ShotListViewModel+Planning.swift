import Foundation
import SwiftUI

// 2026-10-12 — web parity for the shot-list "am Set" features: weather per scene, Drehorte (places
// with colours, bulk assignment, default place per shotlist), applying a suggested shooting order.

extension ShotListViewModel {
    // MARK: Weather

    func loadSceneWeather() async {
        guard let w = try? await APIClient.shared.sceneWeather(projectId: projectId) else { return }
        if w != sceneWeather { sceneWeather = w }
    }

    // MARK: Drehorte

    /// the places of a shotlist: its default (Section.location) first, then the scenes' own places
    func places(in section: SceneSection?) -> [ShotlistPlace] {
        ShotlistPlace.build(section: section, scenes: scenes(in: section))
    }

    /// where a scene is shot: its own place, else the shotlist's default (intermediate steps: none)
    func placeAddress(of scene: Scene, in section: SceneSection?) -> String? {
        if scene.isIntermediateStep || scene.isProjectInfo { return nil }
        return scene.locationAddress ?? section?.locationAddress
    }

    /// set the place of several scenes at once (the default place = no own place, so they follow
    /// the shotlist's default if it changes later)
    func assignPlace(_ place: ShotlistPlace?, to sceneIds: [String], in section: SceneSection) async {
        guard !sceneIds.isEmpty else { return }
        let own = (place == nil || place?.address == section.locationAddress) ? nil : place
        let before = scenes
        withAnimation(.easeOut(duration: 0.2)) {
            for id in sceneIds {
                if let i = scenes.firstIndex(where: { $0.id == id }) {
                    scenes[i].locationAddress = own?.address
                    scenes[i].locationLat = own?.lat
                    scenes[i].locationLng = own?.lng
                }
            }
        }
        do {
            let updated = try await APIClient.shared.assignSceneLocation(sectionId: section.id, sceneIds: sceneIds, address: own?.address, lat: own?.lat, lng: own?.lng)
            for u in updated {
                if let i = scenes.firstIndex(where: { $0.id == u.id }), scenes[i] != u { scenes[i] = u }
            }
        } catch {
            scenes = before
            errorMessage = error.localizedDescription
        }
    }

    /// make a place the shotlist's default (Section.location_*)
    func setDefaultPlace(_ place: ShotlistPlace, in section: SceneSection) async {
        guard let lat = place.lat, let lng = place.lng else { return }
        await updateSectionLocation(section, address: place.address, lat: lat, lng: lng)
    }

    // MARK: Drehreihenfolge

    /// save a whole new Shot-Reihenfolge (e.g. the optimizer's suggestion)
    func applyShootingOrder(_ orderedIds: [String], in sectionId: String) async {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            for (index, id) in orderedIds.enumerated() {
                if let i = scenes.firstIndex(where: { $0.id == id }), scenes[i].shootingOrder != index {
                    scenes[i].shootingOrder = index
                }
            }
        }
        do {
            _ = try await APIClient.shared.reorderScenesShootingOrder(sectionId: sectionId, orderedSceneIds: orderedIds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Progress

    /// "im Kasten" of a shotlist — same rule as the web (every scene except info tiles)
    func progress(in section: SceneSection?) -> (done: Int, total: Int) {
        let real = scenes(in: section).filter { !$0.isProjectInfo }
        return (real.filter(\.completed).count, real.count)
    }
}
