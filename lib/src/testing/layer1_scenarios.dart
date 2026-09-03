import '../core/clock.dart';
import '../core/outcome.dart';
import '../core/storage.dart';
import 'clients.dart';
import 'scenario.dart';
import 'scripted_transport.dart';

/// Os oito cenários da camada 1 — "a rede mente", em `docs/TESTING.md`.
///
/// O nome de cada um é o número e a frase do documento. Se um mudar aqui sem
/// mudar lá, o documento parou de ser a especificação.
final List<Scenario> layer1Scenarios = [
  _scenario01,
  _scenario02,
  _scenario03,
  _scenario04,
  _scenario05,
  _scenario06,
  _scenario07,
  _scenario08,
];

final _scenario01 = Scenario(
  number: 1,
  name: 'duplo submit da mesma operação',
  ablationsThatMustFail: {ClientKind.attemptKey},
  // Dois submits ao mesmo tempo, da mesma operação: é o usuário tocando duas
  // vezes no botão, e não uma fila.
  strictOrder: false,
  body: (run) async {
    final outbox = run.client(transport: run.transport());
    const reference = 'transferencia-1a2b';

    // Sem `await` entre os dois: é o usuário tocando duas vezes no botão, e
    // nenhum dos dois submits enxerga o journal do outro a tempo.
    final results = await Future.wait([
      outbox.submit(run.transfer(reference, 15000)),
      outbox.submit(run.transfer(reference, 15000)),
    ]);

    return [
      if (run.effectsFor(reference) != 1)
        'cenário 1: esperado exatamente um efeito, encontrado '
            '${run.effectsFor(reference)}',
      for (final result in results)
        if (result is! Settled)
          'cenário 1: um dos submits devolveu $result em vez de liquidar',
    ];
  },
);

final _scenario02 = Scenario(
  number: 2,
  name: 'timeout, e o servidor teve sucesso',
  ablationsThatMustFail: {ClientKind.attemptKey},
  body: (run) async {
    // O roteiro está na tabela de `docs/TESTING.md`: envio com resposta
    // perdida, consulta que não sai do aparelho, reenvio com a rede boa.
    final transport = run.transport(
      script: const [Fault.responseLost, Fault.offline, Fault.none],
    );
    final outbox = run.client(transport: transport);
    const reference = 'transferencia-8f3a91';

    final result = await outbox.submit(run.transfer(reference, 15000));

    return [
      if (result is! Settled) 'cenário 2: devolveu $result em vez de liquidar',
      if (run.effectsFor(reference) != 1)
        'cenário 2: ${run.effectsFor(reference)} efeitos depois de reconciliar',
    ];
  },
);

final _scenario03 = Scenario(
  number: 3,
  name: 'processo morto entre journal e envio',
  ablationsThatMustFail: {ClientKind.sendBeforeJournal},
  body: (run) async {
    // O storage sobrevive ao processo; o motor não.
    final storage = InMemoryStorage();
    const reference = 'transferencia-3c4d';

    final firstLife = run.client(
      transport: run.transport(script: const [Fault.processKilled]),
      storage: storage,
    );
    try {
      await firstLife.submit(run.transfer(reference, 15000));
    } on ProcessKilled {
      // O sistema operacional encerrou o app. É o cenário, não um erro.
    }

    // O app reabre, sobre o mesmo storage, e é isto que `recover()` existe
    // para fazer.
    final secondLife = run.client(transport: run.transport(), storage: storage);
    await secondLife.recover();

    final journal = await storage.all();
    return [
      if (journal.isEmpty)
        'cenário 3: a operação sumiu — o journal não tem registro dela depois '
            'da morte do processo, e nenhum recover pode retomá-la',
      if (run.effectsFor(reference) != 1)
        'cenário 3: esperado exatamente um efeito depois de retomar, '
            'encontrado ${run.effectsFor(reference)}',
    ];
  },
);

