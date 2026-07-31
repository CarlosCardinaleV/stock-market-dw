-- DW Bursátil
-- ETL (STAGE -> STAR SCHEMA)

-- Poblar DIM_DATE con generador de fechas (CONNECT BY)
-- Cubre el rango completo presente en el staging.
INSERT INTO DIM_DATE (DATE_KEY, FULL_DATE, DAY_OF_MONTH, DAY_NAME, DAY_OF_WEEK,
    WEEK_OF_YEAR, MONTH_NUM, MONTH_NAME, QUARTER_NUM, YEAR_NUM,
    IS_MONTH_END, IS_YEAR_END)
WITH LIMITES AS (
    SELECT
        MIN(TRADE_DATE) AS FECHA_MIN,
        MAX(TRADE_DATE) AS FECHA_MAX
    FROM
        STG_DAILY_PRICES
),
CALENDARIO AS (
    SELECT
        FECHA_MIN + LEVEL - 1 AS D
    FROM
        LIMITES
    CONNECT BY FECHA_MIN + LEVEL - 1 <= FECHA_MAX
)
SELECT
    TO_NUMBER(TO_CHAR(D, 'YYYYMMDD')) AS DATE_KEY,
    D AS FULL_DATE,
    EXTRACT(DAY FROM D) AS DAY_OF_MONTH,
    TO_CHAR(D, 'Day', 'NLS_DATE_LANGUAGE=SPANISH') AS DAY_NAME,
    TO_NUMBER(TO_CHAR(D, 'D')) AS DAY_OF_WEEK,
    TO_NUMBER(TO_CHAR(D, 'IW')) AS WEEK_OF_YEAR,
    EXTRACT(MONTH FROM D) AS MONTH_NUM,
    TO_CHAR(D, 'Month', 'NLS_DATE_LANGUAGE=SPANISH') AS MONTH_NAME,
    TO_NUMBER(TO_CHAR(D, 'Q')) AS QUARTER_NUM,
    EXTRACT(YEAR FROM D) AS YEAR_NUM,
    CASE WHEN D = LAST_DAY(D) THEN 'Y' ELSE 'N' END AS IS_MONTH_END,
    CASE WHEN TO_CHAR(D,'MMDD') = '1231' THEN 'Y' ELSE 'N' END AS IS_YEAR_END
FROM
    CALENDARIO C
WHERE
    NOT EXISTS (SELECT 1 FROM DIM_DATE D2
        WHERE D2.DATE_KEY = TO_NUMBER(TO_CHAR(C.D, 'YYYYMMDD')));
COMMIT;

-- Poblar DIM_COMPANY con MERGE (lógica SCD Tipo 2)
--     Fuente: OVERVIEW enriquecido con la sub-industria GICS
--     de la lista del S&P 500.
--     primer paso: expirar la versión vigente si cambió algún
--             atributo rastreado (SECTOR, INDUSTRY, NAME).
--     segundo paso: insertar la nueva versión (o la inicial).

-- primer paso: cerrar versiones cuyo contenido cambió en la fuente
UPDATE DIM_COMPANY d
SET
    d.VALID_TO = TRUNC(SYSDATE) - 1,
    d.IS_CURRENT = 'N'
WHERE
    d.IS_CURRENT = 'Y'
    AND EXISTS (
        SELECT 1
        FROM
            STG_COMPANY_OVERVIEW o
        WHERE
            o.SYMBOL = d.SYMBOL
            AND (NVL(INITCAP(o.SECTOR),'~')  != NVL(d.SECTOR,'~')
  OR NVL(INITCAP(o.INDUSTRY),'~')     != NVL(d.INDUSTRY,'~')
  OR NVL(INITCAP(o.COMPANY_NAME),'~') != NVL(d.COMPANY_NAME,'~')))
;

-- segundo paso: insertar versiones nuevas (símbolos nuevos o expirados)
INSERT INTO DIM_COMPANY (SYMBOL, COMPANY_NAME, EXCHANGE, SECTOR, INDUSTRY,
    SUB_INDUSTRY, COUNTRY, VALID_FROM, VALID_TO, IS_CURRENT)
