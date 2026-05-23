#!/usr/bin/env python3
"""
Migrate Home Assistant data from InfluxDB 2.7 to VictoriaMetrics.

Transforms InfluxDB schema (measurement=unit, entity_id tag, field=value)
into Prometheus-compatible metric names matching HA's Prometheus integration:
  homeassistant_sensor_temperature_celsius{entity="sensor.bonn_friesdorf_temperatur"}

Usage:
  python3 migrate-influxdb-to-vm.py [--dry-run] [--start 2025-07-20] [--batch-days 7]

Environment variables:
  INFLUX_URL    InfluxDB URL          (default: http://localhost:8086)
  INFLUX_TOKEN  InfluxDB API token    (default: rescue-tracker-token)
  INFLUX_ORG    InfluxDB org          (default: rescue-org)
  INFLUX_BUCKET InfluxDB bucket       (default: homeassistant)
  VM_URL        VictoriaMetrics URL   (default: http://192.168.4.40:8428)
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.parse
from datetime import datetime, timedelta, timezone

# --- Configuration ---
INFLUX_URL = os.environ.get("INFLUX_URL", "http://localhost:8086")
INFLUX_TOKEN = os.environ.get("INFLUX_TOKEN", "rescue-tracker-token")
INFLUX_ORG = os.environ.get("INFLUX_ORG", "0514db59cd9fcb5b")  # org ID, not name
INFLUX_BUCKET = os.environ.get("INFLUX_BUCKET", "homeassistant")
VM_URL = os.environ.get("VM_URL", "http://192.168.4.40:8428")

# InfluxDB measurement → Prometheus metric name mapping
# HA Prometheus integration naming: homeassistant_{domain}_{device_class}_{unit}
MEASUREMENT_MAP = {
    "°C": "homeassistant_sensor_temperature_celsius",
    "W": "homeassistant_sensor_power_w",
    "kW": "homeassistant_sensor_power_kw",
    "kWh": "homeassistant_sensor_energy_kwh",
    "Wh": "homeassistant_sensor_energy_wh",
    "km": "homeassistant_sensor_distance_km",
    "€": "homeassistant_sensor_unit_u0x20ac",
    "€/d": "homeassistant_sensor_unit_u0x20ac_per_d",
    "%": "homeassistant_sensor_unit_percent",
    "hPa": "homeassistant_sensor_pressure_hpa",
    "km/h": "homeassistant_sensor_unit_km_per_h",
    "W/m²": "homeassistant_sensor_unit_w_per_mu0xb2",
    "mm/h": "homeassistant_sensor_unit_mm_per_h",
    "ppm": "homeassistant_sensor_carbon_dioxide_ppm",
    "lx": "homeassistant_sensor_illuminance_lx",
    "A": "homeassistant_sensor_current_a",
    "V": "homeassistant_sensor_voltage_v",
    "Hz": "homeassistant_sensor_frequency_hz",
    "°": "homeassistant_sensor_unit_u0xb0",
    "L": "homeassistant_sensor_volume_l",
    "dBm": "homeassistant_sensor_signal_strength_dbm",
    "dB": "homeassistant_sensor_signal_strength_db",
    "Celsius": "homeassistant_sensor_measurement_celsius",
    "K": "homeassistant_sensor_unit_k",
    "cm": "homeassistant_sensor_unit_cm",
    "mm": "homeassistant_sensor_distance_mm",
    "m³/s": "homeassistant_sensor_volume_flow_rate_mu0xb3_per_s",
    "m³/h": "homeassistant_sensor_unit_mu0xb3_per_h",
    "m³": "homeassistant_sensor_water_mu0xb3",
    "mL": "homeassistant_sensor_volume_ml",
    "bar": "homeassistant_sensor_unit_bar",
    "imp/min": "homeassistant_sensor_unit_imp_per_min",
    "s": "homeassistant_sensor_unit_s",
}

# Special entity_id overrides for climate entities (different Prometheus metric)
CLIMATE_ENTITIES = {}  # populated dynamically


def flux_query(query):
    """Execute Flux query and return CSV rows."""
    url = f"{INFLUX_URL}/api/v2/query?orgID={INFLUX_ORG}"
    data = query.encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Content-Type": "application/vnd.flux",
            "Accept": "text/csv",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read().decode("utf-8")
    except Exception as e:
        print(f"  ERROR: Flux query failed: {e}", file=sys.stderr)
        return ""


def import_to_vm(lines, dry_run=False, batch_size=50, sleep_seconds=2.0):
    """Import JSONL data to VictoriaMetrics /api/v1/import endpoint.

    Splits into sub-batches of batch_size series to avoid overwhelming VM memory.
    Sleeps between sub-batches to allow merge/flush operations.
    """
    if not lines:
        return 0

    if dry_run:
        payload = "\n".join(lines).encode("utf-8")
        print(f"  [DRY-RUN] Would import {len(lines)} series ({len(payload)} bytes)")
        return len(lines)

    url = f"{VM_URL}/api/v1/import"
    imported = 0

    for i in range(0, len(lines), batch_size):
        chunk = lines[i:i + batch_size]
        payload = "\n".join(chunk).encode("utf-8")
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                resp.read()
            imported += len(chunk)
        except Exception as e:
            print(f"\n  ERROR: VM import failed at sub-batch {i//batch_size}: {e}", file=sys.stderr)
            # Wait longer on error — VM may be under merge pressure
            time.sleep(sleep_seconds * 5)
            # Retry once
            try:
                req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=300) as resp:
                    resp.read()
                imported += len(chunk)
                print(f"  RETRY: sub-batch {i//batch_size} succeeded", file=sys.stderr)
            except Exception as e2:
                print(f"  RETRY FAILED: {e2}", file=sys.stderr)
                return imported

        # Sleep between sub-batches to let VM flush/merge
        if i + batch_size < len(lines):
            time.sleep(sleep_seconds)

    return imported


def migrate_measurement(measurement, vm_metric, start_date, end_date, batch_days, dry_run,
                         batch_size=50, sleep_seconds=2.0):
    """Migrate one InfluxDB measurement to VictoriaMetrics."""
    current = start_date
    total_series = 0
    total_points = 0

    while current < end_date:
        batch_end = min(current + timedelta(days=batch_days), end_date)
        start_str = current.strftime("%Y-%m-%dT%H:%M:%SZ")
        end_str = batch_end.strftime("%Y-%m-%dT%H:%M:%SZ")

        print(f"  {measurement:6s} {start_str[:10]} → {end_str[:10]} ... ", end="", flush=True)

        # Flux: get all value data points for this measurement in the time range
        # Escape measurement for Flux (double quotes)
        meas_escaped = measurement.replace('"', '\\"')
        csv_data = flux_query(f'''
from(bucket: "{INFLUX_BUCKET}")
  |> range(start: {start_str}, stop: {end_str})
  |> filter(fn: (r) => r._measurement == "{meas_escaped}" and r._field == "value")
  |> drop(columns: ["_start", "_stop", "_field", "_measurement", "instance", "source"])
''')

        if not csv_data.strip():
            print("no data")
            current = batch_end
            continue

        # Parse CSV into per-entity time series
        series = {}  # entity_id → [(timestamp_ms, value)]
        domain_map = {}  # entity_id → domain
        for line in csv_data.strip().replace("\r", "").split("\n"):
            # Skip header, empty results, and annotation rows
            if not line.startswith(",_result,"):
                continue
            parts = line.split(",")
            if len(parts) < 7:
                continue
            try:
                # CSV columns: ,_result,table,_time,_value,domain,entity_id
                time_str = parts[3]
                value_str = parts[4]
                domain = parts[5] if len(parts) > 5 else "sensor"
                entity_id = parts[6].strip() if len(parts) > 6 else ""

                if not entity_id or not value_str:
                    continue

                # Parse timestamp
                ts = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
                ts_ms = int(ts.timestamp() * 1000)

                # Parse value (must be numeric)
                value = float(value_str)

                if entity_id not in series:
                    series[entity_id] = []
                    domain_map[entity_id] = domain
                series[entity_id].append((ts_ms, value))
            except (ValueError, IndexError):
                continue

        # Convert to VictoriaMetrics JSON import format
        import_lines = []
        batch_points = 0
        for entity_id, datapoints in series.items():
            if not datapoints:
                continue
            domain = domain_map.get(entity_id, "sensor")
            # Build entity label: domain.entity_id (matching HA Prometheus format)
            entity_label = f"{domain}.{entity_id}"

            timestamps = [dp[0] for dp in datapoints]
            values = [dp[1] for dp in datapoints]

            vm_line = json.dumps({
                "metric": {
                    "__name__": vm_metric,
                    "entity": entity_label,
                    "job": "homeassistant",
                    "instance": "homeassistant",
                },
                "values": values,
                "timestamps": timestamps,
            }, separators=(",", ":"))
            import_lines.append(vm_line)
            batch_points += len(datapoints)

        # Import batch (chunked with rate limiting)
        imported = import_to_vm(import_lines, dry_run, batch_size, sleep_seconds)
        total_series += imported
        total_points += batch_points
        print(f"{imported} series, {batch_points} points")

        current = batch_end

    return total_series, total_points


def main():
    parser = argparse.ArgumentParser(description="Migrate HA data from InfluxDB to VictoriaMetrics")
    parser.add_argument("--dry-run", action="store_true", help="Don't actually import, just show what would happen")
    parser.add_argument("--start", default="2025-07-20", help="Start date (YYYY-MM-DD)")
    parser.add_argument("--end", default=None, help="End date (YYYY-MM-DD, default: now)")
    parser.add_argument("--batch-days", type=int, default=3, help="Days per batch (default: 3)")
    parser.add_argument("--batch-size", type=int, default=50, help="Max series per import request (default: 50)")
    parser.add_argument("--sleep", type=float, default=2.0, help="Seconds to sleep between sub-batches (default: 2.0)")
    parser.add_argument("--measurements", nargs="*", default=None, help="Only migrate specific measurements (e.g. °C W kWh)")
    args = parser.parse_args()

    start_date = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    if args.end:
        end_date = datetime.strptime(args.end, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    else:
        end_date = datetime.now(timezone.utc)

    measurements = args.measurements or list(MEASUREMENT_MAP.keys())

    print(f"=== InfluxDB → VictoriaMetrics Migration ===")
    print(f"  Source:  {INFLUX_URL} (bucket: {INFLUX_BUCKET})")
    print(f"  Target:  {VM_URL}")
    print(f"  Range:   {args.start} → {end_date.strftime('%Y-%m-%d')}")
    print(f"  Batch:   {args.batch_days} days")
    print(f"  Measurements: {len(measurements)}")
    if args.dry_run:
        print(f"  MODE: DRY-RUN (no data will be written)")
    print()

    grand_series = 0
    grand_points = 0
    t0 = time.time()

    for meas in measurements:
        vm_metric = MEASUREMENT_MAP.get(meas)
        if not vm_metric:
            print(f"SKIP: No mapping for measurement '{meas}'")
            continue

        print(f"Migrating: {meas} → {vm_metric}")
        series, points = migrate_measurement(meas, vm_metric, start_date, end_date, args.batch_days, args.dry_run,
                                              args.batch_size, args.sleep)
        grand_series += series
        grand_points += points
        print(f"  Subtotal: {series} series, {points} points")

        # Health check: verify VM is still responding before next measurement
        try:
            hc = urllib.request.urlopen(f"{VM_URL}/health", timeout=10)
            hc.read()
        except Exception:
            print(f"  WARNING: VM health check failed — waiting 30s for recovery...")
            time.sleep(30)
            try:
                hc = urllib.request.urlopen(f"{VM_URL}/health", timeout=10)
                hc.read()
            except Exception:
                print(f"  FATAL: VM still not responding. Aborting migration.")
                sys.exit(1)

        # Sleep between measurements to let VM settle (merge, flush)
        print(f"  Sleeping 5s between measurements...")
        time.sleep(5)
        print()

    elapsed = time.time() - t0
    print(f"=== Migration Complete ===")
    print(f"  Total series: {grand_series}")
    print(f"  Total points: {grand_points}")
    print(f"  Elapsed: {elapsed:.1f}s")
    if grand_points and elapsed > 0:
        print(f"  Rate: {grand_points/elapsed:.0f} points/s")


if __name__ == "__main__":
    main()
