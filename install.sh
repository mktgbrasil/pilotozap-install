#!/usr/bin/env bash
# ==============================================================================
#  PilotoZap — Instalador para VPS Linux (Ubuntu 22.04 / 24.04)
# ==============================================================================
#  UM COMANDO SÓ, na VPS, como root:
#
#      curl -fsSL https://raw.githubusercontent.com/mktgbrasil/pilotozap/main/install.sh \
#        | bash -s -- --token SEU_TOKEN
#
#  O QUE ELE FAZ
#    1. confere o servidor e instala o Docker se faltar;
#    2. baixa o programa de um release PRIVADO do GitHub usando o seu token;
#    3. sobe o PilotoZap em Docker escutando SÓ em 127.0.0.1:3110
#       (nada fica exposto na internet — sem domínio, sem Nginx, sem SSL);
#    4. mostra o comando de túnel SSH pronto para você abrir o painel no seu PC;
#    5. mostra o código da máquina, que você envia ao vendedor para a licença.
#
#  NÃO gera senha de painel: você mesmo cria seu login e sua senha na primeira
#  vez que abrir o painel, logo depois de ativar a licença.
#
#  É IDEMPOTENTE: rodar de novo não apaga dados, licença nem a conexão do
#  WhatsApp. Só atualiza o programa.
# ==============================================================================

set -euo pipefail

# Constantes e opções
readonly VERSAO_INSTALADOR="2.0.0"

# Repositório privado onde ficam os releases com o pacote do programa.
REPO_RELEASES="${PZ_REPO_RELEASES:-mktgbrasil/pilotozap-releases}"
# De onde vêm os arquivos auxiliares (Dockerfile, entrypoint, compose, backup).
# Repositório PÚBLICO, só com o instalador — o `mktgbrasil/pilotozap` é o
# código-fonte e permanece privado.
URL_BASE="${PZ_URL_BASE:-https://raw.githubusercontent.com/mktgbrasil/pilotozap-install/main}"

DIR_BASE="${PZ_DIR_BASE:-/opt/pilotozap}"
NOME_SERVICO="pilotozap"
NOME_IMAGEM="pilotozap-web:local"
PORTA="${PZ_PORTA:-3110}"
HOSTNAME_FIXO="pilotozap-vps"      # NUNCA mudar depois da licença emitida
USUARIO_CONTAINER="root"           # NUNCA mudar depois da licença emitida
TZ_PADRAO="${PZ_TZ:-America/Sao_Paulo}"

TOKEN="${PZ_TOKEN:-}"
FORCAR=0

# Pasta temporária de trabalho (apagada no fim)
DIR_TMP=""
# Pasta ao lado do install.sh — existe só quando o script foi baixado como
# arquivo. Rodando por "curl | bash" ela fica vazia e os arquivos auxiliares
# são baixados do URL_BASE.
DIR_SCRIPT=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Aparência e mensagens
if [[ -t 1 ]]; then
  C_VERDE=$'\033[0;32m'; C_AMARELO=$'\033[0;33m'; C_VERMELHO=$'\033[0;31m'
  C_AZUL=$'\033[0;36m'; C_NEGRITO=$'\033[1m'; C_FIM=$'\033[0m'
else
  C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_AZUL=""; C_NEGRITO=""; C_FIM=""
fi

info()  { echo "${C_AZUL}[ info ]${C_FIM} $*"; }
ok()    { echo "${C_VERDE}[  ok  ]${C_FIM} $*"; }
aviso() { echo "${C_AMARELO}[aviso ]${C_FIM} $*"; }
erro()  { echo "${C_VERMELHO}[ erro ]${C_FIM} $*" >&2; }

titulo() {
  echo
  echo "${C_NEGRITO}────────────────────────────────────────────────────────────${C_FIM}"
  echo "${C_NEGRITO} $*${C_FIM}"
  echo "${C_NEGRITO}────────────────────────────────────────────────────────────${C_FIM}"
}

limpar_temporarios() {
  [[ -n "$DIR_TMP" && -d "$DIR_TMP" ]] && rm -rf "$DIR_TMP" || true
}

# Encerra explicando O QUE FAZER, não só o que falhou.
abortar() {
  local titulo_msg="$1"; shift
  trap - EXIT
  limpar_temporarios
  echo
  erro "$titulo_msg"
  echo
  echo "${C_NEGRITO}Como resolver:${C_FIM}"
  local linha
  for linha in "$@"; do echo "  • $linha"; done
  echo
  echo "Nada foi perdido. Quando resolver, rode o mesmo comando de instalação de novo."
  echo "Se não souber o que fazer, mande esta tela inteira para quem te vendeu o PilotoZap."
  echo
  exit 1
}

ao_falhar() {
  local codigo=$?
  local linha=${BASH_LINENO[0]:-?}
  [[ $codigo -eq 0 ]] && { limpar_temporarios; return 0; }
  limpar_temporarios
  echo
  erro "A instalação parou de forma inesperada (linha $linha, código $codigo)."
  echo
  echo "O que fazer:"
  echo "  • Rode o mesmo comando de instalação de novo — ele continua de onde parou"
  echo "    e não apaga nada que já estava funcionando."
  echo "  • Se repetir o mesmo erro, copie as ÚLTIMAS 30 LINHAS desta tela e envie ao vendedor."
  echo
}
trap ao_falhar EXIT

