import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

Button {
    property bool firstInFocusChain: false
    property bool lastInFocusChain: false
    property bool sendOutput: false

    Material.background: visualFocus ? Material.accent : undefined
    
    // Enhanced futuristic styling
    background: Rectangle {
        radius: 8
        color: parent.visualFocus ? "#00d4ff" : Qt.rgba(0, 212/255, 255/255, 0.1)
        border.color: parent.visualFocus ? "transparent" : "#00d4ff"
        border.width: parent.visualFocus ? 0 : 1
        
        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on border.color { ColorAnimation { duration: 200 } }
        
        // Glow effect for focused buttons
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.color: "#00d4ff"
            border.width: 2
            opacity: parent.parent.visualFocus ? 0.6 : 0
            visible: opacity > 0
            
            layer.enabled: parent.parent.visualFocus
            layer.effect: MultiEffect {
                blurEnabled: true
                blurMax: 12
                blur: 0.8
            }
            
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
    }
    
    contentItem: Text {
        text: parent.text
        font: parent.font
        color: parent.visualFocus ? "#000000" : "#00d4ff"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        Behavior on color { ColorAnimation { duration: 200 } }
    }

    Component.onDestruction: {
        if (visualFocus) {
            let item = nextItemInFocusChain();
            if (item)
                item.forceActiveFocus(Qt.TabFocusReason);
        }
    }

    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Up:
            if (!firstInFocusChain) {
                let item = nextItemInFocusChain(false);
                if (item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                if(!sendOutput)
                    event.accepted = true;
            }
            break;
        case Qt.Key_Down:
            if (!lastInFocusChain) {
                let item = nextItemInFocusChain();
                if (item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                if(!sendOutput)
                    event.accepted = true;
            }
            break;
        case Qt.Key_Return:
            if (visualFocus) {
                clicked();
            }
            event.accepted = true;
            break;
        }
    }
}
