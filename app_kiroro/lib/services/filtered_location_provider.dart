import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';

/// 필터를 통과한 위치 1건.
class FilteredFix {
  /// 필터가 추정한 위치.
  final double lat;
  final double lon;

  /// 원본 GPS가 보고한 위치 (비교/로깅용).
  final double rawLat;
  final double rawLon;

  /// 원본이 보고한 정확도(m).
  final double rawAccuracy;

  /// 필터 공분산에서 계산한 추정 정확도(m). 보통 rawAccuracy보다 작다.
  final double estAccuracy;

  /// 필터가 추정한 속도(m/s)와 진행방향(도). 속도가 낮으면 course는 무의미.
  final double speed;
  final double? course;

  /// 원본과 필터 추정치의 거리(m). 필터가 얼마나 끌어당겼는지.
  final double correctionM;

  /// 이 fix가 이상치로 판정돼 위치 갱신에 반영되지 않았는지.
  final bool outlierRejected;

  /// 워밍업 구간이라 판정에 쓰면 안 되는 값인지.
  final bool inWarmup;

  final DateTime timestamp;

  FilteredFix({
    required this.lat,
    required this.lon,
    required this.rawLat,
    required this.rawLon,
    required this.rawAccuracy,
    required this.estAccuracy,
    required this.speed,
    required this.course,
    required this.correctionM,
    required this.outlierRejected,
    required this.inWarmup,
    required this.timestamp,
  });

  /// 안내 판정에 써도 되는 값인지. 워밍업 중이거나 추정 정확도가 나쁘면 false.
  bool get usable => !inWarmup && estAccuracy <= 25.0;
}

/// GPS 오차 저감을 위한 위치 공급자.
///
/// 적용한 기법 (효과가 큰 순서)
///
/// 1. **bestForNavigation + 연속 스트림**
///    폴링(getCurrentPosition)은 수신기가 만든 fix를 놓치고, await 지연이
///    호출 주기에 실린다. 스트림은 fix가 생길 때마다 즉시 받는다.
///    bestForNavigation은 Android에서 수신기를 연속 측위로 유지한다.
///
/// 2. **등속도 칼만 필터 (2D, 로컬 ENU 평면)**
///    상태 [동쪽위치, 북쪽위치, 동쪽속도, 북쪽속도]. 위치 관측의 신뢰도를
///    accuracy에 반비례하게 주므로, 정확도가 나쁜 fix는 자동으로 덜
///    반영된다. 단순 이동평균과 달리 "움직이는 중"과 "멈춰 있음"을
///    속도 상태로 구분하므로, 보행 중에 위치가 뒤로 끌리지 않는다.
///
/// 3. **도플러 속도를 관측으로 투입**
///    GNSS 수신기의 speed는 위치를 미분한 값이 아니라 반송파 도플러에서
///    직접 얻은 독립 관측이다. 위치보다 훨씬 정확하고, 느리게 변하는
///    오차(대류권/전리층/정적 멀티패스)가 미분 과정에서 소거된다.
///    이 값을 속도 상태의 관측으로 넣으면 위치 추정도 함께 안정된다.
///
/// 4. **ZUPT (정지 구간 속도 0 고정)**
///    도플러 속도가 임계 미만이면 "속도 0"을 강한 신뢰도로 관측에 넣는다.
///    서 있을 때 위치가 슬금슬금 흘러가는 현상(드리프트)을 끊는다.
///    신호 대기가 잦은 보행에서 특히 효과가 크다.
///
/// 5. **혁신(innovation) 기반 이상치 제거**
///    예측 위치와 관측 위치의 차이를 그 시점의 불확실도로 정규화해서,
///    통계적으로 말이 안 되는 fix(멀티패스로 인한 순간 점프)를 거부한다.
///    고정 거리 임계값과 달리, 불확실도가 큰 초반에는 관대하고 추정이
///    수렴한 뒤에는 엄격해진다.
///
/// 6. **워밍업 / stale 게이트**
///    콜드 스타트 직후 fix는 정확도가 나쁘고, 스트림이 끊긴 뒤의 낡은
///    좌표로 판정이 도는 것도 막아야 한다.
///
/// 7. **모의 위치(mock) 차단**
///    개발 중 위치 모킹 앱이 켜져 있으면 실측이 오염된다.
///
/// 남는 한계: 도심 협곡의 멀티패스는 원리적으로 완전 제거가 불가능하다.
/// 그래서 이 필터 위에 서버 맵매칭(횡방향)과 랜드마크 리셋(종방향)이
/// 함께 필요하다.
class FilteredLocationProvider {
  FilteredLocationProvider({
    this.warmupDuration = const Duration(seconds: 8),
    this.maxFixAge = const Duration(seconds: 6),
    this.maxAccuracy = 50.0,
    this.maxSpeedMps = 3.5,
    this.accelNoise = 0.7,
    this.zuptSpeedThreshold = 0.35,
    this.outlierSigma = 3.5,
  });

