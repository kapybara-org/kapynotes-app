// The on-device speech engines, as a module Google Play delivers on demand.
//
// This module holds no code of its own. It exists to carry the shared
// libraries the two local engines run on — ONNX Runtime for Parakeet, LiteRT-LM
// for Gemma — out of the base app and into something Play only sends to a
// phone whose owner has pressed Download on a local model. Measured on 1.18.0,
// those libraries were 111 MB of a 157 MB arm64 install, for a feature that
// is inert until a further 670 MB or 2.6 GB of model arrives on top of it.
//
// The libraries are staged from where the base app's dependencies put them:
// LiteRT-LM and its companions from what Flutter copies out of Dart's native
// assets for the same variant, and Parakeet's runtime from the sherpa_onnx
// Android plugins' own jniLibs, located through `.flutter-plugins-dependencies`
// so that a package upgrade moves them without anyone editing a path here.
// The names come from one list in the root build script, shared with the base
// app's release exclusions, so nothing can end up in neither place.
import groovy.json.JsonSlurper

plugins {
    id("com.android.dynamic-feature")
}

val runtimeLibraries: List<String> by rootProject.extra
val runtimeIncludes = runtimeLibraries.map { "**/$it" }
// A plain directory rather than a Provider: the source-set API refuses
// providers, and the task dependency is wired by hand below.
val stagingRoot: File = layout.buildDirectory.dir("runtimeJniLibs").get().asFile

/// `<plugin>/android/src/main/jniLibs` for every sherpa_onnx Android plugin
/// Flutter resolved, one per ABI.
fun sherpaJniLibsDirs(): List<File> {
    val manifest = rootProject.file("../.flutter-plugins-dependencies")
    if (!manifest.exists()) return emptyList()
    val parsed = JsonSlurper().parse(manifest) as Map<*, *>
    val plugins = (parsed["plugins"] as Map<*, *>)["android"] as List<*>
    return plugins.mapNotNull { entry ->
        val plugin = entry as Map<*, *>
        val name = plugin["name"] as String
        if (!name.startsWith("sherpa_onnx_android")) return@mapNotNull null
        File(plugin["path"] as String, "android/src/main/jniLibs").takeIf { it.isDirectory }
    }
}

android {
    namespace = "com.kapybara.kapynotes.speech_runtime"
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

    sourceSets {
        for (type in listOf("debug", "profile", "release")) {
            getByName(type).jniLibs.srcDir(File(stagingRoot, type))
        }
    }
}

dependencies {
    implementation(project(":app"))
}

// One staging task per build type. It runs after Flutter has copied the
// native assets for the base's matching variant, which is the only ordering
// the Flutter build needs from this module.
for (type in listOf("debug", "profile", "release")) {
    val name = type.replaceFirstChar { it.uppercase() }
    val flutterCopy = project(":app").tasks.matching { it.name == "copyJniLibsflutterBuild$name" }
    val stage = tasks.register<Sync>("stage${name}RuntimeLibs") {
        dependsOn(flutterCopy)
        from(flutterCopy.map { task -> task.outputs.files }) {
            include(runtimeIncludes)
        }
        for (dir in sherpaJniLibsDirs()) {
            from(dir) { include(runtimeIncludes) }
        }
        includeEmptyDirs = false
        into(File(stagingRoot, type))
        doLast {
            val staged = destinationDir.walkTopDown().filter { it.isFile }.count()
            check(staged > 0) {
                "No speech runtime libraries were staged for $type; is this a Flutter build?"
            }
        }
    }
    tasks.matching { it.name == "merge${name}JniLibFolders" }.configureEach {
        dependsOn(stage)
    }
}
