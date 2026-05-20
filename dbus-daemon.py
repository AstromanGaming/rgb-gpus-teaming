#!/usr/bin/env python3
# dbus-daemon.py
# Simple session DBus provider that launches the launcher script on request.

from gi.repository import GLib
from pydbus import SessionBus
import subprocess
import os
import sys
import signal

BUS_NAME = "ca.astromangaming.RGB-GPUs-Teaming"
OBJ_PATH = "/ca/astromangaming/RGB_Gpus_Teaming"
LAUNCHER = "/opt/rgb-gpus-teaming/gnome-launcher.sh"

IFACE = """
<node>
  <interface name='ca.astromangaming.RGB-GPUs-Teaming'>
    <method name='LaunchDesktop'>
      <arg type='s' name='desktopId' direction='in'/>
    </method>
    <method name='LaunchDesktopAsRoot'>
      <arg type='s' name='desktopId' direction='in'/>
    </method>
  </interface>
</node>
"""

class Service:
    def LaunchDesktop(self, desktopId):
        try:
            if not os.path.isfile(LAUNCHER) or not os.access(LAUNCHER, os.X_OK):
                print("Launcher not found or not executable", file=sys.stderr)
                return
            subprocess.Popen([LAUNCHER, desktopId])
        except Exception as e:
            print(f"dbus-daemon: failed to spawn launcher: {e}", file=sys.stderr)

    def LaunchDesktopAsRoot(self, desktopId):
        try:
            if not os.path.isfile(LAUNCHER) or not os.access(LAUNCHER, os.X_OK):
                print("Launcher not found or not executable", file=sys.stderr)
                return
            subprocess.Popen([LAUNCHER, desktopId, "as-root"])
        except Exception as e:
            print(f"dbus-daemon: failed to spawn launcher as root: {e}", file=sys.stderr)

def main():
    loop = GLib.MainLoop()
    def _quit(*args):
        try:
            loop.quit()
        except Exception:
            pass
    signal.signal(signal.SIGINT, _quit)
    signal.signal(signal.SIGTERM, _quit)

    bus = SessionBus()
    try:
        bus.publish(BUS_NAME, (OBJ_PATH, Service(), IFACE))
    except Exception as e:
        print(f"dbus-daemon: failed to publish bus name {BUS_NAME}: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        loop.run()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()