# [S17] Transacciones y recuperación de errores en PostgreSQL con Chinook

* **Estudiante**: Robert Geovanni Barrios Gameros (`2890-24-6773`)
* **Curso**: Base de Datos 1 — Plan Fin de Semana
* **Catedrático**: Ing. Yoel Monzón
* **Universidad**: Universidad Mariano Gálvez de Guatemala — Sede Retalhuleu

Repositorio de práctica para la evaluación **[S17] Transacciones y recuperación de errores en PostgreSQL con Chinook**. Demuestra el control transaccional explícito en **PostgreSQL 18 (`18.6`)** sobre el esquema oficial `Chinook_PostgreSql_SerialPKs.sql`, abarcando confirmación atómica (`COMMIT`), reversión completa ante violación de integridad referencial (`ROLLBACK`), recuperación parcial con puntos de salvaguarda (`SAVEPOINT` / `ROLLBACK TO SAVEPOINT`) y visibilidad entre sesiones concurrentes bajo el nivel de aislamiento `Read Committed`.

---

## 1. Estructura del repositorio

| Archivo | Propósito |
| :--- | :--- |
| `README.md` | Documentación completa de entorno, importación, conexiones A/B en DataGrip o `psql`, autocommit, parámetros dinámicos y repetición de pruebas. |
| `Chinook_PostgreSql_SerialPKs.sql` | Script oficial del esquema y datos de **Chinook v1.4.5** con claves primarias `SERIAL` (`lerocha/chinook-database`). |
| `01_venta_exitosa.sql` | **Escenario 1**: Transacción explícita exitosa (`BEGIN ... COMMIT`), inserción de cabecera con `RETURNING` (`invoice_id = 413`), 3 detalles válidos, cálculo exacto de `total` con `SUM(unit_price * quantity)` (`5.94`) y verificación de coherencia. |
| `02_rollback_total.sql` | **Escenario 2**: Transacción con violación real de `FOREIGN KEY` (`invoice_line_track_id_fkey`, `track_id = 999999`), demostración del estado abortado (`25P02`), recuperación con `ROLLBACK` y comprobación por la clave específica (`invoice_id = 414`) de que no quedaron datos huérfanos. |
| `03_savepoint.sql` | **Escenario 3**: Transacción (`invoice_id = 415`) con 2 detalles válidos iniciales (`track_id` 5 y 6), `SAVEPOINT`, fallo por referencia inválida (`track_id = 888888`), recuperación parcial con `ROLLBACK TO SAVEPOINT`, inserción de un 3.er detalle corregido (`track_id = 7`), `RELEASE SAVEPOINT`, recálculo de total (`4.95`) y `COMMIT`. |
| `04_validaciones.sql` | **Escenario 4 y Auditoría**: Verificación de conexiones independientes (PIDs distintos), prueba de visibilidad en **Sesión B** antes y después del `COMMIT` bajo `Read Committed` (`invoice_id = 416`, `total = 2.97`, y verificación de `413`), y auditoría de huecos de secuencias (`invoice_invoice_id_seq` e `invoice_line_invoice_line_id_seq`). |
| `docker-compose.yml` | Configuración de contenedor **PostgreSQL 18** (`pg18_chinook_s17`) para levantar un entorno aislado reproducible. |
| `.env.example` | Plantilla de variables de entorno sin secretos ni contraseñas reales. |

---

## 2. Entorno, versión y variante de Chinook

