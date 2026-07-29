#!/usr/bin/env bash
# ==============================================================================
#  PilotoZap — Backup automático
# ==============================================================================
#  O QUE ESTE SCRIPT SALVA
#    1. O banco de dados (conversas, leads, agendamentos, licença)
#    2. A pasta de dados do WhatsApp (a sessão conectada e as mídias)
#
#  COMO ELE SALVA COM SEGURANÇA
#    Usa o comando "VACUUM INTO" do SQLite, que gera uma cópia íntegra do banco
#    MESMO COM O SISTEMA NO AR. Copiar o arquivo dev.db "na mão" enquanto o
#    programa roda pode gerar um backup corrompido, porque parte dos dados ainda
#    está no arquivo dev.db-wal. O VACUUM INTO resolve isso.
#
#  QUANDO ELE RODA
#    Todo dia às 03:20 (agendado pelo instalador em /etc/cron.d/pilotozap-backup)
#
#  QUANTOS BACKUPS FICAM GUARDADOS
#    7 diários  (a última semana, dia a dia)
#    4 semanais (o último mês, semana a semana)
#
#  USO MANUAL
#    bash backup.sh                 -> faz um backup agora
#    bash backup.sh --listar        -> mostra os backups existentes
#    bash backup.sh --restaurar ARQUIVO   -> restaura um backup (com confirmação)
# ==============================================================================

set -euo pipefail

# Onde o PilotoZap está instalado.
#
# A ordem importa. Antes, o padrão era só "/opt/pilotozap", e quem instalasse em
# outra pasta via `--diretorio` recebia do próprio instalador o comando
# "bash /caminho/backup.sh" — que falhava, porque o script procurava no lugar
# errado. Agora ele descobre sozinho: usa a pasta onde o PRÓPRIO script está,
# que é sempre a raiz da instalação. A variável de ambiente continua tendo
# prioridade (é o que o cron usa) e o /opt/pilotozap continua como último caso.
DIR_DO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PZ_DIR_BASE:-}" ]]; then
  DIR_BASE="$PZ_DIR_BASE"
elif [[ -f "$DIR_DO_SCRIPT/docker-compose.yml" ]]; then
  DIR_BASE="$DIR_DO_SCRIPT"
else
  DIR_BASE="/opt/pilotozap"
fi
NOME_SERVICO="${PZ_SERVICO:-pilotozap}"
DIR_DIARIOS="$DIR_BASE/backups/diarios"
DIR_SEMANAIS="$DIR_BASE/backups/semanais"
MANTER_DIARIOS=7
MANTER_SEMANAIS=4
SALVAR_USERDATA="${PZ_BACKUP_USERDATA:-1}"

CARIMBO="$(date '+%Y-%m-%d_%H%M')"
DB_HOST="$DIR_BASE/dados/prisma/dev.db"
USERDATA_HOST="$DIR_BASE/dados/userdata"

if [[ -t 1 ]]; then
  C_VERDE=$'\033[0;32m'; C_AMARELO=$'\033[0;33m'; C_VERMELHO=$'\033[0;31m'
  C_NEGRITO=$'\033[1m'; C_FIM=$'\033[0m'
else
  C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_NEGRITO=""; C_FIM=""
fi

