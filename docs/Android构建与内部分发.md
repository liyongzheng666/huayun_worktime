# Android 构建与内部分发

## 当前基线

- Flutter：`3.44.8`
- Java：Temurin JDK `17.0.20`
- Android SDK：API 36，最低支持 API 24
- 应用 ID：`com.hikiot.worktime`
- 当前版本：`2.4.0+4`
- 分发方式：公司内部直接安装 APK，不上架应用商店
- 正式版本来源：GitHub Releases；国内网络不可达时可转发同一个 APK

Android Studio 自带的 JDK 25 当前不能用于本项目的 Gradle 构建。本机 Flutter 已固定使用：

```text
/Users/allyhan/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
```

## 本机构建

在 Flutter 项目目录执行：

```bash
./scripts/build_android_release.sh
```

脚本会从 macOS 钥匙串读取 release 签名密码，构建 APK，并在以下目录生成带版本号的安装包和 SHA-256 文件：

```text
build/app/outputs/flutter-apk/huayun-worktime-v<版本名+构建号>.apk
build/app/outputs/flutter-apk/huayun-worktime-v<版本名+构建号>.apk.sha256
```

普通同事只需取得 APK，在 Android 系统中允许对应来源安装未知应用，然后直接安装。以后只要应用 ID、release keystore 和签名别名保持不变，新版本就能覆盖升级；版本号必须同步递增。

## 签名资产

本机 keystore 位于：

```text
~/Library/Application Support/HuayunWorktime/android/huayun-worktime-release.jks
```

签名别名为 `huayun-worktime`，密码保存在 macOS 钥匙串服务 `com.hikiot.worktime.android.release-signing` 中。keystore、密码和 GitHub Actions Secrets 均不得提交到仓库。

> release keystore 一旦丢失，已安装版本将无法再被后续 APK 覆盖升级。首次正式分发前，必须把 keystore 和密码做一份离机加密备份。

## 发布前检查

1. 更新 `pubspec.yaml` 中的版本，例如从 `2.4.0+4` 提升到 `2.4.1+5`。
2. 运行 `flutter analyze` 和 `flutter test`。
3. 运行 `./scripts/build_android_release.sh`。
4. 使用 `apksigner verify --verbose --print-certs <APK>` 验证签名。
5. 核对 APK 的 SHA-256 与同目录 `.sha256` 文件一致。
6. 先在一台 Android 设备上安装；已有旧版时再验证覆盖升级和数据保留。
7. 将验证过的同一个 APK 上传 GitHub Release；国内网络不可达时仅转发该文件，不重新签名或二次打包。

## GitHub 自动发布

`.github/workflows/android-release.yml` 已配置四个 GitHub Actions Secrets：

- `HUAYUN_ANDROID_KEYSTORE_BASE64`
- `HUAYUN_ANDROID_STORE_PASSWORD`
- `HUAYUN_ANDROID_KEY_ALIAS`
- `HUAYUN_ANDROID_KEY_PASSWORD`

普通 `workflow_dispatch` 只做云端构建验证，不发布 Release。正式发布时推送与 `pubspec.yaml` 完整版本严格一致的 tag：

```bash
git tag v2.4.0+4
git push origin v2.4.0+4
```

工作流会依次执行依赖安装、静态检查、完整测试、release 构建、签名证书指纹验证、SHA-256 生成和 GitHub Release 上传。tag、APK 名称和 `pubspec.yaml` 任一版本不一致都会失败。

2026-08-08 已用 `workflow_dispatch` 完成不发布干跑：Actions run `31259428064` 的静态检查、263 条测试、release 构建、产物命名、SHA-256 和固定证书指纹检查全部通过，且未创建 GitHub Release。

## App 内更新

- Android 启动后异步访问公开 GitHub Releases API；5 秒内无法完成检查则静默失败，不影响登录、工时和提醒功能。
- 设置页提供“检查 Android 更新”，用户主动检查失败时可选择打开 GitHub Releases 页面。
- 版本比较只使用 Android `versionCode`，不按版本名称字符串排序。
- 只接受 `huayun-worktime-v<版本名>+<构建号>.apk` 以及同名 `.sha256` 文件；Release tag 必须是同一完整版本。
- APK 下载到应用私有缓存目录，下载完成后由 Android 原生层重新计算 SHA-256；校验通过才交给系统安装器。
- Android 8 及以上首次更新需要允许本 App“安装未知应用”；App 只负责打开授权页和系统安装确认页，不进行静默安装。
- 超过 7 天的 APK 临时文件会在启动检查前清理。

GitHub 在中国大陆不可达时，自动检查保持静默。使用者可以从公司群、网盘或离线传输取得 GitHub Release 中同一个 APK，直接点击覆盖安装；不要卸载旧版本，否则本地数据会被清除。

## 已完成与剩余验收

- Android 15 / API 35 模拟器已验证：固定签名的 `2.3.1+3` 可通过 `adb install -r` 覆盖升级到 `2.4.0+4`，新版能正常冷启动，已确认的免责声明状态保留。
- 模拟器已覆盖“同签名覆盖安装 + 基础本地状态保留 + 启动无崩溃”，但不替代实际手机的 ROM 和权限差异验收。
- 首个正式 Release 前仍需：在公司实际 Android 手机上验证 App 内发现更新、下载、“安装未知应用”授权、系统安装确认、业务数据保留，并完成 keystore 离机加密备份。
