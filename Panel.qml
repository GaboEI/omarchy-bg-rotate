import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// gabodev.bg-rotate panel: interactive control over the rotation service.
// Plain-Item panel contract: `opened`, open(payloadJson), close(); the host
// calls close() when hiding and consults `opened` for IPC toggle.
Item {
  id: root

  property bool opened: false
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: (manifest && manifest.id) || "gabodev.bg-rotate"

  // Every visible string comes from i18n/<language>.json; en.json is the
  // fallback when the active language has no catalog yet.
  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Resolved lazily: the host injects `service`, but a mount race can leave
  // it null; fall back to the registry at first use.
  property var svc: null
  onServiceChanged: if (root.service)
    root.svc = root.service

  function resolveService() {
    if (root.svc)
      return root.svc;
    if (root.service) {
      root.svc = root.service;
      return root.svc;
    }
    if (root.shell && root.shell.serviceFor)
      root.svc = root.shell.serviceFor(root.pluginId);
    return root.svc;
  }

  function open(payloadJson) {
    root.opened = true;
    var s = root.resolveService();
    if (s)
      s.refreshStatus();
    Qt.callLater(function () {
      if (root.opened)
        keyCatcher.forceActiveFocus();
    });
  }

  function close() {
    root.opened = false;
  }

  function dismiss() {
    if (root.shell && root.shell.hide)
      root.shell.hide(root.pluginId);
    else
      root.close();
  }

  OverlayWindow {
    id: win
    shown: root.opened
    WlrLayershell.namespace: "gabodev-bg-rotate"

    Item {
      anchors.fill: parent

      // Scrim: click outside dismisses.
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Style.space(460)
        height: card.borderTop + Style.spacing.panelPadding + col.implicitHeight + Style.spacing.panelPadding + card.borderBottom
        color: Commons.Color.popups.background
        radius: Style.cornerRadius
        borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))

        // The card swallows its own clicks so they never reach the scrim.
        MouseArea {
          anchors.fill: parent
        }

        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: true
          Keys.onEscapePressed: root.dismiss()
        }

        Column {
          id: col
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: card.borderLeft + Style.spacing.panelPadding
          anchors.rightMargin: card.borderRight + Style.spacing.panelPadding
          anchors.topMargin: card.borderTop + Style.spacing.panelPadding
          spacing: Style.spacing.panelGap

          // a) Header
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              text: strings.t("panel.title")
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
            }
            Text {
              text: root.svc && root.svc.theme !== ""
                    ? strings.t("panel.subtitle").arg(root.svc.theme).arg(Commons.I18n.formatNumber(root.svc.count))
                    : strings.t("panel.loading")
              color: Util.alpha(Commons.Color.popups.text, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }
          }

          // b) Enable toggle
          Toggle {
            width: parent.width
            label: strings.t("panel.enable")
            description: strings.t("panel.enableDescription")
            checked: root.svc ? root.svc.enabled : false
            onClicked: if (root.svc)
              root.svc.setEnabled(!root.svc.enabled)
            foreground: Commons.Color.popups.text
            accent: Commons.Color.accent
            fontFamily: Style.font.family
          }

          // c) Mode
          PanelSectionHeader {
            text: strings.t("panel.mode")
            foreground: Commons.Color.popups.text
            fontFamily: Style.font.family
          }
          ButtonGroup {
            width: parent.width
            options: [
              {
                "value": "next",
                "label": strings.t("panel.modeSequential")
              },
              {
                "value": "random",
                "label": strings.t("panel.modeRandom")
              }
            ]
            value: root.svc ? root.svc.mode : "next"
            onChanged: function (v) {
              if (root.svc)
                root.svc.setMode(v);
            }
            foreground: Commons.Color.popups.text
            background: Commons.Color.popups.background
            accent: Commons.Color.accent
            fontFamily: Style.font.family
          }

          // d) Interval
          PanelSectionHeader {
            text: strings.t("panel.interval")
            foreground: Commons.Color.popups.text
            fontFamily: Style.font.family
          }
          ButtonGroup {
            width: parent.width
            options: [
              {
                "value": "5",
                "label": "5"
              },
              {
                "value": "10",
                "label": "10"
              },
              {
                "value": "20",
                "label": "20"
              },
              {
                "value": "30",
                "label": "30"
              },
              {
                "value": "60",
                "label": "60"
              }
            ]
            value: root.svc ? String(root.svc.intervalMinutes) : "20"
            onChanged: function (v) {
              if (root.svc)
                root.svc.setIntervalMinutes(parseInt(v, 10));
            }
            foreground: Commons.Color.popups.text
            background: Commons.Color.popups.background
            accent: Commons.Color.accent
            fontFamily: Style.font.family
          }
          Row {
            width: parent.width
            spacing: Style.spacing.rowGap

            PanelSlider {
              width: parent.width - intervalText.implicitWidth - parent.spacing
              minimum: 1
              maximum: 180
              step: 1
              integer: true
              value: root.svc ? root.svc.intervalMinutes : 20
              onReleased: function (v) {
                if (root.svc)
                  root.svc.setIntervalMinutes(Math.round(v));
              }
              fillColor: Commons.Color.accent
              knobColor: Commons.Color.popups.text
              trackColor: Util.alpha(Commons.Color.popups.text, 0.25)
              tickColor: Commons.Color.popups.background
            }
            Text {
              id: intervalText
              text: strings.t("panel.minutes").arg(Commons.I18n.formatNumber(root.svc ? root.svc.intervalMinutes : 20))
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // e) Status row
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              text: {
                if (!root.svc || root.svc.count <= 0)
                  return strings.t("panel.noBackgrounds");
                if (root.svc.index < 0)
                  return strings.t("panel.currentNotInList").arg(Commons.I18n.formatNumber(root.svc.count));
                return strings.t("panel.statusPosition").arg(Commons.I18n.formatNumber(root.svc.index + 1)).arg(Commons.I18n.formatNumber(root.svc.count));
              }
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }
            Text {
              visible: root.svc && root.svc.current !== ""
              text: root.svc ? root.svc.current : ""
              color: Util.alpha(Commons.Color.popups.text, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              elide: Text.ElideMiddle
              width: parent.width
            }
            Text {
              visible: root.svc && root.svc.lastError !== ""
              text: root.svc ? root.svc.lastError : ""
              color: Commons.Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }

          // f) Actions
          Row {
            spacing: Style.spacing.rowGap

            Button {
              text: strings.t("panel.nextNow")
              onClicked: if (root.svc)
                root.svc.rotateNow()
              foreground: Commons.Color.popups.text
              accent: Commons.Color.accent
              fontFamily: Style.font.family
            }
            Button {
              text: strings.t("panel.close")
              onClicked: root.dismiss()
              foreground: Commons.Color.popups.text
              accent: Commons.Color.accent
              fontFamily: Style.font.family
            }
          }
        }
      }
    }
  }
}
