import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/ink/velocity_tracker.dart';

void main() {
  test('首點速度為 0，壓感為 1', () {
    final t = VelocityTracker();
    final v = t.add(const Offset(0, 0), Duration.zero);
    expect(v, 0);
    expect(speedToPressure(v, 1800), 1.0);
  });

  test('快速→壓感小，慢速→壓感大（smoothstep）', () {
    expect(speedToPressure(0, 1800), 1.0);
    expect(speedToPressure(1800, 1800), closeTo(0.0, 1e-9));
    expect(speedToPressure(3600, 1800), closeTo(0.0, 1e-9));
    final slow = speedToPressure(200, 1800); // t≈0.111
    final fast = speedToPressure(1500, 1800); // t≈0.833
    expect(slow, greaterThan(fast));
    expect(slow, greaterThan(0.9));
    expect(fast, lessThan(0.3));
  });

  test('EMA 平滑：emaWeight 越大對新速度反應越慢', () {
    final fast = VelocityTracker(emaWeight: 0.9);
    final slow = VelocityTracker(emaWeight: 0.0);
    final p0 = const Offset(0, 0);
    const t0 = Duration.zero;
    fast.add(p0, t0);
    slow.add(p0, t0);
    // 1000px/s 的一步
    const p1 = Offset(10, 0);
    const t1 = Duration(milliseconds: 10);
    final vf = fast.add(p1, t1);
    final vs = slow.add(p1, t1);
    expect(vs, closeTo(1000, 1e-6));
    expect(vf, closeTo(100, 1e-6)); // 0*0.9 + 1000*0.1
  });

  test('dt<=1ms 被忽略（事件批量上報保護）', () {
    final t = VelocityTracker(emaWeight: 0);
    t.add(const Offset(0, 0), Duration.zero);
    t.add(const Offset(1000, 0), const Duration(microseconds: 500));
    expect(t.value, 0);
  });

  test('reset 清零', () {
    final t = VelocityTracker();
    t.add(const Offset(0, 0), Duration.zero);
    t.add(const Offset(10, 0), const Duration(milliseconds: 10));
    t.reset();
    expect(t.value, 0);
    expect(t.add(const Offset(5, 5), const Duration(milliseconds: 30)), 0);
  });
}
