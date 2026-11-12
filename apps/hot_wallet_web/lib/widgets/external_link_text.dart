import 'package:flutter/material.dart';

import '../services/external_link.dart';

/// Clickable external URL rendered as an underlined hyperlink that opens in a new tab.
class ExternalLinkText extends StatelessWidget {
  final String url;
  final String? label;
  final double fontSize;
  final double? maxWidth;

  const ExternalLinkText({
    super.key,
    required this.url,
    this.label,
    this.fontSize = 11,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final textWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label ?? url,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              color: Colors.lightBlueAccent,
              decoration: TextDecoration.underline,
              decorationColor: Colors.lightBlueAccent,
            ),
          ),
        ),
        const SizedBox(width: 4),
        const Icon(
          Icons.open_in_new,
          size: 13,
          color: Colors.lightBlueAccent,
        ),
      ],
    );

    final child = maxWidth == null
        ? textWidget
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth!),
            child: textWidget,
          );

    return Tooltip(
      message: url,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        mouseCursor: SystemMouseCursors.click,
        onTap: () => openExternalUrl(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: child,
        ),
      ),
    );
  }
}
