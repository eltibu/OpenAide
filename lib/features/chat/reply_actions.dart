import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../notes/notes_api.dart';
import 'chat_controller.dart';
import 'composer_draft.dart';
import 'file_details.dart' show FileDetailsScreen;
import 'output_editor.dart';
import 'markdown_extras.dart';
import 'read_aloud.dart';

/// The web UI's thumbs-up reasons, then its thumbs-down ones.
const likeReasons = {
  'accurate_information': 'Accurate information',
  'followed_instructions_perfectly': 'Followed instructions perfectly',
  'showcased_creativity': 'Showcased creativity',
  'positive_attitude': 'Positive attitude',
  'attention_to_detail': 'Attention to detail',
  'thorough_explanation': 'Thorough explanation',
  'other': 'Other',
};
const dislikeReasons = {
  'dont_like_the_style': "Don't like the style",
  'too_verbose': 'Too verbose',
  'not_helpful': 'Not helpful',
  'not_factually_correct': 'Not factually correct',
  'didnt_fully_follow_instructions': "Didn't fully follow instructions",
  'refused_when_it_shouldnt_have': "Refused when it shouldn't have",
  'being_lazy': 'Being lazy',
  'other': 'Other',
};

/// The rating on a reply: 1, -1 or null.
int? ratingOf(ChatMessage m) {
  final r = (m.extra['annotation'] as Map?)?['rating'];
  return r is num ? r.toInt() : int.tryParse('${r ?? ''}');
}

