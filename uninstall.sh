#!/usr/bin/env bash
# ==============================================================================
#  PilotoZap — Desinstalador
# ==============================================================================
#  Remove o PilotoZap deste servidor de forma limpa e SEGURA:
#
#    - faz um último backup antes de mexer em qualquer coisa;
#    - GUARDA todos os backups em /var/backups/pilotozap (eles NUNCA são
#      apagados por este script);
#    - NÃO desinstala o Docker (outros programas podem depender dele);
#    - não mexe em mais nada do servidor: o PilotoZap só existia dentro de
#      /opt/pilotozap e de um container.
#
#  USO:
#    bash uninstall.sh                  -> remove o programa, guarda os dados
#    bash uninstall.sh --purgar-dados   -> remove também os dados (após backup)
# ==============================================================================

set -euo pipefail

DIR_BASE="${PZ_DIR_BASE:-/opt/pilotozap}"
NOME_SERVICO="${PZ_SERVICO:-pilotozap}"
COFRE="/var/backups/pilotozap"
CARIMBO="$(date '+%Y-%m-%d_%H%M')"

PURGAR_DADOS=0
SEM_PERGUNTAS=0

if [[ -t 1 ]]; then
  C_VERDE=$'\033[0;32m'; C_AMARELO=$'\033[0;33m'; C_VERMELHO=$'\033[0;31m'
  C_NEGRITO=$'\033[1m'; C_FIM=$'\033[0m'
else
  C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_NEGRITO=""; C_FIM=""
fi

info()  { echo "  $*"; }
ok()    { echo "  ${C_VERDE}OK${C_FIM} $*"; }
aviso() { echo "  ${C_AMARELO}!${C_FIM} $*"; }
erro()  { echo "  ${C_VERMELHO}x${C_FIM} $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purgar-dados)    PURGAR_DADOS=1; shift ;;
    --sim|-y)          SEM_PERGUNTAS=1; shift ;;
    --diretorio)       DIR_BASE="${2:-}"; shift 2 ;;
    --ajuda|-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) erro "Opção desconhecida: $1"; echo "  Use: bash uninstall.sh [--purgar-dados]"; exit 1 ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || {
  erro "Este script precisa ser executado como administrador."
  echo "  Rode: ${C_NEGRITO}sudo -i${C_FIM} e depois ${C_NEGRITO}bash uninstall.sh${C_FIM}"
  exit 1
}

