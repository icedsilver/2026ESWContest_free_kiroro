import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 즐겨찾기(목적지 북마크)의 영속화를 전담하는 저장소.
/// SharedPreferences 세부 구현을 다른 계층으로부터 감춘다.
class BookmarkRepository {
  static const _storageKey = 'saved_bookmarks';

  Future<Map<String, String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return {};

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      // 저장된 데이터가 손상된 경우, 앱을 죽이지 않고 빈 상태로 시작
      return {};
    }
  }

  Future<void> save(Map<String, String> bookmarks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(bookmarks));
  }
}