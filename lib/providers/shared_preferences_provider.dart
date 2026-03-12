import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional synchronous access to the app's preloaded SharedPreferences.
///
/// `main()` overrides this provider with a ready instance so state notifiers
/// can build from persisted data without an async startup race. Tests and
/// other contexts may leave it unset and use the existing async fallback path.
final sharedPreferencesProvider = Provider<SharedPreferences?>((ref) => null);
