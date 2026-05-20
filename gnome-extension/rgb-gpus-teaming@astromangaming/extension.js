/* extension.js (legacy GJS style)
   Inject "Launch with RGB GPUs Teaming" actions into app menus, overview and dash.
*/

const GLib = imports.gi.GLib;
const Gio = imports.gi.Gio;
const St = imports.gi.St;

const PopupMenu = imports.ui.popupMenu;
const Main = imports.ui.main;
const AppDisplay = imports.ui.appDisplay || null;
const AppIconModule = imports.ui.appIcon || null;
const DashModule = imports.ui.dash || null;
const AppMenuModule = imports.ui.appMenu || null;

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

const DBUS_NAME = 'ca.astromangaming.RGB-GPUs-Teaming';
const DBUS_PATH = '/ca/astromangaming/RGB_Gpus_Teaming';
const DBUS_INTERFACE = 'ca.astromangaming.RGB-GPUs-Teaming';
const FALLBACK_SCRIPT = '/opt/rgb-gpus-teaming/gnome-launcher.sh';
const EXCLUDED_JSON_PATH = '/opt/rgb-gpus-teaming/excluded.json';

function _log() {
  try { log('RGB GPUs Teaming: ' + Array.prototype.join.call(arguments, ' ')); } catch (e) {}
}

function RgbGpusTeamingExtension() {
  this._overrides = [];
  this._injectedByDesktopId = new Map();
  this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
  this._fileMonitor = null;
}

