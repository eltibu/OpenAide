/// Phone actions, so Nexus can stand in for the phone's assistant: "set a
/// timer for 10 minutes", "wake me up at 6:30", "call Mom", "text Sam
/// running late", "open Spotify", "directions to the airport", "turn on
/// the flashlight". These run on the phone (PhoneActions.kt) instead of
/// going to the server; anything else is a normal message.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('nexus/actions');

/// Kept with your other settings on the server; on unless switched off.
const phoneActionsKey = 'nexusPhoneActions';

bool phoneActionsOn(Map? ui) => ui?[phoneActionsKey] != false;

sealed class PhoneAction {
  const PhoneAction();
}

class TimerAction extends PhoneAction {
  const TimerAction(this.seconds);
  final int seconds;
}

class AlarmAction extends PhoneAction {
  const AlarmAction(this.hour, this.minute);
  final int hour;
  final int minute;
}

class CallAction extends PhoneAction {
  const CallAction(this.who);
  final String who;
}

class TextAction extends PhoneAction {
  const TextAction(this.who, this.body);
  final String who;
  final String body;
}

class OpenAppAction extends PhoneAction {
  const OpenAppAction(this.name);
  final String name;
}

class NavigateAction extends PhoneAction {
  const NavigateAction(this.place);
  final String place;
}

class TorchAction extends PhoneAction {
  /// null toggles.
  const TorchAction(this.on);
  final bool? on;
}

const _numbers = {
  'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, //
  'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11,
  'twelve': 12, 'fifteen': 15, 'twenty': 20, 'thirty': 30, 'forty': 40,
  'forty five': 45, 'forty-five': 45, 'sixty': 60, 'ninety': 90,
};

/// Seconds in "5 minutes", "an hour and a half", "1h 30m", "90 seconds".
int? durationSeconds(String text) {
  var t = text.toLowerCase().trim();
  var total = 0.0;
  if (RegExp(r'^half an? hour$').hasMatch(t)) return 1800;
  t = t.replaceAll(RegExp(r'\band a half\b'), 'and 0.5 more');
  final unit = RegExp(
    r'(\d+(?:\.\d+)?|forty[ -]five|[a-z]+)\s*'
    r'(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b',
  );
  String? last;
  for (final m in unit.allMatches(t)) {
    final n = double.tryParse(m[1]!) ?? _numbers[m[1]!]?.toDouble();
    if (n == null) continue;
    final u = m[2]!;
    final per = u.startsWith('h')
        ? 3600
        : u.startsWith('m')
        ? 60
        : 1;
    total += n * per;
    last = u;
  }
  // "an hour and a half": half of the last unit named.
  if (t.contains('0.5 more') && last != null) {
    total +=
        0.5 *
        (last.startsWith('h')
            ? 3600
            : last.startsWith('m')
            ? 60
            : 1);
  }
  return total >= 1 ? total.round() : null;
}

/// (hour, minute) in 24 hours from "7", "6:30", "7 pm", "noon".
(int, int)? clockTime(String text) {
  final t = text.toLowerCase().replaceAll('.', '').trim();
  if (t == 'noon') return (12, 0);
  if (t == 'midnight') return (0, 0);
  final m = RegExp(
    r'^(\d{1,2})(?:[: ](\d{2}))?\s*(am|pm|in the morning|in the evening|tonight)?'
    r'(?:\s+(?:tomorrow|today))?$',
  ).firstMatch(t);
  if (m == null) return null;
  var hour = int.parse(m[1]!);
  final minute = int.tryParse(m[2] ?? '') ?? 0;
  final half = m[3];
  if (hour > 23 || minute > 59) return null;
  if (half == 'pm' || half == 'in the evening' || half == 'tonight') {
    if (hour < 12) hour += 12;
  } else if ((half == 'am' || half == 'in the morning') && hour == 12) {
    hour = 0;
  }
  return (hour, minute);
}

