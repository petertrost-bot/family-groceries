import 'dart:async';

import 'package:family_groceries/household/welcome_screen.dart';
import 'package:family_groceries/l10n/app_localizations.dart';
import 'package:family_groceries/session/login_screen.dart';
import 'package:family_groceries/session/session_cubit.dart';
import 'package:family_groceries/session/social_sign_in.dart';
import 'package:family_groceries/settings/access_repository.dart';
import 'package:family_groceries/settings/account_repository.dart';
import 'package:family_groceries/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../session/fake_auth.dart';
import 'fake_account.dart';
import 'settings_screen_test.dart' show FakeAccessRepository;

typedef SavedExport = ({String fileName, String json, Rect? origin});

void main() {
  late FakeAuth auth;
  late MemorySessionCache cache;
  late SessionCubit session;
  late FakeAccountRepository account;
  late List<SavedExport> saved;
  String? savedPath;

  const user = User(
    id: 'peter',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-10-22T12:00:00Z',
  );

  Future<void> pump(WidgetTester tester, Widget home) async {
    auth = FakeAuth()..user = user;
    addTearDown(auth.close);
    cache = MemorySessionCache()
      ..households['peter'] = const Household(id: 'home', name: 'Zuhause');
    session = SessionCubit(FakeClient(auth), cache);
    addTearDown(session.close);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: account),
          RepositoryProvider.value(
            value: SocialSignIn(
              auth,
              flows: const {},
              native: FakeNativeSignIn(),
            ),
          ),
        ],
        child: BlocProvider.value(
          value: session,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('de'),
            home: home,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget settings({bool showAccount = false, AccessRepository? access}) =>
      SettingsScreen(
        repository: access ?? FakeAccessRepository(),
        showAccount: showAccount,
        saveExport: (fileName, json, {origin}) async {
          saved.add((fileName: fileName, json: json, origin: origin));
          return savedPath;
        },
      );

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await pump(tester, settings());
    await tapKey(tester, 'account-delete');
    expect(find.byKey(const ValueKey('account-delete-dialog')), findsOneWidget);
  }

  Future<void> confirm(WidgetTester tester, [String word = 'LÖSCHEN']) async {
    await tester.enterText(
      find.byKey(const ValueKey('account-delete-confirm-field')),
      word,
    );
    await tester.pump();
  }

  bool confirmEnabled(WidgetTester tester) => tester
      .widget<FilledButton>(
        find.byKey(const ValueKey('account-delete-confirm')),
      )
      .enabled;

  setUp(() {
    account = FakeAccountRepository();
    saved = [];
    savedPath = null;
  });

  testWidgets('deleting stays disabled until LÖSCHEN is typed', (tester) async {
    await openDialog(tester);
    expect(confirmEnabled(tester), isFalse);
    await confirm(tester, 'LÖSCH');
    expect(confirmEnabled(tester), isFalse);
    await confirm(tester, ' löschen ');
    expect(confirmEnabled(tester), isTrue);
    await confirm(tester, 'Loeschen');
    expect(confirmEnabled(tester), isTrue);

    await tapKey(tester, 'account-delete-cancel');
    expect(find.byKey(const ValueKey('account-delete-dialog')), findsNothing);
    expect(account.deleteCalls, 0);
  });

  group('says what happens to the household', () {
    for (final (fate, text) in [
      (
        const FateKept('Zuhause', ['Lea']),
        'Der Haushalt „Zuhause“ bleibt für Lea mit der ganzen Liste erhalten. '
            'Deine Einträge bleiben dort, aber ohne deinen Namen.',
      ),
      (
        const FateKept('WG', ['Anna', 'Lea', 'Max']),
        'Der Haushalt „WG“ bleibt für Anna, Lea und Max mit der ganzen Liste '
            'erhalten. Deine Einträge bleiben dort, aber ohne deinen Namen.',
      ),
      (
        const FateDeleted('Zuhause'),
        'Du bist das letzte Mitglied. Deshalb wird der Haushalt „Zuhause“ mit '
            'Liste, Verlauf, Kategorien und Geschäften gelöscht.',
      ),
      (
        const FateNone(),
        'Du bist in keinem Haushalt, geteilte Daten gibt es nicht.',
      ),
    ]) {
      testWidgets('${fate.runtimeType}: $text', (tester) async {
        account.fateResult = fate;
        await openDialog(tester);
        expect(find.text(text), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('account-delete-dialog')),
            matching: find.textContaining('Meine Daten exportieren'),
          ),
          fate is FateNone ? findsNothing : findsOneWidget,
        );
      });
    }
  });

  testWidgets('a deleted account signs out locally with a notice', (
    tester,
  ) async {
    account.deleteResult = const AccountDeleted(AppleUnlink.manual);
    await openDialog(tester);
    await confirm(tester);
    await tapKey(tester, 'account-delete-confirm');

    expect(find.byKey(const ValueKey('account-delete-dialog')), findsNothing);
    expect(account.deleteCalls, 1);
    expect(auth.signOutScopes, [SignOutScope.local]);
    expect(cache.households, isEmpty);
    expect(cache.forgotten, greaterThan(0));
    expect(
      session.state,
      isA<SignedOut>().having(
        (s) => s.deleted?.removeAppleManually,
        'apple hint',
        isTrue,
      ),
    );
  });

  testWidgets('offline deletes nothing and stays signed in', (tester) async {
    account.deleteError = const AccountOffline();
    await openDialog(tester);
    await confirm(tester);
    await tapKey(tester, 'account-delete-confirm');

    expect(
      find.text(
        'Keine Internetverbindung. Dein Konto wurde nicht gelöscht. '
        'Versuche es erneut, sobald du online bist.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('account-delete-dialog')), findsOneWidget);
    expect(account.deleteCalls, 1);
    expect(auth.signOutScopes, isEmpty);
    expect(session.state, isNot(isA<SignedOut>()));
    expect(confirmEnabled(tester), isTrue, reason: 'retry is possible');
  });

  testWidgets('a server failure names its code', (tester) async {
    account.deleteError = const AccountFailed('delete_failed');
    await openDialog(tester);
    await confirm(tester);
    await tapKey(tester, 'account-delete-confirm');
    expect(
      find.text(
        'Löschen fehlgeschlagen (delete_failed). Dein Konto wurde nicht '
        'gelöscht.',
      ),
      findsOneWidget,
    );
    expect(auth.signOutScopes, isEmpty);
  });

  testWidgets('closing Apple’s sheet cancels the deletion', (tester) async {
    account.deleteError = const AppleReauthCanceled();
    await openDialog(tester);
    await confirm(tester);
    await tapKey(tester, 'account-delete-confirm');
    expect(
      find.text('Abgebrochen. Dein Konto wurde nicht gelöscht.'),
      findsOneWidget,
    );
    expect(auth.signOutScopes, isEmpty);
  });

  testWidgets('while deleting nothing can be pressed or dismissed', (
    tester,
  ) async {
    final gate = account.deleteGate = Completer<void>();
    await openDialog(tester);
    await confirm(tester);
    await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(confirmEnabled(tester), isFalse);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('account-delete-cancel')),
          )
          .enabled,
      isFalse,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.byKey(const ValueKey('account-delete-dialog')), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(session.state, isA<SignedOut>());
    expect(account.deleteCalls, 1);
  });

  testWidgets('the start screen confirms the deletion', (tester) async {
    await pump(tester, const LoginScreen());
    expect(find.byKey(const ValueKey('account-deleted-notice')), findsNothing);

    await session.accountDeleted(
      const AccountDeletedNotice(removeAppleManually: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dein Konto wurde gelöscht.'), findsOneWidget);
    expect(find.textContaining('Mit Apple anmelden'), findsOneWidget);
  });

  testWidgets('without the Apple hint when Apple was revoked', (tester) async {
    await pump(tester, const LoginScreen());
    await session.accountDeleted(
      const AccountDeletedNotice(removeAppleManually: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dein Konto wurde gelöscht.'), findsOneWidget);
    expect(find.textContaining('Mit Apple anmelden'), findsNothing);
  });

  testWidgets('the welcome screen offers deletion too', (tester) async {
    account.fateResult = const FateNone();
    await pump(tester, const WelcomeScreen());
    await tapKey(tester, 'account-delete');
    expect(
      find.text('Du bist in keinem Haushalt, geteilte Daten gibt es nicht.'),
      findsOneWidget,
    );
    await confirm(tester);
    await tapKey(tester, 'account-delete-confirm');
    expect(session.state, isA<SignedOut>());
  });

  testWidgets('a household that cannot be loaded blocks deletion', (
    tester,
  ) async {
    account.fateError = const AccountOffline();
    await openDialog(tester);
    expect(
      find.text(
        'Keine Internetverbindung. Was mit deinem Haushalt passiert, konnte '
        'nicht geladen werden.',
      ),
      findsOneWidget,
    );
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets('exporting saves the JSON under a dated name', (tester) async {
    await pump(tester, settings());
    await tapKey(tester, 'account-export');
    expect(account.exportCalls, 1);
    expect(saved, hasLength(1));
    expect(
      saved.single.fileName,
      matches(RegExp(r'^einkauf-daten-\d{4}-\d{2}-\d{2}\.json$')),
    );
    expect(saved.single.json, account.exportResult);
    expect(saved.single.origin, isNotNull);
    expect(find.text('Daten exportiert'), findsOneWidget);
  });

  testWidgets('a desktop export shows where the file went', (tester) async {
    savedPath = '/home/peter/Downloads/einkauf-daten-2026-10-24.json';
    await pump(tester, settings());
    await tapKey(tester, 'account-export');
    expect(find.text('Daten exportiert: $savedPath'), findsOneWidget);
  });

  testWidgets('an offline export says so and saves nothing', (tester) async {
    account.exportError = const AccountOffline();
    await pump(tester, settings());
    await tapKey(tester, 'account-export');
    expect(saved, isEmpty);
    expect(
      find.text(
        'Keine Internetverbindung. Deine Daten wurden nicht exportiert.',
      ),
      findsOneWidget,
    );
  });

  group('the menu entry Konto', () {
    FakeAccessRepository manyTokens() {
      final access = FakeAccessRepository();
      for (var i = 0; i < 12; i++) {
        access.tokens.add(
          AccessToken(
            id: 't$i',
            name: 'Token $i',
            hint: '000$i',
            createdAt: DateTime(2026, 10, 2),
          ),
        );
      }
      return access;
    }

    bool onScreen(WidgetTester tester, String key) {
      final finder = find.byKey(ValueKey(key));
      return finder.evaluate().isNotEmpty &&
          tester.getRect(finder).bottom <=
              tester.view.physicalSize.height / tester.view.devicePixelRatio;
    }

    testWidgets('opens settings scrolled to the account section', (
      tester,
    ) async {
      await pump(tester, settings(showAccount: true, access: manyTokens()));
      expect(onScreen(tester, 'account-delete'), isTrue);
    });

    testWidgets('plain settings start at the top', (tester) async {
      await pump(tester, settings(access: manyTokens()));
      expect(onScreen(tester, 'account-delete'), isFalse);
    });
  });
}
