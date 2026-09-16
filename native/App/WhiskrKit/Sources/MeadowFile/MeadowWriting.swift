import Foundation

// Writing a meadow file: always the newest format, keys sorted, numbers at most 4 decimals, so the same
// meadow is always the same bytes. What was kept from a newer Whiskr is written back as it was read,
// and the file then says it needs at least what that Whiskr's file needed.

extension MeadowDocument {
    /// The meadow as a file, saved by Whiskr `writtenBy` (its version, `MeadowFormat.isWellFormedVersion`).
    /// Only what can be read back is written: the result is read again with the same checks as any
    /// file, so a meadow over a limit is refused here rather than saved and then unreadable.
    public func fileData(writtenBy: String, catalog: MeadowCatalog = .current) throws -> Data {
        let data = Data(try fileJSON(writtenBy: writtenBy, catalog: catalog).fileText.utf8)
        _ = try MeadowDocument.read(data, catalog: catalog)
        return data
    }

    /// The meadow as the JSON its file holds.
    func fileJSON(writtenBy: String, catalog: MeadowCatalog) throws -> MeadowJSON {
        guard MeadowFormat.isWellFormedVersion(writtenBy) else { throw MeadowFileError.invalid(at: "writtenBy", .outOfRange) }
        let newer = hasNewerContent(catalog)
        var root = unknownSections
        root["whiskrMeadow"] = .number(Double(MeadowFormat.major))
        root["formatMinor"] = .number(Double(newer ? max(MeadowFormat.minor, readFrom?.formatMinor ?? 0) : MeadowFormat.minor))
        root["writtenBy"] = .string(writtenBy)
        root["catalog"] = .number(Double(catalog.number))
        root["needsCatalog"] = .number(Double(needsCatalog(catalog)))
        root["base"] = .string(base)
        for (field, text) in [(MeadowText.Field.name, name), (.author, author), (.description, description)] {
            let clean = MeadowText.sanitised(text)
            guard MeadowText.fits(clean, field) else { throw MeadowFileError.textTooLong(field) }
            root[field.rawValue] = .string(clean)
        }
        root["items"] = .array(try entries.enumerated().map { i, entry in
            switch entry {
            case .item(let item): .object(try item.fileFields(catalog, at: "items[\(i)]"))
            case .parcel(let parcel): .object(parcel.fields)
            }
        })
        if let ground {
            var fields = ground.unknownFields
            fields["cells"] = .number(Double(GroundGrid.side))
            fields["reach"] = .number(GroundGrid.reach)
            fields["paints"] = .array(ground.paints.map { .string($0) })
            fields["runs"] = .array(ground.runs.map { .number(Double($0)) })
            root["ground"] = .object(fields)
        }
        return .object(root)
    }
}

extension MeadowItem {
    /// Its fields as a file writes them, in the form reading gives (`MeadowNormal`); defaults left out.
    /// A spot outside the meadow, a number that is not finite or a shape out of range is refused, saying
    /// where (`path`).
    func fileFields(_ catalog: MeadowCatalog, at path: String) throws -> [String: MeadowJSON] {
        guard let asset = catalog.asset(asset) else { throw MeadowFileError.invalid(at: "\(path).id", .malformedId) }
        func finite(_ values: [Double], _ field: String) throws {
            guard values.allSatisfy(\.isFinite) else { throw MeadowFileError.invalid(at: "\(path).\(field)", .notFinite) }
        }
        func point(_ p: MeadowPoint, _ field: String) throws -> MeadowJSON {
            try finite([p.x, p.z], field)
            guard MeadowPoint(MeadowJSON.quantized(p.x), MeadowJSON.quantized(p.z)).reach <= MeadowFormat.reach else {
                throw MeadowFileError.invalid(at: "\(path).\(field)", .outOfRange)
            }
            return .array([.number(p.x), .number(p.z)])
        }
        var fields = unknownFields
        fields["id"] = .string(asset.id)
        switch placement {
        case .at(let at):
            fields["at"] = try point(at, "at")
            try finite([turn], "turn")
            let turn = MeadowNormal.turn(turn)
            if turn != 0 { fields["turn"] = .number(turn) }
            guard (0...MeadowFormat.maxVariant).contains(variant) else { throw MeadowFileError.invalid(at: "\(path).variant", .outOfRange) }
            if variant != 0 { fields["variant"] = .number(Double(variant)) }
        case .run(let points):
            fields["points"] = .array(try points.map { try point($0, "points") })
        }
        if let range = asset.size, let size {
            guard size.count == 3 else { throw MeadowFileError.invalid(at: "\(path).size", .wrongType) }
            try finite(size, "size")
            if let normal = MeadowNormal.size(size, range) { fields["size"] = .array(normal.map { .number($0) }) }
        }
        if let lean = asset.tilt, let tilt {
            guard tilt.count == 2 else { throw MeadowFileError.invalid(at: "\(path).tilt", .wrongType) }
            try finite(tilt, "tilt")
            if let normal = MeadowNormal.tilt(tilt, lean) { fields["tilt"] = .array(normal.map { .number($0) }) }
        }
        if asset.seeded, let seed { fields["seed"] = .number(Double(seed)) }
        if !params.isEmpty { fields["params"] = .object(params) }
        return fields
    }
}
