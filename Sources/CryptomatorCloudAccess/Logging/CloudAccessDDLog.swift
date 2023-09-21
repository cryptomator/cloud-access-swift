//
//  CloudAccessDDLog.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 12.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import CocoaLumberjackSwift
import Foundation

/// The log level that can dynamically limit log messages (vs. the static DDDefaultLogLevel). This log level will only be checked, if the message passes the `DDDefaultLogLevel`.
public var dynamicCloudAccessLogLevel = DDLogLevel.all

@inlinable
// swiftlint:disable:next identifier_name
public func CloudAccessDDLogDebug(_ message: @autoclosure () -> DDLogMessageFormat,
                                  level: DDLogLevel = dynamicCloudAccessLogLevel,
                                  context: Int = 0,
                                  file: StaticString = #file,
                                  function: StaticString = #function,
                                  line: UInt = #line,
                                  tag: Any? = nil,
                                  asynchronous async: Bool = asyncLoggingEnabled,
                                  ddlog: DDLog = CloudAccessDDLog.shared) {
	_DDLogMessage(message(), level: level, flag: .debug, context: context, file: file, function: function, line: line, tag: tag, asynchronous: async, ddlog: ddlog)
}

@inlinable
// swiftlint:disable:next identifier_name
public func CloudAccessDDLogInfo(_ message: @autoclosure () -> DDLogMessageFormat,
                                 level: DDLogLevel = dynamicCloudAccessLogLevel,
                                 context: Int = 0,
                                 file: StaticString = #file,
                                 function: StaticString = #function,
                                 line: UInt = #line,
                                 tag: Any? = nil,
                                 asynchronous async: Bool = asyncLoggingEnabled,
                                 ddlog: DDLog = CloudAccessDDLog.shared) {
	_DDLogMessage(message(), level: level, flag: .info, context: context, file: file, function: function, line: line, tag: tag, asynchronous: async, ddlog: ddlog)
}

@inlinable
// swiftlint:disable:next identifier_name
public func CloudAccessDDLogWarn(_ message: @autoclosure () -> DDLogMessageFormat,
                                 level: DDLogLevel = dynamicCloudAccessLogLevel,
                                 context: Int = 0,
                                 file: StaticString = #file,
                                 function: StaticString = #function,
                                 line: UInt = #line,
                                 tag: Any? = nil,
                                 asynchronous async: Bool = asyncLoggingEnabled,
                                 ddlog: DDLog = CloudAccessDDLog.shared) {
	_DDLogMessage(message(), level: level, flag: .warning, context: context, file: file, function: function, line: line, tag: tag, asynchronous: async, ddlog: ddlog)
}

@inlinable
// swiftlint:disable:next identifier_name
public func CloudAccessDDLogVerbose(_ message: @autoclosure () -> DDLogMessageFormat,
                                    level: DDLogLevel = dynamicCloudAccessLogLevel,
                                    context: Int = 0,
                                    file: StaticString = #file,
                                    function: StaticString = #function,
                                    line: UInt = #line,
                                    tag: Any? = nil,
                                    asynchronous async: Bool = asyncLoggingEnabled,
                                    ddlog: DDLog = CloudAccessDDLog.shared) {
	_DDLogMessage(message(), level: level, flag: .verbose, context: context, file: file, function: function, line: line, tag: tag, asynchronous: async, ddlog: ddlog)
}

@inlinable
// swiftlint:disable:next identifier_name
public func CloudAccessDDLogError(_ message: @autoclosure () -> DDLogMessageFormat,
                                  level: DDLogLevel = dynamicCloudAccessLogLevel,
                                  context: Int = 0,
                                  file: StaticString = #file,
                                  function: StaticString = #function,
                                  line: UInt = #line,
                                  tag: Any? = nil,
                                  asynchronous async: Bool = false,
                                  ddlog: DDLog = CloudAccessDDLog.shared) {
	_DDLogMessage(message(), level: level, flag: .error, context: context, file: file, function: function, line: line, tag: tag, asynchronous: async, ddlog: ddlog)
}

public class CloudAccessDDLog: DDLog {
	public static let shared = CloudAccessDDLog()
	override public static func add(_ logger: DDLogger) {
		shared.add(logger)
	}

	override public static func add(_ logger: DDLogger, with level: DDLogLevel) {
		shared.add(logger, with: level)
	}

	override public static func remove(_ logger: DDLogger) {
		shared.remove(logger)
	}

	override public static func removeAllLoggers() {
		shared.removeAllLoggers()
	}

	override public static var allLoggersWithLevel: [DDLoggerInformation] {
		return shared.allLoggersWithLevel
	}

	override public static var allLoggers: [DDLogger] {
		return shared.allLoggers
	}
}
