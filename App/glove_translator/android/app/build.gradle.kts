plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.glove_translator"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.glove_translator"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packagingOptions {
        pickFirst("lib/arm64-v8a/libtensorflowlite_jni.so")
        pickFirst("lib/armeabi-v7a/libtensorflowlite_jni.so")
        pickFirst("lib/x86_64/libtensorflowlite_jni.so")
        pickFirst("lib/arm64-v8a/libtensorflowlite_flex_jni.so")
        pickFirst("lib/armeabi-v7a/libtensorflowlite_flex_jni.so")
        pickFirst("lib/x86_64/libtensorflowlite_flex_jni.so")
    }

}

kotlin {
    jvmToolchain(17) // Đồng bộ an toàn Java/Kotlin cho riêng Module App của bạn
}

flutter {
    source = "../.."
}


