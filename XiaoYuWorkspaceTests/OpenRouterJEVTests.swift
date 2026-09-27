import Foundation
import XCTest
@testable import XiaoYuWorkspace

final class OpenRouterJEVTests: XCTestCase {
    func testRequestUsesVersionedModelAndDecisionsEndpoint() throws {
        let request = JEVModelRequest(
            state: ["file_name": "Figure 1.tif"],
            questions: [
                "category": .choice("Choose a research category", criteria: [
                    "figures": "Figures and charts",
                    "other": "Anything else"
                ]),
                "is_submission": .noul("Is this a submission file?")
            ])

        let urlRequest = try OpenRouterJEVModelClient.makeURLRequest(request, apiKey: "test-key")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/systemone")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "typesafe/jev-1.13")
        let state = try XCTUnwrap(json["state"] as? [String: String])
        XCTAssertEqual(state["file_name"], "Figure 1.tif")
        let questions = try XCTUnwrap(json["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["category"]?["type"] as? String, "choice")
        XCTAssertEqual(questions["is_submission"]?["type"] as? String, "noul")
    }

    func testDecodesTypedJevAnswers() throws {
        let data = Data(#"""
        {
            "model":"typesafe/jev-1.13-20260917",
            "answers":{
                "category":{"type":"choice","choice":"figures","confidence":0.81,
                            "probabilities":{"figures":0.9,"other":0.1}},
                "is_submission":{"type":"noul","noul":0.12}
            },
            "usage":{"input_tokens":120,"output_tokens":10,"cost":0.00001}
        }
        """#.utf8)
        let response = try JSONDecoder().decode(JEVModelResponse.self, from: data)
        XCTAssertEqual(response.answers["category"]?.choice, "figures")
        XCTAssertEqual(response.answers["category"]?.confidence, 0.81)
        XCTAssertEqual(response.answers["is_submission"]?.noul, 0.12)
        XCTAssertEqual(response.usage?.inputTokens, 120)
    }

    func testRejectsRequestWithoutDecisionQuestion() {
        let request = JEVModelRequest(state: ["file_name": "file.pdf"], questions: [:])
        XCTAssertThrowsError(try OpenRouterJEVModelClient.makeURLRequest(request, apiKey: "test-key"))
    }
}
