import GLib from 'gi://GLib';
import { Extension, InjectionManager } from 'resource:///org/gnome/shell/extensions/extension.js';
import { AppMenu } from 'resource:///org/gnome/shell/ui/appMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class RgbGpusTeamingExtension extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();

        const excludedDesktopIds = [
            'advisor.desktop',
            'gnome-setup.desktop',
            'manual-setup.desktop',
            'all-ways-egpu-auto-setup.desktop',
            'all-ways-egpu.desktop'
        ];

        /**
         * Try to derive a snap command for the given desktopId/command/appInfo.
         *
         * Strategy:
         *  - If desktopId looks like a snap (snap id present as desktop name), prefer `snap run <snapId>`
         *    when /snap/<snapId>/current exists.
         *  - If /snap/bin/<snapId> exists, prefer that path.
         *  - If the original command already contains '/snap/' or '/var/lib/snapd/', use it as-is.
         *  - Otherwise return null to indicate "not a snap" / no snap-specific command found.
         */
        const getSnapCommand = (desktopId, command, appInfo) => {
            if (!desktopId && !command) return null;

            // Helper to test for a path
            const exists = (path) => GLib.file_test(path, GLib.FileTest.EXISTS);

            // Normalize candidate snap id from desktopId
            let snapCandidates = [];

            if (desktopId) {
                // remove .desktop suffix
                let base = desktopId.replace(/\.desktop$/, '');
                // common snap desktop naming may include dots; try a few variants
                snapCandidates.push(base);
                // sometimes snap desktop ids are prefixed with "snap." or contain "snap-"
                if (base.startsWith('snap.')) snapCandidates.push(base.replace(/^snap\./, ''));
                if (base.includes('-snap-')) snapCandidates.push(base.replace(/-snap-.*$/, ''));
                // also try last segment after dots
                const parts = base.split('.');
                if (parts.length > 1) snapCandidates.push(parts[parts.length - 1]);
            }

            // If appInfo is available, try to extract a better candidate
            try {
                if (appInfo && typeof appInfo.get_id === 'function') {
                    const id = appInfo.get_id();
                    if (id) {
                        snapCandidates.push(id.replace(/\.desktop$/, ''));
                        if (id.startsWith('snap.')) snapCandidates.push(id.replace(/^snap\./, ''));
                    }
                }
            } catch (e) {
                // ignore
            }

            // Also inspect the provided command for snap paths
            if (command) {
                if (command.indexOf('/snap/') !== -1 || command.indexOf('/var/lib/snapd/') !== -1) {
                    // If the command already references a snap path, use it directly
                    return command;
                }
                // If command is a simple name, also try that as candidate
                const cmdBase = command.split(' ')[0];
                if (cmdBase) snapCandidates.push(cmdBase);
            }

            // Deduplicate candidates while preserving order
            const seen = {};
            snapCandidates = snapCandidates.filter(c => {
                if (!c) return false;
                if (seen[c]) return false;
                seen[c] = true;
                return true;
            });

            // Check for canonical snap locations
            for (let snapId of snapCandidates) {
                // canonical mount
                const snapMount = `/snap/${snapId}/current`;
                if (exists(snapMount)) {
                    // prefer `snap run <snapId>` so confinement and environment are correct
                    return `snap run ${snapId}`;
                }
                // check /snap/bin wrapper
                const snapBin = `/snap/bin/${snapId}`;
                if (exists(snapBin)) {
                    return snapBin;
                }
                // some systems expose hostfs path for snap content
                const hostfsPath = `/var/lib/snapd/hostfs/snap/${snapId}/current`;
                if (exists(hostfsPath)) {
                    return `snap run ${snapId}`;
                }
            }

            // No snap-specific command found
            return null;
        };

        this._injectionManager.overrideMethod(AppMenu.prototype, 'open', original => {
            return function (...args) {
                if (this._rgbGpuInjected) return original.call(this, ...args);

                const appInfo = this._app?.app_info;
                if (!appInfo) return original.call(this, ...args);

                const desktopId = appInfo.get_id();
                let command = appInfo.get_executable();

                // Exclude specific desktop files
                if (excludedDesktopIds.includes(desktopId)) {
                    log(`RGB GPUs Teaming: Skipping injection for excluded app ${desktopId}`);
                    return original.call(this, ...args);
                }

                // Flatpak handling (existing)
                if (command?.includes('flatpak') && desktopId?.endsWith('.desktop')) {
                    const flatpakId = desktopId.replace('.desktop', '');
                    command = `flatpak run ${flatpakId}`;
                }

                // Snap handling: try to derive a snap-specific command
                const snapCmd = getSnapCommand(desktopId, command, appInfo);
                if (snapCmd) {
                    log(`RGB GPUs Teaming: Detected snap for ${desktopId}, using command: ${snapCmd}`);
                    command = snapCmd;
                }

                if (!command) return original.call(this, ...args);

                // Use system install path under /opt
                const scriptPath = GLib.build_filenamev([
                    '/opt',
                    'rgb-gpus-teaming',
                    'gnome-launcher.sh'
                ]);

                if (!GLib.file_test(scriptPath, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE)) {
                    log(`RGB GPUs Teaming: Script not found or not executable at ${scriptPath}`);
                    return original.call(this, ...args);
                }

                log(`RGB GPUs Teaming: Injecting for ${desktopId} with command ${command}`);

                this.addAction('Launch with RGB GPUs Teaming', () => {
                    // Quote the command to preserve spaces; spawn_command_line_async will run the whole string
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
