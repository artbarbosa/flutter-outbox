# Flutter Outbox

Uma fila para operações que **não podem acontecer duas vezes**.

> **Estado: documentação de criação.** Nada foi implementado ainda. Os comandos
> citados aqui não existem — o plano para criá-los está em `docs/SETUP.md`, e o
> que já foi decidido está em `PROJECT.md`.

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

Um cliente que trata timeout como falha e retenta com identidade nova — 10 seeds
× 25 pagamentos por linha:

| Perda de rede | Duplicações | Sem desfecho |
|---|---|---|
| 0% | 0 | 0 |
| 10% | **8** | 0 |
| 25% | **22** | 0 |
| 40% | **46** | 11 |
| 60% | **75** | 32 |
| 80% | **106** | 105 |

Cada "duplicação" é uma cobrança que aconteceu duas vezes.

> ⚠️ **Estes números vêm de um protótipo descartável que foi apagado, e não deste
> repositório.** Enquanto este aviso estiver aqui, leia a tabela como uma
> **previsão a ser reproduzida**, não como resultado. Ela sai daqui no dia em que
> `dart run bin/measure.dart` existir e imprimir a versão de verdade.
> A procedência completa está em `docs/TESTING.md`.

**E o cliente comparado não é um espantalho.** Chave de idempotência opcional
fornecida pelo app, timeout resolvido com retry e backoff, exatidão delegada ao
backend — é o padrão dos pacotes de fila offline publicados no pub.dev em 2026,
inclusive os que anunciam "entrega garantida". `PROJECT.md` traz a comparação com
o que existe, com data e método.

## O que você escreve

```dart
final resultado = await outbox.submit(
  Operacao(
    referencia: 'transferencia-8f3a91',   // identidade do pagamento
    payload: {'de': contaA, 'para': contaB, 'valorEmCentavos': 15000},
  ),
);

switch (resultado) {
  Liquidada(:final efeitoId) => mostrarComprovante(efeitoId),
  Rejeitada(:final motivo)   => mostrarErro(motivo),
  NaFila()                   => mostrarPendente(),
  SemDesfecho()              => mostrarProcessando(),
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
dart test                   # a suíte adversarial, headless, em segundos
dart run bin/measure.dart   # a tabela abaixo, gerada
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
1  núcleo         chave derivada da intenção · journal antes do envio ·
                  fila ordenada · reconciliação · ledger
2  persistência   SQLite · outbox durável · app exemplo que sobrevive a app kill
3  background     WorkManager e BGTaskScheduler por platform channel
```

Uma sequência, não três projetos. **A camada 3 nunca é pré-requisito da 2**: se
travar, vira issue aberta e o pacote existe sem ela.

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

**3. Ordem global estrita pode ser a escolha errada.** Preservar a ordem de
enfileiramento significa que uma operação problemática segura tudo atrás dela.
Sistemas maduros costumam preferir ordem **por chave de partição** e paralelismo
entre partições. Escolhi ordem global porque o domínio é dinheiro e o custo de
reordenar é alto — mas é uma escolha de domínio, não uma verdade, e num app com
fila longa ela vira o gargalo.

**4. Simulação determinística prova o que foi simulado.** Reproduzir uma falha
por seed dá reprodutibilidade, não cobertura. O modelo de falha aqui é rede,
morte de processo e relógio. Não tem corrupção de disco, não tem `fsync` que
mente sobre ter gravado, não tem relógio saltando para trás. Se o seu contra-
exemplo estiver fora do modelo, a suíte fica verde e você está certo.

**5. O ledger que registra tudo é instrumento, não realidade.** Um servidor de
verdade deduplica, e a janela em que ele deduplica é finita e varia. Se a sua
janela real for menor do que o intervalo entre a falha e a reconciliação, o
resultado no seu ambiente será diferente do que a tabela mostra.

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
