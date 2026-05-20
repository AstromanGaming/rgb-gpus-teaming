// extension.js (ES module)
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';

let AppIcon = null;
try {
  AppIcon = (await import('resource:///org/gnome/shell/ui/appDisplay.js')).AppIcon;
} catch (e) {
  try {
    AppIcon = (await import('resource:///org/gnome/shell/ui/appIcon.js')).AppIcon;
  } catch (e2) {
    AppIcon = null;
  }
}

// DBus constants
const DBUS_NAME = 'ca.astromangaming.RGB-GPUs-Teaming';
const DBUS_PATH = '/ca/astromangaming/RGB_Gpus_Teaming';
const DBUS_INTERFACE = 'ca.astromangaming.RGB-GPUs-Teaming';

// Fallback script and config
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
  constructor() {
    super();
    this._injectionManager = null;
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    this._injectedByDesktopId = new Map();
    this._fileMonitor = null;
  }

  enable() {
    const extension = this;
    this._injectionManager = new InjectionManager();
    this._loadExcludedFromJson();
    this._setupExcludedFileMonitor();

    // DBus helper returns Promise<boolean>
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
              } catch (err) {
                reject(err);
              }
            }
          );
        });

        const params = new GLib.Variant('(s)', [desktopId]);
        // call asynchronously; ignore reply
        proxy.call(method, params, Gio.DBusCallFlags.NONE, -1, null, null, null);
        return true;
      } catch (e) {
        log(`RGB GPUs Teaming: D-Bus ${method} call failed: ${e}`);
        return false;
      }
    };

    // Safe fallback spawn
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

    // Central injection routine
    this._injectActionsIntoMenu = (menuOwner, desktopId) => {
      try {
        if (!desktopId) return;
        if (this._excludedDesktopIds.has(desktopId)) return;
        if (this._injectedByDesktopId.get(desktopId)) return;

        if (menuOwner && typeof menuOwner.addAction === 'function') {
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
          log(`RGB GPUs Teaming: menuOwner has no addAction; skipping structured injection for ${desktopId}`);
        }

        this._injectedByDesktopId.set(desktopId, true);
        log(`RGB GPUs Teaming: injected actions for ${desktopId}`);
      } catch (e) {
        log(`RGB GPUs Teaming: injection error for ${desktopId}: ${e}`);
      }
    };

    // Helper to override prototype method and remember original
    const overrideProto = (obj, methodName, wrapperFactory) => {
      if (!obj || !obj.prototype || !obj.prototype[methodName]) return;
      const original = obj.prototype[methodName];
      obj.prototype[methodName] = wrapperFactory(original);
      this._injectionManager.addOverride(obj.prototype, methodName, original);
    };

    // Inject into AppMenu.open
    try {
      if (AppMenu && AppMenu.prototype && AppMenu.prototype.open) {
        overrideProto(AppMenu, 'open', (original) => {
          return function (...args) {
            try {
              const appInfo = this._app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !extension._excludedDesktopIds.has(desktopId)) {
                extension._injectActionsIntoMenu(this, desktopId);
              }
            } catch (e) {
              log(`RGB GPUs Teaming: AppMenu.open override error: ${e}`);
            }
            return original.call(this, ...args);
          };
        });
      }
    } catch (e) {
      log(`RGB GPUs Teaming: AppMenu injection failed: ${e}`);
    }

    // Inject into AppIcon (overview)
    try {
      if (AppIcon && AppIcon.prototype) {
        if (AppIcon.prototype._onButtonPress) {
          overrideProto(AppIcon, '_onButtonPress', (original) => {
            return function (actor, event) {
              try {
                const appInfo = this._app?.app_info;
                const desktopId = appInfo?.get_id?.();
                if (desktopId && !extension._excludedDesktopIds.has(desktopId)) {
                  extension._injectActionsIntoMenu(this, desktopId);
                }
              } catch (e) {
                log(`RGB GPUs Teaming: AppIcon._onButtonPress override error: ${e}`);
              }
              return original.call(this, actor, event);
            };
          });
        }

        if (AppIcon.prototype._onSecondaryActivate) {
          overrideProto(AppIcon, '_onSecondaryActivate', (original) => {
            return function (...args) {
              try {
                const appInfo = this._app?.app_info;
                const desktopId = appInfo?.get_id?.();
                if (desktopId && !extension._excludedDesktopIds.has(desktopId)) {
                  extension._injectActionsIntoMenu(this, desktopId);
                }
              } catch (e) {
                log(`RGB GPUs Teaming: AppIcon._onSecondaryActivate override error: ${e}`);
              }
              return original.call(this, ...args);
            };
          });
        }
      }
    } catch (e) {
      log(`RGB GPUs Teaming: AppIcon injection failed: ${e}`);
    }

    // AppDisplay injection (if present)
    try {
      const AppDisplay = await import('resource:///org/gnome/shell/ui/appDisplay.js').then(m => m.AppDisplay).catch(() => null);
      if (AppDisplay && AppDisplay.prototype && AppDisplay.prototype._onButtonPress) {
        overrideProto(AppDisplay, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              const appInfo = this._app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !extension._excludedDesktopIds.has(desktopId)) {
                extension._injectActionsIntoMenu(this, desktopId);
              }
            } catch (e) {
              log(`RGB GPUs Teaming: AppDisplay._onButtonPress override error: ${e}`);
            }
            return original.call(this, actor, event);
          };
        });
      }
    } catch (e) {
      // ignore if not present
    }

    // Favorites / Dash injection (taskbar)
    try {
      const DashModule = await import('resource:///org/gnome/shell/ui/dash.js').catch(() => null);
      const DashItem = DashModule?.DashItem || DashModule?.DashItemView || null;
      const Dash = DashModule?.Dash || DashModule?.DashView || null;

      const createPopupFor = (actor, desktopId) => {
        try {
          if (!actor || actor._rgbGpuMenuCreated) return;
          const menu = new PopupMenu.PopupMenu(actor, 0.0, St.Side.TOP);
          const item1 = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
          item1.connect('activate', () => {
            extension._callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) extension._runFallbackScript(`${desktopId}.desktop`, false);
            });
          });
          const item2 = new PopupMenu.PopupMenuItem('Launch as root (sudo/pkexec)');
          item2.connect('activate', () => {
            extension._callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
              if (!ok) extension._runFallbackScript(`${desktopId}.desktop`, true);
            });
          });
          menu.addMenuItem(item1);
          menu.addMenuItem(item2);
          actor._rgbGpuMenu = menu;
          actor._rgbGpuMenuCreated = true;
          actor.connect('button-press-event', (actorObj, event) => {
            if (event.get_button && event.get_button() === 3) {
              menu.toggle();
            }
            return false;
          });
        } catch (e) {
          log(`RGB GPUs Teaming: createPopupFor error: ${e}`);
        }
      };

      if (DashItem && DashItem.prototype && DashItem.prototype._onButtonPress) {
        overrideProto(DashItem, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              const app = this._app || this.app || null;
              const appInfo = app?.app_info || app?.get_app_info?.();
              const desktopId = appInfo?.get_id?.() || app?.get_id?.();
              if (desktopId && !extension._excludedDesktopIds.has(desktopId)) {
                if (typeof this.addAction === 'function') {
                  extension._injectActionsIntoMenu(this, desktopId);
                } else {
                  createPopupFor(this.actor || this._delegate || actor, desktopId);
                }
              }
            } catch (e) {
              log(`RGB GPUs Teaming: DashItem._onButtonPress override error: ${e}`);
            }
            return original.call(this, actor, event);
          };
        });
      }

      if (Dash && Dash.prototype && Dash.prototype._onButtonPress) {
        overrideProto(Dash, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              const delegate = actor._delegate || actor._app || null;
              const appInfo = delegate?.app_info || delegate?.get_app_info?.();
              const desktopId = appInfo?.get_id?.() || delegate?.get_id?.();
              if (desktopId && !extension._excludedDesktopIds.has(desktopId)) {
                if (delegate && typeof delegate.addAction === 'function') {
                  extension._injectActionsIntoMenu(delegate, desktopId);
                } else {
                  createPopupFor(actor, desktopId);
                }
              }
            } catch (e) {
              log(`RGB GPUs Teaming: Dash._onButtonPress override error: ${e}`);
            }
            return original.call(this, actor, event);
          };
        });
      }
    } catch (e) {
      log(`RGB GPUs Teaming: dash injection setup failed: ${e}`);
    }

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

  _loadExcludedFromJson() {
    try {
      const file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      if (!file.query_exists(null)) {
        log('RGB GPUs Teaming: excluded JSON not found, using defaults');
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