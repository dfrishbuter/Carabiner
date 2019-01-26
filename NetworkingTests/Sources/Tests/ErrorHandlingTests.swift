//
// Created by Nikita Zatsepilov on 2019-01-18.
// Copyright (c) 2019 Ronas IT. All rights reserved.
//

import XCTest
import Networking
import Alamofire

private enum PartialErrorHandlingChainTestKind {
    case testWithFailure
    case testWithRetry
}

private enum EndpointErrorMappingTestKind {
    case mappedErrorWithResponseCode(Int, to: MockError)
    case mappedURLError(with: URLError.Code, to: MockError)
}

final class ErrorHandlingTests: XCTestCase {

    private lazy var errorHandler: MockErrorHandler = .init()
    private lazy var networkService: NetworkService = {
        let errorHandlingService = ErrorHandlingService(errorHandlers: [errorHandler])
        return NetworkService(errorHandlingService: errorHandlingService)
    }()

    private var request: CancellableRequest?
    
    override func tearDown() {
        super.tearDown()
        errorHandler.errorHandling = nil
        request = nil
    }

    func testFullErrorHandlingChain() {
        let errorHandlingTriggeredExpectation = expectation(description: "Expecting error handling triggered multiple times")
        errorHandlingTriggeredExpectation.assertForOverFulfill = true

        let failureTriggeredExpectation = expectation(description: "Expecting request failure")
        failureTriggeredExpectation.expectedFulfillmentCount = 1
        failureTriggeredExpectation.assertForOverFulfill = true

        let firstError = MockError()
        let secondError = MockError()
        let thirdError = MockError()
        errorHandlingTriggeredExpectation.expectedFulfillmentCount = 3

        let errorHandlers = [
            MockErrorHandler { error, completion in
                errorHandlingTriggeredExpectation.fulfill()
                completion(.continueErrorHandling(with: firstError))
            },
            MockErrorHandler { error, completion in
                guard let error = error as? MockError else {
                    XCTFail("Test uses mock errors")
                    return
                }
                XCTAssertTrue(error === firstError)
                errorHandlingTriggeredExpectation.fulfill()
                completion(.continueErrorHandling(with: secondError))
            },
            MockErrorHandler { error, completion in
                guard let error = error as? MockError else {
                    XCTFail("Test uses mock errors")
                    return
                }
                XCTAssertTrue(error === secondError)
                errorHandlingTriggeredExpectation.fulfill()
                completion(.continueErrorHandling(with: thirdError))
            }
        ]

        let errorHandlingService = ErrorHandlingService(errorHandlers: errorHandlers)
        let networkService = MockNetworkService(errorHandlingService: errorHandlingService)
        request = networkService.request(for: MockEndpoint.failure, success: {
            XCTFail("Invalid case")
        }, failure: { error in
            guard let error = error as? MockError else {
                XCTFail("Test uses mock errors")
                return
            }
            XCTAssertTrue(error === thirdError)
            failureTriggeredExpectation.fulfill()
        })

        let expectations = [errorHandlingTriggeredExpectation, failureTriggeredExpectation]
        wait(for: expectations, timeout: 10, enforceOrder: true)
        request = nil
    }

    func testPartialErrorHandlingChainWithFailure() {
        testPartialErrorHandlingChain(testKind: .testWithFailure)
    }
    
    func testPartialErrorHandlingChainWithRetry() {
        testPartialErrorHandlingChain(testKind: .testWithRetry)
    }

    func testFailureWithoutErrorHandling() {
        let networkService = NetworkService()

        let failureExpectation = expectation(description: "Expecting failure response")
        failureExpectation.assertForOverFulfill = true

        request = networkService.request(for: MockEndpoint.failure, success: {
            XCTFail("Invalid case")
        }, failure: { _ in
            failureExpectation.fulfill()
        })

        wait(for: [failureExpectation], timeout: 10)
    }

    func testErrorHandlingWithMappedEndpointErrorByResponseCode() {
        let mappedError = MockError()
        testErrorHandlingWithMappedEndpointError(testKind: .mappedErrorWithResponseCode(400, to: mappedError))
    }

    func testErrorHandlingWithMappedEndpointErrorByURLErrorCode() {
        let mappedError = MockError()
        testErrorHandlingWithMappedEndpointError(testKind: .mappedURLError(with: .badServerResponse, to: mappedError))
    }

