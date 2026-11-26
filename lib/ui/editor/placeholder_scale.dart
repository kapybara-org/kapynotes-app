import 'package:material_ui/material_ui.dart';

/// A placeholder's widget as the field draws it: [child] built at the size
/// the text is before scaling, words included.
///
/// The field scales a placeholder's widget whole with the text, the way it
/// draws the words around it, so words inside it that took the text scale too
/// would grow twice. A [PlaceholderTooltip] in it is drawn over everything
/// else instead, outside the field's scaling, so it takes the scale back.
class PlaceholderScale extends StatelessWidget {
  const PlaceholderScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _ScaleOutside(
    scaler: MediaQuery.textScalerOf(context),
    child: MediaQuery.withNoTextScaling(child: child),
  );
}

class _ScaleOutside extends InheritedWidget {
  const _ScaleOutside({required this.scaler, required super.child});

  final TextScaler scaler;

  @override
  bool updateShouldNotify(_ScaleOutside oldWidget) =>
      scaler != oldWidget.scaler;
}

/// A [Tooltip] whose words are at the scale of the writing around it, in a
/// [PlaceholderScale] too.
class PlaceholderTooltip extends StatelessWidget {
  const PlaceholderTooltip({
    super.key,
    required this.message,
    this.triggerMode,
    required this.child,
  });

  final String message;
  final TooltipTriggerMode? triggerMode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outside = context.dependOnInheritedWidgetOfExactType<_ScaleOutside>();
    if (outside == null) {
      return Tooltip(message: message, triggerMode: triggerMode, child: child);
    }
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: outside.scaler),
      child: Tooltip(
        message: message,
        triggerMode: triggerMode,
        child: MediaQuery.withNoTextScaling(child: child),
      ),
    );
  }
}
