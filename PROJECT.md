# Flutter Outbox — contrato

## Problema

Um aplicativo envia uma operação que muda dinheiro. O servidor processa com
sucesso e **a resposta se perde na volta**. Do lado do cliente, isso é
indistinguível de "a requisição não chegou".

Repetir pode cobrar duas vezes. Não repetir pode não ter cobrado. Retry não
resolve — retry *é* o problema quando a identidade da tentativa muda.

Some a isso o que acontece de verdade num celular: o processo é morto pelo
sistema operacional, o app fica dias sem abrir, a rede volta no meio de um
envio, a janela de background é negada, e o relógio do aparelho está errado.

## O que já existe, e por que não resolve

Esta seção existe porque a primeira pergunta de um revisor competente é "e o que
já tem no pub.dev?". Consultado em **2026-08-27**, pela busca pública do pub.dev
(`https://pub.dev/api/search?q=outbox`, `q=idempotency`, `q=offline+queue`), o
campo está longe de vazio: `offline_sync_outbox`, `durable_outbox`,
`relay_job_queue`, `offline_queue`, `offline_sync_engine` e outros, vários com
release em 2026.

**Não é um campo vazio. É um campo que resolve outro problema.** O padrão
publicado, lido nas descrições e nos README públicos, é consistente:

| O que o ecossistema faz | O que falta |
|---|---|
| a chave de idempotência é **opcional e fornecida pelo app** | quem erra a chave é o app, e o pacote não tem como perceber |
| timeout dispara **retry com backoff** | ninguém pergunta ao servidor o que aconteceu |
| entrega **at-least-once**, com a exatidão delegada ao backend | a expiração da chave no servidor não tem resposta nenhuma |

Um dos pacotes diz, na própria documentação, que at-least-once mais chave de
idempotência dá exatly-once *"desde que o backend respeite as chaves que
recebe"*. Isso está **correto e é insuficiente**: transfere o problema inteiro
para o servidor e não diz o que fazer quando a chave expira lá — que é
exatamente o momento em que o cliente precisa decidir entre reenviar e conferir.

Daí saem as três diferenças, e elas são o projeto:

1. **A chave é derivada, não pedida.** Se o app fornece a chave, o app erra a
   chave — e erra em silêncio.
2. **Timeout é pergunta, nunca reenvio.**
3. **Expiração de chave tem resposta**: cair para a referência de negócio no
   ledger, que não expira.

Consequência para a suíte, e é a melhor notícia desta pesquisa: **o cliente
ingênuo não é um espantalho.** Ele é o comportamento publicado do ecossistema em
2026. Isso troca "criei um adversário fraco para vencer" por "reproduzi a
prática corrente e medi onde ela quebra", e a segunda frase é a que vale como
evidência. `docs/TESTING.md` descreve as ablações.

## Quem usa

Quem escreve aplicativo móvel que envia operação não idempotente por natureza:
pagamento, transferência, emissão, baixa de estoque, confirmação de pedido. O
usuário direto é a pessoa desenvolvedora, e a superfície é um pacote do qual o
app depende.

## Resultado esperado

Um pacote Dart, usável a partir de Flutter, que oferece uma promessa pequena e
difícil:

> **enfileire uma operação que não pode duplicar, e receba um desfecho
> confiável** — mesmo depois de timeout, morte do processo, partição de rede,
> relógio errado e término de tarefa em background.

E, junto no repositório, a prova disso: servidor falso em processo, transporte
que injeta falha por seed, e uma suíte adversarial que reprova uma implementação
ingênua.

## Critério de aceite

Verificável, não em prosa. `docs/TESTING.md` traz o cenário correspondente a
cada linha.

- *Quando* uma operação for enfileirada, o sistema **deve** gravá-la de forma
  durável **antes** de qualquer tentativa de envio.
- *Quando* uma tentativa terminar em timeout, o sistema **deve** consultar o
  servidor antes de reenviar, e **nunca** reenviar com identidade nova.
