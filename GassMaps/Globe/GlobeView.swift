import SwiftUI
import SceneKit
import simd

/// Globo 3D della "Selezione mappa".
/// Camera prospettica ricavata dal video originale:
/// zoom 3.18 · pitch 13° · FOV verticale 33.8° · centro a 22.9°N, 150 pt sotto il centro schermo (su 852 pt).
struct GlobeView: UIViewRepresentable {
    let theme: MapTheme
    /// altezza della vista in punti (serve per tenere costante la dimensione delle etichette)
    let height: CGFloat
    /// trascinamento del globo con il dito
    let interaction: GlobeInteraction

    func makeCoordinator() -> GlobeCoordinator { GlobeCoordinator(interaction: interaction) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 60
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.delegate = context.coordinator
        view.isPlaying = true
        view.rendersContinuously = true
        context.coordinator.setViewHeight(height)
        context.coordinator.apply(theme: theme)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.setViewHeight(height)
        context.coordinator.apply(theme: theme)
    }
}

/// Stato del trascinamento condiviso tra SwiftUI (gesto) e SceneKit (rendering).
final class GlobeInteraction {
    private let lock = NSLock()
    private var dragging = false
    private var pending = CGSize.zero
    private var release: CGSize?

    func changed(delta: CGSize) {
        lock.lock(); defer { lock.unlock() }
        dragging = true
        pending.width += delta.width
        pending.height += delta.height
    }

    func ended(velocity: CGSize) {
        lock.lock(); defer { lock.unlock() }
        dragging = false
        release = velocity
    }

    private var intro: (lat: Double, lon: Double)?
    private var introScaleValue: Float?

    /// Avvia l'ingresso: il globo si orienta con il punto GPS davanti alla camera e smette di ruotare
    func startIntro(lat: Double, lon: Double, scale: Float) {
        lock.lock(); defer { lock.unlock() }
        intro = (lat, lon)
        introScaleValue = scale
    }

    /// Ingrandimento del globo durante l'ingresso (aggiornato a ogni fotogramma da GlobeIntroDriver)
    func setIntroScale(_ s: Float) {
        lock.lock(); defer { lock.unlock() }
        introScaleValue = s
    }

    /// Fine dell'ingresso: il globo torna alla dimensione normale e riprende la rotazione
    func endIntro() {
        lock.lock(); defer { lock.unlock() }
        introScaleValue = nil
    }

    func consumeIntro() -> (lat: Double, lon: Double)? {
        lock.lock(); defer { lock.unlock() }
        let i = intro
        intro = nil
        return i
    }

    var currentIntroScale: Float? {
        lock.lock(); defer { lock.unlock() }
        return introScaleValue
    }

    /// Restituisce e azzera lo spostamento accumulato.
    func consume() -> (dragging: Bool, delta: CGSize, release: CGSize?) {
        lock.lock(); defer { lock.unlock() }
        let r = (dragging, pending, release)
        pending = .zero
        release = nil
        return r
    }
}

final class GlobeCoordinator: NSObject, SCNSceneRendererDelegate {
    // Parametri ricavati dal video (vedi sopra)
    static let targetLat: Double = 22.87
    static let pitchDeg: Double = 12.98
    static let fovDeg: Double = 33.76
    static let zoom: Double = 3.177
    static let screenRefHeight: Double = 852
    static let targetOffsetPt: Double = 150   // il punto guardato è 150 pt sotto il centro

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private(set) var viewHeight: CGFloat = 852
    private let interaction: GlobeInteraction

    // rotazione (yaw = longitudine, tilt = inclinazione nord/sud)
    private static let autoSpeed: Float = -2 * .pi / 26      // rad/s, verso est come nel video
    private static let radPerPt: Float = 0.0019
    private var yaw: Float = Float(-39.25 * .pi / 180)
    private var tilt: Float = 0
    private var yawVelocity: Float = GlobeCoordinator.autoSpeed
    private var tiltVelocity: Float = 0
    private var lastTime: TimeInterval?
    private var introStart: TimeInterval?

    private let earth = SCNNode()
    private let labelsNode = SCNNode()
    private let markersNode = SCNNode()
    private var currentThemeID: String?

    private struct Billboard {
        let node: SCNNode
        let heightPt: Float     // altezza desiderata sullo schermo
        let priority: Int
        let sizePt: CGSize
    }
    private var billboards: [Billboard] = []
    private let lock = NSLock()
    private var frameCount = 0

