// v6.10 리팩터링: 안내 종료 오조작 방지
// - 안내 중 위로 스와이프(종료) 시 즉시 종료하지 않고 2단계 확인을 거친다.
//   1차 스와이프: 아직 종료하지 않고 "한 번 더" 안내 + 확인 창(1.5초) 시작.
//   확인 창 안에 2차 스와이프가 들어오면 그때 실제로 종료한다.
//   확인 창을 넘기면 자동으로 무효화되어, 다음 위로 스와이프는 다시 1차로 취급된다.
// - 재탐색(아래로 스와이프)은 기존과 동일하게 즉시 실행하며, 진행 중이던
//   종료 확인 상태는 초기화한다(다른 제스처가 끼어들면 확인 흐름을 리셋).
//
// v6.9 리팩터링: 안내 화면 "즉시 행동"만 표시
// - _buildTurnArrow()에서 목적지 배지 / 웨이포인트 설명 말풍선 /
//   경유지 카운터 / 스와이프 힌트 문구를 제거. 방향 아이콘 + 남은 거리만 유지.
// - 다가오는 회전(아직 멀리 있는 회전)은 화면에 노출하지 않고 음성으로만
//   예고한다 (NavigationController._turnIconRadius 게이트).
// - currentTurnDisplay가 null(=첫 방향 계산 전: 경로 로드 직후, GPS
//   워밍업/약신호 구간)이면 "직진"으로 단정하지 않고 중립적인 준비
//   화면("안내를 준비하고 있습니다")을 보여준다.
// - _buildRouteInfoBanner()는 대기 화면(_buildIdleView)에서만 노출 —
//   "지금 할 일"이 아닌 누적/요약 정보이므로 안내 중 화면에서는 제거.
//
// v6.8 리팩터링: 서버 누적거리 트래킹(/api/navigation/track) 연동
// - NavigationController에 onTrack 콜백을 넘겨, GPS 좌표를 받을 때마다
//   RouteService.trackPosition()을 fire-and-forget으로 호출한다.
// - 응답으로 오는 total_distance_walked를 _totalWalked에 저장하고,
//   안내 화면 상단 배너에 "지금까지 걸은 거리"로 표시한다.
// - 트래킹 실패/지연은 catchError로 조용히 흡수 — 안내(TTS/햅틱) 흐름에
//   어떤 영향도 주지 않는다.
//
// v6.7 리팩터링: 음성 안내 큐 정리
// - _startNavigating()의 "길 안내를 시작합니다" 제거 (직전 _requestRoute()의
//   "...경로를 받았습니다. 안내를 시작합니다."와 중복 발화였음)
// - "GPS 읽는 중입니다" / "서버에 전송 중입니다" 진행상황 내레이션 제거
//   (정보가치가 낮고, 목적지 설정 1회 흐름에서만 발화 4~5개가 연달아
//   재생돼 실제 안내 시작을 지연시켰음)
// - 대신 "서버 응답을 기다리는 중입니다"를 예외적으로만 안내하도록 변경:
//   평소(수 초 이내 응답)엔 조용히 기다리고, 응답이 일정 시간(5초) 이상
//   지연될 때만 1회 발화. 응답이 오면 타이머를 즉시 취소해 뒤늦게
//   불필요한 발화가 큐에 끼어드는 일이 없도록 함.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import 'controllers/navigation_controller.dart';
import 'models/route_result.dart';
import 'repositories/bookmark_repository.dart';
import 'screens/bookmark_list_page.dart';
import 'services/bluetooth_service.dart';
import 'services/route_service.dart';
import 'services/voice_service.dart';
import 'screens/splash_screen.dart';
import 'widgets/nav_debug_panel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  runApp(const AssistiveDeviceApp());
}

class AssistiveDeviceApp extends StatelessWidget {
  const AssistiveDeviceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '키로로 v6.10',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

enum _SwipeDir { up, left, right, down, none }

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  // ── 서비스/저장소/컨트롤러 (관심사별로 분리됨) ──
  final VoiceService _voice = VoiceService();
  final BluetoothService _bluetooth = BluetoothService();
  final BookmarkRepository _bookmarkRepo = BookmarkRepository();
  final RouteService _routeService = RouteService(baseUrl: 'http://35.216.69.13:5000');
  late final NavigationController _nav;

