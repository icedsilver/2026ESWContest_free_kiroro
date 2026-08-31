import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/route_result.dart';
import '../models/waypoint.dart';
import '../services/filtered_location_provider.dart';

typedef SpeakCallback = Future<void> Function(
    String text, {
    bool urgent,
    String? category,
    bool critical,
    });
typedef SendTurnCallback = void Function(String turnType);
typedef TrackCallback = void Function(String sessionId, double lat, double lon);

/// 변경 요약 (GPS 필터 적용판)
///
/// [1] Geolocator 직접 호출 → FilteredLocationProvider 구독
///
///   기존: 매 tick마다 `await Geolocator.getCurrentPosition(...)`
///   변경: provider가 스트림으로 받은 fix를 필터링해 두고, tick은 보관된
///        최신 fix를 읽기만 한다.
///
///   tick 구조(1초 재귀 스케줄링)는 그대로 둔다. 스트림 이벤트마다 안내
///   로직을 돌리면 "이전 tick의 TTS가 끝나기 전에 다음 tick이 공유 상태를
///   건드리는" 경합이 되살아나기 때문이다. 스트림은 좌표 보관만, 판정과
///   발화는 여전히 tick이 단독으로 한다.
///
///   부수 효과: getCurrentPosition의 await 지연이 tick 주기에서 사라져
///   실제 주기가 정확히 1초가 된다. 안내가 종전보다 살짝 이르게 나올 수 있다.
///
/// [2] 판정 기준이 raw accuracy → estAccuracy 로 바뀜
///
///   estAccuracy는 칼만 공분산에서 나온 값이라 보통 raw보다 작다. 즉
///   기존 25m 게이트가 상대적으로 덜 걸리게 된다. 이건 의도된 것이다 —
///   raw가 나빠도 필터가 여러 fix를 종합해 신뢰할 만한 추정을 갖고 있으면
///   안내를 계속하는 편이 낫다. 반대로 필터가 자신 없으면(추정이 발산하면)
///   estAccuracy가 커져서 게이트가 걸린다.
///
/// [3] 좌표/속도/진행방향 모두 필터 추정치를 쓴다
///
///   currentLat/currentLng = 필터 위치
///   _speed = 칼만 속도(도플러 관측이 반영됨)
///   _gpsHeading = 칼만 속도벡터의 방향
///
///   원본값은 debugRawAccuracy / debugCorrection 으로 노출해 비교 가능하게 뒀다.
///
/// [4] v6.9: 화면 방향 아이콘 즉시성 게이트 + null(계산 전) 상태
///
///   기존엔 다음 경유지가 지정한 turnType(예: LEFT)이 있으면 아무리 멀리
///   있어도(예: 80m 앞) 화면 아이콘이 바로 좌회전으로 바뀌었다. 이는
///   "지금 당장 해야 할 행동"이 아니라 "곧 다가올 행동"이라 화면과
///   음성이 서로 다른 시점의 정보를 전달하는 혼란을 준다.
///
///   그래서 currentTurnDisplay는 목표(다음 경유지 혹은 목적지)까지의
///   거리가 _turnIconRadius 이내일 때만 실제 방향을 반영하고, 그 전에는
///   항상 STRAIGHT를 유지한다. 다가오는 회전에 대한 예고는 기존처럼
///   _thresholds 기반 음성 안내("OO미터 앞에서 좌회전하세요")로만 전달한다.
///
///   또한 currentTurnDisplay는 String?로 바뀌었다. loadRoute() 직후 ~
///   첫 tick이 실제로 방향을 계산하기 전까지(GPS 워밍업/약신호 구간 포함)는
///   "판단 불가" 상태이지, "직진"이 아니다. 이 구간에 'STRAIGHT'라는
///   기본값을 임의로 채우면 실제로는 도착하자마자 회전해야 하는 경로에서도
///   화면이 잠깐 직진을 보여주는 부정확한 신호가 된다. null로 두면 화면은
///   "안내 준비 중" 같은 중립 상태를 보여줄 수 있고, 첫 실질 tick(=
///   _firstDirectionAnnounced가 켜지는 순간)에서야 처음 값이 채워진다.
///
/// [5] v6.11: TTS 큐 밀림 방지
///
///   - tick 주기를 500ms → 1000ms로 복원 (서버의 도착 판정 안전 마진
///     설계 전제와 일치시킴. arrivalFixNeeded=3 tick이 다시 "3초"가 됨).
///   - 한 tick에 경유지를 여러 개 통과해도(GPS 튐/빠른 이동/스킵 등)
///     방향 안내는 최종 경유지 기준 1회만 발화한다. 중간 경유지의
///     "지금 회전하세요"는 이미 지나친 시점엔 낡은 정보이기 때문이다.
///     단, 시설(계단 등) 안전 안내는 지나친 경유지 전부에 대해 유지한다.
///   - 방향류 안내(onSpeak)에 category: 'direction'을 부여해, 아직
///     재생되지 않은 이전 방향 안내가 큐에 남아있으면 자동 폐기되고
///     최신 안내로 교체되도록 한다. GPS 상태 안내는 'gps_status'로 묶어
///     동일하게 처리한다.
///
/// [6] v6.12: tick 내 direction 발화 중복/유실 방지
///
///   VoiceService.speak()의 category 치환 로직은 "큐에 아직 대기 중인"
///   같은 category 항목만 지운다. 이미 _current로 승격되어 재생 중인
///   항목은 건드리지 않는다. 평소엔 문제가 없지만, 직전에 다른 발화
///   (예: _dispatchWaypointsPassed에서 먼저 나가는 시설/계단 안전 안내,
///   category 없는 urgent/critical 발화)가 _current를 차지하고 있으면,
///   그 뒤 큐에 들어간 "지금 좌회전하세요"(category: 'direction')가
///   재생을 시작도 못 한 채, 같은 tick 뒤쪽의 임계값(threshold) 로직이
///   또 category: 'direction'으로 onSpeak를 부르면서 evict되어 "OO미터
///   앞에서 좌회전"으로 덮어써질 수 있었다.
///
///   방향 안내가 유일한 정보원인 사용자에게는 "지금 돌아야 하는 순간"에
///   "아직 여유 있다"는 낡은 정보가 나가는 셈이라 안전 이슈로 이어진다.
///
///   해결: tick마다 _directionSpokenThisTick 플래그를 리셋하고,
///   direction 카테고리 발화는 모두 _speakDirection()을 통해서만 내보내
///   한 tick 안에서 최대 1회만 실제로 큐에 들어가도록 가드한다. 상태값
///   (currentTurnDisplay/statusText/_spokenThresholds)과 haptic/bluetooth
///   갱신은 그대로 매 tick 수행하고, 음성만 스킵되므로 다음 tick(1초 후)에
///   상황이 바뀌면 자연히 새로 안내된다 — 정보 유실이 아니라 같은 tick
///   내 중복 방지다.
class NavigationController {
  NavigationController({
    required this.onSpeak,
    required this.onSendBluetooth,
    required this.onHaptic,
    required this.onStateChanged,
    required this.onArrived,
    this.onTrack,
  });

