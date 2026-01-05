import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

Dialog {
    id: dialog
    
    property string url: ""
    
    title: qsTr("Add to Library")
    modal: true
    width: 340
    height: 420
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    
    Material.roundedScale: Material.MediumScale
    
    anchors.centerIn: parent
    
    function showDialog(urlToShow) {
        url = urlToShow || ""
        open()
    }
    
    onOpened: {
        closeButton.forceActiveFocus()
    }
    
    Shortcut {
        sequence: "Escape"
        enabled: dialog.visible
        onActivated: dialog.close()
    }
    
    Shortcut {
        sequence: "Back"
        enabled: dialog.visible
        onActivated: dialog.close()
    }
    
    footer: DialogButtonBox {
        Button {
            id: closeButton
            text: qsTr("Close")
            flat: true
            onClicked: dialog.close()
        }
    }
    
    ColumnLayout {
        anchors.fill: parent
        spacing: 12
        
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 220
            Layout.preferredHeight: 220
            color: "white"
            border.color: Material.accent
            border.width: 2
            radius: 8
            
            Image {
                id: qrCodeImage
                anchors.centerIn: parent
                width: 200
                height: 200
                source: url ? "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=" + encodeURIComponent(dialog.url) : ""
                fillMode: Image.PreserveAspectFit
                
                BusyIndicator {
                    anchors.centerIn: parent
                    running: qrCodeImage.status === Image.Loading
                    visible: running
                }
            }
        }
        
        Label {
            Layout.fillWidth: true
            text: qsTr("Scan with your phone to add this game to your PlayStation library, then refresh.")
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 12
        }
    }
}
