import GLib from 'gi://GLib';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import { AppIcon } from 'resource:///org/gnome/shell/ui/appIcon.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

/*
  Updated extension to inject a "Launch with RGB GPUs Teaming" menu item:
  - into application menus (AppMenu) as before
  - into dock/app-grid icons (AppIcon) so it appears in the GNOME Dock and App Grid
  Notes:
  - We add the menu item per AppMenu/AppIcon instance and track created items so they
    can be removed cleanly on disable().
  - Commands are safely quoted before being passed to the helper script.
  - We avoid modifying global state and use InjectionManager to restore original methods.
*/

export default class RgbGpusTeamingExtension extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();

        // Track injected AppMenu/AppIcon instances so we inject once per instance
        this._injectedMenus = new WeakSet();
        this._createdItems = new WeakMap();

        // Desktop IDs to skip (same as before)
        const excludedDesktopIds = new Set([
            'advisor.desktop',
            'gnome-setup.desktop',
            'manual-setup.desktop'
        ]);

        // Helper to build the launcher script path
        const getLauncherScript = () => GLib.build_filenamev([
            GLib.get_home_dir(),
            'RGB-GPUs-Teaming.OP',
            'gnome-launcher.sh'
        ]);

        // Helper to create and insert the menu item into a menu-like object
        const insertLaunchItem = (menuOwner, command) => {
            try {
                // Avoid double-injecting into the same owner
                if (this._injectedMenus.has(menuOwner)) return;

                const scriptPath = getLauncherScript();
                if (!GLib.file_test(scriptPath, GLib.FileTest.EXISTS)) {
                    log(`RGB GPUs Teaming: launcher script not found at ${scriptPath}`);
                    return;
                }

                const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
                item.connect('activate', () => {
                    // Safely quote both script path and command
                    const fullCmd = `${GLib.shell_quote(scriptPath)} ${GLib.shell_quote(command)}`;
                    GLib.spawn_command_line_async(fullCmd);
                    if (Main.overview.visible) Main.overview.hide();
                });

                // Try to insert at top if possible, otherwise append
                if (menuOwner.menu && typeof menuOwner.menu.addMenuItem === 'function') {
                    menuOwner.menu.addMenuItem(item, 0);
                } else if (typeof menuOwner.addMenuItem === 'function') {
                    menuOwner.addMenuItem(item, 0);
                } else if (menuOwner._menu && typeof menuOwner._menu.addMenuItem === 'function') {
                    menuOwner._menu.addMenuItem(item, 0);
                } else {
                    // fallback: try to append to any menu property
                    if (menuOwner.menu && typeof menuOwner.menu.addMenuItem === 'function')
                        menuOwner.menu.addMenuItem(item);
                }

                this._injectedMenus.add(menuOwner);
                this._createdItems.set(menuOwner, item);
            } catch (e) {
                log(`RGB GPUs Teaming: failed to insert launch item: ${e}`);
            }
        };

        //
        // 1) Inject into AppMenu.prototype.open (existing behavior)
        //
        this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
            return function (...args) {
                // If already injected for this AppMenu instance, call original
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

                // If desktopId looks like a flatpak .desktop, prefer flatpak run
                if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
                    const flatpakId = desktopId.replace(/\.desktop$/, '');
                    if (GLib.find_program_in_path('flatpak')) {
                        command = `flatpak run ${flatpakId}`;
                    }
                }

                if (!command) return original.apply(this, args);

                insertLaunchItem(this, command);

                return original.apply(this, args);
            };
        });

        //
        // 2) Inject into AppIcon interactions (covers Dock and App Grid)
        //
        // AppIcon is used for icons in the dash (dock) and the app grid. We override
        // the method that builds or shows the context menu so we can add our item.
        //
        // Different GNOME versions may use different internal names; _onButtonPress is common.
        // We override both _onButtonPress and _showContextMenu (if present) defensively.
        //
        const tryOverride = (klass, methodName) => {
            if (klass && klass.prototype && klass.prototype[methodName]) {
                this._injectionManager.overrideMethod(klass.prototype, methodName, original => {
                    return function (...args) {
                        // Call original first to ensure menu exists/behaviors run
                        const result = original.apply(this, args);

                        try {
                            // If we already injected for this AppIcon instance, skip
                            if (this._injectedMenus && this._injectedMenus.has(this)) {
                                return result;
                            }

                            // Try to obtain app info and desktop id
                            const app = this.app || this._app || this._delegate?.app;
                            const appInfo = app?.app_info;
                            if (!appInfo) return result;

                            const desktopId = appInfo.get_id?.();
                            let command = appInfo.get_executable?.();

                            if (desktopId && excludedDesktopIds.has(desktopId)) {
                                return result;
                            }

                            // Prefer flatpak run if desktopId indicates a flatpak and no executable
                            if ((!command || command.length === 0) && desktopId && desktopId.endsWith('.desktop')) {
                                const flatpakId = desktopId.replace(/\.desktop$/, '');
                                if (GLib.find_program_in_path('flatpak')) {
                                    command = `flatpak run ${flatpakId}`;
                                }
                            }

                            if (!command) return result;

                            // Determine the menu owner: many AppIcon implementations expose `menu` or `_menu`
                            const menuOwner = this; // insertLaunchItem handles different shapes
                            insertLaunchItem(menuOwner, command);
                        } catch (e) {
                            log(`RGB GPUs Teaming: AppIcon injection error: ${e}`);
                        }

                        return result;
                    };
                });
            }
        };

        // Try common AppIcon hook points
        tryOverride(AppIcon, '_onButtonPress');
        tryOverride(AppIcon, '_showContextMenu');
        tryOverride(AppIcon, 'open_context_menu'); // some versions
    }

    disable() {
        // Remove created menu items
        try {
            for (const [owner, item] of this._createdItems) {
                try {
                    if (item && typeof item.destroy === 'function') item.destroy();
                } catch (e) {
                    // ignore per-instance cleanup errors
                }
            }
        } catch (e) {
            // ignore
        }

        this._createdItems = null;
        this._injectedMenus = null;

        if (this._injectionManager) {
            this._injectionManager.clear();
            this._injectionManager = null;
        }
    }
}
