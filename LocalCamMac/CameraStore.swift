import Foundation

@MainActor
final class CameraStore: ObservableObject {
    @Published private(set) var cameras: [CameraRecord] = []

    private let storageKey = "local-cam-macos.camera-library"

    init() {
        load()
    }

    func add(camera: CameraRecord) {
        cameras.insert(camera, at: 0)
        save()
    }

    func update(camera: CameraRecord) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[index] = camera
        save()
    }

    func remove(_ camera: CameraRecord) {
        cameras.removeAll { $0.id == camera.id }
        save()
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([CameraRecord].self, from: data)
        else {
            cameras = []
            return
        }
        cameras = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
