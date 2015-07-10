//
//  Protocol.swift
//
//  Copyright (c) 2015 Netguru Sp. z o.o. All rights reserved.
//

import Foundation

public final class InterceptingProtocol: NSURLProtocol, NSURLSessionDataDelegate, NSURLSessionTaskDelegate {

	/// The interceptor removal token type.
	public typealias InterceptorRemovalToken = UInt

	/// The last registered removal token.
	private static var lastRemovalToken: InterceptorRemovalToken = 0

	/// Private request interceptors store.
	private static var requestInterceptors = [InterceptorRemovalToken: RequestInterceptorType]()

	/// Private response interceptors store.
	private static var responseInterceptors = [InterceptorRemovalToken: ResponseInterceptorType]()
	
	/// Private error interceptors store.
	private static var errorInterceptors = [InterceptorRemovalToken: ErrorInterceptorType]()

	/// Private under-the-hood session object.
	private var session: NSURLSession!

	/// Private under-the-hood session task.
	private var sessionTask: NSURLSessionDataTask!
	
	/// Private under-the-hood response object
	private var response: NSHTTPURLResponse?
	
	/// Private under-the-hood response data object.
	private lazy var responseData = NSMutableData()

	// MARK: Interceptor registration

	/// Registers a new request interceptor.
	///
	/// :param: interceptor The new interceptor instance to register.
	///
	/// :returns: A unique token which can be used for removing that request
	/// interceptor.
	public static func registerRequestInterceptor(interceptor: RequestInterceptorType) -> InterceptorRemovalToken {
		requestInterceptors[++lastRemovalToken] = interceptor
		return lastRemovalToken
	}

	/// Registers a new response interceptor.
	///
	/// :param: interceptor The new response interceptor instance to register.
	///
	/// :returns: A unique token which can be used for removing that response
	/// interceptor.
	public static func registerResponseInterceptor(interceptor: ResponseInterceptorType) -> InterceptorRemovalToken {
		responseInterceptors[++lastRemovalToken] = interceptor
		return lastRemovalToken
	}
	
	/// Registers a new error interceptor.
	///
	/// :param: interceptor The new error interceptor instance to register.
	///
	/// :returns: A unique token which can be used for removing that error
	/// interceptor.
	public static func registerErrorInterceptor(interceptor: ErrorInterceptorType) -> InterceptorRemovalToken {
		errorInterceptors[++lastRemovalToken] = interceptor
		return lastRemovalToken
	}

	/// Unregisters the previously registered request interceptor.
	///
	/// :param: removalToken The removal token obtained when registering the
	/// request interceptor.
	public static func unregisterRequestInterceptor(removalToken: InterceptorRemovalToken) {
		requestInterceptors[removalToken] = nil
	}

	/// Unregisters the previously registered response interceptor.
	///
	/// :param: removalToken The removal token obtained when registering the
	/// response interceptor.
	public static func unregisterResponseInterceptor(removalToken: InterceptorRemovalToken) {
		responseInterceptors[removalToken] = nil
	}
	
	/// Unregisters the previously registered error interceptor.
	///
	/// :param: removalToken The removal token obtained when registering the
	/// error interceptor.
	public static func unregisterErrorInterceptor(removalToken: InterceptorRemovalToken) {
		errorInterceptors[removalToken] = nil
	}

	// MARK: Propagation helpers

	/// Propagates the request interception.
	///
	/// :param: request The intercepted request.
	private func propagateRequestInterception(request: NSURLRequest) {
		if let representation = RequestRepresentation(request) {
			for (_, interceptor) in InterceptingProtocol.requestInterceptors {
				if interceptor.canInterceptRequest(representation) {
					interceptor.interceptRequest(representation)
				}
			}
		}
	}

	/// Propagates the request interception.
	///
	/// :param: request The intercepted response.
	/// :param: data The intercepted response data.
	private func propagateResponseInterception(response: NSHTTPURLResponse, _ data: NSData) {
		if let representation = ResponseRepresentation(response, data) {
			for (_, interceptor) in InterceptingProtocol.responseInterceptors {
				if interceptor.canInterceptResponse(representation) {
					interceptor.interceptResponse(representation)
				}
			}
		}
	}

	/// Propagates the error interception.
	///
	/// :param: error The intercepted response error.
	/// :param: response The intercepted response (if any).
	/// :param: error The error which occured during the request.
	private func propagateResponseErrorInterception(response: NSHTTPURLResponse?, _ data: NSData?, _ error: NSError) {
		if let response = response, representation = ResponseRepresentation(response, data) {
			for (_, interceptor) in InterceptingProtocol.errorInterceptors {
				interceptor.interceptError(error, representation)
			}
		}
	}

	// MARK: NSURLProtocol overrides
	
	public override init(request: NSURLRequest, cachedResponse: NSCachedURLResponse?, client: NSURLProtocolClient?) {
		super.init(request: request, cachedResponse: cachedResponse, client: client)
		session = NSURLSession(configuration: NSURLSessionConfiguration.ephemeralSessionConfiguration(), delegate: self, delegateQueue: nil)
		sessionTask = session.dataTaskWithRequest(request)
	}

	public override static func canInitWithRequest(request: NSURLRequest) -> Bool {
		return true
	}

	public override static func canonicalRequestForRequest(request: NSURLRequest) -> NSURLRequest {
		return request
	}

	public override func startLoading() {
		propagateRequestInterception(request)
		sessionTask.resume()
	}

	public override func stopLoading() {
		sessionTask.cancel()
	}

	// MARK: NSURLSessionDataDelegate methods
	
	public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: (NSURLSessionResponseDisposition) -> Void) {
		client?.URLProtocol(self, didReceiveResponse: response, cacheStoragePolicy:NSURLCacheStoragePolicy.Allowed)
		completionHandler(.Allow)
		if let response = response as? NSHTTPURLResponse {
			self.response = response
		}
	}
	
	public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
		client?.URLProtocol(self, didLoadData: data)
		responseData.appendData(data)
	}

	// MARK: NSURLSessionTaskDelegate methods

	public func URLSession(session: NSURLSession, task: NSURLSessionTask, willPerformHTTPRedirection response: NSHTTPURLResponse, newRequest request: NSURLRequest, completionHandler: (NSURLRequest!) -> Void) {
		client?.URLProtocol(self, wasRedirectedToRequest: request, redirectResponse: response)
		completionHandler(request)
	}
	
	public func URLSession(session: NSURLSession, task: NSURLSessionTask, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void) {
		client?.URLProtocol(self, didReceiveAuthenticationChallenge: challenge)
		// TODO: Call completionHandler with proper credentials
	}
	
	public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
		if let error = error {
			client?.URLProtocol(self, didFailWithError: error)
			propagateResponseErrorInterception(response, responseData, error)
		}
		if let response = self.response {
			propagateResponseInterception(response, responseData)
		}
	}
}

public extension InterceptingProtocol {
	
	static func clearInterceptors() {
		lastRemovalToken = 0
		requestInterceptors = [:]
		responseInterceptors = [:]
		errorInterceptors = [:]
	}
}
