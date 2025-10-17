import GLib from 'gi://GLib';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class RgbGpusTeamingExtension extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();

        this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
            return function (...args) {
                if (this._rgbGpuMenuItem) return;

                const appInfo = this._app?.app_info;
                if (!appInfo) return;

                const command = appInfo.get_executable();
                if (!command) return;

                const scriptPath = GLib.build_filenamev([
                    GLib.get_home_dir(),
                    'rgb-gpus-teaming',
                    'gnome-launcher.sh'
                ]);

                if (!GLib.file_test(scriptPath, GLib.FileTest.EXISTS)) {
                    log(`RGB GPUs Teaming: Script not found at ${scriptPath}`);
                    return original.call(this, ...args);
                }

                log(`RGB GPUs Teaming: Injecting for ${appInfo.get_id()} with command ${command}`);

                this._rgbGpuMenuItem = this.addAction('Launch with RGB GPUs Teaming', () => {
                    GLib.spawn_command_line_async(`${scriptPath} "${command}"`);
                    if (Main.overview.visible) Main.overview.hide();
                });

                return original.call(this, ...args);
            };
        });
    }

    disable() {
        this._injectionManager.clear();
    }
}
