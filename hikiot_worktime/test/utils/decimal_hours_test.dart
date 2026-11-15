import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/decimal_hours.dart';

void main() {
  test('十进制与科学计数保持百分之一小时整数', () {
    expect(DecimalHours.tryHundredths(10.2), 1020);
    expect(DecimalHours.tryHundredths('10.20'), 1020);
    expect(DecimalHours.tryHundredths('1.02e1'), 1020);
    expect(DecimalHours.tryHundredths(1.15), 115);
    expect(DecimalHours.tryHundredths('2.9e-1'), 29);
  });
  test('多余位严格截断，不用补epsilon把真实第三位进位', () {
    expect(DecimalHours.tryHundredths('5.559'), 555);
    expect(DecimalHours.tryHundredths('10.199999999999'), 1019);
    expect(DecimalHours.tryHundredths('0.00999'), 0);
    expect(DecimalHours.tryHundredths('-5.559'), -555);
  });
  test('小数点前省略数字和显式正号可解析', () {
    expect(DecimalHours.tryHundredths('.29'), 29);
    expect(DecimalHours.tryHundredths('+1.15'), 115);
    expect(DecimalHours.tryHundredths('1.'), 100);
  });
  test('前导零不改变值且不会误判整数范围', () {
    expect(DecimalHours.tryHundredths('0000000000000000000010.20'), 1020);
    expect(DecimalHours.tryHundredths('000.29'), 29);
  });
  test('负差额与零固定两位格式化', () {
    expect(DecimalHours.formatHundredths(-50), '-0.50');
    expect(DecimalHours.formatHundredths(0), '0.00');
    expect(DecimalHours.formatHundredths(1020), '10.20');
  });
  test('非法与非有限数值拒绝', () {
    for (final value in <Object?>[
      null,
      true,
      {},
      'bad',
      'Infinity',
      'NaN',
      double.nan,
      double.infinity,
    ]) {
      expect(DecimalHours.tryHundredths(value), isNull);
    }
  });
  test('极小数归零，越界数不分配巨量字符串', () {
    expect(DecimalHours.tryHundredths(1e-100), 0);
    expect(DecimalHours.tryHundredths('1e1000000'), isNull);
  });
  test('重复累计与抵扣不产生额外百分之一小时损失', () {
    expect(DecimalHours.sum([10.2, 10.2, 10.2]), 30.6);
    expect(DecimalHours.add(30.6, -10.2), 20.4);
    expect(
      DecimalHours.formatHundredths(
        DecimalHours.tryHundredths(DecimalHours.sum(List.filled(31, 10.2)))!,
      ),
      '316.20',
    );
  });
}
