import Testing
@testable import ChatGPTNavigator

struct ModernConversationParserTests {
    @Test func aStreamingReplyWithoutItsHeadingDoesNotBecomePartOfThePrompt() {
        let nodes = [
            n("AXGroup", "", 0),
            n("AXHeading", "You said:", 1),
            n("AXGroup", "", 1),
            n("AXGroup", "", 2),
            n("AXStaticText", "Please explain the result.", 3),
            n("AXGroup", "", 1),
            n("AXStaticText", "Thinking", 3),
            n("AXStaticText", "Working for 1m50s", 3),
            n("AXStaticText", "A growing response...", 3),
        ]
        #expect(ModernConversationParser.userPrompts(in: nodes).map(\.text) == ["Please explain the result."])
    }

    @Test func streamingSnapshotsProduceOneRememberedPrompt() {
        var memory = ModernPromptMemory()
        let scope = ModernConversationContext(processID: 1, windowID: "w", regionID: "r",
                                              title: "Chat A", conversationID: nil)
        for seconds in 0..<30 {
            let nodes = [
                n("AXHeading", "You said:", 1),
                n("AXGroup", "", 1),
                n("AXStaticText", "The same user prompt", 3),
                n("AXGroup", "", 1),
                n("AXStaticText", "Working for \(seconds)s", 3),
                n("AXStaticText", String(repeating: "Reply ", count: seconds + 1), 3),
            ]
            let parsed = ModernConversationParser.userPrompts(in: nodes)
            memory.observe(parsed.map { ModernPromptObservation(text: $0.text) }, in: scope)
        }
        #expect(memory.records.count == 1)
        #expect(memory.records.values.first?.text == "The same user prompt")
    }

    @Test func multipleParagraphsInsideTheSameBubbleStayTogether() {
        let nodes = [
            n("AXHeading", "You said:", 1),
            n("AXGroup", "", 1),
            n("AXGroup", "", 2), n("AXStaticText", "First paragraph", 3),
            n("AXGroup", "", 2), n("AXStaticText", "Second paragraph", 3),
            n("AXGroup", "", 1), n("AXStaticText", "Thinking", 3),
        ]
        #expect(ModernConversationParser.userPrompts(in: nodes).first?.text == "First paragraph\nSecond paragraph")
    }

    @Test func aUserCanLiterallySayThinkingWithoutBeingFilteredOut() {
        let nodes = [
            n("AXHeading", "You said:", 1),
            n("AXGroup", "", 1), n("AXStaticText", "Thinking", 3),
            n("AXGroup", "", 1), n("AXStaticText", "Working for 2s", 3),
        ]
        #expect(ModernConversationParser.userPrompts(in: nodes).map(\.text) == ["Thinking"])
    }

    @Test func isolatedUserTextStopsBeforeAnUnlabelledReply() {
        let nodes = [
            n("AXHeading", "You said:", 1), n("AXStaticText", "Question", 3),
            n("AXStaticText", "Thinking", 3), n("AXStaticText", "Response", 3),
        ]
        #expect(ModernConversationParser.userPrompts(in: nodes).map(\.text) == ["Question"])
    }

    private func n(_ role: String, _ text: String = "", _ depth: Int) -> ModernConversationNode {
        ModernConversationNode(role: role, text: text, depth: depth)
    }

