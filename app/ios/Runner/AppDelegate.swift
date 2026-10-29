import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var ring: AVAudioPlayer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AuraRing") else { return }
    let tone = registrar.lookupKey(forAsset: "assets/sounds/ringtone.wav")
    FlutterMethodChannel(name: "aura/ring", binaryMessenger: registrar.messenger()).setMethodCallHandler { [weak self] call, result in
      if call.method == "start" { self?.startRing(tone) } else { self?.stopRing() }
      result(nil)
    }
  }

  /// iOS не даёт приложениям мелодию, выбранную в телефоне (её играет только CallKit), поэтому звучит
  /// мелодия AURA. Зато через динамик: принудительный вывод на динамик перебивает и наушники.
  private func startRing(_ asset: String) {
    stopRing()
    guard let path = Bundle.main.path(forResource: asset, ofType: nil) else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
      try session.setActive(true)
      try session.overrideOutputAudioPort(.speaker)
      ring = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      ring?.numberOfLoops = -1
      ring?.play()
    } catch {
      NSLog("AURA: мелодия звонка: \(error)")
    }
  }

  private func stopRing() {
    guard let player = ring else { return }
    player.stop()
    ring = nil
    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none) // разговор дальше идёт как обычно
  }
}