SELECT
    o.SYMBOL,
    INITCAP(o.COMPANY_NAME),
    UPPER(o.EXCHANGE),
    INITCAP(o.SECTOR), -- normalización de dominio
    INITCAP(o.INDUSTRY),
    s.GICS_SUB_INDUSTRY,
    NVL(o.COUNTRY, 'USA'),
    CASE WHEN EXISTS (SELECT 1 FROM DIM_COMPANY x
        WHERE x.SYMBOL = o.SYMBOL) THEN TRUNC(SYSDATE) -- nueva versión SCD2
        ELSE DATE '1900-01-01' END, -- carga inicial
    DATE '9999-12-31',
    'Y'
FROM
    STG_COMPANY_OVERVIEW o
    LEFT JOIN STG_SP500_COMPONENTS s ON (s.SYMBOL = o.SYMBOL)
WHERE
    NOT EXISTS (SELECT 1 FROM DIM_COMPANY d
        WHERE d.SYMBOL = o.SYMBOL AND d.IS_CURRENT = 'Y');
COMMIT;


-- Poblar FACT_DAILY_QUOTE — MERGE
--     MERGE en vez de INSERT para que la carga incremental
--     diaria pueda correr sin duplicar filas existentes.
--     Medidas calculadas con SQL Analytics (window functions):
--       - DAILY_RETURN_PCT : LAG
--       - SMA_20 : AVG OVER (ROWS 19 PRECEDING)
--       - VOLATILITY_20 : STDDEV del retorno (20 días)
--     El join a la dimensión usa la versión vigente en la
--     fecha del hecho (rango VALID_FROM / VALID_TO de SCD2).
MERGE INTO FACT_DAILY_QUOTE f
USING (
    WITH BASE AS (
        SELECT
            SYMBOL,
            TRADE_DATE,
            OPEN_PRICE,
            HIGH_PRICE,
            LOW_PRICE,
            CLOSE_PRICE,
            VOLUME,
            (CLOSE_PRICE / NULLIF(LAG(CLOSE_PRICE) OVER (PARTITION BY SYMBOL
                ORDER BY TRADE_DATE), 0) - 1) * 100 AS RET_PCT
        FROM
            STG_DAILY_PRICES),
    ENRIQUECIDO AS (
        SELECT
            b.*,
            AVG(CLOSE_PRICE) OVER (PARTITION BY SYMBOL ORDER BY TRADE_DATE
                ROWS BETWEEN 19 PRECEDING AND CURRENT ROW)  AS SMA_20,
            STDDEV(RET_PCT) OVER (PARTITION BY SYMBOL ORDER BY TRADE_DATE
                ROWS BETWEEN 19 PRECEDING AND CURRENT ROW)  AS VOL_20,
            COUNT(*) OVER (PARTITION BY SYMBOL ORDER BY TRADE_DATE
                ROWS BETWEEN 19 PRECEDING AND CURRENT ROW)  AS N_VENTANA
        FROM
            BASE b
    )
    SELECT
        TO_NUMBER(TO_CHAR(e.TRADE_DATE, 'YYYYMMDD')) AS DATE_KEY,
        c.COMPANY_KEY,
        e.OPEN_PRICE,
        e.HIGH_PRICE,
        e.LOW_PRICE,
        e.CLOSE_PRICE,
        e.VOLUME,
        ROUND(e.CLOSE_PRICE * e.VOLUME, 2) AS TRADED_VALUE,
        ROUND(e.RET_PCT, 4) AS DAILY_RETURN_PCT,
        ROUND(e.HIGH_PRICE - e.LOW_PRICE, 4) AS INTRADAY_RANGE,
        CASE WHEN e.N_VENTANA = 20 THEN ROUND(e.SMA_20, 4) END AS SMA_20,
        CASE WHEN e.N_VENTANA = 20 THEN ROUND(e.VOL_20, 4) END AS VOLATILITY_20
    FROM
        ENRIQUECIDO e
        JOIN DIM_COMPANY c ON c.SYMBOL = e.SYMBOL
            AND e.TRADE_DATE BETWEEN c.VALID_FROM AND c.VALID_TO
) src ON (f.DATE_KEY = src.DATE_KEY AND f.COMPANY_KEY = src.COMPANY_KEY)
WHEN NOT MATCHED THEN INSERT (DATE_KEY, COMPANY_KEY, OPEN_PRICE, HIGH_PRICE, LOW_PRICE, CLOSE_PRICE,
    VOLUME, TRADED_VALUE, DAILY_RETURN_PCT, INTRADAY_RANGE, SMA_20, VOLATILITY_20)
