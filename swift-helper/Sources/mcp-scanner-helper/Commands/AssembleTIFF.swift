import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AssembleTIFF: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "assemble-tiff", abstract: "Assemble scanned TIFF pages in order.")
    @Option(name: .customLong("output")) var output: String
    @Argument var pages: [String]

    func run() throws {
        try TIFFAssembly.assemble(pages: pages.map { URL(fileURLWithPath: $0) }, output: URL(fileURLWithPath: output))
    }
}

enum TIFFAssembly {
    static func assemble(pages: [URL], output: URL) throws {
        guard !pages.isEmpty else { throw ValidationError("at least one page is required") }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.tiff.identifier as CFString, pages.count, nil) else {
            throw ValidationError("could not create TIFF output")
        }
        for page in pages {
            guard let source = CGImageSourceCreateWithURL(page as CFURL, nil),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetType(source) == UTType.tiff.identifier as CFString else {
                throw ValidationError("expected a readable single-page TIFF: \(page.path)")
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        }
        guard CGImageDestinationFinalize(destination),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetCount(check) == pages.count else {
            throw ValidationError("failed to assemble every TIFF page")
        }
        try FileManager.default.moveItem(at: temporary, to: output)
    }
}
