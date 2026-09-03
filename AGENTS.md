# Regras de trabalho — Flutter Outbox

Leia `PROJECT.md` uma vez antes de começar. Isto aqui é o que vale a cada
iteração.

**Estado em 29/08/2026: a camada 1 está fechada.** Os oito cenários passam, as
três ablações reprovam exatamente onde `docs/TESTING.md` prevê, o soak reproduz
por seed e a tabela do README é gerada por `dart run bin/measure.dart`. Os três
comandos abaixo existem e funcionam. A camada 2 não foi começada.

## Antes de escrever código

1. `docs/SETUP.md` — a sequência de bootstrap, se ainda não foi feita.
2. `docs/ARCHITECTURE.md` — a primeira fatia vertical. Comece por ela.
3. `docs/TESTING.md` — o cenário que você vai fazer passar.
4. `docs/PITFALLS.md` — se o que você vai mexer envolve dinheiro, tempo, ordem
   ou background.

## O que nunca muda sem decisão explícita

- **A chave de idempotência é função da intenção.** Nunca da tentativa, nunca de
  `DateTime.now()`, nunca de um contador, nunca de UUID gerado no envio. Se você
  precisar de tempo para gerar a chave, parou: releia `docs/PITFALLS.md`.
- **O journal é gravado antes do envio**, e o `await` da gravação acontece antes
  da chamada de rede. Inverter isso passa em todos os testes felizes e perde
  dinheiro em produção.
- **O ledger registra toda aplicação e não deduplica.** É o que dá dente aos
  testes. Se alguém "otimizar" isso, a suíte inteira vira decoração.
- **As três ablações fazem parte da entrega**, não do rascunho. Cada uma é o
  motor com **uma** decisão trocada, e cada uma precisa reprovar exatamente nos
  cenários que `docs/TESTING.md` lista. Ablação que passa em tudo significa que a
  decisão dela não está sendo testada por nada. Se você precisar **copiar** o
  motor para escrever uma ablação, pare: o desenho está errado, e
  `docs/ARCHITECTURE.md` explica por quê.
- **A suíte roda headless, sem rede, conta, chave de API ou contêiner.** Se um
  teste precisar de qualquer um deles, ele está no lugar errado.
- **Nada de plugin pronto de background na camada 3.** Escrever o platform
  channel é o que o projeto existe para demonstrar.
- **O contrato público segue o esboço de `docs/ARCHITECTURE.md`.** Mudou a
  forma? Mude lá primeiro, com o motivo — não no código e depois no documento.

## Convenções

- Núcleo em Dart puro: **nada em `lib/src/core/` importa `package:flutter`**. A
  camada 1 tem que rodar em `dart test`, sem SDK do Flutter.
- Dinheiro é `int` em centavos. **Ponto flutuante para valor é bug**, mesmo que
  o teste passe.
- Tempo entra por um `Clock` injetável. Nenhuma chamada direta a
  `DateTime.now()` fora da composição raiz.
- Aleatoriedade entra por seed. Nenhum `Random()` sem seed em código de teste ou
  de injeção de falha.
- Nome de cenário de teste é o número e a frase de `docs/TESTING.md`, para o
  documento e o código não divergirem.
- Arquivo passando de ~300 linhas é sinal de extrair, não regra.

## Comandos

```bash
dart test                  # 90 testes, headless, em ordem embaralhada
dart analyze               # limpo antes de qualquer commit
dart run bin/measure.dart  # a tabela comparativa do README
```

A medição é **gerada por comando**, nunca escrita à mão no README.

## Confidencialidade

Este projeto nasceu de trabalho real em fintech e é destinado a ser público.

- Contas, valores, referências e cenários são **sintéticos**. Sempre.
- Nunca use nome de empresa, sistema, time ou cliente. Nunca use endpoint,
  estrutura de banco ou identificador reais.
- Nada de credencial, token ou `.env` versionado.
- **Teste do reconhecimento:** alguém que trabalhe no domínio não pode
  identificar um sistema específico a partir deste código.

Na dúvida sobre uma origem, pergunte ao dono antes de escrever.

## Limite de escopo

Não adicione cliente HTTP real, autenticação, sincronização bidirecional,
resolução de conflito entre dispositivos, nem camada de UI além do app exemplo
mínimo. `PROJECT.md` tem a lista de não objetivos, e ela é para ser respeitada.

Se a camada 3 travar por mais de uma sessão, **pare e abra uma issue**. Ela
nunca bloqueia a publicação da camada 2.

## Próxima tarefa

A fatia vertical fechou. O que vem, na ordem de `docs/SETUP.md`:

1. **Cenários 1 e 6**, que são os outros dois em que a ablação
   `chave-da-tentativa` precisa reprovar. Faça-os antes dos demais: é a decisão
   já implementada sendo cobrada em mais de um lugar.
2. **Cenários 3, 4, 5, 7 e 8**, um por vez, com as invariantes verificadas
   depois de cada passo. O 3 exige um jeito de matar o processo no meio, e é
   ele que dá sentido à ablação `envia-antes-de-grava`. O 5 traz a fila e a
   ordem, e com ela as invariantes internas 2 e 4.
3. **`test/ablations_test.dart`**, verificando que cada ablação reprova
   **exatamente** onde a tabela de `docs/TESTING.md` prevê — nem mais, nem
   menos.
4. **`bin/measure.dart`**, e só então a substituição da tabela do README pela
   saída dele, tirando o aviso de "previsão a ser reproduzida".

Uma decisão de desenho ficou pendente e precisa ser fechada no passo 3: a
invariante interna 1 é verificada **ao interpretar a resposta**, e não enquanto
a tentativa está em voo. É essa escolha que faz a ablação `envia-antes-de-grava`
reprovar só em 3 e 9, como a tabela manda, em vez de reprovar em todos os
cenários. A redação da invariante em `docs/TESTING.md` ainda descreve a outra
leitura; ajuste o documento quando escrever o teste, com o motivo.
