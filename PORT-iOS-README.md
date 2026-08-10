# Rokid Browser — iOS Port (BLE GATT)

Port of the Rokid glasses control app from **Bluetooth Classic RFCOMM/SPP** to
**BLE GATT**, so the phone side runs on **iOS** (iPhone) while keeping the glasses
side (Android, Rokid RV101).

## Why BLE instead of the original RFCOMM
iOS does **not** allow apps to use Bluetooth Classic RFCOMM/SPP with non-MFi
devices. Only BLE (GATT) is open to normal apps. So the transport was swapped on
**both** ends. The JSON-over-newline protocol and the entire Flutter UI are
unchanged.

## Architecture
```
iPhone (BLE Central)  <— GATT —>  Rokid glasses (BLE Peripheral)
  rokid_browser_phone              rokid_browser_glasses
  ios/Runner/BleCentral.swift      .../BrowserBleServer.kt
```
- **Service UUID:** `a1b2c3d4-e5f6-7890-abcd-ef1234567890` (original app UUID)
- **TX char** `...560001` — WRITE — phone → glasses commands
- **RX char** `...560002` — NOTIFY — glasses → phone state
- Messages: newline-delimited JSON. Long payloads chunked to MTU, reassembled on `\n`.
- Flow control: iOS writes `.withResponse`, next chunk sent from `didWriteValueFor`.
  Android sends one RX notification at a time, advancing on `onNotificationSent`.
- Ping `{"type":"ping"}` keepalive filtered out both ends.

## What was changed
### iOS phone (`rokid_browser_phone`)
- Added iOS platform (`flutter create --platforms=ios`).
- `ios/Runner/BleCentral.swift` — new CoreBluetooth Central.
- `ios/Runner/AppDelegate.swift` — wires the SAME MethodChannel
  (`com.rokid.rokid_browser_phone/methods`: `sendCommand`, `resetConnection`) and
  EventChannel (`.../events`) the Dart UI already uses → **UI untouched**.
- `ios/Runner/Info.plist` — added `NSBluetoothAlwaysUsageDescription`,
  `NSBluetoothPeripheralUsageDescription`, `UIBackgroundModes: bluetooth-central`.
- `lib/secrets.dart` — stub using Google's official AdMob TEST unit IDs.
- Disabled Swift Package Manager (`flutter config --no-enable-swift-package-manager`)
  to resolve a google_mobile_ads(CocoaPods) vs webview(SPM) conflict.

### Android glasses (`rokid_browser_glasses`)
- `.../BrowserBleServer.kt` — new BLE Peripheral (GattServer + advertiser),
  replaces `BrowserBtClient.kt` (RFCOMM, removed — still in git history).
- `MainActivity.kt` — instantiates `BrowserBleServer` instead of `BrowserBtClient`.
- `AndroidManifest.xml` — added `BLUETOOTH_ADVERTISE`; fixed activity to full class
  name `com.rokid.rokid_browser_glasses.MainActivity`.
- **Two pre-existing bugs fixed** (original repo crashes on the glasses):
  1. Dart used channel `com.snorlytics.browser_glasses/*` but Kotlin declared
     `com.rokid.rokid_browser_glasses/*` → EventChannel never fired → BLE never
     started. Aligned Kotlin to `com.snorlytics.browser_glasses/*`.
  2. Manifest `.MainActivity` resolved against namespace `com.snorlytics...` but
     the class lives in package `com.rokid...` → `ClassNotFoundException`.

## Verified on real hardware
- Glasses APK built, sideloaded to RV101, launched without crash.
- **BLE advertising confirmed:** logcat `BrowserBLEServer: Advertising started` +
  system `onAdvertisingSetStarted() status=0` (SUCCESS). RV101 supports BLE
  peripheral — the biggest risk is cleared.
- iOS Runner.app builds cleanly (simulator + device SDK 26.5).

## Build instructions
Prereqs (already installed on this Mac): Flutter 3.44, CocoaPods, Xcode 26.6,
OpenJDK 17, Android SDK (platform-34, build-tools 34).

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:/opt/homebrew/bin:$PATH"

# Glasses APK
cd rokid_browser_glasses
echo "sdk.dir=$ANDROID_HOME" > android/local.properties
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell pm grant com.snorlytics.browser_glasses android.permission.BLUETOOTH_ADVERTISE
adb shell pm grant com.snorlytics.browser_glasses android.permission.BLUETOOTH_CONNECT
adb shell am start -n com.snorlytics.browser_glasses/com.rokid.rokid_browser_glasses.MainActivity

# iPhone app (needs Apple Developer signing team + device plugged/unlocked/trusted,
# Developer Mode ON)
cd ../rokid_browser_phone
flutter build ios --release            # or: flutter run -d <iphone-id>
# In Xcode: open ios/Runner.xcworkspace → Signing & Capabilities → select Team.
```

## Remaining (needs the physical iPhone + Apple account)
- Build/run on the real iPhone (Apple Dev team ID; iPhone unlocked, trusted,
  Developer Mode ON).
- E2E test matrix: short command, JSON >20 bytes, Vietnamese/Unicode typing,
  wifi password (multi-chunk), rapid commands, state notify, app restart,
  Bluetooth toggle, disconnect/reconnect.