* **Motor de Base de Datos**: `PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2)` ejecutándose en contenedor oficial `postgres:18` (`pg18_chinook_s17`).
* **Cliente SQL**: **JetBrains DataGrip** (dos consolas independientes `Sesion_A` y `Sesion_B`) o cliente CLI `psql`. Todos los scripts utilizan **SQL estándar de PostgreSQL**, ejecutándose directamente en DataGrip sin errores de metaórdenes.
* **Variante del esquema**: Oficial **`Chinook_PostgreSql_SerialPKs.sql`** (v1.4.5) del repositorio [`lerocha/chinook-database`](https://github.com/lerocha/chinook-database).
* **Base de datos de trabajo**: `chinook_serial` (creada por el propio script oficial).
* **Tablas principales utilizadas**:
  * `customer` (`customer_id` SERIAL PK): 59 clientes originales (`1..59`).
  * `track` (`track_id` SERIAL PK, `unit_price NUMERIC(10,2)`): 3503 canciones originales (`1..3503`).
  * `invoice` (`invoice_id` SERIAL PK, `customer_id` FK, `total NUMERIC(10,2)`): 412 facturas originales (`1..412`).
  * `invoice_line` (`invoice_line_id` SERIAL PK, `invoice_id` FK, `track_id` FK, `unit_price NUMERIC(10,2)`, `quantity INT`): 2240 líneas originales (`1..2240`).

> **Advertencia importante antes de importar `Chinook_PostgreSql_SerialPKs.sql`**:
> El script oficial contiene en su encabezado las instrucciones:
> ```sql
> DROP DATABASE IF EXISTS chinook_serial;
> CREATE DATABASE chinook_serial;
> \c chinook_serial;
> ```
> Por tanto:
> 1. **Elimina y recrea** por completo la base de datos `chinook_serial` si ya existía. No lo ejecute sobre datos que deba conservar.
> 2. Incluye la metaorden `\c chinook_serial;` propia de `psql`. Si utiliza el contenedor del repositorio, impórtelo desde terminal con `psql` para que se ejecute sin errores de sintaxis.

---

## 3. Instalación e importación paso a paso

1. Copie `.env.example` a `.env` y defina credenciales locales de práctica (nunca suba `.env` al repositorio):
   ```bash
   cp .env.example .env
   ```
2. Levante el contenedor de PostgreSQL 18:
   ```bash
   docker compose up -d
   ```
3. Importe el script oficial `Chinook_PostgreSql_SerialPKs.sql` dentro del contenedor (sustituya `<USUARIO>` por el definido en su `.env`):
   ```bash
   docker exec -i pg18_chinook_s17 psql -U <USUARIO> -d postgres -f /workspace/Chinook_PostgreSql_SerialPKs.sql
   ```
4. Verifique la versión del motor y el conteo base:
   ```sql
   SELECT version(), current_database(), COUNT(*) AS total_canciones FROM track;
   ```
   *(Resultado esperado: `PostgreSQL 18.6 ...`, `chinook_serial`, `total_canciones = 3503`).*

---

## 4. Configuración de Conexiones A y B, Autocommit y Aislamiento en DataGrip

1. **Abrir dos sesiones independientes (A y B)**:
   * En las propiedades del Data Source en DataGrip (*Options -> Single session mode*), asegúrese de que **Single session mode** esté **desmarcada** (valor por defecto) para que cada pestaña abra su propio backend en PostgreSQL.
   * Abra dos consolas apuntando a **`chinook_serial.public`**: **`Sesion_A`** (Operador Transaccional) y **`Sesion_B`** (Observador Externo).
   * En las pruebas ejecutadas, `pg_stat_activity` confirmó dos procesos backend independientes: **`PID 150`** (`Sesion_A`) y **`PID 152`** (`Sesion_B`).
2. **Modo de Autocommit (`Tx: Auto`)**:
   * En DataGrip, ambas consolas operan en modo **`Tx: Auto`** (autocommit activo por defecto fuera de bloques explícitos). Al ejecutar `BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;`, PostgreSQL inicia un bloque transaccional explícito y **suspende la confirmación automática** hasta encontrar `COMMIT;` o `ROLLBACK;`.
3. **Nivel de aislamiento (`Read Committed`)**:
   * Todas las transacciones se abren con `BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;`. Bajo este nivel, cada sentencia `SELECT` de la **Sesión B** lee una instantánea consistente de los datos ya confirmados al inicio de la consulta, impidiendo lecturas sucias (*Dirty Reads*).

---

## 5. Obtención dinámica de claves y manejo de errores en el cliente

1. **Sin `MAX(id) + 1` ni IDs adivinados**:
   * Cada inserción de cabecera en `invoice` emplea `RETURNING invoice_id, ...` para recuperar la clave primaria generada por `invoice_invoice_id_seq`.
   * Las inserciones de detalle y actualizaciones dentro de la misma **Sesión A** referencian esa clave con `currval(pg_get_serial_sequence('invoice', 'invoice_id'))`.
   * La **Sesión B** consulta `(SELECT last_value FROM invoice_invoice_id_seq)` para verificar visibilidad de la transacción en curso sin depender de valores escritos manualmente.
2. **Bloques de recuperación cuando el cliente detiene el script al primer error**:
   * En **`02_rollback_total.sql`**: al fallar el `INSERT` con `track_id = 999999` (`ERROR 23503: invoice_line_track_id_fkey`), la transacción entra en **estado abortado** (`25P02`). Ejecute inmediatamente el **PASO 2.5** (`ROLLBACK;` y `SELECT` de comprobación).
   * En **`03_savepoint.sql`**: al fallar el `INSERT` con `track_id = 888888` (`ERROR 23503: invoice_line_track_id_fkey`), ejecute inmediatamente el **PASO 3.4** (`ROLLBACK TO SAVEPOINT sp_antes_detalle_riesgo;`, inserción del detalle corregido `track_id = 7`, `RELEASE SAVEPOINT`, recálculo de total y `COMMIT;`).

---

## 6. Orden de ejecución y resultados verificados

1. **Verificación de sesión y conexiones independientes**:
   * Ejecutar `PASO 1.1` en `Sesion_A` (`PID 150`, `read committed`) y `PASO 4.1` en `Sesion_B` (`pg_stat_activity` mostrando `PID 150` y `PID 152`).
2. **Escenario 1 (`01_venta_exitosa.sql`)**:
   * `Sesion_A` abre transacción, inserta factura **`413`** con `RETURNING`, inserta 3 detalles (`2241..2243` para `track_id` 1, 2, 3), calcula `total = 5.94`, valida `coincide_exactamente = true`, confirma con `COMMIT;` y verifica desde `Sesion_B`.
3. **Escenario 2 (`02_rollback_total.sql`)**:
   * `Sesion_A` comprueba `track_id = 999999` (`0` filas), inicia venta **`414`** con 1 detalle válido (`2244`, `track_id = 4`), provoca error real FK `[23503]`, ejecuta `ROLLBACK;` y comprueba `cabeceras_encontradas = 0` y `detalles_encontrados = 0` para `414`.
4. **Escenario 3 (`03_savepoint.sql`)**:
   * `Sesion_A` inicia venta **`415`**, inserta 2 detalles válidos (`2246` y `2247`, `track_id` 5 y 6), crea `SAVEPOINT sp_antes_detalle_riesgo`, falla con `track_id = 888888` (`[23503]`), ejecuta `ROLLBACK TO SAVEPOINT`, inserta detalle corregido `track_id = 7` (`2249`), libera el punto, recalcula `total = 4.95` y confirma con `COMMIT`.
5. **Escenario 4 y Auditoría de Secuencias (`04_validaciones.sql`)**:
   * `Sesion_A` inicia venta **`416`** (`total_pendiente = 2.97`) sin `COMMIT`; `Sesion_B` consulta antes del `COMMIT` (`cabeceras_visibles_en_b = 0`, `detalles_visibles_en_b = 0`), `Sesion_A` ejecuta `COMMIT;` y `Sesion_B` repite la consulta (`cabeceras_visibles_en_b = 1`, `detalles_visibles_en_b = 3`, `total_visible_en_b = 2.97`).
   * Auditoría final (`PASO 4.3` y `PASO 4.4`) demuestra los huecos de secuencia en `invoice` (`414`) y en `invoice_line` (`2244`, `2245` y `2248`).

---

## 7. Cómo reiniciar la base a su estado original para repetir las pruebas

```sql
BEGIN;
DELETE FROM invoice_line
WHERE invoice_id > 412
   OR invoice_id IN (SELECT invoice_id FROM invoice WHERE billing_address LIKE '%[S17-%');

DELETE FROM invoice
WHERE invoice_id > 412
   OR billing_address LIKE '%[S17-%';

SELECT setval('invoice_invoice_id_seq', (SELECT MAX(invoice_id) FROM invoice));
SELECT setval('invoice_line_invoice_line_id_seq', (SELECT MAX(invoice_line_id) FROM invoice_line));
COMMIT;
```
