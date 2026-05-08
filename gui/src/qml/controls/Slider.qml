import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Effects

Slider {
    property bool firstInFocusChain: false
    property bool lastInFocusChain: false
    property bool sendOutput: false
    
    // Enhanced futuristic styling
    background: Rectangle {
        x: parent.leftPadding
        y: parent.topPadding + parent.availableHeight / 2 - height / 2
        implicitWidth: 200
        implicitHeight: 4
        width: parent.availableWidth
        height: implicitHeight
        radius: 2
        color: Qt.rgba(255, 255, 255, 0.2)
        
        Rectangle {
            width: parent.parent.visualPosition * parent.width
            height: parent.height
            color: "#00d4ff"
            radius: parent.radius
            
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "#00d4ff"
                opacity: 0.5
                
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 8
                    blur: 0.4
                }
            }
        }
    }
    
    handle: Rectangle {
        x: parent.leftPadding + parent.visualPosition * (parent.availableWidth - width)
        y: parent.topPadding + parent.availableHeight / 2 - height / 2
        implicitWidth: 20
        implicitHeight: 20
        radius: 10
        color: parent.pressed ? "#ffffff" : "#00d4ff"
        border.color: parent.visualFocus ? "#ffffff" : "transparent"
        border.width: parent.visualFocus ? 2 : 0
        
        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on border.color { ColorAnimation { duration: 200 } }
        
        // Glow effect for focused handle
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.color: "#00d4ff"
            border.width: 2
            opacity: parent.parent.visualFocus ? 0.7 : 0
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
        }
    }
}
