import GLib from 'gi://GLib';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
// AppIcon may live in different modules across GNOME Shell versions — resolve at runtime
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

let AppIcon = null;
// Try known locations for AppIcon across GNOME Shell versions
try {
    AppIcon = imports.ui.appDisplay?.AppIcon || null;
} catch (e) { /* ignore */ }
if (!AppIcon) {
    try {
        AppIcon = imports.ui.dash?.AppIcon || null;
    } catch (e) { /* ignore */ }
}
if (!AppIcon) {
    try {
        AppIcon = imports.ui.appIcon?.AppIcon || null;
    } catch (e) { /* ignore */ }
}
if (!AppIcon) {
    log('RGB GPUs Teaming: AppIcon symbol not found in known imports; AppIcon-related injection will be skipped.');
}

export default class RgbGpusTeamingExtension extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();

        // Use iterable collections so we can clean up on disable()
        this._injectedMenus = new Set();
        this._createdItems = new Map();

        const excludedDesktopIds = new Set([
            'advisor.desktop',
            'gnome-setup.desktop',
            'manual-setup.desktop',
            'all-ways-egpu-auto-setup.desktop'
        ]);

        // Use the system-wide launcher under /opt
        const getLauncherScript = () => '/opt/RGB-GPUs-Teaming.OP/gnome-launcher.sh';

        const scriptExistsAndExecutable = (path) =>
            GLib.file_test(path, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE);

        const insertLaunchItem = (menuOwner, command) => {
            try {
                if (this._injectedMenus.has(menuOwner)) return;

                const scriptPath = getLauncherScript();
                if (!scriptExistsAndExecutable(scriptPath)) {
                    log(`RGB GPUs Teaming: launcher script not found or not executable at ${scriptPath}`);
                    return;
                }

                const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
                item.connect('activate', () => {
                    // Quote script and command safely
                    const fullCmd = `${GLib.shell_quote(scriptPath)} ${GLib.shell_quote(command)}`;
                    GLib.spawn_command_line_async(fullCmd);
                    if (Main.overview && Main.overview.visible) Main.overview.hide();
                });

                // Insert into known menu shapes; prefer top insertion when possible
                let inserted = false;
                if (menuOwner.menu && typeof menuOwner.menu.addMenuItem === 'function') {
                    try { menuOwner.menu.addMenuItem(item, 0); inserted = true; } catch (e) {}
                }
                if (!inserted && typeof menuOwner.addMenuItem === 'function') {
                    try { menuOwner.addMenuItem(item, 0); inserted = true; } catch (e) {}
                }
                if (!inserted && menuOwner._menu && typeof menuOwner._menu.addMenuItem === 'function') {
                    try { menuOwner._menu.addMenuItem(item, 0); inserted = true; } catch (e) {}
                }
                if (!inserted) {
                    // fallback: append to any menu property if available
                    if (menuOwner.menu && typeof menuOwner.menu.addMenuItem === 'function') {
                        try { menuOwner.menu.addMenuItem(item); inserted = true; } catch (e) {}
                    }
                }

                // Track for cleanup
                this._injectedMenus.add(menuOwner);
                this._createdItems.set(menuOwner, item);
            } catch (e) {
                log(`RGB GPUs Teaming: failed to insert launch item: ${e}`);
            }
        };

        // Inject into AppMenu.prototype.open
        this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
            return function (...args) {
                try {
                    if (this._injectedMenus && this._injectedMenus.has(this)) {
                        return original.apply(this, args);
                    }

                    const appInfo = this._app?.app_info;
                    if (!appInfo) return original.apply(this, args);

                    const desktopId = appInfo.get_id?.();
                    let command = appInfo.get_executable?.();

                    if (desktopId && excludedDesktopIds.has(desktopId)) {
                        return original.apply(this, args);
                    }

                    if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
                        const flatpakId = desktopId.replace(/\.desktop$/, '');
                        if (GLib.find_program_in_path('flatpak')) {
                            command = `flatpak run ${flatpakId}`;
                        }
                    }

                    if (!command) return original.apply(this, args);

                    insertLaunchItem(this, command);
                } catch (e) {
                    log(`RGB GPUs Teaming: AppMenu injection error: ${e}`);
                }

                return original.apply(this, args);
            };
        });

        // Helper to try overriding AppIcon hook points (only if AppIcon resolved)
        const tryOverride = (klass, methodName) => {
            if (!klass) return;
            if (klass.prototype && klass.prototype[methodName]) {
                this._injectionManager.overrideMethod(klass.prototype, methodName, original => {
                    return function (...args) {
                        const result = original.apply(this, args);

                        try {
                            if (this._injectedMenus && this._injectedMenus.has(this)) {
                                return result;
                            }

                            const app = this.app || this._app || this._delegate?.app;
                            const appInfo = app?.app_info;
                            if (!appInfo) return result;

                            const desktopId = appInfo.get_id?.();
                            let command = appInfo.get_executable?.();

                            if (desktopId && excludedDesktopIds.has(desktopId)) {
                                return result;
                            }

                            if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
                                const flatpakId = desktopId.replace(/\.desktop$/, '');
                                if (GLib.find_program_in_path('flatpak')) {
                                    command = `flatpak run ${flatpakId}`;
                                }
                            }

                            if (!command) return result;

                            const menuOwner = this;
                            insertLaunchItem(menuOwner, command);
                        } catch (e) {
                            log(`RGB GPUs Teaming: AppIcon injection error: ${e}`);
                        }

                        return result;
                    };
                });
            }
        };

        // Only attempt AppIcon overrides if we resolved AppIcon at runtime
        if (AppIcon) {
            tryOverride(AppIcon, '_onButtonPress');
            tryOverride(AppIcon, '_showContextMenu');
            tryOverride(AppIcon, 'open_context_menu');
        } else {
            log('RGB GPUs Teaming: skipping AppIcon injections because AppIcon symbol was not found.');
        }
    }

    disable() {
        // Destroy created menu items and clear tracking collections
        try {
            for (const [owner, item] of this._createdItems.entries()) {
                try {
                    if (item && typeof item.destroy === 'function') item.destroy();
                } catch (e) {
                    // ignore per-instance cleanup errors
                }
            }
        } catch (e) {
            // ignore
        }

        this._createdItems.clear();
        this._injectedMenus.clear();

        if (this._injectionManager) {
            this._injectionManager.clear();
            this._injectionManager = null;
        }
    }
}
