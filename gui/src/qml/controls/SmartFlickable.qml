import QtQuick
import QtQuick.Controls

Flickable {
    id: smartFlick
    
    property int tabIndex: 0
    property int currentTabIndex: 0
    property alias scrollBar: scrollbar
    property Item contentLayout: null
    
    clip: true
    flickableDirection: Flickable.AutoFlickIfNeeded
    
    ScrollBar.vertical: ScrollBar {
        id: scrollbar
        policy: ScrollBar.AlwaysOn
        visible: smartFlick.contentHeight > smartFlick.height
    }
    
    function ensureVisible(item) {
        if (!item) return;
        if (scrollbar.pressed) return; // Don't auto-scroll while user is dragging scrollbar
        
        var ypos = item.mapToItem(smartFlick.contentItem, 0, 0).y
        var itemHeight = item.height
        var flickableHeight = smartFlick.height
        
        if (ypos < smartFlick.contentY) {
            smartFlick.contentY = ypos - 20
        } else if (ypos + itemHeight > smartFlick.contentY + flickableHeight) {
            smartFlick.contentY = ypos + itemHeight - flickableHeight + 20
        }
    }
    
    Connections {
        target: smartFlick.Window.window
        enabled: tabIndex === currentTabIndex && scrollbar.visible && contentLayout !== null
        function onActiveFocusItemChanged() {
            var focusItem = smartFlick.Window.activeFocusItem
            if (focusItem && focusItem.parent) {
                var isChild = false
                var checkItem = focusItem
                while (checkItem) {
                    if (checkItem === contentLayout) {
                        isChild = true
                        break
                    }
                    checkItem = checkItem.parent
                }
                if (isChild) {
                    smartFlick.ensureVisible(focusItem)
                }
            }
        }
    }
}

