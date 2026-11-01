-- =============================================================================
-- TAREA [S17]: Transacciones y recuperación de errores en PostgreSQL con Chinook
-- ARCHIVO: 04_validaciones.sql
-- ESCENARIO 4: Visibilidad entre sesiones (Conexión B) y auditoría de secuencias
-- MOTOR: PostgreSQL 18 | ESQUEMA: Chinook_PostgreSql_SerialPKs.sql
-- CONEXIÓN: Ejecutar SIEMPRE en Consola de SESIÓN B (independiente de Sesión A)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 4.1: Demostración de conexiones independientes (Sesión A vs Sesión B)
-- Propósito: Mostrar el PID propio de la Sesión B, su nivel de aislamiento
-- (Read Committed) y listar en pg_stat_activity las conexiones abiertas sobre
-- la base chinook para probar que Sesión A y Sesión B tienen PIDs distintos.
-- Resultado esperado: Al menos 2 filas con PIDs diferentes (una correspondiente
-- a ESTA SESION B y otra correspondiente a la SESION A).
-- [EJECUTAR EN SESIÓN B Y TOMAR CAPTURA 1B - CONEXIONES INDEPENDIENTES]
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
    state AS estado_actual,
    xact_start AS inicio_transaccion_abierta,
    LEFT(query, 70) AS ultima_sentencia
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
ORDER BY backend_start;

-- -----------------------------------------------------------------------------
-- PASO 4.2: Prueba de visibilidad en Sesión B (Ejecutar ANTES y DESPUÉS del COMMIT de A)
-- Propósito: Consultar desde la Sesión B la factura creada por la Sesión A
-- (identificada dinámicamente por el último valor de invoice_invoice_id_seq,
-- que es 413 durante el Escenario 1).
-- Resultado esperado:
--   * Ejecución 1 (ANTES de COMMIT en Sesión A):
--       cabeceras_visibles_en_b = 0, detalles_visibles_en_b = 0, total_visible_en_b = NULL.
--       Demuestra que Read Committed impide lecturas sucias (Dirty Reads).
--   * Ejecución 2 (DESPUÉS de COMMIT en Sesión A):
--       cabeceras_visibles_en_b = 1, detalles_visibles_en_b = 3, total_visible_en_b = 5.94.
--       Demuestra que los datos son visibles inmediatamente tras el COMMIT.
-- [EJECUTAR ANTES DEL COMMIT DE SESIÓN A -> TOMAR CAPTURA 5]
-- [EJECUTAR DESPUÉS DEL COMMIT DE SESIÓN A -> TOMAR CAPTURA 7]
-- -----------------------------------------------------------------------------
SELECT
    pg_backend_pid() AS pid_sesion_b,
    current_setting('transaction_isolation') AS aislamiento_sesion_b,
    (SELECT last_value FROM invoice_invoice_id_seq) AS invoice_id_consultado,
    (SELECT COUNT(*) FROM invoice WHERE invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)) AS cabeceras_visibles_en_b,
    (SELECT COUNT(*) FROM invoice_line WHERE invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)) AS detalles_visibles_en_b,
    (SELECT total FROM invoice WHERE invoice_id = (SELECT last_value FROM invoice_invoice_id_seq)) AS total_visible_en_b;

-- Desglose de líneas visibles desde Sesión B tras el COMMIT de Sesión A:
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
-- AUDITORÍA FINAL DE ESCENARIOS 1, 2, 3 Y HUECOS DE SECUENCIAS
-- (Ejecutar al finalizar los 3 escenarios para evidenciar el estado global)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 4.3: Auditoría de facturas y huecos en la secuencia invoice_invoice_id_seq
-- Propósito: Demostrar que entre el ID 413 (Escenario 1) y el último ID generado
-- (415 en Escenario 3), el ID 414 dejó un HUECO en la tabla invoice debido al
-- ROLLBACK del Escenario 2, ya que las secuencias en PostgreSQL no retroceden.
-- Resultado esperado: 3 filas (413 Confirmado con total 5.94, 414 HUECO por
-- ROLLBACK sin filas, y 415 Confirmado con total 4.95).
-- [EJECUTAR AL FINAL Y TOMAR CAPTURA 15]
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
-- Propósito: Mostrar todos los valores consumidos en la secuencia de detalles
-- desde 2241 hasta el último valor (2249), evidenciando qué IDs pertenecen a
-- detalles confirmados y cuáles quedaron como huecos por el ROLLBACK total
-- (Escenario 2: 2244 y 2245) o por el ROLLBACK TO SAVEPOINT (Escenario 3: 2248).
-- Resultado esperado: Filas 2241..2249 con huecos explícitos en 2244, 2245 y 2248.
-- [EJECUTAR AL FINAL Y TOMAR CAPTURA 16]
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
