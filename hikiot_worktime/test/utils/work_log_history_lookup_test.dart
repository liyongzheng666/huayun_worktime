import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/boss_session_script.dart';
import 'package:hikiot_worktime/utils/work_log_history_lookup.dart';

/// 这些约定来自一份真实的 `GetHisWorkLogList` 响应，
/// 早期版本因为假设了错误的列名而一直解析不出来。
void main() {
  const store = '__store';

  String build() => WorkLogHistoryLookup.build(
    captureStoreName: store,
    preferredProjectName: '某项目',
  );

  test('服务名取自真机抓包，不是猜的', () {
    expect(
      WorkLogHistoryLookup.serviceUri,
      'InforCenter.WorkReport.ProjectService.GetHisWorkLogList',
    );
  });

  test('按列名 PROJECTID 取值，而不是并不存在的 PROJECTNAME', () {
    // 实测该网格里项目名在 PROJECTID 列的 ColText，项目 ID 在其 ColValue；
    // 根本没有名为 PROJECTNAME 的列。早期正则找 PROJECTNAME，
    // 因此 scan() 直接返回 null，后续全部落空。
    final script = build();
    expect(script.contains("pickId(map, 'PROJECTID', 'PROJECT_')"), isTrue);
    expect(script.contains('PROJECTNAME'), isFalse);
  });

  test('三个值必须来自同一行', () {
    // 一次响应里有多行历史日志，把第 1 行的项目和第 5 行的审核人
    // 拼在一起会得到一份看似合理、实则错误的配置。
    final script = build();
    expect(script.contains('function rowMap(row)'), isTrue);
    expect(script.contains('function readRow(map)'), isTrue);
  });

  test('项目与审核人缺一不可，宁可判失败', () {
    expect(build().contains('if (!projectId || !auditor) return null;'), isTrue);
  });

  test('优先取与 CSV 项目名一致的那一行', () {
    // 历史日志可能横跨多个项目，取错行会把工时记到别的项目名下
    expect(build().contains('hit.projectName === PREFERRED'), isTrue);
  });

  test('同时带出审核人姓名，供用户提交前肉眼核对', () {
    expect(build().contains('auditorName'), isTrue);
  });

  test('先重放取最新数据，失败才退回已抓到的响应', () {
    // 项目和审核人会换，只读旧抓包等于又回到「常量」的老路
    final script = build();
    expect(script.contains("source = 'replay'"), isTrue);
    expect(script.contains("source = 'captured'"), isTrue);
  });

  test('重放复用页面自己发过的参数，不自己构造', () {
    // ViewName / ParaList / CustomViewFilterString 依赖页面上下文，猜不出来
    final script = build();
    expect(script.contains('bossCall(para, SERVICE_URI, found.inner)'), isTrue);
  });

  test('走统一会话入口，不含凭据', () {
    final script = build();
    expect(
      script.contains(
        BossSessionScript.sessionPreamble(captureStoreName: store),
      ),
      isTrue,
    );
    expect(script.contains('Password'), isFalse);
    expect(script.contains('LoginID'), isFalse);
  });
}
