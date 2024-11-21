#!/bin/bash

echo "######################"
echo "#### Moodle SATIS ####"
echo "######################"

# Define COMPOSER_HOME para um diretório temporário
export COMPOSER_HOME=$(mktemp -d)

# Identificar o usuário que está executando o script
echo "Usuário atual: $(whoami)"

# Init
echo "-- INICIANDO --"
echo "Usuário atual: $(whoami)" # Identificar o usuário que está executando o script
start_time=$(date +%s)
LOCK_FILE="satis_upgrade.lock"
LOCK_CONTENT="$$"  # Use o ID do processo como conteúdo do lock
LAST_RUN_FILE="satis_last_composer_update.lock"  # Arquivo para armazenar o timestamp da última execução do composer update
set -e
export COMPOSER_ALLOW_SUPERUSER=1 # Permitir execução do Composer como superusuário
export INDEX_FILE="$SATIS_OUTPUTDIR/public_html/index.html"

# Acessa o diretório onde o script está localizado
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "Falha ao mudar para o diretório do script $SCRIPT_DIR. Saindo..."; exit 1; }
echo "Diretório do script: $SCRIPT_DIR"

# Função para remover o lock file de forma segura
cleanup() {
  if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE")" = "$LOCK_CONTENT" ]; then
    rm -f "$LOCK_FILE"
    echo "Arquivo de lock removido com sucesso."
  fi
}

# Check if lock file exists
if [ -f "$LOCK_FILE" ]; then
  echo "Outro processo está em execução. Saindo..."
  exit 1
fi

# Create lock file with process ID
echo "$LOCK_CONTENT" > "$LOCK_FILE"

# Ensure lock file is removed on script exit or error
trap 'cleanup' EXIT
trap 'echo "Ocorreu um erro. Saindo..."; exit 1;' ERR

# Load .env and check required variables
if [ -f ".env" ]; then
  source .env
else
  echo "Arquivo .env não encontrado. Saindo..."
  exit 1
fi

# Check required environment variables
missing_env_vars=()
for var in SATIS_BASEDIR REPO_BRANCH PHP_BIN SATIS_OUTPUTDIR; do
  if [ -z "${!var}" ]; then
    missing_env_vars+=("$var")
  fi
done

if [ ${#missing_env_vars[@]} -ne 0 ]; then
  echo "As seguintes variáveis de ambiente não estão definidas no .env: ${missing_env_vars[*]}"
  exit 1
fi

# Enter App path
echo "-- Atualizando repositório SATIS --"
cd "$SATIS_BASEDIR" || { echo "Falha ao mudar para o diretório $SATIS_BASEDIR. Saindo..."; exit 1; }
echo "PATH (current): $(pwd)"
echo -e "\n"

echo ">> Resetando e buscando via Git"
if ! git reset --hard HEAD || ! git fetch --all; then
  echo "Falha ao resetar e buscar no repositório Git. Saindo..."
  exit 1
fi

echo ">> Fazendo checkout e pull na branch $REPO_BRANCH"
if ! git checkout "$REPO_BRANCH" || ! git pull origin "$REPO_BRANCH"; then
  echo "Falha ao fazer checkout ou pull da branch $REPO_BRANCH. Saindo..."
  exit 1
fi
echo -e "\n"

# Verificar se a pasta vendor existe
if [ ! -d "vendor" ]; then
  echo ">> Pasta 'vendor' não encontrada. Executando 'composer install'..."
  if ! composer install --no-dev --prefer-dist --optimize-autoloader; then
    echo "Falha ao executar 'composer install'. Saindo..."
    exit 1
  fi
else
  # Check if the composer update was run today
  if [ -f "$LAST_RUN_FILE" ]; then
    LAST_RUN_DATE=$(cat "$LAST_RUN_FILE")
    CURRENT_DATE=$(date +%Y-%m-%d)

    if [ "$LAST_RUN_DATE" = "$CURRENT_DATE" ]; then
      echo "O composer update já foi executado hoje ($LAST_RUN_DATE). Pulando a execução."
    else
      # Update the last run date
      echo "$CURRENT_DATE" > "$LAST_RUN_FILE"

      echo ">> Atualizando dependências do Composer"
      if ! composer update -n; then
        echo "Falha ao atualizar dependências do Composer. Saindo..."
        exit 1
      fi
      echo -e "\n"
    fi
  else
    # Run composer update if the LAST_RUN_FILE does not exist
    CURRENT_DATE=$(date +%Y-%m-%d)
    echo "$CURRENT_DATE" > "$LAST_RUN_FILE"

    echo ">> Atualizando dependências do Composer"
    if ! composer update -n; then
      echo "Falha ao atualizar dependências do Composer. Saindo..."
      exit 1
    fi
    echo -e "\n"
  fi
fi

echo ">> Gerando satis.json"
if ! $PHP_BIN gen.php --satisfile="$SATIS_OUTPUTDIR/satis.json" --output-dir="$SATIS_OUTPUTDIR/"; then
  echo "Falha ao gerar satis.json. Saindo..."
  exit 1
fi
echo -e "\n"

echo ">> Executando SATIS"
if ! vendor/bin/satis build "$SATIS_OUTPUTDIR/satis.json" --skip-errors --minify --no-interaction; then
  echo "Falha ao executar SATIS. Saindo..."
  exit 1
fi
echo -e "\n"

echo ">> Adicionando CSS customizado ao index.html"
if [ -f "$INDEX_FILE" ]; then
  echo "Adicionando CSS personalizado ao index.html"
  sed -i '' '/<head>/a\
    <style>.field-required-by {display: none !important;}</style>
  ' "$INDEX_FILE"
  echo "CSS inline adicionado com sucesso!"
else
  echo "Arquivo index.html não encontrado em $INDEX_FILE. Pulando adição de CSS."
fi

# Display time execution
echo "> Concluindo"
end_time=$(date +%s)
execution_time=$((end_time - start_time))
hours=$((execution_time / 3600))
minutes=$(((execution_time % 3600) / 60))
seconds=$((execution_time % 60))
formatted_time=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
echo "Tempo de execução: $formatted_time"

echo "-- FINALIZADO --"

# Exit with success
exit 0
