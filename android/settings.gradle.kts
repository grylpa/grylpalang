pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Two different floors meet here, and the higher one wins. flutter_local
    // _notifications 23.0.0 requires AGP >= 9.1.1, while Flutter 3.50 warns at
    // anything below 9.3.1 ("support ... will soon be dropped"), so 9.3.1 it is
    // — satisfying the plugin was never the binding constraint.
    //
    // Raising AGP is also what fixes the *Kotlin* warning, which is the part
    // worth knowing: the app module deliberately applies no `kotlin-android`,
    // so it compiles with AGP's **built-in** Kotlin and the 2.4.10 Flutter
    // objected to was AGP 9.1.1's, not anything declared here.
    id("com.android.application") version "9.3.1" apply false
    // Governs only the plugin modules that still apply KGP themselves
    // (flutter_file_dialog, flutter_tts) — not this app's own sources. Kept at
    // or above Flutter's 2.4.20 floor so those modules don't drag the build
    // back under it.
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
