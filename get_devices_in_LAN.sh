#!/usr/bin/env bash
# get_devices_in_LAN.sh
# Escaneo LAN Resiliente: IP|MAC|TYPE|VENDOR|OS|DIST|DEVICE|RTT_MS|OPEN_TCP|MAC_CLASS
#
# Lógica:
# 1. Descubrimiento: Combina arp-scan (si existe) + nmap -sn.
# 2. Análisis: Itera sobre IPs únicas, hace fingerpring de OS y completa datos faltantes (Vendor).
#
# Requiere: nmap, ip, coreutils. Opcional (recomendado): arp-scan.
# Ejecutar como root (sudo).
#
# Ejemplo: sudo ./get_devices_in_LAN.sh 192.168.100.0/24 --aggressive --debug

set -u
# No usamos set -e globalmente para manejar errores manualmente en bloques críticos,
# pero controlamos el flujo lógicamente.

DEBUG=0
AGGRESSIVE=0
IFACE=""
CIDR=""

# Colores para logs (opcional, se ven en stderr)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
  cat <<USAGE
Uso:
  sudo $0 <CIDR> [--iface <IFACE>] [--aggressive] [--debug]

Ejemplos:
  sudo $0 192.168.100.0/24
  sudo $0 192.168.1.0/24 --iface eth0 --aggressive
USAGE
}

log() { [[ "${DEBUG}" -eq 1 ]] && echo -e "${YELLOW}DEBUG: $*${NC}" >&2; }
info() { echo -e "${GREEN}INFO: $*${NC}" >&2; }
warn() { echo -e "${YELLOW}WARN: $*${NC}" >&2; }
die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

# Verifica comando. Si es opcional ($2=1), retorna status en lugar de morir.
check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        if [[ "${2:-0}" -eq 1 ]]; then
            return 1 # Falló, pero es opcional
        else
            die "Falta dependencia obligatoria: $1"
        fi
    fi
    return 0
}

# --- Parseo de Argumentos ---

[[ "${EUID}" -eq 0 ]] || die "Se requieren permisos de root (sudo) para obtener MACs y OS fingerprint."

CIDR="${1:-}"; [[ -n "${CIDR}" ]] || { usage; exit 2; }
if [[ "${CIDR}" == -* ]]; then usage; exit 2; fi # El primer arg debe ser CIDR
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) IFACE="${2:-}"; [[ -n "${IFACE}" ]] || die "--iface requiere valor"; shift 2 ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Argumento desconocido: $1" ;;
  esac
done

# --- Dependencias ---
check_cmd ip
check_cmd awk
check_cmd sed
check_cmd grep
check_cmd sort
check_cmd timeout
check_cmd nmap

HAS_ARP_SCAN=0
if check_cmd arp-scan 1; then
    HAS_ARP_SCAN=1
else
    warn "arp-scan no encontrado. Se usará nmap para descubrimiento (puede ser más lento)."
fi

# --- Configuración de Red ---

if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip route show default | awk '{print $5; exit}')"
  [[ -n "${IFACE}" ]] || die "No pude determinar interfaz por defecto. Usá --iface <IFACE>."
fi

GW_IP="$(ip route show default dev "${IFACE}" 2>/dev/null | awk '{print $3; exit}' || true)"
SELF_IP="$(ip -o -4 addr show dev "${IFACE}" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
SELF_MAC="$(cat "/sys/class/net/${IFACE}/address" 2>/dev/null || true)"

log "CIDR=${CIDR} IFACE=${IFACE} GW=${GW_IP} SELF=${SELF_IP} (${SELF_MAC})"

# --- Funciones de Lógica ---

