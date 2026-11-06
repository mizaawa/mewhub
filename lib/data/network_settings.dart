/// Persisted network preferences. Missing or invalid values use safe defaults.
class NetworkSettings {
  const NetworkSettings({
    this.connectTimeoutSeconds = 30,
    this.responseTimeoutSeconds = 120,
    this.maxRetries = 5,
    this.retryDelaySeconds = 1,
    this.maxRetryDelaySeconds = 60,
    this.exponentialBackoff = true,
    this.retryOnRateLimit = true,
    this.retryOnServerError = true,
    this.respectRetryAfter = true,
  });

  final int connectTimeoutSeconds;
  final int responseTimeoutSeconds;

  /// Additional attempts after the initial request, not total attempts.
  final int maxRetries;
  final int retryDelaySeconds;
  final int maxRetryDelaySeconds;
  final bool exponentialBackoff;
  final bool retryOnRateLimit;
  final bool retryOnServerError;
  final bool respectRetryAfter;

  NetworkSettings copyWith({
    int? connectTimeoutSeconds,
    int? responseTimeoutSeconds,
    int? maxRetries,
    int? retryDelaySeconds,
    int? maxRetryDelaySeconds,
    bool? exponentialBackoff,
    bool? retryOnRateLimit,
    bool? retryOnServerError,
    bool? respectRetryAfter,
  }) => NetworkSettings.fromJson({
    'connectTimeoutSeconds': connectTimeoutSeconds ?? this.connectTimeoutSeconds,
    'responseTimeoutSeconds': responseTimeoutSeconds ?? this.responseTimeoutSeconds,
    'maxRetries': maxRetries ?? this.maxRetries,
    'retryDelaySeconds': retryDelaySeconds ?? this.retryDelaySeconds,
    'maxRetryDelaySeconds': maxRetryDelaySeconds ?? this.maxRetryDelaySeconds,
    'exponentialBackoff': exponentialBackoff ?? this.exponentialBackoff,
    'retryOnRateLimit': retryOnRateLimit ?? this.retryOnRateLimit,
    'retryOnServerError': retryOnServerError ?? this.retryOnServerError,
    'respectRetryAfter': respectRetryAfter ?? this.respectRetryAfter,
  });

  factory NetworkSettings.fromJson(Map<String, dynamic> json) {
    int number(String key, int fallback, int min, int max) {
      final raw = json[key];
      final value = raw is int ? raw : (raw is String ? int.tryParse(raw) : null);
      return (value ?? fallback).clamp(min, max);
    }

    bool flag(String key) => json[key] is bool ? json[key] as bool : true;
    final delay = number('retryDelaySeconds', 1, 1, 60);
    return NetworkSettings(
      connectTimeoutSeconds: number('connectTimeoutSeconds', 30, 5, 120),
      responseTimeoutSeconds: number('responseTimeoutSeconds', 120, 10, 1800),
      maxRetries: number('maxRetries', 5, 0, 20),
      retryDelaySeconds: delay,
      maxRetryDelaySeconds: number('maxRetryDelaySeconds', 60, delay, 300),
      exponentialBackoff: flag('exponentialBackoff'),
      retryOnRateLimit: flag('retryOnRateLimit'),
      retryOnServerError: flag('retryOnServerError'),
      respectRetryAfter: flag('respectRetryAfter'),
    );
  }

  Map<String, dynamic> toJson() => {
    'connectTimeoutSeconds': connectTimeoutSeconds,
    'responseTimeoutSeconds': responseTimeoutSeconds,
    'maxRetries': maxRetries,
    'retryDelaySeconds': retryDelaySeconds,
    'maxRetryDelaySeconds': maxRetryDelaySeconds,
    'exponentialBackoff': exponentialBackoff,
    'retryOnRateLimit': retryOnRateLimit,
    'retryOnServerError': retryOnServerError,
    'respectRetryAfter': respectRetryAfter,
  };
}
