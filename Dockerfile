# ==============================================================================
#  PilotoZap — imagem de execução para servidor Linux
# ==============================================================================
#  POR QUE ESTE ARQUIVO EXISTE (não apague):
#
#  A imagem oficial "node:20-bookworm-slim" NÃO vem com a biblioteca OpenSSL.
#  Sem ela o banco de dados (Prisma) falha logo no arranque com a mensagem:
#
#      libssl.so.3: cannot open shared object file: No such file or directory
#
#  Este Dockerfile resolve isso instalando o pacote `openssl` e gerando o
#  cliente do Prisma DENTRO do Linux (para que ele escolha o motor correto,
#  debian-openssl-3.0.x). Não adianta apenas apontar variáveis de ambiente
#  para outro motor: a biblioteca precisa existir no sistema.
# ==============================================================================

FROM node:20-bookworm-slim

# ── Bibliotecas do sistema ────────────────────────────────────────────────────
#  openssl         -> obrigatório para o Prisma (resolve o bug do libssl.so.3)
#  ca-certificates -> chamadas HTTPS (OpenAI, OpenRouter, WhatsApp)
#  sqlite3         -> usado pelo backup (VACUUM INTO) e para ligar o modo WAL
#  tini            -> encerra o processo com elegância no "docker stop"
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssl \
      ca-certificates \
      sqlite3 \
      tini \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

WORKDIR /app

# ── Dependências de execução ──────────────────────────────────────────────────
#  O bundle é gerado com esbuild "--packages=external", ou seja, o server.cjs
#  NÃO carrega as bibliotecas dentro dele: a pasta node_modules PRECISA existir
#  aqui dentro em tempo de execução. Por isso instalamos as dependências aqui,
#  e não copiamos node_modules do Windows (binários incompatíveis).
#  (o padrão package*.json pega o package.json e, se existir, o package-lock.json)
COPY package*.json ./
#  Se o package-lock.json estiver levemente desatualizado, o "npm ci" recusa.
#  Nesse caso caímos para o "npm install", que resolve as versões na hora.
RUN if [ -f package-lock.json ] && npm ci --omit=dev ; then \
      echo "[build] dependencias instaladas a partir do package-lock.json" ; \
    else \
      echo "[build] package-lock ausente ou desatualizado — usando npm install" ; \
      npm install --omit=dev ; \
    fi \
 && npm cache clean --force

# ── Cliente do Prisma gerado no Linux ─────────────────────────────────────────
#  A CLI do Prisma é instalada de forma global (fora do node_modules do app)
#  para não arrastar as dependências de desenvolvimento para a imagem.
#  A versão precisa acompanhar a do @prisma/client em package.json.
RUN npm install -g prisma@5.22.0

#  O schema fica guardado num lugar separado porque, em execução, a pasta
#  /app/prisma é substituída pela pasta de dados do servidor (onde vive o
#  banco dev.db). O entrypoint recoloca o schema lá toda vez que o app sobe.
COPY prisma/schema.prisma /opt/pilotozap/schema/schema.prisma
RUN mkdir -p /app/prisma \
 && cp /opt/pilotozap/schema/schema.prisma /app/prisma/schema.prisma \
 && prisma generate --schema=/app/prisma/schema.prisma

# ── Aplicação já compilada ────────────────────────────────────────────────────
COPY dist-web/ ./dist-web/
COPY dist/     ./dist/

# ── Script de arranque ────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/pilotozap-entrypoint.sh
RUN chmod +x /usr/local/bin/pilotozap-entrypoint.sh \
 && sed -i 's/\r$//' /usr/local/bin/pilotozap-entrypoint.sh

# ── Verificação de saúde ──────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD node -e "require('http').get({host:'127.0.0.1',port:process.env.PORT||3110,path:'/health',timeout:4000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

EXPOSE 3110

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/pilotozap-entrypoint.sh"]
