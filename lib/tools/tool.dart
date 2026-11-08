import '../ai/provider.dart';

/// A tool the model can call. [execute] returns the text sent back to the model.
class AppTool {
  AppTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
    this.needsApproval = false,
    this.displayName,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final Future<String> Function(Map<String, dynamic> args) execute;
  final bool needsApproval;
  final String? displayName;

  ToolSpec get spec => ToolSpec(name: name, description: description, parameters: parameters);
}

Map<String, dynamic> objectSchema(Map<String, dynamic> props, {List<String> required = const []}) => {
  'type': 'object',
  'properties': props,
  if (required.isNotEmpty) 'required': required,
};

Map<String, dynamic> strProp(String description, {List<String>? enumValues}) => {
  'type': 'string',
  'description': description,
  'enum': ?enumValues,
};

Map<String, dynamic> intProp(String description) => {'type': 'integer', 'description': description};

/// Makes a third-party (MCP) input schema acceptable to every provider:
/// the root must be an object schema with a `properties` map. `$schema`
/// is dropped because some OpenAI-compatible gateways reject it.
Map<String, dynamic> normalizeToolSchema(Map<String, dynamic> schema) {
  final out = Map<String, dynamic>.from(schema)..remove(r'$schema');
  out['type'] = 'object';
  if (out['properties'] is! Map) out['properties'] = <String, dynamic>{};
  final required = out['required'];
  if (required != null && (required is! List || required.isEmpty)) out.remove('required');
  return out;
}
