import 'dart:math';

import '../core/decisions.dart';
import '../core/invariants.dart';
import '../core/journal.dart';
import '../core/operation.dart';
import '../core/storage.dart';
import 'clients.dart';
import 'fake_server.dart';
import 'scripted_transport.dart';

/// O que uma execução do soak custou e produziu.
final class SoakSample {
  const SoakSample({
    required this.effects,
    required this.duplications,
    required this.undetermined,
    required this.sends,
    required this.reconciliations,
    required this.writes,
    required this.sumsUp,
  });

  final int effects;

  /// A coluna que decide. Cada uma é uma cobrança que aconteceu duas vezes.
  final int duplications;

  final int undetermined;
  final int sends;
  final int reconciliations;
  final int writes;
  final bool sumsUp;

  SoakSample operator +(SoakSample other) => SoakSample(
        effects: effects + other.effects,
        duplications: duplications + other.duplications,
        undetermined: undetermined + other.undetermined,
        sends: sends + other.sends,
        reconciliations: reconciliations + other.reconciliations,
        writes: writes + other.writes,
        sumsUp: sumsUp && other.sumsUp,
      );

  static const zero = SoakSample(
    effects: 0,
    duplications: 0,
    undetermined: 0,
    sends: 0,
    reconciliations: 0,
    writes: 0,
    sumsUp: true,
  );
}

/// Uma rodada determinística: mesma seed, mesma sequência de falhas, mesmo
/// resultado, em qualquer máquina.
///
/// As invariantes internas ficam **desligadas** aqui, e só aqui: a medição quer
/// observar o dano até o fim, e não abortar no primeiro sinal dele.
Future<SoakSample> runSoak({
  required ClientKind kind,
  required int seed,
  required double lossRate,
  int operations = 25,
}) =>
    runSoakScript(
      kind: kind,
      script: scriptFor(seed: seed, lossRate: lossRate, operations: operations),
      operations: operations,
    );

/// O roteiro de falha de uma seed, explícito.
///
/// Existe separado de [runSoak] porque a **redução** precisa manipular a lista:
/// encurtar um roteiro até o menor que ainda reprova é busca binária sobre ele,
/// e para isso ele tem que ser um valor, não um detalhe interno.
List<Fault> scriptFor({
  required int seed,
  required double lossRate,
  int operations = 25,
}) {
  final random = Random(seed);
  return [
    for (var i = 0; i < operations * 100; i++) _draw(random, lossRate),
  ];
}

/// A mesma rodada, com o roteiro dado em vez de sorteado.
Future<SoakSample> runSoakScript({
  required ClientKind kind,
  required List<Fault> script,
  int operations = 25,
}) async {
  final server = FakeServer(openingBalances: const {
    'conta-a': 100000000,
    'conta-b': 0,
  });
  final storage = InMemoryStorage();
  final transport = ScriptedTransport(server: server, script: script);
  final outbox = buildClient(
    kind,
    transport: transport,
    storage: storage,
    nonces: AttemptNonces(),
    invariants: Invariants.off(),
  );

  for (var i = 0; i < operations; i++) {
    try {
      await outbox.submit(Operation(
        reference: 'pagamento-$i',
        payload: {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': 1000 + i * 100,
        },
      ));
    } on ProcessKilled {
      // Fora do modelo de falha desta medição, mas o soak não pode morrer por
      // causa disso.
    }
  }

  // O app reabre algumas vezes e tenta fechar o que ficou em aberto. É o que um
  // app de verdade faz, e é onde a reconciliação paga o preço dela.
  for (var round = 0; round < 3; round++) {
    try {
      await outbox.recover();
    } on ProcessKilled {
      break;
    }
  }

  final journal = await storage.all();
  return SoakSample(
    effects: server.ledger.entries.length,
    duplications: server.ledger.duplications,
    undetermined: journal
        .where((e) =>
            e.state != JournalState.settled && e.state != JournalState.rejected)
        .length,
    sends: transport.sends,
    reconciliations: transport.lookups,
    writes: storage.writes,
    sumsUp: server.ledger.sumsUp,
  );
}

Fault _draw(Random random, double lossRate) {
  if (random.nextDouble() >= lossRate) return Fault.none;
  // Partição e resposta perdida em partes iguais: a primeira o cliente
  // reconhece, a segunda ele não tem como distinguir de sucesso.
  return random.nextBool() ? Fault.offline : Fault.responseLost;
}
