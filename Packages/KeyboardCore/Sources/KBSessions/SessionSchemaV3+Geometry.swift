import Foundation
import KBRuntime

extension CanonicalSession {

    // MARK: - Geometri

    public struct Geometry: Codable, Equatable, Sendable {
        public var layoutID: String
        /// **Tam layout parmak izi.** `layoutID` tekil değil: aynı kimlikle tuş
        /// sırası, geometri ve `asciiBase` değişebilir ve bu, kod regresyonu
        /// diye yanlış sınıflanırdı. v2'de yoktu → `.unknown`.
        public var layoutFingerprint: Epistemic<String>
        public var boundsX: Double, boundsY: Double
        public var boundsWidth: Double, boundsHeight: Double
        public var frameInScreenX: Double, frameInScreenY: Double
        public var frameInScreenWidth: Double, frameInScreenHeight: Double
        public var safeAreaBottom: Double
        public var screenScale: Double
        public var interfaceOrientation: String
        public var deviceModel: String
        public var systemVersion: String

        public init(layoutID: String, layoutFingerprint: Epistemic<String>,
                    boundsX: Double, boundsY: Double,
                    boundsWidth: Double, boundsHeight: Double,
                    frameInScreenX: Double, frameInScreenY: Double,
                    frameInScreenWidth: Double, frameInScreenHeight: Double,
                    safeAreaBottom: Double, screenScale: Double,
                    interfaceOrientation: String, deviceModel: String,
                    systemVersion: String) {
            self.layoutID = layoutID; self.layoutFingerprint = layoutFingerprint
            self.boundsX = boundsX; self.boundsY = boundsY
            self.boundsWidth = boundsWidth; self.boundsHeight = boundsHeight
            self.frameInScreenX = frameInScreenX; self.frameInScreenY = frameInScreenY
            self.frameInScreenWidth = frameInScreenWidth
            self.frameInScreenHeight = frameInScreenHeight
            self.safeAreaBottom = safeAreaBottom
            self.screenScale = screenScale
            self.interfaceOrientation = interfaceOrientation
            self.deviceModel = deviceModel
            self.systemVersion = systemVersion
        }
    }
}
