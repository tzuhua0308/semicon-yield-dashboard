-- =====================================================================
-- SECOM 半導體製程良率分析資料庫 Schema
-- 資料來源: UCI SECOM Dataset (1567 lots × 591 sensors)
-- 設計目的: 模擬晶圓廠 MES/YMS 的資料模型
-- =====================================================================

-- 重跑時清空(開發用,正式環境不要這樣)
DROP VIEW  IF EXISTS v_sensor_stats         CASCADE;
DROP VIEW  IF EXISTS v_yield_by_day         CASCADE;
DROP VIEW  IF EXISTS v_lot_full             CASCADE;
DROP TABLE IF EXISTS sensor_data            CASCADE;
DROP TABLE IF EXISTS lots                   CASCADE;
DROP TABLE IF EXISTS sensors                CASCADE;


-- ---------------------------------------------------------------------
-- Table 1: sensors  (感測器主檔)
-- 對應晶圓廠中每個機台/製程站上的感測器定義
-- ---------------------------------------------------------------------
CREATE TABLE sensors (
    sensor_id      SERIAL       PRIMARY KEY,
    sensor_code    VARCHAR(20)  UNIQUE NOT NULL,   -- 'S001' ~ 'S591'
    sensor_name    VARCHAR(100) NOT NULL,          -- 'Sensor 001'
    process_step   VARCHAR(50)  NOT NULL,          -- 對應的製程站(模擬)
    unit           VARCHAR(20),                    -- 單位(模擬)
    created_at     TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  sensors                IS '感測器主檔,591 顆';
COMMENT ON COLUMN sensors.process_step   IS '所屬製程站(模擬:Photo/Etch/CVD/CMP/Implant/Diffusion 等)';


-- ---------------------------------------------------------------------
-- Table 2: lots  (晶圓批號)
-- 每一筆 = 一個 lot 通過完整製程後的量測結果
-- ---------------------------------------------------------------------
CREATE TABLE lots (
    lot_id         SERIAL       PRIMARY KEY,
    lot_code       VARCHAR(20)  UNIQUE NOT NULL,   -- 'LOT00001'
    measure_time   TIMESTAMP    NOT NULL,          -- SECOM 原始 timestamp
    pass_fail      SMALLINT     NOT NULL           -- -1 = Pass, 1 = Fail (SECOM 原始定義)
                                CHECK (pass_fail IN (-1, 1)),
    is_pass        BOOLEAN      GENERATED ALWAYS AS (pass_fail = -1) STORED,
    created_at     TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  lots             IS '晶圓批號,共 1567 筆';
COMMENT ON COLUMN lots.pass_fail   IS 'SECOM 原始標籤: -1=Pass(良品), 1=Fail(不良)';
COMMENT ON COLUMN lots.is_pass     IS '布林版本,方便 SQL 查詢';


-- ---------------------------------------------------------------------
-- Table 3: sensor_data  (感測器讀值,長表格式)
-- 1567 lots × 591 sensors ≈ 92.6 萬筆
-- ---------------------------------------------------------------------
CREATE TABLE sensor_data (
    id             BIGSERIAL    PRIMARY KEY,
    lot_id         INT          NOT NULL REFERENCES lots(lot_id)    ON DELETE CASCADE,
    sensor_id      INT          NOT NULL REFERENCES sensors(sensor_id) ON DELETE CASCADE,
    value          DOUBLE PRECISION,                                -- NULL = SECOM 的 NaN
    measure_time   TIMESTAMP    NOT NULL,
    UNIQUE (lot_id, sensor_id)
);

COMMENT ON TABLE  sensor_data       IS '感測器讀值(long format),~92 萬筆';
COMMENT ON COLUMN sensor_data.value IS '原始 NaN 存成 NULL';


-- ---------------------------------------------------------------------
-- Indexes  (查詢效能用,Week 1 Day 4 會驗證有/無 index 的差異)
-- ---------------------------------------------------------------------
CREATE INDEX idx_sensor_data_lot     ON sensor_data(lot_id);
CREATE INDEX idx_sensor_data_sensor  ON sensor_data(sensor_id);
CREATE INDEX idx_sensor_data_time    ON sensor_data(measure_time);
CREATE INDEX idx_lots_time           ON lots(measure_time);
CREATE INDEX idx_lots_passfail       ON lots(pass_fail);
CREATE INDEX idx_sensors_step        ON sensors(process_step);


-- ---------------------------------------------------------------------
-- View 1: v_lot_full  (lot + 良率欄位友善版)
-- ---------------------------------------------------------------------
CREATE VIEW v_lot_full AS
SELECT
    lot_id,
    lot_code,
    measure_time,
    pass_fail,
    is_pass,
    CASE WHEN is_pass THEN 'PASS' ELSE 'FAIL' END AS status_label
FROM lots;


-- ---------------------------------------------------------------------
-- View 2: v_yield_by_day  (每日良率)
-- Streamlit dashboard 直接拿來畫趨勢圖
-- ---------------------------------------------------------------------
CREATE VIEW v_yield_by_day AS
SELECT
    DATE(measure_time)                                          AS measure_date,
    COUNT(*)                                                    AS total_lots,
    SUM(CASE WHEN pass_fail = -1 THEN 1 ELSE 0 END)             AS pass_count,
    SUM(CASE WHEN pass_fail =  1 THEN 1 ELSE 0 END)             AS fail_count,
    ROUND(
        100.0 * SUM(CASE WHEN pass_fail = -1 THEN 1 ELSE 0 END) / COUNT(*),
        2
    )                                                           AS yield_pct
FROM lots
GROUP BY DATE(measure_time)
ORDER BY measure_date;


-- ---------------------------------------------------------------------
-- View 3: v_sensor_stats  (每顆感測器在 Pass / Fail 樣本的統計差異)
-- Week 2 ML 特徵分析可直接用
-- ---------------------------------------------------------------------
CREATE VIEW v_sensor_stats AS
SELECT
    s.sensor_code,
    s.process_step,
    COUNT(sd.value)                                             AS n_readings,
    COUNT(*) FILTER (WHERE sd.value IS NULL)                    AS n_nulls,
    ROUND(AVG(sd.value) FILTER (WHERE l.pass_fail = -1)::numeric, 4) AS avg_pass,
    ROUND(AVG(sd.value) FILTER (WHERE l.pass_fail =  1)::numeric, 4) AS avg_fail,
    ROUND(STDDEV(sd.value)::numeric, 4)                         AS std_all
FROM sensors s
LEFT JOIN sensor_data sd ON sd.sensor_id = s.sensor_id
LEFT JOIN lots         l ON l.lot_id     = sd.lot_id
GROUP BY s.sensor_id, s.sensor_code, s.process_step;


-- =====================================================================
-- Done. 下一步: 跑 02_load_data.py 把 SECOM CSV 灌進來
-- =====================================================================
