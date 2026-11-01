# [S17] Transacciones y recuperación de errores en PostgreSQL con Chinook

Repositorio de práctica para la evaluación **[S17] Transacciones y recuperación de errores en PostgreSQL con Chinook**. Demuestra el control transaccional explícito en **PostgreSQL 18** sobre el esquema oficial `Chinook_PostgreSql_SerialPKs.sql`, abarcando confirmación atómica (`COMMIT`), reversión completa ante violación de integridad referencial (`ROLLBACK`), recuperación parcial con puntos de salvaguarda (`SAVEPOINT` / `ROLLBACK TO SAVEPOINT`) y visibilidad entre sesiones concurrentes bajo el nivel de aislamiento `Read Committed`.

---

## 1. Estructura del repositorio

| Archivo | Propósito |
| :--- | :--- |
| `README.md` | Documentación de entorno, importación, conexiones A/B en DataGrip o `psql`, autocommit, parámetros dinámicos y repetición de pruebas. |
| `Chinook_PostgreSql_SerialPKs.sql` | Script oficial del esquema y datos de **Chinook v1.4.5** con claves primarias `SERIAL` (`lerocha/chinook-database`). |
| `01_venta_exitosa.sql` | **Escenario 1**: Transacción explícita exitosa (`BEGIN ... COMMIT`), inserción de cabecera con `RETURNING`, 3 detalles válidos, cálculo exacto de `total` con `SUM(unit_price * quantity)` y verificación de coherencia. |
| `02_rollback_total.sql` | **Escenario 2**: Transacción con violación real de `FOREIGN KEY` (`invoice_line_track_id_fkey`), demostración del estado abortado (`25P02`), recuperación con `ROLLBACK` y comprobación por la clave específica de que no quedaron datos huérfanos. |
| `03_savepoint.sql` | **Escenario 3**: Transacción con 2 detalles válidos iniciales, `SAVEPOINT`, fallo por referencia inválida (`23503`), recuperación parcial con `ROLLBACK TO SAVEPOINT`, inserción de un 3.er detalle corregido, `RELEASE SAVEPOINT`, recálculo de total y `COMMIT`. |
| `04_validaciones.sql` | **Escenario 4 y Auditoría**: Consultas para la **Sesión B** (independiente de la Sesión A) comprobando visibilidad antes y después del `COMMIT` bajo `Read Committed`, además de auditoría de huecos de secuencias (`invoice_invoice_id_seq` e `invoice_line_invoice_line_id_seq`). |
| `docker-compose.yml` | Configuración opcional de contenedor **PostgreSQL 18** para levantar un entorno aislado reproducible. |
| `.env.example` | Plantilla de variables de entorno sin secretos ni contraseñas reales. |

---

## 2. Entorno, versión y variante de Chinook

