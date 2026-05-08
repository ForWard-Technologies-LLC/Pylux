import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

TextField {
    property bool firstInFocusChain: false
    property bool lastInFocusChain: false
    property bool sendOutput: false
    readOnly: true
    
    // Enhanced futuristic styling
    background: Rectangle {
        radius: 8
        color: parent.activeFocus ? Qt.rgba(0, 212/255, 255/255, 0.15) : Qt.rgba(0, 212/255, 255/255, 0.05)
        border.color: parent.activeFocus ? "#00d4ff" : Qt.rgba(0, 212/255, 255/255, 0.3)
        border.width: parent.activeFocus ? 2 : 1
        
        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on border.color { ColorAnimation { duration: 200 } }
        Behavior on border.width { NumberAnimation { duration: 200 } }
        
        // Glow effect for focused text fields
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.color: "#00d4ff"
            border.width: 2
            opacity: parent.parent.activeFocus ? 0.5 : 0
            visible: opacity > 0
            
            layer.enabled: parent.parent.activeFocus
            layer.effect: MultiEffect {
                blurEnabled: true
                blurMax: 10
                blur: 0.6
            }
            
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
    }
    
    color: "#ffffff"
    placeholderTextColor: Qt.rgba(255, 255, 255, 0.5)
    selectionColor: "#00d4ff"
    selectedTextColor: "#000000"

    onActiveFocusChanged: {
        if (!activeFocus)
            readOnly = true;
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Up:
            if (!firstInFocusChain) {
                if (readOnly || (!readOnly && cursorPosition === 0 && selectionStart === selectionEnd)) {
                    let item = nextItemInFocusChain(false);
                    if (item)
                        item.forceActiveFocus(Qt.TabFocusReason);
                    if(!sendOutput)
                        event.accepted = true;
                }
            }
            break;
        case Qt.Key_Down:
            if (!lastInFocusChain) {
                if (readOnly || (!readOnly && cursorPosition === length && selectionStart === selectionEnd)) {
                    let item = nextItemInFocusChain();
                    if (item)
                        item.forceActiveFocus(Qt.TabFocusReason);
                    if(!sendOutput)
                        event.accepted = true;
                }
            }
            break;
        case Qt.Key_Return:
            if (readOnly) {
                readOnly = false;
                Qt.inputMethod.show();
                event.accepted = true;
            } else {
                readOnly = true;
            }
            break;
        case Qt.Key_Escape:
            if (!readOnly) {
                readOnly = true;
                editingFinished();
                event.accepted = true;
            }
            break;
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: parent.readOnly
        onClicked: {
            parent.forceActiveFocus(Qt.TabFocusReason);
            parent.readOnly = false;
            Qt.inputMethod.show();
        }
    }
}
