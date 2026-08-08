#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly DEFAULT_KEYSTORE_PATH="${HOME}/Library/Application Support/HuayunWorktime/android/huayun-worktime-release.jks"
readonly KEYCHAIN_ACCOUNT="huayun_worktime"
readonly KEYCHAIN_SERVICE="com.hikiot.worktime.android.release-signing"

export HUAYUN_ANDROID_KEYSTORE_PATH="${HUAYUN_ANDROID_KEYSTORE_PATH:-${DEFAULT_KEYSTORE_PATH}}"
export HUAYUN_ANDROID_KEY_ALIAS="${HUAYUN_ANDROID_KEY_ALIAS:-huayun-worktime}"

if [[ ! -f "${HUAYUN_ANDROID_KEYSTORE_PATH}" ]]; then
    echo "找不到 Android release keystore：${HUAYUN_ANDROID_KEYSTORE_PATH}" >&2
    exit 1
fi

if [[ -z "${HUAYUN_ANDROID_STORE_PASSWORD:-}" ]]; then
    HUAYUN_ANDROID_STORE_PASSWORD="$(
        security find-generic-password \
            -a "${KEYCHAIN_ACCOUNT}" \
            -s "${KEYCHAIN_SERVICE}" \
            -w
    )"
    export HUAYUN_ANDROID_STORE_PASSWORD
fi

# 当前 keystore 的 key 密码与 store 密码相同；CI 仍可分别注入两者。
export HUAYUN_ANDROID_KEY_PASSWORD="${HUAYUN_ANDROID_KEY_PASSWORD:-${HUAYUN_ANDROID_STORE_PASSWORD}}"

cd "${PROJECT_DIR}"
flutter build apk --release "$@"

readonly APP_VERSION="$(awk '/^version: / { print $2; exit }' pubspec.yaml)"
readonly VERSION_NAME="${APP_VERSION%%+*}"
readonly OUTPUT_DIR="${PROJECT_DIR}/build/app/outputs/flutter-apk"
readonly SOURCE_APK="${OUTPUT_DIR}/app-release.apk"
readonly DISTRIBUTION_APK="${OUTPUT_DIR}/huayun-worktime-v${VERSION_NAME}.apk"

cp "${SOURCE_APK}" "${DISTRIBUTION_APK}"
(
    cd "${OUTPUT_DIR}"
    shasum -a 256 "$(basename "${DISTRIBUTION_APK}")" > "$(basename "${DISTRIBUTION_APK}").sha256"
)

echo "正式安装包：${DISTRIBUTION_APK}"
echo "校验文件：${DISTRIBUTION_APK}.sha256"
