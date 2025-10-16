import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

Dialog {
    id: dialog
    
    property string titleId: ""
    property string gameName: ""
    property string deviceName: ""
    property bool opening: false
    property bool succeeded: false
    property string steamBasePath: ""
    
    signal showToast(string message, string color)
    
    title: qsTr("Create Steam Shortcut")
    modal: true
    width: 650
    height: 550
    
    // Center in parent
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2
    
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    
    Material.roundedScale: Material.MediumScale
    
    // Custom footer with buttons to control close behavior
    footer: DialogButtonBox {
        Button {
            text: qsTr("Cancel")
            flat: true
            onClicked: dialog.close()
        }
        Button {
            text: qsTr("Create Shortcut")
            flat: true
            Material.background: Material.accent
            Material.foreground: "white"
            onClicked: {
                console.log("Create Shortcut button clicked")
                
                // Check if cached data exists
                let cachedData = ChiakiGames.getCachedStoreResponse(titleId)
                console.log("Cached data length:", cachedData ? cachedData.length : 0)
                
                if (!cachedData || cachedData.length === 0) {
                    console.log("No cached data, showing toast")
                    dialog.close()
                    dialog.showToast(qsTr("⚠ Game artwork is still loading. Please wait and try again."), "#FF9800")
                    return
                }
                
                console.log("Cached data exists, proceeding with shortcut creation")
                
                // Close the main dialog
                dialog.close()
                
                // Defer opening the log dialog to avoid layout conflicts
                Qt.callLater(() => {
                    logDialog.title = qsTr("Creating Steam Shortcut...")
                    logDialog.standardButtons = Dialog.NoButton
                    logArea.text = qsTr("Starting shortcut creation...\n")
                    logDialog.open()
                    
                    console.log("Calling ChiakiGames.createGameSteamShortcut...")
                    ChiakiGames.createGameSteamShortcut(
                        titleId,
                        gameNameField.text.trim(),
                        function(msg, ok, done) {
                            console.log("Callback received:", msg, "ok:", ok, "done:", done)
                            if (ok) {
                                succeeded = true
                            }
                            logArea.text += msg + "\n"
                            
                            if (done) {
                                opening = false
                                if (ok) {
                                    logDialog.title = qsTr("✓ Shortcut Created Successfully")
                                } else {
                                    logDialog.title = qsTr("✗ Shortcut Creation Failed")
                                }
                                logDialog.standardButtons = Dialog.Close
                            }
                        },
                        steamBasePath,
                        deviceName
                    )
                    console.log("createGameSteamShortcut call finished")
                })
            }
        }
    }
    
    function showDialog(gameTitle, gameTitleId, consoleDeviceName) {
        console.log("GameShortcutDialog.showDialog called with:", gameTitle, gameTitleId, consoleDeviceName)
        
        // Validate required parameters
        if (!consoleDeviceName) {
            console.error("Missing console device name")
            dialog.showToast(qsTr("⚠ Error: Console name is required for shortcut creation"), "#F44336")
            return
        }
        
        if (!gameTitle) {
            console.error("Missing game title")
            dialog.showToast(qsTr("⚠ Error: Game title is required for shortcut creation"), "#F44336")
            return
        }
        
        titleId = gameTitleId
        gameName = gameTitle
        deviceName = consoleDeviceName
        
        try {
            gameNameField.text = gameTitle
            console.log("Set gameNameField.text to:", gameTitle)
        } catch (e) {
            console.error("Error setting gameNameField.text:", e)
        }
        
        // Build launch options using shortcutStream command
        try {
            // Escape quotes in the strings for shell safety
            let escaped_name = gameTitle.replace(/"/g, '\\"')
            let escaped_console = consoleDeviceName.replace(/"/g, '\\"')
            let options = `shortcutStream "${escaped_console}" "${escaped_name}"`
            launchOptionsField.text = options
            console.log("Set launchOptionsField.text to:", launchOptionsField.text)
        } catch (e) {
            console.error("Error setting launchOptionsField.text:", e)
        }
        
        // Get cover image if available
        try {
            coverImage.source = ChiakiGames.getGameImage(gameTitleId)
            console.log("Set coverImage.source")
        } catch (e) {
            console.error("Error setting coverImage.source:", e)
        }
        
        console.log("Opening GameShortcutDialog")
        open()
    }
    
    onOpened: {
        console.log("GameShortcutDialog opened")
        console.log("  visible:", visible)
        console.log("  x:", x, "y:", y)
        console.log("  width:", width, "height:", height)
        console.log("  parent:", parent)
        console.log("  parent.width:", parent ? parent.width : "no parent")
        console.log("  parent.height:", parent ? parent.height : "no parent")
        console.log("  opacity:", opacity)
        console.log("  z:", z)
        console.log("  modal:", modal)
        Qt.callLater(() => {
            try {
                if (gameNameField) {
                    gameNameField.forceActiveFocus()
                    console.log("Focused gameNameField")
                }
            } catch (e) {
                console.error("Error focusing gameNameField:", e)
            }
        })
    }
    
    onClosed: {
        console.log("GameShortcutDialog closed")
    }
    
    onRejected: {
        console.log("GameShortcutDialog rejected")
    }
    
    onAboutToShow: {
        console.log("GameShortcutDialog about to show")
    }
    
    onAboutToHide: {
        console.log("GameShortcutDialog about to hide")
    }
    
    Component.onCompleted: {
        console.log("GameShortcutDialog component completed")
        console.log("  parent:", parent)
        console.log("  visible:", visible)
        console.log("  width:", width)
        console.log("  height:", height)
        console.log("  Overlay.overlay:", Overlay.overlay)
    }
    
    onVisibleChanged: {
        console.log("GameShortcutDialog visibility changed to:", visible)
    }
    
    contentItem: Flickable {
        contentWidth: availableWidth
        contentHeight: contentColumn.height
        clip: true
        
        ScrollBar.vertical: ScrollBar {}
        
        ColumnLayout {
            id: contentColumn
            width: parent.width
            spacing: 20
            
            // Cover art preview
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 200
                Layout.preferredHeight: 200
                color: "#1a1a1a"
                radius: 8
                visible: coverImage.status === Image.Ready
                
                Image {
                    id: coverImage
                    anchors.fill: parent
                    anchors.margins: 4
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                }
            }
            
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                rowSpacing: 20
                columnSpacing: 15
                
                Label {
                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    text: qsTr("Console")
                    font.weight: Font.Medium
                }
                
                Label {
                    Layout.fillWidth: true
                    text: deviceName || qsTr("(Unknown)")
                    wrapMode: Text.Wrap
                    font.pixelSize: 14
                }
                
                Label {
                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    text: qsTr("Steam Game Name")
                    font.weight: Font.Medium
                }
                
                C.TextField {
                    id: gameNameField
                    Layout.fillWidth: true
                    Layout.preferredWidth: 400
                    focus: true
                    focusPolicy: Qt.StrongFocus
                    firstInFocusChain: true
                    KeyNavigation.tab: launchOptionsField
                    KeyNavigation.down: launchOptionsField
                    
                    Keys.onReturnPressed: dialog.accept()
                    Keys.onEnterPressed: dialog.accept()
                    Keys.onEscapePressed: dialog.reject()
                }
                
                Label {
                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    text: qsTr("Launch Options")
                    font.weight: Font.Medium
                }
                
                C.TextField {
                    id: launchOptionsField
                    Layout.fillWidth: true
                    Layout.preferredWidth: 400
                    readOnly: false
                    focusPolicy: Qt.StrongFocus
                    KeyNavigation.backtab: gameNameField
                    KeyNavigation.up: gameNameField
                    KeyNavigation.tab: steamPathButton
                    KeyNavigation.down: steamPathButton
                    
                    Keys.onReturnPressed: dialog.accept()
                    Keys.onEnterPressed: dialog.accept()
                    Keys.onEscapePressed: dialog.reject()
                }
                
                Label {
                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    text: qsTr("Steam Base Path")
                    font.weight: Font.Medium
                }
                
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    
                    Label {
                        Layout.fillWidth: true
                        text: steamBasePath || qsTr("(Using default)")
                        wrapMode: Text.Wrap
                        opacity: 0.7
                        font.pixelSize: 12
                    }
                    
                    C.Button {
                        id: steamPathButton
                        text: qsTr("Choose Custom Path")
                        focusPolicy: Qt.StrongFocus
                        KeyNavigation.backtab: launchOptionsField
                        KeyNavigation.up: launchOptionsField
                        
                        onClicked: {
                            steamBasePath = Chiaki.settings.chooseSteamBasePath()
                        }
                        
                        Keys.onReturnPressed: clicked()
                        Keys.onEnterPressed: clicked()
                        Keys.onEscapePressed: dialog.reject()
                        
                        Material.roundedScale: Material.SmallScale
                    }
                }
            }
            
            Label {
                Layout.fillWidth: true
                text: qsTr("This will create a Steam shortcut that launches directly into this game.")
                wrapMode: Text.Wrap
                opacity: 0.7
                font.pixelSize: 12
            }
        }
    }
    
    // Log dialog
    Dialog {
        id: logDialog
        width: 650
        height: 500
        title: qsTr("Creating Steam Shortcut")
        modal: true
        closePolicy: Popup.NoAutoClose
        standardButtons: Dialog.Close
        Material.roundedScale: Material.MediumScale
        
        onOpened: logArea.forceActiveFocus(Qt.TabFocusReason)
        onClosed: {
            dialog.close()
        }
        
        Flickable {
            id: logFlick
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: logArea.implicitHeight
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            
            ScrollBar.vertical: ScrollBar {
                id: logScrollbar
                policy: ScrollBar.AlwaysOn
            }
            
            Label {
                id: logArea
                width: parent.width - 20
                wrapMode: Text.Wrap
                font.family: "monospace"
                font.pixelSize: 13
                lineHeight: 1.3
                
                onTextChanged: {
                    // Auto-scroll to bottom when text changes
                    Qt.callLater(() => {
                        logFlick.contentY = Math.max(0, logFlick.contentHeight - logFlick.height)
                    })
                }
                
                Keys.onReturnPressed: {
                    if (logDialog.standardButtons == Dialog.Close) {
                        logDialog.close()
                    }
                }
                Keys.onEscapePressed: logDialog.close()
                Keys.onPressed: (event) => {
                    switch (event.key) {
                    case Qt.Key_Up:
                        if (logScrollbar.position > 0.001) {
                            logFlick.flick(0, 500)
                        }
                        event.accepted = true
                        break
                    case Qt.Key_Down:
                        if (logScrollbar.position < 1.0 - logScrollbar.size - 0.001) {
                            logFlick.flick(0, -500)
                        }
                        event.accepted = true
                        break
                    }
                }
            }
        }
    }
}

