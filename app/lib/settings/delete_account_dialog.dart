import 'dart:async';

import 'package:family_groceries/l10n/app_localizations.dart';
import 'package:family_groceries/session/session_cubit.dart';
import 'package:family_groceries/settings/account_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Asks, deletes the account on the server and signs out on this device.
/// The router then shows the start screen with the confirmation.
Future<void> deleteAccount(BuildContext context) async {
  final repository = context.read<AccountRepository>();
  final session = context.read<SessionCubit>();
  final deleted = await showDialog<AccountDeleted>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DeleteAccountDialog(repository: repository),
  );
  if (deleted != null) {
    await session.accountDeleted(
      AccountDeletedNotice(
        removeAppleManually: deleted.apple == AppleUnlink.manual,
      ),
    );
  }
}

/// Whether [input] is the confirmation word; `LOESCHEN` for keyboards
/// without umlauts.
bool isDeleteConfirmation(String input) =>
    const {'löschen', 'loeschen'}.contains(input.trim().toLowerCase());

sealed class const _Step();

final class const _LoadingFate() extends _Step;

final class const _FateFailed(final AccountError error) extends _Step;

final class const _Confirming(
  final HouseholdFate fate, [

  /// Why the last attempt deleted nothing.
  final AccountError? error,
]) extends _Step;

final class const _Deleting(final HouseholdFate fate) extends _Step;

/// Pops with the [AccountDeleted] answer once the server deleted the
/// account.
class const DeleteAccountDialog({
  required final AccountRepository repository,
  super.key,
}) extends StatefulWidget {
  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState() extends State<DeleteAccountDialog> {
  final _confirmation = TextEditingController();
  _Step _step = const _LoadingFate();

  @override
  void initState() {
    super.initState();
    unawaited(_loadFate());
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _loadFate() async {
    _Step next;
    try {
      next = _Confirming(await widget.repository.fate());
    } on AccountError catch (e) {
      next = _FateFailed(e);
    }
    if (mounted) {
      setState(() => _step = next);
    }
  }

  Future<void> _delete(HouseholdFate fate) async {
    setState(() => _step = _Deleting(fate));
    try {
      final deleted = await widget.repository.delete();
      if (mounted) {
        Navigator.of(context).pop(deleted);
      }
    } on AccountError catch (e) {
      if (mounted) {
        setState(() => _step = _Confirming(fate, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final step = _step;
    final deleting = step is _Deleting;
    final error = switch (step) {
      _FateFailed(error: AccountOffline()) => l10n.accountFateOffline,
      _FateFailed(error: AccountFailed(:final code)) => l10n.accountFateFailed(
        code,
      ),
      _FateFailed(error: AppleReauthCanceled()) => l10n.accountFateFailed(
        'canceled',
      ),
      _Confirming(error: AccountOffline()) => l10n.accountDeleteOffline,
      _Confirming(error: AccountFailed(:final code)) =>
        l10n.accountDeleteFailed(code),
      _Confirming(error: AppleReauthCanceled()) => l10n.accountDeleteCanceled,
      _Confirming(error: null) || _LoadingFate() || _Deleting() => null,
    };
    final fate = switch (step) {
      _Confirming(:final fate) || _Deleting(:final fate) => fate,
      _LoadingFate() || _FateFailed() => null,
    };
    return PopScope(
      canPop: !deleting,
      child: AlertDialog(
        key: const ValueKey('account-delete-dialog'),
        title: Text(l10n.accountDeleteTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.accountDeleteWhat),
              const SizedBox(height: 12),
              if (fate == null && error == null)
                const Center(child: CircularProgressIndicator())
              else if (fate != null) ...[
                Text(_fateText(l10n, fate)),
                if (fate is! FateNone) ...[
                  const SizedBox(height: 12),
                  Text(l10n.accountDeleteExportHint),
                ],
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('account-delete-confirm-field'),
                  controller: _confirmation,
                  enabled: !deleting,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: l10n.accountDeleteConfirmLabel,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error, style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (deleting) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('account-delete-cancel'),
            onPressed: deleting ? null : () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('account-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: switch (step) {
              _Confirming(:final fate)
                  when isDeleteConfirmation(_confirmation.text) =>
                () => unawaited(_delete(fate)),
              _ => null,
            },
            child: Text(l10n.accountDeleteConfirm),
          ),
        ],
      ),
    );
  }
}

String _fateText(AppLocalizations l10n, HouseholdFate fate) => switch (fate) {
  FateKept(:final householdName, otherMemberNames: []) =>
    l10n.accountDeleteKeptUnnamed(householdName),
  FateKept(:final householdName, :final otherMemberNames) =>
    l10n.accountDeleteKept(householdName, _joinNames(l10n, otherMemberNames)),
  FateDeleted(:final householdName) => l10n.accountDeleteDeleted(householdName),
  FateNone() => l10n.accountDeleteNone,
};

/// `Lea`, `Lea und Max`, `Anna, Lea und Max`.
String _joinNames(AppLocalizations l10n, List<String> names) =>
    names.length == 1
    ? names.single
    : l10n.namesAnd(names.sublist(0, names.length - 1).join(', '), names.last);
