# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**EasunPy** is a Python library for communicating with Easun ISolar inverters over Modbus TCP. It has two primary consumers:
1. **CLI tool** (`easunpy/` package) — interactive terminal dashboard using the `rich` library
2. **Home Assistant integration** (`custom_components/easun_inverter/`) — HACS-compatible integration

## Commands

```bash
# Development install
pip install -e .

# Run the CLI dashboard (auto-discovers inverter)
python -m easunpy

# Continuous mode
python -m easunpy --continuous

# Manual configuration
python -m easunpy --inverter-ip 192.168.1.100 --local-ip 192.168.1.2

# Run tests
python test_async_isolar.py

# Deploy to Home Assistant host via SSH
./deploy_dev.sh
./deploy_dev.sh --dry-run
```

There is no pytest configuration — tests are run directly.

## Architecture

### Layered Structure

```
HA Integration Layer    custom_components/easun_inverter/ (config_flow, sensor, __init__)
    ↓
Application Layer       easunpy/async_isolar.py  (AsyncISolar, typed dataclasses)
    ↓
Protocol Layer          easunpy/async_modbusclient.py  (Modbus TCP framing, CRC)
    ↓
Utilities               easunpy/crc.py, discover.py, utils.py
```

The synchronous `isolar.py` / `modbusclient.py` are deprecated. Prefer the async variants.

### Communication Protocol

Inverters are found via **UDP broadcast** to `255.255.255.255:58899` with the message `set>server=<local_ip>:<port>`. The inverter then initiates a **reverse TCP connection** back to the local host on port 8899. This is why both IPs (inverter and local) must be known.

Modbus packets use a hybrid format: standard TCP header (6 bytes) with RTU payload (Unit ID + Function Code 0x03 + Register Address + Count + CRC16) and an `FF04` prefix.

### Register Configuration System (`easunpy/models.py`)

All inverter data is defined as `RegisterConfig` entries within a `ModelConfig`. Each register has:
- Address, count of registers to read
- Scale factor (e.g., `0.1` for voltage in 100mV units)
- Optional custom `processor` function for complex transformations

Two models are supported: `ISOLAR_SMG_II_11K` (11 kW, 2 PV inputs) and `ISOLAR_SMG_II_6K` (6 kW, 1 PV input). Adding a new model means adding a new `ModelConfig` with a register map.

### Data Collector Pattern (Home Assistant)

`DataCollector` in `sensor.py` is a shared object that fetches all inverter data once per interval and distributes it to registered `SensorEntity` objects. This prevents multiple concurrent Modbus requests. It tracks consecutive failures and uses exponential backoff.

### HA Integration Details

- Config entry schema version: **v4** — migration logic lives in `__init__.py`
- Entities are split into `sensor` (main values) and `diagnostic` (system info) categories
- On first install, a Lovelace dashboard is auto-generated from `dashboard.yaml` template
- Unique entity IDs use the pattern `{entry_id}_{register_key}`

## Key Files

| File | Purpose |
|------|---------|
| `easunpy/models.py` | Register maps for each inverter model — edit here to add/change data points |
| `easunpy/async_isolar.py` | Main data-fetching logic, groups consecutive registers for bulk reads |
| `easunpy/async_modbusclient.py` | Low-level Modbus TCP with `asyncio.Lock` for serialized access |
| `custom_components/easun_inverter/sensor.py` | All HA sensor entities and the DataCollector |
| `custom_components/easun_inverter/config_flow.py` | HA setup UI with inverter discovery |
