/// O desfecho que `submit` devolve ao app.
sealed class SubmitOutcome {
  const SubmitOutcome();
}

/// Aconteceu, uma vez, e dá para rastrear.
final class Settled extends SubmitOutcome {
  const Settled(this.effectId);

  final String effectId;

  @override
  String toString() => 'Settled($effectId)';
}

/// O servidor recusou, e não houve efeito nenhum.
final class Rejected extends SubmitOutcome {
  const Rejected(this.reason);

  final String reason;

  @override
  String toString() => 'Rejected($reason)';
}

/// Sem rede. Está no journal, na ordem, e sai quando der.
final class Queued extends SubmitOutcome {
  const Queued();

  @override
  String toString() => 'Queued()';
}

/// Destino desconhecido.
///
/// **Não é falha.** Devolver erro neste estado é a mentira que vira cobrança
/// dupla: o app trata como "não aconteceu", manda de novo, e o efeito acontece
/// duas vezes. O registro continua no journal e `recover()` fecha depois.
final class Undetermined extends SubmitOutcome {
  const Undetermined();

  @override
  String toString() => 'Undetermined()';
}
