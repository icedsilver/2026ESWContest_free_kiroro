import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// 큐에 대기 중인(또는 재생 중인) 한 건의 발화 요청.
class _SpeechRequest {
  final String text;
  final Completer<void> completer;
  final String? category;
  final bool critical;
  _SpeechRequest(this.text, this.completer, {this.category, this.critical = false});
}

/// TTS(음성 출력)와 STT(음성 인식)를 함께 다루는 서비스.
///
/// [recognizedText]와 [isListening]은 ValueNotifier로 노출된다.
/// 화면은 콜백을 전달받을 필요 없이 ValueListenableBuilder로
/// 이 값들을 구독하기만 하면 되고, recognizeOnce()가 끝나면
/// recognizedText가 자동으로 갱신된다.
///
/// TTS는 앱 전체에서 이 인스턴스 하나만 사용한다 (다른 화면이 별도
/// FlutterTts를 새로 만들지 말 것). 여러 인스턴스가 동시에 존재하면
/// 발화가 서로 겹치거나 끊기는 문제가 생기고, 특히 이 앱처럼 음성이
/// 유일한 정보 전달 수단인 경우 치명적인 혼란으로 이어질 수 있다.
///
/// 발화 우선순위:
/// - 일반 발화(speak, urgent: false = 기본값): 큐에 쌓여 순서대로 재생된다.
///   턴바이턴 안내, 프롬프트 등 "듣는 도중 끊기면 안 되는" 대부분의 안내가 해당.
/// - 긴급 발화(speak(..., urgent: true)): 대기 중인 큐를 비우고, 현재
///   재생 중인 발화도 즉시 중단한 뒤 바로 재생된다. 도착 안내처럼
///   최신성이 정확성보다 중요한 경우에만 사용한다.
///
/// Android(TextToSpeech)는 기본이 QUEUE_FLUSH(새 발화가 기존 발화를 끊음),
/// iOS(AVSpeechSynthesizer)는 기본이 큐잉(끊지 않고 순서대로 재생)이라
/// 플랫폼별 기본 동작이 서로 다르다. 이 큐를 Dart 쪽에서 직접 관리해서
/// 두 플랫폼에서 항상 동일하게 동작하도록 만든다.
///
/// "안내 후 인식(prompt → listen)" 흐름 재진입 보호:
/// 화면에서 speak()와 recognizeOnce()를 따로따로 호출하면, 사용자가
/// 짧은 시간에 두 번 입력을 트리거했을 때(예: 스와이프 두 번) 두 흐름이
/// 동시에 진행되어 첫 번째 인식 도중에 두 번째 안내 음성이 스피커로
/// 나오고, 그 소리가 마이크로 들어가 인식이 깨지는 문제가 생긴다.
/// 이를 막기 위해 화면에서는 speak()+recognizeOnce()를 따로 부르지 말고
/// [askAndRecognize]를 사용해야 한다. 재진입이 감지되면 이전 흐름의
/// TTS/STT를 모두 명시적으로 취소한 뒤 최신 요청으로 새로 시작한다.
///
/// v6.7: TTS 재생 타임아웃 방어 추가.
/// init()에서 앱 시작 시 가장 먼저 재생되는 "키로로 앱이 실행되었습니다."는
/// 큐의 맨 앞을 차지한다. 만약 이 발화(혹은 그 이후 어떤 발화든)가 TTS
/// 플러그인 쪽 문제로 완료 콜백을 영영 돌려주지 않으면, awaitSpeakCompletion
/// 특성상 _processQueue()의 await가 끝나지 않아 이후의 모든 non-urgent
/// 발화가 영구히 막히는 치명적인 상황이 생길 수 있다. 이를 막기 위해
/// _tts.speak() 호출을 일정 시간으로 제한하고, 시간을 넘기거나 예외가
/// 나도 큐가 다음 요청으로 반드시 넘어가도록 처리한다.
class VoiceService {
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();

  /// 가장 최근에 인식된 음성 텍스트. recognizeOnce()가 완료될 때마다 갱신됨.
  final ValueNotifier<String> recognizedText = ValueNotifier('');

