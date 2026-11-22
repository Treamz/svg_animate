import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'timing.dart';

/// One run of an animation: from [begin] to [end], or for ever when [end] is
/// null.
@immutable
class SvgInterval {
  /// See class doc.
  const SvgInterval(this.begin, this.end);

  /// When the run starts, from the start of the document.
  final Duration begin;

  /// When the run stops, from the start of the document, or null when it never
  /// does.
  final Duration? end;

  @override
  bool operator ==(Object other) =>
      other is SvgInterval && other.begin == begin && other.end == end;

  @override
  int get hashCode => Object.hash(begin, end);

  @override
  String toString() => 'SvgInterval($begin, $end)';
}

/// When an animation element runs, worked out ahead of time.
@immutable
class SmilSchedule {
  /// See class doc.
  const SmilSchedule(this.intervals, this.period);

  /// Every run, in order, up to [scheduleHorizon].
  final List<SvgInterval> intervals;

  /// How often the whole schedule repeats, when it does: the runs from the
  /// start of the document onward recur every [period].
  final Duration? period;
}

/// How far ahead runs are worked out. Matches the longest loop a document is
/// played over, beyond which nothing is sampled.
const Duration scheduleHorizon = Duration(seconds: 60);

/// What an animation element needs from the timing parser to be scheduled.
class SmilScheduleEntry {
  /// See class doc.
  const SmilScheduleEntry({
    required this.element,
    required this.id,
    required this.begin,
    required this.activeDuration,
    required this.restart,
  });

  /// The animation element.
  final XmlElement element;

  /// Its `id`, through which other animations refer to it.
  final String? id;

  /// Its `begin` list, as written.
  final String? begin;

  /// How long one run lasts if nothing restarts it, for a run beginning at the
  /// given time; null for a run that never stops by itself.
  final Duration? Function(Duration begin) activeDuration;

  /// Its `restart` attribute: `always`, `whenNotActive` or `never`.
  final String restart;
}

/// A `begin` value this package can resolve without anybody interacting with
/// the document: a clock value, or the begin or end of another animation plus
/// an offset.
sealed class _BeginValue {
  const _BeginValue();
}

class _Offset extends _BeginValue {
  const _Offset(this.offset);
  final Duration offset;
}

class _Syncbase extends _BeginValue {
  const _Syncbase(this.id, {required this.atEnd, required this.offset});
  final String id;
  final bool atEnd;
  final Duration offset;
}

final RegExp _syncbasePattern = RegExp(r'^(.+)\.(begin|end)\s*(?:([+-])\s*(\S.*))?$');

/// Reads one entry of a `begin` list, or null for one that needs an event,
/// `indefinite`, a wallclock time or a repeat of another animation.
_BeginValue? _parseBeginValue(String raw) {
  final String value = raw.trim();
  final Duration? clock = parseClockValue(value);
  if (clock != null) {
    return _Offset(clock);
  }
  final RegExpMatch? match = _syncbasePattern.firstMatch(value);
  if (match == null) {
    return null;
  }
  final String id = match.group(1)!.trim();
  if (id.isEmpty || id.contains(RegExp(r'\s'))) {
    return null;
  }
  var offset = Duration.zero;
  if (match.group(3) != null) {
    final Duration? parsed = parseClockValue(match.group(4)!);
    if (parsed == null) {
      return null;
    }
    offset = match.group(3) == '-' ? -parsed : parsed;
  }
  return _Syncbase(id, atEnd: match.group(2) == 'end', offset: offset);
}

/// The `begin` values of [raw] this package can resolve.
///
/// An element with no `begin` begins at zero.
List<Object> parsedBeginValues(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const <Object>[_Offset(Duration.zero)];
  }
  return <Object>[
    for (final String part in raw.split(';'))
      if (_parseBeginValue(part) case final _BeginValue value) value,
  ];
}

/// The one begin time [raw] gives, when it gives exactly one and it is a clock
/// value; null otherwise.
Duration? singleBeginTime(String? raw) {
  final List<Object> values = parsedBeginValues(raw);
  return values.length == 1 && values.single is _Offset ? (values.single as _Offset).offset : null;
}

/// Whether [raw] asks for anything a single begin time cannot express: more
/// than one time, or a time that depends on another animation.
bool needsSchedule(String? raw) {
  final List<Object> values = parsedBeginValues(raw);
  return values.length > 1 || values.any((Object v) => v is _Syncbase);
}

