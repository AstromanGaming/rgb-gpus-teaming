// extension.js (ES module) - corrected: no top-level await, dynamic imports inside enable()

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';

const DBUS_NAME = 'ca.astromangaming.RGB-GPUs-Teaming';
const DBUS_PATH = '/ca/astromangaming/RGB_Gpus_Teaming';
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
  constructor() {
    super();
    this._injectionManager = null;
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    this._injectedByDesktopId = new Map();
    this._fileMonitor = null;
    this._dynamicModulesLoaded = false;
    this._AppIconClass = null;
    this._DashModule = null;
  }

  async _loadDynamicModules() {
    if (this._dynamicModulesLoaded) return;
    // Try to import appDisplay or appIcon module for AppIcon class
    try {
      const mod1 = await import('resource:///org/gnome/shell/ui/appDisplay.js').catch(() => null);
      if (mod1 && mod1.AppIcon) {
        this._AppIconClass = mod1.AppIcon;
      } else {
        const mod2 = await import('resource:///org/gnome/shell/ui/appIcon.js').catch(() => null);
        if (mod2 && mod2.AppIcon) this._AppIconClass = mod2.AppIcon;
      }
    } catch (e) {
      // ignore, fallback to null
      this._AppIconClass = null;
    }

    // Try to import dash module (DashItem / Dash)
    try {
      const dashMod = await import('resource:///org/gnome/shell/ui/dash.js').catch(() => null);
      if (dashMod) this._DashModule = dashMod;
    } catch (e) {
      this._DashModule = null;
    }

    this._dynamicModulesLoaded = true;
  }

  enable() {
    // Make enable async-safe by calling an async loader and continuing in its then()
    this._injectionManager = new InjectionManager();
    this._loadExcludedFromJson();
    this._setupExcludedFileMonitor();

    // Load dynamic modules then set up injections
    this._loadDynamicModules().then(() => {
      this._setupInjections();
      log('RGB GPUs Teaming: extension enabled');
    }).catch((e) => {
      log(`RGB GPUs Teaming: failed to load dynamic modules: ${e}`);
      // still attempt to set up injections even if dynamic modules failed
      this._setupInjections();
    });
  }

  _setupInjections() {
    const extension = this;

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
        proxy.call(method, params, Gio.DBusCallFlags.NONE, -1, null, null, null);
        return true;
      } catch (e) {
        log(`RGB GPUs Teaming: D-Bus ${method} call failed: ${e}`);
        return false;
      }
    };

    // Fallback spawn
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
          try {
            menuOwner.addAction('Launch with RGB GPUs Teaming', () => {
              extension._callDbus('LaunchDesktop', desktopId).then((called) => {
                if (!called) extension._runFallbackScript(`${desktopId}.desktop`, false);
              });
              if (Main.overview.visible) Main.overview.hide();
            });

            menuOwner.addAction('Launch as root (sudo/pkexec)', () => {
              extension._callDbus('LaunchDesktopAsRoot', desktopId).then((called) => {
                if (!called) extension._runFallbackScript(`${desktopId}.desktop`, true);
              });
              if (Main.overview.visible) Main.overview.hide();
            });
          } catch (e) {
            log(`RGB GPUs Teaming: addAction failed for ${desktopId}: ${e}`);
          }
        } else {
          log(`RGB GPUs Teaming: menuOwner has no addAction; skipping structured injection for ${desktopId}`);
        }

        this._injectedByDesktopId.set(desktopId, true);
        log(`RGB GPUs Teaming: injected actions for ${desktopId}`);
      } catch (e) {
        log(`RGB GPUs Teaming: injection error for ${desktopId}: ${e}`);
      }
    };

    // Helper to override prototype method and remember original via InjectionManager
    const overrideProto = (obj, methodName, wrapperFactory) => {
      if (!obj || !obj.prototype || !obj.prototype[methodName]) return;
      const original = obj.prototype[methodName];
      obj.prototype[methodName] = wrapperFactory(original);
      try {
        this._injectionManager.addOverride(obj.prototype, methodName, original);
      } catch (e) {
        // fallback: store locally if InjectionManager doesn't support addOverride
        if (!this._localOverrides) this._localOverrides = [];
        this._localOverrides.push({ obj: obj.prototype, method: methodName, original });
      }
    };

    // AppMenu.open injection
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

    // AppIcon (overview) injection if dynamic AppIcon class found
    try {
      const AppIconClass = this._AppIconClass;
      if (AppIconClass && AppIconClass.prototype) {
        if (AppIconClass.prototype._onButtonPress) {
          overrideProto(AppIconClass, '_onButtonPress', (original) => {
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

        if (AppIconClass.prototype._onSecondaryActivate) {
          overrideProto(AppIconClass, '_onSecondaryActivate', (original) => {
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

    // AppDisplay injection (resource import)
    try {
      import('resource:///org/gnome/shell/ui/appDisplay.js').then((mod) => {
        const AppDisplay = mod?.AppDisplay || null;
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
      }).catch(() => {});
    } catch (e) {}

    // Dash / DashItem injection (taskbar)
    try {
      const dashMod = this._DashModule;
      const DashItem = dashMod?.DashItem || dashMod?.DashItemView || null;
      const Dash = dashMod?.Dash || dashMod?.DashView || null;

      const createPopupFor = (actor, desktopId) => {
        try {
          if (!actor || actor._rgbGpuMenuCreated) return;
          const menu = new PopupMenu.PopupMenu(actor, 0.0, St.Side.TOP);
          const item1 = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
          item1.connect('activate', () => {
            this._callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) this._runFallbackScript(`${desktopId}.desktop`, false);
            });
          });
          const item2 = new PopupMenu.PopupMenuItem('Launch as root (sudo/pkexec)');
          item2.connect('activate', () => {
            this._callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
              if (!ok) this._runFallbackScript(`${desktopId}.desktop`, true);
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