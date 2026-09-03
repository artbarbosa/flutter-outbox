# Flutter Outbox

Uma fila para operações que **não podem acontecer duas vezes**.

> **Estado: as três camadas existem** (29/08/2026). 90 testes headless, a
> tabela abaixo é gerada por comando, o app exemplo roda e o platform channel
> compila nas duas plataformas. O que **não** está provado é o agendamento de
> background em aparelho de verdade — leia "O que ainda não foi provado", no
> fim. `PROJECT.md` tem o contrato.

## O problema

Seu app envia uma transferência. O servidor processa com sucesso. **E a resposta
se perde.**

Do lado do cliente, isso é indistinguível de "a requisição não chegou". Se você
repetir, pode cobrar duas vezes. Se não repetir, pode não ter cobrado. Não existe
resposta certa com a informação que o cliente tem.

Retry não resolve — retry **é** o problema, quando a identidade da tentativa
muda a cada tentativa.

Agora some o que acontece de verdade num celular: o sistema operacional mata o
processo, o app fica três dias fechado, a rede volta no meio de um envio, a
janela de background é negada, e o relógio do aparelho está errado.

## Quanto isso custa, em números

Gerado por `dart run bin/measure.dart`, 10 seeds × 25 pagamentos por linha, com
a falha injetada de forma determinística:

| Perda de rede | Duplicações do correto | Duplicações de `chave-da-tentativa` | Sem desfecho |
|---|---|---|---|
| 0% | 0 | 0 | 0 |
| 10% | 0 | 0 | 0 |
| 25% | 0 | **9** | 1 |
| 40% | 0 | **23** | 16 |
| 60% | 0 | **53** | 53 |
| 80% | 0 | **92** | 137 |

Cada "duplicação" é uma cobrança que aconteceu duas vezes. A coluna do meio é um
cliente que trata timeout como falha e retenta com identidade nova; a da
esquerda é este pacote, na mesma rede e nas mesmas seeds.

**A quarta coluna é o preço, e ela está aqui de propósito.** "Sem desfecho" não
é operação perdida: são operações íntegras, na fila, na ordem, esperando a
próxima janela. Elas crescem com a perda porque a ordem é **global e estrita** —
uma operação que não sai segura todas atrás dela. É uma escolha de domínio
discutível, e o ponto 3 de "Onde eu posso estar errado" a discute com estes
números na mão.

O comando imprime também a tabela completa, com as três ablações e o que a
corretude custa em envios, reconciliações e gravações — porque esse custo não é
zero e esconder isso tornaria a tabela suspeita.

**E o cliente comparado não é um espantalho.** Chave de idempotência opcional
fornecida pelo app, timeout resolvido com retry e backoff, exatidão delegada ao
backend — é o padrão dos pacotes de fila offline publicados no pub.dev em 2026,
inclusive os que anunciam "entrega garantida". `PROJECT.md` traz a comparação com
o que existe, com data e método.

## O que você escreve

```dart
final result = await outbox.submit(
  Operation(
    reference: 'transfer-8f3a91',        // identidade do pagamento
    payload: {'from': contaA, 'to': contaB, 'amountInCents': 15000},
  ),
);

switch (result) {
  Settled(:final effectId) => mostrarComprovante(effectId),
  Rejected(:final reason)  => mostrarErro(reason),
  Queued()                 => mostrarPendente(),
  Undetermined()           => mostrarProcessando(),
}
```

E, no start do app, `await outbox.recover();`.

**O que o app deixa de fazer é o produto:** não gera chave de idempotência, não
escreve retry, não decide o que um timeout significa, não trata morte de
processo. Quatro coisas que quase todo mundo implementa errado, e que erram em
silêncio.

## Como conferir que funciona

Sem acreditar em ninguém:

```bash
dart test                   # 90 testes: camadas 1 e 2, headless, em segundos
dart run bin/measure.dart   # a tabela acima, gerada
```

E as outras duas suítes, que precisam do SDK do Flutter:

```bash
cd background && flutter test   # o contrato do platform channel
cd example    && flutter test   # o app exemplo
```

Sem backend, sem conta, sem chave de API, sem contêiner. O servidor, a rede e o
relógio são objetos dentro do processo, e a falha é injetada de forma
determinística **por seed** — mesma seed, mesmo resultado, em qualquer máquina.

A suíte não se contenta em vencer um cliente ruim. Ela roda **quatro** clientes
sobre o mesmo motor — o correto e três **ablações**, cada uma com exatamente uma
decisão de desenho removida — e verifica que cada ablação reprova nos cenários
previstos, nem mais nem menos.

É a diferença entre "meus testes são fortes" e "cada uma das minhas três
decisões é necessária, e aqui está qual teste morre sem ela". Ablação que passa
em tudo significa que a decisão correspondente não está sendo testada por nada —
e aí o defeito é da suíte. `docs/TESTING.md` tem a tabela.

A partir da camada 2, dá para conferir com o celular na mão: modo avião, três
operações, **matar o app pelo gerenciador de tarefas**, reabrir, ligar a rede — e
o ledger fecha com três efeitos, na ordem certa.

## As três camadas

```text
/            flutter_outbox             1 e 2 · Dart puro · roda em dart test
background/  flutter_outbox_background  3 · plugin · Kotlin e Swift à mão
example/     outbox_example             o app, que depende dos dois
```

```text
1  núcleo         chave derivada da intenção · journal antes do envio ·
                  fila ordenada · reconciliação · ledger
2  persistência   SQLite · outbox durável · lease entre instâncias · app exemplo
3  background     WorkManager e BGTaskScheduler por platform channel
```

