import Foundation

enum SharedContainer {
  static let defaultAppGroup = "group.com.keqdroid.keqdroid"
  static let tunnelExtensionSuffix = ".PacketTunnel"

  static var isExtensionProcess: Bool {
    Bundle.main.bundleURL.pathExtension == "appex"
  }

  static var mainAppBundleURL: URL {
    if isExtensionProcess {
      // Runner.app/PlugIns/PacketTunnelExtension.appex -> Runner.app
      return Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    }
    return Bundle.main.bundleURL
  }

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

  /// Resolves a usable App Group container in priority order:
  /// 1. `KeqdroidAppGroup` in Info.plist (if accessible)
  /// 2. `group.<mainBundleIdentifier>` (automatic after re-signing with matching group)
  /// 3. Any App Group declared in `embedded.mobileprovision` (custom/resigner group)
  private static let resolvedAppGroup: (id: String, url: URL?) = {
    let fm = FileManager.default
    var candidates: [String] = []

    if let configured = Bundle.main.object(forInfoDictionaryKey: "KeqdroidAppGroup") as? String,
       !configured.isEmpty,
       !configured.contains("$(") {
      candidates.append(configured)
    }
    candidates.append("group.\(mainBundleIdentifier)")
    candidates.append(contentsOf: provisioningAppGroups())
    candidates.append(defaultAppGroup)

    var seen = Set<String>()
    for group in candidates where seen.insert(group).inserted {
      if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
        return (group, url)
      }
    }
    return (defaultAppGroup, nil)
  }()

  static var appGroupIdentifier: String {
    resolvedAppGroup.id
  }

  static var hasSharedAppGroup: Bool {
    resolvedAppGroup.url != nil
  }

  static var containerURL: URL {
    let fm = FileManager.default
    if let url = resolvedAppGroup.url {
      let dataDir = url.appendingPathComponent("keqdroid", isDirectory: true)
      try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
      return dataDir
    }
    let fallback = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("keqdroid", isDirectory: true)
    try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
    return fallback
  }

  static var geoipURL: URL {
    containerURL.appendingPathComponent("geoip.dat")
  }

  static var geositeURL: URL {
    containerURL.appendingPathComponent("geosite.dat")
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

  static func fileSize(at url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
  }

  /// Copies bundled `geoip-lite.dat` and `geosite.dat` from `Runner.app`'s
  /// `flutter_assets` into `containerURL`. Works in both `Runner` and
  /// `PacketTunnelExtension` even without an App Group, while never overwriting
  /// a larger user-downloaded full `geoip.dat`.
  static func ensureBundledGeoAssets() {
    let fm = FileManager.default
    let flutterAssets = mainAppBundleURL
      .appendingPathComponent("Frameworks", isDirectory: true)
      .appendingPathComponent("App.framework", isDirectory: true)
      .appendingPathComponent("flutter_assets", isDirectory: true)

    let mapping: [(rel: String, dst: URL)] = [
      ("assets/geo/geoip-lite.dat", geoipURL),
      ("assets/bin/windows/geosite.dat", geositeURL),
    ]

    for item in mapping {
      let srcURL = flutterAssets.appendingPathComponent(item.rel)
      guard fm.fileExists(atPath: srcURL.path) else { continue }
      let srcSize = fileSize(at: srcURL)
      let dstSize = fileSize(at: item.dst)
      if fm.fileExists(atPath: item.dst.path) {
        if dstSize >= srcSize && dstSize > 0 {
          continue
        }
        try? fm.removeItem(at: item.dst)
      }
      try? fm.copyItem(at: srcURL, to: item.dst)
    }
  }

  static func readTailText(url: URL, maxBytes: Int) -> String {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      return ""
    }
    if data.count <= maxBytes {
      return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: data.suffix(maxBytes), as: UTF8.self)
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

  /// Extracts `com.apple.security.application-groups` from `embedded.mobileprovision`
  /// so certificates with a custom resigner App Group still share storage seamlessly.
  private static func provisioningAppGroups() -> [String] {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision"),
      mainAppBundleURL.appendingPathComponent("embedded.mobileprovision"),
    ]
    for url in candidates {
      guard let raw = try? Data(contentsOf: url),
            let text = String(data: raw, encoding: .isoLatin1),
            let start = text.range(of: "<?xml"),
            let end = text.range(of: "</plist>") else {
        continue
      }
      let plistStr = String(text[start.lowerBound..<end.upperBound])
      guard let plistData = plistStr.data(using: .utf8),
            let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let groups = entitlements["com.apple.security.application-groups"] as? [String],
            !groups.isEmpty else {
        continue
      }
      return groups
    }
    return []
  }
}
