import 'package:flutter_outbox/testing.dart';

/// Gera a tabela comparativa do README.
///
/// Ela é **gerada por comando, nunca escrita à mão**: uma tabela digitada é uma
/// afirmação, e uma tabela gerada é uma medição que qualquer pessoa reproduz
/// com `dart run bin/measure.dart`. É isso que permite alguém discordar com
/// dados em vez de discordar de opinião.
Future<void> main(List<String> args) async {
  const seeds = 10;
  const operations = 25;

  /// Quantas vezes o app reabre e tenta de novo.
  ///
  /// Declarado porque **é parte da medição**: com ordem global estrita a fila
  /// trava atrás da primeira operação que não sai, e quantas janelas o app teve
  /// pesa tanto quanto a taxa de perda. Vinte representa um app que foi aberto
  /// algumas vezes ao longo de um dia.
  const windows = 20;
  const lossRates = [0.0, 0.10, 0.25, 0.40, 0.60, 0.80];

  // Uma passada só; as duas tabelas saem dos mesmos números.
  final samples = <(double, ClientKind), SoakSample>{};
  var everySumChecks = true;
  for (final lossRate in lossRates) {
    for (final kind in ClientKind.values) {
      var total = SoakSample.zero;
      for (var seed = 1; seed <= seeds; seed++) {
        total += await runSoak(
          kind: kind,
          seed: seed,
          lossRate: lossRate,
          operations: operations,
          windows: windows,
        );
      }
      samples[(lossRate, kind)] = total;
      everySumChecks = everySumChecks && total.sumsUp;
    }
  }

  String percent(double rate) => '${(rate * 100).round()}%';
  String bold(int value) => value == 0 ? '0' : '**$value**';

  final buffer = StringBuffer()
    ..writeln('Operações por linha: $seeds seeds × $operations operações, '
        'com até $windows janelas de background')
    ..writeln()
    // A comparação que decide, e a que vai acima da dobra do README: a coluna
    // de duplicações do cliente correto é zero na faixa inteira.
    ..writeln('| Perda de rede | Duplicações do correto | '
        'Duplicações de `chave-da-tentativa` | Sem desfecho |')
    ..writeln('|---|---|---|---|');

  for (final lossRate in lossRates) {
    final correct = samples[(lossRate, ClientKind.correct)]!;
    final naive = samples[(lossRate, ClientKind.attemptKey)]!;
    buffer.writeln('| ${percent(lossRate)} | ${correct.duplications} | '
        '${bold(naive.duplications)} | ${correct.undetermined} |');
  }

  buffer
    ..writeln()
    ..writeln('A tabela completa, com as três ablações e o custo da '
        'corretude:')
    ..writeln()
    ..writeln('| Perda de rede | Cliente | Efeitos | Duplicações | '
        'Sem desfecho | Envios | Reconciliações | Gravações |')
    ..writeln('|---|---|---|---|---|---|---|---|');

  for (final lossRate in lossRates) {
    for (final kind in ClientKind.values) {
      final total = samples[(lossRate, kind)]!;
      final label =
          kind == ClientKind.correct ? '**${kind.label}**' : kind.label;
      buffer.writeln(
        '| ${percent(lossRate)} | $label | ${total.effects} | '
        '${bold(total.duplications)} | ${total.undetermined} | ${total.sends} | '
        '${total.reconciliations} | ${total.writes} |',
      );
    }
  }

  buffer
    ..writeln()
    ..writeln('A soma do ledger fecha em todas as linhas: '
        '${everySumChecks ? "sim" : "**NÃO** — investigar antes de publicar"}')
    ..writeln()
    ..writeln('O modelo de falha desta medição é **só rede** — partição e '
        'resposta perdida. Por isso `envia-antes-de-grava` e')
    ..writeln('`reenvia-na-expiracao` saem idênticas ao correto: o dano delas '
        'precisa de morte de processo e de expiração de')
    ..writeln('chave, que a suíte cobre nos cenários 3, 4 e 8 e esta tabela '
        'não exercita. Ler as duas linhas como "estas decisões')
    ..writeln('não importam" seria exatamente o erro contrário.')
    ..writeln()
    ..writeln('As colunas de envios, reconciliações e gravações são idênticas '
        'entre os quatro clientes de propósito: cada ablação')
    ..writeln('muda **uma** decisão, e nenhuma delas muda quantas vezes se '
        'tenta. O custo da corretude aparece na comparação entre')
    ..writeln('as faixas de perda, não entre os clientes.');

  // A linha de 0% existe para provar que os clientes acertam quando a rede
  // coopera. Sem ela, a tabela parece manipulada.
  print(buffer.toString().trimRight());
}
