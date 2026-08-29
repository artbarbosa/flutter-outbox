import 'fingerprint.dart';

/// Uma intenção de negócio, não uma requisição.
///
/// A diferença é o projeto inteiro: a requisição é a tentativa, e a tentativa
/// muda. A intenção não.
final class Operation {
  Operation({required this.reference, required this.payload}) {
    if (reference.isEmpty) {
      throw ArgumentError.value(
        reference,
        'reference',
        'a referência de negócio é a identidade da operação, e não pode ser '
            'vazia — sem ela não há como reconciliar quando a chave expirar',
      );
    }
  }

  /// A identidade **de negócio**, estável e escolhida pelo app.
  ///
  /// Duas operações legitimamente idênticas em valor precisam de referências
  /// diferentes, ou viram uma só: a identidade é da operação, não do conteúdo
  /// (`docs/PITFALLS.md`, seção Identidade).
  final String reference;

  final Map<String, Object?> payload;

  /// O que o servidor compara para detectar a mesma chave com outro conteúdo.
  ///
  /// Não entra na chave de idempotência de propósito: se entrasse, mudar o
  /// payload produziria uma chave nova, o servidor nunca veria conflito, e o
  /// cenário 7 não teria como existir.
  late final String payloadFingerprint = fingerprint(canonicalJson(payload));

  @override
  String toString() => 'Operation($reference)';
}
