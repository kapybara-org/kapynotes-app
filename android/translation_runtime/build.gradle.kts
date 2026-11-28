// ML Kit's on-device translator, as a module Google Play delivers on demand.
//
// Live translation uses the phone's own translator where Android has one for
// the pair, and ML Kit's everywhere else. ML Kit is about 20 MB of code and
// native libraries before its first 30 MB language model, for a feature that
// is off until somebody turns it on. So none of it is in the base app: this
// module carries it, Play sends it to a phone only when somebody downloads a
// language pair the system can't translate, and the base finds its one class
// by name (LiveTranslation.kt, OnDeviceTranslationPack).
//
// ML Kit registers its components through the merged manifest. For a module
// that arrives after launch to be found, the base carries ML Kit's
// playstore-dynamic-feature-support: see the base app's build script.
plugins {
    id("com.android.dynamic-feature")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.kapybara.kapynotes.translation_runtime"
    compileSdk = 37

    defaultConfig {
        minSdk = 24
    }

    // A dynamic feature must know every build type the base has. Flutter
    // adds `profile` to the app; without it here, `bundleProfile` fails.
    buildTypes {
        create("profile") {
            initWith(getByName("debug"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(project(":app"))
    implementation("com.google.mlkit:translate:17.0.3")
}
