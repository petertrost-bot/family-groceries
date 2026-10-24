import 'dart:async';

import 'package:family_groceries/settings/account_repository.dart';

/// Answers with [fateResult] and [deleteResult], or throws the matching
/// error; counts every call.
class FakeAccountRepository() implements AccountRepository {
  HouseholdFate fateResult = const FateKept('Zuhause', ['Lea']);
  AccountError? fateError;
  var deleteResult = const AccountDeleted(AppleUnlink.notLinked);
  AccountError? deleteError;

  /// When set, [delete] waits for it.
  Completer<void>? deleteGate;
  var exportResult = '{"format": "family-groceries-export"}';
  AccountError? exportError;
  var deleteCalls = 0;
  var exportCalls = 0;

  @override
  Future<HouseholdFate> fate() async {
    if (fateError case final error?) {
      throw error;
    }
    return fateResult;
  }

  @override
  Future<AccountDeleted> delete() async {
    deleteCalls++;
    await deleteGate?.future;
    if (deleteError case final error?) {
      throw error;
    }
    return deleteResult;
  }

  @override
  Future<String> export() async {
    exportCalls++;
    if (exportError case final error?) {
      throw error;
    }
    return exportResult;
  }
}
