# Android 构建与内部分发

## 当前基线

- Flutter：`3.44.8`
- Java：Temurin JDK `17.0.20`
- Android SDK：API 36，最低支持 API 24
- 应用 ID：`com.hikiot.worktime`
- 当前版本：`2.3.1+3`
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
build/app/outputs/flutter-apk/huayun-worktime-v<版本号>.apk
build/app/outputs/flutter-apk/huayun-worktime-v<版本号>.apk.sha256
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

1. 更新 `pubspec.yaml` 中的版本，例如从 `2.3.1+3` 提升到 `2.3.2+4`。
2. 运行 `flutter analyze` 和 `flutter test`。
3. 运行 `./scripts/build_android_release.sh`。
4. 使用 `apksigner verify --verbose --print-certs <APK>` 验证签名。
5. 核对 APK 的 SHA-256 与同目录 `.sha256` 文件一致。
6. 先在一台 Android 设备上安装；已有旧版时再验证覆盖升级和数据保留。
7. 将验证过的同一个 APK 上传 GitHub Release；国内网络不可达时仅转发该文件，不重新签名或二次打包。

## 后续自动发布

GitHub Actions 需要从 Secrets 还原相同的 keystore，并注入以下环境变量：

- `HUAYUN_ANDROID_KEYSTORE_PATH`
- `HUAYUN_ANDROID_STORE_PASSWORD`
- `HUAYUN_ANDROID_KEY_ALIAS`
- `HUAYUN_ANDROID_KEY_PASSWORD`

自动发布流程应在版本 tag 触发，依次执行测试、release 构建、签名校验、SHA-256 生成和 GitHub Release 上传。App 内更新功能必须以 GitHub Releases 为唯一版本源，并在 GitHub 不可达时快速失败，不影响正常使用。
