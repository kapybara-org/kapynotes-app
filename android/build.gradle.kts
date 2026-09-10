allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// The shared libraries the on-device speech engines run on: ONNX Runtime
// behind Parakeet (sherpa_onnx), LiteRT-LM and its accelerators behind Gemma
// (flutter_gemma_litertlm). In a release build these are excluded from the
// base app and packaged by `:speech_runtime` instead, which Google Play
// delivers on demand; see that module's build script for why. Debug builds
// keep them in the base, because `flutter run` has no Play to fetch from.
//
// One list, read by both sides, so that a library renamed by a package
// upgrade cannot end up in neither place.
extra["runtimeLibraries"] = listOf(
    "libonnxruntime.so",
    "libsherpa-onnx-c-api.so",
    "libsherpa-onnx-cxx-api.so",
    "libLiteRt*.so",
    "libStreamProxy.so",
    "libGemmaModelConstraintProvider.so",
    "libQnn*.so",
)

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
