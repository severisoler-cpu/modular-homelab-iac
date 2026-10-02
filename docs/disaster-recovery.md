# 🚑 Runbook de Recuperación ante Desastres (Disaster Recovery)

> *"Los backups no tienen ningún valor; lo único que importa es la capacidad y el tiempo demostrado de restauración."*

Este documento establece los procedimientos empíricos para la mitigación de incidentes y recuperación de servicios ante fallos de software, corrupción de datos o pérdida física del hardware.

---

## 🎯 Objetivos de Continuidad (RTO & RPO)

| Métrica | Objetivo | Justificación Técnica |
| :--- | :--- | :--- |
| **RPO (Punto Objetivo de Recuperación)** | Configurable (< 24h) | Frecuencia de ejecución definida por el usuario vía cron (ej. diario nocturno: cerebro de apps + dumps atómicos de BD). |
| **RTO (Tiempo Objetivo de Recuperación - Stack)** | < 2 Minutos | Restauración instantánea desde el snapshot en frío de `deploy.sh`. |
| **RTO (Tiempo Objetivo de Recuperación - Total)** | < 45 Minutos | Re-despliegue completo desde Git + restauración de datos desde Bóveda 1. |

---

## 🛠️ Escenario 1: Rollback Inmediato de un Stack tras Despliegue Fallido

Si al ejecutar `./deploy.sh <stack>` una nueva versión de una imagen Docker o una migración rompe el contenedor:

1. **Localizar el snapshot previo:**  
   `deploy.sh` crea automáticamente una copia en frío en `${STORAGE_PATH:-/mnt/storage}/deploy_backups/` antes de realizar el pull.
   ```bash
   ls -lt ${STORAGE_PATH:-/mnt/storage}/deploy_backups/<stack>_*.tar.gz | head -n 1
   ```

2. **Detener el stack con problemas:**
   ```bash
   sudo docker compose -f "$DOCKER_BASE_DIR/<stack>/docker-compose.yml" down
   ```

3. **Restaurar el snapshot seguro:**
   ```bash
   tar -xzf ${STORAGE_PATH:-/mnt/storage}/deploy_backups/<stack>_<timestamp>.tar.gz -C "$DOCKER_BASE_DIR"
   ```

4. **Rearrancar el stack estabilizado:**
   ```bash
   sudo docker compose -f "$DOCKER_BASE_DIR/<stack>/docker-compose.yml" up -d
   ```

---

## 💾 Escenario 2: Restauración de una Base de Datos PostgreSQL desde Restic

Si ocurre una corrupción de datos en la base de datos de **n8n** o **Immich**:

1. **Detener el motor de aplicación (mantener solo el contenedor de base de datos):**
   ```bash
   sudo docker compose -f "$DOCKER_BASE_DIR/automation/docker-compose.yml" stop n8n
   ```

2. **Localizar el snapshot de Restic deseado:**
   ```bash
   restic -r ${STORAGE_PATH:-/mnt/storage}/backups/restic_repo snapshots
   ```

3. **Extraer el volcado SQL más reciente:**
   ```bash
   restic -r ${STORAGE_PATH:-/mnt/storage}/backups/restic_repo restore <SNAPSHOT_ID> \
       --target /tmp/restore_db \
       --include "$DOCKER_BASE_DIR/automation/n8n_backup.sql"
   ```

4. **Inyectar el volcado en PostgreSQL:**
   ```bash
   sudo docker exec -i n8n-postgres psql -U n8n -d n8n < /tmp/restore_db/$DOCKER_BASE_DIR/automation/n8n_backup.sql
   ```

5. **Reiniciar la aplicación y verificar logs:**
   ```bash
   sudo docker compose -f "$DOCKER_BASE_DIR/automation/docker-compose.yml" up -d n8n
   sudo docker compose -f "$DOCKER_BASE_DIR/automation/docker-compose.yml" logs -f n8n
   ```

---

## ☁️ Escenario 3: Recuperación ante Destrucción del Almacenamiento Local (Bóveda Cloud)

Si el disco de almacenamiento local o el servidor sufre un fallo de hardware catastrófico:

1. **Configurar el acceso a la Bóveda Cloud en una nueva máquina:**
   Instalar `restic` y `rclone`, configurando el remoto correspondiente (ej. Google Drive, Backblaze B2 o S3).
   ```bash
   rclone config
   ```

2. **Verificar acceso a los snapshots remotos cifrados:**
   ```bash
   export RESTIC_PASSWORD="TU_PASSWORD_RESTIC"
   restic -r rclone:cloud_remote:backups/restic_repo snapshots
   ```

3. **Restaurar la infraestructura completa:**
   ```bash
   mkdir -p ~/homelab
   restic -r rclone:cloud_remote:backups/restic_repo restore latest \
       --target ~/homelab
   ```

4. **Levantar los servicios:**
   ```bash
   cd ~/homelab
   ./deploy.sh tools/cloudflare
   ./deploy.sh tools/homepage
   ```

---

## 🔍 Checklist de Verificación de Integridad

Ejecutar periódicamente para asegurar que los repositorios de Restic no presentan inconsistencias criptográficas:

```bash
# Comprobar integridad física y estructural de los índices
restic -r ${STORAGE_PATH:-/mnt/storage}/backups/restic_repo check --read-data-subset=10%

# Purgar datos huérfanos desvinculados
restic -r ${STORAGE_PATH:-/mnt/storage}/backups/restic_repo prune
```
