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

1. **Nada em `enviando` sem registro no journal.** Verificada no momento em que
   o motor **interpreta a resposta**: se chegou uma resposta para uma operação
   que o journal não conhece, a ordem `grava → envia` foi invertida.

   A leitura literal — checar enquanto a tentativa está em voo — foi tentada e
   descartada, e o motivo importa: ela faz `envia-antes-de-grava` abortar em
   **todos** os cenários, porque a inversão está sempre lá. A tabela de ablações
   ficaria sem informação nenhuma, e este documento chama isso de ruído duas
   seções abaixo. Verificando na interpretação, a ablação só reprova onde a
   inversão **causa dano**: quando o processo morre no meio (3 e 9) ou quando a
   ordem do journal passa a ser a ordem da rede (4). É a diferença entre uma
   invariante que acusa a decisão e uma que acusa a consequência dela.
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
| `chave-da-tentativa` | a chave sai da tentativa, não da intenção | 1, 2, 6, **7** |
| `envia-antes-de-grava` | o envio acontece antes do `await` do journal | 3, **4**, 9 |
| `reenvia-na-expiracao` | chave desconhecida pelo servidor é tratada como "nada aconteceu" | 8 |

**Os dois números em negrito não estavam aqui, e apareceram na execução.** A
tabela previa 1, 2, 6 e 3, 9; a camada 1 implementada reprova também em 7 e em
4. Estão registrados porque a regra do soak vale para o estudo de ablação
também: reprovação que aparece não se conserta em silêncio.

- **`chave-da-tentativa` reprova no 7** porque a defesa do servidor contra
  payload divergente **depende de a chave ser estável**. Com uma chave nova a
  cada tentativa o servidor nunca vê o conflito: ele recebe uma chave que não
  conhece, aplica, e a proteção que ele oferece fica inacessível. A decisão 1
  não protege só contra duplicação — ela é o que dá ao servidor a chance de
  recusar.
- **`envia-antes-de-grava` reprova no 4** porque gravar depois de enviar faz o
  journal registrar na ordem em que a **rede respondeu**, e não na ordem em que
  o app pediu. Ninguém duplica nada e a conta fecha; o que se perde é a ordem de
  enfileiramento, e quem pega isso é a invariante interna 4.

Nenhum dos dois é ruído: são a mesma decisão sendo cobrada em mais um lugar, o
que é argumento **a favor** dela. O que seria ruído é uma ablação reprovando
onde a decisão dela não tem influência nenhuma — e isso não aconteceu.

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

**O roteiro do cenário 2, porque ele é a fatia vertical e o formato dos outros
sai daqui.** Três interações de rede, em ordem, e a lista *é* a especificação:

| # | Interação | Falha injetada | O que o servidor faz |
|---|---|---|---|
| 1 | envio | a resposta se perde | **aplica o efeito**, e a resposta não volta |
| 2 | consulta por chave | não sai do aparelho | nada |
| 3 | envio | nenhuma | reconhece a chave e devolve o efeito original |

A consulta que falha não é enfeite, e sem ela o cenário não vale nada: o cliente
de chave-da-tentativa perguntaria pela chave que ele mesmo acabou de usar,
receberia o efeito de volta e liquidaria certo. Os dois clientes ficariam
indistinguíveis, e o cenário estaria medindo o servidor em vez do cliente.

É **quando não dá para perguntar** que o reenvio acontece, e é o reenvio que
separa a chave estável da chave nova. Timeout continua sendo pergunta; o
reenvio é o que sobra quando a pergunta não chega — e ele só é seguro porque a
identidade não mudou.

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

**Estes três têm duas metades, e só uma é testável aqui.** Uma janela de
background exige que o sistema operacional a **conceda**, e que o motor faça a
coisa certa **dentro** dela. `test/layer3_windows_test.dart` cobre a segunda,
simulando a janela como um `recover()` sobre um storage que sobrevive — e passar
ali não prova nada sobre a janela vir. A primeira metade só fecha em aparelho
solto, ao longo de dias, e `docs/PITFALLS.md` explica por que o helper de LLDB
do iOS não substitui isso.

**O cenário 15 encontrou um defeito no motor, e vale registrar como.** Ele fazia
o *cliente correto* cobrar duas vezes: ao retomar uma operação que ficou sem
desfecho, o motor começava por reenviar, e depois de cinco dias a chave já não
existia no servidor. A correção está em `docs/PITFALLS.md`, seção Rede —
retomar exige reconciliação bem-sucedida antes de qualquer reenvio, enquanto
reenviar dentro da mesma chamada continua seguro. É a diferença entre estar no
meio de uma tentativa e voltar a uma que ficou, e ela não é medida em tempo.

Este é o tipo de achado que justifica a suíte inteira: nenhum dos oito cenários
da camada 1 pegava isso, porque nenhum deles deixa uma operação parada entre
duas sessões.

## Tipos de teste, e o limite

- **Cenário adversarial** — a maior parte da suíte. Roteiro de falha
  determinístico, invariante verificada no fim e **depois de cada passo**.
- **Soak por seed** — dezenas de operações com falha aleatória reproduzível, em
  várias faixas de perda. Seed que reprovar **vira um cenário nomeado** na
  tabela acima; não conserte em silêncio.
- **Redução da seed que reprovou** — `shrink()`, em `lib/src/testing/`. Uma seed
  que quebra com 25 operações é um relatório ilegível. Antes de virar cenário,
  ela é encurtada: remova operações e falhas enquanto continuar reprovando, e
  pare no menor roteiro que ainda quebra. Na prática, 2011 falhas viram 4.
  `docs/STACK.md` tem a medição e explica por que isto é escrito à mão em vez de
  vir de biblioteca.
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

## A linha de base do protótipo, e o que a medição real disse

O protótipo descartável previa, com 10 seeds × 25 pagamentos, duplicações de
8 / 22 / 46 / 75 / 106 para perdas de 10 / 25 / 40 / 60 / 80%. **A medição deste
repositório, rodada em 29/08/2026, deu 0 / 9 / 25 / 72 / 211.**

O **formato** bateu, e era ele que a previsão fixava: o cliente correto tem zero
duplicações na faixa inteira, a ablação cresce monotonicamente com a perda, e
"sem desfecho" só aparece de 40% para cima. A **magnitude** divergiu para menos
nas faixas baixas e para mais na de 80%, e a causa é conhecida: o roteiro de
falha daqui divide a perda em partes iguais entre partição e resposta perdida, e
só a segunda produz duplicação. Metade das falhas desta suíte é inofensiva por
construção, o que o protótipo não fazia.

Isso é informação e não decepção, como esta seção previa que seria. A tabela
válida é a que `dart run bin/measure.dart` imprime; a do protótipo não é
reproduzível a partir daqui e não volta ao README.

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
