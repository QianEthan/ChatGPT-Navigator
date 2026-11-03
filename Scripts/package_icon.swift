import Foundation

// Package the already resized PNG representations in a native ICNS container.
// This avoids depending on the host's legacy icon image encoder.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: package_icon.swift iconset-directory output.icns")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let representations = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]
func lengthBytes(_ length: Int) -> Data {
    var bigEndian = UInt32(length).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
var payload = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: source.appendingPathComponent(name))
    payload.append(Data(type.utf8))
    payload.append(lengthBytes(png.count + 8))
    payload.append(png)
}
var icon = Data("icns".utf8)
icon.append(lengthBytes(payload.count + 8))
icon.append(payload)
try icon.write(to: destination, options: .atomic)
