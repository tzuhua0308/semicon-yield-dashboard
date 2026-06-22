-- =====================================================================
-- Day 2 SQL 練習 — SECOM 良率分析(8 題)
-- 從 GROUP BY 到 Window Function,涵蓋良率分析師日常 SQL 80%
-- =====================================================================


-- ──────────────────────────────────────────────────────────────────
-- Q1. 每個製程站有幾顆感測器?
-- 觀念:GROUP BY、COUNT、ORDER BY alias
-- ──────────────────────────────────────────────────────────────────
SELECT process_step, COUNT(*) AS sensor_count
FROM sensors
GROUP BY process_step
ORDER BY sensor_count DESC;
-- 預期:12 站,每站 49-50 顆,Photo & Etching 各 50 顆最多


-- ──────────────────────────────────────────────────────────────────
-- Q2. 2008 年 8 月的良率
-- 觀念:WHERE 日期區間、CASE WHEN、100.0 避開整數除法陷阱
-- ──────────────────────────────────────────────────────────────────
SELECT
    COUNT(*)                                                              AS total_lots,
    SUM(CASE WHEN is_pass THEN 1 ELSE 0 END)                              AS pass_lots,
    ROUND(100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*), 2) AS yield_pct
FROM lots
WHERE measure_time >= '2008-08-01'
  AND measure_time <  '2008-09-01';
-- 預期:471 lots / 433 pass / 91.93%


-- ──────────────────────────────────────────────────────────────────
-- Q3. LOT00001 在 Photolithography 站的所有感測器讀值
-- 觀念:三表 JOIN、單引號(字串) vs 雙引號(欄位)
-- ──────────────────────────────────────────────────────────────────
SELECT s.sensor_code, s.process_step, sd.value
FROM lots l
JOIN sensor_data sd ON sd.lot_id    = l.lot_id
JOIN sensors     s  ON s.sensor_id  = sd.sensor_id
WHERE l.lot_code     = 'LOT00001'
  AND s.process_step = 'Photolithography'
ORDER BY s.sensor_code;
-- 預期:50 列(Photo 站 50 顆感測器)


-- ──────────────────────────────────────────────────────────────────
-- Q4. NULL 比例 > 50% 的爛感測器
-- 觀念:子查詢(subquery)、COUNT(*) FILTER、HAVING 不能用 alias
-- ──────────────────────────────────────────────────────────────────
SELECT *
FROM (
    SELECT
        s.sensor_code,
        s.process_step,
        ROUND( 100.0 * COUNT(*) FILTER (WHERE sd.value IS NULL) / COUNT(*), 2 ) AS null_pct
    FROM sensors s
    JOIN sensor_data sd ON s.sensor_id = sd.sensor_id
    GROUP BY s.sensor_code, s.process_step
) t
WHERE null_pct > 50
ORDER BY null_pct DESC;
-- 預期:28 顆爛感測器


-- ──────────────────────────────────────────────────────────────────
-- Q5. NULL > 80% 的爛感測器集中在哪些製程站
-- 觀念:CTE(WITH AS)、LEFT JOIN 保留全部製程站、IS NOT NULL 計數技巧
-- ──────────────────────────────────────────────────────────────────
WITH bad_sensors AS (
    SELECT sensor_id
    FROM sensor_data
    GROUP BY sensor_id
    HAVING COUNT(*) FILTER (WHERE value IS NULL) > COUNT(*) * 0.8
)
SELECT
    s.process_step,
    COUNT(*) FILTER (WHERE b.sensor_id IS NOT NULL) AS bad_sensors,
    COUNT(*)                                        AS total_sensors,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE b.sensor_id IS NOT NULL) / COUNT(*),
        2
    )                                               AS bad_ratio_pct
FROM sensors s
LEFT JOIN bad_sensors b ON b.sensor_id = s.sensor_id
GROUP BY s.process_step
ORDER BY bad_ratio_pct DESC;
-- 預期:12 站全列,CMP & Etching 各 2 顆爛感測器


-- ──────────────────────────────────────────────────────────────────
-- Q6. 每個月的良率
-- 觀念:TO_CHAR 時間格式化、PostgreSQL 允許 GROUP BY 用 alias
-- ──────────────────────────────────────────────────────────────────
SELECT
    TO_CHAR(measure_time, 'YYYY-MM')                                      AS month,
    COUNT(*)                                                              AS total_lots,
    SUM(CASE WHEN is_pass THEN 1 ELSE 0 END)                              AS pass_lots,
    ROUND(100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*), 2) AS yield_pct
FROM lots
GROUP BY month
ORDER BY month;
-- 預期:12 個月,7 月最差 85.96%,12 月最好 100%(但只 34 批)


-- ──────────────────────────────────────────────────────────────────
-- Q7. 每個製程站「最爛」的感測器(Top-N per group)
-- 觀念:Window Function、PARTITION BY、ROW_NUMBER()、CTE 多階段
-- ──────────────────────────────────────────────────────────────────
WITH sensor_nulls AS (
    SELECT
        s.sensor_code,
        s.process_step,
        ROUND( 100.0 * COUNT(*) FILTER (WHERE sd.value IS NULL) / COUNT(*), 2 ) AS null_pct
    FROM sensors s
    JOIN sensor_data sd ON sd.sensor_id = s.sensor_id
    GROUP BY s.sensor_code, s.process_step
),
ranked AS (
    SELECT
        sensor_code,
        process_step,
        null_pct,
        ROW_NUMBER() OVER (PARTITION BY process_step ORDER BY null_pct DESC) AS rank_in_step
    FROM sensor_nulls
)
SELECT process_step, sensor_code, null_pct, rank_in_step
FROM ranked
WHERE rank_in_step = 1
ORDER BY null_pct DESC;
-- 預期:12 列,每站 1 顆冠軍。Etching/CMP/Ion/CVD 4 站並列 91.19%


-- ──────────────────────────────────────────────────────────────────
-- Q8. 月度良率 + 與上月變化(Yield Excursion 偵測)
-- 觀念:Window Function、LAG()、CTE 串接
-- ──────────────────────────────────────────────────────────────────
WITH monthly AS (
    SELECT
        TO_CHAR(measure_time, 'YYYY-MM') AS month,
        ROUND(100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*), 2) AS yield_pct
    FROM lots
    GROUP BY month
)
SELECT
    month,
    yield_pct,
    LAG(yield_pct) OVER (ORDER BY month)                AS prev_month_yield,
    yield_pct - LAG(yield_pct) OVER (ORDER BY month)    AS yield_change
FROM monthly
ORDER BY month;
-- 預期:7 月暴跌 -5.08(Yield Excursion 警報)、8 月反彈 +5.97
