# Testes

Este documento **é a especificação**. O código existe para fazer estes cenários
passarem, e o nome de cada teste é o número e a frase daqui — para documento e
código não divergirem.

## O método tem nome, e não é invenção daqui

Substituir rede, relógio e aleatoriedade por objetos controlados, e reproduzir
qualquer falha por seed, chama-se **deterministic simulation testing**. Foi
inventado pelo FoundationDB, e é o que TigerBeetle, WarpStream e a Antithesis
usam para testar bancos de dados distribuídos. Dizer o nome importa por dois
motivos: quem conhece a linhagem sabe avaliar isto em trinta segundos, e quem
não conhece ganha uma trilha melhor do que este repositório.

Do trabalho mais recente do TigerBeetle vem a correção que mudou o desenho aqui:
**testar de fora não basta.** Verificar só o resultado final deixa passar um
sistema que chegou ao estado certo atravessando um estado impossível. A resposta
deles é instrumentar o protocolo para se autoverificar nos **pontos de decisão**,
e abortar na violação em vez de devolver falso. É por isso que as invariantes
abaixo estão em dois grupos, e o segundo grupo é o que a versão anterior deste
documento não tinha.

## As invariantes externas

O que dá para observar sem abrir o cliente. Verificadas em **todos** os
cenários, não só nos que parecem relevantes:

1. **Nenhuma referência de negócio tem mais de um efeito no ledger.** É a
   invariante global.
2. **O que o cliente considera liquidado tem exatamente um efeito.**
3. **O que foi rejeitado não tem efeito nenhum.**
4. **A soma do ledger bate.** Transferência move valor entre contas; não cria e
   não destrói.
5. **Todo efeito é rastreável** até a chave que o produziu.

## As invariantes internas

Verificadas **dentro** do motor, depois de cada transição de estado, e não no
`expect` do fim. Violação aqui **aborta** — não devolve `false`, não vira
`expect` que alguém comenta depois. O objetivo é que um estado impossível morra
onde nasceu, e não vinte passos adiante, quando já não dá para saber quem o
criou.

1. **Nada em `enviando` sem registro no journal.** Se existe uma tentativa em
   voo cujo journal não foi gravado, a ordem `grava → envia` foi invertida, e a
   suíte feliz não vê isso.
2. **A sequência do journal é contígua.** Sem buracos e sem repetição. Buraco
   significa gravação perdida; repetição significa duas instâncias escrevendo.
3. **A chave é estável ao longo das tentativas da mesma operação.** Se a chave
   de uma operação mudar entre a tentativa 1 e a 3, o defeito central do domínio
   acabou de acontecer — e ele é invisível pelo lado de fora enquanto a rede
   estiver boa.
4. **A ordem de saída é a ordem de entrada**, por sequência do journal.
5. **Todo efeito no ledger casa com uma chave que existe no journal.** Efeito
   órfão significa que o servidor aplicou algo que o cliente não registrou.

A número 3 é a mais valiosa das cinco: ela reprova o defeito **na tentativa em
que ele acontece**, e não na conta que fecha errada dez passos depois.

## As duas regras que dão dente à suíte

Sem elas os testes passam sem provar nada:

- **O ledger registra toda aplicação, e não deduplica.** Se deduplicasse, os
  cenários passariam por causa dele e não por causa da corretude do cliente.
- **A falha é injetada por seed.** Mesma seed, mesma sequência de falhas, mesmo
  resultado, em qualquer máquina. Nada de `Random()` sem seed.

A terceira regra — "o cliente ingênuo reprova" — virou a seção abaixo, porque um
espantalho só não é suficiente.

## As ablações

Um cliente ingênuo que erra tudo é fácil de vencer, e vencê-lo prova pouco: pode
ser que a suíte pegue um erro grosseiro qualquer, e que as três decisões de
desenho deste projeto não tenham nada a ver com o resultado.

O que prova alguma coisa é **remover uma decisão de cada vez** e mostrar qual
teste morre. Isso se chama estudo de ablação, e é o que separa "minha suíte é
forte" de "cada uma das minhas decisões é necessária, e aqui está a evidência
por decisão".

São quatro clientes, **todos parte da entrega**, todos compartilhando o mesmo
motor com uma decisão trocada:

