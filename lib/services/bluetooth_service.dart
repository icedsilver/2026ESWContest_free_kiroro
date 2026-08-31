import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import '../models/waypoint.dart';

/// 외부 보조기기(블루투스)와의 연결/전송을 전담하는 서비스.
class BluetoothService {
  BluetoothConnection? _connection;
  bool _connected = false;

  bool get isConnected => _connection != null && _connected;

  Future<List<BluetoothDevice>> getBondedDevices() {
    return FlutterBluetoothSerial.instance.getBondedDevices();
  }

  /// 기기에 연결하고 표시용 이름을 반환한다.
  Future<String> connect(BluetoothDevice device) async {
    _connection = await BluetoothConnection.toAddress(device.address);
    _connected = true;
    return device.name ?? '알 수 없는 기기';
  }

  void sendTurnType(String turnType) {
    if (_connection == null || !_connected) return;
    try {
      final code = BtCode.fromTurnType(turnType);
      _connection!.output.add(Uint8List.fromList([code]));
    } catch (_) {
      // 단발성 전송 실패는 다음 안내 시점에 자연히 재시도되므로 무시
    }
  }

  void dispose() {
    _connection?.dispose();
  }
}