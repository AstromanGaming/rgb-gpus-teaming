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
let _dashSignals = [];        // { obj, id }
let _dashActorHandlers = [];  // { actor, id }
let _pollSourceId = 0;

/* Logging helper */
function logDebug(msg) {
  try { global.log(`[${EXTENSION_UUID}] ${msg}`); } catch (e) {}
}

/* Check script exists and is executable */
function scriptOk(path) {
  try { return GLib.file_test(path, GLib.FileTest.EXISTS | GLib.FileTest.IS_EXECUTABLE); }
  catch (e) { return false; }
}

/* Shell-quote helper */
function safeQuote(s) {
  try { return GLib.shell_quote(s); } catch (e) { return `'${s.replace(/'/g, "'\\''")}'`; }
}

/* Insert the launch item at the end of the menu or sub-menu.
   Try several common menu containers used by GNOME and extensions. */
function insertLaunchItem(owner, command) {
  if (!PopupMenu || !PopupMenu.PopupMenuItem) return;
  if (!owner) return;
  if (_owners.has(owner)) return;
  if (!scriptOk(LAUNCHER)) return;

  const item = new PopupMenu.PopupMenuItem('Launch with RGB GPUs Teaming');
  item.connect('activate', () => {
    try {
      const cmd = `${safeQuote(LAUNCHER)} ${safeQuote(command)}`;
      GLib.spawn_command_line_async(cmd);
      if (Main.overview?.visible) Main.overview.hide();
    } catch (e) { logDebug(`spawn failed: ${e}`); }
  });

  // Try common containers (append/end)
  try { if (owner._appMenu && typeof owner._appMenu.addMenuItem === 'function') owner._appMenu.addMenuItem(item); } catch (e) {}
  try { if (owner.menu && typeof owner.menu.addMenuItem === 'function') owner.menu.addMenuItem(item); } catch (e) {}
  try { if (owner._menu && typeof owner._menu.addMenuItem === 'function') owner._menu.addMenuItem(item); } catch (e) {}
  try { if (owner.addMenuItem && typeof owner.addMenuItem === 'function') owner.addMenuItem(item); } catch (e) {}

  // Some implementations expose getMenu() or createMenu(); try to append if available
  try {
    if (typeof owner.getMenu === 'function') {
      const m = owner.getMenu();
      if (m && typeof m.addMenuItem === 'function') m.addMenuItem(item);
    }
  } catch (e) {}

  _owners.add(owner);
  _items.set(owner, item);
}

/* Generic override helper */
function overrideMethod(obj, methodName, wrapperFactory) {
  if (!obj?.prototype?.[methodName]) return false;
  const original = obj.prototype[methodName];
  const wrapped = wrapperFactory(original);
  _orig.push({ object: obj.prototype, name: methodName, original });
  obj.prototype[methodName] = wrapped;
  return true;
}

/* Restore overrides */
function restoreOverrides() {
  for (const e of _orig) {
    try { e.object[e.name] = e.original; } catch (ex) {}
  }
  _orig = [];
}

/* Destroy created menu items and clear bookkeeping */
function cleanupItems() {
  for (const item of _items.values()) {
    try { item?.destroy?.(); } catch (e) {}
  }
  _items.clear();
  _owners.clear();

  // disconnect dash delegate signals
  for (const s of _dashSignals) {
    try { s.obj.disconnect(s.id); } catch (e) {}
  }
  _dashSignals = [];

  // disconnect actor handlers
  for (const h of _dashActorHandlers) {
    try { h.actor.disconnect(h.id); } catch (e) {}
  }
  _dashActorHandlers = [];

  // remove poll source if present
  try {
    if (_pollSourceId) {
      GLib.source_remove(_pollSourceId);
      _pollSourceId = 0;
    }
  } catch (e) {}
}

/* AppMenu wrapper (application submenu) */
function makeAppMenuOpenWrapper(original) {
  return function (...args) {
    try {
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
    } catch (e) { logDebug(`AppMenu wrapper error: ${e}`); }
    return original.apply(this, args);
  };
}

