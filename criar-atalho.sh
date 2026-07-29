#!/usr/bin/env bash
# ==============================================================================
#  PilotoZap — cria o atalho de acesso para o computador do cliente
# ==============================================================================
#
#  Gera um pacote (.zip) que o cliente coloca no computador dele. Depois disso
#  ele abre o painel com DOIS CLIQUES, sem digitar comando nenhum.
#
#  O QUE ESTE SCRIPT MONTA:
#    1. Uma chave de acesso exclusiva para abrir o painel
#    2. Um atalho (PilotoZap.bat) que usa essa chave e abre o navegador sozinho
#    3. Um LEIA-ME curto explicando o que fazer com os arquivos
#
#  SOBRE A SEGURANÇA DA CHAVE: ela é travada no servidor para servir APENAS
#  como passagem até a porta do painel. Não abre terminal, não roda comando,
#  não acessa arquivo. Se ela vazar, o máximo que fazem é chegar na tela de
#  login do painel — que continua exigindo usuário e senha.
#
#  Uso:  bash /opt/pilotozap/criar-atalho.sh
# ==============================================================================

set -uo pipefail

DIR_DO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PZ_DIR_BASE:-}" ]]; then
  DIR_BASE="$PZ_DIR_BASE"
elif [[ -f "$DIR_DO_SCRIPT/docker-compose.yml" ]]; then
  DIR_BASE="$DIR_DO_SCRIPT"
else
  DIR_BASE="/opt/pilotozap"
fi

PORTA="${PZ_PORTA:-3110}"
# Se o compose já existe, a porta real vem dele (evita gerar atalho com a porta errada)
if [[ -f "$DIR_BASE/docker-compose.yml" ]]; then
  PORTA_DETECTADA=$(grep -oE '127\.0\.0\.1:[0-9]+' "$DIR_BASE/docker-compose.yml" | head -1 | cut -d: -f2)
  [[ -n "$PORTA_DETECTADA" ]] && PORTA="$PORTA_DETECTADA"
fi

DIR_ACESSO="$DIR_BASE/acesso"
NOME_CHAVE="chave-do-painel"
CHAVE="$DIR_ACESSO/$NOME_CHAVE"
USUARIO_SSH="${PZ_USUARIO_SSH:-root}"

VERDE=$'\033[0;32m'; AMARELO=$'\033[0;33m'; VERMELHO=$'\033[0;31m'
NEGRITO=$'\033[1m'; FIM=$'\033[0m'

# IP público do servidor
IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
[[ -z "$IP" ]] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$IP" ]]; then
  echo "${VERMELHO}Não consegui descobrir o IP deste servidor.${FIM}"
  echo "  Rode informando o IP: ${NEGRITO}PZ_IP=SEU.IP.AQUI bash criar-atalho.sh${FIM}"
  exit 1
fi
IP="${PZ_IP:-$IP}"

echo
echo "${NEGRITO}Criando o atalho de acesso ao painel${FIM}"
echo "------------------------------------------------------------"
echo "  Servidor: $IP    Porta: $PORTA"
echo

mkdir -p "$DIR_ACESSO"
chmod 700 "$DIR_ACESSO"

# ── 1. Chave exclusiva para o túnel ──
if [[ -f "$CHAVE" ]]; then
  echo "  Reaproveitando a chave que já existe."
else
  if ! ssh-keygen -t ed25519 -N "" -C "pilotozap-painel" -f "$CHAVE" >/dev/null 2>&1; then
    echo "${VERMELHO}Não consegui gerar a chave de acesso.${FIM}"
    echo "  Verifique se o ssh-keygen está instalado: ${NEGRITO}apt install -y openssh-client${FIM}"
    exit 1
  fi
  echo "  ${VERDE}Chave de acesso criada.${FIM}"
fi

# ── 2. Autoriza a chave, TRAVADA para só encaminhar a porta do painel ──
# `restrict` desliga tudo (terminal, execução de comando, encaminhamento de
# agente e de X11). Depois reabilitamos SOMENTE o encaminhamento de porta, e
# `permitopen` limita a passagem exclusivamente à porta do painel.
DIR_SSH="/root/.ssh"
[[ "$USUARIO_SSH" != "root" ]] && DIR_SSH="/home/$USUARIO_SSH/.ssh"
mkdir -p "$DIR_SSH" && chmod 700 "$DIR_SSH"
AUTORIZADAS="$DIR_SSH/authorized_keys"
touch "$AUTORIZADAS" && chmod 600 "$AUTORIZADAS"

PUBLICA=$(cat "$CHAVE.pub")
LINHA="restrict,port-forwarding,permitopen=\"127.0.0.1:$PORTA\" $PUBLICA"

# Remove autorização antiga desta mesma chave antes de regravar (idempotente)
if grep -q "pilotozap-painel" "$AUTORIZADAS" 2>/dev/null; then
  grep -v "pilotozap-painel" "$AUTORIZADAS" > "$AUTORIZADAS.tmp" && mv "$AUTORIZADAS.tmp" "$AUTORIZADAS"
  chmod 600 "$AUTORIZADAS"
