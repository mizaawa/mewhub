import '../core/util.dart';

class ChatFolder {
  ChatFolder({String? id, required this.assistantId, required this.name}) : id = id ?? newId();

  final String id;
  final String assistantId;
  final String name;

  ChatFolder copyWith({String? name}) => ChatFolder(id: id, assistantId: assistantId, name: name ?? this.name);

  factory ChatFolder.fromJson(Map<String, dynamic> json) =>
      ChatFolder(id: asStr(json['id']), assistantId: asStr(json['assistantId']), name: asStr(json['name']));

  Map<String, dynamic> toJson() => {'id': id, 'assistantId': assistantId, 'name': name};
}
