import AVFoundation
import Flutter
import UIKit
import ZoomVideoSDK

final class ZoomVideoBridge: NSObject, FlutterStreamHandler, ZoomVideoSDKDelegate {
  static let methodChannelName = "lmszoom/zoom_video/methods"
  static let eventChannelName = "lmszoom/zoom_video/events"
  static let viewType = "lmszoom/zoom_video/view"

  private let sdk = ZoomVideoSDK.shareInstance()
  private var eventSink: FlutterEventSink?
  private var initialized = false
  private var pendingCleanup: FlutterResult?
  private var videoViews: [String: [WeakVideoView]] = [:]

  func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: registrar.messenger())
      .setStreamHandler(self)
    registrar.register(ZoomVideoPlatformViewFactory(bridge: self), withId: Self.viewType)
    NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialize":
      guard let sdk else { result(FlutterError(code: "SDK_UNAVAILABLE", message: "Zoom Video SDK could not be loaded.", details: nil)); return }
      // Zoom's singleton is initialized once for the lifetime of the app. Calls
      // to initialize again before cleanup return Errors_Wrong_Usage (1).
      if initialized { result(nil); return }
      // Request camera access before SDK initialization so the SDK's video
      // subsystem discovers cameras with authorization already granted.
      requestMediaPermissions { [weak self] permissionError in
        guard let self else { return }
        guard permissionError == nil else {
          result(FlutterError(code: "PERMISSION_DENIED", message: permissionError, details: nil)); return
        }
        let params = ZoomVideoSDKInitParams(); params.domain = "zoom.us"; params.enableLog = true
        let error = sdk.initialize(params)
        guard error == .Errors_Success else { result(sdkError(error)); return }
        sdk.delegate = self; initialized = true; result(nil)
      }
    case "join":
      guard initialized, let sdk else { result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize before joining.", details: nil)); return }
      guard let name = args["sessionName"] as? String, !name.isEmpty,
            let userName = args["userName"] as? String, !userName.isEmpty,
            let token = args["token"] as? String, !token.isEmpty else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "sessionName, userName and server-issued JWT token are required.", details: nil)); return
      }
      let context = ZoomVideoSDKSessionContext(); context.sessionName = name; context.userName = userName; context.token = token
      context.sessionPassword = args["sessionPassword"] as? String ?? ""
      let audio = ZoomVideoSDKAudioOptions(); audio.connect = true; audio.mute = args["muted"] as? Bool ?? false; context.audioOption = audio
      let video = ZoomVideoSDKVideoOptions(); video.localVideoOn = args["cameraEnabled"] as? Bool ?? true; context.videoOption = video
      guard sdk.joinSession(context) != nil else { result(FlutterError(code: "JOIN_FAILED", message: "Zoom could not start joining the session. See SDK events for details.", details: nil)); return }
      result(nil)
    case "leave":
      guard let sdk, initialized else { result(nil); return }
      let error = sdk.leaveSession(false); if error == .Errors_Success { result(nil) } else { result(sdkError(error)) }
    case "setCameraEnabled":
      guard let enabled = args["enabled"] as? Bool,
            let sdk,
            let session = sdk.getSession(),
            let user = session.getMySelf(),
            let helper = sdk.getVideoHelper() else {
        result(FlutterError(code: "NOT_IN_SESSION", message: "Video is available only after joining a session.", details: nil)); return
      }
      // localVideoOn may already have started video as part of joinSession.
      // Avoid repeating an operation when the requested state is already active.
      let videoIsOn = user.getVideoCanvas()?.videoStatus()?.on ?? false
      guard videoIsOn != enabled else { result(nil); return }
      let error = enabled ? helper.startVideo() : helper.stopVideo()
      if error == .Errors_Success { refreshVideoViews() }
      if error == .Errors_Success {
        result(nil)
      } else {
        let cameras = (helper.getCameraDeviceList() ?? []).map {
          ["id": $0.deviceId ?? "", "name": $0.deviceName ?? ""]
        }
        let systemCameras = AVCaptureDevice.DiscoverySession(
          deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
          mediaType: .video,
          position: .unspecified
        ).devices
        result(FlutterError(
          code: "ZOOM_SDK_\(error.rawValue)",
          message: "Zoom could not \(enabled ? "start" : "stop") local video: \(error).",
          details: [
            "rawValue": error.rawValue,
            "cameraAuthorization": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "cameraCount": cameras.count,
            "cameras": cameras,
            "systemCameraCount": systemCameras.count,
            "videoWasOn": videoIsOn,
            "mainThread": Thread.isMainThread,
            "sdkVersion": Bundle(for: ZoomVideoSDK.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
          ]
        ))
      }
    case "setMicrophoneMuted":
      guard let muted = args["muted"] as? Bool, let sdk, let user = sdk.getSession()?.getMySelf() else { result(FlutterError(code: "NOT_IN_SESSION", message: "Audio helper is unavailable.", details: nil)); return }
      let error = muted ? sdk.getAudioHelper()?.muteAudio(user) : sdk.getAudioHelper()?.unmuteAudio(user)
      guard let error else { result(FlutterError(code: "SDK_UNAVAILABLE", message: "Zoom audio helper is unavailable.", details: nil)); return }; returnSDK(error, result)
    case "switchCamera":
      guard let helper = sdk?.getVideoHelper() else { result(FlutterError(code: "NOT_IN_SESSION", message: "Video helper is unavailable.", details: nil)); return }
      helper.switchCamera(); result(nil)
    case "cleanup":
      guard let sdk, initialized else { result(nil); return }
      if sdk.getSession() != nil {
        pendingCleanup = result
        let error = sdk.leaveSession(false)
        if error != .Errors_Success {
          pendingCleanup = nil
          result(sdkError(error))
        }
      } else {
        finishCleanup(result)
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func requestMediaPermissions(_ completion: @escaping (String?) -> Void) {
    AVCaptureDevice.requestAccess(for: .video) { videoAllowed in
      guard videoAllowed else { DispatchQueue.main.async { completion("Camera permission was denied.") }; return }
      AVAudioSession.sharedInstance().requestRecordPermission { audioAllowed in
        DispatchQueue.main.async { completion(audioAllowed ? nil : "Microphone permission was denied.") }
      }
    }
  }

  private func sdkError(_ error: ZoomVideoSDKError) -> FlutterError {
    FlutterError(code: "ZOOM_SDK_\(error.rawValue)", message: "Zoom Video SDK error: \(error)", details: error.rawValue)
  }
  private func returnSDK(_ error: ZoomVideoSDKError, _ result: FlutterResult) {
    if error == .Errors_Success { result(nil) } else { result(sdkError(error)) }
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { eventSink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { eventSink = nil; return nil }
  private func emit(_ name: String, _ data: [String: Any] = [:]) { DispatchQueue.main.async { self.eventSink?(["event": name, "data": data]) } }
  func onSessionJoin() {
    emit("sessionJoined", sessionPayload())
    emitUsers("participantsSnapshot", sdk?.getSession()?.getRemoteUsers())
    refreshVideoViews()
  }
  func onSessionLeave() {
    emit("sessionLeft", sessionPayload()); clearVideoViews()
    if let result = pendingCleanup { finishCleanup(result) }
  }
  func onSessionLeave(_ reason: ZoomVideoSDKSessionLeaveReason) {
    emit("sessionLeft", ["reason": String(describing: reason)]); clearVideoViews()
    if let result = pendingCleanup { finishCleanup(result) }
  }
  func onError(_ error: ZoomVideoSDKError, detail: Int) { emit("error", ["code": error.rawValue, "detail": detail, "message": String(describing: error)]) }
  func onUserJoin(_ helper: ZoomVideoSDKUserHelper?, users: [ZoomVideoSDKUser]?) { emitUsers("participantsJoined", users); refreshVideoViews() }
  func onUserLeave(_ helper: ZoomVideoSDKUserHelper?, users: [ZoomVideoSDKUser]?) { emitUsers("participantsLeft", users); refreshVideoViews() }
  func onUserVideoStatusChanged(_ helper: ZoomVideoSDKVideoHelper?, user: [ZoomVideoSDKUser]?) { emitUsers("participantVideoChanged", user); refreshVideoViews() }
  func onUserAudioStatusChanged(_ helper: ZoomVideoSDKAudioHelper?, user: [ZoomVideoSDKUser]?) { emitUsers("participantAudioChanged", user) }
  private func emitUsers(_ event: String, _ users: [ZoomVideoSDKUser]?) {
    emit(event, ["participants": (users ?? []).map { ["id": String($0.getID()), "name": $0.getName(), "videoOn": $0.getVideoCanvas()?.videoStatus()?.on ?? false] }])
  }
  private func sessionPayload() -> [String: Any] { ["sessionName": sdk?.getSession()?.getName() ?? ""] }
  @objc private func appWillResignActive() { emit("appLifecycle", ["state": "inactive"]) }
  @objc private func appDidBecomeActive() { emit("appLifecycle", ["state": "active"]) }

  func attachVideo(to view: UIView, userId: String) {
    let existing = videoViews[userId] ?? []
    videoViews[userId] = existing.filter { $0.value != nil } + [WeakVideoView(view)]
    attach(view, userId: userId)
  }
  private func attach(_ view: UIView, userId: String) {
    guard let session = sdk?.getSession() else { return }
    let user = userId == "local" ? session.getMySelf() : session.getRemoteUsers()?.first(where: { String($0.getID()) == userId })
    guard let user, let canvas = user.getVideoCanvas() else { return }
    // Keep the canvas attached while video is off so a later startVideo call
    // can render without requiring the platform view to be recreated.
    canvas.subscribe(with: view, aspectMode: .panAndScan, andResolution: ._Auto)
  }
  func detachVideo(from view: UIView, userId: String) {
    videoViews[userId]?.removeAll { $0.value == nil || $0.value === view }
    guard let session = sdk?.getSession() else { return }
    let user = userId == "local" ? session.getMySelf() : session.getRemoteUsers()?.first(where: { String($0.getID()) == userId })
    user?.getVideoCanvas()?.unSubscribe(with: view)
  }
  private func refreshVideoViews() {
    DispatchQueue.main.async {
      for (userId, views) in self.videoViews {
        for view in views.compactMap(\.value) { self.attach(view, userId: userId) }
      }
    }
  }
  private func clearVideoViews() {
    DispatchQueue.main.async {
      for (userId, views) in self.videoViews {
        for view in views.compactMap(\.value) { self.detachVideo(from: view, userId: userId) }
      }
    }
  }

  private func finishCleanup(_ result: @escaping FlutterResult) {
    guard let sdk, initialized else { result(nil); return }
    let error = sdk.cleanup()
    if error == .Errors_Success {
      initialized = false
      sdk.delegate = nil
      pendingCleanup = nil
      result(nil)
    } else {
      pendingCleanup = nil
      result(sdkError(error))
    }
  }
}

private final class WeakVideoView {
  weak var value: UIView?
  init(_ value: UIView) { self.value = value }
}

private final class ZoomVideoPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let bridge: ZoomVideoBridge
  init(bridge: ZoomVideoBridge) { self.bridge = bridge }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    ZoomVideoPlatformView(frame: frame, userId: (args as? [String: Any])?["userId"] as? String ?? "local", bridge: bridge)
  }
}
private final class ZoomVideoPlatformView: NSObject, FlutterPlatformView {
  private let videoView: UIView; private let userId: String; private weak var bridge: ZoomVideoBridge?
  init(frame: CGRect, userId: String, bridge: ZoomVideoBridge) { self.videoView = UIView(frame: frame); self.userId = userId; self.bridge = bridge; super.init(); videoView.backgroundColor = .black; videoView.clipsToBounds = true; bridge.attachVideo(to: videoView, userId: userId) }
  func view() -> UIView { videoView }
  deinit { bridge?.detachVideo(from: videoView, userId: userId) }
}
