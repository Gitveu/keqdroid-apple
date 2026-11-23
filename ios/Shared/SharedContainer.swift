import Foundation

enum SharedContainer {
  static let defaultAppGroup = "group.com.keqdroid.keqdroid"
  static let tunnelExtensionSuffix = ".PacketTunnel"

  static var mainBundleIdentifier: String {
    let raw = Bundle.main.bundleIdentifier ?? "com.keqdroid.keqdroid"
    if raw.hasSuffix(tunnelExtensionSuffix) {
      return String(raw.dropLast(tunnelExtensionSuffix.count))
    }
    return raw
  }

  static var tunnelBundleIdentifier: String {
    return mainBundleIdentifier + tunnelExtensionSuffix
  }

  static var appGroupIdentifier: String {
    if let configured = Bundle.main.object(forInfoDictionaryKey: "KeqdroidAppGroup") as? String,
       !configured.isEmpty,
       !configured.contains("$("),
       FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: configured) != nil {
      return configured
    }
    let derived = "group.\(mainBundleIdentifier)"
    if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: derived) != nil {
      return derived
    }
    return defaultAppGroup
  }

  static var containerURL: URL {
    let fm = FileManager.default
    if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
      let dataDir = url.appendingPathComponent("keqdroid", isDirectory: true)
      try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
      return dataDir
    }
    let fallback = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("keqdroid", isDirectory: true)
    try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
    return fallback
  }

  static var coreLogURL: URL {
    containerURL.appendingPathComponent("core_logs.txt")
  }

  static var nativeLogURL: URL {
    containerURL.appendingPathComponent("ios_native.log")
  }

  static var sessionMetaURL: URL {
    containerURL.appendingPathComponent("session_meta.json")
  }

  static func configURL(for engine: String) -> URL {
    let name = engine.lowercased() == "mihomo" ? "mihomo_config.yaml" : "xray_config.json"
    return containerURL.appendingPathComponent(name)
  }

  static func appendNativeLog(_ message: String) {
    let url = nativeLogURL
    let df = DateFormatter()
    df.dateFormat = "yyyy/MM/dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      try? data.write(to: url, options: .atomic)
      return
    }
    if let attrs = try? fm.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int,
       size > 256 * 1024,
       let existing = try? Data(contentsOf: url) {
      let tail = existing.suffix(128 * 1024)
      var trimmed = Data(tail)
      trimmed.append(data)
      try? trimmed.write(to: url, options: .atomic)
      return
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    }
  }

  static func readSessionMeta() -> [String: Any] {
    guard let data = try? Data(contentsOf: sessionMetaURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return obj
  }

  static func writeSessionMeta(_ meta: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) else {
      return
    }
    try? data.write(to: sessionMetaURL, options: .atomic)
  }

  /// Bridges Swift String to cgo's non-const `char*` parameters safely.
  static func withCString<R>(_ value: String, _ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
    let dup = strdup(value)!
    defer { free(dup) }
    return body(dup)
  }
}
