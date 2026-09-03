/// Impede que dois motores esvaziem a mesma fila ao mesmo tempo.
///
/// O app pode acordar em background enquanto o usuário abre a tela, e aí
/// existem dois motores sobre o mesmo outbox. A duplicação de efeito sobrevive
/// sozinha — as duas instâncias mandam a mesma chave, e o servidor deduplica —,
/// mas o trabalho sai dobrado, e no iOS trabalho dobrado na janela de background
/// vira janela negada na próxima vez.
abstract interface class OutboxLock {
  /// `false` quer dizer "outro motor está com a fila", e não é erro: quem não
  /// conseguiu simplesmente não trabalha agora.
  Future<bool> acquire();

  Future<void> release();
}

/// A camada 1: um processo, um motor, nada a proteger.
final class NoLock implements OutboxLock {
  const NoLock();

  @override
  Future<bool> acquire() async => true;

  @override
  Future<void> release() async {}
}
