/// The encrypted chat's MLS session, on the phone: the web's own Rust code
/// (native/encryption), called directly. Nothing in it is saved or logged.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NewC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _CallC = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _FreeTextC = Void Function(Pointer<Utf8>);
typedef _FreeTextD = void Function(Pointer<Utf8>);

class _Lib {
  _Lib(DynamicLibrary lib)
    : create = lib.lookupFunction<_NewC, _NewC>('oa_session_new'),
      call = lib.lookupFunction<_CallC, _CallC>('oa_session_call'),
      free = lib.lookupFunction<_FreeC, _FreeD>('oa_session_free'),
      freeText = lib.lookupFunction<_FreeTextC, _FreeTextD>('oa_string_free');
  final _NewC create;
  final _CallC call;
  final _FreeD free;
  final _FreeTextD freeText;
}

_Lib? _lib;
bool _tried = false;

_Lib? _load() {
  if (_tried) return _lib;
  _tried = true;
  final names = [
    ?Platform.environment['OPENAIDE_ENCRYPTION_LIB'],
    if (Platform.isAndroid) 'libopenaide_encryption.so',
    if (Platform.isLinux)
      'native/encryption/target/release/libopenaide_encryption.so',
    if (Platform.isMacOS)
      'native/encryption/target/release/libopenaide_encryption.dylib',
  ];
  for (final n in names) {
    try {
      return _lib = _Lib(DynamicLibrary.open(n));
    } catch (_) {
      // Not built into this app.
    }
  }
  return null;
}

/// Whether this app has the encryption built in.
bool get mlsAvailable => _load() != null;

class MlsException implements Exception {
  const MlsException();
  @override
  String toString() => 'Encrypted chat ended.';
}

/// One person's place in one encrypted chat. Any refusal ends it: throws
/// [MlsException] and the session can't be used again, as on the web.
class MlsSession {
  MlsSession(Map<String, String> identity, String host) {
    final lib = _load();
    if (lib == null) throw const MlsException();
    _lib = lib;
    _handle = using(
      (arena) => lib.create(
        jsonEncode(identity).toNativeUtf8(allocator: arena),
        host.toNativeUtf8(allocator: arena),
      ),
    );
    if (_handle == nullptr) throw const MlsException();
  }

  late final _Lib _lib;
  late Pointer<Void> _handle;

  bool get closed => _handle == nullptr;

  /// Runs [method] (public_key, key_package, create, join, add, remove,
  /// update, commit_updates, encrypt, process, members).
  Object? call(String method, [String a = '', String b = '', String c = '']) {
    if (closed) throw const MlsException();
    final answer = using((arena) {
      final out = _lib.call(
        _handle,
        method.toNativeUtf8(allocator: arena),
        a.toNativeUtf8(allocator: arena),
        b.toNativeUtf8(allocator: arena),
        c.toNativeUtf8(allocator: arena),
      );
      if (out == nullptr) return null;
      try {
        return jsonDecode(out.toDartString()) as Map;
      } finally {
        _lib.freeText(out);
      }
    });
    if (answer == null || answer['error'] == true) {
      dispose();
      throw const MlsException();
    }
    return answer['ok'];
  }

  void dispose() {
    if (closed) return;
    _lib.free(_handle);
    _handle = nullptr;
  }
}
