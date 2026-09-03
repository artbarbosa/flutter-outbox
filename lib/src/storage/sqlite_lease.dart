import 'package:sqflite_common/sqlite_api.dart';

import '../core/clock.dart';
import '../core/lock.dart';

/// O lock da camada 2: uma linha no banco, com dono e prazo.
///
/// **Lease, e não lock**: um processo morto pelo sistema operacional não libera
/// coisa nenhuma, e um lock sem prazo travaria o outbox até a próxima
/// reinstalação do app. O prazo resolve isso sem exigir que ninguém se comporte
/// bem na hora de morrer.
///
/// O custo é conhecido e aceito: se um motor demorar mais que [duration], outro
/// pode entrar antes de ele terminar. Isso não duplica efeito — a chave é a
/// mesma e o servidor deduplica —, só desfaz a economia de envio que o lease
/// existe para dar. Um prazo generoso torna isso raro; um prazo infinito
/// trocaria um problema raro por um permanente.
final class SqliteLease implements OutboxLock {
  SqliteLease(
    this._db, {
    required this.owner,
    this.clock = const SystemClock(),
    this.duration = const Duration(minutes: 5),
  });

  static const table = 'outbox_lease';

  static const schema = '''
    CREATE TABLE $table (
      id         INTEGER PRIMARY KEY CHECK (id = 1),
      owner      TEXT NOT NULL,
      expires_at TEXT NOT NULL
    )
  ''';

  final Database _db;

  /// Quem está segurando. Serve para diagnóstico e para o dono reentrar no
  /// próprio lease em vez de esperar o prazo dele mesmo.
  final String owner;

  final Clock clock;
  final Duration duration;

  @override
  Future<bool> acquire() async {
    final now = clock.nowUtc();
    // Uma transação só: ler o dono atual e gravar o novo em duas deixa a janela
    // exata em que dois motores acham que ganharam.
    return _db.transaction((txn) async {
      final rows = await txn.query(table, limit: 1);
      if (rows.isNotEmpty) {
        final holder = rows.single['owner']! as String;
        final expiresAt = DateTime.parse(rows.single['expires_at']! as String);
        final expired = !expiresAt.isAfter(now);
        if (!expired && holder != owner) return false;
      }

      await txn.insert(
        table,
        {
          'id': 1,
          'owner': owner,
          'expires_at': now.add(duration).toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  @override
  Future<void> release() async {
    // Só o dono solta. Sem esta cláusula, um motor que perdeu o lease por
    // expiração liberaria o de quem entrou depois dele.
    await _db.delete(table, where: 'owner = ?', whereArgs: [owner]);
  }
}
