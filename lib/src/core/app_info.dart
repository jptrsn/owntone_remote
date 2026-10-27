/// App identity for the About screen (R-14, unit 008).
///
/// Compile-time constants — deliberately **not** `package_info_plus`: the
/// only consumer is a read-only About screen, and a plugin (platform
/// channel + async load) is not justified for two strings. `kAppVersion`
/// mirrors `version:` in pubspec.yaml — the release process (and
/// `about_screen_test.dart`) keep the two in sync.
library;

const String kAppName = 'OwnTone Remote';
const String kAppVersion = '0.1.0+1';