class _Node {
  _Node(this.entry, this.values);

  final SmilScheduleEntry entry;
  final List<_BeginValue> values;
  final List<SvgInterval> intervals = <SvgInterval>[];

  /// Index into [intervals] of the run in progress, if any.
  int? current;

  bool get everBegun => intervals.isNotEmpty;
}

/// The begin or the end of one run of an animation, as something other
/// animations' begin times are derived from.
@immutable
class _Run {
  const _Run(this.node, this.index, {required this.atEnd, this.attempt = 0});

  final _Node node;
  final int index;
  final bool atEnd;

  /// Distinguishes an end rescheduled after a restart from the one first
  /// predicted, which is withdrawn.
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is _Run &&
      identical(other.node, node) &&
      other.index == index &&
      other.atEnd == atEnd &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(identityHashCode(node), index, atEnd, attempt);
}

class _Dependent {
  const _Dependent(this.node, this.offset);
  final _Node node;
  final Duration offset;
}

/// Works out every run of every animation in [entries] up to
/// [scheduleHorizon], following `begin` values that refer to the begin or end
/// of other animations, and `restart`.
///
/// Returns a schedule for each entry whose `begin` needs one (see
/// [needsSchedule]); the others keep their single begin time. An entry that
/// never runs gets a schedule with no intervals.
///
/// Event-driven `begin` values are ignored: there is no interactive document to
/// fire them.
Map<XmlElement, SmilSchedule> scheduleSmilAnimations(List<SmilScheduleEntry> entries) {
  final List<_Node> nodes = <_Node>[
    for (final SmilScheduleEntry entry in entries)
      _Node(entry, parsedBeginValues(entry.begin).cast<_BeginValue>()),
  ];
  final Iterable<_Node> scheduled = nodes.where((n) => needsSchedule(n.entry.begin));
  if (scheduled.isEmpty) {
    return const <XmlElement, SmilSchedule>{};
  }

  final Map<String, _Node> byId = <String, _Node>{
    for (final _Node node in nodes)
      if (node.entry.id case final String id) id: node,
  };
  final Map<_Node, List<_Dependent>> onBegin = <_Node, List<_Dependent>>{};
  final Map<_Node, List<_Dependent>> onEnd = <_Node, List<_Dependent>>{};

  // Events at one instant: ends first, then begins, as SMIL orders them. A
  // begin carries the run whose begin or end it was derived from, if any, so
  // that it can be withdrawn when that run is cut short.
  final queue = SplayTreeMap<int, ({List<(_Node, int)> ends, List<(_Node, _Run?)> begins})>();
  final Set<_Run> withdrawn = <_Run>{};
  ({List<(_Node, int)> ends, List<(_Node, _Run?)> begins}) at(Duration time) => queue.putIfAbsent(
    time.inMicroseconds,
    () => (ends: <(_Node, int)>[], begins: <(_Node, _Run?)>[]),
  );

  void scheduleBegin(_Node node, Duration time, [_Run? origin]) {
    if (time <= scheduleHorizon) {
      at(time).begins.add((node, origin));
    }
  }

  for (final _Node node in nodes) {
    for (final _BeginValue value in node.values) {
      switch (value) {
        case _Offset(:final Duration offset):
          scheduleBegin(node, offset);
        case _Syncbase(:final String id, :final bool atEnd, :final Duration offset):
          final _Node? source = byId[id];
          if (source != null) {
            (atEnd ? onEnd : onBegin)
                .putIfAbsent(source, () => <_Dependent>[])
                .add(_Dependent(node, offset));
          }
      }
    }
  }

  void notify(Map<_Node, List<_Dependent>> map, _Run run, Duration time, Duration now) {
    for (final _Dependent dependent in map[run.node] ?? const <_Dependent>[]) {
      final Duration when = time + dependent.offset;
      // A time already past when it becomes known cannot begin anything.
      if (when >= now) {
        scheduleBegin(dependent.node, when, run);
      }
    }
  }

  // Ends a run early, because something restarted its animation. Whatever was
  // scheduled from the end it was expected to have is withdrawn, and
  // rescheduled from the end it actually had.
  void cutShort(_Node node, Duration now) {
    final int index = node.current!;
    final run = _Run(node, index, atEnd: true);
    withdrawn.add(run);
    node.intervals[index] = SvgInterval(node.intervals[index].begin, now);
    node.current = null;
    final retry = _Run(node, index, atEnd: true, attempt: 1);
    notify(onEnd, retry, now, now);
  }

  var events = 0;
  const maxEvents = 20000;
  while (queue.isNotEmpty && events < maxEvents) {
    final int key = queue.firstKey()!;
    final ({List<(_Node, int)> ends, List<(_Node, _Run?)> begins}) batch = queue.remove(key)!;
    final now = Duration(microseconds: key);
    for (final (_Node node, int interval) in batch.ends) {
      events++;
      // Stale when a restart cut that run short already.
      if (node.current == interval) {
        node.current = null;
      }
    }
    for (final (_Node node, _Run? origin) in batch.begins) {
      events++;
      if (origin != null && withdrawn.contains(origin)) {
        continue;
      }
      if (node.current != null) {
        final SvgInterval running = node.intervals[node.current!];
        if (running.begin == now) {
          continue; // Asked to begin twice at once.
        }
        if (node.entry.restart != 'always') {
          continue;
        }
        cutShort(node, now);
      } else if (node.entry.restart == 'never' && node.everBegun) {
        continue;
      }
      final Duration? length = node.entry.activeDuration(now);
      final Duration? end = length == null ? null : now + length;
      node.intervals.add(SvgInterval(now, end));
      final int index = node.intervals.length - 1;
      notify(onBegin, _Run(node, index, atEnd: false), now, now);
      if (end == null) {
        node.current = index;
      } else if (end > now) {
        node.current = index;
        if (end <= scheduleHorizon) {
          at(end).ends.add((node, index));
        }
        // The end of a run is known as soon as it begins, which is what lets
        // `begin="other.end-0.1s"` start something before the other ends.
        notify(onEnd, _Run(node, index, atEnd: true), end, now);
      } else {
        notify(onEnd, _Run(node, index, atEnd: true), end, now);
      }
    }
  }

  final Duration? period = _period(scheduled.toList());
  return <XmlElement, SmilSchedule>{
    for (final _Node node in scheduled)
      node.entry.element: SmilSchedule(List<SvgInterval>.unmodifiable(node.intervals), period),
  };
}

