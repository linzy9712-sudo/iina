import Foundation

struct JellyfinPlaybackPlan {
  let url: URL
  let sourceID: String
  let sessionID: String
  let transcode: Bool
  let resumeTicks: Int64
  let streams: [JellyfinClient.Stream]
  let audioIndex: Int?
  let subtitleIndex: Int?
}

extension JellyfinClient {
  struct PlaybackResponse: Decodable {
    let MediaSources: [PlaybackSource]?
    let PlaySessionId: String?
    let ErrorCode: String?
  }
  struct Stream: Decodable {
    let Index: Int
    let kind: String
    enum CodingKeys: String, CodingKey { case Index, kind = "Type", DisplayTitle, Codec, DeliveryUrl }
    let DisplayTitle: String?
    let Codec: String?
    let DeliveryUrl: String?
  }
  struct PlaybackSource: Decodable {
    let Id: String
    let Container: String?
    let SupportsDirectPlay: Bool?
    let SupportsTranscoding: Bool?
    let TranscodingUrl: String?
    let RequiredHttpHeaders: [String: String]?
    let MediaStreams: [Stream]?
    let DefaultAudioStreamIndex: Int?
    let DefaultSubtitleStreamIndex: Int?
  }
  struct UserItem: Decodable {
    struct Progress: Decodable { let PlaybackPositionTicks: Int64? }
    let UserData: Progress?
  }

