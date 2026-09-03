import 'dart:io';

import 'package:flutter_outbox_background/flutter_outbox_background.dart';
import 'package:flutter_test/flutter_test.dart';

/// O nome do canal e o identificador da tarefa aparecem em **três** arquivos:
/// Dart, Kotlin e Swift. Se divergirem, a chamada não dá erro — ela some. É o
/// pior tipo de falha, porque a suíte fica verde e nada roda no aparelho.
///
/// Este teste é a única defesa barata contra isso, e ele lê os fontes nativos
/// como texto de propósito: compilar Kotlin e Swift exigiria emulador e
/// toolchain, e a suíte não pode precisar de nenhum dos dois.
void main() {
  String read(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      fail('não achei $path — a estrutura do plugin mudou, e este teste com ela');
    }
    return file.readAsStringSync();
  }

  const kotlinDir =
      'android/src/main/kotlin/com/example/flutter_outbox_background/';
  // Os dois arquivos juntos: o plugin trata o canal, o worker faz o trabalho, e
  // o contrato se cumpre entre os dois.
  final kotlin = read('${kotlinDir}FlutterOutboxBackgroundPlugin.kt') +
      read('${kotlinDir}OutboxDrainWorker.kt');
  final swift = read(
    'ios/flutter_outbox_background/Sources/flutter_outbox_background/'
    'FlutterOutboxBackgroundPlugin.swift',
  );

  test('o nome do canal é o mesmo nos três lados', () {
    expect(BackgroundScheduler.channelName, 'flutter_outbox/background');
    expect(kotlin, contains('"${BackgroundScheduler.channelName}"'));
    expect(swift, contains('"${BackgroundScheduler.channelName}"'));
  });

  test('o identificador da tarefa é o mesmo nos três lados', () {
    expect(kotlin, contains('"${BackgroundScheduler.taskIdentifier}"'));
    expect(swift, contains('"${BackgroundScheduler.taskIdentifier}"'));
  });

  test('os dois lados nativos respondem aos mesmos métodos', () {
    for (final method in ['schedule', 'cancel', 'registerEntrypoint']) {
      expect(kotlin, contains('"$method"'),
          reason: 'o Kotlin não trata $method');
      expect(swift, contains('"$method"'), reason: 'o Swift não trata $method');
    }
    for (final source in [kotlin, swift]) {
      expect(source, contains('runBackgroundWork'),
          reason: 'sem esta chamada, a janela concedida não faz nada');
    }
  });

  test('nenhum dos dois lados usa plugin pronto de background', () {
    // A camada 3 existe para demonstrar escrita de módulo nativo. Um
    // `implementation("dev.fluttercommunity...workmanager")` aqui esvaziaria o
    // projeto inteiro, e é o tipo de "otimização" que alguém faz sem saber o
    // que quebrou. `docs/STACK.md` registra a decisão.
    // Só as linhas de dependência de verdade: um comentário que menciona o
    // WorkManager não é uma dependência dele, e a primeira versão deste teste
    // reprovava pelo próprio comentário do build.gradle.
    final declared = read('android/build.gradle.kts')
        .split('\n')
        .map((line) => line.trim())
        .where((line) =>
            !line.startsWith('//') &&
            (line.startsWith('implementation(') ||
                line.startsWith('api(') ||
                line.startsWith('compileOnly(')))
        .toList();

    expect(declared, isNotEmpty, reason: 'o build.gradle mudou de forma');
    expect(
      declared.singleWhere((line) => line.contains('androidx.work')),
      contains('androidx.work:work-runtime'),
    );
    for (final dependency in declared) {
      expect(dependency, isNot(contains('workmanager')),
          reason: 'usar um plugin pronto esvaziaria a camada 3');
    }
    expect(swift, contains('BGTaskScheduler'));
  });

  test('o Android pede a janela seguinte, e o iOS pede antes do trabalho', () {
    // Sem reagendar, a fila para de ser esvaziada depois da primeira janela.
    expect(kotlin, contains('Result.retry()'),
        reason: 'uma fila que não esvaziou não é uma fila perdida');
    expect(swift, contains('expirationHandler'),
        reason: 'o cenário 13 exige que o encerramento no meio seja tratado');
  });
}