/// Thumbs up or down on a reply, then (as on the web) a sheet asking why.
Future<void> rateReply(
  BuildContext context,
  WidgetRef ref,
  ChatMessage reply,
  int rating,
) async {
  final controller = ref.read(chatControllerProvider.notifier);
  final undo = ratingOf(reply) == rating;
  await controller.rate(reply, rating);
  if (undo || !context.mounted) return;
  final reasons = rating > 0 ? likeReasons : dislikeReasons;
  String? reason;
  int? score =
      ((reply.extra['annotation'] as Map?)?['details'] as Map?)?['rating']
          as int?;
  final comment = TextEditingController();
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rating > 0 ? 'What was good?' : 'What went wrong?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            // The web's 1 to 10: thumbs down allows 1-5, thumbs up 6-10.
            Row(
              children: [
                for (var n = 1; n <= 10; n++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: Semantics(
                        label: 'Rate $n out of 10',
                        child: ChoiceChip(
                          showCheckmark: false,
                          padding: EdgeInsets.zero,
                          labelPadding: EdgeInsets.zero,
                          label: SizedBox(
                            width: double.infinity,
                            child: Text('$n', textAlign: TextAlign.center),
                          ),
                          selected: score == n,
                          onSelected: (rating > 0 ? n < 6 : n > 5)
                              ? null
                              : (on) => setSheet(() => score = on ? n : null),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '1 - Awful',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    '10 - Amazing',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in reasons.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: reason == e.key,
                    onSelected: (on) =>
                        setSheet(() => reason = on ? e.key : null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: comment,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Tell more (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Send feedback'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  final text = comment.text.trim();
  // Not disposed: the dialog's text field still builds while it closes.
  if (sent == true && (reason != null || text.isNotEmpty || score != null)) {
    await controller.rate(
      reply,
      rating,
      reason: reason ?? '',
      comment: text,
      score: score,
    );
  }
}

/// The regenerate button's menu: the web UI's Try again, Add details, More
/// concise, or your own hint.
class RegenerateButton extends ConsumerWidget {
  const RegenerateButton({super.key, required this.reply, required this.color});
  final ChatMessage reply;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    // Settings > Interface > Regenerate menu off: one tap tries again.
    final ui = ref.watch(userSettingsProvider).value?['ui'] as Map?;
    if (ui?['regenerateMenu'] == false) {
      return IconButton(
        tooltip: 'Regenerate',
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.refresh, size: 18, color: color),
        onPressed: () => controller.regenerate(reply),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Regenerate',
      icon: Icon(Icons.refresh, size: 18, color: color),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelected: (v) async {
        if (v == 'again') return controller.regenerate(reply);
        if (v != 'own') return controller.regenerate(reply, hint: v);
        final hint = await askText(
          context,
          title: 'How should it change?',
          hint: 'Shorter, friendlier, with an example...',
          action: 'Regenerate',
        );
        if (hint != null && hint.trim().isNotEmpty) {
          await controller.regenerate(reply, hint: hint);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'again',
          child: ListTile(
            leading: Icon(Icons.refresh),
            title: Text('Try again'),
          ),
        ),
        PopupMenuItem(
          value: 'Add Details',
          child: ListTile(
            leading: Icon(Icons.unfold_more),
            title: Text('Add details'),
          ),
        ),
        PopupMenuItem(
          value: 'More Concise',
          child: ListTile(
            leading: Icon(Icons.unfold_less),
            title: Text('More concise'),
          ),
        ),
        PopupMenuItem(
          value: 'own',
          child: ListTile(
            leading: Icon(Icons.edit_note),
            title: Text('Your own instructions…'),
          ),
        ),
      ],
    );
  }
}

/// Speaks this one reply; tap again to stop.
class SpeakButton extends ConsumerWidget {
  const SpeakButton({super.key, required this.reply, required this.color});
  final ChatMessage reply;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speaker = ref.watch(readAloudProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: speaker.speaking,
      builder: (context, speaking, _) => IconButton(
        tooltip: speaking ? 'Stop reading' : 'Read aloud',
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: color,
        icon: Icon(
          speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
        ),
        onPressed: () => speaking
            ? speaker.stop()
            : ref.read(chatControllerProvider.notifier).readOut(reply),
      ),
    );
  }
}

/// Everything else you can do with a reply, under "⋯".
class ReplyMoreButton extends ConsumerWidget {
  const ReplyMoreButton({
    super.key,
    required this.reply,
    required this.color,
    required this.isLast,
  });
  final ChatMessage reply;
  final Color color;
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final tables = markdownTablesAsCsv(reply.content);
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz, size: 18, color: color),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelected: (v) async {
        switch (v) {
          case 'continue':
            await controller.continueReply(reply);
          case 'edit':
            await editReply(context, ref, reply);
          case 'note':
            await _saveAsNote(context, ref, reply);
          case 'csv':
            await Clipboard.setData(ClipboardData(text: tables.join('\n\n')));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    tables.length == 1
                        ? 'Table copied as CSV'
                        : '${tables.length} tables copied as CSV',
                  ),
                ),
              );
            }
          case 'info':
            await showReplyInfo(context, reply);
          case 'delete':
            if (await confirm(
              context,
              'Delete this reply?',
              'It is removed from the chat on the server too.',
            )) {
              await controller.deleteMessage(reply);
            }
        }
      },
      itemBuilder: (_) => [
        if (isLast)
          const PopupMenuItem(
            value: 'continue',
            child: ListTile(
              leading: Icon(Icons.play_arrow_outlined),
              title: Text('Continue'),
              subtitle: Text('Keep writing where it stopped'),
            ),
          ),
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
          ),
        ),
        const PopupMenuItem(
          value: 'note',
          child: ListTile(
            leading: Icon(Icons.note_add_outlined),
            title: Text('Save as a note'),
          ),
        ),
        if (tables.isNotEmpty)
          const PopupMenuItem(
            value: 'csv',
            child: ListTile(
              leading: Icon(Icons.table_chart_outlined),
              title: Text('Copy table as CSV'),
            ),
          ),
        const PopupMenuItem(
          value: 'info',
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Info'),
            subtitle: Text('Model, time and tokens'),
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Delete'),
          ),
        ),
      ],
    );
  }
}

