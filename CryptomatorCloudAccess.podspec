Pod::Spec.new do |s|
  s.name             = 'CryptomatorCloudAccess'
  s.version          = '0.1.0-alpha.7'
  s.summary          = 'CryptomatorCloudAccess is used in Cryptomator for iOS to access different cloud providers.'


  s.homepage         = 'https://github.com/cryptomator/cloud-access-swift'
  s.license          = { :type => 'AGPLv3', :file => 'LICENSE.txt' }
  s.author           = { 'Philipp Schmid' => 'philipp.schmid@skymatic.de' }
  s.source           = { :git => 'https://github.com/cryptomator/cloud-access-swift.git', :tag => s.version.to_s }
  s.social_media_url = 'https://twitter.com/Cryptomator'

  s.public_header_files = 'CloudAccess/CloudAccess.h'
  s.ios.deployment_target = '8.0'
  s.swift_version = '5.0'
    
  s.source_files = 'CloudAccess/**/*{swift,h,m}'
  
  s.dependency 'PromisesSwift', '~> 1.2'
end
