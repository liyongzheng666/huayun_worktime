/// 工时的十进制边界转换：以0.01小时整数截断，避免二进制乘100少掉一分。
class DecimalHours {
  DecimalHours._();

  static final _number = RegExp(
    r'^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$',
  );
  static final _leadingZeros = RegExp(r'^0+');

  /// 保留输入的十进制含义，超过两位时朝零截断，不补epsilon、不四舍五入。
  static int? tryHundredths(Object? value) {
    if (value is num && !value.isFinite) return null;
    if (value is! num && value is! String) return null;
    final match = _number.firstMatch(value.toString().trim());
    if (match == null) return null;
    final rawWhole = (match[2] ?? '0').replaceFirst(_leadingZeros, '');
    final whole = rawWhole.isEmpty ? '0' : rawWhole;
    final fraction = match[3] ?? match[4] ?? '';
    final exponent = int.tryParse(match[5] ?? '0');
    if (exponent == null) return null;
    final digits = whole + fraction;
    final length = whole.length + exponent + 2;
    if (length <= 0) return 0;
    // 移动端int为64位；拒绝越界也避免异常指数造成巨量字符串分配。
    if (length > 19) return null;
    final text = length >= digits.length
        ? digits.padRight(length, '0')
        : digits.substring(0, length);
    return int.tryParse('${match[1] == '-' ? '-' : ''}$text');
  }

  static String formatHundredths(int value) {
    final sign = value < 0 ? '-' : '';
    final magnitude = value.abs();
    return '$sign${magnitude ~/ 100}.'
        '${(magnitude % 100).toString().padLeft(2, '0')}';
  }

  /// 每日工时已经是两位小数；累计时先换整数，避免30.60累成30.5999。
  static double sum(Iterable<num> values) {
    var total = 0;
    for (final value in values) {
      final cents = tryHundredths(value);
      if (cents == null) throw ArgumentError.value(value, 'hours', '无效工时');
      total += cents;
    }
    return total / 100;
  }

  static double add(num left, num right) => sum([left, right]);
}
