import CoreMediaIO
import Foundation

// The camera "Erklärbär": macOS starts this process when a program looks for cameras.
let provider = CameraProvider(clientQueue: nil)
CMIOExtensionProvider.startService(provider: provider.provider)
CFRunLoopRun()
