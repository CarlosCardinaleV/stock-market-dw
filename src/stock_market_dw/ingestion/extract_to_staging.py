"""
extract_to_staging.py
---------------------
Data extraction from 3 sources → CSVs with Oracle-ready column names.
There is no Oracle connection: files are saved in output/ within the project
(or in the path defined by OUTPUT_DIR). The user uploads them manually to Oracle
Cloud using SQL Loader / Data Import Wizard.

Sources:
  1) yfinance — complete OHLCV history with no API key or limits
  2) Alpha Vantage — company metadata (OVERVIEW, free)
  3) Wikipedia — S&P 500 components and GICS classifications

Generated files (columns = Oracle STG table names):
  stg_daily_prices.csv → load into STG_DAILY_PRICES
  stg_company_overview.csv → load into STG_COMPANY_OVERVIEW
  stg_sp500_components.csv → load into STG_SP500_COMPONENTS

Usage:
  python -m stock_market_dw.ingestion.extract_to_staging # full load
"""

import io
import json
import os
import pathlib
import sys
import time
from datetime import date
import pandas as pd
import requests
from dotenv import load_dotenv

load_dotenv()

API_KEY = os.environ.get("ALPHAVANTAGE_KEY", "")
BASE = "https://www.alphavantage.co/query"
PAUSE_SECONDS = 15 # pause between Alpha Vantage calls (free plan limit)

SYMBOLS = [
    "AAPL", "MSFT", "NVDA", "GOOGL", "AMZN", "TSLA", "DIS",
    "JPM", "GS", "JNJ", "PFE", "UNH", "XOM", "CVX", "PG",
    "KO", "WMT", "CAT", "BA", "NEE", "META", "NFLX", "SPCX",
]

_PROJECT_ROOT = pathlib.Path(__file__).parents[3]
RAW_DIR = _PROJECT_ROOT / "raw"
RAW_DIR.mkdir(exist_ok=True)

def _output_dir() -> pathlib.Path:
    directory = (
        pathlib.Path(os.environ["OUTOUT_DIR"])
        if "OUTPUT_DIR" in os.environ
        else _PROJECT_ROOT / "output"
    )
    directory.mkdir(parents=True, exist_ok=True)
    return directory

## Extraction ##

def extract_prices(symbol: str) -> pd.DataFrame:
    """OHLCV history via yfinance with incremental cache updates.
    
    - First run: downloads the complete history and saves it in raw/ .
    - Subsequent runs: checks the latest cache date; if it is outdated,
        requests only new days from yfinance and adds them to the existing file.
    """
    import yfinance as yf

    cache = RAW_DIR/f"prices_{symbol}.csv"

    if cache.exists():
        existing = pd.read_csv(cache)
        last_date = existing["timestamp"].max() # e.g. "2026-06-12"
        today = str(date.today()) # e.g. "2026-06-16"

        if last_date >= today:
            print(f"    {symbol}: cache is up to date ({last_date})")
            return existing

        # Outdated cache - fetch only new days
        # to start to the day immediately after the last date already stored in the cache:
        start = pd.Timestamp(last_date) + pd.Timedelta(days=1)
        print(f"    {symbol}: updating from {start.date()}...", end=" ", flush=True)
        new_history = yf.Ticker(symbol).history(start=start)

        if new_history.empty:
            print("no new data")
            return existing

        new_dataframe = new_history[["Open", "High", "Low", "Close", "Volume"]].copy()
        new_dataframe.index = pd.to_datetime([day.date() for day in new_dataframe.index])
        new_dataframe.index.name = "timestamp"
        new_dataframe = new_dataframe.reset_index()
        new_dataframe.columns = ["timestamp", "open", "high", "low", "close", "volume"]
        new_dataframe["timestamp"] = new_dataframe["timestamp"].astype(str)

        combined = (
            pd.concat([existing, new_dataframe], ignore_index=True)
            .drop_duplicates("timestamp")
            .sort_values("timestamp", ascending=False)
            .reset_index(drop=True)
        )
        combined.to_csv(cache, index=False)
        print(f"+{len(new_dataframe)} new rows (total {len(combined):,})")
        return combined

    # no cache -> full download
    print(f"    {symbol}: full download...", end=" ", flush=True)
    history = yf.Ticker(symbol).history(period="max")
    if history.empty:
        raise RuntimeError(f"{symbol}: yfinance returned no data")

    dataframe = history[["Open", "High", "Low", "Close", "Volume"]].copy()
    dataframe.index = pd.to_datetime([day.date() for day in dataframe.index])
    dataframe.index.name = "timestamp"
    dataframe = dataframe.reset_index()
    dataframe.columns = ["timestamp", "open", "high", "low", "close", "volume"]
    dataframe["timestamp"] = dataframe["timestamp"].astype(str)
    dataframe = dataframe.sort_values("timestamp", ascending=False).reset_index(drop=True)
    dataframe.to_csv(cache, index=False)
    print(f"{len(dataframe):,} rows")
    return dataframe





if __name__ == "__main__":
    print("done")