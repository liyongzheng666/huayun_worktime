import 'dart:convert';

/// 一个待填充的表单字段：按标签文字定位，填入指定值。
class WorkLogFillField {
  const WorkLogFillField({required this.label, required this.value});

  /// 表单中该字段的标签文字（如「标题」「工作内容」「正常工时」）。
  /// 匹配时忽略首尾空白与结尾的必填星号。
  final String label;

  final String value;
}

/// 工作日志自动填充脚本生成器
///
/// 单一职责：把「标签 → 值」的映射编译成一段可注入 WebView 的 JS，
/// 不关心值从哪来，也不负责注入本身。
///
/// 为什么按标签而不按 id 定位：BOSS 系统的控件 id 形如 `guid220_TextBox`，
/// 实测两次加载之间会整体偏移（guid161 → guid220），按 id 写死会导致
/// 内容被填进错误的字段。
///
/// 有意不做的事：
/// - 不填下拉框与 autoCombox。它们是 hoteam 自研伪控件（input.readonly +
///   隐藏真实值），直接改 value 只改显示不改内部状态，保存时会提交空值。
/// - 不点击「保存」。填充后必须由用户核对再提交。
class WorkLogFillScript {
  WorkLogFillScript._();

  /// 生成「点击工具栏按钮打开表单」的脚本。
  ///
  /// 填报表单没有独立网址，是首页工具栏里「新增工作日志」弹出来的，
  /// 所以「直达」只能靠模拟点击而非跳转 URL。
  ///
  /// 返回的 JS 执行后输出 JSON：`{"clicked":true,"text":"新增工作日志"}`
  static String buildOpenForm({String buttonText = '新增工作日志'}) {
    final wanted = jsonEncode(buttonText);

    return '''
      (function() {
        var WANTED = $wanted;

        function isVisible(el) {
          var r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }

        // 工具栏文字常被父容器一并包含（如「刷新新增工作日志编辑日志…」），
        // 因此收集所有含该文字的可见元素，取文本最短的那个，
        // 即最贴近按钮本身的节点，避免误点整个工具栏。
        var nodes = document.querySelectorAll('a, button, span, div, li, td, i');
        var best = null;
        var bestLen = Infinity;

        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (!isVisible(el)) continue;
          var text = (el.innerText || '').replace(/\\s+/g, '');
          if (text.indexOf(WANTED) < 0) continue;
          if (text.length < bestLen) {
            bestLen = text.length;
            best = el;
          }
        }

        if (!best) {
          return JSON.stringify({ clicked: false, reason: 'notFound' });
        }

        // 只点一次。原生 click 已能触发 jQuery 绑定的处理器，
        // 若再补一次 jQuery trigger('click') 会弹出两个重复表单。
        best.click();
        return JSON.stringify({ clicked: true, text: WANTED });
      })();
    ''';
  }

  /// 生成填充脚本。返回的 JS 执行后输出 JSON 字符串，形如：
  /// `{"filled":["标题","工作内容"],"missing":["正常工时"]}`
  static String build(List<WorkLogFillField> fields) {
    final payload = jsonEncode([
      for (final field in fields)
        {'label': field.label, 'value': field.value},
    ]);

    return '''
      (function() {
        var TARGETS = $payload;

        // 与「导出页面结构」使用同一套标签推断逻辑，保证定位口径一致。
        function nearbyLabel(el) {
          if (el.labels && el.labels[0]) {
            var t = el.labels[0].innerText.trim();
            if (t) return t;
          }
          var cell = el.closest('td, th');
          if (cell && cell.previousElementSibling) {
            var t2 = (cell.previousElementSibling.innerText || '').trim();
            if (t2 && t2.length < 30) return t2;
          }
          var node = el.parentElement;
          for (var depth = 0; node && depth < 4; depth++, node = node.parentElement) {
            var clone = node.cloneNode(true);
            var controls = clone.querySelectorAll('input, select, textarea, button');
            for (var i = 0; i < controls.length; i++) {
              controls[i].parentNode && controls[i].parentNode.removeChild(controls[i]);
            }
            var text = (clone.innerText || '').replace(/\\s+/g, ' ').trim();
            if (text && text.length > 0 && text.length < 30) return text;
          }
          return null;
        }

        // 归一化标签：去空白、去结尾必填星号，便于「正常工时 *」匹配「正常工时」
        function normalize(text) {
          return (text || '').replace(/\\s+/g, '').replace(/[*＊]+\$/, '');
        }

        // 用原生 setter 赋值，绕过前端框架对 value 的拦截；
        // 再补发 input/change/blur，让框架感知到变化。
        function setValue(el, value) {
          var proto = el.tagName === 'TEXTAREA'
            ? window.HTMLTextAreaElement.prototype
            : window.HTMLInputElement.prototype;
          var desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) {
            desc.set.call(el, value);
          } else {
            el.value = value;
          }
          ['input', 'change', 'blur'].forEach(function(type) {
            el.dispatchEvent(new Event(type, { bubbles: true }));
          });
          // 该系统基于 jQuery，原生事件不一定触发其内部处理，补发一次。
          if (window.jQuery) {
            try {
              window.jQuery(el).trigger('input').trigger('change').trigger('blur');
            } catch (e) {}
          }
        }

        var candidates = document.querySelectorAll('input, textarea');
        var filled = [];
        var missing = [];
        var skipped = [];

        TARGETS.forEach(function(target) {
          var wanted = normalize(target.label);
          var matched = null;

          for (var i = 0; i < candidates.length; i++) {
            var el = candidates[i];
            if (el.getAttribute('type') === 'hidden') continue;
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) continue;
            if (normalize(nearbyLabel(el)) !== wanted) continue;
            matched = el;
            break;
          }

          if (!matched) {
            missing.push(target.label);
            return;
          }
          // 只读控件多为伪下拉，直接赋值不会改变内部状态，跳过更安全。
          if (matched.readOnly || (matched.className || '').indexOf('readonly') >= 0) {
            skipped.push(target.label);
            return;
          }

          setValue(matched, target.value);
          filled.push(target.label);
        });

        return JSON.stringify({
          filled: filled,
          missing: missing,
          skipped: skipped
        });
      })();
    ''';
  }
}
