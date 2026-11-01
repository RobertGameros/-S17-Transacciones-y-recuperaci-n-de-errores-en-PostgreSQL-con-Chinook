-- =============================================================================
-- TAREA [S17]: Transacciones y recuperación de errores en PostgreSQL con Chinook
-- ARCHIVO: 01_venta_exitosa.sql
-- ESCENARIO 1: Venta atómica exitosa (integrado con Escenario 4: Visibilidad)
-- MOTOR: PostgreSQL 18 | ESQUEMA: Chinook_PostgreSql_SerialPKs.sql
-- CONEXIÓN: Ejecutar en Consola de SESIÓN A (DataGrip / psql)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 1.1: Identificación de la Sesión A, nivel de aislamiento y precondiciones
-- Propósito: Documentar el identificador de proceso (PID) de la Sesión A, el
-- nivel de aislamiento activo (Read Committed) y comprobar que el cliente
-- (customer_id = 1) y las 3 canciones (track_id 1, 2 y 3) existen en Chinook.
-- Resultado esperado: 1 fila con pid_sesion_a, aislamiento 'read committed',
-- existencia confirmada del cliente 1 y las 3 canciones con unit_price = 0.99.
-- [EJECUTAR ESTE BLOQUE Y TOMAR CAPTURA 1 - SESIÓN A]
-- -----------------------------------------------------------------------------
SELECT
    pg_backend_pid() AS pid_sesion_a,
    current_database() AS base_datos,
    current_user AS usuario,
    current_setting('transaction_isolation') AS aislamiento_actual,
    (SELECT first_name || ' ' || last_name FROM customer WHERE customer_id = 1) AS cliente_esc1,
    (SELECT COUNT(*) FROM track WHERE track_id IN (1, 2, 3)) AS canciones_validas_encontradas,
    now() AS fecha_hora_inicio;

-- -----------------------------------------------------------------------------
-- PASO 1.2: Inicio de transacción explícita e inserción de cabecera con RETURNING
-- Propósito: Abrir explícitamente la transacción en modo READ COMMITTED e
-- insertar una nueva factura para customer_id = 1 con total inicial 0.00,
-- recuperando su clave primaria generada por la secuencia mediante RETURNING.
-- Resultado esperado: 1 fila devuelta con el nuevo invoice_id (413 en copia limpia).
-- [EJECUTAR DESDE BEGIN HASTA RETURNING Y TOMAR CAPTURA 2]
-- -----------------------------------------------------------------------------
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
    c.address || ' [S17-ESC1]',
    c.city,
    c.state,
    c.country,
    c.postal_code,
    0.00::NUMERIC(10,2)
FROM customer c
WHERE c.customer_id = 1
RETURNING
    invoice_id,
    customer_id,
    invoice_date,
    billing_address,
    total AS total_inicial;

-- -----------------------------------------------------------------------------
-- PASO 1.3: Inserción de al menos tres detalles válidos en invoice_line
-- Propósito: Insertar 3 líneas de detalle asociadas al invoice_id recién creado
-- en esta sesión (obtenido dinámicamente con currval de la secuencia oficial
-- sin adivinar IDs ni usar MAX(id)+1), tomando el unit_price real desde track
-- y cantidades positivas (2, 1 y 3 unidades).
-- Resultado esperado: 3 filas insertadas (invoice_line_id 2241, 2242, 2243) con
-- subtotales 1.98, 0.99 y 2.97.
-- [EJECUTAR ESTE INSERT Y TOMAR CAPTURA 3]
-- -----------------------------------------------------------------------------
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
    d.quantity
FROM (
    VALUES
        (1, 2), -- Track 1: For Those About To Rock (We Salute You) | Cantidad: 2
        (2, 1), -- Track 2: Balls to the Wall                       | Cantidad: 1
        (3, 3)  -- Track 3: Fast As a Shark                         | Cantidad: 3
) AS d(track_id, quantity)
JOIN track t ON t.track_id = d.track_id
ORDER BY t.track_id
RETURNING
    invoice_line_id,
    invoice_id,
    track_id,
    unit_price,
    quantity,
    (unit_price * quantity)::NUMERIC(10,2) AS subtotal;

-- -----------------------------------------------------------------------------
-- PASO 1.4: Cálculo dinámico del total y verificación previa al COMMIT
-- Propósito: Actualizar el campo total de la factura calculando la suma exacta
-- de (unit_price * quantity) de sus detalles en invoice_line, y comprobar en la
-- misma consulta que la cantidad de detalles es 3 y que el total coincide.
-- Resultado esperado: 1 fila con invoice_id = 413, cantidad_detalles = 3,
-- total_cabecera = 5.94, suma_detalles = 5.94 y coincide_exactamente = true.
-- [EJECUTAR ESTE BLOQUE (UPDATE + SELECT) Y TOMAR CAPTURA 4]
-- -----------------------------------------------------------------------------
UPDATE invoice i
SET total = (
    SELECT COALESCE(SUM(il.unit_price * il.quantity), 0.00)::NUMERIC(10,2)
    FROM invoice_line il
    WHERE il.invoice_id = i.invoice_id
)
WHERE i.invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'));

SELECT
    i.invoice_id,
    i.customer_id,
    i.billing_address,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    SUM(il.quantity) AS total_unidades,
    i.total AS total_cabecera,
    SUM(il.unit_price * il.quantity)::NUMERIC(10,2) AS suma_detalles,
    (i.total = SUM(il.unit_price * il.quantity)::NUMERIC(10,2)) AS coincide_exactamente
FROM invoice i
JOIN invoice_line il ON il.invoice_id = i.invoice_id
WHERE i.invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'))
GROUP BY i.invoice_id, i.customer_id, i.billing_address, i.total;

-- =============================================================================
-- ¡PAUSA PARA PRUEBA DE VISIBILIDAD (ESCENARIO 4 - ANTES DE COMMIT)!
-- Antes de ejecutar el COMMIT de abajo:
--   1. Cambie a la Consola de SESIÓN B (archivo 04_validaciones.sql).
--   2. Ejecute el PASO 4.1 y PASO 4.2 en SESIÓN B.
--   3. Compruebe que desde SESIÓN B la factura 413 NO ES VISIBLE (0 filas)
--      porque la transacción en SESIÓN A sigue abierta (uncommitted).
--   4. Tome la captura en SESIÓN B y regrese aquí para ejecutar el PASO 1.5.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 1.5: Confirmación definitiva (COMMIT) y consulta final en Sesión A
-- Propósito: Confirmar de manera atómica y durable la venta en la base de datos
-- y mostrar el desglose completo de la factura confirmada.
-- Resultado esperado: Transacción confirmada (COMMIT) y 3 filas de detalle
-- asociadas a la factura con total_factura = 5.94.
-- [EJECUTAR COMMIT + SELECT Y TOMAR CAPTURA 6 (LUEGO IR A SESIÓN B PARA CAPTURA 7)]
-- -----------------------------------------------------------------------------
COMMIT;

SELECT
    i.invoice_id,
    i.customer_id,
    i.billing_address,
    i.total AS total_factura,
    il.invoice_line_id,
    il.track_id,
    t.name AS cancion,
    il.unit_price,
    il.quantity,
    (il.unit_price * il.quantity)::NUMERIC(10,2) AS subtotal
FROM invoice i
JOIN invoice_line il ON il.invoice_id = i.invoice_id
JOIN track t ON t.track_id = il.track_id
WHERE i.invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'))
ORDER BY il.invoice_line_id;
