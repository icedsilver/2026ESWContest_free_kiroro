import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 즐겨찾기(북마크) 관리 화면.
///
/// 음성 인식 결과 표시는 이제 [recognizedText](VoiceService.recognizedText)를
/// 구독하는 방식으로 바뀌었다. 이전에는 onManage/onVoiceSelect가
/// `void Function(String)` 콜백을 받아서 인식될 때마다 그 함수를 호출해
/// 화면 상태를 갱신했는데, 이제는 텍스트가 갱신되면 ValueListenableBuilder가
/// 자동으로 다시 그려주므로 콜백을 따로 넘길 필요가 없다.
///
/// TTS는 이 화면에서 별도 인스턴스를 만들지 않고, MainScreen이 소유한
/// VoiceService의 speak를 [onSpeak]로 전달받아 그대로 쓴다. 화면마다
/// 별도 FlutterTts 인스턴스를 만들면 발화가 서로 겹치거나 끊길 수 있어서,
/// 앱 전체가 하나의 TTS 인스턴스와 하나의 발화 큐를 공유하도록 통일했다.
class BookmarkListPage extends StatefulWidget {
  final Map<String, String> bookmarks;
  final ValueListenable<String> recognizedText;
  final Future<void> Function() onManage;
  final Future<bool> Function() onVoiceSelect;
  final Future<void> Function(String text, {bool urgent}) onSpeak;

  const BookmarkListPage({
    super.key,
    required this.bookmarks,
    required this.recognizedText,
    required this.onManage,
    required this.onVoiceSelect,
    required this.onSpeak,
  });

  @override
  State<BookmarkListPage> createState() => _BookmarkListPageState();
}

class _BookmarkListPageState extends State<BookmarkListPage> {
  bool _busy = false;

  final PageController _pageController = PageController();
  int _currentPage = 0;
  final int _itemsPerPage = 4; // 한 페이지에 보여줄 즐겨찾기 개수

  @override
  void dispose() {
    _pageController.dispose();
    // TTS는 이 화면 소유가 아니므로(MainScreen의 VoiceService 공유) 여기서
    // stop()하지 않는다. 예를 들어 페이지 전환 발화가 끝나기 전에 사용자가
    // 아래로 스와이프해 화면을 나가더라도, 공유 큐에서 발화가 자연스럽게
    // 이어지도록 둔다.
    super.dispose();
  }

  // 길게 누르기: 추가/삭제 음성 인식 처리
  Future<void> _handleManage() async {
    if (_busy) return;
    setState(() => _busy = true);

    await widget.onManage();

    if (mounted) setState(() => _busy = false);
  }

  // 짧게 탭: 목적지 선택 음성 인식 처리
  Future<void> _handleVoiceSelect() async {
    if (_busy) return;
    setState(() => _busy = true);

    final success = await widget.onVoiceSelect();

    if (mounted) {
      setState(() => _busy = false);
      if (success) {
        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) Navigator.of(context).pop();
      }
    }
  }

  // 화면 전체 영역에서 아래로 쓸어내리면 메인으로 이동
  void _handleVerticalSwipe(DragEndDetails details) {
    if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
      Navigator.of(context).pop();
    }
  }

  Widget _buildPromptBox() {
    return ValueListenableBuilder<String>(
      valueListenable: widget.recognizedText,
      builder: (context, text, _) {
        final hasText = text.isNotEmpty;
        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 80),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: hasText ? Colors.green[50] : Colors.grey[50],
            border: Border.all(
              color: hasText ? Colors.green : Colors.grey[300]!,
              width: 2.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: hasText ? Colors.green[800] : Colors.black87,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.bookmarks.keys.toList();

    int pageCount = (keys.length / _itemsPerPage).ceil();
    if (pageCount == 0) pageCount = 1;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragEnd: _handleVerticalSwipe,
          onTap: _handleVoiceSelect,
          onLongPress: _handleManage,
          child: Column(
            children: [
              const SizedBox(height: 16),
              _buildPromptBox(),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    border: Border.all(color: Colors.redAccent, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() => _currentPage = index);
                      widget.onSpeak('${index + 1} 페이지입니다.');
                    },
                    itemCount: pageCount,
                    itemBuilder: (context, pageIndex) {
                      int startIndex = pageIndex * _itemsPerPage;
                      int endIndex = startIndex + _itemsPerPage;
                      if (endIndex > keys.length) endIndex = keys.length;

                      final pageKeys = keys.isEmpty ? <String>[] : keys.sublist(startIndex, endIndex);

                      if (pageKeys.isEmpty) {
                        return Center(
                          child: Text(
                            '저장된 목적지가 없습니다.\n화면을 길게 눌러 추가해 보세요.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[600], fontSize: 16),
                          ),
                        );
                      }

                      return Column(
                        children: pageKeys.map((key) {
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            elevation: 1,
                            color: Colors.white,
                            child: ListTile(
                              leading: const Icon(Icons.star, color: Colors.redAccent),
                              title: Text(
                                key,
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(widget.bookmarks[key] ?? ''),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(pageCount, (index) {
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      height: 10,
                      width: _currentPage == index ? 24 : 10,
                      decoration: BoxDecoration(
                        color: _currentPage == index ? Colors.redAccent : Colors.grey[400],
                        borderRadius: BorderRadius.circular(5),
                      ),
                    );
                  }),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: CircularProgressIndicator(strokeWidth: 3.0, color: Colors.redAccent),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Text(
                  '⬇️ 아무 데나 아래로 쓸어내려 나가기',
                  style: TextStyle(color: Colors.grey[500], fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}