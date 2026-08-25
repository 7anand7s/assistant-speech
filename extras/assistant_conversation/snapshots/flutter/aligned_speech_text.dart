import "package:flutter/material.dart";

import "speech_clip.dart";

/// Selectable text whose currently spoken word is highlighted.
///
/// Word indices deliberately follow the backend's `\\w` token contract, so
/// punctuation and whitespace remain visible without shifting forced-alignment
/// timestamps. Markdown markers are shown as plain text only while narration
/// is active; the normal rich renderer returns as soon as playback ends.
class AlignedSpeechText extends StatelessWidget {
  final String text;
  final int activeWordIndex;
  final TextStyle style;
  final Color highlightColor;
  final Color highlightTextColor;

  const AlignedSpeechText({
    super.key,
    required this.text,
    required this.activeWordIndex,
    required this.style,
    required this.highlightColor,
    required this.highlightTextColor,
  });

  @override
  Widget build(BuildContext context) {
    final visibleText = assistantSpokenText(text);
    final tokens = RegExp(r"[\w']+|\s+|[^\w\s]+")
        .allMatches(visibleText)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    var wordIndex = -1;
    return SelectableText.rich(
      TextSpan(
        children: tokens.map((token) {
          final isWord = RegExp(r"^[\w']+$").hasMatch(token);
          if (isWord) wordIndex += 1;
          final highlighted = isWord && wordIndex == activeWordIndex;
          return TextSpan(
            text: token,
            style: style.copyWith(
              color: highlighted ? highlightTextColor : style.color,
              backgroundColor:
                  highlighted ? highlightColor : Colors.transparent,
              fontWeight: highlighted ? FontWeight.w800 : style.fontWeight,
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}
