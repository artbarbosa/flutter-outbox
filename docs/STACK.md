# Stack

Consultado em 2026-08-26, reconfirmado em 2026-08-27 e **de novo em 2026-08-29,
no bootstrap, sem nenhuma mudança**: as cinco versões da tabela abaixo continuam
sendo as correntes. Versão é fato datado: quem mexer aqui **reconfirma antes de
instalar**.

O método, para você não ter que acreditar na tabela:

```bash
dart --version && flutter --version
for p in test sqflite sqflite_common_ffi path_provider lints; do
  curl -s "https://pub.dev/api/packages/$p" |
    python3 -c "import json,sys;d=json.load(sys.stdin)['latest'];print(d['version'],d['published'][:10])"
done
```

A segunda coluna é a data de publicação da versão corrente. **É ela que decide**
manutenção, não estrela e não popularidade.

## O que dirigiu a escolha

Em ordem, e a ordem importa:

1. **A prova precisa rodar em um comando, sem infraestrutura.** Qualquer coisa
   que adicione um passo entre `git clone` e o resultado custa caro, porque o
   valor do repositório é ser conferível por um estranho em minutos.
2. **O núcleo não pode depender de Flutter.** Camada 1 em `dart test`, em
   segundos, sem SDK de UI.
3. **Transação e ordem são requisito, não conforto.** Um outbox que perde ordem
   ou grava metade não serve.
4. Manutenção viva. Biblioteca parada é dívida com data marcada.

## Decisões

| Camada | Escolha | Versão consultada | Status |
|---|---|---|---|
| Linguagem | Dart | 3.13.1 (Flutter 3.47.1, canal stable) | aceita |
| Núcleo | Dart puro, zero dependência de runtime | — | aceita |
| Teste | `test` | 1.31.2 · 2026-06-27 | aceita |
| SQLite headless no teste | `sqflite_common_ffi` | 2.4.2+1 · 2026-08-16 | aceita |
| Persistência (camada 2) | `sqflite`, com SQL escrito à mão | 2.4.3 · 2026-06-02 | aceita |
| Caminho de arquivo | `path_provider` | 2.1.6 · 2026-06-15 | aceita |
| Background (camada 3) | platform channel escrito à mão sobre `androidx.work` e `BGTaskScheduler` | API de plataforma | aceita |
| Lint | `lints` | 6.1.0 · 2026-01-30 | aceita |
| Mocks | nenhum | — | aceita |
| Teste baseado em propriedade | nenhum; shrinking escrito à mão | — | aceita |

## Por que cada uma, e o que caiu

**`sqflite` com SQL à mão, e não `drift` (2.34.3 · 2026-07-27).**
Drift é maduro, tipado e tem ajuda de migração — e adiciona `build_runner`,
código gerado no repositório e um passo de geração antes de rodar. O outbox tem
duas tabelas. Pelo critério 1, o passo extra custa mais do que a tipagem
economiza. Drift volta à mesa se o schema crescer além de três tabelas ou se as
migrações começarem a doer.

**`Hive` (2.2.3) e `Isar` (3.1.0+1) descartados por manutenção.**
Último release de Hive em **2022-06-30**; de Isar em **2023-04-25** — três e
quatro anos sem publicação. Além disso Hive não oferece transação de verdade,
que aqui é requisito. Isto é medição de data, não opinião sobre a comunidade.

**`sembast` (3.8.9+1 · 2026-06-26) descartado por adequação.**
Está vivo e é bom, mas é NoSQL sobre arquivo. Ordem e transação sobre uma fila
saem com menos código em SQL.

**Nenhum framework de mock, e `mocktail` (1.0.5) descartado.**
O servidor falso e o transporte com falha injetada são implementações reais e
determinísticas, não dublês. Mock aqui esconderia justamente o que precisa ser
observável: quantas vezes o efeito foi aplicado.

**`glados` (1.1.7) descartado pela mesma régua que matou Hive e Isar.**
É a única biblioteca de teste baseado em propriedade com tração em Dart, e a
pergunta "por que não property-based testing num projeto que injeta falha por
seed?" é a primeira que um revisor faz. Último release em **2023-12-04** — dois
anos e oito meses. A regra que descartou Hive por data descarta esta também, e
regra que se aplica só quando é conveniente não é regra.

O que se perde é o **shrinking**: reduzir automaticamente uma sequência que
reprovou até o menor caso que ainda reprova. Isso não é opcional — sem ele, uma
falha de soak com 25 operações é um relatório ilegível. Mas o roteiro de falha
aqui já é uma lista determinística indexada por seed, e encurtar uma lista até
ela parar de reprovar é busca binária: dezenas de linhas, sem dependência, e
**dentro** do vocabulário do domínio (operação, falha, janela) em vez do
vocabulário genérico de um gerador. Escrever ganha do que existe, e é raro isso
ser verdade.

**Nenhum plugin de background.**
Existem plugins que embrulham WorkManager e BGTaskScheduler. Usá-los esvaziaria
a camada 3, que existe para demonstrar escrita de módulo nativo por platform
channel. É uma escolha de propósito, não de engenharia — e está registrada como
tal para ninguém "otimizar" depois.

## Sem contêiner, sem CI no primeiro dia

Contêiner não resolve problema real aqui: runtime e gerenciador de dependências
bastam, e a suíte não tem dependência nativa fora do SQLite, que
`sqflite_common_ffi` resolve.

CI entra quando houver colaboração ou quando o repositório for público — não
antes, e a decisão é do dono.

## O que reconfirmar antes do bootstrap

- versão estável corrente de Dart e Flutter, e se 3.13/3.47 continuam suportadas;
- versão e status de manutenção de `sqflite`, `sqflite_common_ffi`,
  `path_provider` e `test`;
- APIs de `androidx.work` e `BGTaskScheduler` vigentes nas versões de SO que o
  app exemplo vai declarar como mínimo.