    func testErrorHandlingMemoryLeaks() {
        let lifecycleExpectation = expectation(description: "Expecting nil in weak network service")

        let errorHandler = MockErrorHandler { _, _ in
            XCTFail("Memory leak happened")
        }

        let errorHandlingService = ErrorHandlingService(errorHandlers: [errorHandler])
        var networkService: NetworkService? = NetworkService(errorHandlingService: errorHandlingService)
        weak var weakNetworkService = networkService

        networkService?.request(for: MockEndpoint.failure, success: {
            XCTFail("Invalid case")
        }, failure: { _ in
            XCTFail("Invalid case")
        })
        networkService = nil

        _ = XCTWaiter.wait(for: [lifecycleExpectation], timeout: 5)
        XCTAssertNil(weakNetworkService)
        lifecycleExpectation.fulfill()
    }

    // MARK: - Private

    private func testPartialErrorHandlingChain(testKind: PartialErrorHandlingChainTestKind) {
        let errorHandlingTriggeredExpectation = XCTestExpectation(description: "Expecting error handling triggered multiple times")
        errorHandlingTriggeredExpectation.assertForOverFulfill = true

        let failureTriggeredExpectation = XCTestExpectation(description: "Expecting request failure")
        failureTriggeredExpectation.assertForOverFulfill = true

        let firstError = MockError()
        let secondError = MockError()
        errorHandlingTriggeredExpectation.expectedFulfillmentCount = 2

        let errorHandlers = [
            MockErrorHandler { error, completion in
                errorHandlingTriggeredExpectation.fulfill()
                completion(.continueErrorHandling(with: firstError))
            },
            MockErrorHandler { error, completion in
                guard let error = error as? MockError else {
                    XCTFail("Test uses mock errors")
                    return
                }
                XCTAssertTrue(error === firstError)
                errorHandlingTriggeredExpectation.fulfill()

                switch testKind {
                case .testWithFailure:
                    completion(.continueFailure(with: secondError))
                case .testWithRetry:
                    completion(.retryNeeded)
                }
            },
            MockErrorHandler { _, _ in
                XCTFail("Error handling should be interrupted on second error handler")
            }
        ]

        let errorHandlingService = ErrorHandlingService(errorHandlers: errorHandlers)
        let networkService = NetworkService(errorHandlingService: errorHandlingService)
        request = networkService.request(for: MockEndpoint.failure, success: {
            XCTFail("Invalid case")
        }, failure: { error in
            switch testKind {
            case .testWithFailure:
                guard let error = error as? MockError else {
                    XCTFail("Test uses mock errors")
                    return
                }
                XCTAssertTrue(error === secondError)
            case .testWithRetry:
                XCTFail("Retry error handling result should't trigger request failure")
            }
            failureTriggeredExpectation.fulfill()
        })

        var expectations: [XCTestExpectation]
        switch testKind {
        case .testWithFailure:
            expectations = [errorHandlingTriggeredExpectation, failureTriggeredExpectation]
        case .testWithRetry:
            expectations = [errorHandlingTriggeredExpectation]
        }
        
        wait(for: expectations, timeout: 10, enforceOrder: true)
    }

    private func testErrorHandlingWithMappedEndpointError(testKind: EndpointErrorMappingTestKind) {
        var endpoint: Endpoint
        var expectedError: MockError
        switch testKind {
        case .mappedErrorWithResponseCode(let responseCode, to: let mappedError):
            endpoint = MockEndpoint.mappedErrorForResponseCode(responseCode, mappedError: mappedError)
            expectedError = mappedError
        case .mappedURLError(with: let urlErrorCode, to: let mappedError):
            endpoint = MockEndpoint.mappedErrorForURLErrorCode(urlErrorCode, mappedError: mappedError)
            expectedError = mappedError
        }

        let errorHandlingService = ErrorHandlingService(errorHandlers: [GeneralErrorHandler()])
        let networkService = MockNetworkService(errorHandlingService: errorHandlingService)

        let failureExpectation = expectation(description: "Expecting failure response")
        failureExpectation.assertForOverFulfill = true

        request = networkService.request(for: endpoint, success: {
            XCTFail("Invalid case")
        }, failure: { error in
            guard let error = error as? MockError else {
                XCTFail("Test uses mock error")
                return
            }

            XCTAssertTrue(error === expectedError, "Expecting error from endpoint")
            failureExpectation.fulfill()
        })

        wait(for: [failureExpectation], timeout: 10)
    }
}
