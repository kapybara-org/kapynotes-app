# ML Kit (and Firebase) find their component registrars by reflection and
# build each through its no-argument constructor. R8 keeps the classes but
# strips that constructor, so ML Kit's shared components never register and
# Gemini Nano reads as unavailable in a release build.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