/// Edits a reply's text: Save changes it, Save as copy keeps the original
/// as another version.
Future<void> editReply(
  BuildContext context,
  WidgetRef ref,
  ChatMessage reply,
) async {
  // A reply with structured output edits item by item, as on the web.
  final output = reply.extra['output'];
  if (output is List && output.isNotEmpty) {
    final edit = await editOutput(context, output);
    if (edit == null) return;
    await ref
        .read(chatControllerProvider.notifier)
        .editReplyOutput(reply, edit.output, asCopy: edit.asCopy);
    return;
  }
  final text = TextEditingController(text: reply.content);
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit reply'),
      content: SizedBox(
        width: 560,
        child: TextField(
          controller: text,
          autofocus: true,
          minLines: 3,
          maxLines: 14,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'copy'),
          child: const Text('Save as copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'save'),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  final value = text.text;
  // Not disposed: the dialog's text field still builds while it closes.
  if (choice == null || value.trim().isEmpty) return;
  await ref
      .read(chatControllerProvider.notifier)
      .editReply(reply, value, asCopy: choice == 'copy');
}

Future<void> _saveAsNote(
  BuildContext context,
  WidgetRef ref,
  ChatMessage reply,
) async {
  final chat = ref.read(chatControllerProvider).chat;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await NotesApi(ref.read(clientProvider))
        .create(chat?.title ?? 'From a chat', reply.content);
    messenger.showSnackBar(const SnackBar(content: Text('Saved to Notes')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
  }
}

/// Model, time and token use for a reply (the web UI's Info).
Future<void> showReplyInfo(BuildContext context, ChatMessage reply) {
  final usage = (reply.extra['usage'] as Map?)?.cast<String, dynamic>() ?? {};
  final when = DateTime.fromMillisecondsSinceEpoch(reply.timestamp * 1000);
  String label(String key) {
    final words = key.replaceAll('_', ' ');
    return words[0].toUpperCase() + words.substring(1);
  }

  String value(Object? v) {
    if (v is num && v is! int && v != v.roundToDouble()) {
      return v.toStringAsFixed(2);
    }
    if (v is Map) {
      return v.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    }
    return '$v';
  }

  final rows = <(String, String)>[
    if (reply.model != null) ('Model', reply.model!),
    ('Sent', MaterialLocalizations.of(context).formatFullDate(when)),
    (
      'Time',
      MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(when)),
    ),
    for (final e in usage.entries)
      if (e.value != null) (label(e.key), value(e.value)),
  ];
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        children: [
          Text('Reply info', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(
                      k,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(child: SelectableText(v)),
                ],
              ),
            ),
          if (usage.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The server did not record token use for this reply.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Suggested next questions under the last reply; tapping one asks it.
class FollowUps extends ConsumerWidget {
  const FollowUps({super.key, required this.reply});
  final ChatMessage reply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = (reply.extra['followUps'] as List? ?? const [])
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (list.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Follow up',
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          for (final q in list)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              // Settings > Chats can put it in the box to edit first.
              onTap: () =>
                  (ref.read(userSettingsProvider).value?['ui']
                          as Map?)?['insertFollowUpPrompt'] ==
                      true
                  ? ref.read(composerDraftProvider.notifier).put(q)
                  : ref.read(chatControllerProvider.notifier).send(q),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(q)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A source the reply drew on: its name, where it is, and the passages
/// the model read (the web UI's citation window).
Future<void> showSource(BuildContext context, Source source) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(source.name, style: Theme.of(context).textTheme.titleMedium),
          if (source.url != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(
                source.url!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: () => launchUrl(
                Uri.parse(source.url!),
                mode: LaunchMode.externalApplication,
              ),
            ),
          if (source.fileId != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              icon: const Icon(Icons.description_outlined, size: 16),
              label: const Text('View source'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => FileDetailsScreen(
                    fileId: source.fileId!,
                    name: source.name,
                  ),
                ),
              ),
            ),
          if (source.passages.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('No quoted text was saved for this source.'),
            ),
          for (final p in source.passages) ...[
            const SizedBox(height: 12),
            if (p.relevance != null)
              Text(
                'Relevance ${(p.relevance! * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(p.text),
            ),
          ],
        ],
      ),
    ),
  );
}

/// The starter prompts a new chat offers (the model's own, else the
/// server's), like the web UI's suggestions under the greeting.
List<({String title, String subtitle, String content})> promptSuggestions(
  Map<String, dynamic>? modelMeta,
  Map<String, dynamic>? config,
) {
  final raw =
      (modelMeta?['suggestion_prompts'] as List?) ??
      (config?['default_prompt_suggestions'] as List?) ??
      const [];
  final out = <({String title, String subtitle, String content})>[];
  for (final s in raw.whereType<Map>()) {
    final content = '${s['content'] ?? ''}'.trim();
    if (content.isEmpty) continue;
    final title = s['title'];
    final parts = title is List
        ? title.map((t) => '$t').toList()
        : [if (title != null) '$title'];
    out.add((
      title: parts.isNotEmpty && parts.first.isNotEmpty ? parts.first : content,
      subtitle: parts.length > 1 ? parts[1] : '',
      content: content,
    ));
  }
  return out;
}

Future<String?> askText(
  BuildContext context, {
  required String title,
  String? hint,
  String action = 'OK',
}) async {
  final text = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: text,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: Text(action),
        ),
      ],
    ),
  );
  // Not disposed: the dialog's text field still builds while it closes.
  return value;
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;
