plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = mapOf(
    "HUAYUN_ANDROID_KEYSTORE_PATH" to System.getenv("HUAYUN_ANDROID_KEYSTORE_PATH"),
    "HUAYUN_ANDROID_STORE_PASSWORD" to System.getenv("HUAYUN_ANDROID_STORE_PASSWORD"),
    "HUAYUN_ANDROID_KEY_ALIAS" to System.getenv("HUAYUN_ANDROID_KEY_ALIAS"),
    "HUAYUN_ANDROID_KEY_PASSWORD" to System.getenv("HUAYUN_ANDROID_KEY_PASSWORD"),
)
val releaseSigningReady = releaseSigningValues.values.all { !it.isNullOrBlank() }
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (releaseTaskRequested && !releaseSigningReady) {
    val missingValues = releaseSigningValues
        .filterValues { it.isNullOrBlank() }
        .keys
        .joinToString()
    throw GradleException("正式版签名配置不完整，缺少环境变量：$missingValues")
}

android {
    namespace = "com.hikiot.worktime"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 启用 core library desugaring
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    defaultConfig {
        applicationId = "com.hikiot.worktime"
        // WebView需要最低API 21
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 启用 multidex 支持
        multiDexEnabled = true
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(requireNotNull(releaseSigningValues["HUAYUN_ANDROID_KEYSTORE_PATH"]))
                storePassword = releaseSigningValues["HUAYUN_ANDROID_STORE_PASSWORD"]
                keyAlias = releaseSigningValues["HUAYUN_ANDROID_KEY_ALIAS"]
                keyPassword = releaseSigningValues["HUAYUN_ANDROID_KEY_PASSWORD"]
            }
        }
    }

    buildTypes {
        release {
            // 正式签名只从环境变量注入，密钥和密码严禁进入仓库。
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
