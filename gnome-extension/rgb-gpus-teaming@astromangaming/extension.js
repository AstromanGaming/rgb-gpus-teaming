/* extension.js
 *
 * RGB GPUs Teaming GNOME Shell extension (compatibility-focused)
 *
 * This file uses the classic init/enable/disable pattern and performs
 * defensive runtime detection of UI symbols (PopupMenu, AppMenu, AppIcon).
 * It monkey-patches methods at runtime and restores them on disable.
 */

const { GLib } = imports.gi;
const Main = imports.ui.main || {};
const Lang = imports.lang || null;

let PopupMenu = null;
try {
    PopupMenu = imports.ui.popupMenu;
} catch (e) {
    PopupMenu = null;
}

let AppMenuClass = null;
try {
    // Try common locations for AppMenu
    if (imports.ui.appMenu && imports.ui.appMenu.AppMenu) {
        AppMenuClass = imports.ui.appMenu.AppMenu;
    } else if (imports.ui.appDisplay && imports.ui.appDisplay.AppMenu) {
        AppMenuClass = imports.ui.appDisplay.AppMenu;
    } else if (imports.ui.appDisplay && imports.ui.appDisplay.AppIcon && imports.ui.appDisplay.AppIcon.prototype.open_context_menu) {
        // Some shells expose different shapes; we still try AppIcon-based injection later
        AppMenuClass = null;
    }
} catch (e) {
    AppMenuClass = null;
}

// Try to find AppIcon classes for alternate injection points
let AppIconClass = null;
try {
    if (imports.ui.appDisplay && imports.ui.appDisplay.AppIcon) {
        AppIconClass = imports.ui.appDisplay.AppIcon;
    } else if (imports.ui.dash && imports.ui.dash.AppIcon) {
        AppIconClass = imports.ui.dash.AppIcon;
    } else if (imports.ui.appIcon && imports.ui.appIcon.AppIcon) {
        AppIconClass = imports.ui.appIcon.AppIcon;
    }
} catch (e) {
    AppIconClass = null;
}

const EXTENSION_UUID = 'rgb-gpus-teaming@astromangaming';
const OPT_LAUNCHER = '/opt/RGB-GPUs-Teaming.OP/gnome-launcher.sh';
const EXCLUDED_DESKTOPS = new Set([
    'advisor.desktop',
    'gnome-setup.desktop',
    'manual-setup.desktop',
    'all-ways-egpu-auto-setup.desktop'
]);

/* State kept across enable/disable */
let _origMethods = []; // array of { object, name, original }
let _createdItems = new Map(); // Map(menuOwner -> menuItem)
let _injectedOwners = new Set();

function logDebug(msg) {
    try {
        global.log(`[${EXTENSION_UUID}] ${msg}`);
    } catch (e) {
        // ignore
    }
}

function scriptExistsAndExecutable(path) {
    try {
        return GLib.file_test(path, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE);
    } catch (e) {
        return false;
    }
}

function safeShellQuote(s) {
    // Use GLib.shell_quote if available, otherwise simple fallback
    try {
        return GLib.shell_quote(s);
    } catch (e) {
        // basic fallback: wrap in single quotes and escape single quotes
        return `'${s.replace(/'/g, "'\\''")}'`;
    }
}

function insertLaunchItem(menuOwner, command) {
    try {
        if (!PopupMenu || !PopupMenu.PopupMenuItem) {
            logDebug('PopupMenu API not available; skipping insertion.');
            return;
        }

        if (_injectedOwners.has(menuOwner)) return;

        if (!scriptExistsAndExecutable(OPT_LAUNCHER)) {
            logDebug(`Launcher script not found or not executable at ${OPT_LAUNCHER}`);
            return;
        }

        // Create menu item
        let item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
        item.connect('activate', () => {
            try {
                const fullCmd = `${safeShellQuote(OPT_LAUNCHER)} ${safeShellQuote(command)}`;
                GLib.spawn_command_line_async(fullCmd);
                if (Main.overview && Main.overview.visible) Main.overview.hide();
            } catch (e) {
                logDebug(`Failed to spawn launcher: ${e}`);
            }
        });

        // Try to insert at top if possible, otherwise append
        let inserted = false;
        try {
            if (menuOwner.menu && typeof menuOwner.menu.addMenuItem === 'function') {
                menuOwner.menu.addMenuItem(item, 0);
                inserted = true;
            }
        } catch (e) { /* ignore */ }

        if (!inserted) {
            try {
                if (typeof menuOwner.addMenuItem === 'function') {
                    menuOwner.addMenuItem(item, 0);
                    inserted = true;
                }
            } catch (e) { /* ignore */ }
        }

        if (!inserted) {
            try {
                if (menuOwner._menu && typeof menuOwner._menu.addMenuItem === 'function') {
                    menuOwner._menu.addMenuItem(item, 0);
                    inserted = true;
                }
            } catch (e) { /* ignore */ }
        }

        if (!inserted) {
            // fallback: append to any menu property
            try {
                if (menuOwner.menu && typeof menuOwner.menu.addMenuItem === 'function') {
                    menuOwner.menu.addMenuItem(item);
                    inserted = true;
                }
            } catch (e) { /* ignore */ }
        }

        // Track for cleanup
        _injectedOwners.add(menuOwner);
        _createdItems.set(menuOwner, item);
    } catch (e) {
        logDebug(`insertLaunchItem error: ${e}`);
    }
}

