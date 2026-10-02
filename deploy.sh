#!/bin/bash
# =============================================================================
# deploy.sh - Script de despliegue modular con snapshots de seguridad
# Uso: ./deploy.sh [ruta_del_stack] (ej. ./deploy.sh tools/homepage)
# =============================================================================

set -euo pipefail

STACK="${1:-}"

if [ -z "$STACK" ]; then
    echo "❌ Error: Debes especificar el directorio del stack a desplegar."
    echo "Uso: ./deploy.sh <directorio> (ej. ./deploy.sh tools/homepage)"
    exit 1
fi

BASE_DIR="${DOCKER_BASE_DIR:-$HOME/homelab}"
STACK_PATH="$BASE_DIR/$STACK"
BACKUP_DIR="${DEPLOY_BACKUP_DIR:-${STORAGE_PATH:-/mnt/storage}/deploy_backups}"

# Detectar si es un stack nuevo o existente
if [ ! -d "$STACK_PATH" ] || [ ! -f "$STACK_PATH/docker-compose.yml" ] || [ -z "$(sudo docker compose -f "$STACK_PATH/docker-compose.yml" ps -q 2>/dev/null)" ]; then
    IS_NEW_STACK=true
    echo "=========================================="
    echo "✨ DETECTADO NUEVO STACK: $STACK"
    echo "=========================================="
else
    IS_NEW_STACK=false
    echo "=========================================="
    echo "🚀 INICIANDO DESPLIEGUE SEGURO: $STACK"
    echo "=========================================="
fi

if [ "$IS_NEW_STACK" = true ]; then
    # --- FLUJO PARA NUEVO STACK ---
    echo "[1/2] 🔄 Descargando cambios oficiales de Git (Git Pull)..."
    cd "$BASE_DIR" || exit 1

    if ! git pull; then
        echo "❌ Error: El 'git pull' falló."
        exit 1
    fi

    if [ ! -f "$STACK_PATH/docker-compose.yml" ]; then
        echo "❌ Error: Tras hacer 'git pull', no se encontró $STACK_PATH/docker-compose.yml."
        echo "Asegúrate de que la ruta sea correcta y que los cambios se hayan subido al repositorio."
        exit 1
    fi

    echo "[2/2] ▶️ Levantando nuevo stack..."
    if ! sudo docker compose -f "$STACK_PATH/docker-compose.yml" up -d; then
        echo "❌ Error: Fallo al levantar el nuevo stack."
        exit 1
    fi

else
    # --- FLUJO PARA ACTUALIZACIÓN DE STACK EXISTENTE ---
    # 1. Zona segura
    if ! mkdir -p "$BACKUP_DIR"; then
        echo "❌ CRÍTICO: No se pudo crear/acceder al directorio de backups $BACKUP_DIR."
        echo "Abortando despliegue."
        exit 1
    fi

    # 2. Detener servicios
    echo "[1/4] 🛑 Deteniendo contenedores para copia en frío segura..."
    if ! sudo docker compose -f "$STACK_PATH/docker-compose.yml" stop; then
        echo "❌ Error: Fallo al detener los contenedores. Abortando."
        exit 1
    fi

    # 3. Snapshot en frío (PUNTO DE SEGURIDAD CRÍTICO)
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_NAME="$(basename "$STACK")_${TIMESTAMP}.tar.gz"
    echo "[2/4] 📦 Creando snapshot en $BACKUP_DIR/$BACKUP_NAME..."

    if ! tar --ignore-failed-read -czf "$BACKUP_DIR/$BACKUP_NAME" -C "$BASE_DIR" "$STACK"; then
        echo "❌ CRÍTICO: FALLÓ LA COPIA DE SEGURIDAD FÍSICA."
        echo "⚠️  Abortando todo de inmediato. SIN COPIA NO HAY PULL."
        echo "🔄 Volviendo a encender los contenedores para no cortar el servicio..."
        sudo docker compose -f "$STACK_PATH/docker-compose.yml" start
        exit 1
    fi

    # 4. Actualizar código desde Git
    echo "[3/4] 🔄 Descargando cambios oficiales de Git (Git Pull)..."
    cd "$BASE_DIR" || exit 1

    if ! git pull; then
        echo "❌ Error: El 'git pull' falló (posibles conflictos)."
        echo "🔄 Volviendo a encender los contenedores con la versión antigua para no cortar el servicio..."
        sudo docker compose -f "$STACK_PATH/docker-compose.yml" start
        exit 1
    fi

    # 5. Arrancar la nueva versión
    echo "[4/4] ▶️ Levantando servicios actualizados..."
    if ! sudo docker compose -f "$STACK_PATH/docker-compose.yml" up -d; then
        echo "❌ Error: Fallo al levantar los contenedores tras actualizar."
        echo "⚠️  Tienes una copia de seguridad 100% funcional en $BACKUP_DIR/$BACKUP_NAME"
        exit 1
    fi
fi

echo "=========================================="
echo "✅ DESPLIEGUE COMPLETADO CON ÉXITO"
echo "=========================================="
