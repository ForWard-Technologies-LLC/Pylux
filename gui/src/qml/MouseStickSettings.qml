import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

// Mouse look and mouse button bindings, shown below the key bindings in the Keys settings tab
GridLayout {
    columns: 3
    rowSpacing: 3
    columnSpacing: 10

    Label {
        Layout.columnSpan: 3
        Layout.topMargin: 20
        Layout.alignment: Qt.AlignHCenter
        text: qsTr("Mouse")
        font.bold: true
    }

    C.CheckBox {
        Layout.columnSpan: 3
        Layout.alignment: Qt.AlignHCenter
        text: qsTr("Mouse controls right stick (mouse look, replaces Mouse Touchpad)")
        checked: Chiaki.settings.mouseStickEnabled
        onToggled: Chiaki.settings.mouseStickEnabled = checked
    }

    RowLayout {
        Layout.columnSpan: 3
        Layout.alignment: Qt.AlignHCenter
        spacing: 20
        enabled: Chiaki.settings.mouseStickEnabled

        Label {
            text: qsTr("Sensitivity")
        }

        C.Slider {
            id: sensitivity
            Layout.preferredWidth: 250
            from: 0.1
            to: 5
            stepSize: 0.05
            value: Chiaki.settings.mouseStickSensitivity
            onMoved: Chiaki.settings.mouseStickSensitivity = value
        }

        Label {
            Layout.preferredWidth: 50
            text: sensitivity.value.toFixed(2)
        }

        Label {
            text: qsTr("Dead zone compensation")
        }

        C.Slider {
            id: deadzone
            Layout.preferredWidth: 250
            from: 0
            to: 0.5
            stepSize: 0.01
            value: Chiaki.settings.mouseStickDeadzone
            onMoved: Chiaki.settings.mouseStickDeadzone = value
        }

        Label {
            Layout.preferredWidth: 50
            text: Math.round(deadzone.value * 100) + " %"
        }
    }

    Label {
        Layout.columnSpan: 3
        Layout.topMargin: 10
        Layout.alignment: Qt.AlignHCenter
        text: qsTr("Mouse buttons (active when Mouse Touchpad is off)")
    }

    Repeater {
        model: Chiaki.settings.mouseButtonMapping

        RowLayout {
            spacing: 20

            Label {
                Layout.preferredWidth: 200
                horizontalAlignment: Text.AlignRight
                text: modelData.name
            }

            C.ComboBox {
                Layout.preferredWidth: 170
                model: Chiaki.settings.mouseButtonTargets
                textRole: "name"
                valueRole: "value"
                Component.onCompleted: currentIndex = indexOfValue(modelData.target)
                onActivated: Chiaki.settings.setMouseButtonMapping(modelData.mouseButton, currentValue)
            }
        }
    }
}
