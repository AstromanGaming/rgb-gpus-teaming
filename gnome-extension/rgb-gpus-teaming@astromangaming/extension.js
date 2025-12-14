// extension.js (ES module style)

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
  global.log(`[${EXTENSION_UUID}] ${msg}`);
}

function scriptOk(path) {
  return GLib.file_test(path, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE);
}

function safeQuote(s) {
  return GLib.shell_quote(s);
}

function insertLaunchItem(owner, command) {
  if (_owners.has(owner)) return;
  if (!scriptOk(LAUNCHER)) {
    logDebug(`Launcher missing: ${LAUNCHER}`);
    return;
  }

  const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
  item.connect('activate', () => {
    const cmd = `${safeQuote(LAUNCHER)} ${safeQuote(command)}`;
    GLib.spawn_command_line_async(cmd);
    if (Main.overview?.visible) Main.overview.hide();
  });

  try {
    owner.menu?.addMenuItem(item, 0);
  } catch (e) {
    try { owner.addMenuItem?.(item, 0); } catch {}
  }

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
    e.object[e.name] = e.original;
  }
  _orig = [];
}

function cleanupItems() {
  for (const [, item] of _items) {
    item?.destroy?.();
  }
  _items.clear();
  _owners.clear();
}

function makeAppMenuOpenWrapper(original) {
  return function (...args) {
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
    return original.apply(this, args);
  };
}

function makeAppIconWrapper(original) {
  return function (...args) {
    const result = original.apply(this, args);
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
    return result;
  };
}

// Module entry points
export function init() {}

export function enable() {
  cleanupItems();
  restoreOverrides();

  if (AppMenuModule.AppMenu?.prototype?.open) {
    overrideMethod(AppMenuModule.AppMenu, 'open', makeAppMenuOpenWrapper);
    logDebug('Injected into AppMenu.open');
  } else if (AppDisplayModule.AppIcon) {
    const methods = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
    for (const m of methods) {
      if (AppDisplayModule.AppIcon.prototype?.[m]) {
        overrideMethod(AppDisplayModule.AppIcon, m, makeAppIconWrapper);
        logDebug(`Injected into AppIcon.${m}`);
      }
    }
  } else {
    logDebug('No injection points found.');
  }
}

export function disable() {
  cleanupItems();
  restoreOverrides();
}