* **Motor de Base de Datos**: `PostgreSQL 18.x` (instalación nativa local o contenedor oficial `postgres:18`).
* **Cliente SQL**: **JetBrains DataGrip** (dos consolas independientes `Sesión A` y `Sesión B`) o cliente CLI `psql`. Todos los scripts están escritos en **SQL estándar de PostgreSQL**, por lo que se ejecutan directamente en **DataGrip** sin errores de metaórdenes.
* **Variante del esquema**: Oficial **`Chinook_PostgreSql_SerialPKs.sql`** del repositorio [`lerocha/chinook-database`](https://github.com/lerocha/chinook-database/releases).
* **Tablas utilizadas**:
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
> 1. **Elimina y recrea** por completo la base de datos `chinook_serial` si ya existía. No lo ejecute sobre una instancia donde tenga modificaciones que desee conservar.
> 2. Incluye la metaorden `\c chinook_serial;` propia de `psql`. Si importa desde **DataGrip**, ejecute el script mediante el contenedor con `docker exec -i pg18_chinook_s17 psql -U postgres -d postgres -f /workspace/Chinook_PostgreSql_SerialPKs.sql` (o en `psql` local).

---

## 3. Configuración de Conexiones A y B, Autocommit y Aislamiento en DataGrip

1. **Abrir dos sesiones independientes (A y B)**:
   * En el panel **Database Explorer** de DataGrip, verifique en las propiedades del Data Source (*Options -> Single session mode*) que la casilla **Single session mode** esté **desmarcada** (valor por defecto). Así cada consola abre su propio proceso backend en PostgreSQL (`pg_backend_pid()` diferente).
   * Abra o asocie los scripts `01_venta_exitosa.sql`, `02_rollback_total.sql` y `03_savepoint.sql` a la **Consola 1 (Sesión A — Operador Transaccional)**.
   * Abra o asocie el script `04_validaciones.sql` a una **segunda consola nueva** sobre la misma base `chinook`: **Consola 2 (Sesión B — Observador Externo)**.
2. **Modo de Autocommit (`Tx: Auto` / `Tx: Manual`)**:
   * Con `Tx: Auto` (autocommit activo por defecto en PostgreSQL), toda sentencia ejecutada *fuera* de un bloque transaccional se confirma individualmente. Sin embargo, al ejecutar explícitamente `BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;`, PostgreSQL abre un bloque transaccional explícito y **suspende el autocommit** hasta que se ejecute `COMMIT;` o `ROLLBACK;`.
3. **Nivel de aislamiento (`Read Committed`)**:
   * Todas las transacciones se abren con `BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;`. Bajo este nivel, la **Sesión B** únicamente puede ver datos confirmados (`COMMIT`) antes del inicio de cada consulta `SELECT`, impidiendo lecturas sucias (*Dirty Reads*).

---

## 4. Obtención dinámica de claves y manejo de errores en el cliente

1. **Recuperación de clave primaria sin adivinar IDs ni usar `MAX(id) + 1`**:
   * Cada inserción de cabecera en `invoice` utiliza la cláusula `RETURNING invoice_id, customer_id, invoice_date, billing_address, total;` para devolver y mostrar inmediatamente el identificador generado por la secuencia `invoice_invoice_id_seq`.
   * Las sentencias posteriores dentro de la misma **Sesión A** referencian dicho identificador de forma dinámica mediante `currval(pg_get_serial_sequence('invoice', 'invoice_id'))`, que devuelve el valor exacto recién asignado por `nextval()` en la sesión actual (incluso después de un `ROLLBACK`, ya que las secuencias no son transaccionales).
   * En la **Sesión B** (`04_validaciones.sql`), se consulta dinámicamente `(SELECT last_value FROM invoice_invoice_id_seq)` para verificar la visibilidad de la factura en curso antes y después del `COMMIT` sin adivinar identificadores.
2. **¿Qué bloque de recuperación ejecutar cuando DataGrip detiene el script al primer error?**:
   * En **`02_rollback_total.sql`**: al ejecutar el `INSERT` con `track_id = 999999` (Paso 2.3), PostgreSQL devuelve el error `23503 (invoice_line_track_id_fkey)` y la transacción pasa a **estado abortado** (`25P02`). A continuación, seleccione y ejecute inmediatamente el **BLOQUE DE RECUPERACIÓN POST-ERROR (Paso 2.5)** que ejecuta `ROLLBACK;` y comprueba que para ese `invoice_id` quedaron `0` cabeceras y `0` detalles.
   * En **`03_savepoint.sql`**: al ejecutar el `INSERT` con `track_id = 888888` (Paso 3.3), PostgreSQL devuelve el error `23503 (invoice_line_track_id_fkey)`. A continuación, seleccione y ejecute inmediatamente el **BLOQUE DE RECUPERACIÓN PARCIAL CON SAVEPOINT (Paso 3.4)** que inicia en `ROLLBACK TO SAVEPOINT sp_antes_detalle_riesgo;`, inserta el tercer detalle corregido (`track_id = 7`), libera el savepoint, recalcula el total (`4.95`) y confirma con `COMMIT;`.

---

## 5. Orden de ejecución paso a paso

1. **Escenario 1 y 4 (`01_venta_exitosa.sql` en Sesión A + `04_validaciones.sql` en Sesión B)**:
   * En **Sesión A**, ejecute los **Pasos 1.1, 1.2, 1.3 y 1.4** (crea `invoice_id = 413`, inserta 3 detalles válidos y actualiza `total = 5.94`, deteniéndose **antes** de `COMMIT`).
   * En **Sesión B**, ejecute el **Paso 4.1** (verifica PIDs distintos de A y B) y el **Paso 4.2** -> comprueba que `cabeceras_visibles_en_b = 0` y `detalles_visibles_en_b = 0` mientras A no ha confirmado.
   * En **Sesión A**, ejecute el **Paso 1.5** (`COMMIT;` y consulta de factura confirmada).
   * En **Sesión B**, repita el **Paso 4.2** -> comprueba que ahora `cabeceras_visibles_en_b = 1` (`total = 5.94`) y `detalles_visibles_en_b = 3`.
2. **Escenario 2 (`02_rollback_total.sql` en Sesión A)**:
   * Ejecute los **Pasos 2.1 y 2.2** (crea `invoice_id = 414` y 1 detalle válido con `track_id = 4`).
   * Ejecute el **Paso 2.3** (provoca el error real de FK con `track_id = 999999`) y opcionalmente el **Paso 2.4** (muestra el error de transacción abortada `25P02`).
   * Ejecute el **Paso 2.5** (`ROLLBACK;` y consulta de comprobación que demuestra `0` cabeceras y `0` detalles para `invoice_id = 414`).
3. **Escenario 3 (`03_savepoint.sql` en Sesión A)**:
   * Ejecute los **Pasos 3.1 y 3.2** (crea `invoice_id = 415`, inserta 2 detalles válidos `track_id IN (5, 6)` y crea `SAVEPOINT sp_antes_detalle_riesgo;`).
   * Ejecute el **Paso 3.3** (provoca el error real de FK con `track_id = 888888`).
   * Ejecute el **Paso 3.4** (`ROLLBACK TO SAVEPOINT sp_antes_detalle_riesgo;`, inserta detalle corregido `track_id = 7`, `RELEASE SAVEPOINT`, actualiza `total = 4.95`, `COMMIT;` y verifica los 3 detalles finales).
4. **Auditoría final de huecos de secuencia (`04_validaciones.sql` en Sesión B)**:
   * Ejecute los **Pasos 4.3 y 4.4** para evidenciar las facturas confirmadas (`413` y `415`) y los huecos dejados en las secuencias (`414` en `invoice`; `2244`, `2245` y `2248` en `invoice_line`).

---

## 6. Cómo reiniciar la base a su estado original para repetir las pruebas

Si desea repetir las pruebas desde cero para que los identificadores vuelvan a empezar exactamente en `invoice_id = 413` e `invoice_line_id = 2241`, ejecute en DataGrip:

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
