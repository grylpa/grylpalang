import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // No `kotlin-android` here: AGP 9's built-in Kotlin compiles this module
    // (see android.builtInKotlin in gradle.properties). Applying KGP alongside
    // AGP 9 is what Flutter warns about and will fail to build in a future release.
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.grylpa.katalaveno"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.grylpa.katalaveno"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    // Two shipping variants of the same release build, so a development copy can
    // sit on the phone beside the Play one: different applicationId (hence a
    // separate data sandbox and a separate launcher entry), different label,
    // same signing key.
    //
    // Declaring flavors makes the flavor mandatory for every build and run —
    // `flutter run --flavor dev`, `flutter build apk --flavor store`. The
    // scripts in main/ pass it; a bare `flutter run` will now ask for one.
    // The launcher label comes from a manifest placeholder rather than a
    // per-flavor resValue: AGP 9 ships with the resValues build feature off, so
    // a generated string resource fails configuration outright.
    flavorDimensions += "channel"
    productFlavors {
        create("store") {
            dimension = "channel"
            // No suffix: this is the published application ID, and keeping it
            // untouched is what lets an existing install keep its data.
            manifestPlaceholders["appLabel"] = "Katalaveno"
        }
        create("dev") {
            dimension = "channel"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "KataDev"
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }

        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Replaces the deprecated `android { kotlinOptions { jvmTarget = ... } }` block,
// which KGP removes in favour of this compilerOptions DSL.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    //coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