# Ajuda e parâmetros
mostrar_ajuda() {
  cat <<AJUDA
PilotoZap — Instalador v${VERSAO_INSTALADOR}

USO (na VPS, como root):
  curl -fsSL ${URL_BASE}/install.sh | bash -s -- --token SEU_TOKEN

OPÇÕES:
  --token TOKEN        Token de acesso que você recebeu na compra (OBRIGATÓRIO)
  --diretorio CAMINHO  Onde instalar (padrão: /opt/pilotozap)
  --porta NUMERO       Porta interna, só no 127.0.0.1 (padrão: 3110)
  --forcar             Continua mesmo com aviso de pouca memória/disco
  --ajuda              Mostra esta ajuda
AJUDA
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)      TOKEN="${2:-}"; shift 2 ;;
    --diretorio)  DIR_BASE="${2:-}"; shift 2 ;;
    --porta)      PORTA="${2:-}"; shift 2 ;;
    --forcar)     FORCAR=1; shift ;;
    --ajuda|-h|--help) mostrar_ajuda; trap - EXIT; exit 0 ;;
    *) erro "Opção desconhecida: $1"; mostrar_ajuda; trap - EXIT; exit 1 ;;
  esac
done

tem_comando() { command -v "$1" >/dev/null 2>&1; }

# Substitui __PLACEHOLDER__ nos templates sem quebrar com "/" ou "&"
substituir() {
  # substituir ORIGEM DESTINO CHAVE=VALOR [CHAVE=VALOR ...]
  local origem="$1" destino="$2"; shift 2
  local conteudo; conteudo="$(cat "$origem")"
  local par chave valor
  for par in "$@"; do
    chave="${par%%=*}"
    valor="${par#*=}"
    conteudo="${conteudo//__${chave}__/$valor}"
  done
  printf '%s\n' "$conteudo" > "$destino"
}