final _scenario04 = Scenario(
  number: 4,
  name: 'respostas fora de ordem',
  ablationsThatMustFail: {ClientKind.sendBeforeJournal},
  // Os dois submits são concorrentes de propósito: quem chama assim pediu
  // concorrência, e a invariante deste cenário é outra — cada desfecho casa
  // com a sua operação, e não com a que respondeu primeiro.
  strictOrder: false,
  body: (run) async {
    // As duas respostas voltam de trás para frente.
    final transport = run.transport(reorderWindow: 2);
    final outbox = run.client(transport: transport);

    final results = await Future.wait([
      outbox.submit(run.transfer('transferencia-4a', 10000)),
      outbox.submit(run.transfer('transferencia-4b', 25000)),
    ]);

    final violations = <String>[];
    for (final (reference, amount) in [
      ('transferencia-4a', 10000),
      ('transferencia-4b', 25000),
    ]) {
      final effects = run.server.ledger.forReference(reference);
      if (effects.length != 1) {
        violations.add('cenário 4: $reference tem ${effects.length} efeitos');
        continue;
      }
      // Cada desfecho casa com a **sua** operação, e não com a que respondeu
      // primeiro.
      if (effects.single.amountInCents != amount) {
        violations.add(
          'cenário 4: $reference liquidou com ${effects.single.amountInCents}c '
          'em vez de ${amount}c — o desfecho trocou de operação',
        );
      }
    }
    for (final result in results) {
      if (result is! Settled) {
        violations.add('cenário 4: devolveu $result em vez de liquidar');
      }
    }
    return violations;
  },
);

final _scenario05 = Scenario(
  number: 5,
  name: 'partição com fila offline',
  ablationsThatMustFail: {},
  body: (run) async {
    final storage = InMemoryStorage();
    const enqueued = [
      ('transferencia-5a', 10000),
      ('transferencia-5b', 20000),
      ('transferencia-5c', 30000),
    ];

    // Sem rede: nada sai, e nada pode se perder.
    final offline = run.client(
      transport: run.transport(
        script: const [Fault.offline, Fault.offline, Fault.offline],
      ),
      storage: storage,
    );
    final violations = <String>[];
    for (final (reference, amount) in enqueued) {
      final result = await offline.submit(run.transfer(reference, amount));
      if (result is! Queued) {
        violations.add('cenário 5: $reference devolveu $result sem rede');
      }
    }

    // A rede volta **pela metade**: a primeira ainda não sai.
    //
    // É aqui que mora o caso que o roteiro de tudo-offline não alcança. Com
    // todas offline, nenhuma sai e a ordem se preserva por acidente; é quando
    // algumas podem sair que a promessa é cobrada. Se o motor seguir para a
    // segunda, ela é aplicada com a primeira ainda pendente, e a ordem de
    // enfileiramento quebra sem ninguém duplicar nada.
    final parcial = run.transport(
      script: const [Fault.offline, Fault.none, Fault.none],
    );
    await run.client(transport: parcial, storage: storage).recover();

    if (run.effectsFor(enqueued.first.$1) == 0 &&
        run.effectsFor(enqueued[1].$1) > 0) {
      violations.add(
        'cenário 5: ${enqueued[1].$1} foi aplicada com ${enqueued.first.$1} '
        'ainda pendente — ordem global estrita não deixa furar a fila',
      );
    }
    if (parcial.sends > 1) {
      violations.add(
        'cenário 5: ${parcial.sends} envios numa janela em que a primeira '
        'operação nem saiu — insistir atrás de uma parada gasta orçamento de '
        'background para descobrir a mesma coisa várias vezes',
      );
    }

    // E então a rede volta de verdade.
    final online = run.transport();
    await run.client(transport: online, storage: storage).recover();

    final expectedOrder = [for (final (reference, _) in enqueued) reference];
    if (online.referencesInSendOrder.join(',') != expectedOrder.join(',')) {
      violations.add(
        'cenário 5: a ordem de saída não é a de enfileiramento — '
        '${online.referencesInSendOrder.join(" → ")}',
      );
    }
    for (final (reference, _) in enqueued) {
      if (run.effectsFor(reference) != 1) {
        violations.add(
          'cenário 5: $reference tem ${run.effectsFor(reference)} efeitos',
        );
      }
    }
    return violations;
  },
);