- *Quando* o servidor não reconhecer a chave de idempotência, o sistema **deve**
  consultar o ledger pela referência de negócio antes de reenviar.
- *Quando* o processo for encerrado entre a gravação e o envio, o sistema
  **deve**, ao reabrir, concluir a operação exatamente uma vez.
- *Enquanto* não houver rede, o sistema **deve** preservar a ordem de
  enfileiramento e não descartar nenhuma operação.
- *Quando* a mesma chave chegar com payload diferente, o servidor de teste
  **deve** rejeitar e **não** sobrescrever o efeito original.
- *Quando* o sistema operacional encerrar a tarefa de background no meio de um
  envio, o sistema **deve** retomar na janela seguinte e produzir exatamente um
  efeito.
- *Quando* a suíte for executada com a mesma seed, ela **deve** produzir
  exatamente o mesmo resultado, incluindo a contagem de tentativas.

**Invariante global**, verificada em todos os cenários: a soma do ledger bate, e
cada operação tem exatamente um efeito.

## Como se descobre que está errado

Três sinais, e o segundo é o que mais engana:

1. **A invariante quebra** em qualquer cenário ou seed. É o caso fácil.
2. **O cliente ingênuo passa** nos mesmos testes. Se ele passa, a suíte não está
   provando corretude — está provando que o servidor deduplica. É por isso que o
   ledger **registra** toda aplicação em vez de deduplicar.
3. **A suíte precisa de rede, conta ou contêiner** para rodar. Aí ninguém vai
   verificar, e o pacote deixa de ter valor como evidência.

## Escopo, em três camadas

Sequência, não três projetos. **Publica na camada 2.**

| Camada | Entrega | Estado |
|---|---|---|
| 1 — núcleo | chave derivada da intenção, journal, fila ordenada, reconciliação, ledger, transporte com falha por seed, 8 cenários | **fechada em 29/08/2026** |
| 2 — persistência e app | SQLite, outbox durável, lease entre instâncias, app exemplo com roteiro manual, API pública documentada | **fechada em 29/08/2026** |
| 3 — background nativo | WorkManager e BGTaskScheduler por platform channel escrito à mão | **escrita em 29/08/2026, não validada em aparelho** |

A camada 3 é o diferencial, **nunca pré-requisito da 2**. Se travar, vira issue
aberta e o pacote publica sem ela.

## Não objetivos

- **Não** é um cliente HTTP, nem um framework de sincronização bidirecional.
- **Não** resolve conflito de escrita concorrente entre dispositivos: a garantia
  é sobre não duplicar efeito, não sobre mesclar estado divergente.
- **Não** implementa o lado servidor de produção. O servidor que vem junto é de
  teste, e existe para tornar a prova executável.
- **Não** usa plugin pronto de background. Escrever o platform channel é parte
  do que o projeto existe para demonstrar — usar `workmanager` de terceiro
  esvazia a camada 3.
- **Não** persegue desempenho. Corretude sob falha é o produto.

## Decisões tomadas

- **Dart puro no núcleo, Flutter só onde precisa.** A camada 1 não importa
  Flutter, o que mantém a suíte rodando em segundos no CI e no terminal.
- **O ledger registra toda aplicação, e não deduplica.** Sem isso os testes
  passariam por causa do ledger e não por causa da corretude do cliente.
- **A chave de idempotência é função da intenção** — nunca da tentativa, nunca
  do relógio. É a tese do projeto inteiro em uma linha.
- **A reconciliação termina no ledger**, não na chave: a chave expira no
  servidor, o ledger não.
- Stack e versões em `docs/STACK.md`, com data e o que reconfirmar.

## Em aberto

