import 'package:flutter/material.dart';

/// Shared primitives for the caregiver panel, from the design canvas
/// (`Caregiver Panel.dc.html`).
///
/// The panel is one product with sections, not ten loose screens, so every
/// screen in it is built from the same small set of pieces: a scaffold with an
/// eyebrow and a title, cards, rows, toggles, segmented choices, big stats and
/// notes. Keeping them here is what stops the eleventh screen inventing its own
/// spacing.
///
/// The palette is the design's, converted from OKLCH — a lavender family around
/// hue 300 with a single green for "this is going well" and a sand for "this is
/// where support goes". **Sand, never red:** a weak step is not a failure, it is
/// where the work is.
abstract final class CaregiverColors {
  static const bg = Color(0xFFF8F4FF);
  static const surface = Colors.white;
  static const ink = Color(0xFF312940);
  static const subFg = Color(0xFF605A6C);
  static const dim = Color(0xFF827D8C);
  static const eyebrowFg = Color(0xFF6E6284);
  static const accent = Color(0xFF714BA8);
  static const green = Color(0xFF1D7D3E);

  static const line = Color(0x1A231940);
  static const faint = Color(0x24231940);

  /// "Done" — a step or phrase that is finished.
  static const tagDoneBg = Color(0xFFD4F8DA);
  static const tagDoneFg = Color(0xFF005820);

  /// "Held" — set aside for today, or an audio clip missing. Sand, never red.
  static const tagHeldBg = Color(0xFFFFEACA);
  static const tagHeldFg = Color(0xFF764600);

  /// "Now" — the thing currently happening.
  static const tagNowBg = Color(0xFFF1E7FF);
  static const tagNowFg = Color(0xFF53347E);

  static const levelOnBg = Color(0xFFF4EBFF);
  static const dotOff = Color(0xFFA6A2B0);

  static const bannerBg = Color(0xFFFFEDDB);
  static const bannerBd = Color(0xFFDEB58E);
  static const bannerTagFg = Color(0xFF7C4607);
  static const bannerFg = Color(0xFF503721);

  /// A step the person keeps backing up from. Sand: support goes here.
  static const weakBar = Color(0xFFC7944A);
}

/// The frame every caregiver-panel screen sits in: eyebrow, title, optional
/// subtitle, then the content in a single readable column.
class CaregiverScaffold extends StatelessWidget {
  const CaregiverScaffold({
    super.key,
    required this.title,
    required this.children,
    this.eyebrow,
    this.subtitle,
    this.actions,
    this.footer,
    this.loading = false,
    this.error,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final List<Widget> children;

  /// App-bar trailing actions.
  final List<Widget>? actions;

  /// Pinned to the bottom, clear of the scroll — for a primary action that must
  /// stay reachable however long the list gets.
  final Widget? footer;

  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaregiverColors.bg,
      appBar: AppBar(
        backgroundColor: CaregiverColors.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: CaregiverColors.ink,
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: CaregiverColors.ink,
          ),
        ),
        actions: actions,
      ),
      body: SafeArea(
        top: false,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error!, textAlign: TextAlign.center),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                          children: [
                            if (eyebrow != null) ...[
                              Text(
                                eyebrow!,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.4,
                                  color: CaregiverColors.eyebrowFg,
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            if (subtitle != null) ...[
                              Text(
                                subtitle!,
                                style: const TextStyle(
                                  fontSize: 15.5,
                                  height: 1.5,
                                  color: CaregiverColors.subFg,
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],
                            ...children,
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (footer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: SizedBox(
                            width: double.infinity,
                            child: footer,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class CaregiverCard extends StatelessWidget {
  const CaregiverCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(18, 18, 18, 20),
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: CaregiverColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CaregiverColors.line),
      ),
      child: child,
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: body,
    );
  }
}

/// A small uppercase label above a field or block.
class CaregiverFieldLabel extends StatelessWidget {
  const CaregiverFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
      color: CaregiverColors.dim,
    ),
  );
}

/// The one number a screen is about, with a label above and a reading below.
class CaregiverBigStat extends StatelessWidget {
  const CaregiverBigStat({
    super.key,
    required this.tag,
    required this.value,
    this.meta,
    this.small = false,
  });

  final String tag;
  final String value;
  final String? meta;
  final bool small;

  @override
  Widget build(BuildContext context) => CaregiverCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CaregiverFieldLabel(tag),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: small ? 25 : 33,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: CaregiverColors.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (meta != null) ...[
          const SizedBox(height: 6),
          Text(
            meta!,
            style: const TextStyle(
              fontSize: 14,
              height: 1.45,
              color: CaregiverColors.subFg,
            ),
          ),
        ],
      ],
    ),
  );
}