# ETAPA 1 — Conferências antes de mexer em qualquer coisa
verificar_token() {
  if [[ -z "$TOKEN" ]]; then
    abortar "Faltou o token de acesso — sem ele não dá para baixar o programa." \
      "Rode assim, trocando SEU_TOKEN pelo token que você recebeu na compra:" \
      "${C_NEGRITO}curl -fsSL ${URL_BASE}/install.sh | bash -s -- --token SEU_TOKEN${C_FIM}" \
      "Não achou o token? Peça de novo a quem te vendeu o PilotoZap."
  fi
  if [[ ${#TOKEN} -lt 20 ]]; then
    abortar "O token informado parece curto demais para ser válido." \
      "Confira se você colou o token INTEIRO, sem espaços e sem aspas." \
      "Se copiou de um e-mail ou WhatsApp, pode ter faltado um pedaço — copie de novo."
  fi
}

verificar_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    abortar "Este instalador precisa ser executado como administrador (root)." \
      "Entre como root na VPS: ${C_NEGRITO}sudo -i${C_FIM}" \
      "Depois rode o comando de instalação de novo."
  fi
  ok "Executando como administrador (root)."
}

verificar_sistema() {
  if [[ ! -f /etc/os-release ]]; then
    abortar "Não consegui identificar o sistema operacional deste servidor." \
      "Este instalador foi feito para Ubuntu 22.04 ou 24.04." \
      "Peça ao seu provedor de VPS para reinstalar o servidor com Ubuntu 22.04."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ok "Sistema compatível: ${PRETTY_NAME:-$ID}" ;;
    *)
      aviso "Sistema '${PRETTY_NAME:-$ID}' não foi testado (o esperado é Ubuntu 22.04 ou 24.04)."
      if [[ $FORCAR -eq 0 ]]; then
        abortar "Instalação interrompida por incompatibilidade de sistema." \
          "Recomendado: Ubuntu 22.04 LTS ou Ubuntu 24.04 LTS." \
          "Para tentar assim mesmo, acrescente ${C_NEGRITO}--forcar${C_FIM} no fim do comando."
      fi
      ;;
  esac
}

verificar_recursos() {
  local ram_mb disco_gb pai_dir
  ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  pai_dir="$(dirname "$DIR_BASE")"
  [[ -d "$pai_dir" ]] || pai_dir="/"
  disco_gb=$(df -BG --output=avail "$pai_dir" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  [[ -n "$disco_gb" ]] || disco_gb=0

  info "Memória: ${ram_mb} MB | Espaço livre em disco: ${disco_gb} GB"

  if [[ $ram_mb -lt 900 ]]; then
    if [[ $FORCAR -eq 0 ]]; then
      abortar "Este servidor tem pouca memória (${ram_mb} MB). O PilotoZap precisa de pelo menos 1 GB, e o ideal são 2 GB." \
        "Aumente o plano da sua VPS para 2 GB de memória (é a solução mais barata e definitiva)." \
        "Ou crie uma memória de troca (swap) e rode de novo:" \
        "  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" \
        "Para instalar assim mesmo, por sua conta e risco, acrescente ${C_NEGRITO}--forcar${C_FIM}."
    fi
    aviso "Pouca memória (${ram_mb} MB) — continuando por causa do --forcar."
  elif [[ $ram_mb -lt 1800 ]]; then
    aviso "Memória apertada (${ram_mb} MB). Vai funcionar, mas o ideal são 2 GB."
  fi

  if [[ ${disco_gb:-0} -lt 5 ]]; then
    if [[ $FORCAR -eq 0 ]]; then
      abortar "Espaço em disco insuficiente (${disco_gb} GB livres). São necessários pelo menos 5 GB." \
        "Libere espaço com: ${C_NEGRITO}docker system prune -a${C_FIM} (remove imagens antigas do Docker)" \
        "Ou aumente o disco da sua VPS no painel do provedor."
    fi
    aviso "Pouco espaço em disco (${disco_gb} GB) — continuando por causa do --forcar."
  fi
  ok "Recursos do servidor conferidos."
}

verificar_porta() {
  # A porta só é usada em 127.0.0.1, mas ainda assim não pode estar ocupada.
  tem_comando ss || return 0
  if ss -lntH "sport = :$PORTA" 2>/dev/null | grep -q .; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NOME_SERVICO"; then
      ok "Porta $PORTA já é do próprio PilotoZap (reinstalação)."
    else
      abortar "A porta interna $PORTA já está sendo usada por outro programa." \
        "Instale em outra porta acrescentando ${C_NEGRITO}--porta 3111${C_FIM} no fim do comando." \
        "Para ver quem está usando: ${C_NEGRITO}ss -lptn 'sport = :$PORTA'${C_FIM}"
    fi
  fi
}

# ETAPA 2 — Dependências
instalar_basicos() {
  local faltando=()
  tem_comando curl    || faltando+=(curl)
  tem_comando jq      || faltando+=(jq)
  tem_comando ss      || faltando+=(iproute2)
  tem_comando tar     || faltando+=(tar)
  tem_comando gzip    || faltando+=(gzip)
  tem_comando sha256sum || faltando+=(coreutils)
  [[ -d /etc/ssl/certs ]] || faltando+=(ca-certificates)

  if [[ ${#faltando[@]} -gt 0 ]]; then
    info "Instalando ferramentas básicas: ${faltando[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${faltando[@]}" >/dev/null || \
      abortar "Não consegui instalar as ferramentas básicas (${faltando[*]})." \
        "Verifique se o servidor tem internet: ${C_NEGRITO}ping -c2 1.1.1.1${C_FIM}" \
        "Depois rode: ${C_NEGRITO}apt-get update && apt-get install -y ${faltando[*]}${C_FIM} e tente de novo."
  fi
  ok "Ferramentas básicas prontas."
}

instalar_docker() {
  if tem_comando docker && docker compose version >/dev/null 2>&1; then
    ok "Docker já instalado ($(docker --version | cut -d, -f1))."
    return 0
  fi

  titulo "Instalando o Docker"
  info "O Docker é o programa que mantém o PilotoZap rodando de forma isolada."
  info "Isso leva de 1 a 3 minutos..."

  export DEBIAN_FRONTEND=noninteractive
  # shellcheck disable=SC1091
  . /etc/os-release
  local distro="${ID}"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
    -o /etc/apt/keyrings/docker.asc 2>/dev/null || \
    abortar "Não consegui baixar a chave de instalação do Docker." \
      "Verifique a internet do servidor: ${C_NEGRITO}curl -I https://download.docker.com${C_FIM}" \
      "Se estiver tudo certo, instale o Docker seguindo https://docs.docker.com/engine/install/ e rode o instalador de novo."
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null || \
    abortar "A instalação do Docker falhou." \
      "Tente manualmente: ${C_NEGRITO}apt-get install -y docker-ce docker-compose-plugin${C_FIM}" \
      "Se aparecer erro de repositório, rode ${C_NEGRITO}apt-get update${C_FIM} e leia a mensagem." \
      "Depois rode o instalador de novo."

  systemctl enable --now docker >/dev/null 2>&1 || true

  docker compose version >/dev/null 2>&1 || \
    abortar "O Docker foi instalado, mas o complemento 'docker compose' não está funcionando." \
      "Rode: ${C_NEGRITO}apt-get install -y docker-compose-plugin${C_FIM}" \
      "Confira com: ${C_NEGRITO}docker compose version${C_FIM} e rode o instalador de novo."

  ok "Docker instalado e ativo."
}

# ETAPA 3 — Baixar o programa do release PRIVADO do GitHub
# Um asset de release privado NÃO abre por URL de navegador: é preciso usar a
# API, primeiro para descobrir o id do arquivo e depois para baixá-lo.

# Faz a chamada à API e devolve o código HTTP (o corpo vai para o arquivo).
chamar_api() {
  # chamar_api URL ARQUIVO_SAIDA ACCEPT -> ecoa o código HTTP
  local url="$1" saida="$2" accept="$3" codigo=""
  codigo="$(curl -sSL -w '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: ${accept}" \
      -H "User-Agent: pilotozap-installer/${VERSAO_INSTALADOR}" \
      -o "$saida" "$url" 2>/dev/null)" || codigo="000"
  echo "$codigo"
}

# Traduz os erros de token em instruções, não em códigos.
explicar_erro_token() {
  local codigo="$1" contexto="$2"
  case "$codigo" in
    401)
      abortar "Seu token de acesso foi RECUSADO pelo GitHub (${contexto})." \
        "O token está inválido, foi digitado errado ou já expirou." \
        "Fale com quem te vendeu o PilotoZap e peça um token novo." \
        "Ao receber, rode de novo trocando SEU_TOKEN pelo token novo, sem aspas e sem espaços."
      ;;
    403)
      abortar "O GitHub bloqueou o download com este token (${contexto})." \
        "Normalmente isso quer dizer que o token EXPIROU ou perdeu a permissão de leitura." \
        "Fale com quem te vendeu o PilotoZap e peça um token novo." \
        "Se você acabou de tentar várias vezes seguidas, espere 5 minutos e tente uma vez só."
      ;;
    404)
      abortar "Não encontrei o programa do PilotoZap com este token (${contexto})." \
        "Isso acontece quando o token não tem acesso ao repositório do programa — para o GitHub, é como se ele não existisse." \
        "Confira se você colou o token INTEIRO, sem faltar caracteres." \
        "Se estiver certo, peça ao vendedor para liberar o seu token e mande esta mensagem para ele."
      ;;
    000)
      abortar "Não consegui falar com o GitHub (${contexto})." \
        "Teste a internet do servidor: ${C_NEGRITO}curl -I https://api.github.com${C_FIM}" \
        "Se não responder, o firewall da VPS pode estar bloqueando a saída — fale com seu provedor." \
        "Depois rode o instalador de novo."
      ;;
    *)
      abortar "O GitHub respondeu de forma inesperada (código $codigo, ${contexto})." \
        "Espere 2 minutos e rode o instalador de novo." \
        "Se repetir, envie esta tela para quem te vendeu o PilotoZap."
      ;;
  esac
}

