platform :ios, '9.0'
inhibit_all_warnings!
use_frameworks! :linkage => :static

target 'CloudAccess' do
	pod 'CryptomatorCryptoLib', '~> 0.8.0'
	pod 'GRDB.swift', '~> 4.14.0'
	pod 'PromisesSwift', '~> 1.2.0'
	
	target 'CloudAccessTests' do
		inherit! :search_paths
	end
end
