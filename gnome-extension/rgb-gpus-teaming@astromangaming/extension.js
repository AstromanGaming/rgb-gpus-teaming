// extension.js (ES module style for metadata "type": "module")
// GNOME Shell 49 / GJS 1.86 compatible — pure ES module imports, exports init/enable/disable

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

function insertLaunchItem(owner, command) {
  if (!PopupMenu || !PopupMenu.PopupMenuItem) {
    logDebug('PopupMenu API not available; skipping insertion.');
    return;
  }
  if (_owners.has(owner)) return;
  if (!scriptOk(LAUNCHER)) {
    logDebug(`Launcher missing: ${LAUNCHER}`);
    return;
  }

  const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
  item.connect('activate', () => {
    try {
      const cmd = `${safeQuote(LAUNCHER)} ${safeQuote(command)}`;
      GLib.spawn_command_line_async(cmd);
      if (Main.overview?.visible) Main.overview.hide();
    } catch (e) {
      logDebug(`Failed to spawn launcher: ${e}`);
    }
  });

  // Try several insertion strategies (different GNOME versions expose different shapes)
  let inserted = false;
  try {
    if (owner.menu && typeof owner.menu.addMenuItem === 'function') {
      owner.menu.addMenuItem(item, 0);
      inserted = true;
    }
  } catch (e) {}

  if (!inserted) {
    try {
      if (typeof owner.addMenuItem === 'function') {
        owner.addMenuItem(item, 0);
        inserted = true;
      }
    } catch (e) {}
  }

  if (!inserted) {
    try {
      if (owner._menu && typeof owner._menu.addMenuItem === 'function') {
        owner._menu.addMenuItem(item, 0);
        inserted = true;
      }
    } catch (e) {}
  }

  if (!inserted) {
    try {
      if (owner.menu && typeof owner.menu.addMenuItem === 'function') {
        owner.menu.addMenuItem(item);
        inserted = true;
      }
    } catch (e) {}
  }

  _owners.add(owner);
  _items.set(owner, item);
}

function overrideMethod(obj, methodName, wrapperFactory) {
  if (!obj || !obj.prototype || typeof obj.prototype[methodName] !== 'function') return false;
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
    } catch (e) {
      logDebug(`AppMenu wrapper error: ${e}`);
    }
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
    } catch (e) {
      logDebug(`AppIcon wrapper error: ${e}`);
    }
    return result;
  };
}

// Module entry points
export function init() {
  // no-op
}

export function enable() {
  cleanupItems();
  restoreOverrides();

  // Prefer AppMenu injection if available
  if (AppMenuModule?.AppMenu?.prototype?.open) {
    overrideMethod(AppMenuModule.AppMenu, 'open', makeAppMenuOpenWrapper);
    logDebug('Injected into AppMenu.open');
  } else if (AppDisplayModule?.AppIcon) {
    // Fallback: try common AppIcon hook names across versions
    const methods = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
    for (const m of methods) {
      if (AppDisplayModule.AppIcon.prototype?.[m]) {
        overrideMethod(AppDisplayModule.AppIcon, m, makeAppIconWrapper);
        logDebug(`Injected into AppIcon.${m}`);
      }
    }
  } else {
    logDebug('No injection points found; extension will not add menu items.');
  }
}

export function disable() {
  cleanupItems();
  restoreOverrides();
}
