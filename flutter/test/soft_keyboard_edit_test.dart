// Custom build: regression tests for the soft-keyboard diff.
//
// The bug these cover: typing with the phone's Japanese IME dropped characters,
// because the old diff assumed the IME only ever appended to the field.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/soft_keyboard_edit.dart';

void main() {
  // The hidden field is pre-filled with this so backspace always has something
  // to eat; every real edit happens after it.
  const pad = '1111';

  SoftKeyboardEdit edit(String oldV, String newV) =>
      computeSoftKeyboardEdit(oldV, newV);

  group('plain typing', () {
    test('appending one character sends just that character', () {
      expect(edit(pad, '${pad}a'), const SoftKeyboardEdit(0, 'a'));
    });

    test('appending several sends them all', () {
      expect(edit(pad, '${pad}abc'), const SoftKeyboardEdit(0, 'abc'));
    });

    test('backspace erases exactly one', () {
      expect(edit('${pad}abc', '${pad}ab'), const SoftKeyboardEdit(1, ''));
    });

    test('no change sends nothing', () {
      expect(edit('${pad}abc', '${pad}abc').isEmpty, isTrue);
    });
  });

  group('Japanese IME composition', () {
    test('kana replaced by kanji of the SAME length is not dropped', () {
      // The old code hit `if (newValue.length == oldValue.length) { // ? }`
      // and sent nothing at all.
      expect(edit('$padにほん', '$pad日本ご'),
          const SoftKeyboardEdit(3, '日本ご'));
    });

    test('four kana converted to two kanji erases all four', () {
      // The old code sent a single VK_BACK and never sent the kanji.
      expect(edit('$padにほんご', '$pad日本語'),
          const SoftKeyboardEdit(4, '日本語'));
    });

    test('composition growing one kana at a time only sends the new one', () {
      expect(edit('$padにほ', '$padにほん'), const SoftKeyboardEdit(0, 'ん'));
    });

    test('committing a conversion that shortens the text', () {
      expect(edit('$padかんじへんかん', '$pad漢字変換'),
          const SoftKeyboardEdit(7, '漢字変換'));
    });

    test('whole composition abandoned', () {
      expect(edit('$padにほんご', pad), const SoftKeyboardEdit(4, ''));
    });
  });

  group('surrogate pairs', () {
    test('an emoji is appended whole', () {
      expect(edit(pad, '$pad😀'), const SoftKeyboardEdit(0, '😀'));
    });

    test('deleting an emoji erases both code units', () {
      expect(edit('$pad😀', pad), const SoftKeyboardEdit(2, ''));
    });

    test('replacing one emoji with another never splits a pair', () {
      // Both start with the same high surrogate 0xD83D, so a naive code-unit
      // prefix would stop between the halves and emit a lone surrogate.
      final e = edit('$pad😀', '$pad😁');
      expect(e.backspaces, 2);
      expect(e.insert, '😁');
      expect(e.insert.runes.length, 1);
    });
  });

  group('clipboard paste path', () {
    test('an empty old value sends the whole new value', () {
      // _handleNonIOSSoftKeyboardInput blanks oldValue for the clipboard case.
      expect(edit('', 'pasted text'), const SoftKeyboardEdit(0, 'pasted text'));
    });
  });
}
