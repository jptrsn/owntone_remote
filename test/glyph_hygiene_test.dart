import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for broken upstream MaterialIcons glyphs.
///
/// `Icons.shuffle_on` (0xe5a2, `shuffle_on_baseline`) — and its
/// sharp/rounded/outlined variants — begin with a ~470/512-unit
/// rounded-rectangle contour that, under Flutter's nonzero fill, paints as
/// a SOLID box (measured on the official artifact of this Flutter's font
/// hash 3012db47…: ink/bbox ratio 0.99 at 64 px, vs 0.40 for Icons.shuffle;
/// confirmed independently by a fontTools outline dump and a PIL render).
/// Using it made the enabled shuffle button render as a primary-coloured
/// box. The active state therefore rides on the button (filledTonal +
/// IconButton.color — see _ModeToggle in now_playing_screen.dart).
///
/// Audit method (repeatable): render every `Icons.*` used in lib/ from
/// bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf at 64 px
/// and flag ink/bbox ratio > 0.85 whose glyph is not a legitimately solid
/// shape (stop, remove, dns pass at 1.00/1.00/0.86 as genuine solid forms).
void main() {
  test('lib/ must not use the solid-box Icons.shuffle_on family', () {
    final forbidden = RegExp(
      r'Icons\.shuffle_on(_sharp|_rounded|_outlined)?\b',
    );
    final offenders = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final code = file
          .readAsStringSync()
          .split('\n')
          .map((l) => l.split('//').first)
          .join('\n');
      if (forbidden.hasMatch(code)) offenders.add(file.path);
    }
    expect(offenders, isEmpty, reason: 'see this file\u2019s doc comment');
  });
}
