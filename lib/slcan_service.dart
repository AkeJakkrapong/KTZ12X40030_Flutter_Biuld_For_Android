import 'dart:async';
import 'dart:typed_data';
import 'package:usb_serial/usb_serial.dart';

enum ProtocolMode { slcan, robotell, waveshare }

class CanFrame {
  final int id;
  final bool isExtended;
  final List<int> data;

  const CanFrame({
    required this.id,
    required this.isExtended,
    required this.data,
  });
}

class SlcanService {
  UsbPort? _port;
  final _frameController = StreamController<CanFrame>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _debugController = StreamController<String>.broadcast();

  String _partial = '';
  final _binBuf = <int>[];

  Stream<CanFrame> get frameStream => _frameController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<String> get debugStream => _debugController.stream;
  bool get isConnected => _port != null;

  Future<List<UsbDevice>> listDevices() => UsbSerial.listDevices();

  Future<bool> connect(
    UsbDevice device, {
    int serialBaud = 115200,
    ProtocolMode mode = ProtocolMode.slcan,
  }) async {
    await disconnect();
    _partial = '';
    _binBuf.clear();

    _port = await device.create();
    if (_port == null) return false;

    if (!await _port!.open()) {
      _port = null;
      return false;
    }

    await _port!.setDTR(false);
    await _port!.setRTS(false);

    final baud = mode == ProtocolMode.waveshare ? 2000000 : serialBaud;
    try {
      await _port!.setPortParameters(
        baud,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );
    } catch (_) {
      // CDC devices ignore baud rate — non-fatal
    }

    _port!.inputStream!.listen(
      (bytes) => _onData(bytes, mode),
      onError: (_) => disconnect(),
      onDone: () {
        _port = null;
        _statusController.add('Disconnected');
      },
    );

    if (mode == ProtocolMode.slcan) {
      // SLCAN init: close any open channel, set 250 kbps, open
      await _write('C\r');
      await Future.delayed(const Duration(milliseconds: 100));
      await _write('S5\r'); // 250 kbps
      await Future.delayed(const Duration(milliseconds: 100));
      await _write('O\r');
    } else if (mode == ProtocolMode.robotell) {
      // Robotell binary: set 250 kbps (0x05), normal mode (0x00)
      // Packet: AA 55 01 [speed] [mode] [checksum=(01+speed+mode)&0xFF]
      const speed = 0x05;
      const modeCode = 0x00;
      final ck = (0x01 + speed + modeCode) & 0xFF;
      await _writeBytes([0xAA, 0x55, 0x01, speed, modeCode, ck]);
    }
    // Waveshare: no init needed, settings stored in device EEPROM

    final label = mode == ProtocolMode.slcan
        ? 'SLCAN'
        : mode == ProtocolMode.robotell
            ? 'Robotell'
            : 'Waveshare';
    _statusController.add(
      'Connected ($label): ${device.productName ?? device.deviceName}',
    );
    return true;
  }

  Future<void> disconnect() async {
    if (_port == null) return;
    try {
      await _write('C\r');
      await Future.delayed(const Duration(milliseconds: 50));
      await _port!.close();
    } catch (_) {}
    _port = null;
    _partial = '';
    _binBuf.clear();
    _statusController.add('Disconnected');
  }

  Future<void> _write(String cmd) async {
    if (_port == null) return;
    try {
      await _port!.write(Uint8List.fromList(cmd.codeUnits));
    } catch (_) {}
  }

  Future<void> _writeBytes(List<int> bytes) async {
    if (_port == null) return;
    try {
      await _port!.write(Uint8List.fromList(bytes));
    } catch (_) {}
  }

  void _onData(Uint8List bytes, ProtocolMode mode) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    _debugController.add(hex);