  func playback(server: NASServer, entry: NASQueueEntry, token: String, quality: NASQuality, resume: Bool, audioIndex: Int? = nil, subtitleIndex: Int? = nil, startTicks: Int64? = nil, bitrate: NASBitrate = .automatic) async throws -> JellyfinPlaybackPlan {
    guard let item = entry.itemID, let user = server.userID else { throw NASError.authentication }
    // IDs are opaque single URL components, not arbitrary paths.
    guard item.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw NASError.invalidResponse }
    var ticks: Int64 = 0
    if resume && startTicks == nil {
      let detail: UserItem = try await request(server.baseURL, path: "Users/\(user)/Items/\(item)", token: token)
      ticks = max(0, detail.UserData?.PlaybackPositionTicks ?? 0)
    }
    if let startTicks { ticks = max(0, startTicks) }
    let forcesTranscode = quality.forcesTranscode || bitrate != .automatic
    let allowsTranscode = quality != .original || bitrate != .automatic
    let maxBitrate = bitrate.bitsPerSecond ?? quality.bitrate
    var codecConditions: [[String: Any]] = []
    if quality == .hd1080 || quality == .hd720 {
      codecConditions = [["Condition": "LessThanEqual", "Property": "Width", "Value": quality == .hd720 ? "1280" : "1920", "IsRequired": true],
                         ["Condition": "LessThanEqual", "Property": "Height", "Value": quality == .hd720 ? "720" : "1080", "IsRequired": true]]
    }
    let profile: [String: Any] = [
      "Name": "IINA", "MaxStreamingBitrate": maxBitrate,
      "DirectPlayProfiles": [["Type": "Video", "Container": "mkv,mp4,mov,avi,webm,ts,m2ts", "VideoCodec": "h264,hevc,av1,vp9,mpeg2video,mpeg4", "AudioCodec": "aac,mp3,ac3,eac3,dts,flac,opus,vorbis,pcm_s16le,truehd"]],
      "TranscodingProfiles": [["Type": "Video", "Container": "ts", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac", "Context": "Streaming", "MaxAudioChannels": "6", "MinSegments": 2, "BreakOnNonKeyFrames": false]],
      "CodecProfiles": [["Type": "Video", "Codec": "h264", "Conditions": codecConditions]],
      "SubtitleProfiles": [["Format": "srt", "Method": "External"], ["Format": "ass", "Method": "External"], ["Format": "subrip", "Method": "External"], ["Format": "pgssub", "Method": "Encode"]]]
    var body: [String: Any] = ["UserId": user, "DeviceProfile": profile, "MaxStreamingBitrate": maxBitrate,
      "EnableDirectPlay": !forcesTranscode, "EnableDirectStream": false,
      "EnableTranscoding": allowsTranscode, "AllowVideoStreamCopy": !forcesTranscode,
      "StartTimeTicks": 0, "AutoOpenLiveStream": false]
    if let source = entry.sourceID { body["MediaSourceId"] = source }
    if let audioIndex { body["AudioStreamIndex"] = audioIndex }
    if let subtitleIndex { body["SubtitleStreamIndex"] = subtitleIndex }
    let response: PlaybackResponse = try await request(server.baseURL, path: "Items/\(item)/PlaybackInfo", token: token,
      body: JSONSerialization.data(withJSONObject: body))
    guard response.ErrorCode == nil, let session = response.PlaySessionId, !session.isEmpty else { throw NASError.playbackUnavailable }
    let candidates = (response.MediaSources ?? []).filter { entry.sourceID == nil || $0.Id == entry.sourceID }
    let direct = forcesTranscode ? nil : candidates.first { $0.SupportsDirectPlay == true }
    guard let source = direct ?? (!allowsTranscode ? nil : candidates.first { $0.SupportsTranscoding == true }) else { throw NASError.playbackUnavailable }
    // Remote-provider media with additional credentials needs a separate transport provider.
    guard source.RequiredHttpHeaders?.isEmpty != false else { throw NASError.invalidResponse }
    if !forcesTranscode, source.SupportsDirectPlay == true {
      var components = URLComponents(url: server.baseURL.appendingPathComponent("Videos/\(item)/stream"), resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "Static", value: "true"), URLQueryItem(name: "MediaSourceId", value: source.Id),
        URLQueryItem(name: "PlaySessionId", value: session), URLQueryItem(name: "DeviceId", value: deviceID)]
      return JellyfinPlaybackPlan(url: components.url!, sourceID: source.Id, sessionID: session, transcode: false, resumeTicks: ticks, streams: source.MediaStreams ?? [], audioIndex: audioIndex ?? source.DefaultAudioStreamIndex, subtitleIndex: subtitleIndex ?? source.DefaultSubtitleStreamIndex)
    }
    guard allowsTranscode, source.SupportsTranscoding == true, let stream = source.TranscodingUrl,
          let url = URL(string: stream, relativeTo: URL(string: server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")!)?.absoluteURL,
          url.scheme == server.baseURL.scheme, url.host == server.baseURL.host, url.port == server.baseURL.port,
          url.user == nil, url.password == nil else { throw NASError.invalidResponse }
    return JellyfinPlaybackPlan(url: url, sourceID: source.Id, sessionID: session, transcode: true, resumeTicks: ticks, streams: source.MediaStreams ?? [], audioIndex: audioIndex ?? source.DefaultAudioStreamIndex, subtitleIndex: subtitleIndex ?? source.DefaultSubtitleStreamIndex)
  }

  func subtitle(server: NASServer, token: String, stream: Stream) async throws -> Data {
    guard let raw = stream.DeliveryUrl,
          let url = URL(string: raw, relativeTo: URL(string: server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")!)?.absoluteURL,
          url.scheme == server.baseURL.scheme, url.host == server.baseURL.host, url.port == server.baseURL.port,
          url.user == nil, url.password == nil else { throw NASError.invalidResponse }
    let data: Data = try await request(url, path: "", token: token)
    guard data.count <= 20_000_000 else { throw NASError.invalidResponse }
    return data
  }

  func report(server: NASServer, token: String, entry: NASQueueEntry, plan: JellyfinPlaybackPlan,
              event: String, ticks: Int64, paused: Bool) async throws {
    let body: [String: Any] = ["ItemId": entry.itemID!, "MediaSourceId": plan.sourceID, "PlaySessionId": plan.sessionID,
      "PositionTicks": max(0, ticks), "IsPaused": paused, "CanSeek": true,
      "PlayMethod": plan.transcode ? "Transcode" : "DirectPlay", "EventName": "TimeUpdate"]
    let _: JellyfinEmptyResponse = try await request(server.baseURL, path: "Sessions/Playing" + event, token: token,
                                                    body: JSONSerialization.data(withJSONObject: body))
  }
  func stopTranscode(server: NASServer, token: String, sessionID: String) async throws {
    let _: JellyfinEmptyResponse = try await request(server.baseURL, path: "Videos/ActiveEncodings", token: token,
      query: [URLQueryItem(name: "DeviceId", value: deviceID), URLQueryItem(name: "PlaySessionId", value: sessionID)], method: "DELETE")
  }
}
