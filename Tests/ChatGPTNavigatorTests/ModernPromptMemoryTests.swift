import Foundation
import Testing
@testable import ChatGPTNavigator

struct ModernPromptMemoryTests {
    @Test func differentNativeIDsKeepIdenticalPromptsDistinctEvenInSingleMessageViews() {
        var memory = ModernPromptMemory()
        let first = memory.observe([ModernPromptObservation(text: "Again", nativeID: "message-A")], in: context())
        let next = memory.observe([ModernPromptObservation(text: "Again", nativeID: "message-B")], in: context())
        #expect(first.observedIDs != next.observedIDs)
        #expect(memory.records.count == 2)
    }

    private func context(_ title: String = "Chat A", id: String? = nil,
                         window: String = "window", region: String = "region",
                         process: Int32 = 42) -> ModernConversationContext {
        ModernConversationContext(processID: process, windowID: window, regionID: region,
                                  title: title, conversationID: id)
    }
    private func observations(_ text: [String]) -> [ModernPromptObservation] {
        text.map { ModernPromptObservation(text: $0) }
    }
    private func texts(_ memory: ModernPromptMemory) -> [String] {
        memory.orderedIDs.compactMap { memory.records[$0]?.text }
    }

    @Test func scrollingDownAndBackKeepsAllPromptsWithoutDuplicates() {
        var memory = ModernPromptMemory()
        let first = memory.observe(observations(["A", "B", "C"]), in: context())
        let second = memory.observe(observations(["B", "C", "D"]), in: context())
        #expect(second.observedIDs.prefix(2) == first.observedIDs.suffix(2))
        let third = memory.observe(observations(["A", "B"]), in: context())
        #expect(third.observedIDs == Array(first.observedIDs.prefix(2)))
        #expect(texts(memory) == ["A", "B", "C", "D"])
        #expect(memory.records.count == 4)
        #expect(!memory.isProvisional)
    }

