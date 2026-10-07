import UIKit
import KBGeometry
import KBAssembly
import KBSessions

/// Yazım kaydının ortam bilgisi — klavyedeki kayıt ve uygulamadaki kayıt
/// ekranı **aynı** şekilde topluyor (önceden ikisi ayrı yazılmıştı; uygulama
/// yönü hep "portrait" yazıyor, sürümü başka biçimde veriyordu).
enum RecordingSnapshot {
    static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    /// "0.1 (1)".
    static func appVersion(_ bundle: Bundle) -> String {
        let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = bundle.infoDictionary?["CFBundleVersion"] as? String
        return "\(v ?? "?") (\(b ?? "?"))"
    }

    /// Paketteki derleme manifesti; derleme fazı koşmadıysa uydurmak yerine bilinmiyor.
    static func buildManifest(_ bundle: Bundle) -> CanonicalSession.EngineSnapshot.BuildManifest {
        guard let m = BuildManifest(bundle: bundle) else { return .init(codeRevision: .unknown, provenance: .unknown) }
        return .init(
            codeRevision: m.codeRevision == "unknown" ? .unknown : .known(m.codeRevision),
            provenance: .known(.init(
                sourceTree: m.dirty ? .init(digest: m.sourceDigest) : .clean,
                swiftVersion: m.swiftVersion, targetTriple: m.targetTriple,
                arch: m.arch, optimization: m.optimization,
                xcodeVersion: m.xcodeVersion)))
    }

    static func orientationName(_ o: UIInterfaceOrientation?) -> String {
        switch o {
        case .landscapeLeft, .landscapeRight: return "landscape"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .portrait: return "portrait"
        default: return "unknown"
        }
    }

    /// Klavye görünümünün ölçüleri ve ekrandaki yeri. `keyboard` yoksa sıfırlar.
    static func geometry(layout: KeyLayout, keyboard: UIView?, host: UIView) -> CanonicalSession.Geometry {
        let b = keyboard?.bounds ?? .zero
        let f = keyboard.map { $0.convert($0.bounds, to: nil) } ?? .zero
        return .init(layoutID: layout.id,
                     // `layoutID` tekil değil: aynı kimlikle tuş sırası değişebilir.
                     layoutFingerprint: .known(layout.fingerprint),
                     boundsX: Double(b.minX), boundsY: Double(b.minY),
                     boundsWidth: Double(b.width), boundsHeight: Double(b.height),
                     frameInScreenX: Double(f.minX), frameInScreenY: Double(f.minY),
                     frameInScreenWidth: Double(f.width), frameInScreenHeight: Double(f.height),
                     safeAreaBottom: Double(host.safeAreaInsets.bottom),
                     screenScale: UIScreen.main.scale,
                     interfaceOrientation: orientationName(host.window?.windowScene?.interfaceOrientation),
                     deviceModel: UIDevice.current.model,
                     systemVersion: UIDevice.current.systemVersion)
    }
}