mac_class() {
  local mac="$1"
  [[ -n "${mac}" && "${mac}" != "-" ]] || { echo "-"; return; }
  
  # Extraer primer octeto, asegurar mayúsculas
  local first="${mac%%:*}"; first="${first^^}"
  
  # Validar que sea hex válido para evitar crash en operación aritmética
  if [[ ! "${first}" =~ ^[0-9A-F]{2}$ ]]; then
      echo "INVALID"
      return
  fi

  local val=$((16#${first}))
  # Bit 2 (0x02) encendido = LAA (Local Administered Address)
  (( (val & 2) != 0 )) && echo "LOCAL/Random" || echo "GLOBAL"
}

infer_dist() {
  local s="${1,,}" # to lowercase
  case "${s}" in
    *openwrt*) echo "OpenWrt" ;;
    *dd-wrt*) echo "DD-WRT" ;;
    *mikrotik*|*routeros*) echo "MikroTik" ;;
    *ubuntu*) echo "Ubuntu" ;;
    *debian*) echo "Debian" ;;
    *fedora*) echo "Fedora" ;;
    *centos*|*red\ hat*|*rhel*) echo "RHEL/CentOS" ;;
    *arch\ linux*|*arch*) echo "Arch" ;;
    *windows*) echo "Windows" ;;
    *mac\ os*|*os\ x*|*macos*) echo "macOS" ;;
    *android*) echo "Android" ;;
    *ios*|*iphone*|*ipad*) echo "iOS" ;;
    *cisco*) echo "Cisco IOS" ;;
    *linux*) echo "Linux Generic" ;;
    *) echo "-" ;;
  esac
}

first_nonempty() {
  for v in "$@"; do 
    # Trim whitespace
    local clean_v="$(echo "${v}" | xargs)"
    [[ -n "${clean_v}" && "${clean_v}" != "-" ]] && { echo "${clean_v}"; return; }
  done
  echo "-"
}

# --- Estructuras de Datos ---
# Usamos archivos temporales para listas planas, ya que arrays asociativos complejos
# pueden ser lentos o tricky en bash puro para grandes volúmenes.
# Formato interno: IP|MAC|VENDOR_SRC_1

declare -A MAC_MAP
declare -A VENDOR_MAP

# --- Fase 1: Descubrimiento (Discovery) ---

info "Iniciando descubrimiento en ${CIDR}..."

# Método A: arp-scan (si existe)
if [[ "${HAS_ARP_SCAN}" -eq 1 ]]; then
    log "Ejecutando arp-scan..."
    # Capturamos output, parseamos IP MAC VENDOR
    while IFS=$'\t' read -r ip mac vendor; do
        [[ -n "${ip}" ]] || continue
        MAC_MAP["${ip}"]="${mac}"
        VENDOR_MAP["${ip}"]="${vendor}"
    done < <(arp-scan --interface="${IFACE}" --quiet --plain "${CIDR}" 2>/dev/null | \
             awk 'BEGIN{FS="\t"} {print $1"\t"$2"\t"$3}')
fi

# Método B: nmap ping scan (Respaldo o complemento)
# Útil si arp-scan falló o para confirmar hosts.
# -sn: Ping Scan (disable port scan), -PR: ARP Ping (local), -n: No DNS
log "Ejecutando nmap discovery (-sn)..."
while read -r line; do
    # Formato Nmap -oG: Host: 192.168.1.1 ()	Status: Up	Mac: AA:BB:CC... (Vendor)
    # Parseo rudo pero efectivo
    if [[ "$line" =~ Host:\ ([0-9.]+).*Mac:\ ([0-9A-Fa-f:]+)\ \((.*)\) ]]; then
        ip="${BASH_REMATCH[1]}"
        mac="${BASH_REMATCH[2]}"
        vendor="${BASH_REMATCH[3]}"
        
        # Prioridad: Si ya tenemos MAC de arp-scan, la mantenemos (suele ser fiable).
        # Si no tenemos vendor, usamos el de nmap.
        if [[ -z "${MAC_MAP[$ip]:-}" ]]; then
            MAC_MAP["${ip}"]="${mac}"
        fi
        
        # Si el vendor actual está vacío o es "-", y nmap nos dio uno, úsalo.
        current_vendor="${VENDOR_MAP[$ip]:-}"
        if [[ -z "${current_vendor}" || "${current_vendor}" == "-" ]]; then
             VENDOR_MAP["${ip}"]="${vendor}"
        fi
    fi
done < <(nmap -sn -n -PR "${CIDR}" -oG - 2>/dev/null | grep "Status: Up")

# Agregar SELF manualmente si no apareció (a veces los escáneres ignoran la propia interfaz)
if [[ -n "${SELF_IP}" ]]; then
    MAC_MAP["${SELF_IP}"]="${SELF_MAC}"
    VENDOR_MAP["${SELF_IP}"]="${VENDOR_MAP["${SELF_IP}"]:-LOCAL}"
fi

# Verificar si encontramos algo
HOST_COUNT="${#MAC_MAP[@]}"
info "Hosts detectados: ${HOST_COUNT}"