    if (mode == ProtocolMode.robotell) {
      _onDataRobotell(bytes);
    } else if (mode == ProtocolMode.waveshare) {
      _onDataWaveshare(bytes);
    } else {
      _onDataSlcan(bytes);
    }
  }

  // ── SLCAN ASCII parser ─────────────────────────────────────────────────────

  void _onDataSlcan(Uint8List bytes) {
    _partial += String.fromCharCodes(bytes);
    // Normalize \r\n and bare \n so split('\r') works for all adapters
    _partial = _partial.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
    final lines = _partial.split('\r');
    _partial = lines.removeLast();
    for (final line in lines) {
      _parseSlcanLine(line.trim());
    }
  }

  void _parseSlcanLine(String line) {
    if (line.isEmpty) return;
    try {
      if (line.startsWith('T') && line.length >= 10) {
        // Extended 29-bit: T + 8-hex ID + 1-hex DLC + data bytes
        final id = int.parse(line.substring(1, 9), radix: 16);
        final dlc = int.parse(line.substring(9, 10), radix: 16);
        final hex = line.substring(10);
        if (hex.length < dlc * 2) return;
        final data = List.generate(
            dlc, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
        _frameController.add(CanFrame(id: id, isExtended: true, data: data));
      } else if (line.startsWith('t') && line.length >= 5) {
        // Standard 11-bit: t + 3-hex ID + 1-hex DLC + data bytes
        final id = int.parse(line.substring(1, 4), radix: 16);
        final dlc = int.parse(line.substring(4, 5), radix: 16);
        final hex = line.substring(5);
        if (hex.length < dlc * 2) return;
        final data = List.generate(
            dlc, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
        _frameController.add(CanFrame(id: id, isExtended: false, data: data));
      }
    } catch (_) {}
  }

  // ── Robotell binary parser ─────────────────────────────────────────────────
  // Fixed 21-byte frame (data always padded to 8 bytes):
  // [AA][AA] [ID:4 LE] [data:8] [DLC:1] [channel:1] [type:1] [reserved:1] [chk:1] [55][55]
  // type: 0x01 = extended 29-bit, 0x00 = standard 11-bit

  void _onDataRobotell(Uint8List bytes) {
    _binBuf.addAll(bytes);
    _parseBinaryBuffer();
  }

  void _parseBinaryBuffer() {
    const frameSize = 21;
    while (_binBuf.length >= frameSize) {
      if (_binBuf[0] != 0xAA || _binBuf[1] != 0xAA) {
        _binBuf.removeAt(0);
        continue;
      }
      if (_binBuf[19] != 0x55 || _binBuf[20] != 0x55) {
        _binBuf.removeAt(0);
        continue;
      }

      final id = _binBuf[2] |
          (_binBuf[3] << 8) |
          (_binBuf[4] << 16) |
          (_binBuf[5] << 24);

      final dlc = _binBuf[14];
      final isExtended = _binBuf[16] == 0x01;

      if (dlc <= 8) {
        final data = List<int>.from(_binBuf.sublist(6, 6 + dlc));
        _frameController.add(CanFrame(id: id, isExtended: isExtended, data: data));
      }

      _binBuf.removeRange(0, frameSize);
    }
  }

  // ── Waveshare binary parser ────────────────────────────────────────────────
  // Variable-length frame:
  // [AA] [ctrl] [ID: 2 or 4 bytes LE] [data: DLC bytes] [55]
  // ctrl: bit7-6=11, bit5=extended, bit4=remote, bit3-0=DLC
  // Standard (bit5=0): 2-byte ID → frame = 5 + DLC bytes
  // Extended (bit5=1): 4-byte ID → frame = 7 + DLC bytes

  void _onDataWaveshare(Uint8List bytes) {
    _binBuf.addAll(bytes);
    _parseWaveshareBuffer();
  }

  void _parseWaveshareBuffer() {
    while (_binBuf.length >= 5) {
      if (_binBuf[0] != 0xAA) {
        _binBuf.removeAt(0);
        continue;
      }

      final ctrl = _binBuf[1];
      final isExtended = (ctrl & 0x20) != 0;
      final dlc = ctrl & 0x0F;

      if (dlc > 8) {
        _binBuf.removeAt(0);
        continue;
      }

      final frameSize = isExtended ? 7 + dlc : 5 + dlc;
      if (_binBuf.length < frameSize) break;

      if (_binBuf[frameSize - 1] != 0x55) {
        _binBuf.removeAt(0);
        continue;
      }

      final int id;
      if (isExtended) {
        id = _binBuf[2] |
            (_binBuf[3] << 8) |
            (_binBuf[4] << 16) |
            (_binBuf[5] << 24);
      } else {
        id = _binBuf[2] | (_binBuf[3] << 8);
      }

      final dataOffset = isExtended ? 6 : 4;
      final data = List<int>.from(_binBuf.sublist(dataOffset, dataOffset + dlc));
      _frameController.add(CanFrame(id: id, isExtended: isExtended, data: data));

      _binBuf.removeRange(0, frameSize);
    }
  }

  void dispose() {
    disconnect();
    _frameController.close();
    _statusController.close();
    _debugController.close();
  }
}
