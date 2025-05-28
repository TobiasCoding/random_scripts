#!/usr/bin/env bash
# --------------------------------------------------
# Script: dump_project.sh
# Descripción: Genera un único archivo de texto con el
# contenido de todos los archivos de código/entorno en
# un directorio, respetando .gitignore incluso para
# archivos ya trackeados, con barra de progreso y tiempo.
# Uso: ./dump_project.sh [directorio]
# Si no se indica un directorio, por defecto se ejecuta
# en el que está el script.
# --------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

# 1) Determinar directorio objetivo
if [[ -n "${1-}" && -d "$1" ]]; then
  TARGET_DIR="$1"
else
  TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
cd "$TARGET_DIR" || { echo "Error: no se puede acceder a $TARGET_DIR"; exit 1; }

# 2) Recopilar lista de archivos (trackeados + no trackeados, excluyendo ignorados)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -d '' FILES < <(git ls-files -z --cached --others --exclude-standard)
else
  mapfile -d '' FILES < <(find . -type f -print0)
fi

# 3) Cargar patrones de .gitignore (si existe)
IGNORE_PATTERNS=()
if [[ -f .gitignore ]]; then
  # ignorar comentarios y líneas vacías
  mapfile -t IGNORE_PATTERNS < <(grep -Ev '^\s*(#|$)' .gitignore)
fi

# 4) Definir filtros de nombre/extensión
### Incluir los siguientes formatos:
EXT_REGEX='.*\.(py|pyx|pyi|js|mjs|cjs|jsx|ts|tsx|sh|bash|zsh|ksh|fish|ps1|psm1|bat|cmd|java|kt|kts|scala|swift|cs|vb|go|rs|dart|php|rb|r|m|jl|hs|lhs|clj|cljs|edn|pl|pm|coffee|lua|groovy|sql|toml|ini|cfg|properties|gradle|cmake|mk|dockerfile|makefile|html?|xhtml|xml|xsl|json|ya?ml|yaml|vue|svelte|scss|sass|less|styl|css|graphql|gql|proto|adoc|tex|bib|md|rst)$'
### Incluye además estos archivos como excepción a las reglas de la linea anterior
SPECIAL_REGEX='^Dockerfile$|^Makefile$|^requirements\.txt$'

# 5) Filtrar según existencia, .gitignore, trash, self y patrones
FILTERED=()
for f in "${FILES[@]}"; do
  # ruta relativa sin prefijo "./"
  path="${f#./}"

  # 5.1) Omitir si no existe en disco (evita main.py, docker-compose.yml inexistentes)
  if [[ ! -e "$path" ]]; then
    echo "✗ (no existe): $path"
    continue
  fi

  # 5.2) Omitir si coincide con cualquier patrón de .gitignore
  skip=false
  for pattern in "${IGNORE_PATTERNS[@]}"; do
    if [[ "$pattern" == */ ]]; then
      # patrón de directorio
      dir="${pattern%/}"
      if [[ "$path" == "$dir/"* ]]; then
        skip=true
        break
      fi
    else
      # patrón de archivo o glob
      if [[ "$path" == $pattern ]]; then
        skip=true
        break
      fi
    fi
  done
  if [[ "$skip" == true ]]; then
    echo "✗ (gitignore): $path"
    continue
  fi

  # 5.3.1) Omitir directorio .trash cuando se encuentre
  if [[ "$path" == .trash/* ]]; then
    echo "✗ (trash): $path"
    continue
  fi

  # 5.3.2) Omitir directorio node_modules cuando se encuentre
  if [[ "$path" == node_modules/* ]]; then
    echo "✗ (node_modules): $path"
    continue
  fi

  # 5.3.3) Omitir directorio venv cuando se encuentre
  if [[ "$path" == venv/* ]]; then
    echo "✗ (venv): $path"
    continue
  fi

  # 5.3.4) Omitir directorio __pycache__ cuando se encuentre
  if [[ "$path" == __pycache__/* ]]; then
    echo "✗ (__pycache__): $path"
    continue
  fi

  # 5.4) Omitir este mismo script
  if [[ "${path##*/}" == "${BASH_SOURCE[0]##*/}" ]]; then
    echo "✗ (self): $path"
    continue
  fi

  # 5.5) Incluir si extensión o nombre especial
  if [[ "$path" =~ $EXT_REGEX ]] || [[ "$path" =~ $SPECIAL_REGEX ]]; then
    FILTERED+=("$path")
    echo "✓: $path"
  else
    echo "✗ (no match): $path"
  fi
done

TOTAL=${#FILTERED[@]}
if (( TOTAL == 0 )); then
  echo "No se encontraron archivos válidos en $TARGET_DIR"
  exit 0
fi

# 6) Preparar archivo de salida y temporizador
OUTPUT_FILE="$(pwd)/project_$(date +%Y%m%d_%H%M%S).txt"
START_TIME=$(date +%s)

echo "Generando '$OUTPUT_FILE' con $TOTAL archivos..."

# 7) Volcar contenidos con barra de progreso
i=0
for file in "${FILTERED[@]}"; do
  i=$((i+1))
  pct=$((i*100/TOTAL))
  filled=$((pct*50/100))
  bar="$(printf '%0.s#' $(seq 1 $filled))"
  printf "\r[%-50s] %3d%% (%d/%d)" "$bar" "$pct" "$i" "$TOTAL"

  {
    printf "\n\n=== File: %s ===\n" "$file"
    cat "$file" || echo "[Error leyendo $file]"
  } >> "$OUTPUT_FILE"
done

# 8) Mostrar tiempo total
END_TIME=$(date +%s)
ELAPSED=$((END_TIME-START_TIME))
printf "\nCompletado en %d segundos. Archivo: %s\n" "$ELAPSED" "$OUTPUT_FILE"