  final SpeakCallback onSpeak;
  final SendTurnCallback onSendBluetooth;
  final VoidCallback onHaptic;
  final VoidCallback onStateChanged;
  final VoidCallback onArrived;
  final TrackCallback? onTrack;

  /// GPS 필터. 컨트롤러가 소유하므로 화면 쪽 배선이 필요 없다.
  final FilteredLocationProvider _location = FilteredLocationProvider(
    warmupDuration: const Duration(seconds: 3),
    accelNoise: 1.8,
  );
  StreamSubscription<FilteredFix>? _locSub;
  FilteredFix? _lastFix;

  static const List<int> _thresholds = [100, 50, 30, 10, 5];
  static const double maxGpsAccuracy = 25.0;
  static const double arrivalRadius = 15.0;
  static const int arrivalFixNeeded = 3;
  static const double waypointPassRadius = 10.0;

  // v6.11: 500ms → 1000ms 복원. 서버 주석("3 tick 연속 → 체감 반경
  // 7~8m")이 1초 tick을 전제로 설계된 안전 마진이라, 500ms에서는 이
  // 마진이 절반(1.5초)으로 줄어 GPS 튐에 대한 방어력이 약해진 상태였다.
  static const Duration _tickInterval = Duration(milliseconds: 1000);

  // v6.9: 화면 방향 아이콘 노출 기준. 이 거리 이내로 접근했을 때만
  // 실제 회전 방향을 아이콘에 반영한다. 그 전까지는 "지금 할 일"이
  // 아니므로 아이콘은 STRAIGHT를 유지하고, 다가오는 회전 예고는
  // 기존처럼 음성(_thresholds 기반 안내)으로만 전달한다.
  static const double _turnIconRadius = 20.0;

