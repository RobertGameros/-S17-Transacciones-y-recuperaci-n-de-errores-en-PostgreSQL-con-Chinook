-- =============================================================================
-- TAREA [S17]: Transacciones y recuperación de errores en PostgreSQL con Chinook
-- ARCHIVO: 02_rollback_total.sql
-- ESCENARIO 2: Error real de FOREIGN KEY, estado abortado y ROLLBACK completo
-- MOTOR: PostgreSQL 18 | ESQUEMA: Chinook_PostgreSql_SerialPKs.sql
-- CONEXIÓN: Ejecutar en Consola de SESIÓN A (DataGrip / psql)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 2.1: Verificación previa de datos y de inexistencia de track_id = 999999
-- Propósito: Comprobar antes de iniciar la transacción que el cliente 2
-- (Leonie Köhler) y la canción válida (track_id = 4) existen, y demostrar que
-- el identificador de canción elegido para el fallo (track_id = 999999) NO
-- existe en la tabla track (conteo = 0).
-- Resultado esperado: 1 fila con cliente_esc2 = 'Leonie Köhler',
-- cancion_valida_4 = 'Restless and Wild' y existe_track_999999 = 0.
-- [EJECUTAR ESTE SELECT Y TOMAR CAPTURA 8]
-- -----------------------------------------------------------------------------
SELECT
    pg_backend_pid() AS pid_sesion_a,
    current_setting('transaction_isolation') AS aislamiento_actual,
    (SELECT first_name || ' ' || last_name FROM customer WHERE customer_id = 2) AS cliente_esc2,
    (SELECT name FROM track WHERE track_id = 4) AS cancion_valida_track_4,
    (SELECT COUNT(*) FROM track WHERE track_id = 999999) AS existe_track_999999;

-- -----------------------------------------------------------------------------
-- PASO 2.2: Inicio de transacción, creación de cabecera y 1 detalle válido
-- Propósito: Iniciar una nueva venta explícita (diferente del Escenario 1),
-- insertar su cabecera para customer_id = 2 y un primer detalle válido con
-- track_id = 4 (cantidad = 2), mostrando los IDs generados antes del fallo.
-- Resultado esperado: Cabecera temporal creada con invoice_id = 414 y 1 detalle
-- válido creado con invoice_line_id = 2244 (subtotal = 1.98).
-- [EJECUTAR DESDE BEGIN HASTA EL SEGUNDO RETURNING Y TOMAR CAPTURA 9]
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
    c.address || ' [S17-ESC2-ROLLBACK]',
    c.city,
    c.state,
    c.country,
    c.postal_code,
    0.00::NUMERIC(10,2)
FROM customer c
WHERE c.customer_id = 2
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
    2
FROM track t
WHERE t.track_id = 4
RETURNING
    invoice_line_id,
    invoice_id,
    track_id,
    unit_price,
    quantity,
    (unit_price * quantity)::NUMERIC(10,2) AS subtotal;

-- -----------------------------------------------------------------------------
-- PASO 2.3: Provocar violación real de FOREIGN KEY (track_id = 999999)
-- Propósito: Intentar registrar un segundo detalle apuntando a track_id = 999999
-- (inexistente en track) para disparar la restricción de integridad referencial
-- invoice_line_track_id_fkey y dejar la transacción en estado abortado.
-- Resultado esperado:
--   ERROR [23503]: insert or update on table "invoice_line" violates foreign key
--   constraint "invoice_line_track_id_fkey"
--   Detail: Key (track_id)=(999999) is not present in table "track".
-- [EJECUTAR ESTE INSERT Y TOMAR CAPTURA 10 DEL ERROR EN CONSOLA]
-- -----------------------------------------------------------------------------
INSERT INTO invoice_line (
    invoice_id,
    track_id,
    unit_price,
    quantity
)
VALUES (
    currval(pg_get_serial_sequence('invoice', 'invoice_id')),
    999999,
    0.99::NUMERIC(10,2),
    1
);

-- -----------------------------------------------------------------------------
-- PASO 2.4 (Opcional/Demostrativo): Evidenciar el estado abortado (25P02)
-- Propósito: Demostrar que una vez ocurrido el error de FK, PostgreSQL coloca
-- la transacción en estado abortado y rechaza cualquier consulta ordinaria hasta
-- que se ejecute ROLLBACK.
-- Resultado esperado:
--   ERROR [25P02]: current transaction is aborted, commands ignored until end of transaction block
-- -----------------------------------------------------------------------------
SELECT invoice_id, total
FROM invoice
WHERE invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'));

-- =============================================================================
-- BLOQUE DE RECUPERACIÓN POST-ERROR (Ejecutar después de capturar el error)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PASO 2.5: Ejecutar ROLLBACK y demostrar ausencia de cabecera y detalles
-- Propósito: Revertir íntegramente la transacción abortada mediante ROLLBACK y
-- consultar por la clave específica generada en esta venta
-- (currval('invoice_invoice_id_seq'), que conserva el valor 414 en la sesión
-- porque las secuencias no retroceden) para demostrar que no quedaron ni la
-- cabecera ni el primer detalle válido.
-- Resultado esperado:
--   1) ROLLBACK ejecutado exitosamente.
--   2) invoice_id_buscado = 414, cabeceras_encontradas = 0, detalles_encontrados = 0.
-- [EJECUTAR ROLLBACK + SELECT Y TOMAR CAPTURA 11]
-- -----------------------------------------------------------------------------
ROLLBACK;

SELECT
    currval(pg_get_serial_sequence('invoice', 'invoice_id')) AS invoice_id_buscado,
    (SELECT COUNT(*) FROM invoice WHERE invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'))) AS cabeceras_encontradas,
    (SELECT COUNT(*) FROM invoice_line WHERE invoice_id = currval(pg_get_serial_sequence('invoice', 'invoice_id'))) AS detalles_encontrados;
