"""
SECOM Yield Dashboard — Phase 1 最小可運作版本

用法:
    cd ~/Desktop/semicon-yield-dashboard
    streamlit run dashboard/app.py
"""

import os
import pandas as pd
import plotly.express as px
import psycopg2
import streamlit as st

DB_URL = os.getenv(
    "SECOM_DB_URL",
    "postgresql://postgres:postgres@localhost:5432/secom",
)


# ─── DB Helper ─────────────────────────────────────────────────────
@st.cache_data(ttl=300, show_spinner=False)
def query(sql: str) -> pd.DataFrame:
    """跑 SQL,回傳 DataFrame。5 分鐘快取。"""
    conn = psycopg2.connect(DB_URL)
    try:
        return pd.read_sql(sql, conn)
    finally:
        conn.close()


# ─── Page Config ───────────────────────────────────────────────────
st.set_page_config(
    page_title="SECOM Yield Dashboard",
    page_icon="🏭",
    layout="wide",
)

st.title("🏭 SECOM Yield Dashboard")
st.caption("半導體製程良率分析平台 · UCI SECOM Dataset")


# ─── Sidebar ───────────────────────────────────────────────────────
with st.sidebar:
    st.header("📌 關於本專案")
    st.markdown(
        "模擬晶圓廠的 **MES / YMS** 良率管理系統。"
        "從 UCI SECOM 製程資料出發,展示資料庫設計、"
        "ETL pipeline 與互動式儀表板。"
    )

    st.divider()
    st.subheader("📊 資料統計")
    db_stats = query("""
        SELECT
            (SELECT COUNT(*) FROM sensors)     AS n_sensors,
            (SELECT COUNT(*) FROM lots)        AS n_lots,
            (SELECT COUNT(*) FROM sensor_data) AS n_readings,
            (SELECT MIN(measure_time)::date FROM lots) AS start_date,
            (SELECT MAX(measure_time)::date FROM lots) AS end_date
    """)
    s = db_stats.iloc[0]
    st.markdown(f"""
- **感測器數**:{int(s['n_sensors']):,}
- **批號數**:{int(s['n_lots']):,}
- **總讀值**:{int(s['n_readings']):,}
- **時間範圍**:{s['start_date']} ~ {s['end_date']}
""")

    st.divider()
    st.subheader("🛠️ 技術棧")
    st.markdown("""
- **DB**: PostgreSQL 16
- **ETL**: Python · pandas · psycopg2
- **Dashboard**: Streamlit · Plotly
- **資料**: [Kaggle SECOM](https://www.kaggle.com/datasets/paresh2047/uci-semcom)
""")

    st.divider()
    st.subheader("🔗 連結")
    st.markdown("""
- [GitHub Repo](https://github.com/tzuhua0308/semicon-yield-dashboard)
- [UCI Source](https://archive.ics.uci.edu/dataset/179/secom)
""")

    st.divider()
    if st.button("🔄 重新整理資料快取", use_container_width=True):
        st.cache_data.clear()
        st.rerun()


# ─── KPIs (overall) ────────────────────────────────────────────────
kpi = query("""
    SELECT
        COUNT(*)                                           AS total_lots,
        SUM(CASE WHEN is_pass THEN 1 ELSE 0 END)           AS pass_lots,
        SUM(CASE WHEN NOT is_pass THEN 1 ELSE 0 END)       AS fail_lots,
        ROUND(
            100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*),
            2
        )                                                  AS yield_pct
    FROM lots;
""")

c1, c2, c3, c4 = st.columns(4)
c1.metric("總批號數",    f"{int(kpi['total_lots'][0]):,}")
c2.metric("良品批",      f"{int(kpi['pass_lots'][0]):,}")
c3.metric("不良批",      f"{int(kpi['fail_lots'][0]):,}")
c4.metric("整體良率",    f"{kpi['yield_pct'][0]}%")

st.divider()


# ─── Tabs ──────────────────────────────────────────────────────────
tab1, tab2, tab3 = st.tabs([
    "📈 良率趨勢",
    "🌡️ 感測器健康度",
    "🔍 批號追蹤",
])


# ═══ Tab 1: Monthly Yield Trend ═══════════════════════════════════
with tab1:
    st.subheader("每月良率與月對月變化")

    monthly = query("""
        WITH m AS (
            SELECT
                TO_CHAR(measure_time, 'YYYY-MM') AS month,
                COUNT(*)                          AS total_lots,
                ROUND(
                    100.0 * SUM(CASE WHEN is_pass THEN 1 ELSE 0 END) / COUNT(*),
                    2
                )                                 AS yield_pct
            FROM lots
            GROUP BY month
        )
        SELECT
            month, total_lots, yield_pct,
            yield_pct - LAG(yield_pct) OVER (ORDER BY month) AS yield_change
        FROM m
        ORDER BY month;
    """)

    fig = px.line(
        monthly, x="month", y="yield_pct",
        markers=True,
        title="月度良率(%)",
        labels={"yield_pct": "良率 %", "month": "月份"},
    )
    fig.add_hline(y=93.36, line_dash="dash", line_color="gray",
                  annotation_text="整體均值 93.36%")
    fig.update_layout(yaxis=dict(range=[80, 105]))
    st.plotly_chart(fig, use_container_width=True)

    # Show table with monthly details
    col1, col2 = st.columns([2, 1])
    with col1:
        st.markdown("**月度資料明細**")
        st.dataframe(monthly, use_container_width=True, hide_index=True)
        st.download_button(
            "⬇️ 下載 CSV", monthly.to_csv(index=False).encode("utf-8"),
            "monthly_yield.csv", "text/csv",
        )
    with col2:
        worst = monthly.loc[monthly["yield_pct"].idxmin()]
        best = monthly.loc[monthly["yield_pct"].idxmax()]
        st.metric("良率最差月", worst["month"], f"{worst['yield_pct']}%")
        st.metric("良率最好月", best["month"], f"{best['yield_pct']}%")