  List<Waypoint> waypoints = [];
  int routeIndex = 0;
  double currentLat = 0;
  double currentLng = 0;
  double currentHeading = -1; // 나침반 (외부에서 주입)

  double _gpsHeading = -1;
  double _speed = 0;

  static const int _maxSkipLookahead = 2;
  static const double _skipMarginMeters = 30.0;

  double distToNext = 0;
  double distToDestination = 0;

  // v6.9: null = 아직 첫 방향이 계산되지 않음(경로 로드 직후, GPS 워밍업/
  // 약신호 구간). 화면은 이 상태를 "직진"이 아니라 "안내 준비 중"으로
  // 별도 표시해야 한다. 첫 실질 tick에서 실제 방향으로 채워진다.
  String? currentTurnDisplay;

  String currentWaypointDesc = '';
  String statusText = '';

  double _destLat = 0;
  double _destLon = 0;

  String _sessionId = '';

  final Set<int> _spokenThresholds = {};
  int _arrivalFixCount = 0;

  bool _aligned = false;
  String _lastAlignDir = '';

  double? _smoothX;
  double? _smoothY;
  double? _cachedHeading;
  bool _usingGpsHeading = false;
  String _lastLiveDir = 'STRAIGHT';

  static const double _headingSmoothingAlpha = 0.35;

  // v6.13: 완전실명 독립보행 평균속도(0.91 m/s) 데이터에 맞춰 A안 채택.
  // 기존(0.8/0.4)은 enter가 평균 바로 위에 걸쳐 있어, 정상적인 속도
  // 변동(장애물 탐색, 잠깐 멈칫 등)만으로도 GPS헤딩⇄나침반 경계를 계속
  // 넘나들 수 있었다. 1.0/0.5로 올려 평균 전체가 enter 아래에 위치하게
  // 하고, GPS헤딩은 저시력자의 빠른 구간(1.1~1.3)이나 가이드 동반
  // (1.4~1.8)처럼 확실히 빠르게 걷는 경우에만 켜지도록 한다.
  static const double _minReliableSpeedEnter = 1.0;
  static const double _minReliableSpeedExit = 0.5;

  // v6.13: 임계값을 데이터에 맞게 올려도, 순간적인 속도 노이즈만으로
  // 경계 근처에서 흔들리는 근본 구조는 남는다. enter/exit 조건이 이
  // 횟수만큼 "연속" tick에서 충족돼야 실제로 헤딩 소스를 전환한다
  // (tick 주기 1초 기준 최대 ~2초 지연). gpsUsable=false로 인한 강제
  // 나침반 전환은 이 디바운스 대상이 아니다 — 그건 속도 노이즈가 아니라
  // "이번 fix의 GPS 추정 자체를 신뢰할 수 없다"는 판단이라, 지연 없이
  // 즉시 반영하는 편이 안전하다.
  static const int _headingSwitchDebounceTicks = 2;
  bool? _pendingUsingGpsHeading;
  int _pendingHeadingTicks = 0;

  static const Duration weakGpsAnnounceDelay = Duration(seconds: 12);
  DateTime? _weakGpsSince;
  bool _weakGpsAnnounced = false;

  // v6.12: 이번 tick 안에서 category:'direction' 발화가 이미 한 번
  // 나갔는지 여부. _tick() 시작 시 매번 false로 리셋된다.
  bool _directionSpokenThisTick = false;

  Timer? _timer;
  bool _running = false;

  bool get isRunning => _running;

  // ── 디버그 노출 ──
  double debugAccuracy = 0;              // 필터 추정 정확도
  double debugRawAccuracy = 0;           // 원본 GPS 정확도
  double debugCorrection = 0;            // 원본↔필터 거리(m)
  int get debugFixCount => _location.fixCount;
  int get debugRejectedCount => _location.rejectedCount;

  double? get debugHeading => _resolveHeading();
  double? get debugBearingToDest =>
      (_destLat == 0 || currentLat == 0) ? null : _bearingTo(_destLat, _destLon);
  int get debugArrivalFix => _arrivalFixCount;

  String get debugHeadingSource {
    if (_cachedHeading == null) return '없음';
    return _usingGpsHeading ? 'GPS' : '나침반';
  }

