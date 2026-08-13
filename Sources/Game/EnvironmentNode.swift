import Foundation
import SpriteKit

final class EnvironmentNode: SKNode {
    private let plate: SKSpriteNode
    private let atmosphere = SKNode()
    private let reducedMotion: Bool
    private let levelID: Int

    init(levelID: Int, sceneSize: CGSize, reducedMotion: Bool, highContrast: Bool) {
        self.levelID = levelID
        self.reducedMotion = reducedMotion
        let name = String(format: "environment_%02d_%@", levelID, Self.slug(for: levelID))
        let texture = SKTexture(imageNamed: name)
        texture.filteringMode = .linear
        plate = SKSpriteNode(texture: texture)
        super.init()

        self.name = "environment"
        zPosition = -80
        let fittedSize = Self.aspectFill(texture.size(), inside: sceneSize)
        plate.size = CGSize(width: fittedSize.width * 1.08, height: fittedSize.height * 1.08)
        plate.position = CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        if highContrast {
            plate.color = .black
            plate.colorBlendFactor = 0.16
        }
        addChild(plate)
        atmosphere.zPosition = 2
        addChild(atmosphere)
        buildAtmosphere(sceneSize: sceneSize)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var hasCompleteAsset: Bool {
        guard let texture = plate.texture else { return false }
        let size = texture.size()
        return size.width > 1 && size.height > 1
    }

    private func buildAtmosphere(sceneSize: CGSize) {
        guard !reducedMotion else { return }
        let driftDistance = max(18, sceneSize.width * 0.025)
        plate.run(.repeatForever(.sequence([
            .moveBy(x: -driftDistance, y: 0, duration: 11),
            .moveBy(x: driftDistance, y: 0, duration: 13)
        ])), withKey: "horizonDrift")

        switch levelID {
        case 1: addClouds(sceneSize: sceneSize, color: .white.withAlphaComponent(0.07), count: 4, speed: 18)
        case 2: addWindblownPaper(sceneSize: sceneSize)
        case 3: addDust(sceneSize: sceneSize)
        case 4:
            addFog(sceneSize: sceneSize, color: SKColor(red: 0.40, green: 0.72, blue: 0.18, alpha: 0.10), count: 7, speed: 9)
            addWarningPulses(sceneSize: sceneSize)
        default:
            addFog(sceneSize: sceneSize, color: SKColor(red: 0.24, green: 0.58, blue: 0.42, alpha: 0.13), count: 10, speed: 12)
            addEmbers(sceneSize: sceneSize)
        }
    }

    private func addClouds(sceneSize: CGSize, color: SKColor, count: Int, speed: TimeInterval) {
        for index in 0..<count {
            let cloud = SKShapeNode(ellipseOf: CGSize(width: CGFloat(150 + index * 34), height: CGFloat(22 + index * 3)))
            cloud.fillColor = color
            cloud.strokeColor = .clear
            cloud.position = CGPoint(x: CGFloat(index) / CGFloat(count) * sceneSize.width,
                                     y: sceneSize.height * (0.58 + CGFloat(index % 2) * 0.11))
            atmosphere.addChild(cloud)
            cloud.run(.repeatForever(.sequence([
                .moveBy(x: sceneSize.width + 220, y: 0, duration: speed + Double(index) * 2),
                .moveBy(x: -(sceneSize.width + 220), y: 0, duration: 0)
            ])))
        }
    }

    private func addFog(sceneSize: CGSize, color: SKColor, count: Int, speed: TimeInterval) {
        for index in 0..<count {
            let fog = SKShapeNode(ellipseOf: CGSize(width: CGFloat(190 + index * 17), height: CGFloat(30 + index * 2)))
            fog.fillColor = color
            fog.strokeColor = .clear
            fog.position = CGPoint(x: CGFloat(index) / CGFloat(count) * sceneSize.width,
                                   y: sceneSize.height * (0.12 + CGFloat(index % 3) * 0.035))
            atmosphere.addChild(fog)
            fog.run(.repeatForever(.sequence([
                .moveBy(x: index.isMultiple(of: 2) ? sceneSize.width + 220 : -(sceneSize.width + 220), y: 0, duration: speed + Double(index)),
                .moveBy(x: index.isMultiple(of: 2) ? -(sceneSize.width + 220) : sceneSize.width + 220, y: 0, duration: 0)
            ])))
        }
    }

    private func addWindblownPaper(sceneSize: CGSize) {
        for index in 0..<6 {
            let paper = SKShapeNode(rectOf: CGSize(width: 8, height: 5), cornerRadius: 1)
            paper.fillColor = .white.withAlphaComponent(0.34)
            paper.strokeColor = .clear
            paper.position = CGPoint(x: CGFloat(index) * sceneSize.width / 6, y: sceneSize.height * 0.18 + CGFloat(index % 2) * 20)
            atmosphere.addChild(paper)
            paper.run(.repeatForever(.sequence([
                .group([.moveBy(x: sceneSize.width + 80, y: 28, duration: 5 + Double(index) * 0.6), .rotate(byAngle: .pi * 6, duration: 5 + Double(index) * 0.6)]),
                .moveBy(x: -(sceneSize.width + 80), y: -28, duration: 0)
            ])))
        }
    }

    private func addDust(sceneSize: CGSize) {
        addFog(sceneSize: sceneSize, color: SKColor(red: 0.70, green: 0.54, blue: 0.32, alpha: 0.06), count: 6, speed: 14)
    }

    private func addWarningPulses(sceneSize: CGSize) {
        for x in [sceneSize.width * 0.12, sceneSize.width * 0.88] {
            let warning = SKShapeNode(circleOfRadius: 8)
            warning.fillColor = .red.withAlphaComponent(0.18)
            warning.strokeColor = .orange.withAlphaComponent(0.45)
            warning.glowWidth = 7
            warning.position = CGPoint(x: x, y: sceneSize.height * 0.50)
            atmosphere.addChild(warning)
            warning.run(.repeatForever(.sequence([.fadeAlpha(to: 0.18, duration: 0.45), .fadeAlpha(to: 1, duration: 0.12), .wait(forDuration: 1.2)])))
        }
    }

    private func addEmbers(sceneSize: CGSize) {
        for index in 0..<12 {
            let ember = SKShapeNode(circleOfRadius: 1.5)
            ember.fillColor = index.isMultiple(of: 2) ? .orange : .red
            ember.strokeColor = .clear
            ember.position = CGPoint(x: CGFloat(index) / 12 * sceneSize.width, y: sceneSize.height * 0.16)
            atmosphere.addChild(ember)
            ember.run(.repeatForever(.sequence([
                .group([.moveBy(x: CGFloat.random(in: -20...20), y: CGFloat.random(in: 50...100), duration: 2.2 + Double(index % 3)), .fadeOut(withDuration: 2.2)]),
                .moveBy(x: 0, y: -80, duration: 0),
                .fadeIn(withDuration: 0)
            ])))
        }
    }

    private static func slug(for levelID: Int) -> String {
        switch levelID {
        case 1: "closing_time"
        case 2: "freeway_hunger"
        case 3: "hard_hats"
        case 4: "pressure_cooker"
        default: "last_light"
        }
    }

    private static func aspectFill(_ source: CGSize, inside bounds: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = max(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}