  /// 현재 음성 인식 중인지 여부.
  final ValueNotifier<bool> isListening = ValueNotifier(false);

  final List<_SpeechRequest> _queue = [];
  _SpeechRequest? _current;

  /// "안내 후 인식" 흐름이 현재 진행 중인지 여부.
  /// askAndRecognize() 호출 시 재진입 여부를 판단하는 데 쓰인다.
  bool _recognitionActive = false;

  /// 발화 1건이 이 시간을 넘기면 TTS 플러그인이 응답하지 않는 것으로
  /// 간주하고 강제로 다음 큐로 넘어간다. 일반적인 안내 문장은 몇 초
  /// 안에 끝나므로, 15초는 충분히 여유 있으면서도 "영구히 막히는" 최악의
  /// 상황은 확실히 방지하는 값이다.
  static const Duration _speakTimeout = Duration(seconds: 15);
  static const int _maxNonCriticalQueueLength = 4;

  Future<void> init() async {
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.40);
    await _tts.awaitSpeakCompletion(true);
    await speak('키로로 앱이 실행되었습니다.');
  }

  /// 텍스트를 발화한다.
  ///
  /// [urgent]가 false(기본값)면 큐에 쌓여 이전 발화가 끝난 뒤 순서대로
  /// 재생된다. [urgent]가 true면 대기 중인 다른 발화를 모두 취소하고,
  /// 현재 재생 중인 발화도 즉시 끊은 뒤 바로 재생된다.
  ///
  /// 반환되는 Future는 이 발화가 (정상 완료든, 다른 긴급 발화에 의해
  /// 중간에 끊기든, 타임아웃으로 강제 종료되든) 재생 슬롯을 벗어난
  /// 시점에 완료된다. 즉 urgent 발화에 의해 끊긴 일반 발화를 기다리던
  /// 호출자도 무한정 멈춰있지 않는다.
  Future<void> speak(String text, {bool urgent = false, String? category, bool critical = false,}) {
    final completer = Completer<void>();
    final request = _SpeechRequest(text, completer, category: category, critical: critical);

    if (urgent) {
      // 대기 중이던 일반 발화들은 재생되지 못하고 취소됨 — 호출자가
      // 무한 대기하지 않도록 완료 처리는 해준다.
      for (final pending in _queue) {
        if (!pending.completer.isCompleted) pending.completer.complete();
      }
      _queue.clear();

      if (_current != null) {
        _tts.stop();
        if (!_current!.completer.isCompleted) _current!.completer.complete();
        _current = null;
      }

      _queue.insert(0, request);
    } else {
      if(category != null){
        _queue.removeWhere((r) {
          if(r.category == category){
            if(!r.completer.isCompleted) r.completer.complete();
            return true;
          }
          return false;
        });
      }
      _queue.add(request);

      while(_queue.where((r) => !r.critical).length > _maxNonCriticalQueueLength){
        final idx = _queue.indexWhere((r) => !r.critical);
        if(idx == -1) break;
        final dropped = _queue.removeAt(idx);
        if(!dropped.completer.isCompleted) dropped.completer.complete();
      }
    }

    _processQueue();
    return completer.future;
  }

  Future<void> _processQueue() async {
    if (_current != null) return; // 이미 재생 중이면 이번 호출은 대기
    if (_queue.isEmpty) return;

    final request = _queue.removeAt(0);
    _current = request;

    // TTS 플러그인이 완료 콜백을 영영 돌려주지 않는 경우를 대비한 방어
    // 코드. 타임아웃이 나거나 예외가 발생해도 큐는 반드시 다음으로
    // 넘어간다 — 여기서 멈추면 이후 모든 non-urgent 발화가 영구히 막힌다.
    try {
      await _tts.speak(request.text).timeout(_speakTimeout);
    } catch (_) {
      // 타임아웃 또는 플러그인 오류 — 이 발화는 포기하고 계속 진행.
    }

    // urgent 발화가 중간에 끼어들어 _current가 이미 교체/초기화됐다면
    // (stop()이 여기서 뒤늦게 리턴되는 경우) 이 요청은 이미 처리된
    // 것이므로 다시 완료 처리하거나 다음 큐를 건드리지 않는다.
    if (identical(_current, request)) {
      if (!request.completer.isCompleted) request.completer.complete();
      _current = null;
      _processQueue();
    }
  }

  /// 안내 음성을 말한 뒤 곧바로 한 번 음성 인식을 수행하는 원자적 흐름.
  ///
  /// 화면에서 "prompt 발화 → 인식"이 필요할 때는 speak()와
  /// recognizeOnce()를 따로 호출하지 말고 반드시 이 메서드를 써야 한다.
  /// 이미 같은 흐름이 진행 중인 상태(재진입, 예: 스와이프 두 번)에서
  /// 다시 호출되면, 이전 흐름의 TTS 재생과 STT 리스닝을 모두 명시적으로
  /// 취소한 뒤 최신 prompt로 새로 시작한다.
  Future<String> askAndRecognize(String prompt) async {
    if (_recognitionActive) {
      await _cancelOngoingPromptAndRecognition();
    }
    _recognitionActive = true;
    try {
      // urgent: true로 큐/재생 중인 이전 발화를 확실히 정리하고 재생.
      // (아래 _cancelOngoingPromptAndRecognition에서 이미 한 번 정리하지만,
      // urgent 발화 자체의 안전장치이므로 이중 방어 차원에서 유지한다.)
      await speak(prompt, urgent: true);
      return await recognizeOnce();
    } finally {
      _recognitionActive = false;
    }
  }

  /// 진행 중이던 "안내 후 인식" 흐름의 TTS 재생과 STT 리스닝을
  /// 명시적으로 모두 취소한다. askAndRecognize()의 재진입 시에만 호출됨.
  Future<void> _cancelOngoingPromptAndRecognition() async {
    // STT 정지
    if (isListening.value) {
      await _speech.stop();
      isListening.value = false;
    }

    // TTS 정지 — speak(urgent: true)의 부수효과에만 의존하지 않고
    // 여기서 직접 큐/재생 중인 발화를 정리한다.
    _tts.stop();
    for (final pending in _queue) {
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
    _queue.clear();
    if (_current != null) {
      if (!_current!.completer.isCompleted) _current!.completer.complete();
      _current = null;
    }
  }

  /// 한 번의 음성 인식을 수행하고 인식된 텍스트를 반환한다.
  /// 실패/타임아웃 시 빈 문자열을 반환한다.
  /// 완료 시 [recognizedText]가 자동으로 갱신되므로, 호출자는
  /// 화면에 결과를 띄우기 위해 별도 콜백을 넘길 필요가 없다.
  ///
  /// 주의: "prompt 발화 후 인식" 흐름이 필요하면 이 메서드를 단독으로
  /// 부르지 말고 [askAndRecognize]를 사용할 것. 이 메서드를 직접 호출할
  /// 경우에도, 이미 리스닝 중이라면 안전하게 이전 리스닝을 정지하고
  /// 새로 시작한다.
  Future<String> recognizeOnce() async {
    if (isListening.value) {
      await _speech.stop();
      isListening.value = false;
    }

    HapticFeedback.mediumImpact();
    recognizedText.value = ''; // 새 인식 시작 시 이전 결과 초기화
    final completer = Completer<String>();

    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (!completer.isCompleted) completer.complete('');
          });
          isListening.value = false;
        }
      },
    );

    if (!available) {
      await speak('음성 인식을 사용할 수 없습니다.');
      return '';
    }

    isListening.value = true;

    await _speech.listen(
      onResult: (result) {
        if (result.finalResult && !completer.isCompleted) {
          isListening.value = false;
          completer.complete(result.recognizedWords);
        }
      },
      localeId: 'ko_KR',
    );

    final text = await completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => '',
    );
    isListening.value = false;
    recognizedText.value = text;
    return text;
  }

  void dispose() {
    _tts.stop();
    _speech.stop();
    for (final pending in _queue) {
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
    _queue.clear();
    if (_current != null && !_current!.completer.isCompleted) {
      _current!.completer.complete();
    }
    _current = null;
    recognizedText.dispose();
    isListening.dispose();
  }
}