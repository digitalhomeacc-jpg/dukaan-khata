import 'package:material_ui/material_ui.dart';

/// Save in an app bar that always works on the first tap.
///
/// On iPhone (web), a tap while the keyboard is open first closes the keyboard; the page jumps and the tap
/// lands where the button was. So this saves as soon as the finger touches it, shows that it is saving, and
/// never saves twice.
class SaveButton extends StatefulWidget {
  const SaveButton({super.key, required this.onSave, this.label = 'Save', this.enabled = true});

  /// Does the saving; the button shows "Saving…" until it finishes.
  final Future<void> Function() onSave;
  final String label;
  final bool enabled;

  @override
  State<SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<SaveButton> {
  var _busy = false;

  Future<void> _go() async {
    if (_busy || !widget.enabled) return;
    _busy = true;
    if (mounted) setState(() {});
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await widget.onSave();
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Listener(
      onPointerDown: (_) => _go(),
      child: FilledButton(
        onPressed: widget.enabled && !_busy ? _go : null,
        child: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(widget.label),
      ),
    ),
  );
}
