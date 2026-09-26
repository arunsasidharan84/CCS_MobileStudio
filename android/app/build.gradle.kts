plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePath = System.getenv("CCS_ANDROID_KEYSTORE_PATH")
val hasReleaseSigning = !releaseKeystorePath.isNullOrBlank() &&
    file(releaseKeystorePath).exists()

android {
    namespace = "com.ccs.mobile_studio"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.ccs.mobile_studio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = System.getenv("CCS_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("CCS_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("CCS_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Local development fallback only. Published APKs use the
                // stable release key configured in GitHub Actions.
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
