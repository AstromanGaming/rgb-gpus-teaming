import GLib from 'gi://GLib';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class GpuLauncherExtension extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();
        this._modifiedMenus = [];

        const injectGpuMenu = (menuInstance, appInfo) => {
            if (!appInfo || menuInstance._gpuMenuItem) return;

            const command = appInfo.get_executable();
            if (!command) return;

            log(`GPU Launcher: Injecting for ${appInfo.get_id()} with command ${command}`);

            const item = menuInstance.addAction('Launch with dedicated GPU', () => {
                GLib.spawn_command_line_async(`~/rgb-gpus-teaming/gnome-launcher.sh "${command}"`);
                if (Main.overview.visible) Main.overview.hide();
            });

            menuInstance._gpuMenuItem = item;
            this._modifiedMenus.push(menuInstance);
        };

        // App Grid (Dash)
        this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
            return function (...args) {
                injectGpuMenu(this, this._app?.app_info);
                return original.call(this, ...args);
            };
        });

        // Dock (safe dynamic access)
        let DockedAppMenu;
        try {
            const Dash = imports.ui.dash;
            DockedAppMenu = Dash?.DockedAppMenu;
        } catch (e) {
            log('GPU Launcher: Could not access dash.js — skipping dock injection');
        }

        if (DockedAppMenu && DockedAppMenu.prototype?.open) {
            this._injectionManager.overrideMethod(DockedAppMenu.prototype, 'open', original => {
                return function (...args) {
                    injectGpuMenu(this, this._app?.app_info);
                    return original.call(this, ...args);
                };
            });
        } else {
            log('GPU Launcher: DockedAppMenu not available — skipping dock injection');
        }
    }

    disable() {
        this._injectionManager.clear();
        this._injectionManager = null;

        for (let menu of this._modifiedMenus) {
            if (menu._gpuMenuItem) {
                menu._gpuMenuItem.destroy();
                delete menu._gpuMenuItem;
            }
        }

        this._modifiedMenus = [];
    }
}

