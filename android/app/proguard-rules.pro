# R8 keep rules.
#
# AGP 9 minifies release builds by default. This project never asked for that
# and had no rules file at all, which is harmless for code reached by ordinary
# calls — R8 renames a definition and every call site to it together — and is
# not harmless for a name resolved at **runtime from a string**. Pigeon JNI
# does exactly that.
#
# `shared_preferences_android` 2.5.0 ("Updates internal implementation to use
# Pigeon JNI") replaced its message-channel layer with direct JNI calls, so its
# Dart half now carries JVM descriptors as literals:
#
#   r'(Ljava/lang/String;Ljava/lang/String;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;'
#
# R8 renamed `kotlin.coroutines.Continuation` to `vd`, that lookup stopped
# matching the method it names, and the app died before its first frame with
#
#   NoSuchMethodError: no non-static method
#   "Lio/flutter/plugins/sharedpreferences/SharedPreferencesAsyncApiRegistrar;
#    .setString(…Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
#
# on the first settings write. The build was green, because nothing about this
# is visible until the lookup runs — which is the same lesson as the stale
# plugin build in CLAUDE.md, reached by a different route.
#
# The plugin ships no consumer rules of its own (the `jni` package it depends on
# does — `-keep class com.github.dart_lang.jni.** { *; }`, which is why
# `PortContinuation` survives), so they have to live here. Every name below is
# one that plugin resolves by string, taken from the descriptors in its
# generated `lib/src/*.g.jni.dart` rather than guessed. `java.*` needs nothing:
# platform classes are never renamed.
#
# If another plugin adopts Pigeon JNI, it needs the same treatment — the tell is
# a `*.g.jni.dart` in its `lib/`, and the failure is always a NoSuchMethodError
# or NoClassDefFoundError naming a type that R8 has since renamed.
# The plugin's own classes and members, which it looks up by name.
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# The Kotlin side of the suspend-call ABI. This is deliberately the whole
# namespace rather than the list below, which is what a first attempt kept and
# is how the second crash was earned: the names come from **two** places — the
# descriptors in the plugin's generated bindings, and the `jni` package's own
# runtime, which resolves the coroutine intrinsics to decide whether a call
# suspended. Enumerating them is whack-a-mole, each round costing a build, an
# install and a launch to discover; `kotlin.**` ends the game. `-keepnames` is
# `-keep,allowshrinking`, so unused classes and members are still removed — this
# only forbids *renaming* what survives, which is all the lookups need.
#
# What is actually resolved today, for the record: the plugin names
# `kotlin.coroutines.Continuation`, `kotlin.Unit` (and its `INSTANCE` field),
# `kotlin.enums.EnumEntries` and `kotlin.jvm.internal.DefaultConstructorMarker`;
# the `jni` package adds `kotlin.coroutines.intrinsics.CoroutineSingletons`,
# `kotlin.coroutines.intrinsics.IntrinsicsKt`, `kotlin.Result` and
# `kotlin.Result$Failure`.
-keepnames class kotlin.** { *; }
