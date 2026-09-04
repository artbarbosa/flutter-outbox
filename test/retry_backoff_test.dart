import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// A espera entre tentativas.
///
/// Testada **sem esperar**: `RecordedDelay` guarda o que teria dormido, e as
/// asserções são sobre a política. Uma suíte que espera de verdade deixa de
/// rodar em segundos, e aí ninguém a roda.
void main() {
  group('a política', () {
    test('a primeira tentativa nunca espera', () {
      final schedule = ExponentialBackoff(jitter: 0);
      expect(schedule.beforeAttempt(1), Duration.zero);
    });

    test('dobra a cada tentativa', () {
      final schedule = ExponentialBackoff(
        base: const Duration(seconds: 2),
        jitter: 0,
      );
      expect(schedule.beforeAttempt(2), const Duration(seconds: 2));
      expect(schedule.beforeAttempt(3), const Duration(seconds: 4));
      expect(schedule.beforeAttempt(4), const Duration(seconds: 8));
    });

    test('para de dobrar no teto', () {
      final schedule = ExponentialBackoff(
        base: const Duration(seconds: 2),
        cap: const Duration(seconds: 10),
        jitter: 0,
      );
      // Sem teto, uma fila que passou dias offline acordaria com esperas de
      // horas — e com ordem estrita isso segura a fila inteira.
      expect(schedule.beforeAttempt(5), const Duration(seconds: 10));
      expect(schedule.beforeAttempt(40), const Duration(seconds: 10),
          reason: 'expoente grande não pode estourar o deslocamento');
    });

    test('o jitter varia dentro da faixa, e é reprodutível por seed', () {
      List<Duration> run(int seed) {
        final schedule = ExponentialBackoff(
          base: const Duration(seconds: 10),
          jitter: 0.2,
          seed: seed,
        );
        return [for (var n = 2; n <= 6; n++) schedule.beforeAttempt(n)];
      }

      final first = run(7);
      expect(run(7), first, reason: 'mesma seed, mesma sequência de esperas');
      expect(run(8), isNot(first), reason: 'seeds diferentes divergem');

      // ±20% sobre 10s na segunda tentativa.
      expect(first.first.inMilliseconds, inInclusiveRange(8000, 12000));
    });

    test('sem jitter, aparelhos que caíram juntos voltam juntos', () {
      // O caso que o jitter existe para evitar, escrito como teste para o
      // motivo não se perder: dez clientes com a mesma política e sem jitter
      // pedem exatamente a mesma espera, e o servidor que caiu recebe a
      // tempestade inteira de uma vez.
      final semJitter = [
        for (var i = 0; i < 10; i++)
          ExponentialBackoff(jitter: 0, seed: i).beforeAttempt(3),
      ];
      expect(semJitter.toSet(), hasLength(1));

      final comJitter = [
        for (var i = 0; i < 10; i++)
          ExponentialBackoff(jitter: 0.2, seed: i).beforeAttempt(3),
      ];
      expect(comJitter.toSet().length, greaterThan(1));
    });
  });

  group('o motor', () {
    test('espera entre as tentativas, e não antes da primeira', () async {
      final server = FakeServer(openingBalances: const {'conta-a': 1000000});
      final delay = RecordedDelay();
      final outbox = buildClient(
        ClientKind.correct,
        // Três tentativas, todas com a resposta perdida e a consulta
        // inacessível.
        transport: ScriptedTransport(server: server, script: const [
          Fault.responseLost, Fault.offline, //
          Fault.responseLost, Fault.offline, //
          Fault.responseLost, Fault.offline, //
        ]),
        retrySchedule: ExponentialBackoff(
          base: const Duration(seconds: 2),
          jitter: 0,
        ),
        delay: delay,
      );

      await outbox.submit(Operation(
        reference: 'transferencia-backoff',
        payload: const {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': 15000,
        },
      ));

      expect(delay.waits, [
        Duration.zero,
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('o padrão é não esperar, e a medição depende disso', () async {
      // `NoBackoff` é o padrão de propósito: a suíte e a medição precisam rodar
      // em segundos, e a espera é decisão da composição raiz do app.
      final server = FakeServer(openingBalances: const {'conta-a': 1000000});
      final delay = RecordedDelay();
      final outbox = buildClient(
        ClientKind.correct,
        transport: ScriptedTransport(server: server),
        delay: delay,
      );

      await outbox.submit(Operation(
        reference: 'transferencia-sem-espera',
        payload: const {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': 15000,
        },
      ));

      expect(delay.waits, everyElement(Duration.zero));
    });
  });
}
