#!/usr/bin/env python3
"""Tiny bridge between the Razer Mouse bar widget and the OpenRazer daemon.

  razer-mice.py status               -> JSON: {"daemon": bool, "mice": [...]}
  razer-mice.py set-dpi SERIAL DPI   -> sets X and Y DPI, prints the status JSON

Every Razer mouse the daemon knows about is reported. Battery fields are null
for wired-only mice (no razer.device.power interface).
"""
import json
import sys

try:
    import dbus
except ImportError:
    print(json.dumps({"daemon": False, "error": "python-dbus is not installed", "mice": []}))
    sys.exit(0)

BUS_NAME = "org.razer"


def call(obj, iface, method, *args):
    """Call a D-Bus method, returning None when the device doesn't support it."""
    try:
        return getattr(dbus.Interface(obj, iface), method)(*args)
    except dbus.DBusException:
        return None


def mouse_info(bus, serial):
    obj = bus.get_object(BUS_NAME, f"/org/razer/device/{serial}")
    if str(call(obj, "razer.device.misc", "getDeviceType") or "") != "mouse":
        return None

    battery = call(obj, "razer.device.power", "getBattery")
    charging = call(obj, "razer.device.power", "isCharging")
    dpi = call(obj, "razer.device.dpi", "getDPI")
    max_dpi = call(obj, "razer.device.dpi", "maxDPI")
    poll = call(obj, "razer.device.misc", "getPollRate")

    return {
        "serial": str(serial),
        "name": str(call(obj, "razer.device.misc", "getDeviceName") or "Razer mouse"),
        # getBattery reports a float 0-100 (it's a 0-255 hardware value scaled).
        "battery": round(float(battery)) if battery is not None else None,
        "charging": bool(charging) if charging is not None else None,
        "dpi": int(dpi[0]) if dpi is not None and len(dpi) > 0 else None,
        "maxDpi": int(max_dpi) if max_dpi is not None else None,
        "pollRate": int(poll) if poll is not None else None,
    }


def status(bus):
    try:
        manager = bus.get_object(BUS_NAME, "/org/razer")
        serials = dbus.Interface(manager, "razer.devices").getDevices()
    except dbus.DBusException:
        return {"daemon": False, "mice": []}

    mice = []
    for serial in serials:
        try:
            info = mouse_info(bus, serial)
        except dbus.DBusException:
            info = None  # device vanished mid-read (dongle unplugged, mouse asleep)
        if info:
            mice.append(info)
    return {"daemon": True, "mice": mice}


def set_dpi(bus, serial, dpi):
    obj = bus.get_object(BUS_NAME, f"/org/razer/device/{serial}")
    max_dpi = call(obj, "razer.device.dpi", "maxDPI") or dpi
    dpi = max(100, min(int(dpi), int(max_dpi)))
    dbus.Interface(obj, "razer.device.dpi").setDPI(dbus.Int32(dpi), dbus.Int32(dpi))


def main(argv):
    command = argv[1] if len(argv) > 1 else "status"
    try:
        bus = dbus.SessionBus()
    except dbus.DBusException as e:
        print(json.dumps({"daemon": False, "error": str(e), "mice": []}))
        return 0

    if command == "set-dpi":
        if len(argv) != 4:
            print("usage: razer-mice.py set-dpi SERIAL DPI", file=sys.stderr)
            return 2
        try:
            set_dpi(bus, argv[2], int(argv[3]))
        except (dbus.DBusException, ValueError) as e:
            print(f"set-dpi failed: {e}", file=sys.stderr)
            return 1
    elif command != "status":
        print(f"unknown command: {command}", file=sys.stderr)
        return 2

    print(json.dumps(status(bus)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
