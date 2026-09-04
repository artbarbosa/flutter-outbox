# Como usar

O guia de ponta a ponta da API pública. `docs/ARCHITECTURE.md` explica **por
que** o contrato tem esta forma; aqui é só como usá-lo.

Duas coisas antes de começar, porque elas decidem o resto:

- **Você implementa uma interface: `Transport`.** É o único código que fala com
  o seu servidor, e é o único que o pacote não escreve por você.
- **Você escolhe uma referência de negócio antes de enviar.** É a identidade da
  operação, e é dela que a chave de idempotência é derivada. Se o seu app não
  souber dizer "esta é a transferência 8f3a91" antes de mandar, pare aqui e
  leia o ponto 1 de "Onde eu posso estar errado", no README — é o trabalho que
  este pacote empurra para quem usa, de propósito.

## 1. O transporte

O pacote precisa de três verbos. Mandar, e perguntar de duas formas:

```dart
class MeuTransporte implements Transport {
  MeuTransporte(this._http);

  final MeuClienteHttp _http;

  @override
  Future<SendResult> send(OutboundRequest request) async {
    try {
      final resposta = await _http.post(
        '/pagamentos',
        // A chave vai no cabeçalho, e o seu servidor precisa respeitá-la.
        headers: {'Idempotency-Key': request.key.value},
        body: request.payload,
      );
      return switch (resposta.status) {
        200 => SendApplied(resposta.body['efeito'] as String),
        // O servidor reconheceu a chave e devolveu o efeito original.
        200 when resposta.body['replay'] == true =>
          SendReplayed(resposta.body['efeito'] as String),
        409 => SendRefused('a mesma chave chegou com outro payload'),
        422 => SendRefused(resposta.body['motivo'] as String),
        _ => const SendLost(),
      };
    } on TimeoutException {
      // **Destino desconhecido, e não falha.** Devolver SendUnreachable aqui é
      // o erro que vira cobrança dupla.
      return const SendLost();
    } on SocketException {
      // Não saiu do aparelho: nada aconteceu do outro lado.
      return const SendUnreachable();
    }
  }

  @override
  Future<KeyLookup> lookupByKey(IdempotencyKey key) async { /* ... */ }

  @override
  Future<ReferenceLookup> lookupByReference(String reference) async { /* ... */ }
}
```

**A distinção entre `SendLost` e `SendUnreachable` é a mais importante do
arquivo inteiro.** A primeira diz "não sei"; a segunda diz "não saiu daqui".
Tratar as duas como falha é o erro central que este pacote existe para
demonstrar — e é você quem faz essa distinção, porque só o seu cliente HTTP
sabe qual das duas aconteceu.

Na dúvida, devolva `SendLost`. Ela é sempre segura: leva a uma pergunta, nunca
a um reenvio às cegas.

### As duas consultas

`lookupByKey` responde "o que você fez com esta chave?". `lookupByReference`
responde "e com esta operação de negócio?", e é o degrau de baixo — a chave
expira no servidor, a referência não.

Se o seu servidor não oferece nenhuma das duas, o desenho inteiro degrada para
at-least-once com chave. Isso é limite do problema, não do pacote, e está no
ponto 2 do "Onde eu posso estar errado".

## 2. Montar o outbox

```dart
final storage = await SqliteStorage.open(
  databaseFactory,                 // de `package:sqflite`, no aparelho
  path: p.join(diretorio.path, 'outbox.db'),
);

final outbox = Outbox(
  transport: MeuTransporte(http),
  storage: storage,

  // Espera entre tentativas. O padrão é não esperar — bom para teste, ruim
  // contra um servidor em dificuldade.
  retrySchedule: ExponentialBackoff(
    base: const Duration(seconds: 2),
    cap: const Duration(minutes: 5),
    seed: 1,
  ),

  // Impede que a janela de background e a tela esvaziem a fila ao mesmo tempo.
  lock: SqliteLease(storage.database, owner: 'ui'),
);
```

Uma instância por app. Ela não abre porta, não fala com nada sozinha e não tem
estado além do que está no `Storage`.

## 3. Submeter

```dart
final resultado = await outbox.submit(Operation(
  reference: 'transferencia-8f3a91',
  payload: {'from': contaA, 'to': contaB, 'amountInCents': 15000},
));
```

E os quatro desfechos. **Nenhum deles é erro:**

| Desfecho | O que aconteceu | O que a tela mostra |
|---|---|---|
| `Settled(effectId)` | aconteceu, uma vez, e dá para rastrear | o comprovante |
| `Rejected(reason)` | o servidor recusou, e não houve efeito | o motivo |
| `Queued()` | está no journal, na ordem, esperando rede ou a vez | "pendente" |
| `Undetermined()` | destino desconhecido; `recover()` fecha depois | "processando" |

**`Undetermined` não é falha.** Mostrar erro nesse estado faz o usuário mandar
de novo, e aí o efeito acontece duas vezes — é a mentira que este pacote existe
para impedir. Mostre "processando".

`Queued` também não é falha: a operação está gravada, na ordem, e sai sozinha.

## 4. Retomar

```dart
await outbox.recover();
```

No start do app, ao voltar do segundo plano, e na janela de background. É o que
fecha o que ficou aberto quando o processo morreu.

Chamar de novo enquanto outro motor está trabalhando **não faz nada e não é
erro** — o lease decide quem trabalha.

## 5. Background (opcional)

Pacote separado, porque ele importa `package:flutter` e o núcleo não pode:

```yaml
dependencies:
  flutter_outbox:
  flutter_outbox_background:
```

```dart
// No `main`:
final scheduler = BackgroundScheduler();
await scheduler.registerEntrypoint(drainInBackground);
await scheduler.schedule();

// Função de topo, anotada. Uma closure não tem handle, e sem a anotação o
// tree shaking remove isto do build de release — nos dois casos a falha
// aparece só no aparelho.
@pragma('vm:entry-point')
Future<void> drainInBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundScheduler().onBackgroundWork(() async {
    // Dono diferente do da tela: o lease decide quem esvazia a fila.
    final outbox = await montarOutbox(owner: 'background');
    await outbox.recover();
    return (await outbox.storage.unfinished(limit: 1)).isEmpty;
  });
}
```

No iOS, declare o identificador no `Info.plist`, em
`BGTaskSchedulerPermittedIdentifiers` — sem isso o registro lança em tempo de
execução, e só no aparelho.

**O sistema operacional decide quando a janela roda, e pode não conceder por
dias.** Nada no seu app pode expirar por não ter rodado.

## O que o app nunca faz

E é o produto inteiro:

- **não gera chave de idempotência** — ela é derivada da intenção;
- **não escreve retry** — o motor tenta, com teto e com espera;
- **não decide o que um timeout significa** — timeout é pergunta;
- **não trata morte de processo** — o journal é gravado antes do envio.

## Testar o seu código

O servidor falso e o transporte com falha são **parte da entrega**, não do
rascunho: você usa os mesmos para testar o seu app.

```dart
import 'package:flutter_outbox/testing.dart';

final server = FakeServer(openingBalances: {'conta-a': 100000});
final transport = ScriptedTransport(
  server: server,
  // Envio com a resposta perdida, consulta que não sai, reenvio bem-sucedido.
  script: const [Fault.responseLost, Fault.offline, Fault.none],
);

await meuFluxoDePagamento(Outbox(transport: transport, storage: InMemoryStorage()));

expect(server.ledger.duplications, 0);
expect(checkInvariants(server: server, journals: [await storage.all()]), isEmpty);
```

Mesma seed, mesmo resultado, em qualquer máquina. Sem rede, sem conta, sem
contêiner.
