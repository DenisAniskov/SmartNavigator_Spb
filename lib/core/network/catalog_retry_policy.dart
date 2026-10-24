import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

/// Bounded auto-retry policy for the catalog load (P2).
///
/// Only honestly transient failures may be retried automatically: timeouts,
/// connection loss and server-side unavailability (5xx, 429). Data-shape
/// errors and client errors (400/401/403/404/422) are permanent: repeating
/// them cannot succeed and would only spam the backend.
abstract final class CatalogRetryPolicy {
  /// Automatic retries after the initial failed attempt. The waits between
  /// attempts are approximately 2s, 5s and 10s, so one filter generation
  /// makes at most 1 initial + 3 automatic requests — never an endless poll.
  static const maxAutomaticRetries = 3;
  static const backoffDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  /// Retry-After is honored but bounded: a server can never schedule an
  /// unbounded wait, and sub-second waits are lifted to 1s.
  static const minRetryAfter = Duration(seconds: 1);
  static const maxRetryAfter = Duration(seconds: 60);

  /// True when repeating the request can plausibly succeed later.
  static bool isTransient(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.badCertificate:
        case DioExceptionType.cancel:
          return false;
        case DioExceptionType.badResponse:
        case DioExceptionType.unknown:
          break;
      }
      final inner = error.error;
      if (inner is SocketException || inner is TimeoutException) return true;
      final status = error.response?.statusCode;
      return status == 429 || (status != null && status >= 500);
    }
    return error is SocketException || error is TimeoutException;
  }

  /// The wait before automatic retry attempt [retryIndex] (1-based), or null
  /// when the retry budget is exhausted. A server-provided Retry-After wins
  /// over the local backoff and carries no jitter; otherwise the backoff is
  /// [backoffDelays] scaled by ±15% via [random] (0.5 disables the jitter).
  static Duration? automaticDelay({
    required Object error,
    required int retryIndex,
    required double Function() random,
  }) {
    if (retryIndex < 1 || retryIndex > maxAutomaticRetries) return null;
    final retryAfter = retryAfterDelay(error);
    if (retryAfter != null) return retryAfter;
    final base = backoffDelays[min(retryIndex, backoffDelays.length) - 1];
    final factor = 0.85 + 0.3 * random();
    return Duration(milliseconds: (base.inMilliseconds * factor).round());
  }

  /// Parses the Retry-After header of a rate-limit/server-error response.
  /// Returns null when the header is absent or unparsable.
  static Duration? retryAfterDelay(Object error, {DateTime? now}) {
    if (error is! DioException) return null;
    final status = error.response?.statusCode;
    if (status != 429 && (status == null || status < 500)) return null;
    final raw = error.response?.headers.value(HttpHeaders.retryAfterHeader);
    if (raw == null) return null;
    final trimmed = raw.trim();
    Duration parsed;
    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      parsed = Duration(seconds: seconds);
    } else {
      try {
        final when = HttpDate.parse(trimmed);
        parsed = when.difference((now ?? DateTime.now()).toUtc());
      } on Exception {
        // HttpException/FormatException alike: an unparsable header is no
        // signal at all, so the local backoff applies.
        return null;
      }
    }
    if (parsed < minRetryAfter) return minRetryAfter;
    if (parsed > maxRetryAfter) return maxRetryAfter;
    return parsed;
  }
}
