const Map<int, String> kFaultCodes = {
  0: 'No Fault',
  1: 'TCU Failure',
  2: 'Gear Position Sensor Failure',
  3: 'Magnetic Encoder Failure',
  4: 'Shift Motor Failure',
  5: 'Accelerator Pedal Sensor Failure',
  6: 'Brake Sensor Failure',
  7: 'MCU Failure',
  8: 'Motor / MCU Overheating',
};

const double kSpeedDivisor = 86.975;

class InstrumentData {
  final double voltage;
  final double current;
  final double speedKmh;
  final int shaftRpm;
  final String gear;
  final bool throttleConf;
  final bool brakeSignal;
  final bool brakeConf;
  final bool cruiseCtrl;
  final bool handbrake;
  final int faultCode;
  final String faultDesc;

  const InstrumentData({
    required this.voltage,
    required this.current,
    required this.speedKmh,
    required this.shaftRpm,
    required this.gear,
    required this.throttleConf,
    required this.brakeSignal,
    required this.brakeConf,
    required this.cruiseCtrl,
    required this.handbrake,
    required this.faultCode,
    required this.faultDesc,
  });
}

class FaultDisplayData {
  final double v12;
  final int throttle;
  final int gearPos;
  final int magCode;
  final int motorTemp;
  final int mcuTemp;
  final double v4096;
  final double v5;

  const FaultDisplayData({
    required this.v12,
    required this.throttle,
    required this.gearPos,
    required this.magCode,
    required this.motorTemp,
    required this.mcuTemp,
    required this.v4096,
    required this.v5,
  });
}

/// CAN ID 0x0D259CD0 — Instrument display (8 bytes, little-endian)
InstrumentData decodeInstrument(List<int> data) {
  final voltageRaw = data[0] | (data[1] << 8);
  final voltage = voltageRaw * 0.1;

  final currentRaw = data[2] | (data[3] << 8);
  final current = currentRaw * 0.1 - 1000.0; // center at raw=10000 → 0 A

  final shaftRaw = data[4] | (data[5] << 8);
  final shaftRpm = shaftRaw - 10000;
  final speedKmh = shaftRpm.abs() / kSpeedDivisor;

  final flags = data[6];
  final gear = (flags & 0x01) != 0
      ? 'D'
      : ((flags & 0x02) != 0 ? 'R' : 'N');

  final faultCode = data[7];

  return InstrumentData(
    voltage: voltage,
    current: current,
    speedKmh: speedKmh,
    shaftRpm: shaftRpm,
    gear: gear,
    throttleConf: (flags & 0x04) == 0, // active-low
    brakeSignal: (flags & 0x08) != 0,
    brakeConf: (flags & 0x10) != 0,
    cruiseCtrl: (flags & 0x20) != 0,
    handbrake: (flags & 0x40) != 0,
    faultCode: faultCode,
    faultDesc: kFaultCodes[faultCode] ?? 'Reserved ($faultCode)',
  );
}

/// CAN ID 0x0D259CE7 — Fault display (8 bytes, little-endian)
FaultDisplayData decodeFaultDisplay(List<int> data) {
  return FaultDisplayData(
    v12: data[0] * 5 * 0.024,
    throttle: data[1] * 6,
    gearPos: data[2] * 5,
    magCode: data[3] * 128,
    motorTemp: data[4] * 2 - 128,
    mcuTemp: data[5] * 2 - 128,
    v4096: data[6] * 5 * 0.012011,
    v5: data[7] * 2 * 0.012,
  );
}
