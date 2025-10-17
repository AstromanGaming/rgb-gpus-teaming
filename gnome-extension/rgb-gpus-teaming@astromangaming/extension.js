import GLib from 'gi://GLib';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class RgbGpusTeamingExtension extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();

        this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
            return function (...args) {
                if (this._rgbGpuInjected) return original.call(this, ...args);

                const appInfo = this._app?.app_info;
                if (!appInfo) return original.call(this, ...args);

                const desktopId = appInfo.get_id();
                let command = appInfo.get_executable();

                if (command?.includes('flatpak') && desktopId?.endsWith('.desktop')) {
                    const flatpakId = desktopId.replace('.desktop', '');
                    command = `flatpak run ${flatpakId}`;
                }

                if (!command) return original.call(this, ...args);

                const scriptPath = GLib.build_filenamev([
                    GLib.get_home_dir(),
                    'rgb-gpus-teaming',
                    'gnome-launcher.sh'
                ]);

                if (!GLib.file_test(scriptPath, GLib.FileTest.EXISTS)) {
                    log(`RGB GPUs Teaming: Script not found at ${scriptPath}`);
                    return original.call(this, ...args);
                }

                log(`RGB GPUs Teaming: Injecting for ${desktopId} with command ${command}`);

                this.addAction('Launch with RGB GPUs Teaming', () => {
                    GLib.spawn_command_line_async(`${scriptPath} "${command}"`);
                    if (Main.overview.visible) Main.overview.hide();
                });

                this._rgbGpuInjected = true;

                return original.call(this, ...args);
            };
        });
    }

    disable() {
        this._injectionManager.clear();
    }
}
