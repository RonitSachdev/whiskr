import Foundation

// Reading a meadow file, which may come from anyone. In order: the size before parsing; the strict
// parser with its nesting and value limits; the format major (a newer one refused before anything else
// is looked at); the migrations; then every field this Whiskr knows, checked for its type and range;
// then the counts. A count over a limit refuses the file: nothing is ever silently cut. Numbers are
// rounded to 4 decimals as they are read, so a meadow read once reads the same forever after.

extension MeadowDocument {
    /// Reads a meadow file. Throws `MeadowFileError`; never crashes, whatever `data` is.
    public static func read(_ data: Data, catalog: MeadowCatalog = .current, migration: MeadowMigration = .current) throws -> MeadowReading {
        guard data.count <= MeadowFormat.maxBytes else { throw MeadowFileError.tooLarge(bytes: data.count) }
        let json: MeadowJSON
        do {
            json = try MeadowJSON.parse(data, limits: MeadowFormat.limits)
        } catch let error as MeadowJSONError {
            throw MeadowFileError.notJSON(error)
        }
        guard let root = json.object, let major = root["whiskrMeadow"]?.integer, major >= 1 else { throw MeadowFileError.notAMeadow }
        let writtenBy = root["writtenBy"]?.string.flatMap { MeadowFormat.isWellFormedVersion($0) ? $0 : nil }
        guard major <= MeadowFormat.major else { throw MeadowFileError.needsNewerWhiskr(writtenBy: writtenBy) }

        var reader = Reader(catalog: catalog)
        let fileCatalog = try reader.optionalCount(root["catalog"], at: "catalog") ?? 1
        let migrated: MeadowJSON
        do {
            migrated = try migration.migrate(json, major: major, catalog: fileCatalog, toMajor: MeadowFormat.major, toCatalog: catalog.number)
        } catch {
            throw MeadowFileError.notAMeadow
        }
        guard let migrated = migrated.object else { throw MeadowFileError.notAMeadow }
        return try reader.document(migrated, major: major, writtenBy: writtenBy)
    }
}

private struct Reader {
    let catalog: MeadowCatalog
    var leftOutside = 0

    init(catalog: MeadowCatalog) {
        self.catalog = catalog
    }

    /// The top-level keys this Whiskr reads; every other key is a section from a newer one.
    static let knownKeys: Set<String> = [
        "whiskrMeadow", "formatMinor", "writtenBy", "catalog", "needsCatalog", "base", "name", "author", "description", "items", "ground",
    ]

    mutating func document(_ root: [String: MeadowJSON], major: Int, writtenBy: String?) throws -> MeadowReading {
        let minor = try optionalCount(root["formatMinor"], at: "formatMinor", from: 0) ?? 0
        let fileCatalog = try optionalCount(root["catalog"], at: "catalog") ?? 1
        let needsCatalog = try optionalCount(root["needsCatalog"], at: "needsCatalog") ?? 1
        let base = try text(root["base"], at: "base") ?? MeadowFormat.meadowBase
        guard base == MeadowFormat.meadowBase else { throw MeadowFileError.needsNewerWhiskr(writtenBy: writtenBy) }

        var document = MeadowDocument()
        document.readFrom = .init(formatMajor: major, formatMinor: minor, writtenBy: writtenBy, catalog: fileCatalog, needsCatalog: needsCatalog)
        document.name = try words(root["name"], .name)
        document.author = try words(root["author"], .author)
        document.description = try words(root["description"], .description)

        if let items = root["items"] {
            guard let list = items.array else { throw MeadowFileError.invalid(at: "items", .wrongType) }
            for (i, entry) in list.enumerated() {
                if let entry = try self.entry(entry, at: "items[\(i)]") { document.entries.append(entry) }
            }
        }
        if let ground = root["ground"] { document.ground = try self.ground(ground) }
        document.unknownSections = root.filter { !Self.knownKeys.contains($0.key) }

        try checkCounts(document)
        return MeadowReading(document: document, leftOutside: leftOutside, keepsNewerContent: document.hasNewerContent(catalog))
    }

    // MARK: Fields

    func optionalCount(_ value: MeadowJSON?, at path: String, from lowest: Int = 1) throws -> Int? {
        guard let value else { return nil }
        guard value.double != nil else { throw MeadowFileError.invalid(at: path, .wrongType) }
        guard let count = value.integer, count >= lowest, count <= Int(Int32.max) else { throw MeadowFileError.invalid(at: path, .outOfRange) }
        return count
    }

    func text(_ value: MeadowJSON?, at path: String) throws -> String? {
        guard let value else { return nil }
        guard let text = value.string else { throw MeadowFileError.invalid(at: path, .wrongType) }
        return text
    }

