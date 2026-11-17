import Foundation

/// Refresh at most once per server per import, with a short miss cooldown. Cached matches require no network request.
enum NASImportService {
  static func resolve(_ paths: [String], progress: @escaping (Int, Int) -> Void) async throws -> (entries: [NASQueueEntry], errors: [String]) {
    let store = NASPlayerCoordinator.store
    let configuration = try store.load()
    var indexes: [UUID: NASIndex] = [:], lookups: [UUID: NASPathLookup] = [:]
    var refresh = Set<UUID>()
    for path in paths {
      try Task.checkCancellation()
      guard let (rule, remote) = try? NASPathMapper.map(path, rules: configuration.mappings),
            let server = configuration.servers.first(where: { $0.id == rule.server }) else { continue }
      if indexes[server.id] == nil, let index = try? store.index(for: server) {
        indexes[server.id] = index; lookups[server.id] = NASPathLookup(index)
      }
      if let index = indexes[server.id] {
        do { _ = try lookups[server.id]!.match(remote, caseSensitive: rule.caseSensitive) }
        catch NASError.missingMedia { if Date().timeIntervalSince(index.refreshedAt) > 60 { refresh.insert(server.id) } }
        catch { /* Ambiguous matches cannot be repaired by guessing. */ }
      } else { refresh.insert(server.id) }
    }
    var warnings: [String] = []
    for server in configuration.servers where refresh.contains(server.id) {
      try Task.checkCancellation()
      do {
        let token = try JellyfinCredentialStore().read(server)
        let client = JellyfinClient(deviceID: configuration.deviceID)
        let index = try await client.index(server: server, token: token, progress: progress)
        try Task.checkCancellation()
        try store.save(index, for: server.id)
      } catch is CancellationError { throw CancellationError() }
      catch { warnings.append("\(server.name): \(error.localizedDescription)") }
    }
    try Task.checkCancellation()
    let result = NASImportResolver.resolve(paths, configuration: configuration, store: store)
    return (result.entries, warnings + result.errors)
  }
}
