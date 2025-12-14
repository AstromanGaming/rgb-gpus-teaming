// extension.js (ES module style) — requires metadata.json "type": "module"

import GLib from 'gi://GLib';

// Use the legacy imports object for GNOME internals where needed.
// This is allowed inside modules and avoids relying on resource:/// modules
// that may not export the symbols you expect.
const Main = imports.ui.main;
const PopupMenu = imports.ui.popupMenu || null;
const AppDisplay = imports.ui.appDisplay || null;
const AppMenu = imports.ui.appMenu || null;

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

function insertLaunchItem(owner, command) {
  if (!PopupMenu || !PopupMenu.PopupMenuItem) return;
  if (_owners.has(owner)) return;
  if (!scriptOk(LAUNCHER)) { logDebug(`Launcher missing: ${LAUNCHER}`); return; }

  const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
  item.connect('activate', () => {
    try {
      const cmd = `${safeQuote(LAUNCHER)} ${safeQuote(command)}`;
      GLib.spawn_command_line_async(cmd);
      if (Main.overview && Main.overview.visible) Main.overview.hide();
    } catch (e) { logDebug(`spawn failed: ${e}`); }
  });

  let inserted = false;
  try {
    if (owner.menu && typeof owner.menu.addMenuItem === 'function') { owner.menu.addMenuItem(item, 0); inserted = true; }
  } catch (e) {}
  if (!inserted) {
    try { if (typeof owner.addMenuItem === 'function') { owner.addMenuItem(item, 0); inserted = true; } } catch (e) {}
  }
  if (!inserted) {
    try { if (owner._menu && typeof owner._menu.addMenuItem === 'function') { owner._menu.addMenuItem(item, 0); inserted = true; } } catch (e) {}
  }
  if (!inserted) {
    try { if (owner.menu && typeof owner.menu.addMenuItem === 'function') owner.menu.addMenuItem(item); } catch (e) {}
  }

  _owners.add(owner);
  _items.set(owner, item);
}

function overrideMethod(obj, methodName, wrapperFactory) {
  if (!obj || !obj.prototype || !obj.prototype[methodName]) return false;
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

function cleanupCreatedItems() {
  for (const [owner, item] of _items.entries()) {
    try { if (item && typeof item.destroy === 'function') item.destroy(); } catch (e) {}
  }
  _items.clear();
  _owners.clear();
}

function makeAppMenuOpenWrapper(original) {
  return function (...args) {
    try {
      const appInfo = this._app && this._app.app_info ? this._app.app_info : (this._app || null);
      let desktopId = null, command = null;
      try { if (appInfo && typeof appInfo.get_id === 'function') desktopId = appInfo.get_id(); } catch (e) {}
      try { if (appInfo && typeof appInfo.get_executable === 'function') command = appInfo.get_executable(); } catch (e) {}

      if (!(desktopId && EXCLUDED.has(desktopId))) {
        if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
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
      const app = this.app || this._app || this._delegate?.app;
      const appInfo = app && app.app_info ? app.app_info : app;
      let desktopId = null, command = null;
      try { if (appInfo && typeof appInfo.get_id === 'function') desktopId = appInfo.get_id(); } catch (e) {}
      try { if (appInfo && typeof appInfo.get_executable === 'function') command = appInfo.get_executable(); } catch (e) {}

      if (!(desktopId && EXCLUDED.has(desktopId))) {
        if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
          const flatpakId = desktopId.replace(/\.desktop$/, '');
          if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
        }
        if (command) insertLaunchItem(this, command);
      }
    } catch (e) { logDebug(`AppIcon wrapper error: ${e}`); }
    return result;
  };
}

// Module exports required by metadata "type": "module"
export function init() { /* nothing to init */ }

export function enable() {
  cleanupCreatedItems();
  restoreOverrides();

  if (AppMenu && AppMenu.AppMenu && typeof AppMenu.AppMenu.prototype.open === 'function') {
    overrideMethod(AppMenu.AppMenu, 'open', makeAppMenuOpenWrapper);
    logDebug('Injected into AppMenu.open');
  } else if (AppDisplay && AppDisplay.AppIcon) {
    const methodNames = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
    for (const m of methodNames) {
      if (AppDisplay.AppIcon.prototype && typeof AppDisplay.AppIcon.prototype[m] === 'function') {
        overrideMethod(AppDisplay.AppIcon, m, makeAppIconWrapper);
        logDebug(`Injected into AppIcon.${m}`);
      }
    }
  } else {
    logDebug('No injection points found; extension will not add menu items.');
  }
}

export function disable() {
  cleanupCreatedItems();
  restoreOverrides();
}
