import Flutter
import Foundation
import KeqCore
import NetworkExtension
import Security
import UIKit

final class IosVpnPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let methodChannelName = "keqdroid_vpn_channel"
  static let statusEventChannelName = "keqdroid_vpn_status"

  private static weak var sharedInstance: IosVpnPlugin?
  private static var pendingDeepLinkURL: String?

  private let registrar: FlutterPluginRegistrar
  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var statusObserver: NSObjectProtocol?
  private var statsTimer: Timer?

  private var activeManager: NETunnelProviderManager?
  private var generatedCreds: (username: String, password: String)?

  private var lastRxBytes: Int64 = 0
  private var lastTxBytes: Int64 = 0
  private var lastStatsTimestamp: TimeInterval = 0
  private var lastDownloadSpeed: Int64 = 0
  private var lastUploadSpeed: Int64 = 0
  private var lastDialFailures: Int64 = 0
  private var lastNetworkChanges: Int = 0
  private var lastPathSatisfied: Bool = true
  private var lastErrorMessage: String?
  private var geoSyncInFlight: Bool = false

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
    extractGeoAssetsIfNeeded()
    observeVpnStatus()
    reloadActiveManager()
  }

  deinit {
    statsTimer?.invalidate()
    if let obs = statusObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = IosVpnPlugin(registrar: registrar)
    sharedInstance = instance

    let method = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    instance.methodChannel = method
    registrar.addMethodCallDelegate(instance, channel: method)

    let event = FlutterEventChannel(
      name: statusEventChannelName,
      binaryMessenger: registrar.messenger()
    )
    event.setStreamHandler(instance)
  }

  static func handleIncomingURL(_ url: URL) {
    let raw = url.absoluteString
    guard !raw.isEmpty else { return }
    pendingDeepLinkURL = raw
    DispatchQueue.main.async {
      sharedInstance?.methodChannel?.invokeMethod("onDeepLink", arguments: raw)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    emitCurrentStatus()
    startStatsTimer()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    statsTimer?.invalidate()
    statsTimer = nil
    return nil
  }

  // MARK: - FlutterPlugin Method Dispatch

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSocksCredentials":
      let creds = ensureCredentials()
      result(["username": creds.username, "password": creds.password])

    case "getActiveSocksCredentials":
      let meta = SharedContainer.readSessionMeta()
      let user = meta["socksUsername"] as? String ?? ""
      let pass = meta["socksPassword"] as? String ?? ""
      if user.isEmpty || pass.isEmpty {
        result(nil)
      } else {
        result(["username": user, "password": pass])
      }

    case "requestVpnPermission":
      requestVpnPermission(result: result)

    case "startVpn":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing startVpn arguments", details: nil))
        return
      }
      startVpn(args: args, result: result)

    case "stopVpn":
      stopVpn(result: result)

    case "reloadMihomoConfig":
      guard let args = call.arguments as? [String: Any],
            let config = args["mihomoConfig"] as? String, !config.isEmpty else {
        result(false)
        return
      }
      reloadMihomoConfig(config: config, serverName: args["serverName"] as? String, result: result)

    case "getStatus":
      queryExtensionStatsIfConnected { [weak self] in
        guard let self = self else {
          result(["status": "DISCONNECTED"])
          return
        }
        result(self.buildStatusMap())
      }

    case "getXrayLogs":
      fetchLogs(kind: "core", result: result)

    case "getNativeLog":
      fetchLogs(kind: "native", result: result)

    case "syncGeoAssets":
      syncGeoToExtensionIfNeeded(restartAfter: true) { ok in
        result(ok)
      }

    case "getMihomoApi":
      let meta = SharedContainer.readSessionMeta()
      let port = meta["mihomoApiPort"] as? Int ?? 0
      let secret = meta["mihomoApiSecret"] as? String ?? ""
      if port > 0 && !secret.isEmpty {
        result(["port": port, "secret": secret])
      } else {
        result(nil)
      }

    case "getDialFailures":
      result(Int(lastDialFailures))

    case "getPhysicalNetworks":
      result(["count": lastPathSatisfied ? 1 : 0, "changes": lastNetworkChanges])

    case "getSharedContainerPath":
      extractGeoAssetsIfNeeded()
      result(SharedContainer.containerURL.path)

    case "getCoreVersions":
      result(fetchCoreVersions())

    case "getDeviceModel":
      result(hardwareModelIdentifier())

    case "getNativeInternals":
      result([
        "iosVersion": UIDevice.current.systemVersion,
        "deviceModel": hardwareModelIdentifier(),
        "appGroup": SharedContainer.appGroupIdentifier,
        "coreVersions": fetchCoreVersions(),
      ])

    case "getPendingDeepLink":
      let link = IosVpnPlugin.pendingDeepLinkURL
      IosVpnPlugin.pendingDeepLinkURL = nil
      result(link)

    case "getInstalledApps":
      result([])

    case "xrayUrlTestBatch":
      guard let args = call.arguments as? [String: Any] else {
        result([])
        return
      }
      handleUrlTestBatch(args: args, result: result)

    case "xrayUrlTestMulti":
      guard let args = call.arguments as? [String: Any] else {
        result([])
        return
      }
      handleUrlTestMulti(args: args, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - VPN Lifecycle

  private func reloadActiveManager(completion: ((NETunnelProviderManager?) -> Void)? = nil) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self = self else { return }
      if let error = error {
        SharedContainer.appendNativeLog("App: loadAllFromPreferences failed: \(error)")
      }
      let tunnelId = SharedContainer.tunnelBundleIdentifier
      let matched = managers?.first { mgr in
        (mgr.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelId
      } ?? managers?.first
      self.activeManager = matched
      completion?(matched)
    }
  }

  private func loadOrCreateManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self = self else { return }
      if let error = error {
        completion(nil, error)
        return
      }
      let tunnelId = SharedContainer.tunnelBundleIdentifier
      let manager = managers?.first { mgr in
        (mgr.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelId
      } ?? NETunnelProviderManager()

      let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
      proto.providerBundleIdentifier = tunnelId
      proto.serverAddress = "keqdroid"
      manager.protocolConfiguration = proto
      manager.localizedDescription = "keqdroid"
      manager.isEnabled = true

      self.activeManager = manager
      completion(manager, nil)
    }
  }

  private func requestVpnPermission(result: @escaping FlutterResult) {
    loadOrCreateManager { manager, error in
      if let error = error {
        result(FlutterError(code: "PERMISSION_ERROR", message: error.localizedDescription, details: nil))
        return
      }
      guard let manager = manager else {
        result(false)
        return
      }
      manager.saveToPreferences { saveError in
        if let saveError = saveError as NSError? {
          if saveError.domain == NEVPNErrorDomain && saveError.code == NEVPNError.configurationReadWriteFailed.rawValue {
            result(FlutterError(code: "PERMISSION_DENIED", message: saveError.localizedDescription, details: nil))
          } else {
            result(FlutterError(code: "PERMISSION_ERROR", message: saveError.localizedDescription, details: nil))
          }
          return
        }
        manager.loadFromPreferences { _ in
          result(true)
        }
      }
    }
  }

  private func startVpn(args: [String: Any], result: @escaping FlutterResult) {
    extractGeoAssetsIfNeeded()

    let backend = (args["vpnBackend"] as? String ?? "xray").lowercased()
    let engine = backend == "mihomo" ? "mihomo" : "xray"
    let xrayConfig = args["xrayConfig"] as? String ?? ""
    let mihomoConfig = args["mihomoConfig"] as? String ?? ""
    let configContent = engine == "mihomo" ? mihomoConfig : xrayConfig

    if configContent.isEmpty {
      result(FlutterError(code: "EMPTY_CONFIG", message: "Empty \(engine) config", details: nil))
      return
    }

    let serverName = args["serverName"] as? String ?? ""
    let socksUser = args["socksUsername"] as? String ?? generatedCreds?.username ?? ""
    let socksPass = args["socksPassword"] as? String ?? generatedCreds?.password ?? ""
    let logLevel = extractLogLevel(engine: engine, configContent: configContent)
    let mtu = extractMtu(configContent: configContent)
    let ipv6 = configHasIPv6Tun(engine: engine, configContent: configContent)
    let mihomoApi = engine == "mihomo" ? extractMihomoApi(configContent: configContent) : (0, "")

    let configURL = SharedContainer.configURL(for: engine)
    do {
      try configContent.write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      result(FlutterError(code: "CONFIG_WRITE_FAILED", message: error.localizedDescription, details: nil))
      return
    }

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    SharedContainer.writeSessionMeta([
      "engine": engine,
      "serverName": serverName,
      "socksUsername": socksUser,
      "socksPassword": socksPass,
      "logLevel": logLevel,
      "mtu": mtu,
      "ipv6": ipv6,
      "mihomoApiPort": mihomoApi.0,
      "mihomoApiSecret": mihomoApi.1,
      "startTime": nowMs,
    ])

    lastRxBytes = 0
    lastTxBytes = 0
    lastDownloadSpeed = 0
    lastUploadSpeed = 0
    lastDialFailures = 0
    lastStatsTimestamp = Date().timeIntervalSince1970
    lastErrorMessage = nil

    loadOrCreateManager { [weak self] manager, error in
      guard let self = self else { return }
      if let error = error {
        result(FlutterError(code: "VPN_LOAD_FAILED", message: error.localizedDescription, details: nil))
        return
      }
      guard let manager = manager,
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
        result(FlutterError(code: "VPN_CONFIG_INVALID", message: "Invalid VPN protocol configuration", details: nil))
        return
      }

      proto.providerConfiguration = [
        "engine": engine,
        "configContent": configContent,
        "logLevel": logLevel,
        "mtu": mtu,
        "ipv6": ipv6,
      ]
      manager.protocolConfiguration = proto
      manager.isEnabled = true

      manager.saveToPreferences { saveError in
        if let saveError = saveError {
          self.lastErrorMessage = saveError.localizedDescription
          result(FlutterError(code: "VPN_SAVE_FAILED", message: saveError.localizedDescription, details: nil))
          return
        }
        manager.loadFromPreferences { loadError in
          if let loadError = loadError {
            self.lastErrorMessage = loadError.localizedDescription
            result(FlutterError(code: "VPN_RELOAD_FAILED", message: loadError.localizedDescription, details: nil))
            return
          }
          do {
            try manager.connection.startVPNTunnel()
            self.startStatsTimer()
            self.emitCurrentStatus()
            result(nil)
          } catch {
            self.lastErrorMessage = error.localizedDescription
            result(FlutterError(code: "VPN_START_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  private func stopVpn(result: @escaping FlutterResult) {
    activeManager?.connection.stopVPNTunnel()
    lastDownloadSpeed = 0
    lastUploadSpeed = 0
    lastRxBytes = 0
    lastTxBytes = 0
    lastDialFailures = 0
    emitCurrentStatus()
    result(nil)
  }

  private func reloadMihomoConfig(config: String, serverName: String?, result: @escaping FlutterResult) {
    guard let session = activeManager?.connection as? NETunnelProviderSession,
          session.status == .connected else {
      result(false)
      return
    }
    var meta = SharedContainer.readSessionMeta()
    if let serverName = serverName, !serverName.isEmpty {
      meta["serverName"] = serverName
    }
    let mihomoApi = extractMihomoApi(configContent: config)
    if mihomoApi.0 > 0 {
      meta["mihomoApiPort"] = mihomoApi.0
      meta["mihomoApiSecret"] = mihomoApi.1
    }
    SharedContainer.writeSessionMeta(meta)

    let payload: [String: Any] = ["cmd": "reloadMihomo", "configContent": config]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      result(false)
      return
    }
    do {
      try session.sendProviderMessage(data) { reply in
        guard let reply = reply,
              let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let ok = json["ok"] as? Bool else {
          result(false)
          return
        }
        result(ok)
      }
    } catch {
      result(false)
    }
  }

  // MARK: - Status & Telemetry

  private func observeVpnStatus() {
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self = self else { return }
      if let conn = notification.object as? NEVPNConnection,
         let active = self.activeManager?.connection,
         conn !== active {
        return
      }
      self.emitCurrentStatus()
      if self.activeManager?.connection.status == .connected {
        self.syncGeoToExtensionIfNeeded(restartAfter: true, completion: nil)
      }
    }
  }

  private func startStatsTimer() {
    statsTimer?.invalidate()
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      guard let self = self, self.eventSink != nil else { return }
      self.queryExtensionStatsIfConnected { [weak self] in
        self?.emitCurrentStatus()
      }
    }
  }

  private func queryExtensionStatsIfConnected(completion: @escaping () -> Void) {
    guard let session = activeManager?.connection as? NETunnelProviderSession,
          session.status == .connected else {
      lastDownloadSpeed = 0
      lastUploadSpeed = 0
      completion()
      return
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["cmd": "stats"]) else {
      completion()
      return
    }
    do {
      try session.sendProviderMessage(data) { [weak self] reply in
        DispatchQueue.main.async {
          defer { completion() }
          guard let self = self,
                let reply = reply,
                let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            return
          }
          let rx = (json["rx"] as? NSNumber)?.int64Value ?? self.lastRxBytes
          let tx = (json["tx"] as? NSNumber)?.int64Value ?? self.lastTxBytes
          self.lastDialFailures = (json["dialFailures"] as? NSNumber)?.int64Value ?? self.lastDialFailures
          self.lastNetworkChanges = (json["networkChanges"] as? NSNumber)?.intValue ?? self.lastNetworkChanges
          self.lastPathSatisfied = (json["pathSatisfied"] as? Bool) ?? true

          let now = Date().timeIntervalSince1970
          let dt = now - self.lastStatsTimestamp
          if dt > 0.1 && self.lastStatsTimestamp > 0 {
            let drx = max(0, rx - self.lastRxBytes)
            let dtx = max(0, tx - self.lastTxBytes)
            self.lastDownloadSpeed = Int64(Double(drx) / dt)
            self.lastUploadSpeed = Int64(Double(dtx) / dt)
          }
          self.lastRxBytes = rx
          self.lastTxBytes = tx
          self.lastStatsTimestamp = now
        }
      }
    } catch {
      completion()
    }
  }

  private func mapStatus(_ status: NEVPNStatus) -> String {
    switch status {
    case .connected:
      return "CONNECTED"
    case .connecting, .reasserting:
      return "CONNECTING"
    case .disconnecting:
      return "DISCONNECTING"
    case .disconnected, .invalid:
      return "DISCONNECTED"
    @unknown default:
      return "DISCONNECTED"
    }
  }

  private func buildStatusMap() -> [String: Any] {
    let neStatus = activeManager?.connection.status ?? .disconnected
    let meta = SharedContainer.readSessionMeta()
    var map: [String: Any] = [
      "status": mapStatus(neStatus),
      "downloadSpeed": Int(lastDownloadSpeed),
      "uploadSpeed": Int(lastUploadSpeed),
      "totalDownload": Int(lastRxBytes),
      "totalUpload": Int(lastTxBytes),
      "connectionMode": "tun",
    ]
    if neStatus == .connected, let startTimeMs = meta["startTime"] as? Int64 {
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
      map["durationSeconds"] = max(0, Int((nowMs - startTimeMs) / 1000))
    }
    if let err = lastErrorMessage, !err.isEmpty, neStatus == .disconnected {
      map["error"] = err
    }
    return map
  }

  private func emitCurrentStatus() {
    guard let sink = eventSink else { return }
    sink(buildStatusMap())
  }

  // MARK: - In-Process URL Tests (via KeqCore)

  private func handleUrlTestBatch(args: [String: Any], result: @escaping FlutterResult) {
    let items = args["items"] as? [[String: Any]] ?? []
    let socksPort = args["socksPort"] as? Int ?? 10808
    let testUrl = args["testUrl"] as? String ?? "https://connectivitycheck.gstatic.com/generate_204"
    let timeoutMs = args["timeoutMs"] as? Int ?? 15000
    let dataDir = SharedContainer.containerURL.path

    DispatchQueue.global(qos: .userInitiated).async {
      var out: [[String: Any]] = []
      for item in items {
        let id = item["id"] as? String ?? ""
        let config = item["xrayConfig"] as? String ?? ""
        if config.isEmpty {
          out.append(["id": id, "success": false, "latencyMs": NSNull(), "error": "empty config"])
          continue
        }
        let ms: Int64 = SharedContainer.withCString(config) { cfgC in
          SharedContainer.withCString(dataDir) { dirC in
            SharedContainer.withCString(testUrl) { urlC in
              KeqCoreUrlTest(cfgC, dirC, Int32(socksPort), urlC, Int32(timeoutMs))
            }
          }
        }
        if ms > 0 {
          out.append(["id": id, "success": true, "latencyMs": Int(ms)])
        } else {
          out.append(["id": id, "success": false, "latencyMs": NSNull(), "error": "timeout"])
        }
      }
      DispatchQueue.main.async {
        result(out)
      }
    }
  }

  private func handleUrlTestMulti(args: [String: Any], result: @escaping FlutterResult) {
    let config = args["config"] as? String ?? ""
    let probes = args["probes"] as? [[String: Any]] ?? []
    let testUrl = args["testUrl"] as? String ?? "https://connectivitycheck.gstatic.com/generate_204"
    let timeoutMs = args["timeoutMs"] as? Int ?? 15000
    let dataDir = SharedContainer.containerURL.path

    if config.isEmpty || probes.isEmpty {
      result([])
      return
    }
    let ports = probes.map { $0["port"] as? Int ?? 0 }
    guard let portsData = try? JSONSerialization.data(withJSONObject: ports),
          let portsJson = String(data: portsData, encoding: .utf8) else {
      result([])
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let jsonPtr: UnsafeMutablePointer<CChar>? = SharedContainer.withCString(config) { cfgC in
        SharedContainer.withCString(dataDir) { dirC in
          SharedContainer.withCString(portsJson) { portsC in
            SharedContainer.withCString(testUrl) { urlC in
              KeqCoreUrlTestBatch(cfgC, dirC, portsC, urlC, Int32(timeoutMs))
            }
          }
        }
      }
      var map: [String: Int] = [:]
      if let ptr = jsonPtr {
        let raw = String(cString: ptr)
        KeqCoreFreeString(ptr)
        if let data = raw.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int] {
          map = parsed
        }
      }
      var out: [[String: Any]] = []
      for (idx, probe) in probes.enumerated() {
        let id = probe["id"] as? String ?? ""
        let ms = map["\(idx)"] ?? -1
        if ms > 0 {
          out.append(["id": id, "success": true, "latencyMs": ms])
        } else {
          out.append(["id": id, "success": false, "latencyMs": NSNull(), "error": "timeout"])
        }
      }
      DispatchQueue.main.async {
        result(out)
      }
    }
  }

  // MARK: - Helpers

  private func ensureCredentials() -> (username: String, password: String) {
    if let existing = generatedCreds {
      return existing
    }
    let creds = (username: randomToken(bytes: 8), password: randomToken(bytes: 16))
    generatedCreds = creds
    return creds
  }

  private func randomToken(bytes count: Int) -> String {
    var buf = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
    return buf.map { String(format: "%02x", $0) }.joined()
  }

  private func extractGeoAssetsIfNeeded() {
    SharedContainer.ensureBundledGeoAssets()
  }

  private func fetchLogs(kind: String, result: @escaping FlutterResult) {
    let localURL = kind == "native" ? SharedContainer.nativeLogURL : SharedContainer.coreLogURL
    if SharedContainer.hasSharedAppGroup {
      result(SharedContainer.readTailText(url: localURL, maxBytes: 256 * 1024))
      return
    }
    guard let session = activeManager?.connection as? NETunnelProviderSession,
          session.status == .connected,
          let data = try? JSONSerialization.data(withJSONObject: ["cmd": "logs", "kind": kind]) else {
      result(SharedContainer.readTailText(url: localURL, maxBytes: 256 * 1024))
      return
    }
    do {
      try session.sendProviderMessage(data) { reply in
        DispatchQueue.main.async {
          if let reply = reply,
             let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
             let text = json["text"] as? String, !text.isEmpty {
            result(text)
          } else {
            result(SharedContainer.readTailText(url: localURL, maxBytes: 256 * 1024))
          }
        }
      }
    } catch {
      result(SharedContainer.readTailText(url: localURL, maxBytes: 256 * 1024))
    }
  }

  /// Syncs a user-downloaded full `geoip.dat` (23+ MB) into the extension sandbox
  /// in 512 KB chunks when running under a wildcard cert without a shared App Group.
  private func syncGeoToExtensionIfNeeded(restartAfter: Bool, completion: ((Bool) -> Void)?) {
    if SharedContainer.hasSharedAppGroup {
      completion?(true)
      return
    }
    if geoSyncInFlight {
      completion?(false)
      return
    }
    guard let session = activeManager?.connection as? NETunnelProviderSession,
          session.status == .connected else {
      completion?(false)
      return
    }
    let localURL = SharedContainer.geoipURL
    let localSize = SharedContainer.fileSize(at: localURL)
    // Bundled geoip-lite.dat (~0.6 MB) is already extracted directly by the extension.
    if localSize < 2 * 1024 * 1024 {
      completion?(true)
      return
    }
    guard let infoPayload = try? JSONSerialization.data(withJSONObject: ["cmd": "geoInfo"]) else {
      completion?(false)
      return
    }

    geoSyncInFlight = true
    do {
      try session.sendProviderMessage(infoPayload) { [weak self] reply in
        guard let self = self else { return }
        let extSize = (reply.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["size"] as? Int ?? 0
        if extSize == localSize {
          DispatchQueue.main.async {
            self.geoSyncInFlight = false
            completion?(true)
          }
          return
        }
        DispatchQueue.global(qos: .utility).async {
          self.streamGeoFile(localURL: localURL, totalSize: localSize, session: session, restartAfter: restartAfter) { ok in
            DispatchQueue.main.async {
              self.geoSyncInFlight = false
              completion?(ok)
            }
          }
        }
      }
    } catch {
      geoSyncInFlight = false
      completion?(false)
    }
  }

  private func streamGeoFile(
    localURL: URL,
    totalSize: Int,
    session: NETunnelProviderSession,
    restartAfter: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    guard let handle = try? FileHandle(forReadingFrom: localURL) else {
      completion(false)
      return
    }
    defer { try? handle.close() }

    let chunkSize = 512 * 1024
    var offset = 0

    while offset < totalSize {
      let chunk: Data = autoreleasepool {
        (try? handle.read(upToCount: chunkSize)) ?? Data()
      }
      if chunk.isEmpty { break }
      let nextOffset = offset + chunk.count
      let done = nextOffset >= totalSize
      let payloadObj: [String: Any] = [
        "cmd": "geoChunk",
        "offset": offset,
        "totalSize": totalSize,
        "done": done,
        "data": chunk.base64EncodedString(),
      ]
      guard let payload = try? JSONSerialization.data(withJSONObject: payloadObj) else {
        completion(false)
        return
      }

      let sem = DispatchSemaphore(value: 0)
      var chunkOk = false
      do {
        try session.sendProviderMessage(payload) { reply in
          if let reply = reply,
             let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
             let ok = json["ok"] as? Bool {
            chunkOk = ok
          }
          sem.signal()
        }
      } catch {
        completion(false)
        return
      }
      if sem.wait(timeout: .now() + 10) == .timedOut || !chunkOk {
        completion(false)
        return
      }
      offset = nextOffset
    }

    if restartAfter,
       let restartPayload = try? JSONSerialization.data(withJSONObject: ["cmd": "restartCore"]) {
      let sem = DispatchSemaphore(value: 0)
      try? session.sendProviderMessage(restartPayload) { _ in sem.signal() }
      _ = sem.wait(timeout: .now() + 10)
    }
    completion(true)
  }

  private func fetchCoreVersions() -> [String: String] {
    guard let ptr = KeqCoreGetVersions() else { return [:] }
    let raw = String(cString: ptr)
    KeqCoreFreeString(ptr)
    guard let data = raw.data(using: .utf8),
          let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
      return [:]
    }
    return parsed
  }

  private func hardwareModelIdentifier() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    return withUnsafePointer(to: &sysinfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(validatingUTF8: $0) ?? UIDevice.current.model
      }
    }
  }

  private func extractLogLevel(engine: String, configContent: String) -> String {
    guard let data = configContent.data(using: .utf8),
          let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return "warning"
    }
    if engine == "mihomo" {
      return (doc["log-level"] as? String) ?? "warning"
    }
    if let logObj = doc["log"] as? [String: Any],
       let level = logObj["loglevel"] as? String {
      return level
    }
    return "warning"
  }

  private func extractMtu(configContent: String) -> Int {
    guard let data = configContent.data(using: .utf8),
          let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return 1400
    }
    if let tun = doc["tun"] as? [String: Any], let mtu = tun["mtu"] as? Int, mtu >= 1280 {
      return mtu
    }
    if let inbounds = doc["inbounds"] as? [[String: Any]] {
      for inbound in inbounds {
        if (inbound["protocol"] as? String) == "tun",
           let settings = inbound["settings"] as? [String: Any],
           let mtu = settings["MTU"] as? Int, mtu >= 1280 {
          return mtu
        }
      }
    }
    return 1400
  }

  private func configHasIPv6Tun(engine: String, configContent: String) -> Bool {
    guard let data = configContent.data(using: .utf8),
          let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return false
    }
    if engine == "mihomo" {
      if let tun = doc["tun"] as? [String: Any], let ipv6 = tun["ipv6"] as? Bool {
        return ipv6
      }
      return (doc["ipv6"] as? Bool) ?? false
    }
    if let inbounds = doc["inbounds"] as? [[String: Any]] {
      for inbound in inbounds {
        if (inbound["protocol"] as? String) == "tun",
           let settings = inbound["settings"] as? [String: Any],
           let ip = settings["ip"] as? [String] {
          return ip.contains { $0.contains(":") }
        }
      }
    }
    return false
  }

  private func extractMihomoApi(configContent: String) -> (Int, String) {
    guard let data = configContent.data(using: .utf8),
          let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return (0, "")
    }
    let controller = doc["external-controller"] as? String ?? ""
    let secret = doc["secret"] as? String ?? ""
    guard let colon = controller.lastIndex(of: ":"),
          let port = Int(controller[controller.index(after: colon)...]) else {
      return (0, "")
    }
    return (port, secret)
  }
}
