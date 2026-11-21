import Foundation

/// What the app and its camera extension (VirtualCamera/Extension, built with Xcode) agree on.
/// The extension compiles this file too, so it must not use anything else from the app.
enum VirtualCameraIDs {
    /// Bundle id of the camera extension inside Erklärbär.app/Contents/Library/SystemExtensions.
    static let extensionID = "local.screenkast.app.camera"
    /// Only the app with this signing id may put pictures into the camera.
    static let appSigningID = "local.screenkast.app"
    /// The name meeting programs show in their camera list.
    static let cameraName = "Erklärbär"
    static let model = "Erklärbär Live"
    static let manufacturer = "Lernsachen.blog"

    static let device = UUID(uuidString: "5E1D7C2A-8B3F-4A6E-9C01-2F7B3D4E5A61")!
    /// The stream meeting programs read.
    static let sourceStream = UUID(uuidString: "5E1D7C2A-8B3F-4A6E-9C01-2F7B3D4E5A62")!
    /// The stream Erklärbär writes the live picture into.
    static let sinkStream = UUID(uuidString: "5E1D7C2A-8B3F-4A6E-9C01-2F7B3D4E5A63")!

    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let framesPerSecond: Int32 = 30

    /// True for the camera "Erklärbär" itself (it must never be chosen as the webcam of the live picture).
    static func isOwnCamera(uniqueID: String, modelID: String) -> Bool {
        uniqueID.caseInsensitiveCompare(device.uuidString) == .orderedSame || modelID == model
    }
}