  void loadRoute(RouteResult route) {
    waypoints = route.waypoints;
    routeIndex = 0;
    // v6.9: 경로를 막 받은 시점엔 아직 실제 위치 기준 판정이 이뤄지지
    // 않았으므로 null(계산 전)로 시작한다. 곧바로 실행되는 첫 tick에서
    // 실제 거리 기준으로 값이 채워진다.
    currentTurnDisplay = null;
    _destLat = route.destinationLat;
    _destLon = route.destinationLon;
    _sessionId = route.sessionId;
  }

  void start() {
    _spokenThresholds.clear();
    _arrivalFixCount = 0;
    _weakGpsSince = null;
    _weakGpsAnnounced = false;
    _lastLiveDir = 'STRAIGHT';
    _aligned = false;
    _lastAlignDir = '';

    // 헤딩 평활 상태 초기화. 재탐색은 reset()을 거치지 않고 stop()→start()
    // 로 오므로, 여기서 지우지 않으면 이전 경로의 평활값이 이월된다.
    _smoothX = null;
    _smoothY = null;
    _cachedHeading = null;
    _usingGpsHeading = false;
    _pendingUsingGpsHeading = null; // v6.13
    _pendingHeadingTicks = 0;

    _lastFix = null;
    _running = true;

    // GPS 스트림 시작 + 구독
    _location.start();
    _locSub?.cancel();
    _locSub = _location.stream.listen((fix) {
      _lastFix = fix;
    });

    _scheduleNextTick();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _locSub?.cancel();
    _locSub = null;
    _location.stop();
  }

  void reset() {
    stop();
    waypoints = [];
    routeIndex = 0;
    distToNext = 0;
    distToDestination = 0;
    currentTurnDisplay = null; // v6.9
    currentWaypointDesc = '';
    _destLat = 0;
    _destLon = 0;
    _sessionId = '';
    _weakGpsSince = null;
    _weakGpsAnnounced = false;
    _smoothX = null;
    _smoothY = null;
    _cachedHeading = null;
    _usingGpsHeading = false;
    _pendingUsingGpsHeading = null; // v6.13
    _pendingHeadingTicks = 0;
    _lastLiveDir = 'STRAIGHT';
    _aligned = false;
    _lastAlignDir = '';
    _lastFix = null;
  }

  void _scheduleNextTick() {
    _timer = Timer(_tickInterval, () async {
      if (!_running) return;
      await _tick();
      if (_running) _scheduleNextTick();
    });
  }

  /// v6.12: category:'direction' 발화 전용 게이트웨이. 한 tick 안에서는
  /// 최초 1건만 실제로 onSpeak(큐 삽입)까지 이어지고, 이후 호출은
  /// 조용히 무시된다. (자세한 배경은 클래스 상단 [6] 참고)
  Future<void> _speakDirection(String text) async {
    if (_directionSpokenThisTick) return;
    _directionSpokenThisTick = true;
    await onSpeak(text, category: 'direction');
  }