baixar_programa() {
  titulo "Baixando o PilotoZap"

  DIR_TMP="$(mktemp -d /tmp/pilotozap-instalacao.XXXXXX)"
  local json="$DIR_TMP/release.json"

  info "Procurando a versão mais recente..."
  local codigo
  codigo="$(chamar_api "https://api.github.com/repos/${REPO_RELEASES}/releases/latest" \
              "$json" "application/vnd.github+json")"
  [[ "$codigo" == "200" ]] || explicar_erro_token "$codigo" "ao procurar a versão"

  local tag id_pacote nome_pacote id_sha
  tag="$(jq -r '.tag_name // "sem-versao"' "$json" 2>/dev/null || echo "sem-versao")"
  id_pacote="$(jq -r '[.assets[]? | select(.name | endswith(".tar.gz"))][0].id // empty' "$json" 2>/dev/null || true)"
  nome_pacote="$(jq -r '[.assets[]? | select(.name | endswith(".tar.gz"))][0].name // empty' "$json" 2>/dev/null || true)"
  id_sha="$(jq -r '[.assets[]? | select(.name | endswith(".sha256"))][0].id // empty' "$json" 2>/dev/null || true)"

  if [[ -z "$id_pacote" ]]; then
    abortar "A versão mais recente do PilotoZap não tem o arquivo do programa (.tar.gz) publicado." \
      "Isso é um problema do lado de quem publicou a versão, não do seu servidor." \
      "Avise quem te vendeu o PilotoZap: 'o release ${tag} está sem o arquivo .tar.gz'."
  fi
  ok "Versão encontrada: ${tag} (${nome_pacote})"

  local pacote="$DIR_TMP/programa.tar.gz"
  info "Baixando ${nome_pacote}... (pode levar 1 a 3 minutos)"
  codigo="$(chamar_api "https://api.github.com/repos/${REPO_RELEASES}/releases/assets/${id_pacote}" \
              "$pacote" "application/octet-stream")"
  [[ "$codigo" == "200" ]] || explicar_erro_token "$codigo" "ao baixar o programa"

  validar_pacote "$pacote" "$id_sha" "$nome_pacote"
  extrair_pacote "$pacote"
  VERSAO_BAIXADA="$tag"
}

# Token errado devolve um JSON de erro em vez do arquivo — e o "tar" reclamaria
# de um jeito que não ajuda ninguém. Por isso conferimos ANTES de extrair.
validar_pacote() {
  local pacote="$1" id_sha="$2" nome_pacote="$3"

  local tamanho magico
  tamanho="$(stat -c '%s' "$pacote" 2>/dev/null || echo 0)"
  magico="$(head -c 2 "$pacote" 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"

  if [[ "$magico" != "1f8b" ]]; then
    # Se o GitHub mandou texto/JSON, mostramos as primeiras linhas: costuma
    # dizer exatamente qual é o problema do token.
    local espiada
    espiada="$(head -c 300 "$pacote" 2>/dev/null | tr -d '\0' || true)"
    echo
    erro "O que foi baixado NÃO é o programa do PilotoZap (${tamanho} bytes)."
    if [[ -n "$espiada" ]]; then
      echo "─────────────── resposta recebida do GitHub ───────────────"
      echo "$espiada"
      echo "───────────────────────────────────────────────────────────"
    fi
    abortar "O download veio inválido — quase sempre é o token de acesso." \
      "Se acima apareceu 'Bad credentials' ou 'Not Found', o seu token está inválido ou expirou." \
      "Fale com quem te vendeu o PilotoZap e peça um token novo." \
      "Se o token é novo e mesmo assim deu isso, mande esta tela para o vendedor."
  fi

  if [[ "$tamanho" -lt 100000 ]]; then
    abortar "O arquivo do programa veio incompleto (só ${tamanho} bytes)." \
      "O download provavelmente foi interrompido pela conexão da VPS." \
      "Rode o comando de instalação de novo — ele baixa tudo outra vez do zero."
  fi

  if [[ -z "$id_sha" ]]; then
    aviso "Esta versão não trouxe o arquivo de conferência (.sha256) — segui em frente sem essa checagem."
    return 0
  fi

  info "Conferindo se o arquivo baixado está íntegro..."
  local arq_sha="$DIR_TMP/programa.sha256" codigo
  codigo="$(chamar_api "https://api.github.com/repos/${REPO_RELEASES}/releases/assets/${id_sha}" \
              "$arq_sha" "application/octet-stream")"
  if [[ "$codigo" != "200" ]]; then
    aviso "Não consegui baixar o arquivo de conferência (.sha256) — segui em frente."
    return 0
  fi

  local esperado calculado
  esperado="$(awk '{print $1}' "$arq_sha" | head -1 | tr -d '[:space:]')"
  calculado="$(sha256sum "$pacote" | awk '{print $1}')"

  if [[ -z "$esperado" ]]; then
    aviso "O arquivo de conferência veio vazio — segui em frente."
    return 0
  fi

  if [[ "$esperado" != "$calculado" ]]; then
    abortar "O arquivo baixado não confere com o original (${nome_pacote})." \
      "Isso quer dizer que o download chegou corrompido ou pela metade." \
      "Rode o comando de instalação de novo — na segunda tentativa costuma vir certo." \
      "Se acontecer três vezes seguidas, avise o vendedor: a conexão da sua VPS pode estar instável."
  fi
  ok "Arquivo íntegro e conferido."
}

