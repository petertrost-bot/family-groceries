import 'dart:async';
import 'dart:convert';

import 'package:family_groceries/session/social_sign_in.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

/// What deleting the account does to the user's household.
sealed class const HouseholdFate();

/// Others stay in [householdName] with the whole list.
final class const FateKept(
  final String householdName,
  final List<String> otherMemberNames,
) extends HouseholdFate;

/// The user is the last member, so [householdName] goes too.
final class const FateDeleted(final String householdName) extends HouseholdFate;

/// The user is in no household.
final class const FateNone() extends HouseholdFate;

/// Whether the server revoked the app's Sign in with Apple grant.
enum AppleUnlink(final String wire) {
  revoked('revoked'),
  notLinked('not_linked'),

  /// No authorization code reached the server (web, Android, a failed
  /// re-authorization): the user removes the app in the iPhone's settings.
  manual('manual');

  static AppleUnlink parse(Object? wire) => values.firstWhere(
    (v) => v.wire == wire,
    // The account is gone either way; the hint is the safe answer.
    orElse: () => manual,
  );
}

@immutable
class const AccountDeleted(final AppleUnlink apple);

/// Nothing was deleted.
sealed class const AccountError() implements Exception;

final class const AccountOffline() extends AccountError;

/// The server refused or failed; [code] is its `error` field or the HTTP
/// status.
final class const AccountFailed(final String code) extends AccountError;

/// The user closed Apple's re-authorization sheet.
final class const AppleReauthCanceled() extends AccountError;

/// Parses an exception from the Supabase client.
AccountError accountErrorOf(Object error) => switch (error) {
  AccountError() => error,
  // Thrown by functions_client when the request never got an answer.
  FunctionsFetchException() => const AccountOffline(),
  FunctionException(details: {'error': final String code}) => AccountFailed(
    code,
  ),
  FunctionException(:final status) => AccountFailed('$status'),
  PostgrestException(:final code, :final message) => AccountFailed(
    code ?? message,
  ),
  // package:http on web and native (where it also implements
  // SocketException) when the server is unreachable.
  ClientException() || TimeoutException() => const AccountOffline(),
  _ => AccountFailed('${error.runtimeType}'),
};

/// A fresh Sign in with Apple authorization code, or null when none can be
/// had. Throws [SocialSignInCanceled] when the user backs out.
typedef AppleAuthorizationCode = Future<String?> Function();

/// The account section's only door to the backend.
abstract interface class AccountRepository() {
  /// Throws [AccountError].
  Future<HouseholdFate> fate();

  /// Deletes the account on the server, re-authorizing with Apple first
  /// where that is possible. Throws [AccountError]; then nothing was
  /// deleted.
  Future<AccountDeleted> delete();

  /// Everything the server keeps about the user, as indented JSON. Throws
  /// [AccountError].
  Future<String> export();
}

class SupabaseAccountRepository(
  final SupabaseClient _client, {

  /// Only where the platform's own Apple dialog exists (iOS).
  final AppleAuthorizationCode? _appleCode,
}) implements AccountRepository {
  @override
  Future<HouseholdFate> fate() => _guard(() async {
    final userId = _client.auth.currentUser!.id;
    final membership = await _client.rest
        .from('household_members')
        .select('household_id, households(name)')
        .eq('user_id', userId)
        .maybeSingle();
    if (membership case {
      'household_id': final String householdId,
      'households': {'name': final String name},
    }) {
      final (members, profiles) = await (
        _client.rest
            .from('household_members')
            .select('user_id')
            .eq('household_id', householdId),
        // As in the list's catalog: RLS returns everyone the user shares a
        // household with, the member ids pick this one's.
        _client.rest.from('profiles').select('id, display_name'),
      ).wait;
      final others = {for (final row in members) row['user_id']! as String}
        ..remove(userId);
      if (others.isEmpty) {
        return FateDeleted(name);
      }
      return FateKept(name, [
        for (final profile in profiles)
          if (profile
              case {
                'id': final String id,
                'display_name': final String displayName,
              }
              when others.contains(id))
            displayName,
      ]);
    }
    return const FateNone();
  });

  @override
  Future<AccountDeleted> delete() => _guard(() async {
    final code = await _appleAuthorizationCode();
    final response = await _client.functions.invoke(
      'account/delete',
      body: {'apple_authorization_code': ?code},
    );
    return switch (response.data) {
      {'deleted': true, 'apple': final Object? apple} => AccountDeleted(
        AppleUnlink.parse(apple),
      ),
      _ => throw const AccountFailed('bad_response'),
    };
  });

  @override
  Future<String> export() => _guard(() async {
    final data = await _client.rpc<Object?>('export_my_data');
    return const JsonEncoder.withIndent('  ').convert(data);
  });

  Future<String?> _appleAuthorizationCode() async {
    final appleCode = _appleCode;
    final linked =
        _client.auth.currentUser?.identities?.any(
          (i) => i.provider == 'apple',
        ) ??
        false;
    if (appleCode == null || !linked) {
      return null;
    }
    try {
      return await appleCode();
    } on SocialSignInCanceled {
      throw const AppleReauthCanceled();
    }
  }

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on Object catch (e) {
      throw accountErrorOf(e);
    }
  }
}
