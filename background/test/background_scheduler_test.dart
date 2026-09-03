import 'package:flutter/services.dart';
import 'package:flutter_outbox_background/flutter_outbox_background.dart';
import 'package:flutter_test/flutter_test.dart';

/// O lado Dart do canal, testado sem aparelho: as mensagens que saem e a
/// resposta que volta.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(BackgroundScheduler.channelName);
  final sent = <MethodCall>[];

  setUp(() {
    sent.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      sent.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('schedule manda a janela e a exigência de rede', () async {
    await BackgroundScheduler()
        .schedule(earliest: const Duration(minutes: 30), requiresNetwork: false);

    expect(sent.single.method, 'schedule');
    expect(sent.single.arguments, {
      'earliestSeconds': 1800,
      'requiresNetwork': false,
    });
  });

  test('schedule tem um padrão, e ele exige rede', () async {
    await BackgroundScheduler().schedule();

    expect(sent.single.arguments, {
      'earliestSeconds': 900,
      'requiresNetwork': true,
    });
  });

  test('cancel não manda argumento nenhum', () async {
    await BackgroundScheduler().cancel();

    expect(sent.single.method, 'cancel');
    expect(sent.single.arguments, isNull);
  });

  test('registerEntrypoint recusa uma closure', () async {
    // Uma closure não tem handle, e o erro apareceria só no aparelho, semanas
    // depois, como uma janela que roda e não faz nada.
    expect(
      () => BackgroundScheduler().registerEntrypoint(() {}),
      throwsArgumentError,
    );
  });

  test('o handler devolve ao nativo o que o trabalho disse', () async {
    for (final finished in [true, false]) {
      BackgroundScheduler().onBackgroundWork(() async => finished);

      final reply = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        BackgroundScheduler.channelName,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('runBackgroundWork')),
        (_) {},
      );

      expect(
        const StandardMethodCodec().decodeEnvelope(reply!),
        finished,
        reason: 'é este booleano que vira Result.success() ou Result.retry()',
      );
    }
  });
}