function overrideMethod(obj, methodName, wrapperFactory) {
    try {
        if (!obj || !obj.prototype || !obj.prototype[methodName]) return false;
        const original = obj.prototype[methodName];
        const wrapped = wrapperFactory(original);
        _origMethods.push({ object: obj.prototype, name: methodName, original: original });
        obj.prototype[methodName] = wrapped;
        return true;
    } catch (e) {
        logDebug(`overrideMethod failed for ${methodName}: ${e}`);
        return false;
    }
}

function restoreOverrides() {
    for (let entry of _origMethods) {
        try {
            entry.object[entry.name] = entry.original;
        } catch (e) {
            // ignore
        }
    }
    _origMethods = [];
}

function cleanupCreatedItems() {
    try {
        for (let [owner, item] of _createdItems.entries()) {
            try {
                if (item && typeof item.destroy === 'function') item.destroy();
            } catch (e) {
                // ignore
            }
        }
    } catch (e) {
        // ignore
    }
    _createdItems.clear();
    _injectedOwners.clear();
}

/* AppMenu injection wrapper */
function makeAppMenuOpenWrapper(original) {
    return function (...args) {
        try {
            // 'this' is the AppMenu instance
            const appInfo = this._app && this._app.app_info ? this._app.app_info : (this._app ? this._app : null);
            let desktopId = null;
            let command = null;

            try {
                if (this._app && this._app.app_info && typeof this._app.app_info.get_id === 'function') {
                    desktopId = this._app.app_info.get_id();
                } else if (this._app && typeof this._app.get_id === 'function') {
                    desktopId = this._app.get_id();
                }
            } catch (e) { /* ignore */ }

            try {
                if (this._app && this._app.app_info && typeof this._app.app_info.get_executable === 'function') {
                    command = this._app.app_info.get_executable();
                } else if (this._app && typeof this._app.get_executable === 'function') {
                    command = this._app.get_executable();
                }
            } catch (e) { /* ignore */ }

            if (desktopId && EXCLUDED_DESKTOPS.has(desktopId)) {
                // skip
            } else {
                if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
                    const flatpakId = desktopId.replace(/\.desktop$/, '');
                    if (GLib.find_program_in_path('flatpak')) {
                        command = `flatpak run ${flatpakId}`;
                    }
                }

                if (command) {
                    insertLaunchItem(this, command);
                }
            }
        } catch (e) {
            logDebug(`AppMenu wrapper error: ${e}`);
        }

        return original.apply(this, args);
    };
}

/* AppIcon override wrapper factory */
function makeAppIconWrapper(original) {
    return function (...args) {
        const result = original.apply(this, args);
        try {
            // Attempt to find app info on the icon instance
            const app = this.app || this._app || (this._delegate && this._delegate.app);
            const appInfo = app && app.app_info ? app.app_info : app;
            let desktopId = null;
            let command = null;

            try {
                if (appInfo && typeof appInfo.get_id === 'function') desktopId = appInfo.get_id();
            } catch (e) { /* ignore */ }

            try {
                if (appInfo && typeof appInfo.get_executable === 'function') command = appInfo.get_executable();
            } catch (e) { /* ignore */ }

            if (desktopId && EXCLUDED_DESKTOPS.has(desktopId)) {
                // skip
            } else {
                if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
                    const flatpakId = desktopId.replace(/\.desktop$/, '');
                    if (GLib.find_program_in_path('flatpak')) {
                        command = `flatpak run ${flatpakId}`;
                    }
                }

                if (command) {
                    insertLaunchItem(this, command);
                }
            }
        } catch (e) {
            logDebug(`AppIcon wrapper error: ${e}`);
        }
        return result;
    };
}

/* Standard GNOME extension entry points */
function init() {
    // nothing to initialize beyond top-level constants
}

function enable() {
    // Clear any previous state just in case
    cleanupCreatedItems();
    restoreOverrides();

    // Inject into AppMenu.open if available
    if (AppMenuClass && AppMenuClass.prototype && typeof AppMenuClass.prototype.open === 'function') {
        const ok = overrideMethod(AppMenuClass, 'open', makeAppMenuOpenWrapper);
        if (ok) logDebug('Injected into AppMenu.open');
    } else {
        logDebug('AppMenu class or open method not found; skipping AppMenu injection.');
    }

    // Try AppIcon injection points if AppIcon class resolved
    if (AppIconClass) {
        // Try a few method names that appear across versions
        const methodNames = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
        for (let m of methodNames) {
            if (AppIconClass.prototype && typeof AppIconClass.prototype[m] === 'function') {
                const ok = overrideMethod(AppIconClass, m, makeAppIconWrapper);
                if (ok) logDebug(`Injected into AppIcon.${m}`);
            }
        }
    } else {
        logDebug('AppIcon class not found; skipping AppIcon injections.');
    }

    // If neither injection point was available, log a message
    if ((_origMethods.length === 0)) {
        logDebug('No injection points found; extension will not add menu items on app menus.');
    }
}

function disable() {
    // Destroy created items and restore original methods
    cleanupCreatedItems();
    restoreOverrides();
}

var extension = {
    init: init,
    enable: enable,
    disable: disable
};
