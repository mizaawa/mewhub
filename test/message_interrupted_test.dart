import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';

void main() {
  test('a stopped reply survives a save and reload as interrupted', () {
    final msg = ChatMessage(role: Role.assistant, parts: const [TextPart('half a th')], interrupted: true);
    final json = msg.toJson();
    expect(json['interrupted'], isTrue);
    final back = ChatMessage.fromJson(json);
    expect(back.text, 'half a th');
    expect(back.interrupted, isTrue);

    final plain = ChatMessage(role: Role.assistant, parts: const [TextPart('done')]);
    expect(plain.toJson().containsKey('interrupted'), isFalse);
    expect(ChatMessage.fromJson(plain.toJson()).interrupted, isFalse);
    expect(plain.copyWith(interrupted: true).interrupted, isTrue);
  });
}
