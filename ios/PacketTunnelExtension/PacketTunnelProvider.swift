import Foundation
import KeqCore
import NetworkExtension

private let kSysprotoControl: Int32 = 2
private let kUtunOptIfname: Int32 = 2

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private var pathObserver: NSKeyValueObservation?
  private var lastPathStatus: NWPathStatus = .invalid
  private var networkChangesCount: Int = 0
  private var activeEngine: String = "xray"

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    // Stay safely inside iOS 15+ NetworkExtension's 50 MB Jetsam memory ceiling.
    KeqCoreInitMemory(36 * 1024 * 1024, 15)

    let proto = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    let meta = SharedContainer.readSessionMeta()

    let engine = (proto["engine"] as? String)
      ?? (meta["engine"] as? String)
      ?? "xray"
    let logLevel = (proto["logLevel"] as? String)
      ?? (meta["logLevel"] as? String)
      ?? "warning"
    let mtu = (proto["mtu"] as? Int)
      ?? (meta["mtu"] as? Int)
      ?? 1400
    let enableIPv6 = (proto["ipv6"] as? Bool)
      ?? (meta["ipv6"] as? Bool)
      ?? false

    let configURL = SharedContainer.configURL(for: engine)
    if let inlineConfig = proto["configContent"] as? String, !inlineConfig.isEmpty {
      do {
        try inlineConfig.write(to: configURL, atomically: true, encoding: .utf8)
      } catch {
        SharedContainer.appendNativeLog("PacketTunnel: failed to write config: \(error)")
        completionHandler(error)
        return
      }
    }

    guard FileManager.default.fileExists(atPath: configURL.path) else {
      let err = NSError(
        domain: "com.keqdroid.PacketTunnel",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Missing tunnel config at \(configURL.path)"]
      )
      SharedContainer.appendNativeLog("PacketTunnel: \(err.localizedDescription)")
      completionHandler(err)
      return
    }

    let settings = buildNetworkSettings(mtu: mtu, enableIPv6: enableIPv6)
    SharedContainer.appendNativeLog("PacketTunnel: applying network settings (engine=\(engine), mtu=\(mtu), ipv6=\(enableIPv6))")

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        SharedContainer.appendNativeLog("PacketTunnel: setTunnelNetworkSettings failed: \(error)")
        completionHandler(error)
        return
      }

      guard let tunFd = self.findTunFileDescriptor(), tunFd >= 0 else {
        let err = NSError(
          domain: "com.keqdroid.PacketTunnel",
          code: 1002,
          userInfo: [NSLocalizedDescriptionKey: "Could not locate utun file descriptor"]
        )
        SharedContainer.appendNativeLog("PacketTunnel: \(err.localizedDescription)")
        completionHandler(err)
        return
      }

      let dataDir = SharedContainer.containerURL.path
      let logPath = SharedContainer.coreLogURL.path
      SharedContainer.appendNativeLog("PacketTunnel: starting \(engine) on utun fd=\(tunFd)")

      let errPtr: UnsafeMutablePointer<CChar>? = SharedContainer.withCString(engine) { engineC in
        SharedContainer.withCString(configURL.path) { cfgC in
          SharedContainer.withCString(dataDir) { dataC in
            SharedContainer.withCString(logLevel) { lvlC in
              SharedContainer.withCString(logPath) { logC in
                KeqCoreStart(engineC, cfgC, dataC, tunFd, lvlC, logC)
              }
            }
          }
        }
      }
      if let errPtr = errPtr {
        let message = String(cString: errPtr)
        KeqCoreFreeString(errPtr)
        SharedContainer.appendNativeLog("PacketTunnel: KeqCoreStart failed: \(message)")
        let err = NSError(
          domain: "com.keqdroid.PacketTunnel",
          code: 1003,
          userInfo: [NSLocalizedDescriptionKey: message]
        )
        completionHandler(err)
        return
      }

      self.activeEngine = engine
      self.startPathObserver()
      SharedContainer.appendNativeLog("PacketTunnel: \(engine) started successfully")
      completionHandler(nil)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    SharedContainer.appendNativeLog("PacketTunnel: stopping tunnel (reason=\(reason.rawValue))")
    pathObserver?.invalidate()
    pathObserver = nil
    KeqCoreStop()
    completionHandler()
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    guard let json = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any],
          let cmd = json["cmd"] as? String else {
      completionHandler?(nil)
      return
    }

    switch cmd {
    case "stats":
      var rx: Int64 = 0
      var tx: Int64 = 0
      var dialFailures: Int64 = 0
      KeqCoreGetStats(&rx, &tx, &dialFailures)
      let running = KeqCoreIsRunning() != 0
      let reply: [String: Any] = [
        "rx": rx,
        "tx": tx,
        "dialFailures": dialFailures,
        "running": running,
        "networkChanges": networkChangesCount,
        "pathSatisfied": defaultPath?.status == .satisfied,
      ]
      let data = try? JSONSerialization.data(withJSONObject: reply)
      completionHandler?(data)

    case "reloadMihomo":
      let configURL = SharedContainer.configURL(for: "mihomo")
      if let inlineConfig = json["configContent"] as? String, !inlineConfig.isEmpty {
        try? inlineConfig.write(to: configURL, atomically: true, encoding: .utf8)
      }
      let errPtr = SharedContainer.withCString(configURL.path) { cfgC in
        KeqCoreReloadMihomo(cfgC)
      }
      var reply: [String: Any] = ["ok": errPtr == nil]
      if let errPtr = errPtr {
        reply["error"] = String(cString: errPtr)
        KeqCoreFreeString(errPtr)
      }
      let data = try? JSONSerialization.data(withJSONObject: reply)
      completionHandler?(data)

    default:
      completionHandler?(nil)
    }
  }

  private func startPathObserver() {
    lastPathStatus = defaultPath?.status ?? .invalid
    pathObserver = observe(\.defaultPath, options: [.new]) { [weak self] provider, _ in
      guard let self = self else { return }
      let status = provider.defaultPath?.status ?? .invalid
      if status != self.lastPathStatus {
        self.lastPathStatus = status
        self.networkChangesCount += 1
        if status == .satisfied {
          SharedContainer.appendNativeLog("PacketTunnel: physical network changed, resetting connections")
          KeqCoreResetConnections()
        }
      }
    }
  }

  private func buildNetworkSettings(mtu: Int, enableIPv6: Bool) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = NSNumber(value: mtu)

    let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    ipv4.excludedRoutes = [
      NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
      NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
    ]
    settings.ipv4Settings = ipv4

    if enableIPv6 {
      let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
      ipv6.includedRoutes = [NEIPv6Route.default()]
      settings.ipv6Settings = ipv6
    }

    let dns = NEDNSSettings(servers: ["172.19.0.2"])
    dns.matchDomains = [""]
    settings.dnsSettings = dns
    return settings
  }

  private func findTunFileDescriptor() -> Int32? {
    if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, fd >= 0 {
      return fd
    }
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    for fd: Int32 in 3..<1024 {
      var len = socklen_t(buf.count)
      let rc = getsockopt(fd, kSysprotoControl, kUtunOptIfname, &buf, &len)
      if rc == 0 {
        let name = String(cString: buf)
        if name.hasPrefix("utun") {
          return fd
        }
      }
    }
    return nil
  }
}
