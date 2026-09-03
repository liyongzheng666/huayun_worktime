import 'package:flutter/material.dart';

class BossLoginRequest {
  const BossLoginRequest.credentials({
    required this.userName,
    required this.password,
  }) : openWeb = false;

  const BossLoginRequest.openWeb()
    : userName = '',
      password = '',
      openWeb = true;

  final String userName;
  final String password;
  final bool openWeb;
}

/// BOSS 首次登录面板。
///
/// 只把密码作为返回值交给当前这一次隐藏 WebView 登录；调用方不得持久化、打印
/// 或复制它。用户名可以在登录成功后单独记住，减少下次输入。
class BossLoginDialog {
  BossLoginDialog._();

  static Future<BossLoginRequest?> show({
    required BuildContext context,
    String initialUserName = '',
  }) {
    return showDialog<BossLoginRequest>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BossLoginDialogBody(initialUserName: initialUserName),
    );
  }
}

class _BossLoginDialogBody extends StatefulWidget {
  const _BossLoginDialogBody({required this.initialUserName});

  final String initialUserName;

  @override
  State<_BossLoginDialogBody> createState() => _BossLoginDialogBodyState();
}

class _BossLoginDialogBodyState extends State<_BossLoginDialogBody> {
  late final TextEditingController _userNameController;
  late final TextEditingController _passwordController;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _userNameController = TextEditingController(text: widget.initialUserName);
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _userNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userName = _userNameController.text.trim();
    final password = _passwordController.text;
    final valid = userName.isNotEmpty && password.isNotEmpty;

    return AlertDialog(
      title: const Text('登录 BOSS'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('登录将在后台完成，不会打开 BOSS 页面。'),
            const SizedBox(height: 16),
            TextField(
              controller: _userNameController,
              autofocus: userName.isEmpty,
              autofillHints: const <String>[],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '账号',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              autofocus: userName.isNotEmpty,
              obscureText: !_showPassword,
              enableSuggestions: false,
              autocorrect: false,
              autofillHints: const <String>[],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '密码',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? '隐藏密码' : '显示密码',
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (valid) _submit(userName, password);
              },
            ),
            const SizedBox(height: 12),
            Text(
              'App 仅记住账号。密码只用于本次登录，不会由 App 保存或写入日志。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const BossLoginRequest.openWeb()),
          child: const Text('网页登录'),
        ),
        FilledButton(
          onPressed: valid ? () => _submit(userName, password) : null,
          child: const Text('后台登录'),
        ),
      ],
    );
  }

  void _submit(String userName, String password) {
    Navigator.pop(
      context,
      BossLoginRequest.credentials(userName: userName, password: password),
    );
  }
}
