import Foundation
import simd

// Port of src/cat/props.ts: the things a cat works with, each built once and shared by every cat. Each
// prop is one mesh with its materials baked in as colour and roughness, modelled in the space of the
// group the web version pops in and out (so the pop scales about the same point).

enum PropMaterial {
    static let ink: UInt32 = 0x242428
    static let paper = (0xf1eee7 as UInt32, Float(0.9))
    static let card = (0xd3cdc1 as UInt32, Float(0.9))
    static let pillow = (0xd9a53a as UInt32, Float(0.85))
    static let china = (0xf3efe6 as UInt32, Float(0.5))
    static let tea = (0xa8652f as UInt32, Float(0.3))
    static let rice = (0xf7f4ec as UInt32, Float(0.85))
    static let seaweed = (0x26342c as UInt32, Float(0.7))
}

enum Props {
    private static func box(_ w: Float, _ h: Float, _ d: Float, _ r: Float) -> Geometry { Shapes.roundedBox(w, h, d, segments: 3, radius: r) }
    private static func part(_ g: Geometry, _ m: (UInt32, Float), _ at: Vec3, turn: Vec3 = .zero) -> Geometry {
        g.applied(.compose(at, euler: turn)).colored(m.0, roughness: m.1)
    }
    private static let clay = (PropMaterial.ink, Float(0.6))

    /// Two covers hinged at the spine, opening toward the cat. Group at (0, 1, 1.02), turned 0.45 about x.
    static let book: Geometry = {
        let cover = box(0.36, 0.52, 0.035, 0.015), pages = box(0.32, 0.46, 0.03, 0.012)
        var parts: [Geometry] = []
        for side in SIDES {
            let half = Mat4.rotationY(side * 0.3)
            parts.append(part(cover, PropMaterial.card, Vec3(side * 0.18, 0, 0)).applied(half))
            parts.append(part(pages, PropMaterial.paper, Vec3(side * 0.175, 0, -0.022)).applied(half))
        }
        return Geometry.join(parts)
    }()

    /// A laptop propped on a plump cushion, at just the height the paws type at. Group at the root.
    static let desk: Geometry = {
        let cushion = Shapes.sphere(1, 28, 16).applied(.scale(Vec3(0.7, 0.33, 0.46)))
        var keys: [Geometry] = []
        let key = box(0.07, 0.03, 0.06, 0.012)
        for row in 0..<3 {
            for col in 0..<8 {
                keys.append(key.applied(.translation(Vec3((Float(col) - 3.5) * 0.095, 0.715, 1.015 + Float(row) * 0.085))).colored(PropMaterial.ink, roughness: 0.6))
            }
        }
        // The screen leans back from the far edge, low enough to leave the cat's face in view.
        return Geometry.join([
            part(cushion, PropMaterial.pillow, Vec3(0, 0.33, 1.15)),
            part(box(0.84, 0.05, 0.42, 0.02), PropMaterial.card, Vec3(0, 0.68, 1.12)),
            Geometry.join(keys),
            part(box(0.84, 0.46, 0.035, 0.02), PropMaterial.card, Vec3(0, 0.92, 1.36), turn: Vec3(0.3, 0, 0)),
        ])
    }()

    /// Held to one eye, for looking things up far away. Modelled in the head's own space; group at
    /// (0.43, 0.62, 1.3) in the face.
    static let spyglass: Geometry = {
        let barrel = Shapes.cylinder(0.16, 0.11, 0.85, 20).applied(.rotationX(.pi / 2))
        let band = Shapes.cylinder(0.175, 0.165, 0.09, 20).applied(.rotationX(.pi / 2))
        return Geometry.join([
            part(barrel, PropMaterial.paper, .zero), part(band, PropMaterial.card, Vec3(0, 0, 0.38)), part(band, clay, Vec3(0, 0, -0.1)),
        ])
    }()

    /// An untidy stack to be squared away. Group at the root.
    static let papers: Geometry = {
        let sheet = box(0.7, 0.035, 0.9, 0.012)
        let askew: [Float] = [0.12, -0.2, 0.3, -0.08, 0.22, -0.3]
        return Geometry.join(askew.enumerated().map { i, a in
            part(sheet, i % 3 == 1 ? PropMaterial.card : PropMaterial.paper, Vec3(a * 0.12, 0.02 + Float(i) * 0.04, 1.0), turn: Vec3(0, a, 0))
        })
    }()

    /// A cup of tea, modelled around where the paw holds it.
    static let cup: Geometry = {
        let bowl = Shapes.cylinder(0.12, 0.085, 0.15, 20), brew = Shapes.cylinder(0.105, 0.105, 0.01, 20)
        let ear = Shapes.torus(0.045, 0.015, 6, 12, arc: .pi * 1.3).applied(.rotationZ(-.pi * 0.65))
        return Geometry.join([
            part(bowl, PropMaterial.china, Vec3(0, 0.07, 0.06)), part(brew, PropMaterial.tea, Vec3(0, 0.14, 0.06)),
            part(ear, PropMaterial.china, Vec3(0.13, 0.07, 0.06)),
        ])
    }()

    /// A rice ball, held between both paws.
    static let snack: Geometry = {
        let ball = Shapes.sphere(1, 20, 14).applied(.scale(Vec3(0.17, 0.16, 0.1)))
        return Geometry.join([part(ball, PropMaterial.rice, Vec3(0, 0.1, 0.08)), part(box(0.17, 0.09, 0.21, 0.02), PropMaterial.seaweed, Vec3(0, 0, 0.08))])
    }()

    static let button = Vec3(States.buttonX, States.buttonY, States.buttonZ)
    static let chimneyTop = Vec3(0.36, 0.94, 1.3)

    /// The machine's body, sat where the desk sits so the paws reach it the same way. Group at the root.
    static let machine: Geometry = {
        let casing = box(1.1, 0.62, 0.5, 0.08)
        let chimney = Shapes.cylinder(0.08, 0.1, 0.32, 24)
        let dial = Shapes.cylinder(0.1, 0.1, 0.03, 32).applied(.rotationX(.pi / 2))
        let socket = Shapes.cylinder(0.2, 0.22, 0.05, 32)
        return Geometry.join([
            part(casing, PropMaterial.paper, Vec3(0, 0.31, 1.2)), part(chimney, PropMaterial.card, Vec3(chimneyTop.x, 0.78, chimneyTop.z)),
            part(dial, clay, Vec3(0.2, 0.33, 1.45)), part(socket, PropMaterial.card, Vec3(button.x, 0.64, button.z)),
        ])
    }()

    /// The button cap: its top stands 0.1 proud of the socket's rim when the mesh is at BUTTON.y.
    static let buttonCap: Geometry = Shapes.cylinder(0.15, 0.15, 0.2, 32).applied(.translation(Vec3(0, 0.665 + 0.1 - 0.1 - States.buttonY, 0))).colored(PropMaterial.ink, roughness: 0.6)

    /// The ball eyes, pupils and steam are made of: SphereGeometry(1, 32, 20).
    static let disc: Geometry = Shapes.sphere(1, 32, 20)

    static func mesh(_ prop: PropName) -> Geometry {
        switch prop {
        case .book: book
        case .desk: desk
        case .machine: machine
        case .spyglass: spyglass
        case .papers: papers
        case .cup: cup
        case .snack: snack
        }
    }
}