VALUES (src.DATE_KEY, src.COMPANY_KEY, src.OPEN_PRICE, src.HIGH_PRICE, src.LOW_PRICE,
    src.CLOSE_PRICE, src.VOLUME, src.TRADED_VALUE, src.DAILY_RETURN_PCT,
    src.INTRADAY_RANGE, src.SMA_20, src.VOLATILITY_20);
COMMIT;


-- EMA_20 (media móvil exponencial, alfa = 2/21)
--     Cálculo recursivo con WITH recursivo (la EMA depende de
--     su propio valor anterior, no se puede con window simple).
MERGE INTO FACT_DAILY_QUOTE f
USING (
    WITH ORDENADO AS (
        SELECT
            DATE_KEY,
            COMPANY_KEY,
            CLOSE_PRICE,
            ROW_NUMBER() OVER (PARTITION BY COMPANY_KEY
                ORDER BY DATE_KEY) AS RN
        FROM
            FACT_DAILY_QUOTE),
    EMA (COMPANY_KEY, DATE_KEY, RN, EMA_VAL) AS (
        SELECT
            COMPANY_KEY,
            DATE_KEY, RN,
            CLOSE_PRICE
        FROM
            ORDENADO
        WHERE
            RN = 1
        UNION ALL
        SELECT
            o.COMPANY_KEY,
            o.DATE_KEY,
            o.RN,
            (2/21) * o.CLOSE_PRICE + (1 - 2/21) * e.EMA_VAL
        FROM
            ORDENADO o
            JOIN EMA e ON e.COMPANY_KEY = o.COMPANY_KEY
                AND o.RN = e.RN + 1)
    SELECT
        COMPANY_KEY,
        DATE_KEY,
        ROUND(EMA_VAL, 4) AS EMA_VAL
    FROM
        EMA) src ON (f.COMPANY_KEY = src.COMPANY_KEY AND f.DATE_KEY = src.DATE_KEY)
WHEN MATCHED THEN UPDATE SET f.EMA_20 = src.EMA_VAL;
COMMIT;

-- ------------------------------------------------------------
-- Verificación post-carga
-- ------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM STG_DAILY_PRICES) AS FILAS_STAGE,
    (SELECT COUNT(*) FROM FACT_DAILY_QUOTE) AS FILAS_FACT,
    (SELECT COUNT(*) FROM DIM_COMPANY) AS FILAS_DIM_COMPANY,
    (SELECT COUNT(*) FROM DIM_DATE) AS FILAS_DIM_DATE
FROM
    DUAL;






-- para vaciar las tablas manteniendo la forma
-- ALTER TABLE FACT_DAILY_QUOTE DISABLE CONSTRAINT FK_FACT_DATE;
-- ALTER TABLE FACT_DAILY_QUOTE DISABLE CONSTRAINT FK_FACT_COMPANY;

-- TRUNCATE TABLE FACT_DAILY_QUOTE;
-- TRUNCATE TABLE DIM_COMPANY;
-- TRUNCATE TABLE DIM_DATE;

-- reiniciar la identity de DIM_COMPANY
-- ALTER TABLE DIM_COMPANY MODIFY (COMPANY_KEY GENERATED ALWAYS AS IDENTITY (START WITH 1));

-- ALTER TABLE FACT_DAILY_QUOTE ENABLE VALIDATE CONSTRAINT FK_FACT_DATE;
-- ALTER TABLE FACT_DAILY_QUOTE ENABLE VALIDATE CONSTRAINT FK_FACT_COMPANY;