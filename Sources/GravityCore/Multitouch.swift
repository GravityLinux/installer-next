// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CoreFoundation

enum Multitouch {
    static func files(_ root: URL) throws -> [FirmwareFile] {
        var files: [FirmwareFile] = []
        for machine in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where machine.lastPathComponent.hasPrefix("j") {
            let path = machine.appending("Multitouch.im4p")
            if !fm.fileExists(atPath: path.path) { continue }
            let im4p = try IM4P.extract(Data(contentsOf: path)); try require(im4p.name == "mtfw", "Unexpected multitouch payload")
            var xml = im4p.data; while xml.last == 0 { xml.removeLast() }
            let document = try XMLDocument(data: xml, options: [.nodePreserveAll])
            guard let root = document.rootElement() else { throw InstallerError("Invalid multitouch plist") }
            var ids: [String: XMLElement] = [:]
            func resolve(_ element: XMLElement, depth: Int = 0) throws -> XMLElement {
                try require(depth < 64, "Multitouch plist reference nesting exceeds limit")
                if let id = element.attribute(forName: "ID")?.stringValue { ids[id] = element }
                if let id = element.attribute(forName: "IDREF")?.stringValue {
                    guard let original = ids[id] else { throw InstallerError("Missing multitouch plist reference") }
                    return try resolve(original, depth: depth + 1)
                }
                let result = XMLElement(name: element.name ?? "")
                let children = element.children?.compactMap { $0 as? XMLElement } ?? []
                if children.isEmpty { result.stringValue = element.stringValue }
                else { for child in children { result.addChild(try resolve(child, depth: depth + 1)) } }
                return result
            }
            let resolved = try resolve(root), wrapper = XMLElement(name: "plist"); wrapper.addChild(resolved)
            let values = try plist(XMLDocument(rootElement: wrapper).xmlData)
            var collected = Set<String>()
            for (key, value) in values {
                let trackpad = key.hasPrefix("C1FD"), touchbar = key.hasPrefix("C1FB")
                if !trackpad && !touchbar { continue }
                let name = "apple/\(trackpad ? "tpmtfw" : "dfrmtfw")-\(machine.lastPathComponent).bin"
                try require(collected.insert(name).inserted, "Duplicate multitouch firmware")
                let payload = try trackpad ? trackpadBinary(array(value)) : touchbarBinary(array(value))
                files.append(FirmwareFile(name: name, data: payload))
            }
        }
        return files.sorted { $0.name < $1.name }
    }
    static func touchbarBinary(_ values: [[String: Any]]) throws -> Data {
        var result = Data("Z2FW".utf8); result.appendLE(1)
        for value in values where string(value["Type"]) == "Config" {
            guard let initData = dict(dict(value["Config"])["SPI Config"])["Init Payload"] as? Data else { throw InstallerError("Missing touchbar init payload") }
            result.appendLE(0); result.appendLE(UInt64(initData.count)); result.append(initData); result.pad(to: 4)
        }
        for value in values {
            var packet = Data()
            switch string(value["Type"]) {
            case "Binary":
                guard let payload = value["Payload"] as? Data else { throw InstallerError("Missing touchbar binary payload") }
                packet.appendLE(0x3001, bytes: 2); packet.appendLE(UInt64((payload.count + 3) / 4), bytes: 2); packet.appendLE(UInt64(int(value["Address"])))
                packet.appendLE(packet.dropFirst(2).reduce(0) { $0 + UInt64($1) }, bytes: 2)
                packet.append(payload); packet.appendLE(payload.reduce(0) { $0 + UInt64($1) })
            case "Property": result.appendLE(2); result.appendLE(UInt64(int(value["Address"]))); continue
            case "RequestCalibration": packet.appendLE(0x1f01, bytes: 2)
            case "ReadModifyWrite":
                packet.appendLE(0x1e33, bytes: 2)
                for field in ["Address", "Mask", "Value"] { packet.appendLE(UInt64(int(value[field]))) }
                packet.appendLE(packet.dropFirst(2).reduce(0) { $0 + UInt64($1) }, bytes: 2)
            default: continue
            }
            result.appendLE(1); result.appendLE(UInt64(packet.count)); result.append(packet); result.pad(to: 4)
        }
        return result
    }
    static func trackpadBinary(_ values: [[String: Any]]) throws -> Data {
        var blob = Data(), interfaceOffset: Int?
        func encode(_ value: Any) throws {
            if value is NSNull {
                try require(interfaceOffset == nil, "Multiple trackpad interface placeholders")
                interfaceOffset = blob.count; blob.append(0)
            } else if let data = value as? Data {
                try require(data.count <= 65535, "Trackpad payload too large")
                while (blob.count + 3) % 4 != 0 { blob.append(0xd3) }
                blob.append(0x59); blob.append(UInt8(data.count >> 8)); blob.append(UInt8(data.count & 255)); blob.append(data)
            } else if let text = value as? String {
                let bytes = Data(text.utf8) + Data([0]); try require(bytes.count <= 255, "Trackpad string too long")
                if bytes.count < 24 { blob.append(UInt8(0x60 + bytes.count)) } else { blob.append(contentsOf: [0x78, UInt8(bytes.count)]) }; blob.append(bytes)
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { try require(number.boolValue, "Unsupported trackpad boolean"); blob.append(0xf5) }
                else {
                    let n = number.uint64Value; try require(n <= UInt32.max, "Trackpad integer overflow")
                    if n < 24 { blob.append(UInt8(n)) }
                    else if n <= 255 { blob.append(contentsOf: [0x18, UInt8(n)]) }
                    else if n <= 65535 { blob.append(contentsOf: [0x19, UInt8(n >> 8), UInt8(n & 255)]) }
                    else { blob.append(0x1a); for i in (0..<4).reversed() { blob.append(UInt8(truncatingIfNeeded: n >> (i * 8))) } }
                }
            } else if let values = value as? [Any] {
                try require(values.count < 24, "Trackpad array too large"); blob.append(UInt8(0x80 + values.count)); for value in values { try encode(value) }
            } else if var value = value as? [String: Any] {
                // Interface configs without HIDRecorder Descriptor have one placeholder.
                if let configs = value["Interface Config"] as? [[String: Any]] {
                    value["Interface Config"] = configs.map { config -> [String: Any] in var c = config; if c["HIDRecorder Descriptor"] == nil { c["bInterfaceNumber"] = NSNull() }; return c }
                }
                try require(value.count < 16, "Trackpad dictionary too large"); blob.append(UInt8(0xa0 + value.count))
                for key in value.keys.sorted() { try encode(key); try encode(value[key]!) }
            } else { throw InstallerError("Unsupported trackpad plist value") }
        }
        try encode(values); guard let offset = interfaceOffset else { throw InstallerError("Missing trackpad interface placeholder") }
        var result = Data("HIDF".utf8); for n in [1, 32, blob.count, offset] { result.appendLE(UInt64(n)) }; result.append(Data(count: 12)); result.append(blob); return result
    }
}
