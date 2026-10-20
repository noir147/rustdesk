// Custom build: what to send to the peer when the hidden text field changes.
//
// Kept free of imports so it can be unit tested without the app's native
// bindings. See test/soft_keyboard_edit_test.dart.

/// The edit to replay on the peer: erase [backspaces] characters, then type
/// [insert].
class SoftKeyboardEdit {
  final int backspaces;
  final String insert;

  const SoftKeyboardEdit(this.backspaces, this.insert);

  bool get isEmpty => backspaces == 0 && insert.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is SoftKeyboardEdit &&
      other.backspaces == backspaces &&
      other.insert == insert;

  @override
  int get hashCode => Object.hash(backspaces, insert);

  @override
  String toString() => 'SoftKeyboardEdit($backspaces, ${insert.isEmpty ? "''" : insert})';
}

/// Diff [oldValue] against [newValue] on their common prefix.
///
/// The previous logic assumed the IME only ever appends, which holds for a
/// plain ASCII keyboard but not for a Japanese one: composing rewrites the text
/// in place ("にほん" -> "日本"), so a same-length replacement looked like no
/// change at all and a shrink looked like a single backspace with nothing to
/// put back. Comparing prefixes handles append, replace and delete alike.
SoftKeyboardEdit computeSoftKeyboardEdit(String oldValue, String newValue) {
  var i = 0;
  while (i < oldValue.length &&
      i < newValue.length &&
      oldValue.codeUnitAt(i) == newValue.codeUnitAt(i)) {
    i++;
  }
  // Never cut between the halves of a surrogate pair (emoji), or both sides of
  // the edit end up with a lone, meaningless code unit.
  if (i > 0 && i < oldValue.length && i < newValue.length) {
    final prev = newValue.codeUnitAt(i - 1);
    if (prev >= 0xD800 && prev <= 0xDBFF) {
      i--;
    }
  }
  return SoftKeyboardEdit(oldValue.length - i, newValue.substring(i));
}
