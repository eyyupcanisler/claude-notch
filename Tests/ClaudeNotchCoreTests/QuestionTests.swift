import Foundation
import XCTest

@testable import ClaudeNotchCore

final class QuestionTests: XCTestCase {
  private let input = JSONValue.parse(Data("""
    {"questions":[
      {"question":"Hangi çatı?","header":"Çatı","multiSelect":false,
       "options":[{"label":"React","description":"a"},{"label":"Vue","description":"b"}]},
      {"question":"Neler?","header":"Özellik","multiSelect":true,
       "options":[{"label":"Test","description":""},{"label":"Lint","description":""}]}]}
    """.utf8))!

  func testParse() {
    let qs = AskedQuestion.parse(input)
    XCTAssertEqual(qs?.count, 2)
    XCTAssertEqual(qs?[1].multiSelect, true)
    XCTAssertEqual(qs?[0].options.map(\.label), ["React", "Vue"])
    XCTAssertNil(AskedQuestion.parse(JSONValue.parse(Data(#"{"questions":[]}"#.utf8))))
  }

  func testAnswerBodyEchoesInputAndJoinsMultiSelect() throws {
    let body = PendingQuestion.answerBody(
      toolInput: input, answers: ["Hangi çatı?": ["React"], "Neler?": ["Test", "Lint"]])
    let v = try XCTUnwrap(JSONValue.parse(body))
    let out = try XCTUnwrap(v["hookSpecificOutput"])
    XCTAssertEqual(out["hookEventName"]?.stringValue, "PreToolUse")
    XCTAssertEqual(out["permissionDecision"]?.stringValue, "allow")
    XCTAssertEqual(out["updatedInput"]?["answers"]?["Neler?"]?.stringValue, "Test, Lint")
    XCTAssertEqual(out["updatedInput"]?["questions"]?.arrayValue?.count, 2)
  }

  func testCompleteness() throws {
    let q = PendingQuestion(
      id: "q", sessionID: "s", agentID: nil, questions: try XCTUnwrap(AskedQuestion.parse(input)),
      toolInput: input, createdAt: Date(), reply: PermissionReply { _ in })
    XCTAssertFalse(q.isComplete(["Hangi çatı?": ["React"]]))
    XCTAssertFalse(q.isComplete(["Hangi çatı?": ["React", "Vue"], "Neler?": ["Test"]]))
    XCTAssertFalse(q.isComplete(["Hangi çatı?": ["Svelte"], "Neler?": ["Test"]]))
    XCTAssertTrue(q.isComplete(["Hangi çatı?": ["Vue"], "Neler?": ["Test", "Lint"]]))
  }
}

final class QuestionActivityTests: XCTestCase {
  func testActivityShowsTheQuestionNotJSON() {
    let json = #"{"questions":[{"question":"Hangi düzen?","header":"D","options":[{"label":"A"}]}]}"#
    let input = JSONValue.parse(Data(json.utf8))
    XCTAssertEqual(
      ToolSummary.target(toolName: "AskUserQuestion", input: input), "Soru: Hangi düzen?")
  }
}
