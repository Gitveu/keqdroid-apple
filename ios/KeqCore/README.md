# KeqCore (iOS Go bridge)

In-process Go bridge combining the patched `xray-core` and `mihomo` cores into a single dynamic `KeqCore.xcframework` shared by `Runner` and `PacketTunnelExtension`.

The compiled `ios/Frameworks/KeqCore.xcframework` is not committed to git. Build it locally before building or packaging the iOS app:

```bash
bash tool/build_ios_core.sh           # device slice (ios-arm64)
bash tool/build_ios_core.sh simulator # simulator slice (host arch)
bash tool/build_ios_core.sh all       # both device and simulator slices
```