    func words(_ value: MeadowJSON?, _ field: MeadowText.Field) throws -> String {
        let raw = try self.text(value, at: field.rawValue) ?? ""
        guard MeadowText.mayFit(raw, field) else { throw MeadowFileError.textTooLong(field) }
        let text = MeadowText.sanitised(raw)
        guard MeadowText.fits(text, field) else { throw MeadowFileError.textTooLong(field) }
        return text
    }

    func number(_ value: MeadowJSON, at path: String) throws -> Double {
        guard let number = value.double else { throw MeadowFileError.invalid(at: path, .wrongType) }
        guard number.isFinite else { throw MeadowFileError.invalid(at: path, .notFinite) }
        return number
    }

    func numbers(_ value: MeadowJSON, count: Int, at path: String) throws -> [Double] {
        guard let list = value.array, list.count == count else { throw MeadowFileError.invalid(at: path, .wrongType) }
        return try list.map { try number($0, at: path) }
    }

    /// A point, rounded to 4 decimals; nil when it lies outside the meadow.
    func point(_ value: MeadowJSON, at path: String) throws -> MeadowPoint? {
        let pair = try numbers(value, count: 2, at: path)
        guard hypot(pair[0], pair[1]) <= MeadowFormat.reach + 1 else { return nil }
        let point = MeadowPoint(MeadowJSON.quantized(pair[0]), MeadowJSON.quantized(pair[1]))
        return point.reach <= MeadowFormat.reach ? point : nil
    }

    // MARK: Items

    mutating func entry(_ value: MeadowJSON, at path: String) throws -> MeadowEntry? {
        guard var fields = value.object else { throw MeadowFileError.invalid(at: path, .wrongType) }
        guard value.inlineText.utf8.count <= MeadowFormat.maxItemBytes else { throw MeadowFileError.thingTooLarge(at: path) }
        guard let idValue = fields["id"] else { throw MeadowFileError.invalid(at: "\(path).id", .missing) }
        guard let id = idValue.string else { throw MeadowFileError.invalid(at: "\(path).id", .wrongType) }
        guard MeadowCatalog.isWellFormed(id) else { throw MeadowFileError.invalid(at: "\(path).id", .malformedId) }
        guard let asset = catalog.asset(id) else { return .parcel(MeadowParcel(fields: fields)) }
        guard asset.nature != .paint, asset.nature != .eraser else { throw MeadowFileError.invalid(at: "\(path).id", .notAThing) }
        fields["id"] = nil

        func take(_ key: String) -> MeadowJSON? { fields.removeValue(forKey: key) }
        var item = MeadowItem(asset: asset.id, placement: .at(MeadowPoint(0, 0)))
        switch asset.shape {
        case .single:
            guard let at = take("at") else { throw MeadowFileError.invalid(at: "\(path).at", .missing) }
            guard let point = try point(at, at: "\(path).at") else { leftOutside += 1; return nil }
            item.placement = .at(point)
            if let turn = take("turn") { item.turn = MeadowNormal.turn(try number(turn, at: "\(path).turn")) }
            if let variant = take("variant") {
                guard variant.double != nil else { throw MeadowFileError.invalid(at: "\(path).variant", .wrongType) }
                guard let n = variant.integer, (0...MeadowFormat.maxVariant).contains(n) else {
                    throw MeadowFileError.invalid(at: "\(path).variant", .outOfRange)
                }
                item.variant = n
            }
        case .run:
            guard let run = take("points") else { throw MeadowFileError.invalid(at: "\(path).points", .missing) }
            guard let list = run.array else { throw MeadowFileError.invalid(at: "\(path).points", .wrongType) }
            guard MeadowFormat.runPoints.contains(list.count) else { throw MeadowFileError.invalid(at: "\(path).points", .pointCount) }
            var points: [MeadowPoint] = []
            var outside = false
            for (j, point) in list.enumerated() {
                if let point = try self.point(point, at: "\(path).points[\(j)]") { points.append(point) } else { outside = true }
            }
            if outside { leftOutside += 1; return nil }
            item.placement = .run(points)
        }
        if let range = asset.size, let size = take("size") {
            item.size = MeadowNormal.size(try numbers(size, count: 3, at: "\(path).size"), range)
        }
        if let lean = asset.tilt, let tilt = take("tilt") {
            item.tilt = MeadowNormal.tilt(try numbers(tilt, count: 2, at: "\(path).tilt"), lean)
        }
        if asset.seeded {
            guard let seed = take("seed") else { throw MeadowFileError.invalid(at: "\(path).seed", .missing) }
            guard seed.double != nil else { throw MeadowFileError.invalid(at: "\(path).seed", .wrongType) }
            guard let n = seed.integer, (0...Int(UInt32.max)).contains(n) else { throw MeadowFileError.invalid(at: "\(path).seed", .outOfRange) }
            item.seed = UInt32(n)
        }
        if let params = take("params") {
            guard let list = params.object else { throw MeadowFileError.invalid(at: "\(path).params", .wrongType) }
            for (name, value) in list {
                guard let parameter = asset.parameter(name) else { item.params[name] = value; continue }
                let place = "\(path).params.\(name)"
                switch parameter.kind {
                case .integer(let range, _):
                    let n = try number(value, at: place)
                    item.params[name] = .number(Double(MeadowNormal.integer(n, range)))
                case .choice:
                    guard let choice = value.string else { throw MeadowFileError.invalid(at: place, .wrongType) }
                    item.params[name] = .string(choice)
                }
            }
        }
        item.unknownFields = fields
        return .item(item)
    }

