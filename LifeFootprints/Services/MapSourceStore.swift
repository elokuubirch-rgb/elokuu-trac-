import Foundation

extension Notification.Name {
    static let mapSourcesChanged = Notification.Name("mapSourcesChanged")
}

enum MapSourceStore {
    private static let storageKey = "customMapSources.v1"

    static func load() -> [CustomMapSource] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([CustomMapSource].self, from: data)) ?? []
    }

    static func save(_ sources: [CustomMapSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: .mapSourcesChanged, object: nil)
    }

    static func upsert(_ source: CustomMapSource) {
        var sources = load()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        save(sources)
    }

    static func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    static func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        save(load().filter { !ids.contains($0.id) })
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: .mapSourcesChanged, object: nil)
    }
}