| Questão | Como resolver | Quando |
|---|---|---|
| Nome no pub.dev | `outbox`, `flutter_outbox`, `offline_outbox` e `dart_outbox` livres em **27/08/2026** (`curl -o /dev/null -w "%{http_code}" https://pub.dev/api/packages/<nome>` → 404). Reconfirmar antes do publish: nome livre é fato datado | antes de publicar |
| ~~Licença~~ | **Resolvido em 29/08/2026: MIT**, com aceite explícito do dono | — |
| Publicar no pub.dev ou só no GitHub | depende de quanto a API pública estabilizar na camada 2 | fim da camada 2 |
| ~~A camada 3 cobre as duas plataformas ou começa por uma~~ | **Resolvido em 27/08/2026: Android primeiro, iOS depois, e as duas são obrigatórias.** O motivo está em `docs/ARCHITECTURE.md` — não é preferência, é que o `BGTaskScheduler` não roda em simulador e o aparelho ligado ao Xcode não entra em background de verdade | — |

## A porta de publicação

Este repositório nasceu privado e **só vira público quando as cinco linhas
abaixo estiverem marcadas**. Elas estão aqui, e não em outro projeto, porque
quem for publicar vai estar olhando para cá.

- [x] **a camada 2 fechada** (29/08/2026): `git clone`, `dart pub get`,
      `dart test` — 104 testes, sem SDK do Flutter — e `dart run
      bin/measure.dart` imprime a tabela em que a ablação duplica cobrança.
      Validado num clone limpo, não no diretório de trabalho;
- [ ] varredura de confidencialidade limpa **no histórico inteiro**, não só na
      versão final — conta, valor, referência e cenário são sintéticos, e nada
      permite identificar um sistema real.

      **Bloqueada, e o que falta é seu:** `~/.config/termos-proibidos.txt` não
      existe, e sem a lista a varredura é inexistente. O que já foi feito não a
      substitui: uma varredura genérica roda antes de cada commit (caminhos de
      máquina, e-mails, chaves privadas, credenciais) e **pegou um vazamento
      real** — o diretório `.coverage/`, cheio de caminhos absolutos, que
      chegou ao stage e não ao histórico. `git log --all -p | grep -c "/Users/"`
      dá zero hoje. Isso é rede, não prova;
- [x] **licença escolhida: MIT**, com aceite explícito do dono em 29/08/2026.
      Permissiva e curta, que é o que menos atrito cria para um estranho
      executar e reaproveitar o artefato — e provocar isso é o que este
      repositório existe para fazer;
- [x] **nome livre no pub.dev**, reconfirmado em 29/08/2026:
      `flutter_outbox` e `flutter_outbox_background` respondem 404. Nome livre
      é fato datado — reconfirme de novo na véspera do publish;
- [ ] **autorização explícita do dono.** Elegibilidade não é autorização, e
      ninguém publica no lugar dele.

### A varredura não pode morar aqui dentro

Há uma armadilha no jeito óbvio de fazer a varredura, e ela é do tipo que só
aparece depois: **um script que procura os termos proibidos precisa conter os
termos proibidos.** Versionar `scripts/scan.sh` com o nome do empregador dentro
publica exatamente o que a varredura existe para impedir — e publica no lugar
mais fácil de encontrar, porque quem audita um repositório lê os scripts.

Então a regra é:

- a lista de termos **nunca é versionada aqui**, em nenhuma forma, nem em
  exemplo, nem em comentário, nem em teste;
- ela mora fora do repositório, num arquivo que o dono mantém, e a varredura
  roda **de fora para dentro**;
- o repositório registra **que** a varredura passou e **quando** — nunca contra
  o quê.

Em forma de comando, rodado de fora, com a lista fora:

```bash
git -C <repo> log --all -p | grep -i -f ~/.config/termos-proibidos.txt
```

`--all -p` porque a exigência é sobre o **histórico inteiro**: um termo apagado
num commit posterior continua no objeto anterior, e `git log -p` de um branch só
não o encontra. Se aparecer qualquer coisa, o conserto não é um commit novo — é
reescrever o histórico antes de publicar, ou nascer de novo com histórico limpo.

