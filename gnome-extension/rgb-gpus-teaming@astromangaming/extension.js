// extension.js (ES module, GNOME 44+)
// Top-level imports only (no dynamic import/await at top-level)

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import { AppIcon } from 'resource:///org/gnome/shell/ui/appDisplay.js';
import * as DashModule from 'resource:///org/gnome/shell/ui/dash.js';

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

function _log(...args) {
  try { log('RGB GPUs Teaming: ' + args.join(' ')); } catch (e) {}
}

export default class RgbGpusTeaming {
  constructor() {
    this._overrides = [];
    this._injectedByDesktopId = new Map();
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    this._fileMonitor = null;
  }

  enable() {
    _log('enable start');
    this._loadExcludedFromJson();
    this._setupExcludedFileMonitor();
    this._setupInjections();
    _log('enable done');
  }

  disable() {
    _log('disable start');
    for (const o of this._overrides) {
      try { o.obj[o.method] = o.original; } catch (e) {}
    }
    this._overrides = [];
    try { if (this._fileMonitor) { this._fileMonitor.cancel(); this._fileMonitor = null; } } catch (e) {}
    this._injectedByDesktopId = new Map();
    this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    _log('disable done');
  }

  // DBus helper
  _callDbus(method, desktopId) {
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
              const proxy = Gio.DBusProxy.new_for_bus_finish(res);
              const params = new GLib.Variant('(s)', [desktopId]);
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

  _runFallbackScript(arg, asRoot = false) {
    try {
      if (!GLib.file_test(FALLBACK_SCRIPT, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
        _log('fallback script missing or not executable:', FALLBACK_SCRIPT);
        return;
      }
      const argv = asRoot ? [FALLBACK_SCRIPT, arg, 'as-root'] : [FALLBACK_SCRIPT, arg];
      GLib.spawn_async(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null);
    } catch (e) {
      _log('spawn fallback failed:', e);
    }
  }

  _injectActionsIntoMenu(menuOwner, desktopId) {
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
  }

  _overrideProto(obj, methodName, wrapperFactory) {
    if (!obj || !obj.prototype || !obj.prototype[methodName]) return;
    const original = obj.prototype[methodName];
    obj.prototype[methodName] = wrapperFactory(original);
    this._overrides.push({ obj: obj.prototype, method: methodName, original });
    _log('overrode', methodName);
  }

  _setupInjections() {
    // AppMenu
    try {
      if (AppMenu && AppMenu.prototype && AppMenu.prototype.open) {
        this._overrideProto(AppMenu, 'open', (original) => {
          const self = this;
          return function (...args) {
            try {
              const appInfo = this._app?.app_info;
              const desktopId = appInfo?.get_id?.();
              if (desktopId && !self._excludedDesktopIds.has(desktopId)) self._injectActionsIntoMenu(this, desktopId);
            } catch (e) {}
            return original.call(this, ...args);
          };
        });
      }
    } catch (e) { _log('AppMenu injection failed:', e); }

    // AppIcon (overview)
    try {
      if (AppIcon && AppIcon.prototype) {
        if (AppIcon.prototype._onButtonPress) {
          this._overrideProto(AppIcon, '_onButtonPress', (original) => {
            const self = this;
            return function (actor, event) {
              try {
                const appInfo = this._app?.app_info;
                const desktopId = appInfo?.get_id?.();
                if (desktopId && !self._excludedDesktopIds.has(desktopId)) self._injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.call(this, actor, event);
            };
          });
        }
        if (AppIcon.prototype._onSecondaryActivate) {
          this._overrideProto(AppIcon, '_onSecondaryActivate', (original) => {
            const self = this;
            return function (...args) {
              try {
                const appInfo = this._app?.app_info;
                const desktopId = appInfo?.get_id?.();
                if (desktopId && !self._excludedDesktopIds.has(desktopId)) self._injectActionsIntoMenu(this, desktopId);
              } catch (e) {}
              return original.call(this, ...args);
            };
          });
        }
      }
    } catch (e) { _log('AppIcon injection failed:', e); }

    // Dash / DashItem
    try {
      const DashItem = DashModule?.DashItem || DashModule?.DashItemView || null;
      const Dash = DashModule?.Dash || DashModule?.DashView || null;
      const Popup = PopupMenu;

      const createPopupFor = (actor, desktopId) => {
        try {
          if (!actor || actor._rgbGpuMenuCreated) return;
          const menu = new Popup.PopupMenu(actor, 0.0, St.Side.TOP);
          const item1 = new Popup.PopupMenuItem('Launch with RGB GPUs Teaming');
          item1.connect('activate', () => {
            this._callDbus('LaunchDesktop', desktopId).then((ok) => {
              if (!ok) this._runFallbackScript(`${desktopId}.desktop`, false);
            });
          });
          const item2 = new Popup.PopupMenuItem('Launch as root (sudo/pkexec)');
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
            if (event.get_button && event.get_button() === 3) menu.toggle();
            return false;
          });
        } catch (e) { _log('createPopupFor error:', e); }
      };

      if (DashItem && DashItem.prototype && DashItem.prototype._onButtonPress) {
        this._overrideProto(DashItem, '_onButtonPress', (original) => {
          const self = this;
          return function (actor, event) {
            try {
              const app = this._app || this.app || null;
              const appInfo = app?.app_info || (app && app.get_app_info ? app.get_app_info() : null);
              const desktopId = appInfo?.get_id?.() || (app && app.get_id ? app.get_id() : null);
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
          const self = this;
          return function (actor, event) {
            try {
              const delegate = actor._delegate || actor._app || null;
              const appInfo = delegate?.app_info || (delegate && delegate.get_app_info ? delegate.get_app_info() : null);
              const desktopId = appInfo?.get_id?.() || (delegate && delegate.get_id ? delegate.get_id() : null);
              if (desktopId && !self._excludedDesktopIds.has(desktopId)) {
                if (delegate && typeof delegate.addAction === 'function') self._injectActionsIntoMenu(delegate, desktopId);
                else createPopupFor(actor, desktopId);
              }
            } catch (e) {}
            return original.call(this, actor, event);
          };
        });
      }
    } catch (e) { _log('Dash injection setup failed:', e); }
  }

  _loadExcludedFromJson() {
    try {
      const file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      if (!file.query_exists(null)) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      const [, contents] = file.load_contents(null);
      if (!contents) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      const text = imports.byteArray.toString(contents);
      let parsed = null;
      try { parsed = JSON.parse(text); } catch (e) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); return; }
      if (parsed && Array.isArray(parsed.excluded)) this._excludedDesktopIds = new Set(parsed.excluded);
      else this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED);
    } catch (e) { this._excludedDesktopIds = new Set(DEFAULT_EXCLUDED); }
  }

  _setupExcludedFileMonitor() {
    try {
      const file = Gio.File.new_for_path(EXCLUDED_JSON_PATH);
      this._fileMonitor = file.monitor_file(Gio.FileMonitorFlags.NONE, null);
      this._fileMonitor.connect('changed', () => { this._loadExcludedFromJson(); });
    } catch (e) { this._fileMonitor = null; }
  }
}