    @Test func earlierOverlappingScansPrependOlderPrompts() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["D", "E"]), in: context())
        memory.observe(observations(["B", "C", "D"]), in: context())
        memory.observe(observations(["A", "B"]), in: context())
        #expect(texts(memory) == ["A", "B", "C", "D", "E"])
        #expect(!memory.isProvisional)
    }

    @Test func disjointSectionsRemainPendingUntilASharedPromptBridgesThem() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["C", "D"]), in: context())
        memory.observe(observations(["A", "B"]), in: context())
        #expect(memory.records.count == 4)
        #expect(memory.groups.count == 2)
        #expect(memory.isProvisional)
        memory.observe(observations(["B", "C"]), in: context())
        #expect(texts(memory) == ["A", "B", "C", "D"])
        #expect(memory.groups.count == 1)
        #expect(!memory.isProvisional)
    }

    @Test func anEmptyLoadedViewDoesNotEraseDiscoveries() {
        var memory = ModernPromptMemory()
        let first = memory.observe(observations(["A", "B"]), in: context())
        let empty = memory.observe([], in: context())
        #expect(empty.observedIDs.isEmpty)
        #expect(!empty.didReset)
        #expect(memory.orderedIDs == first.observedIDs)
        #expect(texts(memory) == ["A", "B"])
    }

    @Test func changingConversationRouteClearsOldPromptsEvenWithEqualTitles() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["Old prompt"]), in: context("Equal title", id: "route-A"))
        let result = memory.observe(observations(["Other prompt"]), in: context("Equal title", id: "route-B"))
        #expect(result.didReset)
        #expect(texts(memory) == ["Other prompt"])
    }

    @Test func strongIdentitySurvivesRenamingAndRegionRecreation() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["A"]), in: context("Before", id: "route-A", region: "old"))
        let update = memory.observe(observations(["B"]), in: context("Renamed", id: "route-A", region: "new"))
        #expect(!update.didReset)
        #expect(Set(texts(memory)) == ["A", "B"])
    }

    @Test func fallbackScopeResetsOnTitleWindowRegionOrProcessChanges() {
        let alternatives = [
            context("Chat B"), context(window: "another"), context(region: "another"),
            context(process: 99),
        ]
        for next in alternatives {
            var memory = ModernPromptMemory()
            memory.observe(observations(["Old"]), in: context())
            let update = memory.observe(observations(["New"]), in: next)
            #expect(update.didReset)
            #expect(texts(memory) == ["New"])
        }
    }

    @Test func genericWindowTitlesDoNotCreateAnUnscopedMemory() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["Old"]), in: context())
        let update = memory.observe(observations(["New"]), in: context("ChatGPT"))
        #expect(update.mode == .snapshotOnly)
        #expect(memory.records.isEmpty)
    }

    @Test func temporarilyMissingStrongIdentityPausesMergingWithoutErasingMemory() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["A"]), in: context(id: "route-A"))
        let pause = memory.observe(observations(["Unverified"]), in: context())
        #expect(pause.mode == .paused)
        #expect(texts(memory) == ["A"])
        memory.observe(observations(["A", "B"]), in: context(id: "route-A"))
        #expect(texts(memory) == ["A", "B"])
    }

    @Test func nativeMessageIDsDistinguishRepeatedTextAcrossUnloadedViews() {
        var memory = ModernPromptMemory()
        let a = ModernPromptObservation(text: "Again", nativeID: "message-A")
        let b = ModernPromptObservation(text: "Again", nativeID: "message-B")
        let first = memory.observe([a, b], in: context())
        let next = memory.observe([b], in: context())
        #expect(next.observedIDs == [first.observedIDs[1]])
        #expect(memory.records.count == 2)
        #expect(!memory.hasAmbiguousRepeats)
    }

    @Test func anAmbiguousRepeatedPromptDoesNotManufactureAnotherRow() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["Again", "Again"]), in: context())
        for _ in 0..<5 { memory.observe(observations(["Again"]), in: context()) }
        #expect(memory.records.count == 2)
        #expect(memory.hasAmbiguousRepeats)
    }

    @Test func neighborsDisambiguateAnIdenticalPrompt() {
        var memory = ModernPromptMemory()
        let first = memory.observe(observations(["A", "Again", "B", "Again", "C"]), in: context())
        let next = memory.observe(observations(["B", "Again", "C"]), in: context())
        #expect(next.observedIDs == Array(first.observedIDs.suffix(3)))
        #expect(memory.records.count == 5)
        #expect(!memory.hasAmbiguousRepeats)
    }

    @Test func aStableMessageIDUpdatesAnEditWithoutCreatingADuplicate() {
        var memory = ModernPromptMemory()
        let first = memory.observe([ModernPromptObservation(text: "Before", nativeID: "message-A")], in: context())
        let second = memory.observe([ModernPromptObservation(text: "After", nativeID: "message-A")], in: context())
        #expect(first.observedIDs == second.observedIDs)
        #expect(texts(memory) == ["After"])
    }

    @Test func anEditAndANewOccurrenceOfTheOldTextStayDistinct() {
        var memory = ModernPromptMemory()
        memory.observe([ModernPromptObservation(text: "Before", nativeID: "message-A")], in: context())
        memory.observe([ModernPromptObservation(text: "Before"),
                        ModernPromptObservation(text: "After", nativeID: "message-A")], in: context())
        #expect(memory.records.count == 2)
        #expect(texts(memory) == ["Before", "After"])
    }

    @Test func harmlessWhitespaceChangesDoNotDuplicateAMessage() {
        var memory = ModernPromptMemory()
        let first = memory.observe(observations(["Line one\nLine two"]), in: context())
        let second = memory.observe(observations(["Line one Line two"]), in: context())
        #expect(first.observedIDs == second.observedIDs)
        #expect(memory.records.count == 1)
    }

    @Test func conflictingOrderNeverDeletesPromptsOrCreatesACycle() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["A", "B"]), in: context())
        memory.observe(observations(["B", "A"]), in: context())
        #expect(texts(memory) == ["A", "B"])
        #expect(memory.isProvisional)
    }

    @Test func clearingStartsFreshFromTheCurrentView() {
        var memory = ModernPromptMemory()
        memory.observe(observations(["A", "B"]), in: context())
        memory.reset()
        memory.observe(observations(["B"]), in: context())
        #expect(texts(memory) == ["B"])
    }

    @Test func sequentialWindowsRetainALongHistoryWithCompactOrderEdges() {
        var memory = ModernPromptMemory()
        for start in stride(from: 0, through: 995, by: 5) {
            let page = (start..<min(start + 10, 1000)).map { "Prompt \($0)" }
            memory.observe(observations(page), in: context())
        }
        #expect(texts(memory) == (0..<1000).map { "Prompt \($0)" })
        #expect(!memory.isProvisional)
        for _ in 0..<10 {
            memory.observe(observations((700..<710).map { "Prompt \($0)" }), in: context())
        }
        #expect(memory.records.count == 1000)
    }

    @Test func identityExtractionRejectsGenericPagesAndViewportOrdinals() throws {
        let route = try #require(URL(string: "app://-/c/12345678-abcd-1234-abcd-123456789012"))
        #expect(ModernConversationContext.conversationID(from: route) != nil)
        #expect(ModernConversationContext.conversationID(from: URL(string: "app://-/index.html")!) == nil)
        #expect(ModernConversationContext.conversationID(from: URL(string: "file:///tmp/c/123456789012")!) == nil)
        #expect(ModernConversationContext.conversationID(from: URL(string: "/tmp/c/123456789012")!) == nil)
        #expect(ModernConversationContext.messageID(from: "conversation-turn-3") == nil)
        #expect(ModernConversationContext.messageID(from: "_Paragraph_xjxw3_2") == nil)
        #expect(ModernConversationContext.messageID(from: "turn-12345678-abcd-1234-abcd-123456789012") != nil)
    }
}