**Sem lista, a varredura não é limpa: ela é inexistente.** Marcar essa linha sem
ter rodado é pior do que não ter a linha.

### Uma ocorrência já conhecida, e ela não sai com commit novo

Varredura rodada em **27/08/2026**, ainda com o repositório privado. Um achado:

> os commits `63cd129` e `9a85788` contêm o **caminho absoluto do documento
> privado que encomendou o projeto**, dentro de um sistema pessoal na máquina do
> dono.

Não é credencial e não é dado de cliente — é um ponteiro para estrutura privada,
e não deveria estar num repositório público. Já foi removido da versão atual,
**e isso não basta**: `git log --all -p` continua entregando os dois commits.

Portanto, e antes de tornar público, uma das duas:

- reescrever o histórico (`git filter-repo`, ou refazer os dois commits), ou
- **nascer de novo**: `rm -rf .git && git init`, com um commit único. Não há
  história valiosa a preservar aqui — são dois commits de documentação, e a
  documentação está inteira no working tree.

A segunda é mais barata, mais segura e não depende de ferramenta extra.
**Enquanto isto não for feito, a linha de varredura da porta acima não pode ser
marcada.**

## Primeiro marco

A camada 1 fechada: os oito primeiros cenários passando, invariante verificada
em todos, resultado reproduzível por seed, e o cliente ingênuo reprovando. Sem
persistência e sem app — só o núcleo e a prova.

## Como se sabe que deu certo

`Como se descobre que está errado` cuida da corretude. Isto aqui é outra coisa:
**o repositório pode estar impecável e o projeto ter falhado assim mesmo.**

O sucesso não é "o repositório existe", e também não é estrela nem download. É:

> **alguém que o dono não conhece executou o artefato, ou deu um
> contra-argumento técnico a ele.**

É o único indicador que mede o que este projeto existe para produzir — evidência
que convence um estranho — e é antecedente: acontece antes de qualquer efeito na
carreira, e dá para observar.

**Isso não acontece por acaso, e três coisas aqui existem para provocá-lo:**

1. **A medição fica acima da dobra do README.** Uma tabela em que o cliente
   corrente do ecossistema duplica cobrança é a única coisa nesta página que faz
   alguém parar de rolar.
2. **A tabela de ablações é o convite.** "Remova esta decisão e este teste
   morre" é uma afirmação forte e verificável — é o formato que faz gente de
   sistemas distribuídos querer conferir.
3. **A seção `Onde eu posso estar errado` no README.** Contra-argumento chega
   quando existe um lugar óbvio para ele. Repositório que só afirma recebe
   silêncio; repositório que expõe as próprias dúvidas recebe resposta.

Se a camada 2 publicar e passarem três meses sem nenhum dos dois, **o problema
não é o código** — é distribuição, e a resposta está fora deste repositório.
Registre aqui e não conserte com mais engenharia.

## Próximo passo

**Validar a camada 3 em aparelho.** O código existe, compila nas duas
plataformas e tem o contrato do canal testado, mas nada disso é evidência de que
o sistema operacional concede a janela e chama o handler. No Android o
`TestDriver` do WorkManager fecha esse ciclo em emulador; no iOS a validação
leva **dias** e exige aparelho solto, e é por isso que ela nunca bloqueou a
publicação da camada 2.

Depois disso, as decisões do dono na porta de publicação — licença, varredura
com a lista de termos, e a autorização.

## Origem

O projeto foi encomendado para produzir evidência pública de três competências
que existiam só em repositório privado: idempotência e rastreabilidade ponta a
ponta, sincronização offline com fila, e módulos nativos por platform channel.
O documento que o encomendou é privado e **de propósito não está referenciado
aqui por caminho** — este repositório se entende sozinho, e um ponteiro para o
sistema de arquivos de uma máquina não sobrevive a um `git clone`.
