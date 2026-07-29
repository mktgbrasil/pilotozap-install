#!/usr/bin/env bash
# ==============================================================================
#  PilotoZap — Esqueci minha senha do painel
# ==============================================================================
#
#  Apaga APENAS o login e a senha do painel, para você criar um novo.
#
#  POR QUE ISSO EXISTE: o PilotoZap roda dentro do SEU servidor, sem e-mail
#  configurado — então não há como mandar um "link de recuperação". A saída é
#  apagar o acesso atual e cadastrar outro na próxima vez que abrir o painel.
#
#  NADA MAIS É APAGADO. Seus atendimentos, contatos, respostas da inteligência
#  artificial, áudios, agendamentos e a conexão do WhatsApp continuam iguais.
#  A licença também continua valendo.
#
#  Como usar (dentro do servidor):
#      bash /opt/pilotozap/resetar-senha.sh
# ==============================================================================

set -uo pipefail

# Descobre onde o PilotoZap está instalado a partir da pasta deste script,
# para funcionar mesmo em instalação fora do caminho padrão.
DIR_DO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PZ_DIR_BASE:-}" ]]; then
  DIR_BASE="$PZ_DIR_BASE"
elif [[ -f "$DIR_DO_SCRIPT/docker-compose.yml" ]]; then
  DIR_BASE="$DIR_DO_SCRIPT"
else
  DIR_BASE="/opt/pilotozap"
fi

SERVICO="${PZ_SERVICO:-pilotozap}"
ARQUIVO="$DIR_BASE/dados/userdata/credenciais.json"

VERDE=$'\033[0;32m'; AMARELO=$'\033[0;33m'; VERMELHO=$'\033[0;31m'
NEGRITO=$'\033[1m'; FIM=$'\033[0m'

echo
echo "${NEGRITO}PilotoZap — criar um novo login e senha${FIM}"
echo "------------------------------------------------------------"

if [[ ! -f "$DIR_BASE/docker-compose.yml" ]]; then
  echo "${VERMELHO}Não encontrei a instalação do PilotoZap em: $DIR_BASE${FIM}"
  echo
  echo "  Confira se o caminho está certo: ${NEGRITO}ls $DIR_BASE${FIM}"
  echo "  Se instalou em outro lugar, rode:"
  echo "    ${NEGRITO}PZ_DIR_BASE=/caminho/da/instalacao bash resetar-senha.sh${FIM}"
  exit 1
fi

if [[ ! -f "$ARQUIVO" ]]; then
  echo "${AMARELO}Não há login cadastrado ainda.${FIM}"
  echo
  echo "  Isso quer dizer que o painel já vai te pedir para criar um."
  echo "  Abra o painel e faça o cadastro normalmente."
  exit 0
fi

USUARIO_ATUAL=$(grep -o '"usuario"[^,]*' "$ARQUIVO" 2>/dev/null | cut -d'"' -f4)
echo "  Login cadastrado hoje: ${NEGRITO}${USUARIO_ATUAL:-(não identificado)}${FIM}"
echo
echo "  Vou apagar esse acesso para você criar outro."
echo "  ${VERDE}Seus dados NÃO serão apagados${FIM} — atendimentos, contatos,"
echo "  conexão do WhatsApp e licença continuam do jeito que estão."
echo

read -r -p "  Deseja continuar? (digite ${NEGRITO}sim${FIM} para confirmar): " RESPOSTA
if [[ "${RESPOSTA,,}" != "sim" ]]; then
  echo
  echo "  Cancelado. Nada foi alterado."
  exit 0
fi

# Guarda uma cópia antes de apagar: se a pessoa lembrar a senha depois,
# dá para voltar atrás sem ter perdido nada.
COPIA="$ARQUIVO.anterior-$(date +%Y%m%d-%H%M%S)"
if ! cp "$ARQUIVO" "$COPIA" 2>/dev/null; then
  echo "${VERMELHO}Não consegui guardar uma cópia de segurança. Nada foi alterado.${FIM}"
  echo "  Rode este comando como administrador (root) e tente de novo."
  exit 1
fi

rm -f "$ARQUIVO"

echo
echo "  Reiniciando o PilotoZap..."
if ! (cd "$DIR_BASE" && docker compose restart >/dev/null 2>&1); then
  echo "${AMARELO}  O PilotoZap não reiniciou sozinho.${FIM}"
  echo "  Rode à mão: ${NEGRITO}cd $DIR_BASE && docker compose restart${FIM}"
fi

echo
echo "${VERDE}${NEGRITO}  Pronto!${FIM}"
echo
echo "  Agora abra o painel no navegador. Ele vai pedir para você"
echo "  ${NEGRITO}criar um novo login e uma nova senha${FIM}."
echo
echo "  Lembre-se de abrir o túnel antes, no SEU computador:"
echo "    ${NEGRITO}Ver o comando em: cat $DIR_BASE/COMO-ACESSAR.txt${FIM}"
echo
echo "  (A cópia do acesso antigo ficou guardada em:"
echo "   $COPIA)"
echo
