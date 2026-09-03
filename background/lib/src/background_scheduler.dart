import 'dart:ui';

import 'package:flutter/services.dart';

/// O agendamento de trabalho em background, do lado Dart.
///
/// **Escrito à mão, sobre `MethodChannel`.** Existem plugins que embrulham
/// `WorkManager` e `BGTaskScheduler`, e usá-los esvaziaria esta camada, que
/// existe para demonstrar escrita de módulo nativo. É escolha de propósito, e
/// está registrada como tal em `docs/STACK.md` para ninguém "otimizar" depois.
///
/// O que o sistema operacional promete é **pouco**, e a API reflete isso:
/// [schedule] pede uma janela, não a garante. No iOS ela pode não vir por dias.
/// Nada no pacote pode expirar por não ter rodado.
final class BackgroundScheduler {
  BackgroundScheduler({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Um nome só, e ele aparece três vezes: aqui, no Kotlin e no Swift. Se
  /// divergirem, a chamada some sem erro — o pior tipo de falha, e o motivo de
  /// haver um teste que compara os três arquivos.
  static const channelName = 'flutter_outbox/background';

  /// O identificador da tarefa, que o iOS exige declarado no `Info.plist` e o
  /// Android usa como nome único do trabalho. Mesma regra: um lugar só.
  static const taskIdentifier = 'com.example.flutter_outbox.drain';

  final MethodChannel _channel;

  /// Pede ao sistema uma janela para esvaziar a fila.
  ///
  /// Idempotente de propósito: chamar duas vezes não cria duas tarefas. Os dois
  /// lados nativos substituem o trabalho existente em vez de empilhar —
  /// reagendamento descontrolado gasta o orçamento de execução do app e faz o
  /// sistema punir as janelas seguintes.
  Future<void> schedule({
    Duration earliest = const Duration(minutes: 15),
    bool requiresNetwork = true,
  }) async {
    await _channel.invokeMethod<void>('schedule', <String, Object?>{
      'earliestSeconds': earliest.inSeconds,
      'requiresNetwork': requiresNetwork,
    });
  }

  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  /// Diz ao nativo **qual função Dart** chamar quando a janela vier.
  ///
  /// O app pode estar fechado quando o sistema conceder a janela, e aí não há
  /// `main()` rodando: o Android sobe um motor Dart headless e precisa de um
  /// ponto de entrada para ele. Esse ponto vira um número — um `callback
  /// handle` — que sobrevive à morte do processo porque fica em
  /// `SharedPreferences`.
  ///
  /// [entrypoint] tem que ser uma **função de topo** (ou estática) anotada com
  /// `@pragma('vm:entry-point')`. Uma closure não tem handle, e o tree shaking
  /// remove o que não é anotado — nos dois casos a falha aparece só no
  /// aparelho, semanas depois.
  Future<void> registerEntrypoint(Function entrypoint) async {
    final handle = PluginUtilities.getCallbackHandle(entrypoint);
    if (handle == null) {
      throw ArgumentError(
        'sem handle para o ponto de entrada: ele precisa ser uma função de '
        'topo ou estática, anotada com @pragma(\'vm:entry-point\')',
      );
    }
    await _channel.invokeMethod<void>(
      'registerEntrypoint',
      <String, Object?>{'handle': handle.toRawHandle()},
    );
  }

  /// Registra quem esvazia a fila quando o sistema conceder a janela.
  ///
  /// O retorno de [work] decide o que o nativo responde ao sistema: `true`
  /// quando o trabalho terminou, `false` quando vale a pena tentar de novo — no
  /// Android, `Result.success()` ou `Result.retry()`.
  ///
  /// O sistema pode encerrar a tarefa no meio, e nada aqui tenta impedir isso:
  /// quem garante que a interrupção não deixa estado inconsistente é o journal,
  /// gravado antes de cada envio. É o cenário 13.
  void onBackgroundWork(Future<bool> Function() work) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'runBackgroundWork') {
        throw MissingPluginException('método desconhecido: ${call.method}');
      }
      return work();
    });
  }
}
