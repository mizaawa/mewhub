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
