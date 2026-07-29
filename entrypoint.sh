#!/bin/sh
# ==============================================================================
#  PilotoZap — script de arranque de dentro do container
# ==============================================================================
#  Roda toda vez que o programa liga. Ele:
#    1. garante que as pastas de dados existam;
#    2. recoloca o schema do banco (a pasta /app/prisma vem do servidor);
#    3. cria/atualiza as tabelas do banco;
#    4. liga o modo WAL do SQLite (permite backup com o sistema no ar);
#    5. inicia o servidor web.
#
#  NÃO altere este arquivo sem falar com o suporte.
# ==============================================================================
set -e

echo "[PilotoZap] Preparando as pastas de dados..."
mkdir -p /app/prisma /app/userdata

# O schema vem de dentro da imagem; a pasta /app/prisma é montada a partir do
# servidor (é onde ficam os dados que precisam sobreviver a atualizações).
cp -f /opt/pilotozap/schema/schema.prisma /app/prisma/schema.prisma

echo "[PilotoZap] Verificando a estrutura do banco de dados..."
if ! prisma db push --schema=/app/prisma/schema.prisma --skip-generate; then
  echo "[PilotoZap] AVISO: nao consegui atualizar a estrutura do banco de dados."
  echo "[PilotoZap] O programa vai tentar iniciar assim mesmo."
  echo "[PilotoZap] Se o painel nao abrir: faca um backup da pasta de dados"
  echo "[PilotoZap] (bash backup.sh) e acione o suporte com esta mensagem."
fi

# Modo WAL: leitura e escrita simultaneas mais seguras. Tambem e o que permite
# ao backup usar VACUUM INTO com o sistema no ar, sem risco de arquivo corrompido.
sqlite3 /app/prisma/dev.db "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true

echo "[PilotoZap] Iniciando o servidor na porta ${PORT:-3110}..."
exec node dist-web/server.cjs
