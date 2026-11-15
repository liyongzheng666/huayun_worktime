import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants/constants.dart';
import '../core/error/exceptions.dart';
import 'monthly_attendance_aggregator.dart';
import 'storage_service.dart';

class HikiotApiClient {
  static const String baseUrl = ApiConstants.baseUrl;
  static const String accountDetailUrl = ApiConstants.accountDetailUrl;
  static const String dailyAttendanceUrl = ApiConstants.dailyAttendanceUrl;

  final http.Client _httpClient;
  String? _token;
  int _sessionGeneration = 0;
  final Map<(int, String, String), Future<http.Response>> _dailyInFlight = {};

  HikiotApiClient({String? token, http.Client? httpClient})
    : _token = token,
      _httpClient = httpClient ?? http.Client();

  void setToken(String token) {
    if (_token != token) _invalidateReads();
    _token = token;
  }

  void _invalidateReads() {
    _sessionGeneration++;
    _dailyInFlight.clear();
  }

  Map<String, String> _getHeaders({bool useBearer = false}) {
    final headers = {
      'User-Agent': ApiConstants.mobileUserAgent,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Content-Type': 'application/json',
      'appNo': ApiConstants.appNo,
      'terminal': ApiConstants.terminalMobile,
      'versionCode': ApiConstants.versionCode,
    };

    if (_token != null) {
      if (useBearer) {
        headers['Authorization'] = 'Bearer $_token';
      }
      headers['token'] = _token!;
      headers['www_token'] = _token!;
    }

    return headers;
  }

  Future<Map<String, dynamic>?> getAccountDetail() async {
    final response = await _send(
      () => _httpClient.get(
        Uri.parse(accountDetailUrl),
        headers: _getHeaders(useBearer: true),
      ),
    );
    final json = _decodeResponse(response);
    final data = _readBusinessData(json);
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw const ParseException('账号详情数据格式错误');
  }

  Future<bool> changeTeam(String teamNo) async {
    _invalidateReads();
    final response = await _send(
      () => _httpClient.post(
        Uri.parse(ApiConstants.changeTeamUrl),
        headers: _getHeaders(useBearer: true),
        body: jsonEncode({'teamNo': teamNo, 'terminal': 2}),
      ),
    );
    final json = _decodeResponse(response);
    _readBusinessData(json, allowMissingData: true);
    _invalidateReads();
    return true;
  }

  Future<bool> logout() async {
    _invalidateReads();
    final response = await _send(
      () => _httpClient.post(
        Uri.parse(ApiConstants.logoutUrl),
        headers: _getHeaders(useBearer: true),
      ),
    );
    final json = _decodeResponse(response);
    _readBusinessData(json, allowMissingData: true);
    return true;
  }

  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async {
    final url = '$dailyAttendanceUrl?date=$date&ID=myStatic';
    final generation = _sessionGeneration;
    final key = (generation, date, personNo);
    final request = _dailyInFlight.putIfAbsent(
      key,
      () => _send(
        () => _httpClient.get(
          Uri.parse(url),
          headers: _getHeaders(useBearer: true),
        ),
      ),
    );
    final http.Response response;
    try {
      response = await request;
    } finally {
      if (identical(_dailyInFlight[key], request)) _dailyInFlight.remove(key);
    }
    if (generation != _sessionGeneration) {
      throw const NetworkException('账号或团队已变化，请重新读取考勤');
    }
    // 只合并在途HTTP读取，各调用者独立解析，避免修改共享Map污染其他页面。
    final json = _decodeResponse(response);
    final data = _readBusinessData(json);
    if (data == null) return null;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw const ParseException('每日考勤数据格式错误');
  }

  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async {
    try {
      return await MonthlyAttendanceAggregator(
        month: month,
        personNo: personNo,
        loadDailyAttendance: getDailyAttendance,
      ).aggregate();
    } on TokenExpiredException {
      rethrow;
    } on ValidationException {
      rethrow;
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on AppException {
      rethrow;
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const TokenExpiredException('未授权访问');
    }

    if (response.statusCode != 200) {
      throw ApiException.fromResponse(response.statusCode, null);
    }

    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      throw const ParseException('API 响应不是 JSON 对象');
    } on FormatException catch (e) {
      throw ParseException.fromError(e);
    }
  }

  dynamic _readBusinessData(
    Map<String, dynamic> json, {
    bool allowMissingData = false,
  }) {
    final code = json['code'];
    if (code == AppConstants.apiCodeSuccess) {
      if (allowMissingData) return json['data'];
      return json.containsKey('data') ? json['data'] : null;
    }

    if (code == AppConstants.apiCodeTokenExpired ||
        code == 401 ||
        code == 403) {
      throw TokenExpiredException(_readMessage(json, fallback: '登录状态已失效'));
    }

    throw ApiException(
      _readMessage(json, fallback: 'API 请求失败'),
      code: code?.toString(),
    );
  }

  String _readMessage(Map<String, dynamic> json, {required String fallback}) {
    final message = json['message'] ?? json['msg'];
    return message is String && message.isNotEmpty ? message : fallback;
  }

  static Future<String?> loadToken() async {
    return StorageService().loadToken();
  }

  static Future<void> saveToken(String token) async {
    await StorageService().saveToken(token);
  }
}