/* AppIcon / Dash item wrapper (overview/app-grid and dock items) */
function makeAppIconWrapper(original) {
  return function (...args) {
    const result = original.apply(this, args);
    try {
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
    } catch (e) { logDebug(`AppIcon wrapper error: ${e}`); }
    return result;
  };
}

/* Try to attach to existing dash items (so already-visible icons get the menu) */
function attachToExistingDashItems() {
  try {
    const candidates = [];

    // Common places where dash items are stored across GNOME versions / extensions
    if (Main.dash && Array.isArray(Main.dash._items)) candidates.push(...Main.dash._items);
    if (Main.overview?.dash && Array.isArray(Main.overview.dash._items)) candidates.push(...Main.overview.dash._items);

    // Dash-to-Dock / Dash-to-Panel / Ubuntu Dock sometimes expose _delegate._items or _delegate._actors
    if (Main.dash && Main.dash._delegate) {
      try {
        const d = Main.dash._delegate;
        if (Array.isArray(d._items)) candidates.push(...d._items);
        if (Array.isArray(d._actors)) candidates.push(...d._actors);
      } catch (e) {}
    }

    // Ubuntu Dock / Dash-to-Dock specifics: some versions store launchers in Main.dash._launcher or _actors
    if (Main.dash && Main.dash._launcher && Array.isArray(Main.dash._launcher)) {
      candidates.push(...Main.dash._launcher);
    }

    // Deduplicate and attempt to insert when possible
    const seen = new Set();
    for (const owner of candidates) {
      if (!owner || seen.has(owner)) continue;
      seen.add(owner);

      try {
        const appInfo = (owner.app || owner._app || owner._delegate?.app)?.app_info;
        let desktopId = appInfo?.get_id?.();
        let command = appInfo?.get_executable?.();
        if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
          const flatpakId = desktopId.replace(/\.desktop$/, '');
          if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
        }
        if (command) {
          insertLaunchItem(owner, command);

          // Also attach a lightweight button-press handler to ensure insertion on interaction
          try {
            if (owner.connect && typeof owner.connect === 'function') {
              const id = owner.connect('button-press-event', () => {
                try { insertLaunchItem(owner, command); } catch (e) {}
                return false;
              });
              _dashActorHandlers.push({ actor: owner, id });
            }
          } catch (e) {}
        }
      } catch (e) {
        // ignore per-item errors
      }
    }
  } catch (e) {
    logDebug(`attachToExistingDashItems error: ${e}`);
  }
}

/* Recursively search an actor subtree for actors whose name or style class
   suggests they are the dock/dash container (Ubuntu Dock / Dash-to-Dock). */
function findDockActorsOnStage() {
  const matches = [];
  try {
    if (!global || !global.stage) return matches;

    const queue = [global.stage];
    while (queue.length) {
      const actor = queue.shift();
      if (!actor) continue;

      // actor.get_name may not exist on all objects; guard it
      let name = '';
      try { name = actor.get_name ? actor.get_name() : ''; } catch (e) { name = ''; }

      // style classes may be available via actor.get_style_class_name or actor.get_style_context
      let style = '';
      try {
        if (actor.get_style_class_name) style = actor.get_style_class_name() || '';
        else if (actor.get_style_context && actor.get_style_context().list_classes) {
          style = actor.get_style_context().list_classes().join(' ');
        }
      } catch (e) { style = ''; }

      const combined = `${name} ${style}`.toLowerCase();

      // common identifiers for Ubuntu Dock / Dash-to-Dock
      if (combined.includes('dash') || combined.includes('ubuntu-dock') || combined.includes('dash-to-dock') || combined.includes('dash-container') || combined.includes('dock')) {
        matches.push(actor);
      }

      // enqueue children if available
      try {
        if (actor.get_children) {
          const children = actor.get_children();
          for (let i = 0; i < children.length; i++) queue.push(children[i]);
        } else if (actor.get_child_at_index) {
          const n = actor.get_n_children ? actor.get_n_children() : 0;
          for (let i = 0; i < n; i++) queue.push(actor.get_child_at_index(i));
        }
      } catch (e) {
        // ignore traversal errors
      }
    }
  } catch (e) {
    logDebug(`findDockActorsOnStage error: ${e}`);
  }
  return matches;
}

