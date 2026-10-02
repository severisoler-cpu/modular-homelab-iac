#!/bin/bash
# =============================================================================
# SCRIPT MAESTRO DE BACKUPS
# Estrategia 3-2-1 con Restic y gestión de energía Wake-on-LAN
# Ejecución periódica recomendada vía cron
# =============================================================================

set -uo pipefail  # Abortar si se usa variable no definida o falla una tubería

# --- DIRECTORIOS BASE ---
BASE_DIR="${DOCKER_BASE_DIR:-$HOME/homelab}"
DATA_DIR="${STORAGE_PATH:-/mnt/storage}"

# --- CONFIGURACIÓN DE BÓVEDAS RESTIC ---
export RESTIC_PASSWORD_FILE="${BASE_DIR}/.restic_password"
LOG_FILE="${BASE_DIR}/backup.log"

# Bóveda 1: Local (HDD Secundario / Almacenamiento Masivo)
REPO_LOCAL="${DATA_DIR}/backups/restic_repo"

# Bóveda 2: Cloud Off-site (Almacenamiento Cloud cifrado vía rclone)
REPO_CLOUD="rclone:cloud_remote:backups/restic_repo"

# Bóveda 3: Dispositivo Secundario (PC / Servidor local vía SFTP)
PC_IP="192.168.1.50"                  # Sustituir por la IP local del equipo de respaldo
PC_MAC="XX:XX:XX:XX:XX:XX"            # Sustituir por la MAC para Wake-on-LAN
PC_USER="TU_USUARIO_SFTP"             # Sustituir por el usuario SFTP/SSH
REPO_WIN="sftp:${PC_USER}@${PC_IP}:C:/Backups_Homelab"

# Exclusiones estándar para el backup de aplicaciones:
EXCLUDES_CEREBRO=(
    --exclude="*/jellyfin/config/data/trickplay"
    --exclude="*/photos/postgres"
    --exclude="*/tools/scrutiny/influxdb"
    --exclude="*/tools/gitea/data/ssh"
)

# --- SECRETOS EXTERNOS ---
# Las credenciales se leen desde un archivo externo (chmod 600)
# para no exponerlas en el propio script ni en el repositorio git.
SECRETS_FILE="${BASE_DIR}/.backup_secrets"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
REMOTE_DB_HOST=""
REMOTE_DB_PORT="5432"
REMOTE_DB_USER=""
REMOTE_DB_PASSWORD=""
REMOTE_DB_NAME="postgres"

if [ -f "$SECRETS_FILE" ]; then
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
fi

# ================================================================================

APAGAR_AL_TERMINAR=0
ERRORES=""
INICIO=$(date +%s)

# --- FUNCIONES ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

notificar_error() {
    local MENSAJE="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
             -d chat_id="$TG_CHAT_ID" \
             -d text="$MENSAJE" \
             -d parse_mode="HTML" > /dev/null || true
    fi
}

registrar_error() {
    local CONTEXTO="$1"
    log "⛔ ERROR en: $CONTEXTO"
    ERRORES="${ERRORES}\n  - ${CONTEXTO}"
}

# Wrapper para comandos críticos: si falla, registra el error pero NO aborta el script entero
ejecutar_paso() {
    local DESCRIPCION="$1"
    shift
    log "▶ Iniciando: $DESCRIPCION..."
    if "$@"; then
        log "  ✓ OK: $DESCRIPCION"
    else
        local STATUS=$?
        if [ "$STATUS" -eq 3 ]; then
            # Restic exit code 3: snapshot guardado correctamente, pero algunos archivos se omitieron con advertencia
            log "  ⚠️ AVISO: $DESCRIPCION completado (snapshot guardado correctamente con advertencias menores)"
        else
            registrar_error "$DESCRIPCION"
        fi
    fi
}

# =============================================================================
log "================================================================"
log " INICIO DEL BACKUP — $(date '+%A, %d de %B de %Y')"
log "================================================================"

# =============================================================================
# PASO 1: PREPARACIÓN — Exportación en caliente de bases de datos
# =============================================================================
log ""
log "--- PASO 1: PREPARACIÓN (Exportación de Bases de Datos) ---"

# n8n (PostgreSQL)
SQL_N8N="${BASE_DIR}/automation/n8n_backup.sql"
log "▶ Exportando base de datos de n8n..."
if sudo docker exec n8n-postgres pg_dump -U n8n n8n > "$SQL_N8N"; then
    TAMANO=$(du -sh "$SQL_N8N" | cut -f1)
    log "  ✓ n8n exportado correctamente (${TAMANO})"
