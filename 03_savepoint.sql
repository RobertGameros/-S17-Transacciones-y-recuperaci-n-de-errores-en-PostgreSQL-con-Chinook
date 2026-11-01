-- =============================================================================
-- TAREA [S17]: Transacciones y recuperación de errores en PostgreSQL con Chinook
-- ARCHIVO: 03_savepoint.sql
-- ESCENARIO 3: Recuperación parcial de errores mediante SAVEPOINT
-- MOTOR: PostgreSQL 18 | ESQUEMA: Chinook_PostgreSql_SerialPKs.sql
-- CONEXIÓN: Ejecutar en Consola de SESIÓN A (DataGrip / psql)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 3.1: Verificación previa de cliente, canciones válidas (5, 6, 7) e inválida (888888)
-- Propósito: Comprobar que el cliente 3 (François Tremblay) y las canciones 5,
-- 6 y 7 existen en Chinook, y que track_id = 888888 no existe (conteo = 0).
-- Resultado esperado: 1 fila con cliente_esc3 = 'François Tremblay',
-- canciones_validas_5_6_7 = 3 y existe_track_888888 = 0.
-- -----------------------------------------------------------------------------
SELECT
    pg_backend_pid() AS pid_sesion_a,
    current_setting('transaction_isolation') AS aislamiento_actual,
    (SELECT first_name || ' ' || last_name FROM customer WHERE customer_id = 3) AS cliente_esc3,
    (SELECT COUNT(*) FROM track WHERE track_id IN (5, 6, 7)) AS canciones_validas_5_6_7,
    (SELECT COUNT(*) FROM track WHERE track_id = 888888) AS existe_track_888888;

-- -----------------------------------------------------------------------------
-- PASO 3.2: Inicio de transacción, cabecera, 2 detalles válidos y SAVEPOINT
-- Propósito: Iniciar la tercera venta, insertar su cabecera (que recibirá
-- invoice_id = 415 dejando evidente el hueco del 414 revertido en el Escenario 2),
-- agregar 2 detalles válidos iniciales (track_id 5 y 6) y crear el punto de
-- salvaguarda SAVEPOINT sp_antes_detalle_riesgo antes de la operación riesgosa.
-- Resultado esperado:
--   - Cabecera creada con invoice_id = 415.
--   - 2 detalles válidos insertados (invoice_line_id 2246 y 2247; subtotales 0.99 y 1.98).
--   - SAVEPOINT sp_antes_detalle_riesgo establecido.
-- [EJECUTAR DESDE BEGIN HASTA SAVEPOINT Y TOMAR CAPTURA 12]
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
    c.address || ' [S17-ESC3-SAVEPOINT]',
    c.city,
    c.state,
    c.country,
    c.postal_code,
    0.00::NUMERIC(10,2)
FROM customer c
WHERE c.customer_id = 3
RETURNING
    invoice_id,
    customer_id,
    invoice_date,
    billing_address,
    total;

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
        (5, 1), -- Track 5: Princess of the Dawn  | Cantidad: 1 (previo al SAVEPOINT)
        (6, 2)  -- Track 6: Put The Finger On You | Cantidad: 2 (previo al SAVEPOINT)
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

SAVEPOINT sp_antes_detalle_riesgo;

-- -----------------------------------------------------------------------------
-- PASO 3.3: Operación de riesgo — Provocar error de FK tras el SAVEPOINT
-- Propósito: Intentar insertar un detalle con referencia inválida (track_id = 888888)
-- después de haber creado el SAVEPOINT.
-- Resultado esperado:
--   ERROR [23503]: insert or update on table "invoice_line" violates foreign key
--   constraint "invoice_line_track_id_fkey"
--   Detail: Key (track_id)=(888888) is not present in table "track".
-- [EJECUTAR ESTE INSERT Y TOMAR CAPTURA 13 DEL ERROR]
-- -----------------------------------------------------------------------------
INSERT INTO invoice_line (
    invoice_id,
    track_id,
    unit_price,
    quantity
)
VALUES (
    currval(pg_get_serial_sequence('invoice', 'invoice_id')),
    888888,
    0.99::NUMERIC(10,2),
    1
);

-- =============================================================================
-- BLOQUE DE RECUPERACIÓN PARCIAL CON SAVEPOINT
-- (Ejecutar inmediatamente después de capturar el error del PASO 3.3)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 3.4: Recuperación con ROLLBACK TO SAVEPOINT, detalle corregido, recálculo y COMMIT
-- Propósito:
--   1) Ejecutar ROLLBACK TO SAVEPOINT sp_antes_detalle_riesgo para limpiar el
--      estado de error y deshacer únicamente el intento fallido (conservando la
--      cabecera 415 y los detalles de track_id 5 y 6).
--   2) Insertar el tercer detalle corregido con una canción válida (track_id = 7, cant = 2).
--   3) Ejecutar RELEASE SAVEPOINT sp_antes_detalle_riesgo (que libera el marcador
--      interno sin confirmar aún la transacción global; NO equivale a COMMIT).
--   4) Recalcular el total sumando los 3 detalles válidos (0.99 + 1.98 + 1.98 = 4.95).
--   5) Confirmar toda la operación con COMMIT y consultar el resultado final.
-- Resultado esperado:
--   - 3 detalles confirmados (tracks 5, 6 y 7; track 888888 ausente; hueco en
--     invoice_line_id = 2248 entre 2247 y 2249).
--   - total_factura = 4.95 coincidente con la suma de los 3 subtotales.
-- [EJECUTAR TODO ESTE BLOQUE DESDE ROLLBACK TO SAVEPOINT HASTA EL SELECT FINAL Y TOMAR CAPTURA 14]
-- -----------------------------------------------------------------------------
ROLLBACK TO SAVEPOINT sp_antes_detalle_riesgo;

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
    2
FROM track t
WHERE t.track_id = 7
RETURNING
    invoice_line_id,
    invoice_id,
    track_id,
    unit_price,
    quantity,
    (unit_price * quantity)::NUMERIC(10,2) AS subtotal;

RELEASE SAVEPOINT sp_antes_detalle_riesgo;

UPDATE invoice i
SET total = (
    SELECT COALESCE(SUM(il.unit_price * il.quantity), 0.00)::NUMERIC(10,2)
    FROM invoice_line il
    WHERE il.invoice_id = i.invoice_id
)
WHERE i.invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'));

COMMIT;

SELECT
    i.invoice_id,
    i.total AS total_factura,
    il.invoice_line_id,
    il.track_id,
    t.name AS cancion,
    il.unit_price,
    il.quantity,
    (il.unit_price * il.quantity)::NUMERIC(10,2) AS subtotal,
    CASE
        WHEN il.track_id IN (5, 6) THEN 'Conservado (previo al SAVEPOINT)'
        WHEN il.track_id = 7 THEN 'Corregido (después de ROLLBACK TO SAVEPOINT)'
        ELSE 'Otro'
    END AS estado_detalle
FROM invoice i
JOIN invoice_line il ON il.invoice_id = i.invoice_id
JOIN track t ON t.track_id = il.track_id
WHERE i.invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'))
ORDER BY il.invoice_line_id;