if [[ "${HOST_COUNT}" -eq 0 ]]; then
    warn "No se encontraron hosts. Revisa la conexión, el CIDR o el aislamiento de red."
    exit 0
fi

# --- Fase 2: Análisis Profundo (OS & Details) ---

# Imprimir Header
echo "IP|MAC|TYPE|VENDOR|OS|DIST|DEVICE|RTT_MS|OPEN_TCP|MAC_CLASS"

# Convertir claves a lista y ordenar IPs numéricamente (sort -V)
SORTED_IPS=$(printf '%s\n' "${!MAC_MAP[@]}" | sort -V)

for ip in $SORTED_IPS; do
    mac="${MAC_MAP[$ip]:-"-"}"
    vendor="${VENDOR_MAP[$ip]:-"-"}"
    
    type="HOST"
    [[ "${ip}" == "${GW_IP}" ]] && type="GATEWAY"
    [[ "${ip}" == "${SELF_IP}" ]] && type="HOST/SELF"

    # Preparar escaneo Nmap detallado
    # -O: OS Detect
    # -F: Fast mode (menos puertos) o default. Si AGGRESSIVE=1 usamos standard.
    # --max-retries 1: Para ser rápido.
    nmap_opts="-n -Pn -O --osscan-guess --max-os-tries 1"
    [[ "${AGGRESSIVE}" -eq 1 ]] && nmap_opts+=" -sV --version-light" || nmap_opts+=" -F"

    log "Analizando ${ip}..."
    
    # Capturamos salida normal de Nmap para parsear detalles que -oG no da bien (como RTT o OS guesses complejos)
    out="$(timeout 40s nmap ${nmap_opts} "${ip}" 2>/dev/null || true)"

    # 1. Fallback de Vendor: Si arp-scan falló, Nmap a veces lo pone en la salida normal
    # Línea: "MAC Address: XX:XX:XX:XX:XX:XX (Nombre del Vendor)"
    if [[ "${vendor}" == "-" || -z "${vendor}" ]]; then
        nmap_vendor="$(echo "${out}" | grep "MAC Address:" | sed -n 's/.*(\(.*\)).*/\1/p')"
        [[ -n "${nmap_vendor}" ]] && vendor="${nmap_vendor}"
    fi

    # 2. RTT / Latencia
    # Línea: "Host is up (0.0023s latency)."
    lat_val="$(echo "${out}" | grep "Host is up" | sed -nE 's/.*\(([0-9.]+)s latency\).*/\1/p')"
    if [[ -n "${lat_val}" ]]; then
        rtt_ms="$(awk -v s="${lat_val}" 'BEGIN{printf "%.1f", (s*1000)}')"
    else
        rtt_ms="-"
    fi

    # 3. OS Detection
    # Buscamos "Running:", "OS details:", o "Aggressive OS guesses:"
    os_running="$(echo "${out}" | grep "^Running:" | cut -d: -f2- | xargs)"
    os_details="$(echo "${out}" | grep "^OS details:" | cut -d: -f2- | xargs)"
    os_guess="$(echo "${out}" | grep "^Aggressive OS guesses:" | cut -d: -f2- | cut -d, -f1 | xargs)"
    
    os_final="$(first_nonempty "${os_running}" "${os_details}" "${os_guess}")"

    # 4. Device Type
    device="$(echo "${out}" | grep "^Device type:" | cut -d: -f2- | xargs)"
    [[ -z "${device}" ]] && device="-"

    # 5. Open Ports (Resumen)
    # awk busca líneas con "/tcp open" y junta los puertos con comas
    open_tcp="$(echo "${out}" | awk '/\/tcp *open/ {print $1}' | cut -d/ -f1 | paste -sd, - | cut -c 1-30)"
    [[ -z "${open_tcp}" ]] && open_tcp="-"
    [[ "${#open_tcp}" -ge 30 ]] && open_tcp="${open_tcp}..." # Truncar si es muy largo

    # 6. Datos derivados
    dist="$(infer_dist "${os_final}")"
    mclass="$(mac_class "${mac}")"

    # Imprimir línea final
    echo "${ip}|${mac}|${type}|${vendor}|${os_final}|${dist}|${device}|${rtt_ms}|${open_tcp}|${mclass}"

done

info "Escaneo finalizado."