else
    registrar_error "pg_dump de n8n falló (¿está el contenedor encendido?)"
    rm -f "$SQL_N8N"
fi

# Immich (PostgreSQL + pgvector)
SQL_IMMICH="${BASE_DIR}/photos/immich_backup.sql"
log "▶ Exportando base de datos de Immich..."
if sudo docker exec immich_postgres pg_dump -U postgres immich > "$SQL_IMMICH"; then
    TAMANO=$(du -sh "$SQL_IMMICH" | cut -f1)
    log "  ✓ Immich exportado correctamente (${TAMANO})"
else
    registrar_error "pg_dump de Immich falló (¿está el contenedor encendido?)"
    rm -f "$SQL_IMMICH"
fi

# PostgreSQL Remota / Cloud (Opcional)
SQL_CLOUD="${BASE_DIR}/remote_db_backup.sql.gz"
if [ -n "${REMOTE_DB_PASSWORD:-}" ] && [ -n "${REMOTE_DB_HOST:-}" ]; then
    log "▶ Exportando base de datos remota..."
    if sudo docker run --rm \
        -e PGPASSWORD="$REMOTE_DB_PASSWORD" \
        postgres:17-alpine \
        pg_dump -h "$REMOTE_DB_HOST" -p "${REMOTE_DB_PORT:-5432}" -U "${REMOTE_DB_USER:-postgres}" -d "${REMOTE_DB_NAME:-postgres}" \
        --clean --if-exists --no-owner --no-privileges | gzip > "$SQL_CLOUD"; then
        TAMANO=$(du -sh "$SQL_CLOUD" | cut -f1)
        log "  ✓ Base de datos remota exportada correctamente (${TAMANO})"
    else
        registrar_error "pg_dump de Base de datos remota falló"
        rm -f "$SQL_CLOUD"
    fi
else
    log "  ℹ️ Base de datos remota: credenciales no configuradas en .backup_secrets (omitiendo)"
fi

# =============================================================================
# PASO 2: BÓVEDA LOCAL — Almacenamiento Masivo (Tier 1: Cerebro de aplicaciones)
# Propósito: Recuperación casi instantánea ante incidentes operativos
# =============================================================================
log ""
log "--- PASO 2: BÓVEDA LOCAL ---"

ejecutar_paso "Backup aplicaciones → Bóveda Local" \
    restic -r "$REPO_LOCAL" backup "$BASE_DIR" \
        "${EXCLUDES_CEREBRO[@]}"

# Limpieza inteligente: retención de 7 días, 4 semanas, 6 meses
# El --prune físico solo se ejecuta los domingos para optimizar I/O
ejecutar_paso "Forget (retención) → Bóveda Local" \
    restic -r "$REPO_LOCAL" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6

if [ "$(date +%u)" -eq 7 ]; then
    log "  ℹ️ Es domingo — ejecutando prune físico en Bóveda Local..."
    ejecutar_paso "Prune (limpieza física) → Bóveda Local" \
        restic -r "$REPO_LOCAL" prune
    ejecutar_paso "Check (integridad) → Bóveda Local" \
        restic -r "$REPO_LOCAL" check
fi

# =============================================================================
# PASO 3: BÓVEDA CLOUD — Almacenamiento Off-site (Tier 1: Apps + Biblioteca Personal)
# Propósito: Supervivencia ante desastres físicos locales
# =============================================================================
log ""
log "--- PASO 3: BÓVEDA CLOUD ---"

ejecutar_paso "Backup aplicaciones → Bóveda Cloud" \
    restic -r "$REPO_CLOUD" backup "$BASE_DIR" \
        "${EXCLUDES_CEREBRO[@]}" \
        -o rclone.args="serve restic --stdio --tpslimit 8 --tpslimit-burst 8 --transfers 4"

ejecutar_paso "Backup biblioteca fotos → Bóveda Cloud" \
    restic -r "$REPO_CLOUD" backup "${DATA_DIR}/immich" \
        --exclude="${DATA_DIR}/immich/library/thumbs" \
        -o rclone.args="serve restic --stdio --tpslimit 8 --tpslimit-burst 8 --transfers 4"

ejecutar_paso "Forget (retención) → Bóveda Cloud" \
    restic -r "$REPO_CLOUD" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6

if [ "$(date +%u)" -eq 7 ]; then
    ejecutar_paso "Prune (limpieza física) → Bóveda Cloud" \
        restic -r "$REPO_CLOUD" prune
fi

