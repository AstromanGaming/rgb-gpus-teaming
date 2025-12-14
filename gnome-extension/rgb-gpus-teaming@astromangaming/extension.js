import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as AppMenuModule from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as AppDisplayModule from 'resource:///org/gnome/shell/ui/appDisplay.js';

const EXTENSION_UUID = 'rgb-gpus-teaming@astromangaming';
const LAUNCHER = '/opt/RGB-GPUs-Teaming.OP/gnome-launcher.sh';
const EXCLUDED = new Set([
  'advisor.desktop',
  'gnome-setup.desktop',
  'manual-setup.desktop',
  'all-ways-egpu-auto-setup.desktop'
]);

let _orig = [];
let _items = new Map();
let _owners = new Set();

function logDebug(msg) {
  try { global.log(`[${EXTENSION_UUID}] ${msg}`); } catch (e) {}
}

function scriptOk(path) {
  try { return GLib.file_test(path, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE); }
  catch (e) { return false; }
}

function safeQuote(s) {
  try { return GLib.shell_quote(s); } catch (e) { return `'${s.replace(/'/g, "'\\''")}'`; }
}

/* Insert the launch item at the end of the menu or sub-menu.
   Try several common menu containers used by GNOME. */
function insertLaunchItem(owner, command) {
  if (!PopupMenu || !PopupMenu.PopupMenuItem) return;
  if (!owner) return;
  if (_owners.has(owner)) return;
  if (!scriptOk(LAUNCHER)) return;

  const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
  item.connect('activate', () => {
    try {
      const cmd = `${safeQuote(LAUNCHER)} ${safeQuote(command)}`;
      GLib.spawn_command_line_async(cmd);
      if (Main.overview?.visible) Main.overview.hide();
    } catch (e) { logDebug(`spawn failed: ${e}`); }
  });

  // Append to common menu containers (no index => append/end)
  try { if (owner._appMenu && typeof owner._appMenu.addMenuItem === 'function') owner._appMenu.addMenuItem(item); } catch (e) {}
  try { if (owner.menu && typeof owner.menu.addMenuItem === 'function') owner.menu.addMenuItem(item); } catch (e) {}
  try { if (owner._menu && typeof owner._menu.addMenuItem === 'function') owner._menu.addMenuItem(item); } catch (e) {}
  try { if (owner.addMenuItem && typeof owner.addMenuItem === 'function') owner.addMenuItem(item); } catch (e) {}

  // Some implementations expose getMenu(); try to append if available
  try {
    if (typeof owner.getMenu === 'function') {
      const m = owner.getMenu();
      if (m && typeof m.addMenuItem === 'function') m.addMenuItem(item);
    }
  } catch (e) {}

  _owners.add(owner);
  _items.set(owner, item);
}

function overrideMethod(obj, methodName, wrapperFactory) {
  if (!obj?.prototype?.[methodName]) return false;
  const original = obj.prototype[methodName];
  const wrapped = wrapperFactory(original);
  _orig.push({ object: obj.prototype, name: methodName, original });
  obj.prototype[methodName] = wrapped;
  return true;
}

function restoreOverrides() {
  for (const e of _orig) {
    try { e.object[e.name] = e.original; } catch (ex) {}
  }
  _orig = [];
}

function cleanupItems() {
  for (const item of _items.values()) {
    try { item?.destroy?.(); } catch (e) {}
  }
  _items.clear();
  _owners.clear();
}

function makeAppMenuOpenWrapper(original) {
  return function (...args) {
    try {
      const appInfo = this._app?.app_info;
      let desktopId = appInfo?.get_id?.();
      let command = appInfo?.get_executable?.();

      if (!(desktopId && EXCLUDED.has(desktopId))) {
        if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
          const flatpakId = desktopId.replace(/\.desktop$/, '');
          if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
        }
        if (command) insertLaunchItem(this, command);
      }
    } catch (e) { logDebug(`AppMenu wrapper error: ${e}`); }
    return original.apply(this, args);
  };
}

function makeAppIconWrapper(original) {
  return function (...args) {
    const result = original.apply(this, args);
    try {
      const appInfo = (this.app || this._app || this._delegate?.app)?.app_info;
      let desktopId = appInfo?.get_id?.();
      let command = appInfo?.get_executable?.();

      if (!(desktopId && EXCLUDED.has(desktopId))) {
        if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
          const flatpakId = desktopId.replace(/\.desktop$/, '');
          if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
        }
        if (command) insertLaunchItem(this, command);
      }
    } catch (e) { logDebug(`AppIcon wrapper error: ${e}`); }
    return result;
  };
}

/* Functional API expected by modern GNOME loaders */
export function init() { /* no-op */ }

export function enable() {
  cleanupItems();
  restoreOverrides();

  // Inject into AppMenu.open if available (application submenu)
  if (AppMenuModule?.AppMenu?.prototype?.open) {
    overrideMethod(AppMenuModule.AppMenu, 'open', makeAppMenuOpenWrapper);
    logDebug('Injected into AppMenu.open');
  }

  // Inject into AppIcon methods used by the overview / app grid
  if (AppDisplayModule?.AppIcon) {
    const methods = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
    for (const m of methods) {
      if (AppDisplayModule.AppIcon.prototype?.[m]) {
        overrideMethod(AppDisplayModule.AppIcon, m, makeAppIconWrapper);
        logDebug(`Injected into AppIcon.${m}`);
      }
    }
  }

  if (_orig.length === 0) {
    logDebug('No injection points found; extension will not add menu items.');
  }
}

export function disable() {
  cleanupItems();
  restoreOverrides();
}

/* Default class export to satisfy loaders that call `new extensionModule.default()` */
export default class RgbGpusTeamingExtension {
  constructor() { /* optional state */ }
  init() { return init(); }
  enable() { return enable(); }
  disable() { return disable(); }
}