  Future<void> _tick() async {
    try {
      // v6.12: tick마다 direction 발화 가드를 리셋한다.
      _directionSpokenThisTick = false;

      final fix = _lastFix;

      // (a) 아직 첫 fix 없음
      if (fix == null) {
        statusText = 'GPS 위치를 찾는 중입니다';
        onStateChanged();
        return;
      }

      debugAccuracy = fix.estAccuracy;
      debugRawAccuracy = fix.rawAccuracy;
      debugCorrection = fix.correctionM;

      // (b) 헤딩은 정확도 게이트와 무관하게 갱신한다.
      //     나침반은 자력계 기반이라 GPS 품질과 상관이 없고, GPS가 나쁜
      //     구간(도심 협곡)이야말로 방향 정보가 가장 필요한 상황이다.
      _speed = fix.speed;
      _gpsHeading = fix.course ?? -1;
      _updateResolvedHeading(gpsUsable: fix.usable);

      // (c) 워밍업 — 좌표는 갱신하되 판정/발화는 하지 않는다.
      //     콜드 스타트 직후 fix로 도착 판정이 돌면 엉뚱한 곳에서
      //     "도착했습니다"가 나갈 수 있다. currentTurnDisplay는 여전히
      //     null로 남아 화면이 "안내 준비 중" 상태를 보여준다.
      if (fix.inWarmup) {
        currentLat = fix.lat;
        currentLng = fix.lon;
        statusText = 'GPS 안정화 중 (±${fix.estAccuracy.toStringAsFixed(0)}m)';
        onStateChanged();
        return;
      }

      // (d) 필터 추정 정확도 게이트. 여기도 마찬가지로 currentTurnDisplay를
      //     건드리지 않으므로, 로드 직후라면 계속 null(안내 준비 중)이다.
      if (fix.estAccuracy > maxGpsAccuracy) {
        statusText = 'GPS 신호 대기 중 (오차 ±${fix.estAccuracy.toStringAsFixed(0)}m)';
        onStateChanged();

        _weakGpsSince ??= DateTime.now();
        final weakDuration = DateTime.now().difference(_weakGpsSince!);
        if (weakDuration >= weakGpsAnnounceDelay && !_weakGpsAnnounced) {
          _weakGpsAnnounced = true;
          onHaptic();
          await onSpeak(
            'GPS 신호가 약합니다. 안내가 잠시 지연될 수 있습니다.',
            category: 'gps_status',
          );
        }
        return;
      }

      if (_weakGpsAnnounced) {
        onHaptic();
        await onSpeak('GPS 신호가 회복되었습니다.', category: 'gps_status');
      }
      _weakGpsSince = null;
      _weakGpsAnnounced = false;

      currentLat = fix.lat;
      currentLng = fix.lon;

      // 서버 트래킹은 필터 좌표를 보낸다 — 앱이 실제로 믿고 있는 위치와
      // 서버가 스냅하는 대상을 일치시키기 위함.
      if (_sessionId.isNotEmpty) {
        onTrack?.call(_sessionId, currentLat, currentLng);
      }

      if (waypoints.isEmpty && _destLat == 0) return;

      final destLat = _destLat != 0 ? _destLat : waypoints.last.lat;
      final destLon = _destLat != 0 ? _destLon : waypoints.last.lon;
      final destDist = _haversine(currentLat, currentLng, destLat, destLon);
      distToDestination = destDist;
      // ── 출발 정렬 단계 (문제 1·3) ──
      if (!_aligned) {
        final bool toDest0 = routeIndex >= waypoints.length;
        final double tLat0 = toDest0 ? destLat : waypoints[routeIndex].lat;
        final double tLon0 = toDest0 ? destLon : waypoints[routeIndex].lon;
        final double tDist0 = _haversine(currentLat, currentLng, tLat0, tLon0);
        final heading = _resolveHeading();

        if (heading == null) {
          _aligned = true;
          currentTurnDisplay = 'STRAIGHT';
          onHaptic();
          unawaited(_speakDirection(
              '안내를 시작합니다. ${tDist0.toStringAsFixed(0)}미터 이동하세요.'));
          onSendBluetooth('STRAIGHT');
        } else {
          final diff = (_bearingTo(tLat0, tLon0) - heading + 540) % 360 - 180;
          final absD = diff.abs();
          if (absD <= 30) {
            _aligned = true;
            _lastAlignDir = '';
            currentTurnDisplay = 'STRAIGHT';
            onHaptic();
            unawaited(_speakDirection(
                '좋습니다. ${tDist0.toStringAsFixed(0)}미터 직진하세요.'));
            onSendBluetooth('STRAIGHT');
          } else {
            final String dir = absD >= 150 ? 'UTURN' : (diff > 0 ? 'RIGHT' : 'LEFT');
            if (dir != _lastAlignDir) {
              _lastAlignDir = dir;
              currentTurnDisplay = dir;
              onHaptic();
              onSendBluetooth(dir);
              final msg = absD >= 150
                  ? '뒤로 돌아주세요.'
                  : (diff > 0 ? '오른쪽으로 몸을 돌리세요.' : '왼쪽으로 몸을 돌리세요.');
              unawaited(_speakDirection(msg));
            }
            onStateChanged();
            return; // 정렬 안 끝났으면 주행 판정 스킵
          }
        }
      }

      if (destDist < arrivalRadius) {
        _arrivalFixCount++;
        if (_arrivalFixCount >= arrivalFixNeeded) {
          await _dispatchArrival();
          return;
        }
      } else {
        _arrivalFixCount = 0;
      }

      final List<Waypoint> passedWaypoints = [];
      while (routeIndex < waypoints.length) {
        final wp = waypoints[routeIndex];
        final d = _haversine(currentLat, currentLng, wp.lat, wp.lon);
        final reached = d < waypointPassRadius;
        final resolvedHeading = _resolveHeading();
        final passedBehind = resolvedHeading != null &&
            d < 30.0 &&
            _angleDiff(resolvedHeading, _bearingTo(wp.lat, wp.lon)) > 100;
        if (!reached && !passedBehind) break;

        if (reached) {
          passedWaypoints.add(wp);
        }
        routeIndex++;
        _spokenThresholds.clear();
      }

      // v6.11: 한 tick에 경유지를 여러 개 통과했어도 방향 안내는 한 번만
      // (중간 경유지 방향 지시는 이미 낡은 정보). 시설 안내는 전부 유지.
      if (passedWaypoints.isNotEmpty) {
        await _dispatchWaypointsPassed(passedWaypoints);
      }

      if (fix.estAccuracy <= 15.0 && routeIndex < waypoints.length) {
        final cur = waypoints[routeIndex];
        double bestD = _haversine(currentLat, currentLng, cur.lat, cur.lon);
        int bestIdx = routeIndex;
        final int lookaheadEnd = min(routeIndex + _maxSkipLookahead, waypoints.length - 1);
        for (int i = routeIndex + 1; i <= lookaheadEnd; i++) {
          final d = _haversine(currentLat, currentLng, waypoints[i].lat, waypoints[i].lon);
          if (d < bestD - _skipMarginMeters) {
            bestD = d;
            bestIdx = i;
          }
        }
        if (bestIdx != routeIndex) {
          routeIndex = bestIdx;
          _spokenThresholds.clear();

          onHaptic();
          await _speakDirection('다음 경유지로 경로를 변경합니다.');
        }
      }

      final bool toDestination = routeIndex >= waypoints.length;
      final double targetLat = toDestination ? destLat : waypoints[routeIndex].lat;
      final double targetLon = toDestination ? destLon : waypoints[routeIndex].lon;
      final String upcomingTurn = toDestination ? 'STRAIGHT' : waypoints[routeIndex].turnType;
      final double targetDist =
      toDestination ? destDist : _haversine(currentLat, currentLng, targetLat, targetLon);
      final String alignDir = _relativeDirection(targetLat, targetLon, upcomingTurn);
      // liveDir: 음성/블루투스 안내에 쓰이는 "실제 목표 방향". 거리와
      // 무관하게 항상 정확한 값을 유지해야 _thresholds 기반 예고 음성이
      // 제때 정확한 내용을 말할 수 있다.
      final String liveDir = upcomingTurn != 'STRAIGHT' ? upcomingTurn : alignDir;

      distToNext = targetDist;

      // v6.9: 화면 아이콘은 liveDir을 그대로 쓰지 않고, 목표까지 거리가
      // _turnIconRadius 이내일 때만 반영한다. 이 tick에 도달했다는 것
      // 자체가 "첫 방향 계산이 이루어졌다"는 뜻이므로 더 이상 null이
      // 아니며, 그 전까지는 STRAIGHT를 유지한다.
      final bool turnIsImmediate = targetDist <= _turnIconRadius;
      currentTurnDisplay = turnIsImmediate ? liveDir : 'STRAIGHT';

      statusText = toDestination
          ? '목적지까지 ${destDist.toStringAsFixed(0)}m'
          : '목적지까지 ${destDist.toStringAsFixed(0)}m · ${targetDist.toStringAsFixed(0)}m 후 ${_turnTypeLabel(liveDir)}';
      currentWaypointDesc = toDestination
          ? '목적지 부근'
          : waypoints[routeIndex].description.isNotEmpty
          ? waypoints[routeIndex].description
          : waypoints[routeIndex].name;



      int? matched;
      for (final threshold in _thresholds) {
        if (targetDist <= threshold && !_spokenThresholds.contains(threshold)) {
          if (matched == null || threshold < matched) matched = threshold;
        }
      }

      String? thresholdSpeech;
      if (matched != null) {
        for (final threshold in _thresholds) {
          if (threshold >= matched) _spokenThresholds.add(threshold);
        }

        final bool isImminent = matched == _thresholds.last; // 5m
        if (toDestination) {
          thresholdSpeech = isImminent
              ? '곧 목적지에 도착합니다.'
              : '목적지까지 ${matched}미터 남았습니다.';
        } else {
          if (liveDir == 'STRAIGHT') {
            if (isImminent) {
              thresholdSpeech = '지금 직진 하세요.';
            } else if (matched >= 50) {
              thresholdSpeech = '약 ${matched}미터 계속 직진하세요.';
            } else {
              thresholdSpeech = '${matched}미터까지 직진하세요.';
            }
          } else {
            thresholdSpeech = isImminent
                ? '지금 ${_turnTypeToKorean(liveDir)}'
                : '${matched}미터 앞에서 ${_turnTypeLabel(liveDir)}';
          }
        }
      }

      if (thresholdSpeech != null) {
        onHaptic();
        onSendBluetooth(liveDir);
        unawaited(_speakDirection(thresholdSpeech));
      }
      onStateChanged();
    } catch (_) {}
  }