[[ -d "$DIR_BASE" ]] || {
  erro "Não encontrei uma instalação do PilotoZap em $DIR_BASE."
  echo "  Se instalou em outro lugar, rode: ${C_NEGRITO}bash uninstall.sh --diretorio /caminho${C_FIM}"
  exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
echo
echo "${C_NEGRITO}╔════════════════════════════════════════════════════════════╗${C_FIM}"
echo "${C_NEGRITO}║          DESINSTALAÇÃO DO PILOTOZAP                        ║${C_FIM}"
echo "${C_NEGRITO}╚════════════════════════════════════════════════════════════╝${C_FIM}"
echo
echo "  O que VAI ser removido:"
echo "    • o programa PilotoZap e seu container"
echo "    • o agendamento do backup automático"
if [[ $PURGAR_DADOS -eq 1 ]]; then
echo "    • ${C_VERMELHO}os dados (banco, conversas, sessão do WhatsApp)${C_FIM}"
fi
echo
echo "  O que NÃO vai ser removido:"
echo "    • ${C_VERDE}seus backups${C_FIM} (movidos para $COFRE)"
if [[ $PURGAR_DADOS -eq 0 ]]; then
echo "    • ${C_VERDE}seus dados atuais${C_FIM} (também guardados em $COFRE)"
fi
echo "    • o Docker (outros programas podem usá-lo)"
echo

if [[ $SEM_PERGUNTAS -eq 0 ]]; then
  read -r -p "  Digite REMOVER (em maiúsculas) para confirmar: " confirmacao </dev/tty || true
  [[ "$confirmacao" == "REMOVER" ]] || { echo; echo "  Cancelado. Nada foi alterado."; echo; exit 0; }
fi
echo

# ── 1. Último backup ──────────────────────────────────────────────────────────
echo "${C_NEGRITO}[1/4] Fazendo um último backup${C_FIM}"
mkdir -p "$COFRE"
if [[ -f "$DIR_BASE/backup.sh" ]]; then
  if PZ_DIR_BASE="$DIR_BASE" bash "$DIR_BASE/backup.sh" >/dev/null 2>&1; then
    ok "Último backup criado."
  else
    aviso "Não consegui rodar o backup automático — vou copiar os arquivos direto."
  fi
fi

# Cópia bruta de segurança (sempre, mesmo que o backup.sh tenha funcionado)
DESTINO_COFRE="$COFRE/desinstalacao_${CARIMBO}"
mkdir -p "$DESTINO_COFRE"
[[ -d "$DIR_BASE/dados" ]] && cp -a "$DIR_BASE/dados" "$DESTINO_COFRE/" 2>/dev/null || true
for arquivo in .env IDENTIDADE-NAO-ALTERAR.txt CODIGO-DA-MAQUINA.txt COMO-ACESSAR.txt docker-compose.yml; do
  [[ -f "$DIR_BASE/$arquivo" ]] && cp -a "$DIR_BASE/$arquivo" "$DESTINO_COFRE/" 2>/dev/null || true
done
chmod -R go-rwx "$DESTINO_COFRE" 2>/dev/null || true
ok "Dados e configurações copiados para $DESTINO_COFRE"

# Move os backups existentes para o cofre
if [[ -d "$DIR_BASE/backups" ]]; then
  mkdir -p "$COFRE/backups"
  cp -a "$DIR_BASE/backups/." "$COFRE/backups/" 2>/dev/null || true
  ok "Backups preservados em $COFRE/backups"
fi

# ── 2. Parar e remover o container ────────────────────────────────────────────
echo
echo "${C_NEGRITO}[2/4] Desligando o PilotoZap${C_FIM}"
if [[ -f "$DIR_BASE/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
  # Atenção: sem "-v" de propósito. O "-v" apagaria volumes de dados.
  (cd "$DIR_BASE" && docker compose down --remove-orphans) >/dev/null 2>&1 || true
  ok "Container parado e removido."
else
  docker rm -f "$NOME_SERVICO" >/dev/null 2>&1 || true
  aviso "Não achei o docker-compose.yml — removi o container diretamente."
fi

# Remove a imagem construída (libera espaço; não afeta outros containers)
if command -v docker >/dev/null 2>&1; then
  docker image rm -f "pilotozap-web:local" >/dev/null 2>&1 || true
  ok "Imagem do programa removida."
fi

# ── 3. Agendamento do backup ──────────────────────────────────────────────────
echo
echo "${C_NEGRITO}[3/4] Removendo o agendamento do backup${C_FIM}"
if [[ -f /etc/cron.d/pilotozap-backup ]]; then
  rm -f /etc/cron.d/pilotozap-backup
  systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1 || true
  ok "Agendamento removido."
else
  info "Nenhum agendamento encontrado."
fi

# ── 4. Pasta da instalação ────────────────────────────────────────────────────
echo
echo "${C_NEGRITO}[4/4] Removendo os arquivos do programa${C_FIM}"
if [[ $PURGAR_DADOS -eq 1 ]]; then
  rm -rf "$DIR_BASE"
  ok "Pasta $DIR_BASE removida por completo (cópia de segurança em $DESTINO_COFRE)."
else
  # Remove só o programa; deixa os dados no lugar caso o cliente reinstale.
  rm -rf "$DIR_BASE/app" "$DIR_BASE/docker-compose.yml"
  ok "Programa removido. Seus dados continuam em $DIR_BASE/dados"
  info "Para apagar tudo depois: ${C_NEGRITO}rm -rf $DIR_BASE${C_FIM}"
fi

# ── Resumo ────────────────────────────────────────────────────────────────────
echo
echo "${C_VERDE}${C_NEGRITO}  PilotoZap removido com sucesso.${C_FIM}"
echo
echo "  Seus backups e dados estão guardados em:"
echo "     ${C_NEGRITO}$COFRE${C_FIM}"
echo
echo "  Para ver o que ficou salvo: ${C_NEGRITO}ls -lh $COFRE${C_FIM}"
echo
echo "  Se um dia quiser reinstalar, rode o comando de instalação de novo"
echo "  (com o seu token) e depois restaure o backup com:"
echo "     ${C_NEGRITO}bash backup.sh --restaurar $COFRE/backups/diarios/banco_....db.gz${C_FIM}"
echo
echo "  Se você deixou algum túnel SSH aberto no seu computador, pode fechá-lo:"
echo "  ele não leva mais a lugar nenhum."
echo
