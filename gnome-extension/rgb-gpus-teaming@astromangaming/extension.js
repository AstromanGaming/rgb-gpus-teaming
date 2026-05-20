import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

let AppIcon;
try {
  AppIcon = imports.ui.appDisplay?.AppIcon || imports.ui.appIcon?.AppIcon || null;
} catch (e) {
  AppIcon = null;
}

const DBUS_NAME = 'ca.astromangaming.RGB-GPUs-Teaming';
const DBUS_PATH = '/ca/astromangaming/RGB-GPUs-Teaming';
const DBUS_INTERFACE = 'ca.astromangaming.RGB-GPUs-Teaming';

const FALLBACK_SCRIPT = '/opt/rgb-gpus-teaming/gnome-launcher.sh';
const EXCLUDED_JSON_PATH = '/opt/rgb-gpus-teaming/excluded.json';

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
    const extension = this;
    this._injectionManager = new InjectionManager();
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    this._injectedByDesktopId = new Map();
    this._fileMonitor = null;

    this._loadExcludedFromJson();
    this._setupExcludedFileMonitor();

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

    this._runFallbackScript = (arg, asRoot = false) => {
      try {
        if (!GLib.file_test(FALLBACK_SCRIPT, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
          log(`RGB GPUs Teaming: fallback script absent or not executable: ${FALLBACK_SCRIPT}`);
          return;
        }
        const argv = asRoot ? [FALLBACK_SCRIPT, arg, 'as-root'] : [FALLBACK_SCRIPT, arg];
        GLib.spawn_async(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null);
      } catch (e) {
        log(`RGB GPUs Teaming: failed to spawn fallback script: ${e}`);
      }
    };

    this._injectActionsIntoMenu = (menuOwner, desktopId) => {
      try {
        if (!desktopId) return;
        if (this._isExcluded(desktopId)) return;
        if (this._injectedByDesktopId.get(desktopId)) return;

        if (typeof menuOwner.addAction === 'function') {
          menuOwner.addAction('Launch with RGB GPUs Teaming', () => {
            extension._callDbus('LaunchDesktop', desktopId).then((called) => {
              if (!called) extension._runFallbackScript(`${desktopId}.desktop`, false);
            });
            if (Main.overview.visible) Main.overview.hide();
          });

          menuOwner.addAction('Launch with RGB GPUs Teaming (root)', () => {
            extension._callDbus('LaunchDesktopAsRoot', desktopId).then((called) => {
              if (!called) extension._runFallbackScript(`${desktopId}.desktop`, true);
            });
            if (Main.overview.visible) Main.overview.hide();
          });
        } else {
          log('RGB GPUs Teaming: menuOwner has no addAction; skipping structured injection');
        }

        this._injectedByDesktopId.set(desktopId, true);
        log(`RGB GPUs Teaming: injected actions for ${desktopId}`);
      } catch (e) {
        log(`RGB GPUs Teaming: injection error for ${desktopId}: ${e}`);
      }
    };

    this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
      return function (...args) {
        try {
          const appInfo = this._app?.app_info;
          if (!appInfo) return original.call(this, ...args);
          const desktopId = appInfo.get_id();
          if (!desktopId) return original.call(this, ...args);
          if (!extension._isExcluded(desktopId)) extension._injectActionsIntoMenu(this, desktopId);
        } catch (e) {
          log(`RGB GPUs Teaming: AppMenu.open override error: ${e}`);
        }
        return original.call(this, ...args);
      };
    });

    if (AppIcon && AppIcon.prototype) {
      if (AppIcon.prototype._onButtonPress) {
        this._injectionManager.overrideMethod(AppIcon.prototype, '_onButtonPress', original => {
          return function (actor, event) {
            try {
              const app = this._app;
              const appInfo = app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !extension._isExcluded(desktopId)) extension._injectActionsIntoMenu(this, desktopId);
            } catch (e) {
              log(`RGB GPUs Teaming: AppIcon._onButtonPress override error: ${e}`);
            }
            return original.call(this, actor, event);
          };
        });
      }

      if (AppIcon.prototype._onSecondaryActivate) {
        this._injectionManager.overrideMethod(AppIcon.prototype, '_onSecondaryActivate', original => {
          return function (...args) {
            try {
              const app = this._app;
              const appInfo = app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !extension._isExcluded(desktopId)) extension._injectActionsIntoMenu(this, desktopId);
            } catch (e) {
              log(`RGB GPUs Teaming: AppIcon._onSecondaryActivate override error: ${e}`);
            }
            return original.call(this, ...args);
          };
        });
      }
    }

    try {
      const AppDisplay = imports.ui.appDisplay?.AppDisplay || null;
      if (AppDisplay && AppDisplay.prototype && AppDisplay.prototype._onButtonPress) {
        this._injectionManager.overrideMethod(AppDisplay.prototype, '_onButtonPress', original => {
          return function (actor, event) {
            try {
              const app = this._app;
              const appInfo = app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !extension._isExcluded(desktopId)) extension._injectActionsIntoMenu(this, desktopId);
            } catch (e) {
              log(`RGB GPUs Teaming: AppDisplay._onButtonPress override error: ${e}`);
            }
            return original.call(this, actor, event);
          };
        });
      }
    } catch (e) {}

    try {
      const AppFavorites = imports.ui.appFavorites?.AppFavorites || null;
      if (AppFavorites && AppFavorites.prototype && AppFavorites.prototype._onButtonPress) {
        this._injectionManager.overrideMethod(AppFavorites.prototype, '_onButtonPress', original => {
          return function (actor, event) {
            try {
              const app = this._app;
              const appInfo = app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !extension._isExcluded(desktopId)) extension._injectActionsIntoMenu(this, desktopId);
            } catch (e) {
              log(`RGB GPUs Teaming: AppFavorites._onButtonPress override error: ${e}`);
            }
            return original.call(this, actor, event);
          };
        });
      }
    } catch (e) {}

    log('RGB GPUs Teaming: extension enabled');
  }

  disable() {
    try {
      if (this._injectionManager) {
        this._injectionManager.clear();
        this._injectionManager = null;
      }
    } catch (e) {
      log(`RGB GPUs Teaming: error clearing injection manager: ${e}`);
    }

    try {
      if (this._fileMonitor) {
        this._fileMonitor.cancel();
        this._fileMonitor = null;
      }
    } catch (e) {
      log(`RGB GPUs Teaming: error cancelling file monitor: ${e}`);
    }

    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    this._injectedByDesktopId = new Map();

    log('RGB GPUs Teaming: extension disabled');
  }

  _isExcluded(desktopId) {
    return this._excludedDesktopIds.has(desktopId);
  }

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