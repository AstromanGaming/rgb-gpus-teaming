/* extension.js - minimal lifecycle, loads injector.js via Me.imports */
const ExtensionUtils = imports.misc.extensionUtils;
const Me = ExtensionUtils.getCurrentExtension();

let _injector = null;

function init() {
  // nothing heavy here
}

function enable() {
  try {
    // injector.js is loaded from the extension folder as a legacy module
    _injector = Me.imports.injector;
    if (_injector && typeof _injector.enable === 'function') {
      _injector.enable();
      log('rgb-gpus-teaming: injector enabled');
    } else {
      log('rgb-gpus-teaming: injector module missing enable()');
    }
  } catch (e) {
    log('rgb-gpus-teaming: enable error: ' + e);
  }
}

function disable() {
  try {
    if (_injector && typeof _injector.disable === 'function') {
      _injector.disable();
      log('rgb-gpus-teaming: injector disabled');
    }
  } catch (e) {
    log('rgb-gpus-teaming: disable error: ' + e);
  }
}