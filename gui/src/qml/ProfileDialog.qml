import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {

    buttonText: {
        if(deleteBox.visible && deleteBox.checked)
            qsTr("Delete Profile")
        else if(profileName.visible)
            qsTr("Create Profile")
        else
            qsTr("Switch Profile")
    }
    buttonEnabled: {
        if(deleteBox.visible && deleteBox.checked)
            true
        else if(profileName.visible)
            profileName.text.trim();
        else
            !(profileComboBox.model[profileComboBox.currentIndex] == "default" && Chiaki.settings.currentProfile == "") && profileComboBox.model[profileComboBox.currentIndex] != Chiaki.settings.currentProfile
    }
    onAccepted: {
        if(deleteBox.visible && deleteBox.checked) {
            Chiaki.settings.deleteProfile(profileComboBox.model[profileComboBox.currentIndex])
        }
        else if(profileName.visible) {
            Chiaki.settings.currentProfile = profileName.text.trim()
            stack.pop()
            root.showToast(qsTr("Profile Created"), qsTr("Restart app for changes to take effect"), "#FF9800")
            return
        }
        else {
            let oldProfile = Chiaki.settings.currentProfile
            let newProfile = profileComboBox.model[profileComboBox.currentIndex] == "default" ? "" : profileComboBox.model[profileComboBox.currentIndex]
            if (oldProfile !== newProfile) {
                Chiaki.settings.currentProfile = newProfile
                stack.pop()
                root.showToast(qsTr("Profile Switched"), qsTr("Restart app for changes to take effect"), "#FF9800")
                return
            }
        }
        stack.pop()
    }

    Item {
        GridLayout {
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 50
            }
            columns: 2
            rowSpacing: 10
            columnSpacing: 20

            Label {
                Layout.alignment: Qt.AlignRight
                text: qsTr("User Profile:")
            }

            C.ComboBox {
                id: profileComboBox
                Layout.preferredWidth: 400
                firstInFocusChain: false
                model: Chiaki.settings.profiles
                currentIndex: Math.max(0, model.indexOf(Chiaki.settings.currentProfile))
                lastInFocusChain: model[currentIndex] == "default" || model[currentIndex] == Chiaki.settings.currentProfile
                
                // This handler is triggered when user selects an item (press A on item in popup)
                onActivated: (index) => {
                    currentIndex = index;
                    // Auto-focus the "Switch Profile" button for quick profile switching
                    if (headerButton && headerButton.visible && headerButton.enabled) {
                        headerButton.forceActiveFocus(Qt.TabFocusReason);
                    }
                }
                
                // Allow navigation up to dialog header button
                Keys.onPressed: (event) => {
                    // Don't intercept keys when popup is open - let ComboBox handle it
                    if (popup.visible)
                        return;
                    
                    if (event.key === Qt.Key_Up) {
                        if (headerButton && headerButton.visible && headerButton.enabled) {
                            headerButton.forceActiveFocus(Qt.TabFocusReason)
                            event.accepted = true
                        }
                    }
                }
            }

            Label {
                text: qsTr("New Profile Name")
                visible: profileComboBox.currentIndex == profileComboBox.model.indexOf("create new profile")
            }

            C.TextField {
                id: profileName
                visible: profileComboBox.currentIndex == profileComboBox.model.indexOf("create new profile")
                Layout.preferredWidth: 400
                lastInFocusChain: true
            }

            Label {
                text: qsTr("Delete selected profile")
                visible: profileComboBox.model[profileComboBox.currentIndex] != "default" && profileComboBox.model[profileComboBox.currentIndex] != "create new profile" && profileComboBox.model[profileComboBox.currentIndex] != Chiaki.settings.currentProfile
            }

            C.CheckBox {
                id: deleteBox
                visible: profileComboBox.model[profileComboBox.currentIndex] != "default" && profileComboBox.model[profileComboBox.currentIndex] != "create new profile" && profileComboBox.model[profileComboBox.currentIndex] != Chiaki.settings.currentProfile
                lastInFocusChain: true
            }
        }
    }
}