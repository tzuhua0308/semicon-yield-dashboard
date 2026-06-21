#!/usr/bin/env python3
"""
SECOM ETL — 把 UCI SECOM 資料集灌進 PostgreSQL。

用法:
    # 預設連線 postgresql://postgres:postgres@localhost:5432/secom
    python etl/02_load_data.py

    # 自訂連線
    python etl/02_load_data.py --db-url postgresql://user:pwd@host:5432/dbname

    # 已下載過資料,跳過 Kaggle 下載
    python etl/02_load_data.py --skip-download

預期執行時間: ~30 秒(1567 lots × 591 sensors ≈ 92.6 萬筆)
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from tqdm import tqdm

# ─── Config ────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR     = PROJECT_ROOT / "data"
SECOM_CSV    = DATA_DIR / "uci-secom.csv"   # Kaggle 版本是單一 CSV(1568 行 × 592 欄)

DEFAULT_DB_URL = os.getenv(
    "SECOM_DB_URL",
    "postgresql://postgres:postgres@localhost:5432/secom",
)

# 591 顆感測器假裝分佈在 12 個製程站 → 對應 schema 的 process_step 欄位
PROCESS_STEPS = [
    "Photolithography", "Etching", "CVD", "PVD",
    "CMP", "Ion Implantation", "Diffusion", "Cleaning",
    "Metrology", "Annealing", "Doping", "Inspection",
]
UNITS = ["Celsius", "mTorr", "sccm", "mW", "kV", "rpm", "sec", "ratio"]

BATCH_SIZE = 50_000
PAGE_SIZE  = 10_000


# ─── Steps ─────────────────────────────────────────────────────────────
def download_data() -> None:
    """從 Kaggle 下載 SECOM(已有檔案則跳過)。"""
    if SECOM_CSV.exists():
        print(f"✓ SECOM data already in {DATA_DIR}")
        return

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    print(f"↓ Downloading SECOM via Kaggle CLI → {DATA_DIR}")
    try:
        subprocess.run(
            ["kaggle", "datasets", "download",
             "-d", "paresh2047/uci-semcom",
             "-p", str(DATA_DIR), "--unzip"],
            check=True,
        )
    except FileNotFoundError:
        sys.exit(
            "❌ kaggle CLI 未安裝。請先 `pip install kaggle` 並到 "
            "https://www.kaggle.com/settings 下載 API Token 放到 ~/.kaggle/kaggle.json"
        )
    except subprocess.CalledProcessError as e:
        sys.exit(f"❌ Kaggle 下載失敗: {e}")


def load_secom() -> tuple[pd.DataFrame, pd.DataFrame]:
    """讀 SECOM Kaggle CSV(單一檔)。"""
    print("→ Reading SECOM file...")
    df = pd.read_csv(SECOM_CSV)

    # 第 1 欄 Time、最後 1 欄 Pass/Fail、中間 590 欄是感測器
    y = pd.DataFrame({
        "measure_time": pd.to_datetime(df["Time"]),
        "label":        df["Pass/Fail"].astype(int),
    })
    X = df.drop(columns=["Time", "Pass/Fail"])

    print(f"  X shape: {X.shape}, y shape: {y.shape}")
    return X, y


def insert_sensors(cur, n_sensors: int) -> dict[str, int]:
    """灌 sensors 主檔,回傳 sensor_code → sensor_id。"""
    rows = [
        (
            f"S{i+1:03d}",
            f"Sensor {i+1:03d}",
            PROCESS_STEPS[i % len(PROCESS_STEPS)],
            UNITS[i % len(UNITS)],
        )
        for i in range(n_sensors)
    ]
    result = execute_values(
        cur,
        "INSERT INTO sensors (sensor_code, sensor_name, process_step, unit) "
        "VALUES %s RETURNING sensor_id, sensor_code",
        rows,
        page_size=len(rows),  # 一次塞完,RETURNING 才拿得到全部
        fetch=True,
    )
    mapping = {code: sid for sid, code in result}
    print(f"✓ Inserted {len(mapping)} sensors")
    return mapping


def insert_lots(cur, y: pd.DataFrame) -> dict[str, int]:
    """灌 lots,回傳 lot_code → lot_id。"""
    rows = [
        (f"LOT{i+1:05d}", row.measure_time.to_pydatetime(), int(row.label))
        for i, row in y.iterrows()
    ]
    result = execute_values(
        cur,
        "INSERT INTO lots (lot_code, measure_time, pass_fail) "
        "VALUES %s RETURNING lot_id, lot_code",
        rows,
        page_size=len(rows),
        fetch=True,
    )
    mapping = {code: lid for lid, code in result}
    print(f"✓ Inserted {len(mapping)} lots")
    return mapping


def insert_sensor_data(
    cur,
    X: pd.DataFrame,
    y: pd.DataFrame,
    lot_map: dict[str, int],
    sensor_map: dict[str, int],
) -> None:
    """寬表 → 長表,批次灌進 sensor_data。"""
    n_lots, n_sensors = X.shape
    total = n_lots * n_sensors
    print(f"→ Pivoting to long format ({total:,} cells)...")

    sensor_ids   = np.array([sensor_map[f"S{j+1:03d}"]   for j in range(n_sensors)])
    lot_ids      = np.array([lot_map[f"LOT{i+1:05d}"]    for i in range(n_lots)])
    measure_time = y["measure_time"].to_numpy()

    # 向量化展開(避免 Python for loop)
    lot_id_col    = np.repeat(lot_ids, n_sensors)
    sensor_id_col = np.tile(sensor_ids, n_lots)
    value_col     = X.values.flatten()
    time_col      = np.repeat(measure_time, n_sensors)

    print(f"→ Inserting in batches of {BATCH_SIZE:,}...")
    for start in tqdm(range(0, total, BATCH_SIZE), desc="Batches"):
        end = min(start + BATCH_SIZE, total)
        chunk = [
            (
                int(lot_id_col[k]),
                int(sensor_id_col[k]),
                None if np.isnan(value_col[k]) else float(value_col[k]),
                pd.Timestamp(time_col[k]).to_pydatetime(),
            )
            for k in range(start, end)
        ]
        execute_values(
            cur,
            "INSERT INTO sensor_data (lot_id, sensor_id, value, measure_time) VALUES %s",
            chunk,
            page_size=PAGE_SIZE,
        )
    print(f"✓ Inserted {total:,} sensor_data rows")


def sanity_check(cur) -> None:
    """印出三張表的筆數,確認灌入成功。"""
    print("\n── Sanity check ──")
    for table, expected in [("sensors", 591), ("lots", 1567), ("sensor_data", None)]:
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        n = cur.fetchone()[0]
        tag = f"(expect {expected:,})" if expected else ""
        print(f"  {table:<14} {n:>10,}  {tag}")


# ─── Main ──────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(description="SECOM → PostgreSQL ETL")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL,
                        help="Postgres 連線字串")
    parser.add_argument("--skip-download", action="store_true",
                        help="跳過 Kaggle 下載")
    args = parser.parse_args()

    if not args.skip_download:
        download_data()

    X, y = load_secom()

    safe_url = args.db_url.split("@")[-1]
    print(f"→ Connecting to {safe_url}")
    conn = psycopg2.connect(args.db_url)
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            sensor_map = insert_sensors(cur, n_sensors=X.shape[1])
            lot_map    = insert_lots(cur, y)
            insert_sensor_data(cur, X, y, lot_map, sensor_map)
            sanity_check(cur)
        conn.commit()
        print("\n✅ ETL complete.")
    except Exception:
        conn.rollback()
        print("\n❌ Rolled back — no data inserted.")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
