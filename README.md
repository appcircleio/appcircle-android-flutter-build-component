# Appcircle Flutter Build for Android

Build your Flutter project with [Flutter SDK](https://github.com/flutter/flutter).

Required Input Variables
- `$AC_FLUTTER_PROJECT_DIR`: The root directory of your Flutter project where pubspec.yaml file exist.
- `$AC_OUTPUT_TYPE`: Output type for your build file(apk or aab)

Optional Input Variables
- `$AC_FLUTTER_BUILD_MODE`: Specifies Flutter build mode. Defaults to: `release`
- `$AC_FLUTTER_BUILD_EXTRA_ARGS`: Additional custom build arguments. For example: `--split-per-abi`

Output Variables
- `$AC_APK_PATH`: Path for the generated .apk file
- `$AC_AAB_PATH`: Path for the generated .aab (Android App Bundle) file