**A camada 3 mora em pacote separado, e não é capricho:** o `MethodChannel` vem
de `package:flutter`, e um pacote que declara Flutter não roda em `dart test` —
nem para as partes que não usam Flutter. Manter a camada 3 no pacote principal
custaria a suíte headless, que é o ativo mais valioso daqui.

## O roteiro manual, com o celular na mão

A camada 2 existe para isto, e ele leva dois minutos:

1. `cd example && flutter run`
2. Toque no ícone de **modo avião** na barra de cima;
3. Toque em **Pagar** três vezes — as três aparecem na lista como `pending`;
4. **Mate o app pelo gerenciador de tarefas.** Não é fechar: é matar;
5. Reabra o app. As três continuam lá, na mesma ordem, com a mesma sequência;
6. Desligue o modo avião.

O ledger fecha com três efeitos, na ordem certa, e nenhum pagamento acontece
duas vezes — mesmo com o transporte do exemplo perdendo metade das respostas de
propósito.

## O que ele não é

Não é cliente HTTP, não é sincronização bidirecional, não resolve conflito de
escrita entre dispositivos, e não traz servidor de produção. A garantia é
estreita e difícil: **não duplicar efeito.**

## Onde eu posso estar errado

Cinco pontos em que o desenho é discutível. Estão aqui porque um argumento sem
flanco exposto não recebe resposta — e resposta técnica de gente que não me
conhece é o que este repositório existe para produzir. **Se você discorda de
algum, abra uma issue: é o retorno mais útil que este projeto pode receber.**

**1. Derivar a chave da intenção só funciona se a intenção tiver identidade.**
O pacote assume que o app sabe dizer "esta é a transferência 8f3a91" antes de
enviar. Um app que só sabe "o usuário apertou pagar" não tem isso, e o conserto
é gerar e persistir a referência na tela — trabalho que eu empurro para quem
usa. Dá para argumentar que o pacote deveria resolver isso, e eu escolhi não
resolver.

**2. A reconciliação exige um servidor que aceite ser perguntado.** Consulta por
chave e por referência de negócio. Boa parte das APIs não oferece nem uma nem
outra, e contra um servidor desses o desenho inteiro degrada para at-least-once
com chave — exatamente o que eu critico. **Isto não é limitação de implementação,
é limite do problema**, e nenhum pacote de cliente resolve sozinho.

**3. Ordem global estrita pode ser a escolha errada, e agora dá para ver o
preço.** Preservar a ordem de enfileiramento significa que uma operação
problemática segura tudo atrás dela. Na tabela acima é a coluna "sem desfecho":
a 80% de perda ela sobe para **137 de 250 operações** — nenhuma perdida, todas
esperando, e a fila inteira parada atrás da primeira que não saiu.

Sistemas maduros costumam preferir ordem **por chave de partição** e paralelismo
entre partições, e com isso esse número despencaria. Escolhi ordem global porque
o domínio é dinheiro e o custo de reordenar é alto — mas é escolha de domínio,
não verdade, e num app com fila longa ela vira o gargalo. **Se você acha que a
troca está errada, os números para argumentar estão logo ali.**

**4. Simulação determinística prova o que foi simulado.** Reproduzir uma falha
por seed dá reprodutibilidade, não cobertura. O modelo de falha aqui é rede,
morte de processo e relógio. Não tem corrupção de disco, não tem `fsync` que
mente sobre ter gravado, não tem relógio saltando para trás. Se o seu contra-
exemplo estiver fora do modelo, a suíte fica verde e você está certo.

**5. O ledger que registra tudo é instrumento, não realidade.** Um servidor de
verdade deduplica, e a janela em que ele deduplica é finita e varia. Se a sua
janela real for menor do que o intervalo entre a falha e a reconciliação, o
resultado no seu ambiente será diferente do que a tabela mostra.

## O que ainda não foi provado

Um repositório que só afirma recebe silêncio. Estas são as lacunas conhecidas, e
elas estão aqui em vez de escondidas atrás de um badge verde:

**O agendamento de background não foi validado em aparelho.** O platform channel
compila nas duas plataformas e o contrato entre Dart, Kotlin e Swift tem teste.
O que não existe é evidência de que o sistema operacional concede a janela e
chama o handler num aparelho de verdade — e no iOS essa evidência leva **dias**
para ser produzida, porque `BGTaskScheduler` não roda em simulador e um aparelho
ligado ao Xcode não entra em background. `test/layer3_windows_test.dart` cobre o
que o motor faz **dentro** da janela; a janela vir é outra coisa.

**O cenário 11 não foi escrito**, e é de propósito: não existe migração enquanto
existe um schema só, e um teste de v1 para v1 é decoração. A regra dele — a
fixture nasce com fila pendente, nunca com banco vazio — está no código da
migração, em `SqliteStorage.migrate`.

**O modelo de falha é rede, morte de processo e relógio.** Não tem corrupção de
disco, não tem `fsync` que mente, não tem relógio saltando para trás.

## Para quem vai trabalhar aqui

| Documento | Quando |
|---|---|
| `PROJECT.md` | o contrato: critério de aceite, não objetivos, o que está em aberto, a porta de publicação |
| `AGENTS.md` | antes da primeira linha de código |
| `docs/SETUP.md` | a sequência de bootstrap, ainda não executada |
| `docs/ARCHITECTURE.md` | componentes, o contrato em esboço e a primeira fatia vertical |
| `docs/TESTING.md` | os 15 cenários adversariais e as invariantes |
| `docs/PITFALLS.md` | ao mexer em dinheiro, tempo, ordem ou background |
| `docs/STACK.md` | ao escolher ou trocar biblioteca |
