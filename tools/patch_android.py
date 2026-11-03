#!/usr/bin/env python3
"""Po `flutter create` dopisuje uprawnienia do manifestu i włącza desugaring (wymagany przez
flutter_local_notifications). Uruchamiany z katalogu app/ przez workflow."""
import pathlib
import re
import sys

PERMS = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
"""

root = pathlib.Path("android/app")

# --- manifest ---
mf = root / "src/main/AndroidManifest.xml"
txt = mf.read_text(encoding="utf-8")
QUERIES = """    <queries>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
    </queries>
"""
if "ACCESS_FINE_LOCATION" not in txt:
    txt = txt.replace("<application", PERMS + QUERIES + "    <application", 1)
    mf.write_text(txt, encoding="utf-8")
    print("manifest: dodano uprawnienia")

# --- gradle (kts lub groovy) ---
kts, groovy = root / "build.gradle.kts", root / "build.gradle"
if kts.exists():
    g = kts.read_text(encoding="utf-8")
    if "isCoreLibraryDesugaringEnabled" not in g:
        g, n = re.subn(r"(compileOptions\s*\{)", r"\1\n        isCoreLibraryDesugaringEnabled = true", g, count=1)
        if n == 0:
            sys.exit("Nie znaleziono compileOptions w build.gradle.kts - dopisz desugaring ręcznie")
    if "desugar_jdk_libs" not in g:
        g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
    kts.write_text(g, encoding="utf-8")
    print("gradle.kts: włączono desugaring")
elif groovy.exists():
    g = groovy.read_text(encoding="utf-8")
    if "coreLibraryDesugaringEnabled" not in g:
        g, n = re.subn(r"(compileOptions\s*\{)", r"\1\n        coreLibraryDesugaringEnabled true", g, count=1)
        if n == 0:
            sys.exit("Nie znaleziono compileOptions w build.gradle - dopisz desugaring ręcznie")
    if "desugar_jdk_libs" not in g:
        g += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
    groovy.write_text(g, encoding="utf-8")
    print("gradle: włączono desugaring")
else:
    sys.exit("Brak android/app/build.gradle(.kts)")