    // MARK: Ground

    func ground(_ value: MeadowJSON) throws -> GroundGrid {
        guard var fields = value.object else { throw MeadowFileError.invalid(at: "ground", .wrongType) }
        func take(_ key: String) throws -> MeadowJSON {
            guard let value = fields.removeValue(forKey: key) else { throw MeadowFileError.invalid(at: "ground.\(key)", .missing) }
            return value
        }
        guard try number(try take("cells"), at: "ground.cells") == Double(GroundGrid.side) else {
            throw MeadowFileError.invalid(at: "ground.cells", .outOfRange)
        }
        guard try number(try take("reach"), at: "ground.reach") == GroundGrid.reach else { throw MeadowFileError.invalid(at: "ground.reach", .outOfRange) }
        guard let paintList = try take("paints").array else { throw MeadowFileError.invalid(at: "ground.paints", .wrongType) }
        guard paintList.count <= GroundGrid.maxPaints else { throw MeadowFileError.invalid(at: "ground.paints", .outOfRange) }
        var paints: [String] = []
        for (i, paint) in paintList.enumerated() {
            let path = "ground.paints[\(i)]"
            guard let id = paint.string else { throw MeadowFileError.invalid(at: path, .wrongType) }
            guard MeadowCatalog.isWellFormed(id) else { throw MeadowFileError.invalid(at: path, .malformedId) }
            if let asset = catalog.asset(id), asset.nature != .paint { throw MeadowFileError.invalid(at: path, .notAPaint) } // the eraser too
            let current = catalog.currentId(id)
            guard !paints.contains(current) else { throw MeadowFileError.invalid(at: path, .duplicatePaint) }
            paints.append(current)
        }
        guard let runList = try take("runs").array else { throw MeadowFileError.invalid(at: "ground.runs", .wrongType) }
        var runs: [Int] = []
        runs.reserveCapacity(runList.count)
        for value in runList {
            guard let n = value.integer, abs(n) <= GroundGrid.cellCount else {
                throw MeadowFileError.invalid(at: "ground.runs", value.double == nil ? .wrongType : .outOfRange)
            }
            runs.append(n)
        }
        do {
            return GroundGrid(paints: paints, cells: try GroundGrid.cells(runs: runs, paintCount: paints.count), unknownFields: fields)
        } catch {
            throw MeadowFileError.invalid(at: "ground.runs", .runs(error))
        }
    }

    // MARK: Counts

    func checkCounts(_ document: MeadowDocument) throws {
        let total = document.entries.count
        guard total <= MeadowFormat.maxItems else { throw MeadowFileError.tooManyThings(count: total) }
        let newer = document.parcels.count
        guard newer <= MeadowFormat.maxNewerItems else { throw MeadowFileError.tooManyNewerThings(count: newer) }
        let counts = document.counts(catalog)
        for cap in MeadowCatalog.Cap.allCases {
            if let count = counts[cap], count > cap.limit { throw MeadowFileError.tooManyOfKind(cap, count: count) }
        }
    }
}

/// The one form each known number takes, as read and as written, so a meadow that has been through a
/// file once is a fixed point.
enum MeadowNormal {
    /// Rounded to 4 decimals, in [0, 2π).
    static func turn(_ radians: Double) -> Double {
        var t = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if t < 0 { t += 2 * .pi }
        let q = MeadowJSON.quantized(t)
        return q >= MeadowJSON.quantized(2 * .pi) ? 0 : q
    }

    /// Each axis clamped to `range` and rounded; nil when every axis is 1.
    static func size(_ axes: [Double], _ range: ClosedRange<Double>) -> [Double]? {
        let size = axes.map { MeadowJSON.quantized(min(max($0, range.lowerBound), range.upperBound)) }
        return size.allSatisfy { $0 == 1 } ? nil : size
    }

    /// Each lean clamped to ±`lean` and rounded; nil when upright.
    static func tilt(_ axes: [Double], _ lean: Double) -> [Double]? {
        let tilt = axes.map { MeadowJSON.quantized(min(max($0, -lean), lean)) }
        return tilt.allSatisfy { $0 == 0 } ? nil : tilt.map { $0 == 0 ? 0 : $0 }
    }

    /// Rounded to a whole number and clamped to `range`.
    static func integer(_ value: Double, _ range: ClosedRange<Int>) -> Int {
        Int(min(max(value.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
    }
}
