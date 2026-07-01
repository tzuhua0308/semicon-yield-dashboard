-- =====================================================================
-- Fab IT / 良率分析師 面試 SQL 模擬題(5 題)
-- 難度: 入門 → 進階,涵蓋 90% 面試會問的 SQL 情境
-- 資料集: SECOM (1567 lots × 590 sensors × 924K readings)
-- =====================================================================


-- ──────────────────────────────────────────────────────────────────
-- Q1. 上下半年良率比較 + 期對期變化
-- 觀念: EXTRACT(MONTH FROM)、CASE WHEN、CTE + LAG 用 period 排序
-- ──────────────────────────────────────────────────────────────────
WITH halves AS (
    SELECT
        CASE
            WHEN EXTRACT(MONTH FROM measure_time) <= 6 THEN 'H1 2008'
            ELSE 'H2 2008'
        END                                                                    AS period,
        COUNT(*)                                                               AS total_lots,
        ROUND(100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*), 2)  AS yield_pct
    FROM lots
    GROUP BY period
)
SELECT
    period, total_lots, yield_pct,
    yield_pct - LAG(yield_pct) OVER (ORDER BY period)   AS change_pct
FROM halves
ORDER BY period;
-- 預期: H1 377 lots 93.37%,H2 1190 lots 93.36%,change -0.01
-- 業務洞察: 產量翻 3 倍良率幾乎不變 → 製程穩定


-- ──────────────────────────────────────────────────────────────────
-- Q2. 找出 Pass/Fail 樣本平均讀值差距最大的 Top 10 感測器
-- 觀念: AVG FILTER、ABS、CTE 兩階段、alias 只能用於外層 SELECT
-- ──────────────────────────────────────────────────────────────────
WITH stats AS (
    SELECT
        s.sensor_code,
        s.process_step,
        AVG(sd.value) FILTER (WHERE l.is_pass)     AS avg_pass,
        AVG(sd.value) FILTER (WHERE NOT l.is_pass) AS avg_fail
    FROM sensors s
    JOIN sensor_data sd ON sd.sensor_id = s.sensor_id
    JOIN lots        l  ON l.lot_id     = sd.lot_id
    GROUP BY s.sensor_code, s.process_step
)
SELECT
    sensor_code, process_step,
    ROUND(avg_pass::numeric, 4)                      AS avg_pass,
    ROUND(avg_fail::numeric, 4)                      AS avg_fail,
    ROUND(ABS(avg_pass - avg_fail)::numeric, 4)      AS abs_diff
FROM stats
ORDER BY abs_diff DESC NULLS LAST
LIMIT 10;
-- 預期: S162 Ion Implantation 差距 334.95 居冠
-- 業務洞察: 這 10 顆是 Week 2 ML 特徵選擇的優先候選


-- ──────────────────────────────────────────────────────────────────
-- Q3. 髒批號 Top 10(NULL 比例最高的批號)
-- 觀念: CTE + FILTER、CTE 必須跟 SELECT 一起跑、單位陷阱(50 vs 0.5)
-- ──────────────────────────────────────────────────────────────────
WITH lot_nulls AS (
    SELECT
        lot_id,
        COUNT(*) FILTER (WHERE value IS NULL) AS null_count,
        ROUND(100.0 * COUNT(*) FILTER (WHERE value IS NULL) / COUNT(*), 2) AS null_pct
    FROM sensor_data
    GROUP BY lot_id
)
SELECT
    l.lot_code, l.measure_time, l.pass_fail,
    ln.null_count, ln.null_pct
FROM lot_nulls ln
JOIN lots l ON l.lot_id = ln.lot_id
ORDER BY ln.null_pct DESC
LIMIT 10;
-- 預期: LOT01567 2008-10-17 06:07 有 152 NULL (25.76%);其中 10/16-17 集中 3 批
-- 業務洞察: SECOM 沒有 lot > 50% NULL,資料品質是「感測器級別」問題不是「批號級別」


-- ──────────────────────────────────────────────────────────────────
-- Q4. Yield Excursion 偵測(3 天移動平均連續跌 5% 以上)
-- 觀念: ROWS BETWEEN N PRECEDING、Window Function 不能用於 WHERE、3 層 CTE
-- ──────────────────────────────────────────────────────────────────
WITH daily AS (
    SELECT
        DATE(measure_time)                                                    AS day,
        COUNT(*)                                                              AS lots,
        ROUND(100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*), 2) AS yield_pct
    FROM lots
    GROUP BY DATE(measure_time)
),
rolling AS (
    SELECT
        day, lots, yield_pct,
        ROUND(AVG(yield_pct) OVER (
            ORDER BY day
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        )::numeric, 2) AS rolling_3d
    FROM daily
),
with_lag AS (
    -- 為什麼要多包一層?因為 Window Function 不能用於 WHERE
    -- 先把 LAG 算完存成普通欄位,外層才能篩
    SELECT
        day,
        rolling_3d,
        LAG(rolling_3d) OVER (ORDER BY day) AS prev_rolling_3d
    FROM rolling
)
SELECT
    day                                              AS event_date,
    rolling_3d,
    prev_rolling_3d,
    ROUND((rolling_3d - prev_rolling_3d)::numeric, 2) AS drop_pct
FROM with_lag
WHERE rolling_3d - prev_rolling_3d < -5
ORDER BY day;
-- 預期: 8 個 Yield Excursion 事件日,7 月 4 個(Cascading Yield Loss 級聯崩潰)
-- 業務洞察: 面試官會問「為什麼 7 月集中?」→ 對照 EQ log / PM 排程 / 感測器故障


-- ──────────────────────────────────────────────────────────────────
-- Q5. 每個製程站「變異係數(CV)」最高的 Top 3 感測器(共 36 列)
-- 觀念: STDDEV / AVG = CV、除以 0 保護、ROW_NUMBER + PARTITION BY、NULLS LAST
-- ──────────────────────────────────────────────────────────────────
WITH sensor_cv AS (
    SELECT
        s.sensor_code, s.process_step,
        AVG(sd.value)    AS mean_val,
        STDDEV(sd.value) AS stddev_val,
        CASE
            WHEN ABS(AVG(sd.value)) > 0.001    -- 避免 mean ≈ 0 時 CV 爆炸
            THEN STDDEV(sd.value) / ABS(AVG(sd.value))
            ELSE NULL
        END AS cv
    FROM sensors s
    JOIN sensor_data sd ON s.sensor_id = sd.sensor_id
    GROUP BY s.sensor_code, s.process_step
),
ranked AS (
    SELECT
        sensor_code, process_step,
        ROUND(mean_val::numeric, 4)   AS mean_val,
        ROUND(stddev_val::numeric, 4) AS stddev_val,
        ROUND(cv::numeric, 4)         AS cv,
        ROW_NUMBER() OVER (
            PARTITION BY process_step
            ORDER BY cv DESC NULLS LAST
        ) AS cv_rank
    FROM sensor_cv
    WHERE cv IS NOT NULL
)
SELECT process_step, cv_rank, sensor_code, mean_val, stddev_val, cv
FROM ranked
WHERE cv_rank <= 3
ORDER BY process_step, cv_rank;
-- 預期: 12 站 × 3 = 36 列;Diffusion S103 CV 56.49 領先
-- 業務洞察: Metrology 量測站不穩定 = 決策基礎爛;這 36 顆是保養排程首要對象