| Cliente | O que muda | Precisa reprovar em |
|---|---|---|
| `correto` | nada | nenhum — passa em todos |
| `chave-da-tentativa` | a chave sai da tentativa, não da intenção | 1, 2, 6 |
| `envia-antes-de-grava` | o envio acontece antes do `await` do journal | 3, 9 |
| `reenvia-na-expiracao` | chave desconhecida pelo servidor é tratada como "nada aconteceu" | 8 |

O `chave-da-tentativa` é o antigo cliente ingênuo, e continua sendo o mais
importante: é ele que representa o padrão publicado no ecossistema
(`PROJECT.md` tem a medição). Os outros dois existem para responder "e se eu
tirar só isto?".

**A coluna da direita é uma asserção, não uma expectativa.** Um teste verifica
que cada ablação reprova **exatamente** onde a tabela diz. Ablação que reprova
em cenário demais é ruído; ablação que passa em todos significa que a decisão
correspondente **não está sendo testada por nada** — e aí o buraco é da suíte,
não do cliente.

Isto tem um custo real e ele precisa ser dito: o motor tem que ser parametrizado
pelas três decisões, em vez de tê-las embutidas. É uma restrição de desenho que
vem do teste, e ela é boa — as três decisões viram nomes explícitos no código em
vez de linhas espalhadas que alguém "otimiza" sem saber o que quebrou.

## Camada 1 — a rede mente

| # | Cenário | Invariante específica |
|---|---|---|
| 1 | duplo submit da mesma operação | exatamente um efeito |
| 2 | timeout, e o servidor teve sucesso | zero duplicação depois de reconciliar |
| 3 | processo morto entre journal e envio | retoma e conclui, uma vez |
| 4 | respostas fora de ordem | cada desfecho casa com a sua operação |
| 5 | partição com fila offline | ordem preservada, nada perdido |
| 6 | retry durante retry | sem efeito múltiplo |
| 7 | chave reusada com payload diferente | rejeita, não sobrescreve |
| 8 | relógio do cliente atrasado | expiração não corrompe estado |

O cenário 8 é o mais sutil: a chave de idempotência expira no servidor, e o
cliente não sabe que horas são. A defesa não é sincronizar relógio — é **não
depender dele**, e terminar a reconciliação no ledger, que não expira.

## Camada 2 — o processo morre de verdade

| # | Cenário | Invariante específica |
|---|---|---|
| 9 | morte no meio da gravação local | nada meio-gravado: a operação existe ou não existe |
| 10 | app reaberto dias depois | o outbox retoma na ordem, sem duplicar |
| 11 | migração de schema com fila pendente | nenhuma operação pendente se perde |
| 12 | duas instâncias disputando o mesmo outbox | um efeito só, sem corromper a ordem |

**O 11 não é um teste para escrever no primeiro dia.** Não existe migração
enquanto existe um schema só, e um teste de migração de v1 para v1 é decoração.
O que ele é de verdade é uma **regra para quando a primeira migração chegar**: a
fixture da migração nasce com fila pendente e journal em estado intermediário,
nunca com banco vazio. Escreva isso no código da migração, no dia dela.

**O 12 é da camada 2, mas a motivação é da 3.** Duas instâncias só disputam de
verdade quando o sistema operacional acorda o app em background com a tela
aberta. Dá para forçar dois motores sobre o mesmo arquivo na camada 2, e vale a
pena — só não confunda ter passado ali com ter provado no aparelho. Repare que a
invariante de duplicação sobrevive sozinha, porque as duas instâncias mandam a
**mesma** chave e o servidor deduplica; o que o lock protege é a **ordem** e o
estado local, e é isso que o teste precisa olhar.

## Camada 3 — o sistema operacional decide

| # | Cenário | Invariante específica |
|---|---|---|
| 13 | SO encerra a tarefa de background no meio do envio | retoma na janela seguinte, uma vez |
| 14 | background dispara sem rede | não gasta tentativa à toa, ordem preservada |
| 15 | iOS nega janela de execução por dias | nada expira, nada duplica quando volta |

## Tipos de teste, e o limite

- **Cenário adversarial** — a maior parte da suíte. Roteiro de falha
  determinístico, invariante verificada no fim e **depois de cada passo**.
- **Soak por seed** — dezenas de operações com falha aleatória reproduzível, em
  várias faixas de perda. Seed que reprovar **vira um cenário nomeado** na
  tabela acima; não conserte em silêncio.