    @Test func separatesTheThreeObservedUserTurnsFromRepliesAndMetadata() {
        var nodes = [n("AXGroup", "", 0)]
        for (index, fruit) in ["Apple", "Banana", "Cherry"].enumerated() {
            let number = ["ONE", "TWO", "THREE"][index]
            nodes += [
                n("AXGroup", "", 1),
                n("AXHeading", "You said:", 2),
                n("AXStaticText", "You said:", 3),
                n("AXStaticText", "7:41 PM", 2),
                n("AXGroup", "", 2),
                n("AXGroup", "", 3),
                n("AXStaticText", "NAVTEST \(number). Reply with only: \(fruit).", 4),
                n("AXHeading", "ChatGPT said:", 2),
                n("AXStaticText", "ChatGPT said:", 3),
                n("AXStaticText", "\(fruit).", 4),
                n("AXButton", "Copy", 2),
                n("AXStaticText", "Copy", 3),
                n("AXStaticText", "7:41 PM", 2),
            ]
        }
        let prompts = ModernConversationParser.userPrompts(in: nodes)
        #expect(prompts.map(\.text) == [
            "NAVTEST ONE. Reply with only: Apple.",
            "NAVTEST TWO. Reply with only: Banana.",
            "NAVTEST THREE. Reply with only: Cherry.",
        ])
        #expect(prompts.map(\.turn) == [0, 2, 4])
    }

    @Test func preservesOneCharacterPromptsAndRepeatedParagraphs() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 1),
            n("AXGroup", "", 2),
            n("AXStaticText", "A", 4),
            n("AXStaticText", "again", 4),
            n("AXStaticText", "again", 4),
            n("AXHeading", "ChatGPT said:", 1),
            n("AXStaticText", "Assistant reply", 4),
        ])
        #expect(prompts.first?.text == "A\nagain\nagain")
        #expect(prompts.first?.sourceIndices == [2, 3, 4])
    }

    @Test func excludesControlsAndAvoidsCountingTheirChildren() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 1),
            n("AXButton", "Edit", 2),
            n("AXStaticText", "Edit", 3),
            n("AXTextArea", "Unsent draft", 2),
            n("AXStaticText", "Unsent draft", 3),
            n("AXGroup", "", 2),
            n("AXStaticText", "Actual prompt", 4),
        ])
        #expect(prompts.first?.text == "Actual prompt")
    }

    @Test func treatsDeeperQuotedSpeakerHeadingsAsMessageContent() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 1),
            n("AXGroup", "", 2),
            n("AXStaticText", "Explain this quoted heading:", 3),
            n("AXGroup", "", 3),
            n("AXHeading", "ChatGPT said:", 4),
            n("AXStaticText", "ChatGPT said:", 5),
            n("AXStaticText", "followed by this text", 3),
            n("AXHeading", "ChatGPT said:", 1),
            n("AXHeading", "You said:", 4),
            n("AXStaticText", "Assistant quoted content", 5),
        ])
        #expect(prompts.count == 1)
        #expect(prompts.first?.text == "Explain this quoted heading:\nChatGPT said:\nfollowed by this text")
    }

    @Test func doesNotInferOwnershipFromTextOrStyleAlone() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXGroup", "You said:", 1),
            n("AXStaticText", "NAVTEST ONE", 4),
            n("AXStaticText", "_Paragraph_xjxw3_2", 4),
        ])
        #expect(prompts.isEmpty)
    }

    @Test func preservesATimeTypedInTheBodyButOmitsShallowMetadataTime() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 1),
            n("AXStaticText", "7:41 PM", 1),
            n("AXStaticText", "7:41 PM", 4),
            n("AXHeading", "ChatGPT said:", 1),
        ])
        #expect(prompts.first?.text == "7:41 PM")
    }

    @Test func keepsIdenticalPromptsAsSeparateTurns() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 1), n("AXStaticText", "Again", 4),
            n("AXHeading", "ChatGPT said:", 1), n("AXStaticText", "Okay", 4),
            n("AXHeading", "You said:", 1), n("AXStaticText", "Again", 4),
        ])
        #expect(prompts.map(\.text) == ["Again", "Again"])
        #expect(prompts.map(\.turn) == [0, 2])
    }

    @Test func omitsTheUnfinishedTailWhenTraversalIsTruncated() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 1), n("AXStaticText", "Complete prompt", 4),
            n("AXHeading", "ChatGPT said:", 1), n("AXStaticText", "Reply", 4),
            n("AXHeading", "You said:", 1), n("AXStaticText", "Partial prompt", 4),
        ], includeTrailingMessage: false)
        #expect(prompts.map(\.text) == ["Complete prompt"])
    }

    @Test func stopsReadingWhenTheWalkLeavesTheTurnContainer() {
        let prompts = ModernConversationParser.userPrompts(in: [
            n("AXHeading", "You said:", 3), n("AXStaticText", "Prompt", 6),
            n("AXGroup", "", 1), n("AXStaticText", "Unrelated sidebar", 4),
        ])
        #expect(prompts.first?.text == "Prompt")
    }

    @Test func skipsAssistantOnlyAndUnknownLanguageSnapshots() {
        #expect(ModernConversationParser.userPrompts(in: [
            n("AXHeading", "ChatGPT said:", 1), n("AXStaticText", "Reply", 4),
        ]).isEmpty)
        #expect(ModernConversationParser.userPrompts(in: [
            n("AXHeading", "Vous avez dit :", 1), n("AXStaticText", "Unknown role", 4),
        ]).isEmpty)
    }
}