/// A quiet aside. Never a warning — this is where the app explains itself.
class CaregiverNote extends StatelessWidget {
  const CaregiverNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        height: 1.55,
        color: CaregiverColors.subFg,
      ),
    ),
  );
}

/// A standing statement that cannot be dismissed — used where the app has to
/// keep saying something about itself, like the experimental ML banner.
class CaregiverBanner extends StatelessWidget {
  const CaregiverBanner({super.key, required this.tag, required this.text});

  final String tag;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    decoration: BoxDecoration(
      color: CaregiverColors.bannerBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: CaregiverColors.bannerBd),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tag,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.3,
            color: CaregiverColors.bannerTagFg,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            height: 1.55,
            color: CaregiverColors.bannerFg,
          ),
        ),
      ],
    ),
  );
}

/// A small coloured tag on a row: done / held / now.
class CaregiverTag extends StatelessWidget {
  const CaregiverTag({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  const CaregiverTag.done({super.key, this.label = 'done'})
    : background = CaregiverColors.tagDoneBg,
      foreground = CaregiverColors.tagDoneFg;

  const CaregiverTag.held({super.key, this.label = 'held'})
    : background = CaregiverColors.tagHeldBg,
      foreground = CaregiverColors.tagHeldFg;

  const CaregiverTag.now({super.key, this.label = 'now'})
    : background = CaregiverColors.tagNowBg,
      foreground = CaregiverColors.tagNowFg;

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: foreground,
      ),
    ),
  );
}

/// A row in a list: title, optional meta line, optional leading thumbnail,
/// optional tag, and either a chevron (navigates) or a switch (toggles).
class CaregiverRow extends StatelessWidget {
  const CaregiverRow({
    super.key,
    required this.title,
    this.meta,
    this.leading,
    this.tag,
    this.value,
    this.onTap,
    this.switchValue,
    this.onSwitch,
  });

  final String title;
  final String? meta;
  final Widget? leading;
  final Widget? tag;

  /// A right-aligned current value, for rows that show their answer in place.
  final String? value;

  final VoidCallback? onTap;
  final bool? switchValue;
  final ValueChanged<bool>? onSwitch;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 13)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: CaregiverColors.ink,
                        ),
                      ),
                    ),
                    if (tag != null) ...[const SizedBox(width: 8), tag!],
                  ],
                ),
                if (meta != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    meta!,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      color: CaregiverColors.dim,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 12),
            Text(
              value!,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CaregiverColors.subFg,
              ),
            ),
          ],
          if (switchValue != null)
            Switch(
              value: switchValue!,
              onChanged: onSwitch,
              activeTrackColor: CaregiverColors.green,
            )
          else if (onTap != null)
            const Icon(
              Icons.chevron_right,
              color: CaregiverColors.dim,
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

/// A titled group of rows in one card — the panel's basic unit.
class CaregiverSection extends StatelessWidget {
  const CaregiverSection({super.key, this.label, required this.rows});

  final String? label;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label != null) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 9),
          child: CaregiverFieldLabel(label!),
        ),
      ],
      Container(
        decoration: BoxDecoration(
          color: CaregiverColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: CaregiverColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                const Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  color: CaregiverColors.line,
                ),
              rows[i],
            ],
          ],
        ),
      ),
      const SizedBox(height: 22),
    ],
  );
}

/// One choice among a few — used for session length, playback speed, and the
/// dose target.
class CaregiverChoiceChip extends StatelessWidget {
  const CaregiverChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? CaregiverColors.accent : CaregiverColors.surface,
    borderRadius: BorderRadius.circular(11),
    child: InkWell(
      onTap: selected ? null : onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected ? CaregiverColors.accent : CaregiverColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : CaregiverColors.ink,
          ),
        ),
      ),
    ),
  );
}

/// A row of small numbers with labels under them.
class CaregiverStats extends StatelessWidget {
  const CaregiverStats({super.key, required this.items});

  /// (value, label) pairs.
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) => CaregiverCard(
    child: Row(
      children: [
        for (final (value, label) in items)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: CaregiverColors.ink,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: CaregiverColors.dim,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// The panel's primary button.
class CaregiverButton extends StatelessWidget {
  const CaregiverButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      padding: WidgetStatePropertyAll(
        const EdgeInsets.symmetric(vertical: 17),
      ),
      textStyle: WidgetStatePropertyAll(
        const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
    );
    return primary
        ? FilledButton(
            onPressed: onPressed,
            style: style.copyWith(
              backgroundColor: const WidgetStatePropertyAll(
                CaregiverColors.accent,
              ),
            ),
            child: Text(label),
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: style.copyWith(
              foregroundColor: const WidgetStatePropertyAll(
                CaregiverColors.ink,
              ),
              side: const WidgetStatePropertyAll(
                BorderSide(color: CaregiverColors.line, width: 2),
              ),
            ),
            child: Text(label),
          );
  }
}