  String _statusText = '준비됨';
  // 재탐색(_onResearchRoute) 시 다시 쓸 목적지 쿼리. 음성으로 들어온 텍스트일
  // 수도, 즐겨찾기 주소일 수도 있다. (화면에 인식 결과를 보여주는 역할은
  // VoiceService.recognizedText가 전담하므로 더 이상 이 필드가 겸하지 않는다)
  String _currentDestinationQuery = '';

  bool _navigating = false;

  String _destinationName = '';
  int _totalDistance = 0;
  int _totalTime = 0;

  // v6.8: 서버 트래킹(/api/navigation/track)이 돌려주는, 현재 세션 시작
  // 이후 누적 도보거리(m). 트래킹 호출이 없거나 실패하면 0으로 남는다 —
  // 이 값이 안 보인다고 해서 안내가 실패한 것은 아니다(로컬 안내와 무관).
  double _totalWalked = 0;

  final Map<String, String> _bookmarks = {};

  StreamSubscription<CompassEvent>? _compassSub;

  double _dragDx = 0;
  double _dragDy = 0;
  static const double _swipeThreshold = 60.0;
  static const double _dragMaxRange = 110.0;

  // v6.10: 안내 종료 오조작 방지용. 위로 스와이프 1회는 경고만 하고,
  // 이 시각 이전에 같은 제스처가 한 번 더 들어와야 실제로 종료한다.
  DateTime? _endConfirmDeadline;
  static const Duration _endConfirmWindow = Duration(milliseconds: 1500);

  late final AnimationController _upAnimCtrl =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final AnimationController _leftAnimCtrl =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final AnimationController _rightAnimCtrl =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();

    _nav = NavigationController(
      onSpeak: _voice.speak,
      onSendBluetooth: _bluetooth.sendTurnType,
      onHaptic: () => HapticFeedback.mediumImpact(),
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      onArrived: _onArrived,
      // v6.8: 서버 누적거리 트래킹. NavigationController는 "언제" 보낼지만
      // 결정하고, 실제 HTTP 호출/에러 처리는 여기서 한다. await하지 않고
      // .then/.catchError로 비동기 흡수 — 안내 흐름을 절대 막지 않는다.
      onTrack: (sessionId, lat, lon) {
        _routeService
            .trackPosition(sessionId: sessionId, lat: lat, lon: lon)
            .then((result) {
          if (!mounted) return;
          setState(() => _totalWalked = result.totalDistanceWalked);
        }).catchError((_) {
          // 트래킹 실패는 부가 정보 손실일 뿐, 안내 자체엔 영향 없으므로
          // 조용히 무시한다 (다음 tick에서 자연히 재시도됨).
        });
      },
    );

    _voice.init();
    _loadBookmarks();

