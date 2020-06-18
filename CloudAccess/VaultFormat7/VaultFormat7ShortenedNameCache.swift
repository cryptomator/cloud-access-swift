//
//  VaultFormat7ShortenedNameCache.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

struct ShortenedURL {
	let url: URL
	let isShortened: Bool
	let nameFileURL: URL?

	init(url: URL, isShortened: Bool, nameFileURL: URL?) {
		self.url = url
		self.isShortened = isShortened
		self.nameFileURL = nameFileURL
	}
}

class VaultFormat7ShortenedNameCache {

	/**
	 Applies the .c9s shortening defined in vault format 7 (if required).
	 This **does not** persist the original name to `name.c9s`, though.

	- Parameter originalURL: The unshortened URL.
	- Returns: A `ShortenedURL` object that is either based on the `originalURL` (if no shortening is required) or a shortened URL
	*/
	func getShortenedURL(_ originalURL: URL) -> ShortenedURL {
		return ShortenedURL(url: originalURL, isShortened: false, nameFileURL: nil)
	}

	/**
	 Undos .c9s shortening defined in vault format 7 (if required).

	- Parameter shortenedURL: A potentially shortened URL.
	- Parameter contentLoader: A closure loading the contents of `nameC9SURL`.
	- Parameter nameC9SURL: The URL of a `name.c9s` that needs to be loaded.
	- Returns: Either `shortenedURL` if no shortening was applied or the original ("inflated") URL
	*/
	func getOriginalURL(_ shortenedURL: URL, contentLoader: (_ nameC9SURL: URL) -> Promise<Data>) -> Promise<URL> {
		return Promise(shortenedURL)
	}

}