extrair_pacote() {
  local pacote="$1"
  local destino="$DIR_TMP/programa"
  mkdir -p "$destino"

  info "Descompactando..."
  tar -xzf "$pacote" -C "$destino" || \
    abortar "Não consegui descompactar o programa." \
      "O download pode ter chegado danificado." \
      "Rode o comando de instalação de novo." \
      "Se repetir, confira o espaço em disco: ${C_NEGRITO}df -h${C_FIM}"

  # O pacote pode vir com uma pasta raiz só
  local origem="$destino"
  [[ -d "$destino/app" ]] && origem="$destino/app"

  local obrigatorios=("dist-web/server.cjs" "dist/index.html" "prisma/schema.prisma" "package.json")
  local item
  for item in "${obrigatorios[@]}"; do
    [[ -e "$origem/$item" ]] || \
      abortar "O pacote do PilotoZap veio incompleto: falta '$item'." \
        "Isso é um problema da versão publicada, não do seu servidor." \
        "Avise quem te vendeu o PilotoZap e mande esta mensagem."
  done

  PROGRAMA_ORIGEM="$origem"
  ok "Programa baixado e conferido."
}

# ETAPA 4 — Arquivos auxiliares (Dockerfile, entrypoint, compose, backup)
# Rodando por "curl | bash" não existe pasta ao lado do script, então os
# arquivos auxiliares são baixados do mesmo repositório do install.sh.
obter_auxiliar() {
  # obter_auxiliar NOME DESTINO OBRIGATORIO(0|1)
  local nome="$1" destino="$2" obrigatorio="${3:-1}"

  if [[ -n "$DIR_SCRIPT" && -f "$DIR_SCRIPT/$nome" ]]; then
    cp -f "$DIR_SCRIPT/$nome" "$destino"
    return 0
  fi

  if curl -fsSL --max-time 60 "${URL_BASE}/${nome}" -o "$destino" 2>/dev/null; then
    return 0
  fi

  if [[ "$obrigatorio" == "1" ]]; then
    abortar "Não consegui obter um arquivo necessário do instalador: ${nome}" \
      "Teste a internet do servidor: ${C_NEGRITO}curl -I ${URL_BASE}/${nome}${C_FIM}" \
      "Se responder 404, avise o vendedor: o arquivo '${nome}' sumiu do repositório." \
      "Depois rode o comando de instalação de novo."
  fi
  return 1
}

# ETAPA 5 — Pastas e identidade fixa do servidor
# A licença é presa a uma "impressão digital" do servidor: nome da máquina
# (hostname), endereço de rede (MAC) e usuário. Dentro do Docker esses valores
# mudariam a cada reinício, por isso são FIXADOS aqui e nunca mais alterados.
preparar_estrutura() {
  titulo "Preparando as pastas"
  mkdir -p "$DIR_BASE"/{app,dados/prisma,dados/userdata,backups/diarios,backups/semanais,logs}
  chmod 700 "$DIR_BASE"

  local arquivo_identidade="$DIR_BASE/IDENTIDADE-NAO-ALTERAR.txt"

  if [[ -f "$arquivo_identidade" ]]; then
    # Reinstalação: reaproveita a identidade original, senão a licença quebra.
    MAC_FIXO="$(grep -oP '^MAC=\K.*' "$arquivo_identidade" | head -1)"
    HOSTNAME_FIXO="$(grep -oP '^HOSTNAME=\K.*' "$arquivo_identidade" | head -1)"
    USUARIO_CONTAINER="$(grep -oP '^USUARIO=\K.*' "$arquivo_identidade" | head -1)"
    ok "Identidade do servidor preservada da instalação anterior (a licença continua valendo)."
  else
    # Endereço de rede fixo e único (faixa 02:42 = uso local, padrão do Docker)
    MAC_FIXO="$(printf '02:42:ac:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
    cat > "$arquivo_identidade" <<IDENT
# ============================================================================
#  IDENTIDADE DO SERVIDOR — NÃO ALTERE ESTE ARQUIVO
# ============================================================================
#  A licença do PilotoZap está presa a estes três valores.
#  Se você mudar qualquer um deles, a licença PARA DE FUNCIONAR e será
#  preciso pedir uma nova ao vendedor.
#
#  Gerado em: $(date '+%d/%m/%Y %H:%M:%S')
# ============================================================================
HOSTNAME=$HOSTNAME_FIXO
MAC=$MAC_FIXO
USUARIO=$USUARIO_CONTAINER
IDENT
    chmod 400 "$arquivo_identidade"
    ok "Identidade fixa do servidor criada (guardada em IDENTIDADE-NAO-ALTERAR.txt)."
  fi

  info "Copiando os arquivos do programa..."
  # Apaga só o código antigo. Os dados ficam FORA da pasta app/.
  rm -rf "$DIR_BASE/app/dist-web" "$DIR_BASE/app/dist"
  cp -a "$PROGRAMA_ORIGEM/dist-web" "$DIR_BASE/app/"
  cp -a "$PROGRAMA_ORIGEM/dist"     "$DIR_BASE/app/"
  mkdir -p "$DIR_BASE/app/prisma"
  cp -a "$PROGRAMA_ORIGEM/prisma/schema.prisma" "$DIR_BASE/app/prisma/schema.prisma"
  cp -a "$PROGRAMA_ORIGEM/package.json" "$DIR_BASE/app/"
  [[ -f "$PROGRAMA_ORIGEM/package-lock.json" ]] && cp -a "$PROGRAMA_ORIGEM/package-lock.json" "$DIR_BASE/app/" || true
  [[ -d "$PROGRAMA_ORIGEM/public" ]] && cp -a "$PROGRAMA_ORIGEM/public" "$DIR_BASE/app/" || true
  ok "Arquivos do programa copiados para $DIR_BASE/app"
}