    _compassSub = FlutterCompass.events?.listen((event) {
      final h = event.heading;
      if (h == null) return;
      // 기기에 따라 -180~180으로 오는 경우가 있어 0~360으로 정규화한다.
      _nav.currentHeading = (h % 360 + 360) % 360;
    });
  }

  Future<void> _loadBookmarks() async {
    final loaded = await _bookmarkRepo.load();
    if (!mounted) return;
    setState(() {
      _bookmarks
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _saveBookmarks() => _bookmarkRepo.save(_bookmarks);

  // ── 목적지 검색 (위로 스와이프) ──
  Future<void> _onSwipeUpDestinationPipeline() async {
    await _voice.speak('목적지를 말씀하세요');
    final text = await _voice.recognizeOnce();
    if (text.isEmpty) {
      _setStatus('인식 실패');
      await _voice.speak('인식 실패. 다시 시도 하세요.');
      return;
    }

    setState(() {
      _currentDestinationQuery = text;
      _destinationName = text;
    });
    _setStatus('인식됨: $text');
    await _voice.speak('$text 로 목적지 설정');

    await _requestRoute(text);
  }

  // ── 즐겨찾기 목록 (왼쪽 스와이프) ──
  Future<void> _onSwipeLeftBookmarkPipeline() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookmarkListPage(
          bookmarks: _bookmarks,
          recognizedText: _voice.recognizedText,
          onManage: _onManageBookmark,
          onVoiceSelect: _onVoiceSelectBookmark,
          onSpeak: _voice.speak,
        ),
      ),
    );
  }

  Future<bool> _onVoiceSelectBookmark() async {
    HapticFeedback.mediumImpact();
    if (_bookmarks.isEmpty) {
      await _voice.speak('저장된 즐겨찾기가 없습니다. 화면을 길게 눌러 목적지를 추가하세요.');
      return false;
    }

    await _voice.speak('저장된 목적지 이름을 말씀하세요');
    final name = await _voice.recognizeOnce();

    if (name.isEmpty) {
      await _voice.speak('인식 실패');
      return false;
    }

    final targetKey = _findBookmarkKey(name);
    if (targetKey == null) {
      await _voice.speak('$name 목적지를 찾을 수 없습니다.');
      return false;
    }

    await _onStartBookmarkNavigation(targetKey);
    return true;
  }

  Future<void> _onManageBookmark() async {
    HapticFeedback.heavyImpact();

    await _voice.speak('즐겨찾기 추가 혹은 삭제를 말씀하세요');
    await Future.delayed(const Duration(seconds: 1)); // 잔향 방지용 1초 대기

    final action = await _voice.recognizeOnce();

    if (action.isEmpty) {
      await _voice.speak('인식 실패');
      return;
    }

    if (action.contains('추가') || action.contains('저장')) {
      await _runAddBookmarkFlow();
    } else if (action.contains('삭제') || action.contains('제거')) {
      await _runDeleteBookmarkFlow();
    } else {
      await _voice.speak('다시 한 번 말씀하세요');
    }
  }

  Future<void> _runAddBookmarkFlow() async {
    await _voice.speak('저장할 목적지의 주소나 이름을 말씀하세요');
    final address = await _voice.recognizeOnce();
    if (address.isEmpty) {
      await _voice.speak('인식 실패');
      return;
    }

    await _voice.speak('$address 을 저장할 이름을 말씀하세요.');
    final name = await _voice.recognizeOnce();
    if (name.isEmpty) {
      await _voice.speak('인식 실패');
      return;
    }

    setState(() => _bookmarks[name] = address);
    await _saveBookmarks();
    _setStatus('북마크 저장됨: $name → $address');
    await _voice.speak('$address 가 $name 으로 저장되었습니다.');
  }

  Future<void> _runDeleteBookmarkFlow() async {
    if (_bookmarks.isEmpty) {
      await _voice.speak('저장된 즐겨찾기가 없습니다.');
      return;
    }

    await _voice.speak('삭제할 즐겨찾기의 이름을 말씀해주세요.');
    final name = await _voice.recognizeOnce();
    if (name.isEmpty) {
      await _voice.speak('인식 실패');
      return;
    }

    final targetKey = _findBookmarkKey(name);
    if (targetKey == null) {
      await _voice.speak('$name 즐겨찾기를 찾을 수 없습니다');
      return;
    }

    await _voice.speak('$targetKey 삭제하시겠습니까? 삭제 또는 아니오 라고 말씀해주세요.');
    final confirm = await _voice.recognizeOnce();
    if (confirm.isEmpty) {
      await _voice.speak('인식 실패');
      return;
    }

    if (confirm.contains('삭제') || confirm.contains('제거') || confirm.contains('지워')) {
      setState(() => _bookmarks.remove(targetKey));
      await _saveBookmarks();
      _setStatus('북마크 삭제됨: $targetKey');
      await _voice.speak('$targetKey 가 삭제되었습니다.');
    } else {
      await _voice.speak('삭제 취소');
    }
  }

  String? _findBookmarkKey(String spokenName) {
    for (final key in _bookmarks.keys) {
      if (key.replaceAll(' ', '') == spokenName.replaceAll(' ', '')) {
        return key;
      }
    }
    return null;
  }

  Future<void> _onStartBookmarkNavigation(String name) async {
    final address = _bookmarks[name];
    if (address == null) return;

    setState(() {
      _currentDestinationQuery = address;
      _destinationName = name;
    });
    _setStatus('북마크 선택: $name');
    await _voice.speak('$name 로 안내를 시작합니다.');

    await _requestRoute(address, overrideDisplayName: name);
  }

  // ── 경로 요청 (RouteService에 위임, 실패 시 사용자에게 명확히 안내) ──
  //
  // v6.7: "GPS 읽는 중입니다" / "서버에 전송 중입니다"처럼 정보가치가 낮은
  // 진행상황 내레이션을 제거했다. 대신 서버 응답이 유독 느릴 때만
  // 예외적으로 "서버 응답을 기다리는 중입니다"를 1회 안내한다. 평소
  // (수 초 이내 응답)에는 조용히 기다렸다가 바로 "...경로를 받았습니다.
  // 안내를 시작합니다."로 넘어가므로, 목적지 설정 1회 흐름에서 재생되는
  // 발화 수가 최대 5개 → 2개(목적지 인식 확인 + 결과 안내)로 줄어든다.
  Future<void> _requestRoute(String destinationText, {String? overrideDisplayName}) async {
    _setStatus('경로 요청 중...');

    Timer? slowServerTimer;
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      _setStatus('서버에 요청 중...');

      // 네트워크가 유독 느릴 때만 예외적으로 안내한다. 응답이 이 시간 안에
      // 오면 타이머가 취소되어 발화 자체가 큐에 들어가지 않는다.
      slowServerTimer = Timer(const Duration(seconds: 5), () {
        _voice.speak('서버 응답을 기다리는 중입니다.');
      });

      final route = await _routeService.fetchRoute(
        destinationText: destinationText,
        currentPosition: pos,
      );
      slowServerTimer.cancel();

      _nav.loadRoute(route);
      final displayName =
      route.destinationName.isNotEmpty ? route.destinationName : (overrideDisplayName ?? destinationText);

      setState(() {
        _destinationName = displayName;
        _totalDistance = route.totalDistance;
        _totalTime = route.totalTime;
        _totalWalked = 0; // v6.8: 새 경로 시작 시 누적 도보거리 초기화
      });

      final distKm = (route.totalDistance / 1000).toStringAsFixed(1);
      final timeMin = (route.totalTime / 60).ceil();
      _setStatus('목적지: $displayName · ${distKm}km · ${timeMin}분');
      await _voice.speak('$displayName 까지 ${distKm}킬로미터, 약 ${timeMin}분 경로를 받았습니다');

      if (route.waypoints.isNotEmpty || route.hasDestinationCoordinate) {
        _startNavigating();
      }
    } on RouteParseException catch (e) {
      // 서버 응답 형식이 깨진 경우 — 원본처럼 조용히 0으로 넘어가지 않고 명확히 실패를 알림
      slowServerTimer?.cancel();
      _setStatus('경로 데이터 오류: ${e.message}');
      await _voice.speak('경로 정보를 처리하는 중 오류가 발생했습니다. 다시 시도해 주세요.');
    } catch (e) {
      slowServerTimer?.cancel();
      _setStatus('오류: $e');
      await _voice.speak('오류가 발생했습니다.');
    }
  }

  // v6.7: "길 안내를 시작합니다" 발화 제거. 직전 _requestRoute()의
  // "...경로를 받았습니다. 안내를 시작합니다."와 같은 정보를 다시
  // 말하는 중복 발화였다. 상태 갱신(_navigating, _setStatus, _nav.start())만
  // 남긴다.
  void _startNavigating() {
    HapticFeedback.mediumImpact();
    setState(() => _navigating = true);
    _setStatus('길 안내 시작...');
    _nav.start();
  }

  Future<void> _onResearchRoute() async {
    HapticFeedback.mediumImpact();
    if (_currentDestinationQuery.isEmpty) return;
    await _voice.speak('경로를 재검색합니다.');
    _nav.stop();
    await _requestRoute(_currentDestinationQuery, overrideDisplayName: _destinationName);
  }

  void _onArrived() {
    setState(() {
      _navigating = false;
      _destinationName = '';
      _currentDestinationQuery = '';
      _totalDistance = 0;
      _totalTime = 0;
      _totalWalked = 0; // v6.8
      _statusText = '준비됨';
    });
  }

  Future<void> _connectBluetooth() async {
    HapticFeedback.mediumImpact();
    await _voice.speak('블루투스 기기 검색');
    try {
      final devices = await _bluetooth.getBondedDevices();
      if (!mounted) return;

      final selected = await showDialog<BluetoothDevice>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('블루투스 기기 선택', style: TextStyle(color: Colors.black)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: devices
                  .map((d) => ListTile(
                leading: const Icon(Icons.bluetooth, color: Colors.blue),
                title: Text(d.name ?? '알 수 없음', style: const TextStyle(color: Colors.black)),
                subtitle: Text(d.address, style: const TextStyle(color: Colors.black54)),
                onTap: () => Navigator.pop(context, d),
              ))
                  .toList(),
            ),
          ),
        ),
      );

      if (selected == null) return;

      final name = await _bluetooth.connect(selected);
      setState(() {});
      _setStatus('블루투스 연결: $name');
      await _voice.speak('블루투스 연결 완료.');
    } catch (e) {
      _setStatus('블루투스 연결 실패');
      await _voice.speak('블루투스 연결 실패.');
    }
  }

  void _setStatus(String msg) {
    setState(() => _statusText = msg);
  }

  // ── 제스처 처리 ──
  void _resetDrag() {
    _dragDx = 0;
    _dragDy = 0;
  }

  void _onIdlePanUpdate(DragUpdateDetails details) {
    _dragDx += details.delta.dx;
    _dragDy += details.delta.dy;

    double upT = 0;
    double leftT = 0;
    double rightT = 0;

    if (_dragDx.abs() > _dragDy.abs()) {
      final t = (_dragDx.abs() / _dragMaxRange).clamp(0.0, 1.0);
      if (_dragDx < 0) {
        leftT = t;
      } else {
        rightT = t;
      }
    } else if (_dragDy < 0) {
      upT = ((-_dragDy) / _dragMaxRange).clamp(0.0, 1.0);
    }

    _upAnimCtrl.value = upT;
    _leftAnimCtrl.value = leftT;
    _rightAnimCtrl.value = rightT;
  }

  void _handleIdleSwipeEnd() {
    _SwipeDir dir = _SwipeDir.none;
    if (_dragDx.abs() >= _swipeThreshold || _dragDy.abs() >= _swipeThreshold) {
      if (_dragDx.abs() > _dragDy.abs()) {
        dir = _dragDx < 0 ? _SwipeDir.left : _SwipeDir.right;
      } else if (_dragDy < 0) {
        dir = _SwipeDir.up;
      }
    }

    _upAnimCtrl.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    _leftAnimCtrl.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    _rightAnimCtrl.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);

    switch (dir) {
      case _SwipeDir.up:
        HapticFeedback.mediumImpact();
        _onSwipeUpDestinationPipeline();
        break;
      case _SwipeDir.left:
        HapticFeedback.mediumImpact();
        _onSwipeLeftBookmarkPipeline();
        break;
      case _SwipeDir.right:
        HapticFeedback.mediumImpact();
        _connectBluetooth();
        break;
      default:
        break;
    }
  }

  // v6.10: 위로 스와이프(종료)는 오조작 방지를 위해 2단계 확인을 거친다.
  // - 1차 스와이프: 아직 종료하지 않고 "한 번 더" 안내 + 확인 창(1.5초) 시작
  // - 확인 창 안에 2차 스와이프가 들어오면 그때 실제로 종료
  // - 확인 창을 넘기면 자동으로 무효화되어, 다음 위로 스와이프는 다시 1차로 취급
  // 재탐색(아래로 스와이프)은 기존과 동일하게 즉시 실행하며, 진행 중이던
  // 종료 확인 상태는 초기화한다(다른 제스처가 끼어들면 확인 흐름을 리셋).
  void _handleNavSwipeEnd() {
    if (_dragDy.abs() > _dragDx.abs() && _dragDy.abs() >= _swipeThreshold) {
      if (_dragDy > 0) {
        _endConfirmDeadline = null;
        _onResearchRoute();
        return;
      }

      final now = DateTime.now();
      final awaitingConfirm =
          _endConfirmDeadline != null && now.isBefore(_endConfirmDeadline!);

      if (awaitingConfirm) {
        _endConfirmDeadline = null;
        HapticFeedback.heavyImpact();
        _voice.speak('안내를 종료합니다');
        _nav.reset();
        _onArrived();
      } else {
        _endConfirmDeadline = now.add(_endConfirmWindow);
        HapticFeedback.selectionClick();
        _voice.speak('종료하려면 한 번 더 위로 스와이프하세요');
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _compassSub?.cancel();
    _nav.dispose();
    _bluetooth.dispose();
    _voice.dispose();
    _upAnimCtrl.dispose();
    _leftAnimCtrl.dispose();
    _rightAnimCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: _navigating ? _buildNavigatingView() : _buildIdleView(),
      ),
    );
  }

  // v6.9: 안내 화면에서는 "지금 할 일"인 방향 아이콘만 남긴다.
  // 목적지 배지 / 총거리·남은거리·누적거리 배너는 안내 중 화면에서 뺐다
  // (음성으로 이미 안내되고, 대기 화면에서는 여전히 확인 가능).
  Widget _buildNavigatingView() {
    return Column(
      children: [
        _buildStatusBar(),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _resetDrag(),
            onPanUpdate: (d) {
              _dragDx += d.delta.dx;
              _dragDy += d.delta.dy;
            },
            onPanEnd: (_) => _handleNavSwipeEnd(),
            child: Stack(
              children: [
                _buildTurnArrow(),
                NavDebugPanel(nav: _nav),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // v6.9: 방향 아이콘 + 남은 거리만 표시. 목적지명 / 웨이포인트 설명
  // 말풍선 / 경유지 카운터 / 스와이프 힌트 문구는 제거 — "지금 할 일"이
  // 아닌 정보는 음성 안내로만 전달한다.
  //
  // currentTurnDisplay가 null이면(경로 로드 직후, 첫 방향이 아직
  // 계산되지 않은 상태 — GPS 워밍업/약신호 구간 포함) "직진"으로
  // 단정하지 않고 중립적인 준비 화면을 보여준다.
  Widget _buildTurnArrow() {
    final turnType = _nav.currentTurnDisplay;

    if (turnType == null) {
      return Container(
        color: Colors.grey[50],
        width: double.infinity,
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(strokeWidth: 4, color: Colors.grey[400]),
            ),
            const SizedBox(height: 16),
            Text(
              '안내를 준비하고 있습니다',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    final info = _turnArrowInfo(turnType);
    final fgColor = info['fgColor'] as Color;
    return Container(
      color: info['bgColor'] as Color,
      width: double.infinity,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(info['icon'] as IconData, size: 160, color: fgColor),
          const SizedBox(height: 12),
          Text(
            info['label'] as String,
            style: TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: fgColor),
          ),
          if (_nav.distToNext > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${_nav.distToNext.toStringAsFixed(0)} m',
              style: TextStyle(fontSize: 28, color: fgColor.withOpacity(0.85)),
            ),
          ],
        ],
      ),
    );
  }

  Map<String, dynamic> _turnArrowInfo(String turnType) {
    switch (turnType) {
      case 'LEFT':
        return {'icon': Icons.turn_left, 'label': '좌회전', 'bgColor': Colors.blue[50]!, 'fgColor': Colors.blue[800]!};
      case 'RIGHT':
        return {'icon': Icons.turn_right, 'label': '우회전', 'bgColor': Colors.green[50]!, 'fgColor': Colors.green[800]!};
      case 'UTURN':
        return {'icon': Icons.u_turn_left, 'label': '유턴', 'bgColor': Colors.orange[50]!, 'fgColor': Colors.orange[800]!};
      case 'ARRIVED':
        return {'icon': Icons.flag, 'label': '도착!', 'bgColor': Colors.yellow[50]!, 'fgColor': Colors.yellow[800]!};
      default:
        return {'icon': Icons.arrow_upward, 'label': '직진', 'bgColor': Colors.grey[50]!, 'fgColor': Colors.grey[800]!};
    }
  }

  Widget _buildIdleView() {
    return Column(
      children: [
        _buildStatusBar(),
        // v6.9: 대기 화면에서는 방금 받은 경로 요약(총거리/시간)을 여전히
        // 참고 정보로 보여준다 — "지금 할 일"이 아니라 안내 시작 전
        // 확인용이므로 대기 화면에 두는 게 자연스럽다.
        if (_totalDistance > 0) _buildRouteInfoBanner(),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _resetDrag(),
            onPanUpdate: _onIdlePanUpdate,
            onPanEnd: (_) => _handleIdleSwipeEnd(),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: const Alignment(0, -0.2),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _voice.isListening,
                    builder: (context, listening, _) => _buildDirCircle(
                      controller: _upAnimCtrl,
                      icon: listening ? Icons.mic : Icons.mic_none,
                      color: Colors.black87,
                      dir: const Offset(0, -1),
                    ),
                  ),
                ),
                Align(
                  alignment: const Alignment(-0.5, 0.15),
                  child: _buildDirCircle(
                    controller: _leftAnimCtrl,
                    icon: Icons.star_outline,
                    color: Colors.redAccent,
                    dir: const Offset(-1, 0),
                  ),
                ),
                Align(
                  alignment: const Alignment(0.5, 0.15),
                  child: _buildDirCircle(
                    controller: _rightAnimCtrl,
                    icon: _bluetooth.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                    color: Colors.blueAccent,
                    dir: const Offset(1, 0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirCircle({
    required AnimationController controller,
    required IconData icon,
    required Color color,
    required Offset dir,
  }) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final t = controller.value;
        return Transform.translate(
          offset: dir * (34 * t),
          child: Transform.scale(
            scale: 1 + 0.22 * t,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: color, width: 5),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Icon(icon, color: color, size: 44),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRouteInfoBanner() {
    final remainStr = _navigating && _nav.distToDestination > 0
        ? '남은 거리 ${(_nav.distToDestination / 1000).toStringAsFixed(2)} km'
        : '총 ${(_totalDistance / 1000).toStringAsFixed(1)} km · 약 ${(_totalTime / 60).ceil()}분';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.indigo[50],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_destinationName.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.place, size: 15, color: Colors.indigo),
                const SizedBox(width: 4),
                Text('목적지: $_destinationName', style: const TextStyle(color: Colors.indigo, fontSize: 14, fontWeight: FontWeight.bold)),
              ],
            ),
          if (_destinationName.isNotEmpty) const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_navigating ? Icons.near_me : Icons.route, size: 15, color: Colors.indigo),
              const SizedBox(width: 4),
              Text(remainStr, style: const TextStyle(color: Colors.indigo, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          // v6.8: 서버 트래킹이 값을 준 경우에만 표시. 세션ID가 없거나
          // 트래킹 호출이 아직 한 번도 성공하지 않았으면(_totalWalked == 0)
          // 조용히 숨겨서, "걸은 거리 0m"처럼 오해를 주는 표시를 막는다.
          if (_navigating && _totalWalked > 0) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.directions_walk, size: 15, color: Colors.indigo),
                const SizedBox(width: 4),
                Text(
                  '지금까지 걸은 거리 ${_totalWalked.toStringAsFixed(0)} m',
                  style: const TextStyle(color: Colors.indigo, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.grey[100],
      child: Row(
        children: [
          Icon(
            _bluetooth.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _bluetooth.isConnected ? Colors.blue : Colors.grey,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text('|', style: TextStyle(color: Colors.grey[400])),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_statusText, style: const TextStyle(color: Colors.black87, fontSize: 13), overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}