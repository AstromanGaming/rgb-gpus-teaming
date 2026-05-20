const GLib = imports.gi.GLib;
const Gio = imports.gi.Gio;
const St = imports.gi.St;

const PopupMenu = imports.ui.popupMenu;
const Main = imports.ui.main;
const AppDisplay = imports.ui.appDisplay || null;
const AppMenu = imports.ui.appMenu && imports.ui.appMenu.AppMenu ? imports.ui.appMenu.AppMenu : null;
const ExtensionUtils = imports.misc.extensionUtils;
const Me = ExtensionUtils.getCurrentExtension();

const DBUS_NAME = 'ca.astromangaming.RGB-GPUs-Teaming';
const DBUS_PATH = '/ca/astromangaming/RGB_Gpus_Teaming'; // valid object path (no hyphens)
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

function logDebug(...args) {
  try {
    log('RGB GPUs Teaming: ' + args.join(' '));
  } catch (e) {}
}

function RgbGpusTeamingExtension() {
  this._overrides = [];
  this._injectedByDesktopId = new Map();
  this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
  this._fileMonitor = null;
}

RgbGpusTeamingExtension.prototype = {
  enable: function () {
    logDebug('enable');
    this._loadExcludedFromJson();
    this._setupExcludedFileMonitor();

    // store originals for cleanup
    this._overrides = [];

    // Helper: call DBus method asynchronously; returns Promise<boolean>
    this._callDbus = (method, desktopId) => {
      return new Promise((resolve) => {
        try {
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
                let proxy = Gio.DBusProxy.new_for_bus_finish(res);
                let params = new GLib.Variant('(s)', [desktopId]);
                proxy.call(method, params, Gio.DBusCallFlags.NONE, -1, null, (p, r) => {
                  try {
                    proxy.call_finish(r);
                  } catch (e) {
                    // ignore call finish errors
                  }
                  resolve(true);
                }, null);
              } catch (e) {
                logDebug('DBus proxy creation failed:', e);
                resolve(false);
              }
            }
          );
        } catch (e) {
          logDebug('DBus call setup failed:', e);
          resolve(false);
        }
      });
    };

    // Fallback: spawn script safely with argv array
    this._runFallbackScript = (arg, asRoot) => {
      try {
        if (!GLib.file_test(FALLBACK_SCRIPT, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
          logDebug('fallback script missing or not executable:', FALLBACK_SCRIPT);
          return;
        }
        let argv = asRoot ? [FALLBACK_SCRIPT, arg, 'as-root'] : [FALLBACK_SCRIPT, arg];
        GLib.spawn_async(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null);
      } catch (e) {
        logDebug('spawn fallback failed:', e);
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
              this._callDbus('LaunchDesktop', desktopId).then((ok) => {
                if (!ok) this._runFallbackScript(`${desktopId}.desktop`, false);
              });
              if (Main.overview && Main.overview.visible) Main.overview.hide();
            });

            menuOwner.addAction('Launch as root (sudo/pkexec)', () => {
              this._callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
                if (!ok) this._runFallbackScript(`${desktopId}.desktop`, true);
              });
              if (Main.overview && Main.overview.visible) Main.overview.hide();
            });
          } catch (e) {
            logDebug('addAction failed:', e);
          }
        } else {
          logDebug('menuOwner has no addAction; skipping structured injection for', desktopId);
        }

        this._injectedByDesktopId.set(desktopId, true);
        logDebug('injected actions for', desktopId);
      } catch (e) {
        logDebug('injectActions error:', e);
      }
    };

    // Utility to override prototype method and remember original
    const overrideProto = (obj, methodName, wrapperFactory) => {
      if (!obj || !obj.prototype || !obj.prototype[methodName]) return;
      let original = obj.prototype[methodName];
      let self = this;
      obj.prototype[methodName] = wrapperFactory(original);
      this._overrides.push({ obj: obj.prototype, method: methodName, original: original });
      logDebug('overrode', methodName, 'on', obj);
    };

    // 1) AppMenu.open injection (application menu)
    try {
      if (AppMenu && AppMenu.prototype && AppMenu.prototype.open) {
        overrideProto(AppMenu, 'open', (original) => {
          return function (...args) {
            try {
              let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
              if (appInfo && appInfo.get_id) {
                let desktopId = appInfo.get_id();
                if (desktopId) this._extension && this._extension._injectActionsIntoMenu ? this._extension._injectActionsIntoMenu(this, desktopId) : null;
              }
            } catch (e) {
              // ignore
            }
            return original.apply(this, args);
          };
        });
      }
    } catch (e) {
      logDebug('AppMenu injection failed:', e);
    }

    // Attach extension reference to prototypes used in wrappers
    // (so wrapper can call back into this instance)
    try {
      if (AppMenu && AppMenu.prototype) AppMenu.prototype._extension = this;
    } catch (e) {}

    // 2) AppIcon (overview grid) injection
    try {
      let AppIcon = imports.ui.appDisplay && imports.ui.appDisplay.AppIcon ? imports.ui.appDisplay.AppIcon : (imports.ui.appIcon && imports.ui.appIcon.AppIcon ? imports.ui.appIcon.AppIcon : null);
      if (AppIcon && AppIcon.prototype) {
        if (AppIcon.prototype._onButtonPress) {
          overrideProto(AppIcon, '_onButtonPress', (original) => {
            return function (actor, event) {
              try {
                let app = this._app || null;
                let appInfo = app && app.app_info ? app.app_info : null;
                let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (app && app.get_id ? app.get_id() : null);
                if (desktopId && !this._extension._isExcluded(desktopId)) this._extension._injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.call(this, actor, event);
            };
          });
        }
        if (AppIcon.prototype._onSecondaryActivate) {
          overrideProto(AppIcon, '_onSecondaryActivate', (original) => {
            return function (...args) {
              try {
                let app = this._app || null;
                let appInfo = app && app.app_info ? app.app_info : null;
                let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (app && app.get_id ? app.get_id() : null);
                if (desktopId && !this._extension._isExcluded(desktopId)) this._extension._injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.apply(this, args);
            };
          });
        }
        AppIcon.prototype._extension = this;
      }
    } catch (e) {
      logDebug('AppIcon injection failed:', e);
    }

    // 3) AppDisplay injection (if present)
    try {
      if (imports.ui.appDisplay && imports.ui.appDisplay.AppDisplay && imports.ui.appDisplay.AppDisplay.prototype._onButtonPress) {
        overrideProto(imports.ui.appDisplay.AppDisplay, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let app = this._app || null;
              let appInfo = app && app.app_info ? app.app_info : null;
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (app && app.get_id ? app.get_id() : null);
              if (desktopId && !this._extension._isExcluded(desktopId)) this._extension._injectActionsIntoMenu(this, desktopId);
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
        imports.ui.appDisplay.AppDisplay.prototype._extension = this;
      }
    } catch (e) {
      // ignore
    }

    // 4) Favorites / Dash injection (taskbar)
    try {
      let DashItem = imports.ui.dash && (imports.ui.dash.DashItem || imports.ui.dash.DashItemView) ? (imports.ui.dash.DashItem || imports.ui.dash.DashItemView) : null;
      let Dash = imports.ui.dash && (imports.ui.dash.Dash || imports.ui.dash.DashView) ? (imports.ui.dash.Dash || imports.ui.dash.DashView) : null;

      const createPopupFor = (actor, desktopId) => {
        try {
          if (!actor || actor._rgbGpuMenuCreated) return;
          let menu = new PopupMenu.PopupMenu(actor, 0.0, St.Side.TOP);
          let item1 = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
          item1.connect('activate', () => {
            this._callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) this._runFallbackScript(`${desktopId}.desktop`, false);
            });
          });
          let item2 = new PopupMenu.PopupMenuItem('Launch as root (sudo/pkexec)');
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
          logDebug('createPopupFor error:', e);
        }
      };

      if (DashItem && DashItem.prototype && DashItem.prototype._onButtonPress) {
        overrideProto(DashItem, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let app = this._app || this.app || null;
              let appInfo = app && app.app_info ? app.app_info : (app && app.get_app_info ? app.get_app_info() : null);
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (app && app.get_id ? app.get_id() : null);
              if (desktopId && !this._extension._isExcluded(desktopId)) {
                if (typeof this.addAction === 'function') {
                  this._extension._injectActionsIntoMenu(this, desktopId);
                } else {
                  createPopupFor(this.actor || this._delegate || actor, desktopId);
                }
              }
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
        DashItem.prototype._extension = this;
      }

      if (Dash && Dash.prototype && Dash.prototype._onButtonPress) {
        overrideProto(Dash, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let delegate = actor._delegate || actor._app || null;
              let appInfo = delegate && delegate.app_info ? delegate.app_info : (delegate && delegate.get_app_info ? delegate.get_app_info() : null);
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (delegate && delegate.get_id ? delegate.get_id() : null);
              if (desktopId && !this._extension._isExcluded(desktopId)) {
                if (delegate && typeof delegate.addAction === 'function') {
                  this._extension._injectActionsIntoMenu(delegate, desktopId);
                } else {
                  createPopupFor(actor, desktopId);
                }
              }
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
        Dash.prototype._extension = this;
      }
    } catch (e) {
      logDebug('Dash injection setup failed:', e);
    }

    logDebug('enable finished');
  },

  disable: function () {
    logDebug('disable');
    // restore overrides
    try {
      for (let o of this._overrides) {
        try {
          o.obj[o.method] = o.original;
        } catch (e) {}
      }
      this._overrides = [];
    } catch (e) {
      logDebug('error restoring overrides:', e);
    }

    // cancel file monitor
    try {
      if (this._fileMonitor) {
        this._fileMonitor.cancel();
        this._fileMonitor = null;
      }
    } catch (e) {}

    this._injectedByDesktopId = new Map();
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);

    logDebug('disabled');
  },

  _isExcluded: function (desktopId) {
    return this._excludedDesktopIds.has(desktopId);
  },

  _loadExcludedFromJson: function () {
    try {
      let file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      if (!file.query_exists(null)) {
        logDebug('excluded JSON not found, using defaults');
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
        return;
      }
      let [, contents] = file.load_contents(null);
      if (!contents) {
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
        return;
      }
      let text = imports.byteArray.toString(contents);
      let parsed = null;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        logDebug('invalid excluded JSON:', e);
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
        return;
      }
      if (parsed && Array.isArray(parsed.excluded)) {
        this._excludedDesktopIds = new Set(parsed.excluded);
        logDebug('loaded excluded list length', parsed.excluded.length);
      } else {
        this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
      }
    } catch (e) {
      logDebug('error reading excluded JSON:', e);
      this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    }
  },

  _setupExcludedFileMonitor: function () {
    try {
      let file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      this._fileMonitor = file.monitor_file(Gio.FileMonitorFlags.NONE, null);
      this._fileMonitor.connect('changed', () => {
        logDebug('excluded JSON changed, reloading');
        this._loadExcludedFromJson();
      });
    } catch (e) {
      logDebug('could not setup file monitor:', e);
      this._fileMonitor = null;
    }
  }
};

function init() {
  return new RgbGpusTeamingExtension();
}