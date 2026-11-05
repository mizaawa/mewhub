# Flutter embedding and plugins ship their own consumer rules; these cover
# the remaining reflection users.

# flutter_local_notifications (Gson-serialised notification details)
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# Keep generic type info for Gson TypeToken subclasses.
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Play Core (deferred components) is referenced by the Flutter engine but unused.
-dontwarn com.google.android.play.core.**
