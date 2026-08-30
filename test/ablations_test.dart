import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// O estudo de ablação.
///
/// Não basta vencer um cliente ruim: isso provaria que a suíte pega um erro
/// grosseiro qualquer, e não que cada uma das três decisões de desenho é
/// necessária. O que prova alguma coisa é **remover uma decisão de cada vez** e
/// mostrar qual teste morre.
///
/// A tabela de `docs/TESTING.md` é uma **asserção**, e é isto aqui que a cobra.
void main() {
  const timeout = Duration(seconds: 10);

  group('cada ablação reprova exatamente onde docs/TESTING.md prevê', () {
    for (final scenario in layer1Scenarios) {
      for (final kind in ClientKind.values) {
        final mustFail = scenario.ablationsThatMustFail.contains(kind);

        test('cenário ${scenario.number} / ${kind.label} → '
            '${mustFail ? "reprova" : "passa"}', () async {
          final outcome =
              await runScenario(scenario, kind).timeout(timeout);

          if (mustFail) {
            expect(
              outcome.passed,
              isFalse,
              reason: 'a tabela diz que ${kind.label} reprova no cenário '
                  '${scenario.number}, e ele passou — ou a decisão não é '
                  'necessária ali, ou o cenário parou de cobrá-la',
            );
          } else {
            expect(
              outcome.violations,
              isEmpty,
              reason: 'a tabela não prevê reprovação de ${kind.label} no '
                  'cenário ${scenario.number}:\n  $outcome',
            );
          }
        });
      }
    }
  });

  test('o cliente correto passa em todos os cenários', () async {
    for (final scenario in layer1Scenarios) {
      final outcome =
          await runScenario(scenario, ClientKind.correct).timeout(timeout);
      expect(outcome.violations, isEmpty, reason: '$scenario:\n  $outcome');
    }
  });

  test('nenhuma ablação passa em todos os cenários', () async {
    // Ablação que passa em tudo significa que a decisão correspondente **não
    // está sendo testada por nada** — e aí o buraco é da suíte, não do cliente.
    for (final kind in ClientKind.values.where((k) => k != ClientKind.correct)) {
      final failures = <int>[];
      for (final scenario in layer1Scenarios) {
        final outcome = await runScenario(scenario, kind).timeout(timeout);
        if (!outcome.passed) failures.add(scenario.number);
      }
      expect(
        failures,
        isNotEmpty,
        reason: 'a decisão removida por ${kind.label} não é cobrada por '
            'nenhum cenário da camada 1',
      );
    }
  });

  test('a tabela do código é a tabela do documento', () {
    // Se estas listas mudarem, `docs/TESTING.md` muda junto — no mesmo commit.
    final tabela = {
      for (final s in layer1Scenarios)
        s.number: s.ablationsThatMustFail.map((k) => k.label).toList()..sort(),
    };

    expect(tabela, {
      1: ['chave-da-tentativa'],
      2: ['chave-da-tentativa'],
      3: ['envia-antes-de-grava'],
      4: ['envia-antes-de-grava'],
      5: <String>[],
      6: ['chave-da-tentativa'],
      7: ['chave-da-tentativa'],
      8: ['reenvia-na-expiracao'],
    });
  });
}