  /// v6.11: 한 tick에 경유지를 여러 개 지나쳤을 때(GPS 튐, 빠른 이동,
  /// 스킵 로직 등) 각각에 대해 "지금 회전하세요"를 반복 발화하지 않는다 —
  /// 중간 경유지의 방향 지시는 이미 지나친 시점에 낡은 정보이기 때문이다.
  ///
  /// 단, 시설(계단 등) 안전 안내는 병합하지 않고 지나친 경유지 전부에
  /// 대해 유지한다 — 병합하면 실제 위험 구간 안내를 누락할 수 있다.
  /// critical: true로 표시해 VoiceService의 큐 길이 상한 정리 대상에서도
  /// 제외되도록 한다.
  ///
  /// v6.12: 여기서 나가는 방향 안내(마지막 3곳의 onSpeak)는 모두
  /// _speakDirection()을 거친다. 시설 안내가 먼저 _current를 차지해
  /// 이 방향 안내가 큐에서 대기하게 되더라도, 같은 tick 뒤쪽의 임계값
  /// 로직이 _directionSpokenThisTick 가드에 막혀 이를 evict하지 않는다.
  Future<void> _dispatchWaypointsPassed(List<Waypoint> passed) async {
    for (final wp in passed) {
      final facilitySpeech = _facilitySpeech(wp.facility);
      if (facilitySpeech != null) {
        onHaptic();
        final isUrgent = wp.facility == 'STAIRS' || wp.facility == 'STAIRS_RAMP';
        unawaited(onSpeak(facilitySpeech, urgent: isUrgent, critical: true));
      }
    }

    // 방향 안내는 최종(=현재 목표) 경유지 기준으로 한 번만.
    final wp = passed.last;
    currentTurnDisplay = wp.turnType;
    currentWaypointDesc = wp.description.isNotEmpty ? wp.description : wp.name;

    onHaptic();
    onSendBluetooth(wp.turnType);

    final bool toDest = routeIndex >= waypoints.length;
    final double targetLat = toDest
        ? (_destLat != 0 ? _destLat : (waypoints.isNotEmpty ? waypoints.last.lat : 0))
        : waypoints[routeIndex].lat;
    final double targetLon = toDest
        ? (_destLon != 0 ? _destLon : (waypoints.isNotEmpty ? waypoints.last.lon : 0))
        : waypoints[routeIndex].lon;
    final double nextDist = (targetLat != 0 && targetLon != 0)
        ? _haversine(currentLat, currentLng, targetLat, targetLon)
        : 0;

    if (nextDist >= 40) {
      if (wp.turnType == 'STRAIGHT') {
        unawaited(_speakDirection(
          '약 ${nextDist.toStringAsFixed(0)}미터 직진하세요.',
        ));
      } else {
        unawaited(_speakDirection(
          '지금 ${_turnTypeLabel(wp.turnType)}하세요. 약 ${nextDist.toStringAsFixed(0)}미터 직진 구간입니다.',
        ));
      }
    } else {
      unawaited(_speakDirection(
        '지금 ${_turnTypeToKorean(wp.turnType)}',
      ));
    }

    onStateChanged();
  }

