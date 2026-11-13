-- =============================================================================
-- TAREA [S17]: Transacciones y recuperación de errores en PostgreSQL con Chinook
-- ARCHIVO: 04_validaciones.sql
-- ESCENARIO 4: Visibilidad entre sesiones (Sesión A vs Sesión B) y auditoría final
-- MOTOR: PostgreSQL 18 (18.6) | ESQUEMA: Chinook_PostgreSql_SerialPKs.sql
-- BASE DE DATOS: chinook_serial
-- CONEXIÓN PRINCIPAL: Ejecutar consultas de observación en SESIÓN B
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 4.1: Demostración de conexiones independientes (Sesión A vs Sesión B)
-- Conexión: SESIÓN B
-- Propósito: Mostrar en pg_stat_activity las conexiones abiertas sobre la base
-- chinook_serial para comprobar que Sesión A y Sesión B poseen identificadores
-- de proceso backend (PID) independientes y operan en aislamiento Read Committed.
-- Resultado esperado: Al menos 2 filas con distintos PID (ej. PID 150 para
-- SESIÓN A y PID 152 para SESIÓN B), ambos en nivel 'read committed'.
-- -----------------------------------------------------------------------------
SELECT
    pid,
    CASE
        WHEN pid = pg_backend_pid() THEN 'SESIÓN B (Observador Externo - Esta consola)'
        ELSE 'SESIÓN A (Operador Transaccional - Otra consola)'
    END AS rol_conexion,
    usename AS usuario,
    datname AS base_datos,
    current_setting('transaction_isolation') AS aislamiento,
    state AS estado_actual
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
ORDER BY backend_start;

-- -----------------------------------------------------------------------------
-- PASO 4.2A: Operación pendiente en SESIÓN A para prueba dedicada de visibilidad
-- Conexión: SESIÓN A (ejecutar hasta UPDATE ... RETURNING SIN hacer COMMIT aún)
-- Propósito: Abrir una transacción explícita en modo READ COMMITTED e insertar
-- una factura (invoice_id = 416) con 3 detalles (tracks 8, 9 y 10) para el
-- cliente 4 (Bjørn Hansen), calculando su total dinámicamente (2.97).
-- Resultado esperado: invoice_id = 416, total_pendiente = 2.97 (aún sin COMMIT).
-- -----------------------------------------------------------------------------
/*
-- >>> EJECUTAR ESTE BLOQUE EN SESIÓN A (SIN COMMIT TODAVÍA):
BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;

INSERT INTO invoice (
    customer_id,
    invoice_date,
    billing_address,
    billing_city,
    billing_state,
    billing_country,
    billing_postal_code,
    total
)
SELECT
    c.customer_id,
    CURRENT_TIMESTAMP,
    c.address || ' [S17-ESC4-VISIBILIDAD]',
    c.city,
    c.state,
    c.country,
    c.postal_code,
    0.00::NUMERIC(10,2)
FROM customer c
WHERE c.customer_id = 4;

INSERT INTO invoice_line (
    invoice_id,
    track_id,
    unit_price,
    quantity
)
SELECT
    currval(pg_get_serial_sequence('invoice', 'invoice_id')),
    t.track_id,
    t.unit_price,
    1
FROM track t
WHERE t.track_id IN (8, 9, 10)
ORDER BY t.track_id;

UPDATE invoice i
SET total = (
    SELECT COALESCE(SUM(il.unit_price * il.quantity), 0.00)::NUMERIC(10,2)
    FROM invoice_line il
    WHERE il.invoice_id = i.invoice_id
)
WHERE i.invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'))
RETURNING invoice_id, customer_id, billing_address, total AS total_pendiente;
*/

-- -----------------------------------------------------------------------------
-- PASO 4.2B: Prueba de visibilidad en SESIÓN B (ANTES y DESPUÉS del COMMIT de A)
-- Conexión: SESIÓN B
-- Propósito: Consultar desde la Sesión B la factura pendiente en Sesión A
-- (identificada dinámicamente mediante invoice_invoice_id_seq.last_value,
-- o bien verificando también la factura 413 del Escenario 1).
-- Resultado esperado:
--   * Ejecución 1 (ANTES de ejecutar COMMIT en Sesión A):
--       cabeceras_visibles_en_b = 0, detalles_visibles_en_b = 0,
--       total_visible_en_b = NULL.
--       Demuestra que Read Committed impide lecturas sucias (Dirty Reads).
--   * Luego ejecutar COMMIT; en SESIÓN A y repetir esta misma consulta:
--   * Ejecución 2 (DESPUÉS de ejecutar COMMIT en Sesión A):
--       cabeceras_visibles_en_b = 1, detalles_visibles_en_b = 3,
--       total_visible_en_b = 2.97 (o 5.94 si se consulta en Escenario 1).
--       Demuestra que los cambios confirmados son visibles inmediatamente en B.
-- -----------------------------------------------------------------------------
SELECT
    pg_backend_pid() AS pid_sesion_b,
    current_setting('transaction_isolation') AS aislamiento_sesion_b,
    (SELECT last_value FROM invoice_invoice_id_seq) AS invoice_id_consultado,
    (SELECT COUNT(*) FROM invoice WHERE invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)) AS cabeceras_visibles_en_b,
    (SELECT COUNT(*) FROM invoice_line WHERE invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)) AS detalles_visibles_en_b,
    (SELECT total FROM invoice WHERE invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)) AS total_visible_en_b;

