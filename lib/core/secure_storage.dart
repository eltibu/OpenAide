import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where sign-ins and keys are kept: Android's keystore, Apple's keychain,
/// Windows' credential store, Linux's keyring.
///
/// On a Mac it uses the login keychain rather than the newer "data
/// protection" keychain: that one needs a paid Apple developer team in the
/// app's signature, and the Mac download is signed without one.
const appSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
