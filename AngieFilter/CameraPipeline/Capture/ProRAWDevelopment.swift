import CoreImage
import Foundation

/// A ProRAW still developed twice. `scene` is linear scene light for the 银幕 print: no tone curve, no local
/// tone mapping, so shadows and skies keep the contrast the phone's photo flattens. `display` is Apple's own
/// rendering, the stand-in for the processed photo: the intensity mix blends back to it, and a look picked
/// after the shutter uses it alone.
struct ProRAWDevelopment {
    let scene: CIImage
    let display: CIImage

    init?(data: Data) {
        guard let linear = CIRAWFilter(imageData: data, identifierHint: nil),
              let rendered = CIRAWFilter(imageData: data, identifierHint: nil) else { return nil }
        let baseline = linear.baselineExposure
        linear.baselineExposure = 0
        linear.boostAmount = 0
        if linear.isLocalToneMapSupported {
            linear.localToneMapAmount = 0
        }
        // Without extended range the filter clips at 1, losing about a stop and a half of highlights. Values over 1
        // survive the Display P3 working space. `exposure` must stay 0: the filter applies it in the context's working
        // space, so in gamma-encoded P3 a −2 comes out about four stops down, not two.
        linear.extendedDynamicRangeAmount = 2
        guard let raw = linear.outputImage,
              let scene = ScreenPrint.sceneLight(fromLinear: raw, baselineExposure: baseline),
              let display = rendered.outputImage else { return nil }
        PerfLog.line(String(format: "proraw still %.0fx%.0f baseline %.2f EV", raw.extent.width, raw.extent.height, baseline))
        self.scene = scene
        self.display = display
    }
}