/* Attach handlers to actors found on the stage that look like dock items.
   This complements attachToExistingDashItems() and delegate signals. */
function attachStageDockActors() {
  try {
    const dockActors = findDockActorsOnStage();
    if (!dockActors || dockActors.length === 0) {
      logDebug('attachStageDockActors: no dock actors found on stage');
      return;
    }

    for (const dock of dockActors) {
      // traverse immediate children to find per-app actors
      try {
        const children = (dock.get_children && dock.get_children()) || [];
        for (let i = 0; i < children.length; i++) {
          const child = children[i];
          if (!child) continue;

          // Heuristic: app actors often have a child with a 'app' or 'launcher' property
          let owner = null;
          try {
            if (child._delegate) owner = child._delegate;
            else if (child._app) owner = child;
            else owner = child;
          } catch (e) { owner = child; }

          // Attach a button-press-event to ensure insertion on interaction
          try {
            if (owner && owner.connect && typeof owner.connect === 'function') {
              const id = owner.connect('button-press-event', () => {
                try {
                  const appInfo = (owner.app || owner._app || owner._delegate?.app)?.app_info;
                  let desktopId = appInfo?.get_id?.();
                  let command = appInfo?.get_executable?.();
                  if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
                    const flatpakId = desktopId.replace(/\.desktop$/, '');
                    if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
                  }
                  if (command) insertLaunchItem(owner, command);
                } catch (e) {}
                return false;
              });
              _dashActorHandlers.push({ actor: owner, id });
            }
          } catch (e) {}

          // If the child itself exposes a getMenu or _appMenu, try immediate insertion
          try {
            const appInfo = (child.app || child._app || child._delegate?.app)?.app_info;
            let desktopId = appInfo?.get_id?.();
            let command = appInfo?.get_executable?.();
            if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
              const flatpakId = desktopId.replace(/\.desktop$/, '');
              if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
            }
            if (command) insertLaunchItem(child, command);
          } catch (e) {}
        }
      } catch (e) {
        logDebug(`attachStageDockActors traverse error: ${e}`);
      }

      // Also try to connect to 'menu-created' on the dock actor itself (Ubuntu Dock sometimes emits it)
      try {
        if (dock.connect && typeof dock.connect === 'function') {
          const id2 = dock.connect('menu-created', (d, owner) => {
            try {
              const appInfo = (owner.app || owner._app || owner._delegate?.app)?.app_info;
              let desktopId = appInfo?.get_id?.();
              let command = appInfo?.get_executable?.();
              if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
                const flatpakId = desktopId.replace(/\.desktop$/, '');
                if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
              }
              if (command) insertLaunchItem(owner, command);
            } catch (e) { logDebug(`dock menu-created handler error: ${e}`); }
          });
          _dashSignals.push({ obj: dock, id: id2 });
        }
      } catch (e) {}
    }
  } catch (e) {
    logDebug(`attachStageDockActors error: ${e}`);
  }
}

/* Connect to dash delegate 'menu-created' or similar signals to append when menus are created */
function connectDashDelegateSignals() {
  try {
    // Many dash implementations expose a delegate with a 'menu-created' signal
    const delegate = Main.dash?._delegate || Main.overview?.dash?._delegate;
    if (delegate && typeof delegate.connect === 'function') {
      const id = delegate.connect('menu-created', (d, owner) => {
        try {
          const appInfo = (owner.app || owner._app || owner._delegate?.app)?.app_info;
          let desktopId = appInfo?.get_id?.();
          let command = appInfo?.get_executable?.();
          if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
            const flatpakId = desktopId.replace(/\.desktop$/, '');
            if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
          }
          if (command) insertLaunchItem(owner, command);
        } catch (e) { logDebug(`delegate menu-created handler error: ${e}`); }
      });
      _dashSignals.push({ obj: delegate, id });
    }

    // Ubuntu Dock (integrated) sometimes emits 'menu-created' on Main.dash itself
    if (Main.dash && typeof Main.dash.connect === 'function') {
      try {
        const id2 = Main.dash.connect('menu-created', (d, owner) => {
          try {
            const appInfo = (owner.app || owner._app || owner._delegate?.app)?.app_info;
            let desktopId = appInfo?.get_id?.();
            let command = appInfo?.get_executable?.();
            if ((!command || command.length === 0) && desktopId?.endsWith('.desktop')) {
              const flatpakId = desktopId.replace(/\.desktop$/, '');
              if (GLib.find_program_in_path('flatpak')) command = `flatpak run ${flatpakId}`;
            }
            if (command) insertLaunchItem(owner, command);
          } catch (e) { logDebug(`Main.dash menu-created handler error: ${e}`); }
        });
        _dashSignals.push({ obj: Main.dash, id: id2 });
      } catch (e) {}
    }
  } catch (e) {
    logDebug(`connectDashDelegateSignals error: ${e}`);
  }
}

