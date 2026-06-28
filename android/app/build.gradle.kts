plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

android {
    namespace = "com.lanke.nagomusic"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lanke.nagomusic"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 27
        targetSdk = flutter.targetSdkVersion
        versionName = flutter.versionName
        // Derive a monotonic versionCode from the semantic version so the
        // version string stays clean (e.g. "1.3.1", no "+N"). The optional
        // pubspec build number (flutter.versionCode, default 1) is the
        // maintenance counter. Example: 1.3.1 -> 1030101, 1.3.1+2 -> 1030102.
        run {
            val parts = (flutter.versionName).split(".")
            val major = parts.getOrNull(0)?.toIntOrNull() ?: 0
            val minor = parts.getOrNull(1)?.toIntOrNull() ?: 0
            val patch = parts.getOrNull(2)?.toIntOrNull() ?: 0
            versionCode = (major * 10000 + minor * 100 + patch) * 100 +
                flutter.versionCode
        }
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }
    fun prop(name: String): String? {
        return System.getenv(name) ?: keystoreProperties.getProperty(name)
    }
    val storeFilePath = prop("SIGNING_STORE_FILE")
    val storePasswordValue = prop("SIGNING_STORE_PASSWORD")
    val keyAliasValue = prop("SIGNING_KEY_ALIAS")
    val keyPasswordValue = prop("SIGNING_KEY_PASSWORD")
    val hasReleaseSigning = !storeFilePath.isNullOrBlank() &&
        !storePasswordValue.isNullOrBlank() &&
        !keyAliasValue.isNullOrBlank() &&
        !keyPasswordValue.isNullOrBlank()

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(storeFilePath!!)
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // No keystore configured: fall back to debug signing so local
                // sideload builds still work, but make it LOUD — a debug-signed
                // build must never be uploaded to the Play Store.
                logger.warn(
                    "\n**********\n" +
                    "WARNING: release build is using the DEBUG signing key " +
                    "(no key.properties / SIGNING_* env vars found).\n" +
                    "This APK is fine for local install but will be REJECTED by " +
                    "the Play Store and cannot upgrade a properly-signed install.\n" +
                    "Configure android/key.properties to sign for distribution.\n" +
                    "**********\n"
                )
                signingConfigs.getByName("debug")
            }
            // Code shrinking (R8/minify) is intentionally OFF: this is a
            // Flutter app whose size is dominated by native .so + assets that
            // R8 cannot shrink (enabling it changed the APK size by <2% in
            // testing), while the Kotlin-serialization-based lyricon provider
            // carries reflection/serializer risk under obfuscation. The keep
            // rules in proguard-rules.pro are kept ready: to enable shrinking,
            // flip these to true and test the floating-lyrics + media paths.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("io.github.proify.lyricon:provider:0.1.68")
}

flutter {
    source = "../.."
}
