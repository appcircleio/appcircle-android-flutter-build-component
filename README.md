# Appcircle Flutter Build for Android

This component builds your Flutter project for Android with the [Flutter SDK](https://github.com/flutter/flutter).

Required Input Variables
- `$AC_FLUTTER_PROJECT_DIR`: The root directory of your Flutter project where pubspec.yaml file exist.
- `$AC_OUTPUT_TYPE`: Output type for your build file(apk or aab)

Optional Input Variables
- `$AC_FLUTTER_BUILD_MODE`: Specifies Flutter build mode. Defaults to: `release`
- `$AC_FLUTTER_BUILD_EXTRA_ARGS`: Additional custom build arguments. For example: `--split-per-abi`

Output Variables
- `$AC_APK_PATH`: Path for the generated .apk file
- `$AC_AAB_PATH`: Path for the generated .aab (Android App Bundle) file

## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library (Coverage, Open3). No Gemfile or Bundler needed.

```bash
gem install rspec   # once
ruby test/test_main.rb
```

Tests never execute the real Flutter toolchain: subprocess tests run `main.rb` against a fake `flutter` on `PATH` inside a temporary directory. A coverage report is printed at the end of each run.
