import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';
import 'decoder.dart';
import 'slcan_service.dart';
import 'canalystii_service.dart';

// Colour palette — supercar display
const _cBg     = Color(0xFF080808);  // carbon black
const _cCard   = Color(0xFF0F0F0F);  // dark carbon panel
const _cBorder = Color(0xFF1E1E1E);  // carbon edge
const _cFg     = Color(0xFFF0EEE8);  // warm ivory white
const _cMuted  = Color(0xFF666666);  // platinum gray
const _cAccent = Color(0xFFC9A227);  // champagne gold
const _cValue  = Color(0xFFFFFFFF);  // pure white readout
const _cOk     = Color(0xFF00C896);  // teal green
const _cWarn   = Color(0xFFF0A500);  // deep amber
const _cErr    = Color(0xFFFF3B30);  // racing red
const _cOff    = Color(0xFF1A1A1A);  // inactive

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KTZ12X40030',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _cBg,
        colorScheme: const ColorScheme.dark(
          primary: _cAccent,
          surface: _cCard,
        ),
        dividerColor: _cBorder,
      ),
      home: const MonitorScreen(),
    );
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  final _slcan = SlcanService();
  final _canalystii = CanalystiiService();
  StreamSubscription? _frameSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _frameSub2;
  StreamSubscription? _statusSub2;
  StreamSubscription? _usbSub;

  List<CanDevice> _devices = [];
  CanDevice? _selectedDevice;
  bool _isConnected = false;
  String _status = 'Not connected';
  ProtocolMode _protocol = ProtocolMode.slcan;

  InstrumentData? _instrument;
  FaultDisplayData? _faultDisplay;

  // raw frames: ordered insertion; cd0 and ce7 are shown first
  final _rawFrames = <String, _RawFrame>{};

  @override
  void initState() {
    super.initState();
    _refreshDevices();
    _statusSub = _slcan.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _frameSub = _slcan.frameStream.listen(_onFrame);
    _statusSub2 = _canalystii.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _frameSub2 = _canalystii.frameStream.listen(_onFrame);
    _usbSub = UsbSerial.usbEventStream?.listen((_) => _refreshDevices());
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _statusSub?.cancel();
    _frameSub2?.cancel();
    _statusSub2?.cancel();
    _usbSub?.cancel();
    _slcan.dispose();
    _canalystii.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    final serialDevices = await UsbSerial.listDevices();
    final canalystiiDevices = await _canalystii.listDevices();
    if (!mounted) return;
    final devices = [
      // Exclude CANalyst-II (VID 0x04D8) — handled as raw USB by CanalystiiService
      ...serialDevices.where((d) => d.vid != 0x04D8).map((d) => CanDevice.serial(d)),
      ...canalystiiDevices,
    ];
    setState(() {
      _devices = devices;
      if (_selectedDevice != null &&
          !devices.any((d) => d == _selectedDevice)) {
        _selectedDevice = null;
      }
      _selectedDevice ??= devices.isNotEmpty ? devices.first : null;
    });
  }

  Future<void> _connect() async {
    if (_selectedDevice == null) return;
    setState(() => _status = 'Connecting…');
    try {
      final device = _selectedDevice!;
      final bool ok;
      if (device.isCanalystii) {
        ok = await _canalystii.connect(device);
      } else {
        ok = await _slcan.connect(device.serialDevice, mode: _protocol);
      }
      if (mounted) setState(() {
        _isConnected = ok;
        if (!ok) _status = 'Connection failed';
      });
    } catch (e) {
      if (mounted) setState(() {
        _isConnected = false;
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _disconnect() async {
    if (_selectedDevice?.isCanalystii == true) {
      await _canalystii.disconnect();
    } else {
      await _slcan.disconnect();
    }
    if (mounted) {
      setState(() {
        _isConnected = false;
        _instrument = null;
        _faultDisplay = null;
      });
    }
  }

  void _onFrame(CanFrame frame) {
    if (!mounted) return;
    final idStr = '0x${frame.id.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    setState(() {
      if (frame.id == 0x0D259CD0 && frame.data.length >= 8) {
        _instrument = decodeInstrument(frame.data);
      } else if (frame.id == 0x0D259CE7 && frame.data.length >= 8) {
        _faultDisplay = decodeFaultDisplay(frame.data);
      }
      final now = DateTime.now();
      final existing = _rawFrames[idStr];
      final cycleMs = existing != null
          ? now.difference(existing.lastTime).inMilliseconds
          : null;
      _rawFrames[idStr] = _RawFrame(
        id: idStr,
        data: frame.data,
        count: (existing?.count ?? 0) + 1,
        cycleMs: cycleMs,
        lastTime: now,
      );
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cBg,
      appBar: AppBar(
        backgroundColor: _cCard,
        title: const Text(
          'KTZ12X40030',
          style: TextStyle(
            color: _cAccent,
            fontWeight: FontWeight.w600,
            fontSize: 16,
            letterSpacing: 2.0,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _buildConnectionBar(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            _StatusBar(status: _status, connected: _isConnected),
            const SizedBox(height: 8),
            _buildMetricsGrid(),
            const SizedBox(height: 8),
            _buildSignalsCard(),
            const SizedBox(height: 8),
            _buildFaultDisplayCard(),
            const SizedBox(height: 8),
            _buildRawFramesCard(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 8),
      color: _cCard,
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<CanDevice>(
                value: _selectedDevice,
                hint: const Text('Select USB device',
                    style: TextStyle(color: _cMuted, fontSize: 13)),
                dropdownColor: _cCard,
                style: const TextStyle(color: _cFg, fontSize: 13),
                isExpanded: true,
                items: _devices
                    .map((d) => DropdownMenuItem(
                          value: d,
                          child: Text(
                            d.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: _isConnected
                    ? null
                    : (d) => setState(() => _selectedDevice = d),
              ),
            ),
          ),
          // Protocol toggle hidden for CANalyst-II (protocol is fixed)
          if (_selectedDevice?.isCanalystii != true)
          GestureDetector(
            onTap: _isConnected
                ? null
                : () => setState(() {
                      _protocol = _protocol == ProtocolMode.slcan
                          ? ProtocolMode.robotell
                          : _protocol == ProtocolMode.robotell
                              ? ProtocolMode.waveshare
                              : ProtocolMode.slcan;
                    }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _isConnected ? _cOff : _cBorder,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _protocol == ProtocolMode.slcan
                    ? 'CANable'
                    : _protocol == ProtocolMode.robotell
                        ? 'Robotell'
                        : 'Waveshare',
                style: TextStyle(
                  color: _isConnected ? _cMuted : _cAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _isConnected
              ? SizedBox(
                  height: 36,
                  child: ElevatedButton(
                    onPressed: _disconnect,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _cErr.withOpacity(0.25),
                        foregroundColor: _cErr,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: const TextStyle(fontSize: 13)),
                    child: const Text('Disconnect'),
                  ),
                )
              : SizedBox(
                  height: 36,
                  child: ElevatedButton(
                    onPressed: _selectedDevice != null ? _connect : null,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _cAccent.withOpacity(0.25),
                        foregroundColor: _cAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        textStyle: const TextStyle(fontSize: 13)),
                    child: const Text('Connect'),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildMetricsGrid() {
    final i = _instrument;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.05,
      children: [
        _MetricCard(
          label: 'VOLTAGE',
          unit: 'V',
          value: i?.voltage.toStringAsFixed(1) ?? '--.-',
        ),
        _MetricCard(
          label: 'CURRENT',
          unit: 'A',
          value: i?.current.toStringAsFixed(1) ?? '--.-',
        ),
        _MetricCard(
          label: 'SPEED',
          unit: 'km/h',
          value: i?.speedKmh.toStringAsFixed(1) ?? '--.-',
        ),
        _MetricCard(
          label: 'SHAFT RPM',
          unit: 'rpm',
          value: i?.shaftRpm.toString() ?? '----',
        ),
        _MetricCard(
          label: 'GEAR',
          unit: '',
          value: i?.gear ?? '-',
          valueColor: i?.gear == 'D'
              ? _cOk
              : (i?.gear == 'R' ? _cWarn : _cFg),
          valueFontSize: 34,
        ),
        _MetricCard(
          label: 'FAULT',
          unit: '',
          value: i == null ? '--' : '${i.faultCode}',
          valueColor: (i?.faultCode ?? 0) == 0 ? _cOk : _cErr,
          subtitle: i?.faultDesc,
        ),
      ],
    );
  }

  Widget _buildSignalsCard() {
    final i = _instrument;
    Widget cell(_SignalDot dot) => Expanded(child: Align(alignment: Alignment.centerLeft, child: dot));
    return _SectionCard(
      title: 'SIGNALS  (0x0D259CD0 byte 6)',
      child: Column(
        children: [
          Row(children: [
            cell(_SignalDot(label: 'THROTTLE CFM', active: i?.throttleConf ?? false)),
            cell(_SignalDot(label: 'BRAKE SIG',    active: i?.brakeSignal  ?? false)),
            cell(_SignalDot(label: 'BRAKE CFM',    active: i?.brakeConf    ?? false)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            cell(_SignalDot(label: 'CRUISE',    active: i?.cruiseCtrl ?? false)),
            cell(_SignalDot(label: 'HANDBRAKE', active: i?.handbrake  ?? false, activeColor: _cErr)),
            const Expanded(child: SizedBox()),
          ]),
        ],
      ),
    );
  }

  Widget _buildFaultDisplayCard() {
    final fd = _faultDisplay;
    Widget cell(_SmallMetric m) => Expanded(child: m);
    return _SectionCard(
      title: 'FAULT DISPLAY  (0x0D259CE7)',
      child: Column(
        children: [
          Row(children: [
            cell(_SmallMetric(
              label: 'MOTOR TEMP',
              value: fd == null ? '--' : '${fd.motorTemp} °C',
              color: fd != null && fd.motorTemp > 80 ? _cErr : (fd != null && fd.motorTemp > 60 ? _cWarn : _cFg),
            )),
            cell(_SmallMetric(
              label: 'MCU TEMP',
              value: fd == null ? '--' : '${fd.mcuTemp} °C',
              color: fd != null && fd.mcuTemp > 80 ? _cErr : (fd != null && fd.mcuTemp > 60 ? _cWarn : _cFg),
            )),
            cell(_SmallMetric(label: '12V RAIL',  value: fd == null ? '--' : '${fd.v12.toStringAsFixed(2)} V')),
            cell(_SmallMetric(label: 'THROTTLE',  value: fd == null ? '--' : '${fd.throttle}')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            cell(_SmallMetric(label: 'GEAR POS',   value: fd == null ? '--' : '${fd.gearPos}')),
            cell(_SmallMetric(label: 'MAG CODE',   value: fd == null ? '--' : '${fd.magCode}')),
            cell(_SmallMetric(label: '4.096V REF', value: fd == null ? '--' : '${fd.v4096.toStringAsFixed(3)} V')),
            cell(_SmallMetric(label: '5V SUPPLY',  value: fd == null ? '--' : '${fd.v5.toStringAsFixed(3)} V')),
          ]),
        ],
      ),
    );
  }

  Widget _buildRawFramesCard() {
    // Pinned order: cd0, ce7, then rest in insertion order
    final pinned = ['0x0D259CD0', '0x0D259CE7'];
    final ordered = [
      ...pinned.where(_rawFrames.containsKey).map((k) => _rawFrames[k]!),
      ..._rawFrames.entries
          .where((e) => !pinned.contains(e.key))
          .map((e) => e.value),
    ];

    return _SectionCard(
      title: 'RAW CAN FRAMES',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Expanded(
                  child: Text('CAN ID',
                      style: TextStyle(
                          color: _cMuted,
                          fontSize: 10,
                          letterSpacing: 0.8))),
              SizedBox(
                  width: 28,
                  child: Text('DLC',
                      style: TextStyle(color: _cMuted, fontSize: 10),
                      textAlign: TextAlign.right)),
              SizedBox(
                  width: 48,
                  child: Text('COUNT',
                      style: TextStyle(color: _cMuted, fontSize: 10),
                      textAlign: TextAlign.right)),
              SizedBox(
                  width: 68,
                  child: Text('CYCLE (ms)',
                      style: TextStyle(color: _cMuted, fontSize: 10),
                      textAlign: TextAlign.right)),
            ],
          ),
          const Divider(color: _cBorder, height: 8),
          if (ordered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No frames received',
                  style: TextStyle(color: _cMuted, fontSize: 13)),
            )
          else
            ...ordered.map((f) => _RawFrameRow(frame: f)),
        ],
      ),
    );
  }

}

// ── Data model ────────────────────────────────────────────────────────────────

class _RawFrame {
  final String id;
  final List<int> data;
  final int count;
  final int? cycleMs;
  final DateTime lastTime;
  _RawFrame({
    required this.id,
    required this.data,
    required this.count,
    this.cycleMs,
    DateTime? lastTime,
  }) : lastTime = lastTime ?? DateTime.now();
}

// ── Widgets ───────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final String status;
  final bool connected;
  const _StatusBar({required this.status, required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _cCard,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: connected ? _cOk.withOpacity(0.4) : _cBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? _cOk : _cMuted,
              boxShadow: connected
                  ? [BoxShadow(color: _cOk.withOpacity(0.5), blurRadius: 4)]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(status,
              style: TextStyle(
                  color: connected ? _cFg : _cMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String unit;
  final String value;
  final Color? valueColor;
  final double valueFontSize;
  final String? subtitle;

  const _MetricCard({
    required this.label,
    required this.unit,
    required this.value,
    this.valueColor,
    this.valueFontSize = 24,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final vColor = valueColor ?? _cValue;
    return Container(
      decoration: BoxDecoration(
        color: _cCard,
        borderRadius: BorderRadius.circular(3),
        border: Border(
          top:    const BorderSide(color: _cAccent, width: 1),
          left:   BorderSide(color: _cBorder),
          right:  BorderSide(color: _cBorder),
          bottom: BorderSide(color: _cBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: _cMuted, fontSize: 11, letterSpacing: 0.8)),
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              value,
                              style: TextStyle(
                                color: vColor,
                                fontSize: valueFontSize,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                shadows: [
                                  Shadow(color: vColor.withOpacity(0.7), blurRadius: 10),
                                ],
                              ),
                            ),
                          ),
                          if (unit.isNotEmpty)
                            Text(unit,
                                style: const TextStyle(
                                    color: _cMuted, fontSize: 10)),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitle!,
                                style: const TextStyle(color: _cMuted, fontSize: 9),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalDot extends StatelessWidget {
  final String label;
  final bool active;
  final Color activeColor;

  const _SignalDot({
    required this.label,
    required this.active,
    this.activeColor = _cOk,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? activeColor : _cOff,
            boxShadow: active
                ? [BoxShadow(color: activeColor.withOpacity(0.5), blurRadius: 5)]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: active ? _cFg : _cMuted, fontSize: 12)),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _cCard,
        borderRadius: BorderRadius.circular(4),
        border: Border(
          left:   const BorderSide(color: _cAccent, width: 3),
          top:    BorderSide(color: _cBorder),
          right:  BorderSide(color: _cBorder),
          bottom: BorderSide(color: _cBorder),
        ),
        boxShadow: [
          BoxShadow(color: _cErr.withOpacity(0.35), blurRadius: 8, spreadRadius: -1, offset: const Offset(-3, 0)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: _cAccent, fontSize: 11, letterSpacing: 1.0,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _SmallMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SmallMetric({
    required this.label,
    required this.value,
    this.color = _cFg,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: _cMuted, fontSize: 11, letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _RawFrameRow extends StatelessWidget {
  final _RawFrame frame;
  const _RawFrameRow({required this.frame});

  @override
  Widget build(BuildContext context) {
    final hex = frame.data
        .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line 1: CAN ID | DLC | COUNT | CYCLE
          Row(
            children: [
              Expanded(
                child: Text(frame.id,
                    style: const TextStyle(
                        color: _cAccent,
                        fontSize: 11,
                        fontFamily: 'monospace')),
              ),
              SizedBox(
                width: 28,
                child: Text('${frame.data.length}',
                    style: const TextStyle(color: _cFg, fontSize: 11),
                    textAlign: TextAlign.right),
              ),
              SizedBox(
                width: 48,
                child: Text('${frame.count}',
                    style: const TextStyle(color: _cMuted, fontSize: 11),
                    textAlign: TextAlign.right),
              ),
              SizedBox(
                width: 68,
                child: Text(
                  frame.cycleMs != null ? '${frame.cycleMs}' : '--',
                  style: TextStyle(
                    color: frame.cycleMs != null ? _cWarn : _cMuted,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          // Line 2: full DATA hex
          const SizedBox(height: 2),
          Text(
            hex,
            style: const TextStyle(
                color: _cFg, fontSize: 11, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
