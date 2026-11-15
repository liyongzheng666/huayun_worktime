import 'package:flutter/material.dart';

class BossLoginRequest {
  const BossLoginRequest.credentials({
    required this.userName,
    required this.password,
    this.rememberPassword = true,
  }) : openWeb = false,
       forgetCredentials = false;

  const BossLoginRequest.openWeb()
    : userName = '',
      password = '',
      openWeb = true,
      rememberPassword = false,
      forgetCredentials = false;

  const BossLoginRequest.forget()
    : userName = '',
      password = '',
      openWeb = false,
      rememberPassword = false,
      forgetCredentials = true;

  final String userName;
  final String password;
  final bool openWeb;
  final bool rememberPassword;
  final bool forgetCredentials;
}

/// BOSS 首次登录面板。
///
/// 用户可明确选择通过本机系统安全存储记住验证成功的密码，也可随时清除。
/// 密码不得写入日志、剪贴板或普通偏好设置。
class BossLoginDialog {
  BossLoginDialog._();

  static Future<BossLoginRequest?> show({
    required BuildContext context,
    String initialUserName = '',
    bool hasRememberedPassword = false,
  }) {
    return showDialog<BossLoginRequest>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BossLoginDialogBody(
        initialUserName: initialUserName,
        hasRememberedPassword: hasRememberedPassword,
      ),
    );
  }
}

class _BossLoginDialogBody extends StatefulWidget {
  const _BossLoginDialogBody({
    required this.initialUserName,
    required this.hasRememberedPassword,
  });

  final String initialUserName;
  final bool hasRememberedPassword;

  @override
  State<_BossLoginDialogBody> createState() => _BossLoginDialogBodyState();
}

class _BossLoginDialogBodyState extends State<_BossLoginDialogBody> {
  late final TextEditingController _userNameController;
  late final TextEditingController _passwordController;
  bool _showPassword = false;
  bool _rememberPassword = true;

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
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _rememberPassword,
              title: const Text('记住密码并自动登录'),
              subtitle: const Text('仅本机；可取消或清除'),
              onChanged: (value) =>
                  setState(() => _rememberPassword = value ?? false),
            ),
            const SizedBox(height: 12),
            Text(
              '勾选后，验证成功的密码将保存在本机系统安全存储，供登录失效时自动恢复。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.hasRememberedPassword)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const BossLoginRequest.forget()),
            child: const Text('清除记住的密码'),
          ),
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
      BossLoginRequest.credentials(
        userName: userName,
        password: password,
        rememberPassword: _rememberPassword,
      ),
    );
  }
}
