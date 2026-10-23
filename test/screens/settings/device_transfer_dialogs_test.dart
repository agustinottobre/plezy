import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/device_transfer_dialogs.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Android', deviceName: 'TV Test'));

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  group('ReceiveSetupDialog layout', () {
    testWidgets('renders QR and PIN side-by-side on wide/TV screen without overflow', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2.0; // 960x540 logical pixels (TV)
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReceiveSetupDialog(),
          ),
        ),
      );

      // Allow async initState _initReceiver to bind ephemeral port via real IO
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(find.text(t.deviceTransfer.receiveTitle), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text(t.deviceTransfer.pinCode), findsOneWidget);
      expect(find.byType(Row), findsWidgets);

      // Verify that QR image and PIN are laid out together in a Row
      final qrFinder = find.byType(QrImageView);
      final pinLabelFinder = find.text(t.deviceTransfer.pinCode);

      final qrTopLeft = tester.getTopLeft(qrFinder);
      final pinTopLeft = tester.getTopLeft(pinLabelFinder);

      // Side-by-side: PIN label is to the right of the QR code
      expect(pinTopLeft.dx, greaterThan(qrTopLeft.dx));

      // No overflow exceptions
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders QR and PIN vertically on mobile portrait screen without overflow', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0; // 360x800 logical pixels (Mobile)
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReceiveSetupDialog(),
          ),
        ),
      );

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(find.text(t.deviceTransfer.receiveTitle), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text(t.deviceTransfer.pinCode), findsOneWidget);

      final qrTopLeft = tester.getTopLeft(find.byType(QrImageView));
      final pinTopLeft = tester.getTopLeft(find.text(t.deviceTransfer.pinCode));

      // Stacked: PIN label is below the QR code
      expect(pinTopLeft.dy, greaterThan(qrTopLeft.dy));

      expect(tester.takeException(), isNull);
    });
  });

  group('SendSetupDialog layout', () {
    testWidgets('renders smoothly on mobile portrait without overflow', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0; // 360x800 logical pixels
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SendSetupDialog(initialPin: '123456'),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(t.deviceTransfer.sendTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
