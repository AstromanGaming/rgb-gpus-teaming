/* injector.js
   Contient la logique d'injection (AppMenu, AppIcon, Dash/DashItem),
   le fallback popup pour la barre des tâches, et la lecture du fichier excluded.json.
   Format legacy (imports.*), pas d'export ES.
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

const EXCLUDED_JSON_PATH = '/opt/rgb-gpus-teaming/excluded.json';
const FALLBACK_SCRIPT = '/opt/rgb-gpus-teaming/gnome-launcher.sh';

function _log() {
  try { log('rgb-gpus-teaming: ' + Array.prototype.join.call(arguments, ' ')); } catch (e) {}
}

var injector = (function () {
  let _overrides = [];
  let _injectedByDesktopId = new Map();
  let _excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
  let _fileMonitor = null;

  function _overrideProto(obj, methodName, wrapperFactory) {
    if (!obj || !obj.prototype || !obj.prototype[methodName]) return;
    let original = obj.prototype[methodName];
    obj.prototype[methodName] = wrapperFactory(original);
    _overrides.push({ obj: obj.prototype, method: methodName, original: original });
    _log('overrode', methodName);
  }

  function _callDbus(method, desktopId) {
    // This function is kept for parity; extension uses DBus service or fallback script.
    return new Promise((resolve) => {
      try {
        Gio.DBusProxy.new_for_bus(
          Gio.BusType.SESSION,
          Gio.DBusProxyFlags.NONE,
          null,
          'ca.astromangaming.RGB-GPUs-Teaming',
          '/ca/astromangaming/RGB_Gpus_Teaming',
          'ca.astromangaming.RGB-GPUs-Teaming',
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
  }

  function _runFallbackScript(arg, asRoot) {
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
  }

  function _injectActionsIntoMenu(menuOwner, desktopId) {
    try {
      if (!desktopId) return;
      if (_excludedDesktopIds.has(desktopId)) return;
      if (_injectedByDesktopId.get(desktopId)) return;

      if (menuOwner && typeof menuOwner.addAction === 'function') {
        try {
          menuOwner.addAction('Launch with RGB GPUs Teaming', () => {
            _callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) _runFallbackScript(desktopId + '.desktop', false);
            });
            if (Main.overview && Main.overview.visible) Main.overview.hide();
          });

          menuOwner.addAction('Launch as root (sudo/pkexec)', () => {
            _callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
              if (!ok) _runFallbackScript(desktopId + '.desktop', true);
            });
            if (Main.overview && Main.overview.visible) Main.overview.hide();
          });
        } catch (e) {
          _log('addAction failed:', e);
        }
      } else {
        _log('menuOwner has no addAction; skipping structured injection for', desktopId);
      }

      _injectedByDesktopId.set(desktopId, true);
      _log('injected actions for', desktopId);
    } catch (e) {
      _log('injectActions error:', e);
    }
  }

  // AppMenu injection
  function _setupAppMenuInjection() {
    try {
      let AppMenu = AppMenuModule && AppMenuModule.AppMenu ? AppMenuModule.AppMenu : null;
      if (AppMenu && AppMenu.prototype && AppMenu.prototype.open) {
        let self = this;
        _overrideProto(AppMenu, 'open', (original) => {
          return function (...args) {
            try {
              let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : null;
              if (desktopId && !_excludedDesktopIds.has(desktopId)) _injectActionsIntoMenu(this, desktopId);
            } catch (e) {}
            return original.apply(this, args);
          };
        });
      }
    } catch (e) {
      _log('AppMenu injection failed:', e);
    }
  }

  // AppIcon injection (overview)
  function _setupAppIconInjection() {
    try {
      let AppIcon = (AppDisplay && AppDisplay.AppIcon) ? AppDisplay.AppIcon : (AppIconModule && AppIconModule.AppIcon ? AppIconModule.AppIcon : null);
      if (AppIcon && AppIcon.prototype) {
        if (AppIcon.prototype._onButtonPress) {
          _overrideProto(AppIcon, '_onButtonPress', (original) => {
            return function (actor, event) {
              try {
                let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
                let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : null;
                if (desktopId && !_excludedDesktopIds.has(desktopId)) _injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.call(this, actor, event);
            };
          });
        }
        if (AppIcon.prototype._onSecondaryActivate) {
          _overrideProto(AppIcon, '_onSecondaryActivate', (original) => {
            return function (...args) {
              try {
                let appInfo = this._app && this._app.app_info ? this._app.app_info : null;
                let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : null;
                if (desktopId && !_excludedDesktopIds.has(desktopId)) _injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.apply(this, args);
            };
          });
        }
      }
    } catch (e) {
      _log('AppIcon injection failed:', e);
    }
  }

  // Dash / DashItem injection (taskbar) with right-click popup fallback
  function _setupDashInjection() {
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
            _callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) _runFallbackScript(desktopId + '.desktop', false);
            });
          });
          let item2 = new PopupMenu.PopupMenuItem('Launch as root (sudo/pkexec)');
          item2.connect('activate', () => {
            _callDbus('LaunchDesktopAsRoot', desktopId).then((ok) => {
              if (!ok) _runFallbackScript(desktopId + '.desktop', true);
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
        _overrideProto(DashItem, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let app = this._app || this.app || null;
              let appInfo = app && app.app_info ? app.app_info : (app && app.get_app_info ? app.get_app_info() : null);
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (app && app.get_id ? app.get_id() : null);
              if (desktopId && !_excludedDesktopIds.has(desktopId)) {
                if (typeof this.addAction === 'function') _injectActionsIntoMenu(this, desktopId);
                else createPopupFor(this.actor || this._delegate || actor, desktopId);
              }
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
      }

      if (Dash && Dash.prototype && Dash.prototype._onButtonPress) {
        _overrideProto(Dash, '_onButtonPress', (original) => {
          return function (actor, event) {
            try {
              let delegate = actor._delegate || actor._app || null;
              let appInfo = delegate && delegate.app_info ? delegate.app_info : (delegate && delegate.get_app_info ? delegate.get_app_info() : null);
              let desktopId = appInfo && appInfo.get_id ? appInfo.get_id() : (delegate && delegate.get_id ? delegate.get_id() : null);
              if (desktopId && !_excludedDesktopIds.has(desktopId)) {
                if (delegate && typeof delegate.addAction === 'function') _injectActionsIntoMenu(delegate, desktopId);
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
  }

  // excluded.json handling
  function _loadExcludedFromJson() {
    try {
      let file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      if (!file.query_exists(null)) { _excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      let [, contents] = file.load_contents(null);
      if (!contents) { _excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      let text = imports.byteArray.toString(contents);
      let parsed = null;
      try { parsed = JSON.parse(text); } catch (e) { _excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      if (parsed && Array.isArray(parsed.excluded)) _excludedDesktopIds = new Set(parsed.excluded);
      else _excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    } catch (e) { _excludedDesktopIds = new Set(DEFAULT_EXCLUDED); }
  }

  function _setupExcludedFileMonitor() {
    try {
      let file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      _fileMonitor = file.monitor_file(Gio.FileMonitorFlags.NONE, null);
      _fileMonitor.connect('changed', () => { _loadExcludedFromJson(); });
    } catch (e) { _fileMonitor = null; }
  }

  // public API
  return {
    enable: function () {
      _loadExcludedFromJson();
      _setupExcludedFileMonitor();
      _setupAppMenuInjection();
      _setupAppIconInjection();
      _setupDashInjection();
      _log('injector enabled');
    },
    disable: function () {
      // restore overrides
      for (let o of _overrides) {
        try { o.obj[o.method] = o.original; } catch (e) {}
      }
      _overrides = [];
      try { if (_fileMonitor) { _fileMonitor.cancel(); _fileMonitor = null; } } catch (e) {}
      _injectedByDesktopId = new Map();
      _excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
      _log('injector disabled');
    }
  };
})();

// expose injector as module for extension.js to import
var enable = injector.enable;
var disable = injector.disable;
