// The workspace build oracle's stand-in for DevEco's hvigorw.js
// (TASK-XPA-015). A registered Hvigor preset names this script as Node's
// first argument and pins it as a verified resource held open while the
// build runs; node.sh only checks that it can read it.
'use strict';
module.exports = { fixture: 'arkdeck-workspace-build-oracle' };
