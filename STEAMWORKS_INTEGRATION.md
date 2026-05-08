# pylux Steamworks Integration

## 🎮 **Overview**

This integration adds Steamworks SDK support to pylux, enabling the PlayStation OAuth login flow to open in Steam's overlay instead of a separate browser window.

## 📁 **Integration Architecture**

### **Isolated Design**
- **Location**: `gui/src/steamworks/` and `gui/include/steamworks/`
- **Isolation**: Completely separate from main codebase
- **Minimal Impact**: Only touches PSN login button logic
- **Merge Safe**: Designed to minimize upstream conflicts

### **File Structure**
```
gui/
├── src/steamworks/
│   ├── steamworks_api.cpp          # Implementation
│   └── README.md                   # Module documentation
├── include/steamworks/
│   └── steamworks_wrapper.h        # Header interface
├── third_party/
│   ├── README_STEAMWORKS.md        # Installation guide
│   └── steamworks_sdk/             # SDK placement (you provide)
```

## 🚀 **Installation Steps**

### **1. Place Steamworks SDK**
```bash
# Download SDK from Steamworks Partner Portal
# Extract to: gui/third_party/steamworks_sdk/
```

### **2. Configure Your App ID**
Edit `gui/src/steamworks/steamworks_api.cpp`:
```cpp
// TODO: Replace 0 with your actual Steam App ID
if (!steamworks_wrapper->initialize(YOUR_STEAM_APP_ID)) {
```

### **3. Build with Steamworks**
```bash
cmake -DCHIAKI_ENABLE_STEAMWORKS=ON ..
make
```

## ⚙️ **How It Works**

### **PSN Login Flow**
1. **User clicks "Login to PSN"** in Settings → Config
2. **Steam Check**: `Chiaki.openPsnLoginInSteamOverlay()` attempts Steam overlay
3. **Fallback**: If Steam unavailable, opens normal PSN dialog
4. **OAuth**: PlayStation login proceeds in Steam overlay or browser

### **Code Integration Points**
- **QML Backend**: `QmlBackend::openPsnLoginInSteamOverlay()`
- **Button Logic**: `SettingsDialog.qml` PSN button modified
- **Wrapper**: `SteamworksWrapper` class handles all Steam API calls

## 🔧 **Configuration**

### **Runtime Control**
In `SettingsDialog.qml`:
```javascript
var useSteamOverlay = true; // Set this bool based on your preference
```

### **Build Control**
```cmake
# Enable/disable during build
-DCHIAKI_ENABLE_STEAMWORKS=ON/OFF
```

### **Graceful Degradation**
- ✅ **No SDK**: Compiles without Steamworks, normal browser flow
- ✅ **No Steam**: Runtime fallback to normal browser flow  
- ✅ **With Steam**: Uses overlay for better integration

## 📋 **Files Modified**

### **New Files**
- `gui/src/steamworks/steamworks_api.cpp`
- `gui/src/steamworks/README.md` 
- `gui/include/steamworks/steamworks_wrapper.h`
- `gui/third_party/README_STEAMWORKS.md`
- `STEAMWORKS_INTEGRATION.md`

### **Modified Files**
- `CMakeLists.txt` - Added `CHIAKI_ENABLE_STEAMWORKS` option
- `gui/CMakeLists.txt` - Added Steamworks build integration
- `gui/include/qmlbackend.h` - Added `openPsnLoginInSteamOverlay()` method
- `gui/src/qmlbackend.cpp` - Implemented Steam overlay functionality
- `gui/src/qml/SettingsDialog.qml` - Modified PSN button to try Steam first

## 🛡️ **Isolation Benefits**

### **Merge Safety**
- **Separate Module**: All Steam code in isolated directory
- **Minimal Touchpoints**: Only PSN button logic modified
- **Build Optional**: Can be disabled with CMake flag
- **Zero Impact**: No effect when disabled or SDK missing

### **Maintainability**
- **Single Purpose**: Only handles Steam overlay activation
- **Clear Interface**: Simple wrapper with minimal API
- **Self-Contained**: All Steam dependencies isolated
- **Documentation**: Comprehensive setup and usage guides

## 🎯 **Usage**

1. **Set your Steam App ID** in `steamworks_api.cpp`
2. **Place Steamworks SDK** in `gui/third_party/steamworks_sdk/`
3. **Build with** `-DCHIAKI_ENABLE_STEAMWORKS=ON`
4. **Run pylux through Steam** (required for overlay)
5. **Click "Login to PSN"** → Opens in Steam overlay! 🎉

## ⚠️ **Requirements**

- Valid Steam developer account and App ID
- Steamworks SDK from Valve
- Steam client running when using overlay
- pylux launched through Steam for overlay access

This integration enhances the user experience while maintaining complete backward compatibility and build flexibility!



