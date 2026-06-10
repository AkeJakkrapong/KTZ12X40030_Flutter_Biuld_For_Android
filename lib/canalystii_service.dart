import 'dart:async';
import 'package:flutter/services.dart';
import 'slcan_service.dart';

class CanDevice {
  final String name;
  final dynamic _raw; // UsbDevice for serial, int (deviceId) for CANalyst-II

  bool get isCanalystii => _raw is int;

  dynamic get serialDevice => isCanalystii ? null : _raw;
  int? get canalystiiId => isCanalystii ? _raw as int : null;

  CanDevice.serial(dynamic usbDevice)
      : name = (usbDevice.productName as String?) ??
            (usbDevice.deviceName as String?) ??
            'Device ${usbDevice.deviceId}',
        _raw = usbDevice;

  CanDevice.canalystii(int deviceId, String deviceName)
      : name = deviceName,
        _raw = deviceId;

  @override
  bool operator ==(Object other) =>
      other is CanDevice && other._raw == _raw;

  @override
  int get hashCode => _raw.hashCode;
}

class CanalystiiService {
  static const _methods = MethodChannel('canalystii/methods');
  static const _frames = EventChannel('canalystii/frames');

  final _frameController = StreamController<CanFrame>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  StreamSubscription? _frameSub;

  Stream<CanFrame> get frameStream => _frameController.stream;
  Stream<String> get statusStream => _statusController.stream;

  Future<List<CanDevice>> listDevices() async {
    try {
      final List raw = await _methods.invokeMethod('listDevices');
      return raw
          .map((d) => CanDevice.canalystii(d['deviceId'] as int, d['name'] as String))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> connect(CanDevice device) async {
    try {
      final ok = await _methods.invokeMethod<bool>(
        'connect',
        {'deviceId': device.canalystiiId},
      );
      if (ok == true) {
        _frameSub = _frames.receiveBroadcastStream().listen(
          (raw) {
            try {
              final m = Map<String, dynamic>.from(raw as Map);
              if (m.containsKey('_status')) {
                _statusController.add(m['_status'] as String);
                return;
              }
              _frameController.add(CanFrame(
                id: (m['id'] as num).toInt(),
                isExtended: m['extended'] == true,
                data: (m['data'] as List).map((e) => (e as num).toInt()).toList(),
              ));
            } catch (e) {
              _statusController.add('frame_err: $e');
            }
          },
          onError: (e) => _statusController.add('stream_err: $e'),
        );
        _statusController.add('Connected (CANalyst-II): ${device.name}');
        return true;
      }
      return false;
    } catch (e) {
      _statusController.add('Error: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    await _frameSub?.cancel();
    _frameSub = null;
    try {
      await _methods.invokeMethod('disconnect');
    } catch (_) {}
    _statusController.add('Disconnected');
  }

  void dispose() {
    disconnect();
    _frameController.close();
    _statusController.close();
  }
}