/// The phone action [message] asks for, or null for a normal message.
PhoneAction? parsePhoneAction(String message) {
  RegExp re(String p) => RegExp(p, caseSensitive: false);
  // Names, places and message bodies keep their capitals.
  final t = message
      .trim()
      .replaceAll(RegExp(r'[.!?]+$'), '')
      .replaceFirst(re(r'^(?:hey|ok|okay)\s+nexus[,\s]*'), '')
      .replaceFirst(re(r'^(?:please|can you|could you)\s+'), '')
      .replaceFirst(re(r'\s+please$'), '')
      .trim();
  RegExpMatch? m;
  if ((m = re(r'^(?:set|start)?\s*(?:a\s+)?timer\s+(?:for\s+)?(.+)$')
              .firstMatch(t)) !=
          null ||
      (m = re(r'^(?:set|start)?\s*(?:a\s+)?(.+?)\s+timer$').firstMatch(t)) !=
          null) {
    final seconds = durationSeconds(m![1]!);
    return seconds == null ? null : TimerAction(seconds);
  }
  if ((m = re(
        r'^(?:set\s+(?:an?\s+|my\s+)?alarm|alarm|wake me(?:\s+up)?)\s+(?:for|at)?\s*(.+)$',
      ).firstMatch(t)) !=
      null) {
    final time = clockTime(m![1]!);
    return time == null ? null : AlarmAction(time.$1, time.$2);
  }
  if ((m =
          re(
            r'^(?:turn|switch)\s+(on|off)\s+(?:the\s+|my\s+)?(?:flashlight|torch)$',
          ).firstMatch(t) ??
          re(
            r'^(?:turn|switch)\s+(?:the\s+|my\s+)?(?:flashlight|torch)\s+(on|off)$',
          ).firstMatch(t)) !=
      null) {
    return TorchAction(m![1]!.toLowerCase() == 'on');
  }
  if (re(r'^(?:flashlight|torch)$').hasMatch(t)) {
    return const TorchAction(null);
  }
  if ((m = re(r'^(?:call|phone|ring|dial)\s+(.{1,40})$').firstMatch(t)) !=
      null) {
    final who = m![1]!;
    if (re(r'^(?:me|it|this|that|them|him|her|you)\b').hasMatch(who)) {
      return null;
    }
    return CallAction(who);
  }
  if ((m = re(
        r'^(?:send\s+(?:a\s+)?(?:text|message|sms)\s+to|text|sms|message)\s+'
        r'(.{1,40}?)\s+(?:saying|that says|that|:)\s*(.+)$',
      ).firstMatch(t)) !=
      null) {
    return TextAction(m![1]!, m[2]!);
  }
  if ((m = re(r'^(?:text|sms)\s+(\S+)(?:\s+(.+))?$').firstMatch(t)) != null) {
    return TextAction(m![1]!, m[2] ?? '');
  }
  if ((m = re(
        r'^(?:navigate|directions|get directions|take me|drive me|drive)\s+(?:me\s+)?to\s+(.+)$',
      ).firstMatch(t)) !=
      null) {
    return NavigateAction(m![1]!);
  }
  if ((m = re(r'^(?:open|launch|start)\s+(?:the\s+)?(.{1,30}?)(?:\s+app)?$')
          .firstMatch(t)) !=
      null) {
    return OpenAppAction(m![1]!);
  }
  return null;
}