# ETAPA 6 — Configuração (.env) — SEM credenciais
# O login e a senha do painel são criados pelo próprio cliente na primeira vez
# que ele abre o painel, logo depois de ativar a licença. Este arquivo NÃO
# guarda usuário nem senha.
preparar_env() {
  titulo "Escrevendo a configuração"
  local env_arquivo="$DIR_BASE/.env"

  # Reinstalação: preserva o arquivo, porque o cliente pode ter acrescentado
  # ajustes próprios nele. A porta real vem do docker-compose.yml, que sempre
  # é regravado — então nada fica desatualizado por causa disso.
  if [[ -f "$env_arquivo" ]]; then
    ok "Configuração anterior preservada (nada foi sobrescrito)."
    return 0
  fi

  cat > "$env_arquivo" <<ENVFILE
# ============================================================================
#  Configuração do PilotoZap — gerado automaticamente em $(date '+%d/%m/%Y %H:%M')
# ============================================================================
#  Não há usuário nem senha aqui: você cria seu login na primeira vez que
#  abre o painel, logo depois de ativar a licença.
# ============================================================================

# Porta interna do programa (só o próprio servidor enxerga)
PORT=$PORTA

# Onde ficam os dados do WhatsApp e as mídias (dentro do container)
USERDATA_PATH=/app/userdata
DIST_DIR=/app/dist

# Fuso horário
TZ=$TZ_PADRAO
ENVFILE
  chmod 600 "$env_arquivo"
  ok "Configuração escrita (sem senhas — você cria a sua no painel)."
}

# ETAPA 7 — Docker: montar e subir
montar_docker() {
  titulo "Montando o PilotoZap"

  obter_auxiliar "Dockerfile"                  "$DIR_BASE/app/Dockerfile"     1
  obter_auxiliar "entrypoint.sh"               "$DIR_BASE/app/entrypoint.sh"  1
  obter_auxiliar "docker-compose.yml.template" "$DIR_TMP/compose.template"    1

  substituir "$DIR_TMP/compose.template" "$DIR_BASE/docker-compose.yml" \
    "NOME_SERVICO=$NOME_SERVICO" \
    "NOME_IMAGEM=$NOME_IMAGEM" \
    "PORTA=$PORTA" \
    "HOSTNAME_FIXO=$HOSTNAME_FIXO" \
    "MAC_ADDRESS=$MAC_FIXO" \
    "USUARIO=$USUARIO_CONTAINER" \
    "DIR_BASE=$DIR_BASE" \
    "TZ=$TZ_PADRAO"

  info "Construindo a imagem do programa (leva de 3 a 8 minutos na primeira vez)."
  info "É normal aparecerem muitas linhas de texto. Aguarde."
  if ! (cd "$DIR_BASE" && docker compose build 2>&1 | tail -40); then
    abortar "A construção do programa falhou." \
      "Causa mais comum: a VPS ficou sem memória ou sem espaço." \
      "Libere espaço com: ${C_NEGRITO}docker system prune -af${C_FIM}" \
      "Veja o espaço livre com: ${C_NEGRITO}df -h${C_FIM}" \
      "Depois rode o instalador de novo — ele continua de onde parou."
  fi
  ok "Programa construído."

  info "Ligando o PilotoZap..."
  (cd "$DIR_BASE" && docker compose up -d) || \
    abortar "Não consegui ligar o PilotoZap." \
      "Veja o motivo com: ${C_NEGRITO}cd $DIR_BASE && docker compose logs --tail 50${C_FIM}" \
      "Se aparecer 'port is already allocated', outro programa está usando a porta $PORTA." \
      "Nesse caso instale em outra porta acrescentando ${C_NEGRITO}--porta 3111${C_FIM}."
  ok "Container no ar."
}

esperar_ficar_pronto() {
  info "Esperando o PilotoZap responder (pode levar até 90 segundos)..."
  local tentativa resposta
  for tentativa in $(seq 1 45); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORTA}/health" >/dev/null 2>&1; then
      resposta="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORTA}/health" || echo '')"
      ok "PilotoZap respondendo. ($resposta)"
      return 0
    fi
    sleep 2
    [[ $((tentativa % 10)) -eq 0 ]] && info "  ainda subindo... ($((tentativa*2))s)"
  done

  echo
  erro "O PilotoZap subiu mas não respondeu a tempo. Últimas linhas do registro:"
  echo "─────────────────────────────────────────────────────────"
  (cd "$DIR_BASE" && docker compose logs --tail 30 2>&1) || true
  echo "─────────────────────────────────────────────────────────"
  abortar "O programa não ficou pronto." \
    "Se você viu 'libssl.so.3' acima, a imagem foi construída errada — rode: ${C_NEGRITO}cd $DIR_BASE && docker compose build --no-cache && docker compose up -d${C_FIM}" \
    "Se viu 'out of memory' ou 'Killed', a VPS tem pouca memória: aumente para 2 GB." \
    "Para acompanhar ao vivo: ${C_NEGRITO}cd $DIR_BASE && docker compose logs -f${C_FIM}"
}

