/* extension.js */
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const DBUS_NAME = 'ca.astromangaming.RGB-GPUs-Teaming';
const DBUS_PATH = '/ca/astromangaming/RGB-GPUs-Teaming';
const DBUS_INTERFACE = 'ca.astromangaming.RGB-GPUs-Teaming';

// Path to the JSON file containing excluded desktop IDs
const EXCLUDED_JSON_PATH = '/opt/rgb-gpus-teaming/excluded.json';

// Default excluded list used if JSON missing or invalid
const DEFAULT_EXCLUDED = [
  'advisor.desktop',
  'gnome-setup.desktop',
  'manual-setup.desktop',
  'all-ways-egpu-auto-setup.desktop',
  'all-ways-egpu.desktop',
  'gnome-setup-vulkan.desktop',
  'advisor-vulkan.desktop',
  'manual-setup-vulkan.desktop'
];

export default class RgbGpusTeamingExtension extends Extension {
  enable() {
    this._injectionManager = new InjectionManager();
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);

    // Load initial excluded list from JSON
    this._loadExcludedFromJson();

    // Setup file monitor to reload on change
    this._setupExcludedFileMonitor();

    // DBus helper (async)
    this._callDbus = async (method, desktopId) => {
      try {
        const proxy = await new Promise((resolve, reject) => {
          Gio.DBusProxy.new_for_bus(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.NONE,
            null,
            DBUS_NAME,
            DBUS_PATH,
            DBUS_INTERFACE,
            null,
            (obj, res) => {
              try {
                const p = Gio.DBusProxy.new_for_bus_finish(res);
                resolve(p);
              } catch (e) {
                reject(e);
              }
            }
          );
        });

        const params = new GLib.Variant('(s)', [desktopId]);
        proxy.call(method, params, Gio.DBusCallFlags.NONE, -1, null, null, null);
        return true;
      } catch (e) {
        log(`RGB GPUs Teaming: D-Bus ${method} call failed: ${e}`);
        return false;
      }
    };

    // Inject into AppMenu.open
    this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
      return function (...args) {
        if (this._rgbGpuInjected) return original.call(this, ...args);

        const appInfo = this._app?.app_info;
        if (!appInfo) return original.call(this, ...args);

        const desktopId = appInfo.get_id();
        if (!desktopId) return original.call(this, ...args);

        if (this._extension && this._extension._isExcluded(desktopId)) {
          log(`RGB GPUs Teaming: Skipping injection for excluded app ${desktopId}`);
          return original.call(this, ...args);
        }

        log(`RGB GPUs Teaming: Injecting actions for ${desktopId}`);

        const extensionInstance = this;

        this.addAction('Launch with RGB GPUs Teaming', () => {
          try {
            extensionInstance._callDbus('LaunchDesktop', desktopId).then((called) => {
              if (!called) {
                const scriptPath = GLib.build_filenamev(['/opt', 'rgb-gpus-teaming', 'gnome-launcher.sh']);
                if (GLib.file_test(scriptPath, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
                  GLib.spawn_command_line_async(`${scriptPath} "${desktopId}"`);
                } else {
                  log(`RGB GPUs Teaming: No DBus and no fallback script at ${scriptPath}`);
                }
              }
            });
          } catch (e) {
            log(`RGB GPUs Teaming: Error calling D-Bus LaunchDesktop: ${e}`);
          }
          if (Main.overview.visible) Main.overview.hide();
        });

        this.addAction('Launch as root (sudo/pkexec)', () => {
          try {
            extensionInstance._callDbus('LaunchDesktopAsRoot', desktopId).then((called) => {
              if (!called) {
                const scriptPath = GLib.build_filenamev(['/opt', 'rgb-gpus-teaming', 'gnome-launcher.sh']);
                if (GLib.file_test(scriptPath, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
                  GLib.spawn_command_line_async(`${scriptPath} "${desktopId}" as-root`);
                } else {
                  log(`RGB GPUs Teaming: No DBus and no fallback script at ${scriptPath}`);
                }
              }
            });
          } catch (e) {
            log(`RGB GPUs Teaming: Error calling D-Bus LaunchDesktopAsRoot: ${e}`);
          }
          if (Main.overview.visible) Main.overview.hide();
        });

        this._rgbGpuInjected = true;
        return original.call(this, ...args);
      };
    });
  }

  disable() {
    this._injectionManager.clear();
    if (this._fileMonitor) {
      try { this._fileMonitor.cancel(); } catch (e) {}
      this._fileMonitor = null;
    }
  }

  // Check if a desktopId is excluded
  _isExcluded(desktopId) {
    return this._excludedDesktopIds.has(desktopId);
  }

  // Load JSON file and update the Set
  _loadExcludedFromJson() {
    try {
      const file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      if (!file.query_exists(null)) {
        log(`RGB GPUs Teaming: excluded JSON not found at ${EXCLUDED_JSON_PATH}, using defaults`);
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
        return;
      }

      const [, contents] = file.load_contents(null);
      if (!contents) {
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
        return;
      }

      const text = imports.byteArray.toString(contents);
      let parsed = null;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        log(`RGB GPUs Teaming: invalid JSON in ${EXCLUDED_JSON_PATH}: ${e}`);
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
        return;
      }

      if (parsed && Array.isArray(parsed.excluded)) {
        this._excludedDesktopIds = new Set(parsed.excluded);
        log(`RGB GPUs Teaming: loaded ${parsed.excluded.length} excluded desktopIds from JSON`);
      } else {
        log(`RGB GPUs Teaming: JSON missing 'excluded' array, using defaults`);
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
      }
    } catch (e) {
      log(`RGB GPUs Teaming: error reading excluded JSON: ${e}`);
      this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    }
  }

  // Setup Gio.FileMonitor to watch the JSON file for changes and reload
  _setupExcludedFileMonitor() {
    try {
      const file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      this._fileMonitor = file.monitor_file(Gio.FileMonitorFlags.NONE, null);
      this._fileMonitor.connect('changed', () => {
        log('RGB GPUs Teaming: excluded JSON changed, reloading');
        this._loadExcludedFromJson();
      });
    } catch (e) {
      log(`RGB GPUs Teaming: could not setup file monitor for ${EXCLUDED_JSON_PATH}: ${e}`);
      this._fileMonitor = null;
    }
  }
}