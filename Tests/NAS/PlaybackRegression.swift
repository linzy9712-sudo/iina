import Foundation

private final class PlaybackHTTP: URLProtocol {
  static var reply: (URLRequest) throws -> (Int, String) = { _ in (500, "") }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (code, body) = try Self.reply(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@main struct PlaybackRegression {
  static func main() async throws {
    let server = NASServer(name: "Mock", baseURL: URL(string: "http://localhost:8096/jellyfin")!, serverID: "server", userID: "user")
    let entry = NASQueueEntry(title: "中文 电影", server: server.id, serverID: server.serverID, itemID: "abc123", sourceID: "source")
    precondition(NASQueueEntry.decode(entry.mpvPath) == entry)
    precondition(!entry.mpvPath.contains("token"))
    var copy = entry; copy.id = UUID(); precondition(copy.identity == entry.identity && copy.mpvPath != entry.mpvPath)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PlaybackHTTP.self]
    let client = JellyfinClient(deviceID: "device", session: URLSession(configuration: configuration))
    var negotiatedBodies: [[String: Any]] = []
    PlaybackHTTP.reply = { request in
      precondition(request.value(forHTTPHeaderField: "X-Emby-Token") == "test-token")
      if request.url!.path.contains("PlaybackInfo") {
        let data: Data
        if let body = request.httpBody { data = body }
        else {
          let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
          var collected = Data(), bytes = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable { let size = stream.read(&bytes, maxLength: bytes.count); if size <= 0 { break }; collected.append(contentsOf: bytes.prefix(size)) }
          data = collected
        }
        negotiatedBodies.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
        return (200, "{\"PlaySessionId\":\"session\",\"MediaSources\":[{\"Id\":\"source\",\"SupportsDirectPlay\":true,\"SupportsTranscoding\":true,\"TranscodingUrl\":\"Videos/abc123/master.m3u8\"}]}")
      }
      return (200, "{\"UserData\":{\"PlaybackPositionTicks\":120000000}}")
    }
    let direct = try await client.playback(server: server, entry: entry, token: "test-token", quality: .original, resume: true)
    precondition(!direct.transcode && direct.resumeTicks == 120000000 && direct.url.path == "/jellyfin/Videos/abc123/stream")
    let hls = try await client.playback(server: server, entry: entry, token: "test-token", quality: .hd720, resume: false)
    precondition(hls.transcode && hls.url.path == "/jellyfin/Videos/abc123/master.m3u8")
    precondition(negotiatedBodies[1]["EnableDirectPlay"] as? Bool == false)
    precondition(negotiatedBodies[1]["AllowVideoStreamCopy"] as? Bool == false)
    let profile = negotiatedBodies[1]["DeviceProfile"] as! [String: Any]
    let codecs = profile["CodecProfiles"] as! [[String: Any]]
    let conditions = codecs[0]["Conditions"] as! [[String: Any]]
    precondition(conditions.contains { $0["Property"] as? String == "Height" && $0["Value"] as? String == "720" })
    for bitrate in NASBitrate.allCases where bitrate != .automatic {
      let capped = try await client.playback(server: server, entry: entry, token: "test-token", quality: .original,
                                            resume: false, startTicks: 75_000_000, bitrate: bitrate)
      precondition(capped.transcode && capped.resumeTicks == 75_000_000)
      let body = negotiatedBodies.last!
      precondition(body["MaxStreamingBitrate"] as? Int == bitrate.bitsPerSecond)
      precondition((body["DeviceProfile"] as! [String: Any])["MaxStreamingBitrate"] as? Int == bitrate.bitsPerSecond)
      precondition(body["EnableDirectPlay"] as? Bool == false)
      precondition(body["AllowVideoStreamCopy"] as? Bool == false)
      precondition(body["EnableTranscoding"] as? Bool == true)
    }
    PlaybackHTTP.reply = { _ in (200, "{\"PlaySessionId\":\"session\",\"MediaSources\":[{\"Id\":\"source\",\"SupportsTranscoding\":true,\"TranscodingUrl\":\"https://untrusted.invalid/stream.m3u8\"}]}") }
    do { _ = try await client.playback(server: server, entry: entry, token: "test-token", quality: .transcode, resume: false); fatalError("Cross-origin stream accepted") }
    catch NASError.invalidResponse { }
    var requests: [URLRequest] = []
    PlaybackHTTP.reply = { request in requests.append(request); return (204, "") }
    try await client.report(server: server, token: "test-token", entry: entry, plan: hls, event: "", ticks: 0, paused: false)
    try await client.report(server: server, token: "test-token", entry: entry, plan: hls, event: "/Stopped", ticks: 100, paused: true)
    try await client.stopTranscode(server: server, token: "test-token", sessionID: hls.sessionID)
    precondition(requests.count == 3 && requests.last!.httpMethod == "DELETE")
    precondition(requests.last!.url!.query!.contains("PlaySessionId=session"))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("lists.json")
    let saved = NASPlaylistArchive(playlists: [NASSavedPlaylist(name: "Mixed", entries: [.local("/local.mp4"), entry, copy])])
    try saved.write(url)
    let restored = try NASPlaylistArchive.read(url)
    precondition(restored.playlists[0].entries.map(\.identity) == saved.playlists[0].entries.map(\.identity))
    let bytes = try String(contentsOf: url, encoding: .utf8)
    precondition(!bytes.contains("test-token") && !bytes.contains("master.m3u8") && !bytes.contains("PlaySessionId"))
    print("PASS: stable identities, mixed playlist archive, direct/HLS negotiation, resolution constraints, resume, cross-origin rejection and session-scoped cleanup")
  }
}