# ETAPA 8 — Estabilidade da identidade (o que impede a licença de morrer)
# Lê a "impressão digital" do servidor exatamente como o PilotoZap a calcula.
ler_machine_id() {
  (cd "$DIR_BASE" && docker compose exec -T "$NOME_SERVICO" node -e '
    const os=require("os"),c=require("crypto");
    const p=[os.hostname()||"",os.platform(),os.arch(),os.userInfo().username||""];
    try{
      const ifs=os.networkInterfaces(); const macs=[];
      for(const n of Object.keys(ifs)){ for(const x of (ifs[n]||[])){
        if(!x.internal && x.mac && x.mac!=="00:00:00:00:00:00") macs.push(x.mac);
      }}
      macs.sort(); if(macs.length) p.push(macs[0]);
    }catch(e){}
    process.stdout.write(c.createHash("sha256").update(p.join("|")).digest("hex"));
  ' 2>/dev/null) || echo ""
}

verificar_identidade_estavel() {
  titulo "Conferindo a estabilidade da licença"
  info "Vou reiniciar o programa uma vez para garantir que a identidade do servidor não muda."

  MACHINE_ID="$(ler_machine_id)"
  if [[ -z "$MACHINE_ID" ]]; then
    aviso "Não consegui ler o código da máquina agora."
    aviso "Você vai conseguir vê-lo na tela de Licença, dentro do painel."
    return 0
  fi

  (cd "$DIR_BASE" && docker compose restart >/dev/null 2>&1) || true
  sleep 6
  local segunda_leitura="" i
  for i in $(seq 1 15); do
    segunda_leitura="$(ler_machine_id)"
    [[ -n "$segunda_leitura" ]] && break
    sleep 2
  done

  if [[ -n "$segunda_leitura" && "$segunda_leitura" != "$MACHINE_ID" ]]; then
    abortar "A identidade do servidor mudou entre um reinício e outro — a licença não ficaria válida." \
      "Isso indica que o arquivo docker-compose.yml não fixou o endereço de rede (mac_address)." \
      "Confira se essas linhas existem em $DIR_BASE/docker-compose.yml:" \
      "    hostname: $HOSTNAME_FIXO" \
      "    mac_address: \"$MAC_FIXO\"" \
      "    user: \"$USUARIO_CONTAINER\"" \
      "Depois rode: ${C_NEGRITO}cd $DIR_BASE && docker compose up -d --force-recreate${C_FIM} e o instalador de novo."
  fi

  echo "$MACHINE_ID" > "$DIR_BASE/CODIGO-DA-MAQUINA.txt"
  chmod 600 "$DIR_BASE/CODIGO-DA-MAQUINA.txt"
  ok "Identidade estável e confirmada."
  esperar_ficar_pronto
}

# ETAPA 9 — Backup automático
instalar_backup() {
  titulo "Ativando o backup automático"

  if ! obter_auxiliar "backup.sh" "$DIR_BASE/backup.sh" 0; then
    aviso "Não consegui obter o backup.sh — o backup automático NÃO foi ativado."
    aviso "Isso não impede o PilotoZap de funcionar. Avise o vendedor."
    return 0
  fi
  chmod +x "$DIR_BASE/backup.sh"

  cat > /etc/cron.d/pilotozap-backup <<CRON
# Backup automático do PilotoZap — todo dia às 03:20 da manhã
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
20 3 * * * root PZ_DIR_BASE=$DIR_BASE /bin/bash $DIR_BASE/backup.sh >> $DIR_BASE/logs/backup.log 2>&1
CRON
  chmod 644 /etc/cron.d/pilotozap-backup
  systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1 || true

  info "Fazendo o primeiro backup agora para conferir que funciona..."
  if PZ_DIR_BASE="$DIR_BASE" bash "$DIR_BASE/backup.sh" >/dev/null 2>&1; then
    ok "Backup automático ativado (todo dia às 03:20). Primeiro backup criado."
  else
    aviso "O backup automático foi agendado, mas o primeiro teste falhou."
    aviso "Rode manualmente para ver o erro: ${C_NEGRITO}bash $DIR_BASE/backup.sh${C_FIM}"
  fi

  obter_auxiliar "uninstall.sh" "$DIR_BASE/uninstall.sh" 0 && chmod +x "$DIR_BASE/uninstall.sh" || true
  obter_auxiliar "README.md"    "$DIR_BASE/LEIA-ME.md"   0 || true
  # Recuperação de senha: o painel roda no servidor do cliente, sem e-mail
  # configurado, então não existe "esqueci minha senha" por link. Sem este
  # script, quem esquece a senha depende de alguém ditar comandos por telefone.
  obter_auxiliar "resetar-senha.sh" "$DIR_BASE/resetar-senha.sh" 0 && chmod +x "$DIR_BASE/resetar-senha.sh" || true

  # Atalho de acesso: gera a chave e monta o pacote que o cliente usa para abrir
  # o painel com dois cliques. Sem isso ele precisaria digitar o comando do túnel
  # no PowerShell toda vez — que é justamente onde a maioria desiste.
  if obter_auxiliar "criar-atalho.sh" "$DIR_BASE/criar-atalho.sh" 0; then
    chmod +x "$DIR_BASE/criar-atalho.sh"
    if PZ_DIR_BASE="$DIR_BASE" PZ_PORTA="$PORTA" bash "$DIR_BASE/criar-atalho.sh" >/dev/null 2>&1; then
      ok "Atalho de acesso criado em $DIR_BASE/acesso/PilotoZap-atalho.zip"
    else
      aviso "Não consegui montar o atalho de acesso automaticamente."
      aviso "Rode depois: ${C_NEGRITO}bash $DIR_BASE/criar-atalho.sh${C_FIM}"
    fi
  fi
}

# ETAPA 10 — Relatório final com o túnel SSH pronto
descobrir_ip_publico() {
  local ip=""
  ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
  echo "$ip"
}

relatorio_final() {
  local ip usuario_ssh comando_tunel arquivo_acesso
  ip="$(descobrir_ip_publico)"
  [[ -n "$ip" ]] || ip="IP-DA-SUA-VPS"
  usuario_ssh="${SUDO_USER:-root}"
  comando_tunel="ssh -L ${PORTA}:127.0.0.1:${PORTA} ${usuario_ssh}@${ip}"
  arquivo_acesso="$DIR_BASE/COMO-ACESSAR.txt"

  # Um texto só, salvo em arquivo e mostrado na tela: o cliente sempre encontra
  # as mesmas instruções, mesmo que feche a janela sem ler.
  cat > "$arquivo_acesso" <<TXT
============================================================
 PILOTOZAP — COMO ACESSAR O SEU PAINEL
 Instalado em: $(date '+%d/%m/%Y às %H:%M')   Versão: ${VERSAO_BAIXADA:-?}
============================================================

 O painel roda SÓ dentro do seu servidor, invisível para a internet.
 Para abri-lo você cria um "túnel" do seu computador até a VPS.

 1) NO SEU COMPUTADOR (não no servidor), abra:
      Windows    -> PowerShell (menu Iniciar, digite "PowerShell")
      Mac/Linux  -> Terminal

 2) Cole este comando e aperte Enter:

      $comando_tunel

    Ele pede a senha da VPS. DEIXE ESSA JANELA ABERTA enquanto usar o
    painel — se fechar, o painel para de abrir (o robô continua atendendo).

 3) Abra o navegador em:

      http://localhost:${PORTA}

 4) Ative a licença. Envie este código da máquina para quem te vendeu
    o PilotoZap e cole a chave que receber na tela de Licença:

      ${MACHINE_ID:-<abra a tela de Licença no painel para ver>}

 5) Crie o SEU login e a SUA senha na tela seguinte. Anote os dois:
    ninguém mais tem essa senha, nem o vendedor.

 6) Conecte o WhatsApp: no painel, vá em Conexões e leia o QR Code.

