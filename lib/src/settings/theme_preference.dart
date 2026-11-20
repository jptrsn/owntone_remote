import 'package:flutter/material.dart' show ChangeNotifier, ThemeMode;

import 'settings_store.dart';

/// Listenable holder for the theme preference (R-26). [SettingsStore] is
/// not listenable and `MaterialApp.themeMode` needs a rebuild on change, so
/// the app watches this instead of the store. The store stays the single
/// source of truth — this is a mirror seeded from it at construction (the
/// read-validate fallback for corrupt values lives in the store getter).
class ThemePreference extends ChangeNotifier {
  ThemePreference(this._store) : _mode = _store.themeMode;

  final SettingsStore _store;
  ThemeMode _mode;

  ThemeMode get mode => _mode;

  /// Optimistic like the rocker-step row: notify first (the scheme flips
  /// with no restart), persist after.
  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _store.saveThemeMode(mode);
  }
}
