import Foundation
import Testing
@testable import TranscriptionEngines

@Suite("Engine catalog")
struct EngineCatalogTests {
    @Test("Ids are unique")
    func idsAreUnique() {
        let ids = EngineCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every option has plain-language copy")
    func copyIsPresent() {
        for option in EngineCatalog.all {
            #expect(!option.name.isEmpty)
            #expect(!option.download.isEmpty)
            #expect(!option.accuracy.isEmpty)
            #expect(!option.speed.isEmpty)
            // The summary is what people actually read when choosing.
            #expect(option.summary.count > 30, "summary for \(option.id) is too terse")
            #expect(!option.summary.lowercased().contains("quantiz"),
                    "summary for \(option.id) leaks jargon")
        }
    }

    @Test("Every option is an English model")
    func englishOnly() {
        for option in EngineCatalog.all {
            #expect(!option.name.lowercased().contains("all languages"),
                    "\(option.id) is advertised as multilingual")
            if case .whisper(let variant) = option.backend {
                // Multilingual Whisper builds are larger and slightly weaker on
                // English than the .en builds of the same size.
                #expect(variant.hasSuffix(".en"), "\(variant) is a multilingual Whisper build")
            }
        }
    }

    @Test("Accuracy wording comes from a known set")
    func accuracyWording() {
        let allowed: Set<String> = ["Basic", "Good", "Very good", "Best"]
        for option in EngineCatalog.all {
            #expect(allowed.contains(option.accuracy), "unexpected wording: \(option.accuracy)")
        }
    }

    @Test("An unknown id falls back instead of failing")
    func unknownIDFallsBack() {
        let option = EngineCatalog.option(id: "does-not-exist")
        #expect(option.isSupportedOnThisMac)
        #expect(EngineCatalog.all.contains(option))
    }

    @Test("An empty id resolves to the recommended default")
    func emptyIDUsesDefault() {
        #expect(EngineCatalog.option(id: "").id == EngineCatalog.defaultEngineID)
    }

    @Test("The default is usable on this Mac")
    func defaultIsSupported() {
        #expect(EngineCatalog.option(id: EngineCatalog.defaultEngineID).isSupportedOnThisMac)
    }

    @Test("Only supported options are offered")
    func selectableIsFiltered() {
        for option in EngineCatalog.selectable {
            #expect(option.isSupportedOnThisMac)
        }
        #expect(!EngineCatalog.selectable.isEmpty)
    }

    @Test("Moonshine ids match the underlying model catalog")
    func moonshineIDsResolve() {
        for option in EngineCatalog.all {
            if case .moonshine(let modelID) = option.backend {
                // option(id:) falls back silently, so a typo would otherwise
                // quietly select a different model.
                #expect(option.id == modelID, "engine id and model id should agree for \(option.id)")
            }
        }
    }

    @Test("Sizes are described consistently")
    func sizesAgree() {
        for option in EngineCatalog.all {
            if option.download == "No download" {
                #expect(option.approximateMB == 0)
            } else {
                #expect(option.approximateMB > 0, "\(option.id) claims a download but reports 0 MB")
            }
        }
    }

    @Test("Whisper models are kept out of the user's Documents folder")
    func whisperDownloadLocation() {
        // WhisperKit defaults to ~/Documents/huggingface, which is a poor place
        // to leave hundreds of megabytes.
        let path = EngineLoader.whisperDownloadBase.path
        #expect(path.contains("Application Support"))
        #expect(!path.contains("Documents"))
    }
}
