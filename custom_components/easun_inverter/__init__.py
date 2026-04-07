"""The Easun ISolar Inverter integration."""
from __future__ import annotations

from pathlib import Path

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
import homeassistant.helpers.config_validation as cv
from homeassistant.helpers.storage import Store
import logging

_LOGGER = logging.getLogger(__name__)

DOMAIN = "easun_inverter"

# List of platforms to support. There should be a matching .py file for each,
# eg. switch.py and sensor.py
PLATFORMS: list[Platform] = [Platform.SENSOR]

# Use config_entry_only_config_schema since we only support config flow
CONFIG_SCHEMA = cv.config_entry_only_config_schema("easun_inverter")

async def async_migrate_entry(hass: HomeAssistant, config_entry: ConfigEntry) -> bool:
    """Migrate old entry."""
    _LOGGER.debug("Migrating from version %s", config_entry.version)

    if config_entry.version < 4:
        new_data = {**config_entry.data}
        
        # Add model with default value if it doesn't exist
        if "model" not in new_data:
            new_data["model"] = "ISOLAR_SMG_II_11K"
            
        # Update the entry with new data and version
        hass.config_entries.async_update_entry(
            config_entry,
            data=new_data,
            version=4
        )
        _LOGGER.info("Migration to version %s successful", 4)

    return True

async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    """Set up the Easun ISolar Inverter component."""
    _LOGGER.debug("Setting up Easun ISolar Inverter component")
    return True

async def _ensure_dashboard(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Create a per-inverter Lovelace dashboard on first install."""
    import yaml

    device_id = entry.entry_id[:8]
    url_path = f"easun_{device_id}"

    dashboard_path = Path(__file__).parent / "dashboard.yaml"
    try:
        raw = await hass.async_add_executor_job(dashboard_path.read_text)
    except Exception as e:
        _LOGGER.warning(f"Could not read dashboard.yaml: {e}")
        return

    # Template entity IDs for this specific inverter
    raw = raw.replace("sensor.easun_", f"sensor.easun_{device_id}_")
    try:
        config = yaml.safe_load(raw)
    except Exception as e:
        _LOGGER.warning(f"Could not parse dashboard.yaml: {e}")
        return

    # Write dashboard config to lovelace storage (idempotent)
    config_store = Store(hass, 1, f"lovelace.{url_path}")
    if await config_store.async_load() is None:
        await config_store.async_save({"config": config})
        _LOGGER.info(f"Created Lovelace dashboard config: {url_path}")

    # Register dashboard in the dashboards registry (idempotent)
    registry_store = Store(hass, 1, "core.lovelace_dashboards")
    registry = await registry_store.async_load() or {}
    items = registry.get("items", [])
    if not any(d.get("url_path") == url_path for d in items):
        items.append({
            "id": url_path,
            "url_path": url_path,
            "title": f"Easun Inverter ({device_id})",
            "icon": "mdi:solar-power",
            "show_in_sidebar": True,
            "require_admin": False,
            "mode": "storage",
        })
        registry["items"] = items
        await registry_store.async_save(registry)
        _LOGGER.info(f"Registered dashboard in sidebar: {url_path}")

        hass.components.persistent_notification.async_create(
            f"Dashboard **Easun Inverter ({device_id})** has been added. "
            "**Restart Home Assistant** to see it in the sidebar.",
            title="Easun Inverter Dashboard Installed",
            notification_id=f"easun_inverter_dashboard_{device_id}",
        )


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up Easun ISolar Inverter from a config entry."""
    if entry.version < 4:
        if not await async_migrate_entry(hass, entry):
            return False

    model = entry.data["model"]  # No default - should be required
    _LOGGER.warning(f"Setting up inverter with model: {model}, config data: {entry.data}")

    # Initialize domain data
    hass.data.setdefault(DOMAIN, {})

    # Forward the setup to the sensor platform
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    # Install Lovelace dashboard on first setup
    await _ensure_dashboard(hass, entry)

    return True

async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload a config entry."""
    _LOGGER.debug("Unloading Easun ISolar Inverter config entry")
    
    # Cleanup any update listeners
    if entry.entry_id in hass.data[DOMAIN]:
        if "update_listener" in hass.data[DOMAIN][entry.entry_id]:
            _LOGGER.debug("Cancelling update listener")
            hass.data[DOMAIN][entry.entry_id]["update_listener"]()
    
    # Unload the sensor platform
    unload_ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    
    # Clean up domain data
    if unload_ok and entry.entry_id in hass.data[DOMAIN]:
        _LOGGER.debug("Removing entry data")
        hass.data[DOMAIN].pop(entry.entry_id)
    
    return unload_ok 