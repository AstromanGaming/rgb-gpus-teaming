#!/usr/bin/env python3
# dbus-daemon.py
from gi.repository import GLib
from pydbus import SessionBus
import subprocess
import os
import sys

BUS_NAME = "ca.astromangaming.RGB-GPUs-Teaming"
OBJ_PATH = "/ca/astromangaming/RGB-GPUs-Teaming"
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
            print(f"rgbgpus-daemon: failed to spawn launcher: {e}", file=sys.stderr)

    def LaunchDesktopAsRoot(self, desktopId):
        try:
            if not os.path.isfile(LAUNCHER) or not os.access(LAUNCHER, os.X_OK):
                print("Launcher not found or not executable", file=sys.stderr)
                return
            # Pass second argument 'as-root' to indicate elevation request
            subprocess.Popen([LAUNCHER, desktopId, "as-root"])
        except Exception as e:
            print(f"rgbgpus-daemon: failed to spawn launcher as root: {e}", file=sys.stderr)

if __name__ == "__main__":
    bus = SessionBus()
    bus.publish(BUS_NAME, (OBJ_PATH, Service(), IFACE))
    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass