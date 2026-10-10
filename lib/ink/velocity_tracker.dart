import 'dart:ui' show Offset;

/// 速度追蹤（EMA 平滑）。時間戳必須用手寫事件的 `event.timeStamp`，
/// 禁止 `DateTime.now()`（事件批量上報會導致速度計算失真）。
class VelocityTracker {
  Offset? _lastPos;
  Duration? _lastTime;
  double _ema = 0;

  /// 規格預設：maxSpeed 由調參面板持有，此處僅做 EMA。
  double emaWeight;

  VelocityTracker({this.emaWeight = 0.6});

  double get value => _ema;

  double add(Offset pos, Duration t) {
    if (_lastPos != null) {
      final dt = (t - _lastTime!).inMicroseconds / 1e6;
      if (dt > 0.001) {
        final speed = (pos - _lastPos!).distance / dt;
        _ema = _ema * emaWeight + speed * (1 - emaWeight);
      }
    }
    _lastPos = pos;
    _lastTime = t;
    return _ema;
  }

  void reset() {
    _lastPos = null;
    _lastTime = null;
    _ema = 0;
  }
}

/// 速度→壓感映射（smoothstep）：快=細（p 小），慢=粗（p 大）。
/// pressure = 1.0 - t*t*(3-2*t)，t = (speed/maxSpeed).clamp(0,1)
double speedToPressure(double speed, double maxSpeed) {
  final t = (speed / maxSpeed).clamp(0.0, 1.0);
  return 1.0 - t * t * (3 - 2 * t);
}

/// 可調手感參數（調參面板 + perDeviceProfile 共用）。
class StrokeParams {
  double maxSpeed;
  double emaWeight;
  double thinning;
  double streamline;
  double size;

  StrokeParams({
    this.maxSpeed = 1200.0,
    this.emaWeight = 0.6,
    this.thinning = 0.7,
    this.streamline = 0.5,
    this.size = 4.0,
  });

  StrokeParams copy() => StrokeParams(
        maxSpeed: maxSpeed,
        emaWeight: emaWeight,
        thinning: thinning,
        streamline: streamline,
        size: size,
      );

  Map<String, dynamic> toJson() => {
        'maxSpeed': maxSpeed,
        'emaWeight': emaWeight,
        'thinning': thinning,
        'streamline': streamline,
        'size': size,
      };

  factory StrokeParams.fromJson(Map<String, dynamic> json) => StrokeParams(
        maxSpeed: (json['maxSpeed'] as num?)?.toDouble() ?? 1200.0,
        emaWeight: (json['emaWeight'] as num?)?.toDouble() ?? 0.6,
        thinning: (json['thinning'] as num?)?.toDouble() ?? 0.7,
        streamline: (json['streamline'] as num?)?.toDouble() ?? 0.5,
        size: (json['size'] as num?)?.toDouble() ?? 4.0,
      );
}
