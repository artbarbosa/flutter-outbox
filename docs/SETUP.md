# Bootstrap

**Executado em 29/08/2026, passos 1 a 6.** A camada 1 está fechada e os
comandos do fim deste documento funcionam. O que resta é o passo 7, a camada 2.
O texto abaixo fica como está: ele é o registro do que foi feito, e a régua para
quem for repetir a sequência em outro projeto.

## Antes de rodar qualquer coisa

Reconfirme o que `docs/STACK.md` lista como datado. As versões de lá foram
consultadas em 2026-08-26 e reconfirmadas em 2026-08-27, e envelhecem:

- Dart e Flutter estáveis correntes, e se as linhas escolhidas seguem suportadas;
- versão e manutenção de `sqflite`, `sqflite_common_ffi`, `path_provider`,
  `test` e `lints`.

Se alguma decisão não se sustentar na reconfirmação, **atualize
`docs/STACK.md` antes de instalar** — não depois, e não só no código.

## A sequência

1. **Iniciar o pacote Dart puro na raiz.** É pacote, não app: a camada 1 roda em
   `dart test`, sem SDK do Flutter. O app exemplo vem depois, em subdiretório
   próprio.
2. **Declarar as dependências mínimas.** Em `dev_dependencies`, o suficiente
   para testar e analisar. Runtime da camada 1: **nenhuma**. Se aparecer
   dependência de runtime na camada 1, pare e justifique.
3. **Fechar a primeira fatia vertical** de `docs/ARCHITECTURE.md`, com o cenário
   2 de `docs/TESTING.md` passando e o cliente ingênuo reprovando nele.
4. **Preencher os cenários 1 a 8**, um a um, cada um verificando as invariantes
   externas **e as internas** — as internas abortam, não devolvem `false`.
5. **Fechar as três ablações** e o teste que verifica que cada uma reprova
   exatamente onde `docs/TESTING.md` prevê. Elas vêm antes da medição de
   propósito: se o motor não for parametrizável pelas três decisões, é agora que
   isso aparece, com quatro cenários escritos e não com quinze.
6. **Escrever o gerador da medição** — a tabela comparativa sai de comando,
   nunca da mão — e **substituir a tabela do README** pela saída dele, tirando o
   aviso de "previsão a ser reproduzida".
7. Só então a camada 2: persistência, fila durável e app exemplo.

Um cenário por vez, com a invariante verificada depois de cada passo. A
tentação de implementar os oito de uma vez é o caminho mais curto para uma suíte
que passa sem provar.

## Estrutura esperada depois do bootstrap

```text
lib/
  outbox.dart              superfície pública
  src/
    core/                  camada 1 — sem package:flutter aqui dentro
    storage/               camada 2 — SQLite, sobre sqflite_common (Dart puro)
    testing/               servidor falso, transporte com falha, as 4 clientes
test/
  scenario_01_....dart     um arquivo por cenário, nome igual ao de TESTING.md
  ablations_test.dart      cada ablação reprova onde TESTING.md prevê
  soak_seeded_test.dart
  shrink_test.dart
  layer2_sqlite_test.dart  cenários 9, 10 e 12, headless por sqflite_common_ffi
bin/
  measure.dart             gera a tabela comparativa
background/                camada 3 — plugin Flutter separado, Kotlin e Swift
example/                   app exemplo, a partir da camada 2
```

**A camada 3 não ficou em `lib/src/platform/`, como esta lista previa.** O
`MethodChannel` vem de `package:flutter`, e declarar Flutter no pacote principal
faria `dart test` parar de rodar — inclusive para as camadas 1 e 2. Ela virou
`background/`, um plugin próprio. `docs/ARCHITECTURE.md` tem o desenho.

`src/testing/` fica em `lib/` de propósito: o servidor falso e o transporte com
falha são parte da entrega, e quem depende do pacote precisa conseguir usá-los
para testar o próprio código.

## Comandos que deverão existir

```bash
dart pub get
dart analyze               # precisa terminar limpo
dart test                  # a suíte inteira, headless, em segundos
dart run bin/measure.dart  # a tabela comparativa
```

Nenhuma variável de ambiente é necessária, e nenhuma deve ser introduzida: a
suíte não fala com nada fora do processo. Se um dia for preciso, declare o
**nome** aqui — nunca o valor.

## Como validar num ambiente limpo

Em uma máquina sem nada deste projeto, **e sem o SDK do Flutter**:

1. `git clone` e entrar no diretório;
2. `dart pub get`;
3. `dart analyze` — precisa terminar limpo;
4. `dart test` — precisa passar sem instalar mais nada, sem rede e sem conta;
5. `dart run bin/measure.dart` — precisa imprimir a tabela.

Se qualquer passo exigir um passo a mais, o critério 1 de `docs/STACK.md` foi
violado e a decisão precisa ser revista.

`background/` e `example/` ficam de fora disso de propósito: eles são pacotes
próprios, exigem Flutter, e têm as suas próprias suítes.

```bash
cd background && flutter pub get && flutter analyze && flutter test
cd example    && flutter pub get && flutter analyze && flutter test
```

O `analysis_options.yaml` da raiz exclui os dois. Sem essa exclusão, `dart
analyze` num clone recém-feito reprova com dezenas de erros até alguém rodar
`flutter pub get` lá dentro — e aí o passo 3 acima deixaria de valer.

## Versionamento

O repositório já nasce versionado. Vale a decisão de `AGENTS.md`: nada de
credencial, token ou arquivo de ambiente versionado, em nenhum momento.

Publicar no GitHub e escolher licença **são decisões do dono**, listadas em
aberto no `PROJECT.md`. Não decida por ele.
