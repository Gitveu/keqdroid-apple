import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/core/exceptions.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/ios_tunnel_backend.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('keqdroid_vpn_channel');
  late IosTunnelBackend backend;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    backend = IosTunnelBackend();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    backend.dispose();
  });

  test('fetchSocksCredentials returns native credentials', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getSocksCredentials') {
            return {'username': 'u1', 'password': 'p1'};
          }
          return null;
        });

    final creds = await backend.fetchSocksCredentials();
    expect(creds.username, 'u1');
    expect(creds.password, 'p1');
    expect(calls.single.method, 'getSocksCredentials');
  });

  test('startSession forwards engine, configs and serverName', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });

    await backend.startSession(
      const TunnelSessionRequest(
        mode: ConnectionMode.tun,
        vpnBackend: VpnBackend.mihomo,
        xrayConfig: '{}',
        mihomoConfig: '{"tun":{"enable":true}}',
        socksPort: 2080,
        serverName: 'DE-1',
      ),
    );

    expect(calls.single.method, 'startVpn');
    final args = Map<Object?, Object?>.from(calls.single.arguments as Map);
    expect(args['vpnBackend'], 'mihomo');
    expect(args['mihomoConfig'], '{"tun":{"enable":true}}');
    expect(args['serverName'], 'DE-1');
    expect(args['tunnelMode'], 'tun');
  });

  test('requestTunnelPermission maps PERMISSION_DENIED exception', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'PERMISSION_DENIED', message: 'denied');
        });

    await expectLater(
      backend.requestTunnelPermission(),
      throwsA(isA<VpnPermissionDeniedException>()),
    );
  });

  test('getCurrentState parses status and traffic telemetry', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return {
            'status': 'CONNECTED',
            'downloadSpeed': 1024,
            'uploadSpeed': 512,
            'totalDownload': 4096,
            'totalUpload': 2048,
            'durationSeconds': 90,
            'connectionMode': 'tun',
          };
        });

    final state = await backend.getCurrentState();
    expect(state.status, VpnStatus.connected);
    expect(state.downloadSpeed, 1024);
    expect(state.uploadSpeed, 512);
    expect(state.totalDownload, 4096);
    expect(state.totalUpload, 2048);
    expect(state.duration, const Duration(seconds: 90));
    expect(state.activeMode, ConnectionMode.tun);
  });

  test('xrayUrlTestMulti parses results and invokes onEach callback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'xrayUrlTestMulti') {
            return [
              {'id': 's1', 'success': true, 'latencyMs': 42},
              {'id': 's2', 'success': false, 'latencyMs': null, 'error': 'timeout'},
            ];
          }
          return null;
        });

    final seen = <String>[];
    final res = await backend.xrayUrlTestMulti(
      config: '{}',
      probes: const [('s1', 20001), ('s2', 20002)],
      onEach: (r) => seen.add(r.id),
    );

    expect(res, isNotNull);
    expect(res!.length, 2);
    expect(res[0].success, isTrue);
    expect(res[0].latencyMs, 42);
    expect(res[1].success, isFalse);
    expect(seen, ['s1', 's2']);
  });

  test('getInstalledApps returns empty list on iOS', () async {
    expect(await backend.getInstalledApps(), isEmpty);
  });
}