final _scenario06 = Scenario(
  number: 6,
  name: 'retry durante retry',
  ablationsThatMustFail: {ClientKind.attemptKey},
  body: (run) async {
    // Três tentativas, todas com a resposta perdida e a consulta inacessível:
    // o orçamento acaba sem o cliente descobrir o destino.
    final transport = run.transport(script: const [
      Fault.responseLost, Fault.offline, //
      Fault.responseLost, Fault.offline, //
      Fault.responseLost, Fault.offline, //
    ]);
    final outbox = run.client(transport: transport);
    const reference = 'transferencia-6e7f';

    final first = await outbox.submit(run.transfer(reference, 15000));

    // A janela de background acorda o app enquanto a tela já está aberta: dois
    // retries sobre a mesma operação, ao mesmo tempo.
    await Future.wait([outbox.recover(), outbox.recover()]);

    return [
      if (first is! Undetermined)
        'cenário 6: o submit devolveu $first, e o cenário exige que ele acabe '
            'sem desfecho para os retries disputarem',
      if (run.effectsFor(reference) != 1)
        'cenário 6: ${run.effectsFor(reference)} efeitos depois de retries '
            'concorrentes',
    ];
  },
);

final _scenario07 = Scenario(
  number: 7,
  name: 'chave reusada com payload diferente',
  ablationsThatMustFail: {ClientKind.attemptKey},
  body: (run) async {
    const reference = 'transferencia-7g8h';

    // O aparelho de sempre envia a operação de verdade.
    await run
        .client(transport: run.transport(), storage: InMemoryStorage())
        .submit(run.transfer(reference, 15000));

    // E então a mesma referência de negócio volta com outro valor, de um
    // storage limpo — outro aparelho, ou o app reinstalado.
    final result = await run
        .client(transport: run.transport(), storage: InMemoryStorage())
        .submit(run.transfer(reference, 99000));

    final effects = run.server.ledger.forReference(reference);
    return [
      if (result is! Rejected)
        'cenário 7: devolveu $result em vez de rejeitar o payload divergente',
      if (effects.length != 1)
        'cenário 7: ${effects.length} efeitos para a mesma referência',
      if (effects.isNotEmpty && effects.first.amountInCents != 15000)
        'cenário 7: o efeito original virou ${effects.first.amountInCents}c — '
            'foi sobrescrito',
    ];
  },
);

final _scenario08 = Scenario(
  number: 8,
  name: 'relógio do cliente atrasado',
  ablationsThatMustFail: {ClientKind.resendOnExpiry},
  body: (run) async {
    // O envio se perde, e entre ele e a consulta o servidor **esquece a
    // chave**. O cliente não tem como prever esse instante, e o relógio dele
    // está anos atrasado — de propósito, para provar que nada aqui depende
    // dele.
    final transport = run.transport(
      script: const [Fault.responseLost, Fault.keysExpired],
    );
    final outbox = run.client(
      transport: transport,
      clock: FixedClock(DateTime.utc(2019, 3, 14)),
    );
    const reference = 'transferencia-8i9j';

    final result = await outbox.submit(run.transfer(reference, 15000));

    return [
      if (result is! Settled)
        'cenário 8: devolveu $result — a chave expirou e a reconciliação '
            'deveria ter terminado no ledger, que não expira',
      if (run.effectsFor(reference) != 1)
        'cenário 8: ${run.effectsFor(reference)} efeitos depois da expiração '
            'da chave',
    ];
  },
);