    // camera
    private var camPos = SIMD3<Float>(0, 0, 3)
    private var camForward = SIMD3<Float>(0, 0, -1)

    init(interaction: GlobeInteraction) {
        self.interaction = interaction
        super.init()
        scene.background.contents = UIColor.clear
        setupCamera()
        setupEarth()
        applyOrientation()
    }

    private func applyOrientation() {
        let qTilt = simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0))
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        earth.simdOrientation = qTilt * qYaw
    }

    /// Aggiorna l'altezza della vista e la scala del bagliore (pt per unità mondo sul bordo).
    func setViewHeight(_ h: CGFloat) {
        guard h > 0, abs(h - viewHeight) > 0.5 || haloScaleSet == false else { return }
        viewHeight = h
        haloScaleSet = true
        let fov = Float(GlobeCoordinator.fovDeg * .pi / 180)
        let focal = Float(h) / 2 / tan(fov / 2)
        let dist = simd_length(camPos)
        let limb = sqrt(max(dist * dist - 1, 0.01))
        let ptPerUnit = focal / limb
        _ = ptPerUnit
    }
    private var haloScaleSet = false

    // MARK: Camera prospettica

    /// Posizione e orientamento della camera (in raggi terrestri), identici al video.
    static func cameraBasis() -> (pos: SIMD3<Double>, forward: SIMD3<Double>, up: SIMD3<Double>) {
        let fov = GlobeCoordinator.fovDeg * .pi / 180
        let focalPt = (GlobeCoordinator.screenRefHeight / 2) / tan(fov / 2)
        let radiusPt = 512 * pow(2, GlobeCoordinator.zoom) / (2 * .pi)
        let dist = focalPt / radiusPt                  // distanza camera-punto guardato, in raggi terrestri
        let la = GlobeCoordinator.targetLat * .pi / 180
        let p = GlobeCoordinator.pitchDeg * .pi / 180

        let n = SIMD3<Double>(0, sin(la), cos(la))       // normale nel punto guardato (lon 0)
        let north = SIMD3<Double>(0, cos(la), -sin(la))
        let target = n
        let pos = target + dist * (n * cos(p) - north * sin(p))
        let f = simd_normalize(target - pos)
        let up = n * sin(p) + north * cos(p)
        // il punto guardato appare 150 pt sotto il centro: ruoto la camera verso l'alto
        let delta = atan(GlobeCoordinator.targetOffsetPt / focalPt)
        return (pos, f * cos(delta) + up * sin(delta), up * cos(delta) - f * sin(delta))
    }

    /// Linea dell'orizzonte (bordo del globo) in coordinate schermo, per una vista di dimensione `size`.
    static func limbPoints(size: CGSize, samples: Int = 240) -> [CGPoint] {
        guard size.width > 0, size.height > 0 else { return [] }
        let cam = cameraBasis()
        let fov = GlobeCoordinator.fovDeg * .pi / 180
        let focal = Double(size.height) / 2 / tan(fov / 2)
        let right = simd_cross(cam.forward, cam.up)
        let d = simd_length(cam.pos)
        let cn = cam.pos / d
        let center = cn / d
        let rho = sqrt(max(1 - 1 / (d * d), 0))
        var a = simd_cross(cn, SIMD3<Double>(1, 0, 0))
        if simd_length(a) < 1e-6 { a = simd_cross(cn, SIMD3<Double>(0, 1, 0)) }
        a = simd_normalize(a)
        let b = simd_cross(cn, a)
        var pts: [CGPoint] = []
        for i in 0...samples {
            let t = Double(i) / Double(samples) * 2 * .pi
            let pnt = center + rho * (cos(t) * a + sin(t) * b)
            let q = pnt - cam.pos
            let z = simd_dot(q, cam.forward)
            guard z > 0.001 else { continue }
            pts.append(CGPoint(x: Double(size.width) / 2 + focal * simd_dot(q, right) / z,
                               y: Double(size.height) / 2 - focal * simd_dot(q, cam.up) / z))
        }
        return pts
    }

    private func setupCamera() {
        let basis = GlobeCoordinator.cameraBasis()
        let pos = basis.pos
        let f = basis.forward
        let up = basis.up

        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.fieldOfView = CGFloat(GlobeCoordinator.fovDeg)
        camera.zNear = 0.01
        camera.zFar = 20
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z))
        let look = pos + f
        cameraNode.simdLook(at: SIMD3<Float>(Float(look.x), Float(look.y), Float(look.z)),
                            up: SIMD3<Float>(Float(up.x), Float(up.y), Float(up.z)),
                            localFront: SIMD3<Float>(0, 0, -1))
        scene.rootNode.addChildNode(cameraNode)
        camPos = cameraNode.simdPosition
        camForward = SIMD3<Float>(Float(f.x), Float(f.y), Float(f.z))
    }

    // MARK: Terra

    private func setupEarth() {
        let geometry = GlobeCoordinator.makeSphere(radius: 1, latSegments: 128, lonSegments: 256)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.darkGray
        material.diffuse.mipFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.isDoubleSided = false
        material.shaderModifiers = [
            .fragment: """
            #pragma arguments
            float3 hazeColor;
            #pragma body
            float3 gm_n = normalize(_surface.normal);
            float3 gm_v = normalize(_surface.view);
            float gm_d = clamp(dot(gm_n, gm_v), 0.0, 1.0);
            float gm_rim = 1.0 - gm_d;
            // foschia atmosferica verso l'orizzonte (come la "fog" del globo originale)
            float gm_haze = pow(gm_rim, 2.8);
            _output.color.rgb = mix(_output.color.rgb, hazeColor, clamp(gm_haze * 0.92, 0.0, 0.92));
            """
        ]
        geometry.materials = [material]
        earth.geometry = geometry
        scene.rootNode.addChildNode(earth)
        earth.addChildNode(labelsNode)
        earth.addChildNode(markersNode)
    }

    private func setupAtmosphere() {
        let halo = SCNSphere(radius: 1.12)
        halo.segmentCount = 128
        let haloMat = SCNMaterial()
        haloMat.lightingModel = .constant
        haloMat.diffuse.contents = UIColor.clear
        haloMat.cullMode = .front
        haloMat.blendMode = .add
        haloMat.writesToDepthBuffer = false
        haloMat.shaderModifiers = [
            .fragment: """
            #pragma arguments
            float3 glowColor;
            float3 coreColor;
            float3 centerView;
            float ptPerUnit;
            #pragma body
            // altezza (in pt sullo schermo) del raggio di vista sopra il bordo della Terra
            float3 gm_dir = normalize(_surface.position);
            float gm_b = length(cross(centerView, gm_dir));
            float gm_h = max(gm_b - 1.0, 0.0) * ptPerUnit;
            // profilo misurato sul video: linea quasi bianca di ~2 pt + coda blu di ~40 pt
            float gm_core = 0.85 * exp(-gm_h / 2.5);
            float gm_tail = 0.25 * exp(-gm_h / 12.0);
            _output.color = float4(coreColor * gm_core + glowColor * gm_tail, 1.0);
            """
        ]
        halo.materials = [haloMat]
        let center = simd_inverse(cameraNode.simdTransform) * SIMD4<Float>(0, 0, 0, 1)
        haloMat.setValue(NSValue(scnVector3: SCNVector3(center.x, center.y, center.z)), forKey: "centerView")
        haloMat.setValue(NSNumber(value: Float(500)), forKey: "ptPerUnit")
        let haloNode = SCNNode(geometry: halo)
        haloNode.name = "halo"
        haloNode.renderingOrder = 5
        scene.rootNode.addChildNode(haloNode)
    }

    // MARK: Tema

    func apply(theme: MapTheme) {
        guard theme.id != currentThemeID else { return }
        currentThemeID = theme.id

        let material = earth.geometry?.firstMaterial
        material?.setValue(GlobeCoordinator.vec(theme.haze), forKey: "hazeColor")


        if let cached = GlobeTextureProvider.shared.cached(theme) {
            material?.diffuse.contents = cached
        } else {
            material?.diffuse.contents = GlobeTextureProvider.fallback(for: theme)
            let id = theme.id
            GlobeTextureProvider.shared.texture(for: theme) { [weak self] image in
                guard let self = self, self.currentThemeID == id, let image = image else { return }
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.4
                material?.diffuse.contents = image
                SCNTransaction.commit()
            }
        }
        buildBillboards(theme)
    }

    private static func vec(_ c: UIColor) -> NSValue {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return NSValue(scnVector3: SCNVector3(Float(r), Float(g), Float(b)))
    }

    private func buildBillboards(_ theme: MapTheme) {
        lock.lock()
        defer { lock.unlock() }
        labelsNode.childNodes.forEach { $0.removeFromParentNode() }
        markersNode.childNodes.forEach { $0.removeFromParentNode() }
        billboards.removeAll()

        // icone del tema (priorità massima)
        for marker in GlobeMarkers.list(for: theme) {
            guard let image = MapIcons.poiIcon(marker.category, theme: theme, pointSize: 40) else { continue }
            let node = makeBillboardNode(image: image)
            node.simdPosition = GlobeCoordinator.position(lat: marker.lat, lon: marker.lon, radius: 1.01)
            markersNode.addChildNode(node)
            let aspect = image.size.width / max(image.size.height, 1)
            billboards.append(Billboard(node: node, heightPt: 26, priority: 0,
                                        sizePt: CGSize(width: 26 * aspect, height: 26)))
        }

        // etichette
        for (i, label) in GlobeLabels.all.enumerated() {
            let text = theme.globeUppercase ? label.name.uppercased() : label.name
            guard let image = GlobeCoordinator.labelImage(text: text, isCity: label.isCity, theme: theme) else { continue }
            let node = makeBillboardNode(image: image)
            node.simdPosition = GlobeCoordinator.position(lat: label.lat, lon: label.lon, radius: 1.004)
            labelsNode.addChildNode(node)
            let h: CGFloat = label.isCity ? 11 : 12.5
            let aspect = image.size.width / max(image.size.height, 1)
            billboards.append(Billboard(node: node, heightPt: Float(h), priority: label.isCity ? 2000 + i : 1000 + i,
                                        sizePt: CGSize(width: h * aspect, height: h)))
        }
        billboards.sort { $0.priority < $1.priority }
    }

    private func makeBillboardNode(image: UIImage) -> SCNNode {
        let aspect = image.size.width / max(image.size.height, 1)
        let plane = SCNPlane(width: aspect, height: 1)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = image
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.renderingOrder = 20
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]
        node.scale = SCNVector3(0.001, 0.001, 0.001)
        return node
    }

    static func labelImage(text: String, isCity: Bool, theme: MapTheme) -> UIImage? {
        let fontSize: CGFloat = 36
        let gtaTheme = theme.id == "noir" || theme.id == "palm"
        let font = gtaTheme ? FontRegistry.gtaUIFont(size: fontSize)
            : (UIFont(name: theme.globeFont, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize, weight: .heavy))
        let strokeAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: theme.globeLabelHalo,
            .strokeColor: theme.globeLabelHalo, .strokeWidth: 22
        ]
        let fillAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.globeLabel]
        let textSize = (text as NSString).size(withAttributes: fillAttrs)
        let pad: CGFloat = 8
        let dot: CGFloat = isCity ? 22 : 0
        let size = CGSize(width: ceil(textSize.width + pad * 2 + dot), height: ceil(textSize.height + pad * 2))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            if isCity {
                let r = CGRect(x: pad, y: size.height / 2 - 7, width: 14, height: 14)
                ctx.cgContext.setFillColor(theme.globeLabelHalo.withAlphaComponent(0.7).cgColor)
                ctx.cgContext.fillEllipse(in: r)
                ctx.cgContext.setFillColor(theme.globeLabel.cgColor)
                ctx.cgContext.fillEllipse(in: r.insetBy(dx: 3, dy: 3))
            }
            let origin = CGPoint(x: pad + dot, y: pad)
            (text as NSString).draw(at: origin, withAttributes: strokeAttrs)
            (text as NSString).draw(at: origin, withAttributes: fillAttrs)
        }
    }

    // MARK: Aggiornamento per frame: dimensione costante su schermo, visibilità e collisioni

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // rotazione: trascinamento con il dito, poi inerzia e ritorno alla rotazione automatica
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.1))
        lastTime = time
        // ingresso dal punto GPS: globo ingrandito e centrato sulla posizione, poi si allontana
        if let start = interaction.consumeIntro() {
            yaw = Float(-start.lon * .pi / 180)
            tilt = Float((start.lat - GlobeCoordinator.targetLat) * .pi / 180)
            yawVelocity = 0
            tiltVelocity = 0
        }
        let introScale = interaction.currentIntroScale
        let wasIntro = introStart != nil
        introStart = introScale == nil ? nil : time
        earth.simdScale = SIMD3<Float>(repeating: introScale ?? 1)
        if wasIntro && introScale == nil {
            yawVelocity = 0     // riparte dolcemente verso la rotazione automatica
        }
        if introScale != nil {
            _ = interaction.consume()      // durante l'ingresso il globo non ruota
            applyOrientation()
        } else {
        let input = interaction.consume()
        if input.dragging || input.delta != .zero {
            yaw += Float(input.delta.width) * GlobeCoordinator.radPerPt
            tilt += Float(input.delta.height) * GlobeCoordinator.radPerPt
            if dt > 0 {
                yawVelocity = Float(input.delta.width) * GlobeCoordinator.radPerPt / dt
                tiltVelocity = Float(input.delta.height) * GlobeCoordinator.radPerPt / dt
            }
        }
        if let v = input.release {
            yawVelocity = Float(v.width) * GlobeCoordinator.radPerPt
            tiltVelocity = Float(v.height) * GlobeCoordinator.radPerPt
        }
        if !input.dragging {
            let k = min(1, dt * 1.6)
            yawVelocity += (GlobeCoordinator.autoSpeed - yawVelocity) * k
            tiltVelocity += (0 - tiltVelocity) * min(1, dt * 3)
            yaw += yawVelocity * dt
            tilt += tiltVelocity * dt
            tilt += (0 - tilt) * min(1, dt * 0.9)       // torna lentamente all'inclinazione originale
        }
        tilt = min(max(tilt, -0.6), 0.75)
        applyOrientation()
        }

        let viewHeight = self.viewHeight
        guard viewHeight > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        frameCount += 1
        let fov = Float(GlobeCoordinator.fovDeg * .pi / 180)
        let worldPerPtAtUnitDepth = 2 * tan(fov / 2) / Float(viewHeight)
        let doCollisions = frameCount % 4 == 0
        var placed: [CGRect] = []

        for b in billboards {
            let p = b.node.presentation.simdWorldPosition
            let toPoint = p - camPos
            let depth = simd_dot(toPoint, camForward)
            // lato visibile della sfera?
            let facing = -simd_dot(simd_normalize(toPoint), simd_normalize(p))
            guard depth > 0, facing > 0.02 else {
                if !b.node.isHidden { b.node.isHidden = true }
                continue
            }
            // dimensione costante sullo schermo (leggermente più piccola vicino all'orizzonte)
            let s = b.heightPt * worldPerPtAtUnitDepth * depth
            b.node.scale = SCNVector3(s, s, s)
            let fade = min(1, (facing - 0.02) / 0.12)

            if doCollisions {
                let sp = renderer.projectPoint(SCNVector3(p.x, p.y, p.z))
                let rect = CGRect(x: CGFloat(sp.x) - b.sizePt.width / 2, y: CGFloat(sp.y) - b.sizePt.height / 2,
                                  width: b.sizePt.width, height: b.sizePt.height).insetBy(dx: -3, dy: -2)
                if placed.contains(where: { $0.intersects(rect) }) {
                    b.node.isHidden = true
                    continue
                }
                placed.append(rect)
                b.node.isHidden = false
            }
            b.node.opacity = CGFloat(fade)
        }
    }

    // MARK: Geometria

    static func position(lat: Double, lon: Double, radius: Double) -> SIMD3<Float> {
        let la = lat * .pi / 180
        let lo = lon * .pi / 180
        return SIMD3<Float>(Float(radius * cos(la) * sin(lo)),
                            Float(radius * sin(la)),
                            Float(radius * cos(la) * cos(lo)))
    }

    /// Sfera con mappatura UV equirettangolare esplicita (u = longitudine, v = latitudine dall'alto).
    static func makeSphere(radius: Double, latSegments: Int, lonSegments: Int) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        vertices.reserveCapacity((latSegments + 1) * (lonSegments + 1))

        for i in 0...latSegments {
            let v = Double(i) / Double(latSegments)
            let lat = (90.0 - 180.0 * v) * .pi / 180
            for j in 0...lonSegments {
                let u = Double(j) / Double(lonSegments)
                let lon = (-180.0 + 360.0 * u) * .pi / 180
                let n = SCNVector3(Float(cos(lat) * sin(lon)), Float(sin(lat)), Float(cos(lat) * cos(lon)))
                normals.append(n)
                vertices.append(SCNVector3(n.x * Float(radius), n.y * Float(radius), n.z * Float(radius)))
                uvs.append(CGPoint(x: u, y: v))
            }
        }

        var indices: [UInt32] = []
        let row = lonSegments + 1
        for i in 0..<latSegments {
            for j in 0..<lonSegments {
                let a = UInt32(i * row + j)
                let b = UInt32(i * row + j + 1)
                let c = UInt32((i + 1) * row + j)
                let d = UInt32((i + 1) * row + j + 1)
                indices += [a, c, b, b, c, d]
            }
        }

        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }
}
