// extension.js (module style)
import GLib from 'gi://GLib';
const Main = imports.ui.main;
const PopupMenu = imports.ui.popupMenu || null;
const AppMenu = imports.ui.appMenu || null;
const AppDisplay = imports.ui.appDisplay || null;

const LAUNCHER = '/opt/RGB-GPUs-Teaming.OP/gnome-launcher.sh';
const EXCLUDED = new Set(['advisor.desktop','gnome-setup.desktop','manual-setup.desktop','all-ways-egpu-auto-setup.desktop']);

let _orig = [];
let _items = new Map();
let _owners = new Set();

function insertLaunchItem(owner, command) {
  if (!PopupMenu || !PopupMenu.PopupMenuItem) return;
  if (_owners.has(owner)) return;
  if (!GLib.file_test(LAUNCHER, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) return;

  const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
  item.connect('activate', () => {
    GLib.spawn_command_line_async(`${GLib.shell_quote(LAUNCHER)} ${GLib.shell_quote(command)}`);
    if (Main.overview?.visible) Main.overview.hide();
  });

  try { owner.menu?.addMenuItem(item, 0); } catch (e) { try { owner.addMenuItem?.(item, 0); } catch {} }
  _owners.add(owner);
  _items.set(owner, item);
}

function overrideMethod(obj, name, wrapperFactory) {
  if (!obj?.prototype?.[name]) return false;
  const original = obj.prototype[name];
  const wrapped = wrapperFactory(original);
  _orig.push({ object: obj.prototype, name, original });
  obj.prototype[name] = wrapped;
  return true;
}

function restoreOverrides() {
  for (const e of _orig) e.object[e.name] = e.original;
  _orig = [];
}

function cleanupItems() {
  for (const item of _items.values()) item?.destroy?.();
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

export function init() {}
export function enable() {
  cleanupItems();
  restoreOverrides();
  if (AppMenu?.AppMenu?.prototype?.open) {
    overrideMethod(AppMenu.AppMenu, 'open', makeAppMenuOpenWrapper);
  } else if (AppDisplay?.AppIcon) {
    const methods = ['_onButtonPress','_showContextMenu','open_context_menu','show_context_menu'];
    for (const m of methods) if (AppDisplay.AppIcon.prototype?.[m]) overrideMethod(AppDisplay.AppIcon, m, (orig)=>function(...a){ const r = orig.apply(this,a); try { const appInfo = (this.app||this._app||this._delegate?.app)?.app_info; let desktopId = appInfo?.get_id?.(); let command = appInfo?.get_executable?.(); if (!(desktopId && EXCLUDED.has(desktopId))) { if ((!command||command.length===0) && desktopId?.endsWith('.desktop')) { const flatpakId = desktopId.replace(/\.desktop$/,''); if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`; } if (command) insertLaunchItem(this, command); } } catch(e){} return r; });
  }
}
export function disable() {
  cleanupItems();
  restoreOverrides();
}