RgbGpusTeamingExtension.prototype = {
  enable: function () {
    _log('enable');
    this._loadExcludedFromJson();
    this._setupExcludedFileMonitor();

    // Setup injections
    this._setupAppMenuInjection();
    this._setupAppIconInjection();
    this._setupDashInjection();

    _log('enabled');
  },

  disable: function () {
    _log('disable');
    // restore overrides
    for (let o of this._overrides) {
      try { o.obj[o.method] = o.original; } catch (e) {}
    }
    this._overrides = [];

    try {
      if (this._fileMonitor) { this._fileMonitor.cancel(); this._fileMonitor = null; }
    } catch (e) {}

    this._injectedByDesktopId = new Map();
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    _log('disabled');
  },

  // --- core helpers
  _callDbus: function (method, desktopId) {
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
                try { proxy.call_finish(r); } catch (e) {}
                resolve(true);
              }, null);
            } catch (e) {
              _log('DBus proxy creation failed:', e);
              resolve(false);
            }
          }
        );
      } catch (e) {
        _log('DBus call setup failed:', e);
        resolve(false);
      }
    });
  },

  _runFallbackScript: function (arg, asRoot) {
    try {
      if (!GLib.file_test(FALLBACK_SCRIPT, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
        _log('fallback script missing or not executable:', FALLBACK_SCRIPT);
        return;
      }
      let argv = asRoot ? [FALLBACK_SCRIPT, arg, 'as-root'] : [FALLBACK_SCRIPT, arg];
      GLib.spawn_async(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null);
    } catch (e) {
      _log('spawn fallback failed:', e);
    }
  },

  _injectActionsIntoMenu: function (menuOwner, desktopId) {
    try {
      if (!desktopId) return;
      if (this._excludedDesktopIds.has(desktopId)) return;
      if (this._injectedByDesktopId.get(desktopId)) return;

      if (menuOwner && typeof menuOwner.addAction === 'function') {
        try {
          menuOwner.addAction('Launch with RGB GPUs Teaming', () => {
            this._callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) this._runFallbackScript(desktopId + '.desktop', false);
            });
            if (Main.overview && Main.overview.visible) Main.overview.hide();
          });

          menuOwner.addAction('Launch as root (sudo/pkexec)', () => {
            this._callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
              if (!ok) this._runFallbackScript(desktopId + '.desktop', true);
            });
            if (Main.overview && Main.overview.visible) Main.overview.hide();
          });
        } catch (e) {
          _log('addAction failed:', e);
        }
      } else {
        _log('menuOwner has no addAction; skipping structured injection for', desktopId);
      }

      this._injectedByDesktopId.set(desktopId, true);
      _log('injected actions for', desktopId);
    } catch (e) {
      _log('injectActions error:', e);
    }
  },

  _overrideProto: function (obj, methodName, wrapperFactory) {
    if (!obj || !obj.prototype || !obj.prototype[methodName]) return;
    let original = obj.prototype[methodName];
    obj.prototype[methodName] = wrapperFactory(original);
    this._overrides.push({ obj: obj.prototype, method: methodName, original: original });
    _log('overrode', methodName);
  },

  // --- injection points
  _setupAppMenuInjection: function () {
    try {
      let AppMenu = AppMenuModule && AppMenuModule.AppMenu ? AppMenuModule.AppMenu : null;
      if (AppMenu && AppMenu.prototype && AppMenu.prototype.open) {
        let self = this;
        this._overrideProto(AppMenu, 'open', (original) => {
          return function (...args) {
            try {
              let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : null;
              if (desktopId && !self._excludedDesktopIds.has(desktopId)) self._injectActionsIntoMenu(this, desktopId);
            } catch (e) {}
            return original.apply(this, args);
          };
        });
      }
    } catch (e) {
      _log('AppMenu injection failed:', e);
    }
  },

  _setupAppIconInjection: function () {
    try {
      let AppIcon = (AppDisplay && AppDisplay.AppIcon) ? AppDisplay.AppIcon : (AppIconModule && AppIconModule.AppIcon ? AppIconModule.AppIcon : null);
      if (AppIcon && AppIcon.prototype) {
        let self = this;
        if (AppIcon.prototype._onButtonPress) {
          this._overrideProto(AppIcon, '_onButtonPress', (original) => {
            return function (actor, event) {
              try {
                let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
                let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : null;
                if (desktopId && !self._excludedDesktopIds.has(desktopId)) self._injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.call(this, actor, event);
            };
          });
        }
        if (AppIcon.prototype._onSecondaryActivate) {
          this._overrideProto(AppIcon, '_onSecondaryActivate', (original) => {
            return function (...args) {
              try {
                let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
                let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : null;
                if (desktopId && !self._excludedDesktopIds.has(desktopId)) self._injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.apply(this, args);
            };
          });
        }
      }
    } catch (e) {
      _log('AppIcon injection failed:', e);
    }
  },

  _setupDashInjection: function () {
    try {
      let DashItem = DashModule && (DashModule.DashItem || DashModule.DashItemView) ? (DashModule.DashItem || DashModule.DashItemView) : null;
      let Dash = DashModule && (DashModule.Dash || DashModule.DashView) ? (DashModule.Dash || DashModule.DashView) : null;
      let self = this;

      const createPopupFor = function (actor, desktopId) {
        try {
          if (!actor || actor._rgbGpuMenuCreated) return;
          let menu = new PopupMenu.PopupMenu(actor, 0.0, St.Side.TOP);
          let item1 = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
          item1.connect('activate', () => {
            self._callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) self._runFallbackScript(desktopId + '.desktop', false);
            });
          });
          let item2 = new PopupMenu.PopupMenuItem('Launch as root (sudo/pkexec)');
          item2.connect('activate', () => {
            self._callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
              if (!ok) self._runFallbackScript(desktopId + '.desktop', true);
            });
          });
          menu.addMenuItem(item1);
          menu.addMenuItem(item2);
          actor._rgbGpuMenu = menu;
          actor._rgbGpuMenuCreated = true;
          actor.connect('button-press-event', (actorObj, event) => {
            if (event.get_button && event.get_button() === 3) menu.toggle();
            return false;
          });
        } catch (e) { _log('createPopupFor error:', e); }
      };

      if (DashItem && DashItem.prototype && DashItem.prototype._onButtonPress) {
        this._overrideProto(DashItem, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let app = this._app || this.app || null;
              let appInfo = app && app.app_info ? app.app_info : (app && app.get_app_info ? app.get_app_info() : null);
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (app && app.get_id ? app.get_id() : null);
              if (desktopId && !self._excludedDesktopIds.has(desktopId)) {
                if (typeof this.addAction === 'function') self._injectActionsIntoMenu(this, desktopId);
                else createPopupFor(this.actor || this._delegate || actor, desktopId);
              }
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
      }

      if (Dash && Dash.prototype && Dash.prototype._onButtonPress) {
        this._overrideProto(Dash, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let delegate = actor._delegate || actor._app || null;
              let appInfo = delegate && delegate.app_info ? delegate.app_info : (delegate && delegate.get_app_info ? delegate.get_app_info() : null);
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (delegate && delegate.get_id ? delegate.get_id() : null);
              if (desktopId && !self._excludedDesktopIds.has(desktopId)) {
                if (delegate && typeof delegate.addAction === 'function') self._injectActionsIntoMenu(delegate, desktopId);
                else createPopupFor(actor, desktopId);
              }
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
      }
    } catch (e) {
      _log('Dash injection setup failed:', e);
    }
  },

  // --- excluded JSON handling
  _loadExcludedFromJson: function () {
    try {
      let file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      if (!file.query_exists(null)) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      let [, contents] = file.load_contents(null);
      if (!contents) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      let text = imports.byteArray.toString(contents);
      let parsed = null;
      try { parsed = JSON.parse(text); } catch (e) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      if (parsed && Array.isArray(parsed.excluded)) this._excludedDesktopIds = new Set(parsed.excluded);
      else this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    } catch (e) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); }
  },

  _setupExcludedFileMonitor: function () {
    try {
      let file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      this._fileMonitor = file.monitor_file(Gio.FileMonitorFlags.NONE, null);
      this._fileMonitor.connect('changed', () => { this._loadExcludedFromJson(); });
    } catch (e) { this._fileMonitor = null; }
  }
};

function init() {
  return new RgbGpusTeamingExtension();
}