import ArgumentParser
import Foundation

struct AssemblePDF: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assemble-pdf",
        abstract: "Assemble a list of TIFF pages into a single PDF, optionally with Vision OCR."
    )

    @Option(name: .long, help: "Output PDF path.")
    var output: String

    @Flag(name: .long, help: "Run Vision OCR per page and embed an invisible text layer.")
    var searchable = false

    @Argument(help: "Page TIFF paths, in the order they should appear in the output PDF.")
    var pages: [String] = []

    func run() throws {
        guard !pages.isEmpty else {
            FileHandle.standardError.write(Data("assemble-pdf: at least one page TIFF is required\n".utf8))
            throw ExitCode(1)
        }

        let result = SearchablePDF.assemble(
            pageTIFFs: pages.map { URL(fileURLWithPath: $0) },
            outputURL: URL(fileURLWithPath: output),
            searchable: searchable
        )

        switch result {
        case .success:
            JSONOut.line(AssemblePdfResult(
                status: "ok",
                output: output,
                pages: pages.count,
                searchable: searchable
            ))
        case .failure(let err):
            FileHandle.standardError.write(Data("assemble-pdf: \(err.localizedDescription)\n".utf8))
            throw ExitCode(1)
        }
    }
}

private struct AssemblePdfResult: Encodable {
    let status: String
    let output: String
    let pages: Int
    let searchable: Bool
}
