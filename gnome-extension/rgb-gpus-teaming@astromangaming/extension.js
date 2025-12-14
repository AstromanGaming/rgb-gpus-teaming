/* extension.js - compatibility-focused, GJS-style imports */

const { GLib } = imports.gi;
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
    try {
        return GLib.file_test(path, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE);
    } catch (e) { return false; }
}

function safeQuote(s) {
    try { return GLib.shell_quote(s); } catch (e) { return `'${s.replace(/'/g, "'\\''")}'`; }
}

function insertLaunchItem(owner, command) {
    if (!PopupMenu || !PopupMenu.PopupMenuItem) return;
    if (_owners.has(owner)) return;
    if (!scriptOk(LAUNCHER)) { logDebug(`Launcher missing: ${LAUNCHER}`); return; }

    let item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
    item.connect('activate', () => {
        try {
            const cmd = `${safeQuote(LAUNCHER)} ${safeQuote(command)}`;
            GLib.spawn_command_line_async(cmd);
            if (Main.overview && Main.overview.visible) Main.overview.hide();
        } catch (e) { logDebug(`spawn failed: ${e}`); }
    });

    // Try several insertion points
    try {
        if (owner.menu && typeof owner.menu.addMenuItem === 'function') owner.menu.addMenuItem(item, 0);
        else if (typeof owner.addMenuItem === 'function') owner.addMenuItem(item, 0);
        else if (owner._menu && typeof owner._menu.addMenuItem === 'function') owner._menu.addMenuItem(item, 0);
        else if (owner.menu && typeof owner.menu.addMenuItem === 'function') owner.menu.addMenuItem(item);
    } catch (e) { /* ignore insertion errors */ }

    _owners.add(owner);
    _items.set(owner, item);
}

function overrideMethod(obj, name, wrapperFactory) {
    if (!obj || !obj.prototype || !obj.prototype[name]) return false;
    const original = obj.prototype[name];
    const wrapped = wrapperFactory(original);
    _orig.push({ object: obj.prototype, name: name, original: original });
    obj.prototype[name] = wrapped;
    return true;
}

function restore() {
    for (let e of _orig) {
        try { e.object[e.name] = e.original; } catch (ex) {}
    }
    _orig = [];
}

function cleanup() {
    try {
        for (let [owner, item] of _items) {
            try { if (item && typeof item.destroy === 'function') item.destroy(); } catch (e) {}
        }
    } catch (e) {}
    _items.clear();
    _owners.clear();
}

function appMenuWrapper(original) {
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

function appIconWrapper(original) {
    return function (...args) {
        const res = original.apply(this, args);
        try {
            const app = this.app || this._app || (this._delegate && this._delegate.app);
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
        return res;
    };
}

/* GNOME extension entry points */
function init() { /* nothing */ }

function enable() {
    cleanup();
    restore();

    // AppMenu injection
    if (AppMenu && AppMenu.AppMenu && typeof AppMenu.AppMenu.prototype.open === 'function') {
        overrideMethod(AppMenu.AppMenu, 'open', appMenuWrapper);
        logDebug('Injected AppMenu.open');
    } else if (AppDisplay && AppDisplay.AppIcon) {
        // fallback: try AppIcon methods
        const iconClass = AppDisplay.AppIcon;
        const methods = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
        for (let m of methods) {
            if (iconClass.prototype && typeof iconClass.prototype[m] === 'function') {
                overrideMethod(iconClass, m, appIconWrapper);
                logDebug(`Injected AppIcon.${m}`);
            }
        }
    } else {
        logDebug('No AppMenu/AppIcon injection points found; extension will be mostly inert.');
    }
}

function disable() {
    cleanup();
    restore();
}

var extension = { init: init, enable: enable, disable: disable };
