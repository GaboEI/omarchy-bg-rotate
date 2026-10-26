import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// gabodev.bg-rotate service: owns the rotation schedule, persists its own
// config, and reports status to the panel. Wallpaper enumeration and theme
// parsing live in the bundled scripts/omarchy-bg-rotate; this file only
// schedules it, runs it and parses its JSON status.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/bg-rotate/config.json"

  // Bundled helper, resolved relative to the plugin so the plugin is
  // self-contained: `omarchy plugin add <repo>` copies the whole directory and
  // the script travels with it. `__sourceDir` is the directory omarchy-shell
  // loaded the plugin from (it keeps that marker for third-party plugins); the
  // omarchyPath lookup covers a host that does not pass it.
  readonly property string pluginDir: {
    var dir = root.manifest ? String(root.manifest.__sourceDir || "") : "";
    dir = dir.replace(/^file:\/\//, "").replace(/\/{2,}/g, "/").replace(/\/+$/, "");
    if (dir !== "")
      return dir;
    return root.omarchyPath !== "" ? root.omarchyPath + "/plugins/gabodev.bg-rotate" : "";
  }
  readonly property string rotateBin: root.pluginDir !== "" ? root.pluginDir + "/scripts/omarchy-bg-rotate" : ""

  // Set by probeScript(): every Process that runs the helper is gated on it,
  // so a copy installed without its script or its exec bit reports the problem
  // instead of failing silently.
  property bool scriptReady: false
  property bool statusRequested: false
  property bool probePending: false

  onRotateBinChanged: root.probeScript()

  Component.onCompleted: root.probeScript()

  // ---- Persisted config ----------------------------------------------------
  property bool enabled: false
  property string mode: "next"
  property int intervalMinutes: 20
  property double nextDueAt: 0

  // ---- Live status (from `omarchy-bg-rotate status`) -----------------------
  property string theme: ""
  property int count: 0
  property int index: -1
  property string current: ""

  // ---- Localized errors ----------------------------------------------------
  // The key and its arguments are stored, not the rendered text: `lastError`
  // is a binding over the same catalogs the panel reads, so switching language
  // re-renders an error already on screen instead of freezing it in the
  // language that was active when it happened.
  property string lastErrorKey: ""
  property var lastErrorArgs: []

  readonly property string lastError: {
    if (root.lastErrorKey === "")
      return "";
    var message = strings.t(root.lastErrorKey, root.lastErrorKey);
    for (var i = 0; i < root.lastErrorArgs.length; i++)
      message = message.replace("%" + (i + 1), String(root.lastErrorArgs[i]));
    return message;
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function setError(key, args) {
    root.lastErrorKey = key;
    root.lastErrorArgs = args || [];
  }

  function clearError() {
    root.lastErrorKey = "";
    root.lastErrorArgs = [];
  }

  function defaults() {
    return {
      "enabled": false,
      "mode": "next",
      "intervalMinutes": 20,
      "nextDueAt": 0
    };
  }

  function applyConfig(cfg) {
    root.enabled = cfg.enabled === true;
    root.mode = (cfg.mode === "random") ? "random" : "next";
    var n = Math.floor(Number(cfg.intervalMinutes));
    root.intervalMinutes = (isFinite(n) && n >= 1) ? n : 20;
    var d = Number(cfg.nextDueAt);
    root.nextDueAt = (isFinite(d) && d > 0) ? d : 0;
  }

  function persist() {
    configFile.setText(JSON.stringify({
      "enabled": root.enabled,
      "mode": root.mode,
      "intervalMinutes": root.intervalMinutes,
      "nextDueAt": root.nextDueAt
    }, null, 2) + "\n");
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var cfg = null;
      try {
        cfg = JSON.parse(configFile.text());
      } catch (e) {
        cfg = null;
      }
      root.applyConfig(cfg || root.defaults());
      root.armTimer();
    }
    onLoadFailed: {
      root.applyConfig(root.defaults());
      root.armTimer();
    }
    onSaveFailed: function (error) {
      root.setError("error.saveFailed");
      console.warn("gabodev.bg-rotate: config save failed (" + String(error) + ")");
    }
  }

  // ---- Bundled script probe ------------------------------------------------
  // `test -x` rather than FileView: the check that matters is executability,
  // not content, and a missing file must be reported the same way as one
  // copied without its exec bit.
  Process {
    id: probeProc
    command: ["test", "-x", root.rotateBin]
    onExited: function (exitCode) {
      if (root.probePending) {
        root.probePending = false;
        root.probeScript();
        return;
      }
      root.scriptReady = root.rotateBin !== "" && exitCode === 0;
      if (!root.scriptReady) {
        root.setError("error.missingScript", [root.rotateBin !== "" ? root.rotateBin : root.pluginDir]);
        console.warn("gabodev.bg-rotate: bundled script is missing or not executable:", root.rotateBin);
        return;
      }
      if (root.lastErrorKey === "error.missingScript")
        root.clearError();
      if (root.statusRequested) {
        root.statusRequested = false;
        statusProc.running = true;
      }
    }
  }

  function probeScript() {
    // The host injects `manifest` after createObject, so this can run before
    // `__sourceDir` is known. Stay quiet until the path resolves instead of
    // reporting a missing script for a path that does not exist yet.
    if (root.rotateBin === "") {
      root.scriptReady = false;
      if (root.pluginDir !== "")
        root.setError("error.missingScript", [root.pluginDir]);
      return;
    }
    if (probeProc.running) {
      root.probePending = true;
      return;
    }
    probeProc.running = true;
  }

  // ---- Schedule ------------------------------------------------------------
  // Catch-up is a single tick: a nextDueAt in the past arms the timer at the
  // 1s floor and fires once, never N times. First arm is never 0: an unset
  // nextDueAt is pushed a full interval into the future.
  function armTimer() {
    if (!root.enabled) {
      rotateTimer.stop();
      return;
    }
    var now = Date.now();
    if (root.nextDueAt <= 0) {
      root.nextDueAt = now + root.intervalMinutes * 60000;
      root.persist();
    }
    rotateTimer.interval = Math.max(1000, root.nextDueAt - now);
    rotateTimer.restart();
  }

  Timer {
    id: rotateTimer
    repeat: false
    onTriggered: root.tick()
  }

  function tick() {
    if (!root.scriptReady) {
      // Never start a Process with an empty or non-executable command: re-check
      // the bundle and try again next interval instead of spinning on it.
      root.probeScript();
      root.nextDueAt = Date.now() + root.intervalMinutes * 60000;
      root.persist();
      root.armTimer();
      return;
    }
    if (rotateProc.running) {
      root.armTimer();
      return;
    }
    rotateProc.running = true;
    watchdogTerm.restart();
  }

  // ---- Rotation process ------------------------------------------------------
  Timer {
    id: watchdogTerm
    interval: 45000
    repeat: false
    onTriggered: {
      if (rotateProc.running) {
        console.warn("gabodev.bg-rotate: rotate watchdog hit, SIGTERM");
        rotateProc.signal(15);
        watchdogKill.restart();
      }
    }
  }

  Timer {
    id: watchdogKill
    interval: 5000
    repeat: false
    onTriggered: {
      if (rotateProc.running) {
        console.warn("gabodev.bg-rotate: rotate still alive, SIGKILL");
        rotateProc.signal(9);
      }
    }
  }

  Process {
    id: rotateProc
    command: [root.rotateBin, root.mode]
    onExited: function (exitCode) {
      watchdogTerm.stop();
      watchdogKill.stop();
      if (exitCode !== 0) {
        root.setError("error.exitCode", [exitCode]);
        console.warn("gabodev.bg-rotate: rotate exited with code", exitCode);
      }
      if (root.enabled)
        root.nextDueAt = Date.now() + root.intervalMinutes * 60000;
      root.persist();
      root.armTimer();
      root.refreshStatus();
    }
  }

  // ---- Status refresh --------------------------------------------------------
  function refreshStatus() {
    if (!root.scriptReady) {
      // The probe answers asynchronously; refreshStatus finishes the job from
      // its callback so an open panel never stays silently empty.
      root.statusRequested = true;
      root.probeScript();
      return;
    }
    root.statusRequested = false;
    if (!statusProc.running)
      statusProc.running = true;
  }

  Process {
    id: statusProc
    command: [root.rotateBin, "status"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: {
        var text = statusOut.text.trim();
        if (text === "")
          return;
        var data = null;
        try {
          data = JSON.parse(text);
        } catch (e) {
          data = null;
        }
        if (!data) {
          root.setError("error.invalidStatus");
          console.warn("gabodev.bg-rotate: invalid status JSON:", text.slice(0, 120));
          return;
        }
        root.theme = String(data.theme || "");
        root.count = Math.max(0, Math.floor(Number(data.count) || 0));
        var idx = Math.floor(Number(data.index));
        root.index = isFinite(idx) ? idx : -1;
        var cur = String(data.current || "");
        root.current = cur.indexOf("/") >= 0 ? cur.split("/").pop() : cur;
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.setError("error.exitCode", [exitCode]);
        console.warn("gabodev.bg-rotate: status exited with code", exitCode);
      }
    }
  }

  // ---- Public API (panel + IPC) ---------------------------------------------
  function setEnabled(v) {
    var b = v === true;
    if (b === root.enabled)
      return;
    root.enabled = b;
    if (b)
      root.nextDueAt = Date.now() + root.intervalMinutes * 60000;
    root.persist();
    root.armTimer();
  }

  function setMode(m) {
    var s = String(m);
    if (s !== "next" && s !== "random")
      return;
    if (s === root.mode)
      return;
    root.mode = s;
    root.persist();
  }

  function setIntervalMinutes(n) {
    var v = Math.round(Number(n));
    if (!isFinite(v) || v < 1)
      return;
    if (v > 180)
      v = 180;
    if (v === root.intervalMinutes)
      return;
    root.intervalMinutes = v;
    if (root.enabled)
      root.nextDueAt = Date.now() + v * 60000;
    root.persist();
    root.armTimer();
  }

  function rotateNow() {
    if (!root.scriptReady) {
      root.probeScript();
      return;
    }
    if (rotateProc.running)
      return;
    rotateProc.running = true;
    watchdogTerm.restart();
  }

  ShellIpc {
    target: "gabodev.bg-rotate"
    function status(): string {
      return JSON.stringify({
        "enabled": root.enabled,
        "mode": root.mode,
        "intervalMinutes": root.intervalMinutes,
        "theme": root.theme,
        "count": root.count,
        "index": root.index,
        "current": root.current
      });
    }
    function enable(): string {
      root.setEnabled(true);
      return "ok";
    }
    function disable(): string {
      root.setEnabled(false);
      return "ok";
    }
    function toggle(): string {
      root.setEnabled(!root.enabled);
      return "ok";
    }
    function mode(s: string): string {
      root.setMode(s);
      return "ok";
    }
    function interval(n: string): string {
      root.setIntervalMinutes(Number(n));
      return "ok";
    }
    function next(): string {
      root.rotateNow();
      return "ok";
    }
  }
}
