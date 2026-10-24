import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@immutable
class const Household({required final String id, required final String name});

sealed class const Session();

final class const SessionLoading() extends Session;

final class const SignedOut({
  /// Why the last sign-in failed, e.g. an error on a provider's return URL.
  final Exception? error,

  /// Set when the user just deleted their account, for the start screen's
  /// confirmation.
  final AccountDeletedNotice? deleted,
}) extends Session;

/// The confirmation after an account deletion.
@immutable
class const AccountDeletedNotice({
  /// Apple's grant was not revoked, so the user removes the app from their
  /// Apple account themselves.
  required final bool removeAppleManually,
});

final class const NeedsHousehold(final String userId) extends Session;

final class const InHousehold(final String userId, final Household household)
    extends Session;

/// A household RPC refused the request, e.g. an expired invite code.
final class const HouseholdError(
  /// The Postgres exception message, e.g. `invalid_invite`.
  final String code,
) implements Exception;

/// The household each user was last in, kept on the device so an offline
/// start can open the list.
abstract interface class SessionCache() {
  Future<Household?> household(String userId);

  /// Also drops the user's cached lists of any other household.
  Future<void> remember(String userId, Household? household);

  /// Drops everything cached for every user.
  Future<void> forget();
}

class SessionCubit(final SupabaseClient _client, final SessionCache _cache)
    extends Cubit<Session> {
  this : super(const SessionLoading()) {
    // Also replays a failed browser sign-in that supabase_flutter read from
    // the return URL before this cubit existed.
    _auth = _client.auth.onAuthStateChange.listen(
      (event) => unawaited(_load(event.session?.user.id)),
      onError: (Object e) => switch (e) {
        // An offline token refresh: the session stays and is retried.
        AuthRetryableFetchException() => unawaited(
          _load(_client.auth.currentUser?.id),
        ),
        _ => emit(SignedOut(error: e is Exception ? e : null)),
      },
    );
  }

  late final StreamSubscription<AuthState> _auth;

  /// The user whose household the server last confirmed.
  String? _loadedFor;
  Timer? _retry;

  Future<void> _load(String? userId) async {
    if (userId == null) {
      _loadedFor = null;
      _retry?.cancel();
      // The sign-out that [accountDeleted] causes keeps its notice.
      emit(
        SignedOut(
          deleted: switch (state) {
            SignedOut(:final deleted) => deleted,
            _ => null,
          },
        ),
      );
      await _cache.forget();
      return;
    }
    if (_loadedFor == userId) {
      return;
    }
    try {
      await refresh();
      _loadedFor = userId;
    } on Object {
      // Offline: open the cached household, and ask until the server answers.
      if (state is SessionLoading) {
        if (await _cache.household(userId) case final household?) {
          if (_client.auth.currentUser?.id == userId) {
            emit(InHousehold(userId, household));
          }
        }
      }
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 3), () {
        if (!isClosed && _client.auth.currentUser?.id == userId) {
          unawaited(_load(userId));
        }
      });
    }
  }

  Future<void> refresh() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      emit(const SignedOut());
      return;
    }
    final row = await _client.rest
        .from('household_members')
        .select('households(id, name)')
        .eq('user_id', userId)
        .maybeSingle();
    final next = switch (row?['households']) {
      {'id': final String id, 'name': final String name} => InHousehold(
        userId,
        Household(id: id, name: name),
      ),
      _ => NeedsHousehold(userId),
    };
    await _cache.remember(userId, switch (next) {
      InHousehold(:final household) => household,
      _ => null,
    });
    emit(next);
  }

  Future<void> createHousehold(String name) =>
      _rpc('create_household', {'p_name': name});

  Future<void> join(String code) => _rpc('join_household', {'p_code': code});

  Future<void> signOut() => _client.auth.signOut();

  /// The server already deleted the account and its sessions: signs out on
  /// this device only and drops everything cached.
  Future<void> accountDeleted(AccountDeletedNotice notice) async {
    _loadedFor = null;
    _retry?.cancel();
    emit(SignedOut(deleted: notice));
    await _cache.forget();
    try {
      // GoTrue's default scope is this device only.
      await _client.auth.signOut();
    } on Object {
      // Local sign-out only clears storage; the account is gone regardless.
    }
  }

  Future<void> _rpc(String fn, Map<String, Object?> params) async {
    try {
      await _client.rpc<Object?>(fn, params: params);
    } on PostgrestException catch (e) {
      throw HouseholdError(e.message);
    }
    await refresh();
  }

  @override
  Future<void> close() async {
    _retry?.cancel();
    await _auth.cancel();
    await super.close();
  }
}
