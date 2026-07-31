-- Stock Market Data Warehouse
-- ETL (STAGE -> STAR SCHEMA)

-- Populate DIM_DATE using a date generator (CONNECT BY)
-- Covers the full range present in the staging area.
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

-- Populate DIM_COMPANY using MERGE (SCD Type 2 logic)
--     Source: OVERVIEW enriched with GICS sub-industry data
--     from the S&P 500 list.
--     Step 1: Expire the current version if any tracked
--             attribute (SECTOR, INDUSTRY, NAME) has changed.
--     Step 2: Insert the new version (or the initial one).

-- Step 1: Close versions where the content has changed in the source
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

-- second step: insert new versions (new or expired symbols)
INSERT INTO DIM_COMPANY (SYMBOL, COMPANY_NAME, EXCHANGE, SECTOR, INDUSTRY,
    SUB_INDUSTRY, COUNTRY, VALID_FROM, VALID_TO, IS_CURRENT)
SELECT
    o.SYMBOL,
    INITCAP(o.COMPANY_NAME),
    UPPER(o.EXCHANGE),
    INITCAP(o.SECTOR),
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


-- Populate FACT_DAILY_QUOTE — MERGE
--     Use MERGE instead of INSERT so that the daily incremental
--     load can run without duplicating existing rows.
--     Metrics calculated using SQL Analytics (window functions):
--       - DAILY_RETURN_PCT : LAG
--       - SMA_20 : AVG OVER (ROWS 19 PRECEDING)
--       - VOLATILITY_20 : STDDEV of the return (20 days)
--     The join to the dimension uses the version active on the
--     fact date (SCD2 VALID_FROM / VALID_TO range).
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


-- EMA_20 (exponential moving average, alpha = 2/21)
--     Recursive calculation using recursive WITH (the EMA depends on
--     its own previous value; a simple window function cannot be used).
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
-- post upload verification
-- ------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM STG_DAILY_PRICES) AS FILAS_STAGE,
    (SELECT COUNT(*) FROM FACT_DAILY_QUOTE) AS FILAS_FACT,
    (SELECT COUNT(*) FROM DIM_COMPANY) AS FILAS_DIM_COMPANY,
    (SELECT COUNT(*) FROM DIM_DATE) AS FILAS_DIM_DATE
FROM
    DUAL;






-- to empty the tables while preserving their structure
-- ALTER TABLE FACT_DAILY_QUOTE DISABLE CONSTRAINT FK_FACT_DATE;
-- ALTER TABLE FACT_DAILY_QUOTE DISABLE CONSTRAINT FK_FACT_COMPANY;

-- TRUNCATE TABLE FACT_DAILY_QUOTE;
-- TRUNCATE TABLE DIM_COMPANY;
-- TRUNCATE TABLE DIM_DATE;

-- restart identity of DIM_COMPANY
-- ALTER TABLE DIM_COMPANY MODIFY (COMPANY_KEY GENERATED ALWAYS AS IDENTITY (START WITH 1));

-- ALTER TABLE FACT_DAILY_QUOTE ENABLE VALIDATE CONSTRAINT FK_FACT_DATE;
-- ALTER TABLE FACT_DAILY_QUOTE ENABLE VALIDATE CONSTRAINT FK_FACT_COMPANY;