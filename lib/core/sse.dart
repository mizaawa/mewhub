import 'dart:convert';

class SseEvent {
  SseEvent(this.event, this.data, this.id);
  final String? event;
  final String data;
  final String? id;
}

/// Decodes a `text/event-stream` byte stream into events (WHATWG spec subset).
///
/// Some OpenAI-compatible gateways send bare JSON lines without `data:`
/// framing; those lines are passed through as events too.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  String? event;
  String? id;
  final data = StringBuffer();
  var hasData = false;
  await for (final raw in lines) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) {
      if (hasData) yield SseEvent(event, data.toString(), id);
      event = null;
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue;
    if (line.startsWith('{') && !hasData) {
      yield SseEvent(event, line, id);
      continue;
    }
    final idx = line.indexOf(':');
    final field = idx < 0 ? line : line.substring(0, idx);
    var value = idx < 0 ? '' : line.substring(idx + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
      case 'id':
        id = value;
    }
  }
  if (hasData) yield SseEvent(event, data.toString(), id);
}