- **Redução da seed que reprovou.** Uma seed que quebra com 25 operações é um
  relatório ilegível. Antes de virar cenário, ela é encurtada: remova operações e
  falhas enquanto continuar reprovando, e pare no menor roteiro que ainda quebra.
  É busca binária sobre uma lista, dezenas de linhas, e é o que transforma um
  soak vermelho em um cenário que cabe na cabeça. `docs/STACK.md` explica por que
  isto é escrito à mão em vez de vir de biblioteca.
- **Teste de contrato do servidor falso** — replay, conflito de chave,
  requisição em voo, expiração. Ele é uma implementação real e precisa ser
  testado como tal.
- **Roteiro manual**, a partir da camada 2 — no README, para quem quiser
  conferir com o celular na mão: modo avião, três operações, matar o app pelo
  gerenciador de tarefas, reabrir, ligar a rede.

**Sem framework de mock.** O servidor falso e o transporte não são dublês: são
implementações determinísticas cuja contagem de efeitos precisa ser observável.

## O que a suíte nunca pode precisar

Rede real, conta, chave de API, contêiner, emulador para a camada 1, ou
qualquer variável de ambiente. Se um teste precisar, ele está na camada errada.

SQLite nos testes da camada 2 roda headless por `sqflite_common_ffi` — sem
aparelho e sem emulador.

## A linha de base já medida — e por que ela ainda não vale

Antes deste repositório existir, um protótipo descartável da camada 1 foi
escrito, medido e **apagado de propósito**, para que ninguém copiasse estrutura
em vez de reimplementar do princípio. O que ele mediu, com 10 seeds × 25
pagamentos por linha:

| Perda de rede | Cliente | Efeitos | Duplicações | Sem desfecho |
|---|---|---|---|---|
| 0% | ingênuo | 250 | 0 | 0 |
| 10% | ingênuo | 258 | **8** | 0 |
| 25% | ingênuo | 272 | **22** | 0 |
| 40% | ingênuo | 294 | **46** | 11 |
| 60% | ingênuo | 319 | **75** | 32 |
| 80% | ingênuo | 338 | **106** | 105 |
| qualquer | **correto** | 250 | **0** | 0 |

A 40% de perda o protótipo também mediu o **custo** da corretude: 380 envios
contra 411 do ingênuo, mas 122 reconciliações e 939 gravações que o ingênuo não
paga.

**Estes números não são resultado deste repositório, e não vão para o README
como se fossem.** O código que os produziu não existe mais; ninguém pode
reproduzi-los a partir daqui. Eles estão registrados por três motivos, e nenhum
deles é publicação:

1. **São uma previsão falsificável.** Quando a camada 1 fechar e `measure.dart`
   rodar, os números novos vão cair perto destes ou não. Cair perto confirma;
   divergir muito é sinal para investigar — provavelmente o roteiro de falha
   ficou diferente, o que é informação e não decepção.
2. **Fixam a ordem de grandeza.** Duplicação existe a partir de 10% de perda, e
   "sem desfecho" no cliente ingênuo só aparece de 40% para cima. Uma suíte que
   não reproduzir esse formato está medindo outra coisa.
3. **Registram por que o escopo cresceu.** Este protótipo mostrou que a camada 1
   inteira sai em cerca de uma hora — e foi por isso que o projeto foi
   reescopado em 26/08/2026 para incluir persistência e background. Uma hora de
   trabalho não é um artefato de portfólio.

Quando a medição real existir, ela **substitui** esta tabela, e esta seção vira
uma nota de uma linha dizendo que a previsão bateu ou não.

## A medição

Gerada por comando, nunca escrita à mão. Compara o cliente correto com **as três
ablações** na mesma rede e nas mesmas seeds, e sai em Markdown, pronta para
colar no README:

```text
Operações por linha: N seeds × M operações

| Perda de rede | Cliente | Efeitos | Duplicações | Sem desfecho | Envios | Reconciliações | Gravações |
```

Faixas de perda a cobrir: 0%, 10%, 25%, 40%, 60% e 80%. A linha de 0% existe
para provar que os dois clientes acertam quando a rede coopera — sem ela, a
tabela parece manipulada.

**A coluna que decide é "Duplicações".** O cliente correto tem zero em toda a
faixa; o ingênuo cresce com a perda. As colunas de envios, reconciliações e
gravações mostram o **custo** da corretude, que não é zero e não deve ser
escondido.

É essa tabela que permite alguém **discordar com dados** em vez de discordar de
opinião.