/// "10 minutes", "1 hour 30 minutes".
String durationWords(int seconds) {
  final h = seconds ~/ 3600;
  final m = seconds % 3600 ~/ 60;
  final s = seconds % 60;
  String part(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  return [
    if (h > 0) part(h, 'hour'),
    if (m > 0) part(m, 'minute'),
    if (s > 0) part(s, 'second'),
  ].join(' ');
}

String clockWords(int hour, int minute) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h:${'$minute'.padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
}

bool _isNumber(String who) =>
    RegExp(r'^\+?[\d\s()\-.]{3,}$').hasMatch(who.trim()) &&
    RegExp(r'\d{3}').hasMatch(who.replaceAll(RegExp(r'\D'), ''));

/// Runs [action]: what to tell you, or null when it isn't a phone action
/// after all (no app by that name), so the message goes to Nexus.
/// [pick] chooses between contacts with the same name.
Future<String?> runPhoneAction(
  PhoneAction action, {
  required Future<Map?> Function(List<Map> people) pick,
}) async {
  Future<String> call(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<String>(method, args) ?? 'done';
    } on MissingPluginException {
      return 'Phone actions work on the phone only.';
    }
  }

  /// A number for [who]: as typed, or from your contacts.
  Future<(String?, String)> numberFor(String asked) async {
    if (_isNumber(asked)) return (asked, asked);
    // "Ana (number ending 34)", as the assistant is told to pick one.
    final ending = RegExp(r'\s*\(number ending (\d+)\)\s*$').firstMatch(asked);
    final who = ending == null ? asked : asked.substring(0, ending.start);
    List? people;
    try {
      people = await _channel.invokeMethod<List>('contacts', {'name': who});
    } on MissingPluginException {
      return (null, 'Phone actions work on the phone only.');
    }
    if (people == null) {
      return (null, 'OpenAide needs to see your contacts to find $who.');
    }
    var list = people.whereType<Map>().toList();
    if (ending != null) {
      final narrowed = list
          .where(
            (p) => '${p['number']}'
                .replaceAll(RegExp(r'\D'), '')
                .endsWith(ending[1]!),
          )
          .toList();
      if (narrowed.isNotEmpty) list = narrowed;
    }
    if (list.isEmpty) return (null, 'No contact called $who.');
    final chosen = list.length == 1 ? list.single : await pick(list);
    if (chosen == null) return (null, '');
    return ('${chosen['number']}', '${chosen['name']}');
  }

  switch (action) {
    case TimerAction(:final seconds):
      final r = await call('timer', {'seconds': seconds});
      return r == 'done' ? 'Timer set for ${durationWords(seconds)}.' : r;
    case AlarmAction(:final hour, :final minute):
      final r = await call('alarm', {'hour': hour, 'minute': minute});
      return r == 'done' ? 'Alarm set for ${clockWords(hour, minute)}.' : r;
    case CallAction(:final who):
      final (number, name) = await numberFor(who);
      if (number == null) return name;
      final r = await call('dial', {'number': number});
      return r == 'done' ? 'Calling $name: tap call.' : r;
    case TextAction(:final who, :final body):
      final (number, name) = await numberFor(who);
      if (number == null) return name;
      final r = await call('sms', {'number': number, 'body': body});
      return r == 'done' ? 'Message to $name ready: tap send.' : r;
    case OpenAppAction(:final name):
      final r = await call('openApp', {'name': name});
      // Not an app: probably meant for Nexus ("open the file I sent").
      return r == 'done' ? 'Opening $name.' : null;
    case NavigateAction(:final place):
      final r = await call('navigate', {'place': place});
      return r == 'done' ? 'Directions to $place.' : r;
    case TorchAction(:final on):
      final r = await call('torch', {'on': on});
      return r == 'on' || r == 'off' ? 'Flashlight $r.' : r;
  }
}

/// Opens the calendar app with a new event filled in, for you to save.
/// Times are milliseconds since the epoch.
Future<String> addCalendarEvent({
  required String title,
  int? start,
  int? end,
  bool allDay = false,
  String? location,
  String? description,
}) async {
  try {
    return await _channel.invokeMethod<String>('calendar', {
          'title': title,
          'start': start,
          'end': end,
          'allDay': allDay,
          'location': location,
          'description': description,
        }) ??
        'done';
  } on MissingPluginException {
    return 'Calendar works on the phone only.';
  }
}