  String? _facilitySpeech(String facility) {
    switch (facility) {
      case 'STAIRS':
      case 'STAIRS_RAMP':
        return '전방에 계단이 있습니다. 주의하세요.';
      case 'RAMP':
        return '전방에 경사로가 있습니다.';
      case 'OVERPASS':
        return '전방에 육교가 있습니다.';
      case 'UNDERPASS':
        return '전방에 지하보도가 있습니다.';
      case 'ELEVATOR':
        return '전방에 엘리베이터가 있습니다.';
      default:
        if (facility.startsWith('CROSSWALK')) return '전방에 횡단보도가 있습니다.';
        return null;
    }
  }

  Future<void> _dispatchArrival() async {
    onHaptic();
    onSendBluetooth('ARRIVED');
    await onSpeak('목적지에 도착했습니다.', urgent: true);
    reset();
    onArrived();
  }

  double _bearingTo(double toLat, double toLon) {
    final dLon = _toRad(toLon - currentLng);
    final lat1 = _toRad(currentLat);
    final lat2 = _toRad(toLat);
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  double _angleDiff(double a, double b) {
    final diff = ((a - b + 360) % 360);
    return diff > 180 ? 360 - diff : diff;
  }

  String _relativeDirection(double toLat, double toLon, String fallbackTurnType) {
    final heading = _resolveHeading();
    if (heading == null) return fallbackTurnType;

    final bearing = _bearingTo(toLat, toLon);
    final diff = (bearing - heading + 360) % 360;
    final angle = diff <= 180 ? diff : 360 - diff;
    final side = diff <= 180 ? 'RIGHT' : 'LEFT';

    const double exitStraight = 35.0;
    const double enterStraight = 25.0;

    final String result = _lastLiveDir == 'STRAIGHT'
        ? (angle > exitStraight ? side : 'STRAIGHT')
        : (angle < enterStraight ? 'STRAIGHT' : side);

    _lastLiveDir = result;
    return result;
  }

  /// [gpsUsable]: 이번 추정이 신뢰 범위 안인지. false면 GPS 진행방향 사용을
  /// 해제하고 나침반만 쓴다.
  ///
  /// v6.13: enter/exit 판정 결과(candidate)가 현재 상태(_usingGpsHeading)와
  /// 다르면 곧바로 전환하지 않고, 같은 candidate가
  /// [_headingSwitchDebounceTicks]회 연속으로 나와야 실제로 전환한다.
  /// candidate가 현재 상태와 같아지거나 방향이 바뀌면 카운터는 리셋된다.
  /// gpsUsable=false만은 디바운스 없이 즉시 나침반으로 전환한다 —
  /// 정확도 게이트 붕괴는 속도 노이즈가 아니라 신뢰도 판단이기 때문이다.
  void _updateResolvedHeading({required bool gpsUsable}) {
    if (!gpsUsable) {
      _usingGpsHeading = false;
      _pendingUsingGpsHeading = null;
      _pendingHeadingTicks = 0;
    } else {
      final bool candidate = _usingGpsHeading
          ? !(_speed < _minReliableSpeedExit || _gpsHeading < 0)
          : (_speed >= _minReliableSpeedEnter && _gpsHeading >= 0);

      if (candidate == _usingGpsHeading) {
        // 이미 현재 상태와 일치 — 전환 시도가 아니므로 진행 중이던
        // 디바운스 카운트가 있었다면 취소한다.
        _pendingUsingGpsHeading = null;
        _pendingHeadingTicks = 0;
      } else {
        if (_pendingUsingGpsHeading == candidate) {
          _pendingHeadingTicks++;
        } else {
          _pendingUsingGpsHeading = candidate;
          _pendingHeadingTicks = 1;
        }

        if (_pendingHeadingTicks >= _headingSwitchDebounceTicks) {
          _usingGpsHeading = candidate;
          _pendingUsingGpsHeading = null;
          _pendingHeadingTicks = 0;
        }
      }
    }

    final double? raw =
    _usingGpsHeading ? _gpsHeading : (currentHeading >= 0 ? currentHeading : null);

    if (raw == null) {
      _cachedHeading = null;
      return;
    }

    final rad = _toRad(raw);
    final x = cos(rad), y = sin(rad);
    if (_smoothX == null) {
      _smoothX = x;
      _smoothY = y;
    } else {
      _smoothX = _smoothX! + _headingSmoothingAlpha * (x - _smoothX!);
      _smoothY = _smoothY! + _headingSmoothingAlpha * (y - _smoothY!);
    }
    _cachedHeading = (atan2(_smoothY!, _smoothX!) * 180 / pi + 360) % 360;
  }

  double? _resolveHeading() => _cachedHeading;

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _toRad(double deg) => deg * pi / 180;

  String _turnTypeToKorean(String t) {
    switch (t) {
      case 'RIGHT':
        return '우회전 하세요.';
      case 'LEFT':
        return '좌회전 하세요.';
      case 'UTURN':
        return '유턴 하세요.';
      case 'ARRIVED':
        return '목적지에 도착했습니다.';
      default:
        return '직진 하세요.';
    }
  }

  String _turnTypeLabel(String t) {
    switch (t) {
      case 'RIGHT':
        return '우회전';
      case 'LEFT':
        return '좌회전';
      case 'UTURN':
        return '유턴';
      case 'ARRIVED':
        return '도착';
      default:
        return '직진';
    }
  }

  void dispose() {
    stop();
    _location.dispose();
  }
}