fi
echo "$LINHA" >> "$AUTORIZADAS"
echo "  ${VERDE}Chave autorizada no servidor (apenas para abrir o painel).${FIM}"

# ── 3. O atalho do Windows ──
# A janela do SSH fica aberta de propósito: fechá-la encerra a conexão. É a
# forma mais simples de o cliente entender que "fechou a janela, desconectou".
cat > "$DIR_ACESSO/PilotoZap.bat" <<BAT
@echo off
title PilotoZap - conexao com o painel
cd /d "%~dp0"

echo.
echo   Conectando ao seu servidor...
echo.

REM Abre o navegador alguns segundos depois, ja com a conexao de pe
start /b "" cmd /c "timeout /t 5 >nul & start \"\" http://localhost:$PORTA"

echo   O painel vai abrir sozinho no navegador.
echo.
echo   MANTENHA ESTA JANELA ABERTA enquanto estiver usando o painel.
echo   Para desconectar, e so fechar esta janela.
echo.

ssh -i "$NOME_CHAVE" -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -N -L $PORTA:127.0.0.1:$PORTA $USUARIO_SSH@$IP

echo.
echo   Conexao encerrada. Pode fechar esta janela.
pause >nul
BAT

# ── 4. Versão para Mac e Linux ──
cat > "$DIR_ACESSO/PilotoZap.command" <<CMD
#!/bin/bash
cd "\$(dirname "\$0")"
chmod 600 "$NOME_CHAVE" 2>/dev/null
echo ""
echo "  Conectando ao seu servidor..."
echo "  O painel vai abrir sozinho no navegador."
echo "  MANTENHA ESTA JANELA ABERTA enquanto usar o painel."
echo ""
( sleep 5 && (open http://localhost:$PORTA 2>/dev/null || xdg-open http://localhost:$PORTA 2>/dev/null) ) &
ssh -i "$NOME_CHAVE" -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -N -L $PORTA:127.0.0.1:$PORTA $USUARIO_SSH@$IP
echo ""
echo "  Conexao encerrada."
CMD
chmod +x "$DIR_ACESSO/PilotoZap.command"

# ── 5. Instruções para o cliente ──
cat > "$DIR_ACESSO/LEIA-ME.txt" <<LEIA
COMO ABRIR O SEU PAINEL DO PILOTOZAP
=====================================

1. Coloque ESTA PASTA INTEIRA em algum lugar do seu computador.
   Sugestao: Documentos. Nao separe os arquivos, eles trabalham juntos.

2. NO WINDOWS: clique duas vezes em  PilotoZap.bat
   NO MAC:      clique duas vezes em  PilotoZap.command

3. Vai abrir uma janela preta e, em seguida, o painel no navegador.

4. IMPORTANTE: deixe a janela preta aberta enquanto estiver usando.
   Ela e a conexao com o seu servidor. Fechou a janela, fechou o painel.
   (Seu robo continua atendendo normalmente, mesmo com o painel fechado.)

QUER UM ATALHO NA AREA DE TRABALHO?
   Clique com o botao DIREITO em PilotoZap.bat  ->  Enviar para
   ->  Area de trabalho (criar atalho)

SE NAO ABRIR
   - Espere 10 segundos: a primeira conexao costuma demorar um pouco.
   - Se pedir senha, os arquivos foram separados. Coloque todos de volta
     na mesma pasta.
   - Se aparecer erro de conexao, confira sua internet e tente de novo.
   - Persistindo, chame o suporte e mande uma foto da janela preta.

SOBRE O ARQUIVO "$NOME_CHAVE"
   E a sua chave de acesso. Nao compartilhe e nao apague.
   Ela serve SOMENTE para abrir o painel: nao da acesso a mais nada
   no servidor.
LEIA

# ── 6. Empacota ──
PACOTE="$DIR_ACESSO/PilotoZap-atalho.zip"
rm -f "$PACOTE"
if command -v zip >/dev/null 2>&1; then
  (cd "$DIR_ACESSO" && zip -q "$PACOTE" "$NOME_CHAVE" "PilotoZap.bat" "PilotoZap.command" "LEIA-ME.txt")
else
  apt-get install -y -qq zip >/dev/null 2>&1 && \
    (cd "$DIR_ACESSO" && zip -q "$PACOTE" "$NOME_CHAVE" "PilotoZap.bat" "PilotoZap.command" "LEIA-ME.txt")
fi

echo
if [[ -f "$PACOTE" ]]; then
  echo "${VERDE}${NEGRITO}  Pronto!${FIM}"
  echo
  echo "  Pacote do cliente: ${NEGRITO}$PACOTE${FIM}"
  echo
  echo "  Baixe para o seu computador com este comando"
  echo "  (rode no SEU computador, nao aqui no servidor):"
  echo
  echo "    ${NEGRITO}scp $USUARIO_SSH@$IP:$PACOTE .${FIM}"
  echo
  echo "  Depois e so mandar o arquivo para o cliente. Ele extrai numa"
  echo "  pasta e abre o painel com dois cliques, sem digitar comando."
else
  echo "${AMARELO}  Não consegui criar o .zip, mas os arquivos estão prontos em:${FIM}"
  echo "    $DIR_ACESSO"
fi
echo