/// The interval every scheduled animation repeats on from the start of the
/// document, if they share one.
///
/// Taken from the gaps between the last runs of those that keep restarting,
/// then checked against every run: each run before the last period must recur
/// one period later, and each run after the first period must have occurred
/// one period earlier.
Duration? _period(List<_Node> nodes) {
  const Duration tolerance = Duration(microseconds: 2);
  var period = 0;
  for (final _Node node in nodes) {
    final List<SvgInterval> runs = node.intervals;
    if (runs.length < 3 || runs.last.begin < scheduleHorizon ~/ 2) {
      continue;
    }
    final int gap = (runs.last.begin - runs[runs.length - 2].begin).inMicroseconds;
    if (gap <= 0) {
      return null;
    }
    period = period == 0 ? gap : _leastCommonMultiple(period, gap);
    if (period > scheduleHorizon.inMicroseconds ~/ 3) {
      return null;
    }
  }
  if (period == 0) {
    return null;
  }
  final p = Duration(microseconds: period);

  bool matches(SvgInterval a, SvgInterval b, Duration shift) {
    if ((a.begin + shift - b.begin).abs() > tolerance) {
      return false;
    }
    if (a.end == null || b.end == null) {
      return a.end == null && b.end == null;
    }
    // A run cut short by the horizon has not really ended there.
    if (a.end! + shift >= scheduleHorizon || b.end! >= scheduleHorizon) {
      return true;
    }
    return (a.end! + shift - b.end!).abs() <= tolerance;
  }

  for (final _Node node in nodes) {
    final List<SvgInterval> runs = node.intervals;
    for (final SvgInterval run in runs) {
      if (run.begin + p * 2 <= scheduleHorizon &&
          !runs.any((SvgInterval o) => matches(run, o, p))) {
        return null;
      }
      if (run.begin >= p &&
          run.begin + p <= scheduleHorizon &&
          !runs.any((SvgInterval o) => matches(o, run, p))) {
        return null;
      }
    }
  }
  return p;
}

int _leastCommonMultiple(int a, int b) {
  int x = a, y = b;
  while (y != 0) {
    final int r = x % y;
    x = y;
    y = r;
  }
  return a ~/ x * b;
}
