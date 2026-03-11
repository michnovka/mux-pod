import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service for registering font licenses
class LicenseService {
  static bool _initialized = false;

  /// Register licenses (executed only once)
  static void registerLicenses() {
    if (_initialized) return;
    _initialized = true;

    LicenseRegistry.addLicense(() async* {
      final hackgenLicense =
          await rootBundle.loadString('assets/fonts/HackGenConsole-LICENSE.txt');
      yield LicenseEntryWithLineBreaks(['HackGen Console'], hackgenLicense);

      final udevLicense =
          await rootBundle.loadString('assets/fonts/UDEVGothicNF-LICENSE.txt');
      yield LicenseEntryWithLineBreaks(['UDEV Gothic NF'], udevLicense);
    });
  }
}