/* Polling fallback: some docks initialize after extensions load.
   Poll a few times to catch Dash-to-Dock / Ubuntu Dock initialization. */
function startDashPoll() {
  try {
    let attempts = 0;
    const maxAttempts = 12; // poll for ~6 seconds (12 * 500ms)
    _pollSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
      try {
        attachToExistingDashItems();
        connectDashDelegateSignals();
        attachStageDockActors();
      } catch (e) {}
      attempts++;
      if (attempts >= maxAttempts) {
        _pollSourceId = 0;
        return false; // stop polling
      }
      return true; // continue polling
    });
    // store a dummy entry so cleanup removes it via GLib.source_remove
    _dashSignals.push({ obj: GLib, id: _pollSourceId });
  } catch (e) {
    logDebug(`startDashPoll error: ${e}`);
  }
}

/* Functional API expected by modern GNOME loaders */
export function init() { /* no-op */ }

export function enable() {
  cleanupItems();
  restoreOverrides();

  // AppMenu injection (application submenu)
  if (AppMenuModule?.AppMenu?.prototype?.open) {
    overrideMethod(AppMenuModule.AppMenu, 'open', makeAppMenuOpenWrapper);
    logDebug('Injected into AppMenu.open');
  }

  // AppIcon injection (overview / app grid)
  if (AppDisplayModule?.AppIcon) {
    const methods = ['_onButtonPress', '_showContextMenu', 'open_context_menu', 'show_context_menu'];
    for (const m of methods) {
      if (AppDisplayModule.AppIcon.prototype?.[m]) {
        overrideMethod(AppDisplayModule.AppIcon, m, makeAppIconWrapper);
        logDebug(`Injected into AppIcon.${m}`);
      }
    }
  }

  // Dash / Dock injection: try common prototypes and methods
  const dashCandidates = [
    AppDisplayModule.Dash,
    AppDisplayModule.DashItem,
    Main.overview?.dash?.constructor,
    Main.dash?.constructor,
    Main.dash?.Dash
  ];

  const dashMethods = ['_onSecondaryClick', '_showAppMenu', '_onButtonPress', 'open', 'show_context_menu', '_showContextMenu'];

  for (const cand of dashCandidates) {
    if (!cand || !cand.prototype) continue;
    for (const m of dashMethods) {
      if (cand.prototype[m]) {
        overrideMethod(cand, m, makeAppIconWrapper);
        logDebug(`Injected into dock candidate ${cand.name || '<anon>'}.${m}`);
      }
    }
  }

  // Attach to existing dash items so visible icons get the menu immediately
  attachToExistingDashItems();

  // Connect delegate signals (menu-created) as a robust fallback (covers Ubuntu Dock)
  connectDashDelegateSignals();

  // Attach actors found on stage (target Ubuntu Dock / Dash-to-Dock variants)
  attachStageDockActors();

  // Start polling for a short period to catch Dash-to-Dock / Ubuntu Dock initialization
  startDashPoll();

  if (_orig.length === 0 && _dashSignals.length === 0 && _dashActorHandlers.length === 0) {
    logDebug('No injection points found; extension will not add menu items.');
  }
}

export function disable() {
  cleanupItems();
  restoreOverrides();
}

/* Default class export to satisfy loaders that call `new extensionModule.default()` */
export default class RgbGpusTeamingExtension {
  constructor() { /* optional state */ }
  init() { return init(); }
  enable() { return enable(); }
  disable() { return disable(); }
}
