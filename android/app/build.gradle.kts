import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// A fixed key (from android/key.properties, written by CI from repo secrets)
// signs every build the same way, so a new APK installs over the previous
// one. Without it, builds fall back to the per-machine debug key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.nexus.nexus_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nexus.nexus_assistant"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 9 (API 28) is the first to accept a key rotation proof, which
        // lets builds signed with the release key install over the old key.
        minSdk = maxOf(flutter.minSdkVersion, 28)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Models on the phone (llama.cpp) are built for 64-bit ARM, which
        // nearly every phone since 2017 has; elsewhere the screen says so.
        externalNativeBuild {
            cmake {
                abiFilters += listOf("arm64-v8a")
                arguments += listOf("-DCMAKE_BUILD_TYPE=Release", "-DANDROID_STL=c++_shared")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }

    // llama.cpp picks the CPU code for the phone's chip from separate
    // libraries at run time, so they have to be unpacked on install.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasKey) {
            create("fixed") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasKey) signingConfigs.getByName("fixed")
                else signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // FileProvider, used to hand a downloaded update to the installer.
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
