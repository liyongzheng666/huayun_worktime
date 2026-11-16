import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hikiot_worktime/services/attendance_photo_loader.dart';

final photoPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('并发及再次查看复用成功解码的图片，每张图请求结束关闭连接', () async {
    var requests = 0;
    var closed = 0;
    final pending = Completer<http.Response>();
    final loader = AttendancePhotoLoader(
      createClient: () => _TrackedClient((_) {
        requests++;
        return pending.future;
      }, () => closed++),
    );
    final first = loader.load('https://example.test/in');
    final second = loader.load('https://example.test/in');
    pending.complete(http.Response.bytes(photoPng, 200));
    final results = await Future.wait([first, second]);
    expect(results.first, photoPng);
    expect(await loader.load('https://example.test/in'), photoPng);
    expect(requests, 1);
    expect(closed, 1);
  });

  test('403不进入缓存；用户重试可重新下载有效图片', () async {
    var requests = 0;
    final loader = AttendancePhotoLoader(
      createClient: () => MockClient((_) async {
        requests++;
        return requests == 1
            ? http.Response('expired', 403)
            : http.Response.bytes(photoPng, 200);
      }),
    );
    await expectLater(
      loader.load('https://example.test/out'),
      throwsA(
        isA<AttendancePhotoException>().having(
          (e) => e.refreshAddress,
          '需要刷新地址',
          true,
        ),
      ),
    );
    expect(
      await loader.load('https://example.test/out', retry: true),
      photoPng,
    );
    expect(requests, 2);
  });

  test('HTTP200错误文本不能当图片缓存', () async {
    var requests = 0;
    final loader = AttendancePhotoLoader(
      createClient: () => MockClient((_) async {
        requests++;
        return http.Response('{"code":"expired"}', 200);
      }),
    );
    for (var i = 0; i < 2; i++) {
      await expectLater(
        loader.load('https://example.test/out'),
        throwsA(isA<AttendancePhotoException>()),
      );
    }
    expect(requests, 2);
  });
}