registrar() { echo "[$(date '+%d/%m/%Y %H:%M:%S')] $*"; }
ok()        { echo "[$(date '+%d/%m/%Y %H:%M:%S')] ${C_VERDE}OK${C_FIM}    — $*"; }
aviso()     { echo "[$(date '+%d/%m/%Y %H:%M:%S')] ${C_AMARELO}AVISO${C_FIM} — $*"; }
falhar() {
  echo "[$(date '+%d/%m/%Y %H:%M:%S')] ${C_VERMELHO}ERRO${C_FIM}  — $1" >&2
  shift
  [[ $# -gt 0 ]] && { echo "" >&2; echo "O que fazer:" >&2; for l in "$@"; do echo "  • $l" >&2; done; }
  exit 1
}

container_rodando() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NOME_SERVICO"
}

# ──────────────────────────────────────────────────────────────────────────────
# Fazer o backup
# ──────────────────────────────────────────────────────────────────────────────
fazer_backup() {
  mkdir -p "$DIR_DIARIOS" "$DIR_SEMANAIS"

  [[ -f "$DB_HOST" ]] || falhar "Não encontrei o banco de dados em $DB_HOST." \
    "Confira se o PilotoZap está instalado nesta pasta: ${C_NEGRITO}ls $DIR_BASE${C_FIM}" \
    "Se instalou em outro lugar, rode: ${C_NEGRITO}PZ_DIR_BASE=/caminho/da/instalacao bash backup.sh${C_FIM}"

  local destino_db="$DIR_DIARIOS/banco_${CARIMBO}.db"
  local temporario_container="/app/prisma/.backup-em-andamento.db"
  local temporario_host="$DIR_BASE/dados/prisma/.backup-em-andamento.db"

  rm -f "$temporario_host"

  registrar "Copiando o banco de dados com segurança (VACUUM INTO)..."
  if container_rodando; then
    # Caminho preferido: o sqlite3 de dentro do container, com o sistema no ar.
    if ! docker exec "$NOME_SERVICO" sqlite3 "/app/prisma/dev.db" \
           "VACUUM INTO '${temporario_container}';" 2>/dev/null; then
      aviso "O VACUUM INTO pelo container falhou. Tentando pelo próprio servidor..."
      backup_pelo_host "$temporario_host"
    fi
  else
    aviso "O PilotoZap não está rodando agora — fazendo o backup direto do arquivo."
    backup_pelo_host "$temporario_host"
  fi

  [[ -f "$temporario_host" ]] || falhar "A cópia do banco não foi criada." \
    "Verifique se o container está de pé: ${C_NEGRITO}cd $DIR_BASE && docker compose ps${C_FIM}" \
    "Veja os registros: ${C_NEGRITO}cd $DIR_BASE && docker compose logs --tail 30${C_FIM}"

  # Confere se a cópia está íntegra antes de considerá-la um backup válido
  registrar "Conferindo a integridade da cópia..."
  local resultado="desconhecido"
  if command -v sqlite3 >/dev/null 2>&1; then
    resultado="$(sqlite3 "$temporario_host" "PRAGMA integrity_check;" 2>/dev/null | head -1 || echo erro)"
  elif container_rodando; then
    resultado="$(docker exec "$NOME_SERVICO" sqlite3 "$temporario_container" "PRAGMA integrity_check;" 2>/dev/null | head -1 || echo erro)"
  fi

  if [[ "$resultado" != "ok" && "$resultado" != "desconhecido" ]]; then
    rm -f "$temporario_host"
    falhar "A cópia do banco saiu corrompida (resultado: $resultado). Backup NÃO foi salvo." \
      "Isso pode indicar problema no disco da VPS ou banco danificado." \
      "Rode de novo: ${C_NEGRITO}bash $DIR_BASE/backup.sh${C_FIM}" \
      "Se repetir, acione o suporte com esta mensagem — NÃO apague os backups antigos."
  fi

  mv "$temporario_host" "$destino_db"
  gzip -f "$destino_db"
  destino_db="${destino_db}.gz"
  ok "Banco de dados salvo: $(basename "$destino_db") ($(du -h "$destino_db" | cut -f1))"

  # ── Pasta de dados do WhatsApp ──────────────────────────────────────────────
  if [[ "$SALVAR_USERDATA" == "1" && -d "$USERDATA_HOST" ]]; then
    registrar "Salvando a sessão do WhatsApp e as mídias..."
    local destino_userdata="$DIR_DIARIOS/whatsapp_${CARIMBO}.tar.gz"
    if tar -czf "$destino_userdata" -C "$DIR_BASE/dados" userdata 2>/dev/null; then
      ok "Sessão do WhatsApp salva: $(basename "$destino_userdata") ($(du -h "$destino_userdata" | cut -f1))"
    else
      aviso "Não consegui salvar a pasta do WhatsApp. O banco de dados FOI salvo normalmente."
      rm -f "$destino_userdata"
    fi
  fi

  promover_semanal
  limpar_antigos
  resumo
}

# Backup feito a partir do próprio servidor (plano B).
backup_pelo_host() {
  local saida="$1"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB_HOST" "VACUUM INTO '${saida}';" || \
      falhar "O VACUUM INTO falhou também pelo servidor." \
        "Instale o sqlite3 no servidor: ${C_NEGRITO}apt-get install -y sqlite3${C_FIM}" \
        "Depois rode de novo: ${C_NEGRITO}bash $DIR_BASE/backup.sh${C_FIM}"
  else
    # Último recurso: cópia bruta. Só é segura com o programa parado.
    aviso "O programa 'sqlite3' não está instalado no servidor — fazendo cópia simples."
    aviso "Para backups mais seguros instale: apt-get install -y sqlite3"
    cp -f "$DB_HOST" "$saida"
    [[ -f "${DB_HOST}-wal" ]] && cp -f "${DB_HOST}-wal" "${saida}-wal" || true
  fi
}

# Uma vez por semana (domingo, ou se faltar o backup semanal), promove o
# backup do dia para a pasta dos semanais.
promover_semanal() {
  local precisa=0
  [[ "$(date '+%u')" == "7" ]] && precisa=1 || true
  if [[ -z "$(find "$DIR_SEMANAIS" -name 'banco_*.db.gz' -mtime -7 2>/dev/null)" ]]; then
    precisa=1
  fi
  [[ $precisa -eq 1 ]] || return 0

  local ultimo
  ultimo="$(find "$DIR_DIARIOS" -name 'banco_*.db.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [[ -n "$ultimo" ]] || return 0

  cp -f "$ultimo" "$DIR_SEMANAIS/"
  local userdata_semana="$DIR_DIARIOS/whatsapp_${CARIMBO}.tar.gz"
  [[ -f "$userdata_semana" ]] && cp -f "$userdata_semana" "$DIR_SEMANAIS/" || true
  ok "Cópia semanal criada: $(basename "$ultimo")"
}

limpar_antigos() {
  apagar_excedentes() {
    local pasta="$1" padrao="$2" manter="$3" arquivo
    # shellcheck disable=SC2012
    find "$pasta" -maxdepth 1 -name "$padrao" -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n +$((manter + 1)) | cut -d' ' -f2- \
      | while IFS= read -r arquivo; do
          [[ -n "$arquivo" ]] || continue
          rm -f "$arquivo"
          registrar "Backup antigo removido: $(basename "$arquivo")"
        done
  }

  apagar_excedentes "$DIR_DIARIOS"  'banco_*.db.gz'      "$MANTER_DIARIOS"
  apagar_excedentes "$DIR_DIARIOS"  'whatsapp_*.tar.gz'  "$MANTER_DIARIOS"
  apagar_excedentes "$DIR_SEMANAIS" 'banco_*.db.gz'      "$MANTER_SEMANAIS"
  apagar_excedentes "$DIR_SEMANAIS" 'whatsapp_*.tar.gz'  "$MANTER_SEMANAIS"
}

resumo() {
  local qtd_d qtd_s tamanho
  qtd_d="$(find "$DIR_DIARIOS"  -name 'banco_*.db.gz' 2>/dev/null | wc -l)"
  qtd_s="$(find "$DIR_SEMANAIS" -name 'banco_*.db.gz' 2>/dev/null | wc -l)"
  tamanho="$(du -sh "$DIR_BASE/backups" 2>/dev/null | cut -f1)"
  ok "Backup concluído. Guardados: $qtd_d diário(s) e $qtd_s semanal(is), ocupando $tamanho."
}

# ──────────────────────────────────────────────────────────────────────────────
# Listar
# ──────────────────────────────────────────────────────────────────────────────
listar() {
  echo
  echo "${C_NEGRITO}BACKUPS DIÁRIOS (últimos 7 dias)${C_FIM} — $DIR_DIARIOS"
  ls -lh "$DIR_DIARIOS" 2>/dev/null | grep -E 'banco_|whatsapp_' || echo "  (nenhum ainda)"
  echo
  echo "${C_NEGRITO}BACKUPS SEMANAIS (últimas 4 semanas)${C_FIM} — $DIR_SEMANAIS"
  ls -lh "$DIR_SEMANAIS" 2>/dev/null | grep -E 'banco_|whatsapp_' || echo "  (nenhum ainda)"
  echo
  echo "Para restaurar um deles:"
  echo "  ${C_NEGRITO}bash $DIR_BASE/backup.sh --restaurar $DIR_DIARIOS/banco_ANO-MES-DIA_HORA.db.gz${C_FIM}"
  echo
}

# ──────────────────────────────────────────────────────────────────────────────
# Restaurar
# ──────────────────────────────────────────────────────────────────────────────
restaurar() {
  local arquivo="${1:-}"
  [[ -n "$arquivo" ]] || falhar "Você precisa dizer QUAL backup quer restaurar." \
    "Veja a lista com: ${C_NEGRITO}bash $DIR_BASE/backup.sh --listar${C_FIM}" \
    "Depois rode: ${C_NEGRITO}bash $DIR_BASE/backup.sh --restaurar CAMINHO_DO_ARQUIVO${C_FIM}"
  [[ -f "$arquivo" ]] || falhar "O arquivo '$arquivo' não existe." \
    "Confira o caminho exato com: ${C_NEGRITO}bash $DIR_BASE/backup.sh --listar${C_FIM}"

  echo
  echo "${C_AMARELO}${C_NEGRITO}ATENÇÃO — RESTAURAÇÃO DE BACKUP${C_FIM}"
  echo
  echo "  Você está prestes a substituir os dados ATUAIS do PilotoZap pelos dados"
  echo "  do backup:"
  echo "     $arquivo"
  echo "     (de $(date -r "$arquivo" '+%d/%m/%Y às %H:%M'))"
  echo
  echo "  Tudo que aconteceu DEPOIS dessa data (conversas, leads, agendamentos)"
  echo "  será perdido. Antes de substituir, vou guardar os dados atuais numa"
  echo "  cópia de emergência — então dá para voltar atrás se você se arrepender."
  echo
  read -r -p "  Digite RESTAURAR (em maiúsculas) para continuar: " confirmacao </dev/tty || true
  [[ "$confirmacao" == "RESTAURAR" ]] || { echo "Cancelado. Nada foi alterado."; exit 0; }

  # Cópia de emergência do estado atual
  local emergencia="$DIR_BASE/backups/antes-da-restauracao_${CARIMBO}"
  mkdir -p "$emergencia"
  [[ -f "$DB_HOST" ]] && cp -f "$DB_HOST" "$emergencia/dev.db" || true
  [[ -d "$USERDATA_HOST" ]] && tar -czf "$emergencia/userdata.tar.gz" -C "$DIR_BASE/dados" userdata 2>/dev/null || true
  ok "Estado atual guardado em: $emergencia"

  registrar "Parando o PilotoZap..."
  (cd "$DIR_BASE" && docker compose stop) >/dev/null 2>&1 || true

  registrar "Restaurando o banco de dados..."
  # Os arquivos -wal e -shm precisam sumir: eles pertencem ao banco antigo.
  rm -f "${DB_HOST}-wal" "${DB_HOST}-shm"
  if [[ "$arquivo" == *.gz ]]; then
    gunzip -c "$arquivo" > "$DB_HOST"
  else
    cp -f "$arquivo" "$DB_HOST"
  fi

  # Se existir um backup da sessão do WhatsApp com o mesmo carimbo de data,
  # oferece restaurá-lo também (sem ele o WhatsApp pede o QR Code de novo).
  local carimbo_arquivo companheiro
  carimbo_arquivo="$(basename "$arquivo" | sed -E 's/^banco_(.*)\.db(\.gz)?$/\1/')"
  companheiro="$(dirname "$arquivo")/whatsapp_${carimbo_arquivo}.tar.gz"
  if [[ -f "$companheiro" ]]; then
    read -r -p "  Restaurar também a sessão do WhatsApp desse mesmo dia? (s/N): " r </dev/tty || true
    if [[ "${r,,}" == "s" || "${r,,}" == "sim" ]]; then
      rm -rf "$USERDATA_HOST"
      tar -xzf "$companheiro" -C "$DIR_BASE/dados"
      ok "Sessão do WhatsApp restaurada."
    fi
  fi

  registrar "Ligando o PilotoZap de novo..."
  (cd "$DIR_BASE" && docker compose up -d) >/dev/null 2>&1 || \
    falhar "Não consegui religar o PilotoZap depois da restauração." \
      "Rode: ${C_NEGRITO}cd $DIR_BASE && docker compose up -d${C_FIM}" \
      "E veja o motivo: ${C_NEGRITO}cd $DIR_BASE && docker compose logs --tail 40${C_FIM}"

  echo
  ok "Restauração concluída."
  echo
  echo "  Abra o painel e confira se os dados estão como você esperava."
  echo "  Se algo deu errado, os dados de antes da restauração estão em:"
  echo "     ${C_NEGRITO}$emergencia${C_FIM}"
  echo "  Para voltar atrás: ${C_NEGRITO}bash $DIR_BASE/backup.sh --restaurar $emergencia/dev.db${C_FIM}"
  echo
  echo "  Observação: se você NÃO restaurou a sessão do WhatsApp, será preciso"
  echo "  reconectar lendo o QR Code no painel."
  echo
}

# ──────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --listar|-l)     listar ;;
  --restaurar|-r)  restaurar "${2:-}" ;;
  --ajuda|-h|--help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  "")              fazer_backup ;;
  *)               falhar "Opção desconhecida: $1" \
                     "Use: bash backup.sh (backup agora), --listar ou --restaurar ARQUIVO" ;;
esac