# ═══ Tab 2: Sensor Health ═════════════════════════════════════════
with tab2:
    st.subheader("各製程站平均 NULL 比例(感測器健康度)")

    health = query("""
        WITH per_sensor AS (
            SELECT
                s.sensor_id, s.sensor_code, s.process_step,
                100.0 * COUNT(*) FILTER (WHERE sd.value IS NULL) / COUNT(*) AS null_pct
            FROM sensors s
            JOIN sensor_data sd ON sd.sensor_id = s.sensor_id
            GROUP BY s.sensor_id, s.sensor_code, s.process_step
        )
        SELECT
            process_step,
            ROUND(AVG(null_pct)::numeric, 2) AS avg_null_pct,
            COUNT(*) FILTER (WHERE null_pct > 50) AS unreliable_sensors,
            COUNT(*) AS total_sensors
        FROM per_sensor
        GROUP BY process_step
        ORDER BY avg_null_pct DESC;
    """)

    fig2 = px.bar(
        health, x="process_step", y="avg_null_pct",
        color="avg_null_pct",
        color_continuous_scale="Reds",
        title="平均 NULL 比例(越紅越糟)",
        labels={"avg_null_pct": "平均 NULL %", "process_step": "製程站"},
    )
    st.plotly_chart(fig2, use_container_width=True)

    st.markdown("**🚨 Top 10 最爛感測器**")
    worst10 = query("""
        SELECT
            s.sensor_code, s.process_step,
            ROUND(100.0 * COUNT(*) FILTER (WHERE sd.value IS NULL) / COUNT(*), 2) AS null_pct
        FROM sensors s
        JOIN sensor_data sd ON sd.sensor_id = s.sensor_id
        GROUP BY s.sensor_code, s.process_step
        ORDER BY null_pct DESC
        LIMIT 10;
    """)
    st.dataframe(worst10, use_container_width=True, hide_index=True)
    st.download_button(
        "⬇️ 下載 CSV", worst10.to_csv(index=False).encode("utf-8"),
        "worst10_sensors.csv", "text/csv",
    )


# ═══ Tab 3: Lot Tracker ═══════════════════════════════════════════
with tab3:
    st.subheader("單一批號感測器讀值查詢")

    lots_list = query("""
        SELECT lot_code, measure_time, pass_fail, is_pass
        FROM lots
        ORDER BY lot_code;
    """)
    steps_list = query("SELECT DISTINCT process_step FROM sensors ORDER BY process_step;")

    col1, col2 = st.columns(2)
    with col1:
        chosen_lot = st.selectbox("選擇批號", lots_list["lot_code"].tolist(), index=0)
    with col2:
        chosen_step = st.selectbox(
            "選擇製程站(All = 全部)",
            ["All"] + steps_list["process_step"].tolist(),
        )

    # Lot info badge
    lot_info = lots_list[lots_list["lot_code"] == chosen_lot].iloc[0]
    badge_color = "🟢" if lot_info["is_pass"] else "🔴"
    badge_text = "PASS" if lot_info["is_pass"] else "FAIL"

    c1, c2, c3 = st.columns(3)
    c1.metric("批號", chosen_lot)
    c2.metric("量測時間", str(lot_info["measure_time"]))
    c3.metric("判定結果", f"{badge_color} {badge_text}")

    # Filter readings
    step_filter = "" if chosen_step == "All" else f"AND s.process_step = '{chosen_step}'"
    readings = query(f"""
        SELECT
            s.sensor_code, s.process_step, sd.value
        FROM lots l
        JOIN sensor_data sd ON sd.lot_id = l.lot_id
        JOIN sensors     s  ON s.sensor_id = sd.sensor_id
        WHERE l.lot_code = '{chosen_lot}'
        {step_filter}
        ORDER BY s.sensor_code;
    """)

    st.markdown(f"**讀值清單**({len(readings)} 筆,NULL 顯示為空白)")
    st.dataframe(readings, use_container_width=True, hide_index=True, height=400)
    st.download_button(
        "⬇️ 下載 CSV", readings.to_csv(index=False).encode("utf-8"),
        f"{chosen_lot}_readings.csv", "text/csv",
    )


# ─── Footer ────────────────────────────────────────────────────────
st.divider()
st.caption(
    "Built with 🐍 Python · 🐘 PostgreSQL · 🎈 Streamlit · 📊 Plotly  ·  "
    "Data: [UCI SECOM](https://archive.ics.uci.edu/dataset/179/secom)  ·  "
    "Source: [GitHub](https://github.com/tzuhua0308/semicon-yield-dashboard)"
)