# =============================================================================
# PASO 4: GESTIÓN DE ENERGÍA DEL EQUIPO SECUNDARIO (Wake-on-LAN)
# =============================================================================
log ""
log "--- PASO 4: GESTIÓN DE ENERGÍA DEL EQUIPO SECUNDARIO ---"

if ping -c 1 -W 2 "$PC_IP" > /dev/null 2>&1; then
    log "  ℹ️ El equipo destino ya estaba encendido — no se apagará al terminar."
    APAGAR_AL_TERMINAR=0
else
    log "  El equipo está apagado. Enviando paquete Wake-on-LAN..."
    wakeonlan "$PC_MAC" > /dev/null 2>&1 || true
    APAGAR_AL_TERMINAR=1

    log "  Esperando a que el sistema arranque..."
    INTENTOS=0
    until ping -c 1 -W 2 "$PC_IP" > /dev/null 2>&1; do
        sleep 5
        INTENTOS=$((INTENTOS + 1))
        if [ $INTENTOS -gt 36 ]; then  # 3 minutos máximo
            registrar_error "Equipo secundario no respondió tras 3 minutos — saltando bóveda off-host"
            APAGAR_AL_TERMINAR=0
            break
        fi
    done

    if ping -c 1 -W 2 "$PC_IP" > /dev/null 2>&1; then
        log "  Equipo encendido. Esperando estabilización del servicio SSH/SFTP..."
        sleep 20
    fi
fi

# =============================================================================
# PASO 5: BÓVEDA OFF-HOST SECUNDARIA (Solo si el equipo está disponible)
# Tier 1: Apps completas
# Tier 2: Datos masivos (música, documentos, fotos completas)
# =============================================================================
if ping -c 1 -W 2 "$PC_IP" > /dev/null 2>&1; then
    log ""
    log "--- PASO 5: BÓVEDA SECUNDARIA (Apps + Datos Masivos) ---"

    ejecutar_paso "Backup aplicaciones → Bóveda Secundaria" \
        restic -r "$REPO_WIN" backup "$BASE_DIR" \
            "${EXCLUDES_CEREBRO[@]}"

    if [ "${SKIP_TIER2:-0}" -eq 1 ]; then
        log "  ⚡ MODO TEST: Tier 2 (${DATA_DIR}) omitido intencionalmente."
    else
        ejecutar_paso "Backup datos masivos → Bóveda Secundaria" \
            restic -r "$REPO_WIN" backup "$DATA_DIR" \
                --exclude="${DATA_DIR}/backups" \
                --exclude="${DATA_DIR}/deploy_backups" \
                --exclude="${DATA_DIR}/media" \
                --exclude="${DATA_DIR}/torrents"
    fi

    ejecutar_paso "Forget (retención) → Bóveda Secundaria" \
        restic -r "$REPO_WIN" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6

    if [ "$(date +%u)" -eq 7 ]; then
        ejecutar_paso "Prune (limpieza física) → Bóveda Secundaria" \
            restic -r "$REPO_WIN" prune
        ejecutar_paso "Check (integridad) → Bóveda Secundaria" \
            restic -r "$REPO_WIN" check
    fi
else
    log "  ⚠️ Equipo secundario no disponible — bóveda off-host omitida."
    registrar_error "Equipo secundario no disponible — bóveda off-host omitida"
fi

# =============================================================================
# PASO 6: APAGADO ORDENADO (Si fue encendido por Wake-on-LAN)
# =============================================================================
log ""
log "--- PASO 6: GESTIÓN DE APAGADO ---"
if [ "$APAGAR_AL_TERMINAR" -eq 1 ]; then
    log "  El equipo fue encendido automáticamente. Enviando orden de apagado remoto..."
    ssh -o ConnectTimeout=10 "${PC_USER}@${PC_IP}" "shutdown /s /t 0" || \
        registrar_error "No se pudo enviar la orden de apagado al equipo"
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
FIN=$(date +%s)
DURACION=$(( (FIN - INICIO) / 60 ))

log ""
log "================================================================"
if [ -z "$ERRORES" ]; then
    log " ✅ BACKUP COMPLETADO CON ÉXITO en ${DURACION} minutos"
else
    log " ⚠️ BACKUP COMPLETADO CON ERRORES en ${DURACION} minutos"
    log " Errores detectados:${ERRORES}"
    notificar_error "⚠️ <b>[Homelab] Backup con errores</b> (${DURACION}m)$(echo -e "$ERRORES" | sed 's/  - /\n  • /g')"
fi
log "================================================================"
