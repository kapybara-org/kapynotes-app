import 'package:material_ui/material_ui.dart';

import '../ai/recording_translation.dart';
import '../core/theme.dart';
import '../speech/languages.dart';
import 'editor/editor_context_menu.dart';
import 'kapy_ai/kapy_ai_parts.dart';
import 'settings_rows.dart' show SettingsSegmented;
import 'sharing_sheet.dart' show SharingSheetFrame;

/// What Translate to… was asked for.
typedef TranslatePick = ({TranslateScope scope, Language language});

/// Translate to…'s picker over the voice window: a small dialog beside a
/// pointer, and a sheet on a phone when [asSheet]. Null when it was closed
/// without a pick.
Future<TranslatePick?> showTranslatePicker(
  BuildContext context, {
  required bool asSheet,
  required TranslateScope scope,
  required bool hasSummary,
  required List<Language> yours,
}) {
  final picker = TranslatePicker(
    scope: scope,
    hasSummary: hasSummary,
    yours: yours,
    compact: asSheet,
  );
  if (!asSheet) {
    return showDialog<TranslatePick>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: context.palette.surfaceBackground,
        child: SizedBox(width: 360, height: 480, child: picker),
      ),
    );
  }
  return showModalBottomSheet<TranslatePick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (context) => SharingSheetFrame(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: picker,
      ),
    ),
  );
}

/// The Summary / Transcript switch, the person's own languages, and a
/// search over every language. A tap on a language picks it.
class TranslatePicker extends StatefulWidget {
  const TranslatePicker({
    super.key,
    required this.scope,
    required this.hasSummary,
    required this.yours,
    this.compact = false,
  });

  /// What to translate to start with: the page in view.
  final TranslateScope scope;
  final bool hasSummary;

  /// The app's and the device's languages, then the recent picks.
  final List<Language> yours;

  /// On a phone: rows with 44 pt targets.
  final bool compact;

  @override
  State<TranslatePicker> createState() => _TranslatePickerState();
}

class _TranslatePickerState extends State<TranslatePicker> {
  late TranslateScope _scope = widget.hasSummary
      ? widget.scope
      : TranslateScope.transcript;
  final TextEditingController _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _pick(Language language) => Navigator.of(
    context,
  ).pop<TranslatePick>((scope: _scope, language: language));

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final searching = _query.text.trim().isNotEmpty;
    final found = searchLanguages(_query.text);
    final label = kapyText(
      12,
      16,
      palette.textTertiary,
      weight: FontWeight.w600,
    );
    return Column(
      key: const ValueKey('voice-translate-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Translate to…',
                  style: kapyText(
                    15,
                    20,
                    palette.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(
                width: 176,
                child: SettingsSegmented<TranslateScope>(
                  options: TranslateScope.values,
                  selected: _scope,
                  width: 176,
                  labelFor: (scope) => switch (scope) {
                    TranslateScope.summary => 'Summary',
                    TranslateScope.transcript => 'Transcript',
                  },
                  keyFor: (scope) =>
                      ValueKey('voice-translate-scope-${scope.name}'),
                  enabledFor: (scope) =>
                      scope == TranslateScope.transcript || widget.hasSummary,
                  onSelected: (scope) => setState(() => _scope = scope),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Container(
            constraints: BoxConstraints(minHeight: widget.compact ? 44 : 34),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: palette.controlBackground,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: palette.separator),
            ),
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.searchRounded,
                  size: 15,
                  color: palette.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('voice-translate-search'),
                    contextMenuBuilder: kapyTextFieldMenu,
                    controller: _query,
                    cursorColor: palette.selectedBorder,
                    style: kapyText(13.5, 20, palette.textPrimary),
                    decoration: InputDecoration.collapsed(
                      hintText: 'Search every language',
                      hintStyle: kapyText(13.5, 20, palette.textTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!searching && widget.yours.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
            child: Text('Your languages', style: label),
          ),
          for (final language in widget.yours)
            _Row(
              key: ValueKey('voice-translate-yours-${language.code}'),
              language: language,
              compact: widget.compact,
              onPressed: () => _pick(language),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text('All languages', style: label),
          ),
        ],
        Expanded(
          child: found.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No language by that name',
                    style: kapyText(13, 19, palette.textTertiary),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('voice-translate-all'),
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: found.length,
                  itemBuilder: (context, index) => _Row(
                    key: ValueKey('voice-translate-all-${found[index].code}'),
                    language: found[index],
                    compact: widget.compact,
                    onPressed: () => _pick(found[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// "हिन्दी · Hindi": a language in its own name, and in English beside it
/// when that differs.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.language,
    required this.compact,
    required this.onPressed,
  });

  final Language language;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onPressed,
      child: Container(
        constraints: BoxConstraints(minHeight: compact ? 44 : 32),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            text: language.own,
            style: kapyText(14, 20, palette.textPrimary),
            children: [
              if (language.own != language.english)
                TextSpan(
                  text: ' · ${language.english}',
                  style: kapyText(13, 20, palette.textTertiary),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
