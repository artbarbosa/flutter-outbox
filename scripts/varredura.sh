#!/usr/bin/env bash
#
# Varredura de confidencialidade sobre o HISTÓRICO INTEIRO.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ESTE ARQUIVO NUNCA PODE CONTER UM TERMO PROIBIDO.                       │
# │                                                                          │
# │  Nem em exemplo, nem em comentário, nem em valor padrão. Um script que    │
# │  carrega o nome do empregador dentro publica exatamente o que a varredura │
# │  existe para impedir — e no lugar mais fácil de achar, porque quem audita │
# │  um repositório lê os scripts primeiro. A lista mora FORA, e este arquivo │
# │  só sabe o caminho dela.                                                  │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Uso:
#   scripts/varredura.sh [caminho-da-lista]
#
# A lista tem uma expressão por linha, sem comentários — `grep -f` trata `#`
# como padrão literal, não como comentário.
set -euo pipefail

LISTA="${1:-$HOME/.config/termos-proibidos.txt}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$LISTA" ]; then
  echo "✗ lista não encontrada: $LISTA" >&2
  echo "  Sem lista, a varredura não é limpa: ela é inexistente." >&2
  exit 2
fi

# Conta linhas com conteúdo de verdade. Este é o ponto do script inteiro: com
# uma lista vazia, o BSD grep casa TUDO e o GNU grep casa NADA — e a segunda
# resposta parece "limpo". Recusar é a única leitura que não engana em nenhuma
# das duas plataformas.
TERMOS="$(grep -cve '^[[:space:]]*$' "$LISTA" || true)"
if [ "$TERMOS" -eq 0 ]; then
  echo "✗ a lista está vazia: $LISTA" >&2
  echo "  Marcar a linha da porta de publicação agora seria pior do que não" >&2
  echo "  ter a linha. PROJECT.md explica o que vai aqui dentro." >&2
  exit 2
fi

echo "Varrendo o histórico inteiro de $REPO contra $TERMOS termo(s)…"

# `--all -p` porque a exigência é sobre o histórico inteiro: um termo apagado
# num commit posterior continua vivo no objeto anterior, e `git log -p` de um
# branch só não o encontra.
#
# `-F` trata os termos como literais: sem ele, um `.` num domínio vira "qualquer
# caractere" e a saída enche de falso positivo.
if ACHADOS="$(git -C "$REPO" log --all -p | grep -i -F -f "$LISTA" || true)" \
   && [ -n "$ACHADOS" ]; then
  echo "✗ ACHOU. O conserto não é um commit novo:" >&2
  echo "  reescreva o histórico, ou nasça de novo com histórico limpo." >&2
  echo >&2
  # Só a contagem: imprimir as linhas jogaria os termos no terminal, no
  # histórico do shell e em qualquer log de CI.
  echo "  ocorrências: $(printf '%s\n' "$ACHADOS" | wc -l | tr -d ' ')" >&2
  echo "  Para ver onde, rode o grep à mão — e não em CI." >&2
  exit 1
fi

echo "✓ limpo contra $TERMOS termo(s), em $(git -C "$REPO" rev-list --all --count) commits."
echo "  Registre no PROJECT.md QUE passou e QUANDO — nunca contra o quê."
