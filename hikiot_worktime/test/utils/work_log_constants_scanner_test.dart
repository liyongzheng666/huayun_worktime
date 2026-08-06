import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_constants_scanner.dart';

void main() {
  const projectName = '面向比亚迪公司汽车造型设计场景的工业造型设计软件攻关项目-自筹';

  final script = WorkLogConstantsScanner.build(
    captureStoreName: '__store',
    preferredProjectName: projectName,
  );

  /// 从生成的脚本里取出正则源码，用 Dart 跑一遍。
  ///
  /// 这样验的是**实际生成的**正则（含转义层数），而不是另写一份对照——
  /// 转义写错正是这段最容易翻车的地方。
  RegExp extractRegExp(String varName) {
    // 声明可能跨行（长正则换行写），因此允许 = 与 / 之间有任意空白
    final match = RegExp(
      'var $varName =\\s*/([\\s\\S]+?)/;',
    ).firstMatch(script);
    expect(match, isNotNull, reason: '脚本中应包含 $varName');
    return RegExp(match!.group(1)!);
  }

  group('正则能穿透 BOSS 的多层转义响应', () {
    // 以下片段取自真实抓包，保留原始转义层数（三层反斜杠）
    const objectDataResponse =
        r'{"d":"{\"d\":\"{'
        r'\\\"PROJECTID\\\": \\\"PROJECT_899dce8a24c648d781317f6185f2dabb\\\",'
        r'\\\"PROJECTCODE\\\": \\\"PROJECT_75e02aca37424830beb8fde9cd9c4b48\\\",'
        r'\\\"AUDITOR\\\": \\\";USERINFO_891ca55ea07b40a38d6dc2b54681bce2\\\"'
        r'}\"}"}';

    test('提取 PROJECTID', () {
      final match = extractRegExp(
        'RE_D_PROJECT_ID',
      ).firstMatch(objectDataResponse);
      expect(match, isNotNull);
      expect(match!.group(1), 'PROJECT_899dce8a24c648d781317f6185f2dabb');
    });

    test('提取 PROJECTCODE', () {
      final match = extractRegExp(
        'RE_D_PROJECT_CODE',
      ).firstMatch(objectDataResponse);
      expect(match, isNotNull);
      expect(match!.group(1), 'PROJECT_75e02aca37424830beb8fde9cd9c4b48');
    });

    test('提取 AUDITOR，保留前导分号', () {
      final match = extractRegExp('RE_D_AUDITOR').firstMatch(objectDataResponse);
      expect(match, isNotNull);
      // 提交报文里 AUDITOR 带前导分号，丢了会导致审核人无效
      expect(match!.group(1), ';USERINFO_891ca55ea07b40a38d6dc2b54681bce2');
    });

    test('单层转义的请求体同样能匹配', () {
      // 保存报文的 workLogData 是单层转义
      const requestBody =
          r'{"workLogData":"{\"PROJECTID\":\"PROJECT_899dce8a24c648d781317f6185f2dabb\",'
          r'\"PROJECTCODE\":\"PROJECT_75e02aca37424830beb8fde9cd9c4b48\",'
          r'\"AUDITOR\":\";USERINFO_891ca55ea07b40a38d6dc2b54681bce2\"}"}';

      expect(
        extractRegExp('RE_D_PROJECT_ID').firstMatch(requestBody)?.group(1),
        'PROJECT_899dce8a24c648d781317f6185f2dabb',
      );
      expect(
        extractRegExp('RE_D_AUDITOR').firstMatch(requestBody)?.group(1),
        ';USERINFO_891ca55ea07b40a38d6dc2b54681bce2',
      );
    });

    test('完全不含项目信息的响应不误匹配', () {
      const unrelated = r'{"d":"{\"d\":[24,10.3,13.7]}"}';
      expect(extractRegExp('RE_D_PROJECT_ID').hasMatch(unrelated), isFalse);
      expect(extractRegExp('RE_D_AUDITOR').hasMatch(unrelated), isFalse);
    });
  });

  group('列表形状（ColName/ColValue 三元组）', () {
    // 取自真实的 GetDataGridList 响应：字段名是 PROJECTNAME 而非 PROJECTID，
    // 值藏在 ColValue 里，中间隔着 ColText。只认详情形状会完全扫不到。
    const gridResponse =
        r'{"d":"{\"d\":{\"__type\":\"EditGridObject\",\"Rows\":[['
        r'{\"__type\":\"EditGridColDataObject\",\"ColIcon\":null,'
        r'\"ColName\":\"EID\",\"ColText\":\"WORKLOG_4b118b9e79dc4a99bcf00d4df74f1ea9\",'
        r'\"ColValue\":\"WORKLOG_4b118b9e79dc4a99bcf00d4df74f1ea9\",\"Editable\":1},'
        r'{\"__type\":\"EditGridColDataObject\",\"ColIcon\":null,'
        r'\"ColName\":\"PROJECTNAME\",\"ColText\":\"面向比亚迪公司汽车造型设计场景的工业造型设计软件攻关项目-自筹\",'
        r'\"ColValue\":\"PROJECT_899dce8a24c648d781317f6185f2dabb\",\"Editable\":0},'
        r'{\"__type\":\"EditGridColDataObject\",\"ColIcon\":null,'
        r'\"ColName\":\"AUDITOR\",\"ColText\":\"杨亚伦\",'
        r'\"ColValue\":\";USERINFO_891ca55ea07b40a38d6dc2b54681bce2\",\"Editable\":1}'
        r']]}}"}';

    test('从 PROJECTNAME 列取到项目 ID', () {
      expect(
        extractRegExp('RE_L_PROJECT_ID').firstMatch(gridResponse)?.group(1),
        'PROJECT_899dce8a24c648d781317f6185f2dabb',
      );
    });

    test('从 AUDITOR 列取到审核人 ID', () {
      expect(
        extractRegExp('RE_L_AUDITOR').firstMatch(gridResponse)?.group(1),
        ';USERINFO_891ca55ea07b40a38d6dc2b54681bce2',
      );
    });

    test('取到 WORKLOG 的 EID，用于补查 PROJECTCODE', () {
      expect(
        extractRegExp('RE_L_EID').firstMatch(gridResponse)?.group(1),
        'WORKLOG_4b118b9e79dc4a99bcf00d4df74f1ea9',
      );
    });

    test('空列表不误匹配', () {
      const empty =
          r'{"d":"{\"d\":{\"__type\":\"EditGridObject\",\"RecordsTotal\":0,\"Rows\":[]}}"}';
      expect(extractRegExp('RE_L_PROJECT_ID').hasMatch(empty), isFalse);
      expect(extractRegExp('RE_L_EID').hasMatch(empty), isFalse);
    });
  });

  group('脚本约定', () {
    test('同时扫描响应体和请求体', () {
      // 新建表单的请求体里也带着项目列表，只扫响应会漏
      expect(script.contains('entry.response'), isTrue);
      expect(script.contains('entry.body'), isTrue);
    });

    test('优先匹配 CSV 中的项目名，避免多项目时选错', () {
      expect(script.contains('matchedPreferred'), isTrue);
      expect(script.contains(projectName), isTrue);
    });

    test('不涉及任何凭据字段', () {
      expect(script.contains('Password'), isFalse);
      expect(script.contains('LoginID'), isFalse);
    });

    test('找不到时返回可操作的中文提示', () {
      expect(script.contains('我的工作日志'), isTrue);
      expect(script.contains('notFound'), isTrue);
    });
  });

  group('值可能在 ColText 而不是 ColValue', () {
    test('ColValue 为 null 时从 ColText 取值', () {
      // 实测 BOSS 首页「我的项目」网格就是这种形状：
      // "ColName":"EID","ColText":"PROJECT_xxx","ColValue":null
      // 早期正则只认 ColValue，导致明明抓到了却解析不出来。
      expect(
        script.contains(r'Col(?:Text|Value)'),
        isTrue,
        reason: '三个列表正则都应同时接受 ColText 与 ColValue',
      );
      expect(script.contains('ColValue\\\\*"\\s*:'), isFalse,
          reason: '不应再有只认 ColValue 的正则');
    });
  });
}