-- Propósito: Desglose detallado de cabecera y líneas visibles desde Sesión B
-- una vez ejecutado el COMMIT en Sesión A.
-- Resultado esperado: 3 filas con los detalles de la factura confirmada.
SELECT
    i.invoice_id,
    i.billing_address,
    i.total AS total_cabecera,
    il.invoice_line_id,
    il.track_id,
    t.name AS cancion,
    il.unit_price,
    il.quantity,
    (il.unit_price * il.quantity)::NUMERIC(10,2) AS subtotal
FROM invoice i
JOIN invoice_line il ON il.invoice_id = i.invoice_id
JOIN track t ON t.track_id = il.track_id
WHERE i.invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)
ORDER BY il.invoice_line_id;

-- =============================================================================
-- AUDITORÍA FINAL DE ESCENARIOS 1, 2, 3, 4 Y HUECOS DE SECUENCIAS
-- Conexión: SESIÓN B (ejecutar al finalizar todos los escenarios)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 4.3: Auditoría de facturas y hueco en la secuencia invoice_invoice_id_seq
-- Propósito: Comparar todos los IDs generados por la secuencia desde 413 hasta
-- last_value contra la tabla invoice, evidenciando las ventas confirmadas y el
-- hueco en el ID 414 provocado por el ROLLBACK del Escenario 2.
-- Resultado esperado:
--   - 413: CONFIRMADO EN TABLA (COMMIT) | 3 detalles | total 5.94
--   - 414: HUECO EN SECUENCIA (Revertido con ROLLBACK en Escenario 2) | 0 detalles
--   - 415: CONFIRMADO EN TABLA (COMMIT) | 3 detalles | total 4.95
--   - 416: CONFIRMADO EN TABLA (COMMIT) | 3 detalles | total 2.97
-- -----------------------------------------------------------------------------
SELECT
    s.id_secuencia AS invoice_id_generado,
    i.customer_id,
    i.billing_address,
    i.total AS total_cabecera,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COALESCE(SUM(il.unit_price * il.quantity), 0.00)::NUMERIC(10,2) AS suma_detalles,
    CASE
        WHEN i.invoice_id IS NOT NULL THEN 'CONFIRMADO EN TABLA (COMMIT)'
        ELSE 'HUECO EN SECUENCIA (Revertido con ROLLBACK en Escenario 2)'
    END AS estado_transaccional
FROM generate_series(413, GREATEST((SELECT last_value FROM invoice_invoice_id_seq), 415)) AS s(id_secuencia)
LEFT JOIN invoice i ON i.invoice_id = s.id_secuencia
LEFT JOIN invoice_line il ON il.invoice_id = i.invoice_id
GROUP BY s.id_secuencia, i.invoice_id, i.customer_id, i.billing_address, i.total
ORDER BY s.id_secuencia;

-- -----------------------------------------------------------------------------
-- PASO 4.4: Auditoría de huecos en la secuencia invoice_line_invoice_line_id_seq
-- Propósito: Inspeccionar todos los valores consumidos de la secuencia de
-- detalles desde 2241 hasta last_value, evidenciando los IDs confirmados y los
-- huecos dejados por el ROLLBACK total (Escenario 2: 2244 y 2245) y por el
-- ROLLBACK TO SAVEPOINT (Escenario 3: 2248).
-- Resultado esperado:
--   - 2241..2243: CONFIRMADO (invoice_id = 413)
--   - 2244..2245: HUECO EN SECUENCIA (Escenario 2 - detalle válido + intento FK)
--   - 2246..2247: CONFIRMADO (invoice_id = 415, previos al SAVEPOINT)
--   - 2248:       HUECO EN SECUENCIA (Escenario 3 - intento FK 888888 descartado)
--   - 2249:       CONFIRMADO (invoice_id = 415, detalle corregido post-SAVEPOINT)
--   - 2250..2252: CONFIRMADO (invoice_id = 416, prueba de visibilidad)
-- -----------------------------------------------------------------------------
SELECT
    s.line_id AS invoice_line_id_secuencia,
    il.invoice_id,
    il.track_id,
    il.unit_price,
    il.quantity,
    CASE
        WHEN il.invoice_line_id IS NOT NULL THEN 'CONFIRMADO (invoice_id = ' || il.invoice_id || ')'
        ELSE 'HUECO EN SECUENCIA (Descartado por ROLLBACK o ROLLBACK TO SAVEPOINT)'
    END AS estado_en_invoice_line
FROM generate_series(2241, GREATEST((SELECT last_value FROM invoice_line_invoice_line_id_seq), 2249)) AS s(line_id)
LEFT JOIN invoice_line il ON il.invoice_line_id = s.line_id
ORDER BY s.line_id;