  /// 이 시간 동안의 fix는 받아서 필터에 먹이되, usable=false로 표시한다.
  final Duration warmupDuration;

  /// 이보다 오래된 fix는 버린다.
  final Duration maxFixAge;

  /// 이보다 정확도가 나쁜 fix는 필터에 아예 넣지 않는다.
  /// (게이트가 너무 빡빡하면 도심에서 갱신이 멈추므로 여유 있게 잡는다)
  final double maxAccuracy;

  /// 사람이 낼 수 있는 최대 속도(m/s). 상태 예측 시 속도를 이 값으로 제한한다.
  final double maxSpeedMps;

  /// 프로세스 잡음: 보행자의 가속도 변동(m/s²). 크면 필터가 관측을 빨리
  /// 따라가고(반응 빠름/잡음 많음), 작으면 부드럽지만 굼뜨다.
  final double accelNoise;

  /// 이 속도 미만이면 정지로 보고 속도 0을 관측에 넣는다(ZUPT).
  final double zuptSpeedThreshold;

  /// 혁신이 표준편차의 몇 배를 넘으면 이상치로 볼지.
  final double outlierSigma;

  final _controller = StreamController<FilteredFix>.broadcast();
  Stream<FilteredFix> get stream => _controller.stream;

  StreamSubscription<Position>? _sub;

  // ── 로컬 평면 기준점 ──
  double? _originLat;
  double? _originLon;
  double _metersPerLon = 0;
  static const double _metersPerLat = 111320.0;

  // ── 칼만 상태 [x(동), y(북), vx, vy] ──
  final List<double> _x = [0, 0, 0, 0];
  // 공분산 4x4
  final List<List<double>> _P = [
    [1e6, 0, 0, 0],
    [0, 1e6, 0, 0],
    [0, 0, 1e2, 0],
    [0, 0, 0, 1e2],
  ];
  bool _initialized = false;

  DateTime? _lastFixTime;
  DateTime? _startedAt;

  int fixCount = 0;
  int rejectedCount = 0;
  int staleCount = 0;

  bool get inWarmup {
    final t = _startedAt;
    if (t == null) return true;
    return DateTime.now().difference(t) < warmupDuration;
  }