------------------------------------------------------------
 Comandos úteis (rodar dentro da VPS):
   Ver se está no ar  : cd $DIR_BASE && docker compose ps
   Ver o que aconteceu: cd $DIR_BASE && docker compose logs --tail 50
   Reiniciar          : cd $DIR_BASE && docker compose restart
   Backup manual      : bash $DIR_BASE/backup.sh
   Esqueci a senha    : bash $DIR_BASE/resetar-senha.sh
   Refazer o atalho   : bash $DIR_BASE/criar-atalho.sh

 Pasta da instalação : $DIR_BASE
 Backups             : $DIR_BASE/backups

 NUNCA altere IDENTIDADE-NAO-ALTERAR.txt nem as linhas hostname /
 mac_address / user do docker-compose.yml — a licença para de funcionar.
============================================================
TXT
  chmod 600 "$arquivo_acesso"

  echo
  echo "${C_VERDE}${C_NEGRITO}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║            PILOTOZAP INSTALADO COM SUCESSO!              ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo "${C_FIM}"
  cat "$arquivo_acesso"
  echo
  echo "  ${C_NEGRITO}Guarde isto:${C_FIM} o texto acima também ficou salvo no servidor."
  echo "  Para ver de novo: ${C_NEGRITO}cat $arquivo_acesso${C_FIM}"
  echo
}

# Fluxo principal
principal() {
  echo "${C_NEGRITO}"
  echo "  ┌────────────────────────────────────────────────────────┐"
  echo "  │  PilotoZap — Instalador automático para servidor        │"
  echo "  │  versão $VERSAO_INSTALADOR                                           │"
  echo "  └────────────────────────────────────────────────────────┘"
  echo "${C_FIM}"
  echo "  Em poucos minutos seu robô de WhatsApp estará no ar,"
  echo "  visível apenas para você. Não precisa de domínio nem de e-mail."
  echo

  titulo "Passo 1 de 6 — Conferindo o servidor"
  verificar_token
  verificar_root
  verificar_sistema
  verificar_recursos
  instalar_basicos
  verificar_porta

  titulo "Passo 2 de 6 — Instalando o que falta"
  instalar_docker

  titulo "Passo 3 de 6 — Baixando o programa"
  baixar_programa

  titulo "Passo 4 de 6 — Preparando os arquivos"
  preparar_estrutura
  preparar_env

  titulo "Passo 5 de 6 — Ligando o PilotoZap"
  montar_docker
  esperar_ficar_pronto
  verificar_identidade_estavel

  titulo "Passo 6 de 6 — Backup automático"
  instalar_backup

  limpar_temporarios
  trap - EXIT
  relatorio_final
}

principal "$@"
