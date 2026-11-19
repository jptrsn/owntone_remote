import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/outputs/output.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';

Output _o(String id, {bool selected = false}) => Output(
  id: id,
  name: 'Name-$id',
  type: 'Chromecast',
  selected: selected,
  hasPassword: false,
  needsAuthKey: false,
  volume: 50,
);

/// R-09 selection-set math: one checkbox tap recomputes the full selected-id
/// list that goes out in the single `PUT /api/outputs/set` — never N
/// per-output toggles.
void main() {
  final outputs = [
    _o('a', selected: true),
    _o('b'),
    _o('c'),
    _o('d', selected: true),
  ];

  test('enabling an unselected output adds it, server order kept', () {
    expect(OutputsController.selectedIdsAfterToggle(outputs, 'b'), [
      'a',
      'b',
      'd',
    ]);
  });

  test('disabling a selected output removes it, others untouched', () {
    expect(OutputsController.selectedIdsAfterToggle(outputs, 'a'), ['d']);
  });

  test('multi-select: toggling one of many keeps the rest selected', () {
    expect(OutputsController.selectedIdsAfterToggle(outputs, 'd'), ['a']);
  });

  test('disabling the last selected output yields the empty set', () {
    final only = [_o('x', selected: true), _o('y')];
    expect(OutputsController.selectedIdsAfterToggle(only, 'x'), <String>[]);
  });

  test('empty set plus an enable yields that single id', () {
    final none = [_o('x'), _o('y')];
    expect(OutputsController.selectedIdsAfterToggle(none, 'y'), ['y']);
  });

  test('unknown id leaves the set unchanged', () {
    expect(OutputsController.selectedIdsAfterToggle(outputs, 'zzz'), [
      'a',
      'd',
    ]);
  });

  // R-09 (issue #20): the UI's last-output confirm / stop-on-confirm keys
  // on exactly this predicate — silent multi-deselect vs warned last
  // deselect.
  group('emptiesSelection (issue #20 last-deselect predicate)', () {
    test('the ONLY selected output empties the set when deselected', () {
      final only = [_o('x', selected: true), _o('y')];
      expect(OutputsController.emptiesSelection(only, 'x'), isTrue);
    });

    test('one of several selected does NOT empty the set', () {
      expect(OutputsController.emptiesSelection(outputs, 'a'), isFalse);
      expect(OutputsController.emptiesSelection(outputs, 'd'), isFalse);
    });

    test('enabling never counts as emptying', () {
      expect(OutputsController.emptiesSelection(outputs, 'b'), isFalse);
      final none = [_o('x'), _o('y')];
      expect(OutputsController.emptiesSelection(none, 'y'), isFalse);
    });

    test('zero selected or unknown id never matches', () {
      final none = [_o('x'), _o('y')];
      expect(OutputsController.emptiesSelection(none, 'x'), isFalse);
      expect(OutputsController.emptiesSelection(outputs, 'zzz'), isFalse);
    });
  });
}
