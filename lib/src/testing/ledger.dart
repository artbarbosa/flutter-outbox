import '../core/idempotency_key.dart';

/// Um efeito que existiu de verdade do lado do servidor.
final class LedgerEntry {
  const LedgerEntry({
    required this.effectId,
    required this.key,
    required this.reference,
    required this.from,
    required this.to,
    required this.amountInCents,
  });

  final String effectId;
  final IdempotencyKey key;
  final String reference;
  final String from;
  final String to;

  /// Dinheiro é `int` em centavos. Ponto flutuante para valor é bug, mesmo que
  /// o teste passe.
  final int amountInCents;

  @override
  String toString() =>
      'LedgerEntry($effectId $reference $from→$to ${amountInCents}c key=$key)';
}

/// O livro do servidor de teste.
///
/// **Registra toda aplicação, e não deduplica.** É a regra que dá dente à
/// suíte inteira: se ele deduplicasse, os cenários passariam por causa dele e
/// não por causa da corretude do cliente, e a suíte viraria decoração.
final class Ledger {
  Ledger({Map<String, int> openingBalances = const {}})
      : _balances = Map<String, int>.from(openingBalances),
        _opening = openingBalances.values.fold(0, (a, b) => a + b);

  final List<LedgerEntry> entries = [];
  final Map<String, int> _balances;
  final int _opening;

  void apply(LedgerEntry entry) {
    entries.add(entry);
    _balances[entry.from] = (_balances[entry.from] ?? 0) - entry.amountInCents;
    _balances[entry.to] = (_balances[entry.to] ?? 0) + entry.amountInCents;
  }

  int balanceOf(String account) => _balances[account] ?? 0;

  /// Invariante externa 4: transferência move valor entre contas; não cria e
  /// não destrói.
  bool get sumsUp => _balances.values.fold(0, (a, b) => a + b) == _opening;

  List<LedgerEntry> forReference(String reference) =>
      entries.where((e) => e.reference == reference).toList();

  /// Quantas referências de negócio tiveram mais de um efeito.
  ///
  /// Cada uma é uma cobrança que aconteceu duas vezes. É a coluna que decide a
  /// tabela da medição.
  int get duplications {
    final byReference = <String, int>{};
    for (final entry in entries) {
      byReference[entry.reference] = (byReference[entry.reference] ?? 0) + 1;
    }
    return byReference.values
        .where((count) => count > 1)
        .fold(0, (total, count) => total + count - 1);
  }

  /// Invariante externa 1, a global.
  bool get everyReferenceHasAtMostOneEffect => duplications == 0;
}
