platform :ios, '9.0'
inhibit_all_warnings!
use_frameworks! :linkage => :static

target 'CloudAccess' do
	pod 'GRDB.swift', '~> 4.14'
	pod 'PromisesSwift', '~> 1.2'
	pod 'CryptomatorCryptoLib', '~> 0.3'
	
	target 'CloudAccessTests' do
		inherit! :search_paths
	end
end