  Future<void> start() async {
    await stop();
    _startedAt = DateTime.now();
    _initialized = false;
    fixCount = 0;
    rejectedCount = 0;
    staleCount = 0;

    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen(_onPosition, onError: (_) {}, cancelOnError: false);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  void _onPosition(Position pos) {
    // ── 사전 게이트 ──
    if (pos.isMocked) return;                 // 모의 위치 차단
    if (pos.accuracy <= 0) return;            // 정확도 미상
    if (pos.accuracy > maxAccuracy) return;   // 쓸 수 없을 만큼 나쁨

    final now = pos.timestamp;
    if (DateTime.now().difference(now) > maxFixAge) {
      staleCount++;
      return;
    }

    fixCount++;

    // ── 로컬 평면 초기화 ──
    if (_originLat == null) {
      _originLat = pos.latitude;
      _originLon = pos.longitude;
      _metersPerLon = _metersPerLat * cos(pos.latitude * pi / 180);
    }

    final zx = (pos.longitude - _originLon!) * _metersPerLon;
    final zy = (pos.latitude - _originLat!) * _metersPerLat;

    if (!_initialized) {
      _x[0] = zx;
      _x[1] = zy;
      _x[2] = 0;
      _x[3] = 0;
      _setP(0, 0, pos.accuracy * pos.accuracy);
      _setP(1, 1, pos.accuracy * pos.accuracy);
      _setP(2, 2, 4.0);
      _setP(3, 3, 4.0);
      _initialized = true;
      _lastFixTime = now;
      _emit(pos, zx, zy, false);
      return;
    }

    // ── 예측 ──
    final dt = (now.difference(_lastFixTime!).inMilliseconds / 1000.0)
        .clamp(0.001, 5.0);
    _predict(dt);
    _lastFixTime = now;

    // ── 이상치 검사 (위치 혁신) ──
    // 혁신을 그 시점의 총 불확실도(예측 + 관측)로 정규화한다.
    // 고정 임계값과 달리, 추정이 아직 불확실할 땐 관대하고 수렴한 뒤엔 엄격하다.
    final r = pos.accuracy * pos.accuracy;
    final innovX = zx - _x[0];
    final innovY = zy - _x[1];
    final sX = _P[0][0] + r;
    final sY = _P[1][1] + r;
    final mahalanobis =
    sqrt(innovX * innovX / sX + innovY * innovY / sY);

    final isOutlier = mahalanobis > outlierSigma;
    if (isOutlier) {
      rejectedCount++;
      // 위치 관측은 버리되 속도 관측은 살린다 — 도플러 속도는 위치가
      // 튀는 상황에서도 대체로 건전하기 때문.
      _updateVelocityFrom(pos);
      _emit(pos, zx, zy, true);
      return;
    }

    // ── 위치 갱신 (순차 스칼라 업데이트) ──
    _scalarUpdate(0, zx, r);
    _scalarUpdate(1, zy, r);

    // ── 속도 갱신 (도플러 / ZUPT) ──
    _updateVelocityFrom(pos);

    // 사람이 낼 수 없는 속도로 발산하지 않도록 제한
    final sp = sqrt(_x[2] * _x[2] + _x[3] * _x[3]);
    if (sp > maxSpeedMps) {
      final k = maxSpeedMps / sp;
      _x[2] *= k;
      _x[3] *= k;
    }

    _emit(pos, zx, zy, false);
  }

  /// 등속도 모델 예측 + 프로세스 잡음 주입.
  void _predict(double dt) {
    _x[0] += _x[2] * dt;
    _x[1] += _x[3] * dt;

    // F P F^T  (F는 등속도 모델)
    final p = _P;
    final p00 = p[0][0] + dt * (p[2][0] + p[0][2]) + dt * dt * p[2][2];
    final p01 = p[0][1] + dt * (p[2][1] + p[0][3]) + dt * dt * p[2][3];
    final p02 = p[0][2] + dt * p[2][2];
    final p03 = p[0][3] + dt * p[2][3];
    final p11 = p[1][1] + dt * (p[3][1] + p[1][3]) + dt * dt * p[3][3];
    final p12 = p[1][2] + dt * p[3][2];
    final p13 = p[1][3] + dt * p[3][3];
    final p22 = p[2][2];
    final p23 = p[2][3];
    final p33 = p[3][3];

    // 프로세스 잡음 Q (가속도 백색잡음 모델)
    final sa2 = accelNoise * accelNoise;
    final q11 = sa2 * dt * dt * dt * dt / 4;
    final q13 = sa2 * dt * dt * dt / 2;
    final q33 = sa2 * dt * dt;

    p[0][0] = p00 + q11;
    p[0][1] = p01;
    p[0][2] = p02 + q13;
    p[0][3] = p03;
    p[1][0] = p01;
    p[1][1] = p11 + q11;
    p[1][2] = p12;
    p[1][3] = p13 + q13;
    p[2][0] = p02 + q13;
    p[2][1] = p12;
    p[2][2] = p22 + q33;
    p[2][3] = p23;
    p[3][0] = p03;
    p[3][1] = p13 + q13;
    p[3][2] = p23;
    p[3][3] = p33 + q33;
  }

  /// 도플러 속도 관측 또는 ZUPT 적용.
  void _updateVelocityFrom(Position pos) {
    final speed = pos.speed;
    if (speed < 0) return; // 속도 미제공

    // speedAccuracy가 없으면 보수적으로 1.0 m/s를 가정
    double sv = pos.speedAccuracy;
    if (sv <= 0 || sv.isNaN) sv = 1.0;

    if (speed < zuptSpeedThreshold) {
      // ZUPT — 서 있다. 속도를 0으로 강하게 고정해 드리프트를 끊는다.
      _scalarUpdate(2, 0.0, 0.05);
      _scalarUpdate(3, 0.0, 0.05);
      return;
    }

    // 도플러 속도를 방향과 함께 성분으로 분해.
    // heading이 없으면 크기 정보만으로는 성분을 만들 수 없으므로 건너뛴다.
    final hd = pos.heading;
    if (hd < 0 || hd > 360) return;

    final rad = hd * pi / 180;
    final vEast = speed * sin(rad);
    final vNorth = speed * cos(rad);
    final rv = sv * sv;

    _scalarUpdate(2, vEast, rv);
    _scalarUpdate(3, vNorth, rv);
  }

  /// 상태 i에 대한 스칼라 관측 갱신.
  /// R이 대각이고 H가 단위행 벡터이므로 행렬 역변환 없이 처리된다.
  void _scalarUpdate(int i, double z, double r) {
    final s = _P[i][i] + r;
    if (s <= 0) return;
    final innov = z - _x[i];

    final k = List<double>.generate(4, (j) => _P[j][i] / s);
    for (int j = 0; j < 4; j++) {
      _x[j] += k[j] * innov;
    }
    // P = (I - K H) P
    final row = List<double>.from(_P[i]);
    for (int j = 0; j < 4; j++) {
      for (int c = 0; c < 4; c++) {
        _P[j][c] -= k[j] * row[c];
      }
    }
    // 수치 안정성: 대칭 유지
    for (int j = 0; j < 4; j++) {
      for (int c = j + 1; c < 4; c++) {
        final m = (_P[j][c] + _P[c][j]) / 2;
        _P[j][c] = m;
        _P[c][j] = m;
      }
    }
  }

  void _setP(int i, int j, double v) => _P[i][j] = v;

  void _emit(Position pos, double zx, double zy, bool rejected) {
    final lat = _originLat! + _x[1] / _metersPerLat;
    final lon = _originLon! + _x[0] / _metersPerLon;

    final estAcc = sqrt(max(_P[0][0], 0) + max(_P[1][1], 0));
    final speed = sqrt(_x[2] * _x[2] + _x[3] * _x[3]);
    final course = speed >= zuptSpeedThreshold
        ? (atan2(_x[2], _x[3]) * 180 / pi + 360) % 360
        : null;

    final dx = zx - _x[0];
    final dy = zy - _x[1];

    _controller.add(FilteredFix(
      lat: lat,
      lon: lon,
      rawLat: pos.latitude,
      rawLon: pos.longitude,
      rawAccuracy: pos.accuracy,
      estAccuracy: estAcc,
      speed: speed,
      course: course,
      correctionM: sqrt(dx * dx + dy * dy),
      outlierRejected: rejected,
      inWarmup: inWarmup,
      timestamp: pos.timestamp,
    ));
  }
}