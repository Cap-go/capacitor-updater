require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'PayjustnowCapacitorUpdater'
  s.version = '1.0.0'
  s.summary = package['description']
  s.license = package['license']
  s.homepage = package['repository']['url']
  s.author = package['author']
  s.source = { :git => 'https://github.com/PJN-Repo/capacitor-updater', :tag => s.version.to_s }
  s.source_files = 'ios/Plugin/**/*.{swift,h,m,c,cc,mm,cpp}'
  s.ios.deployment_target  = '13.0'
  s.dependency 'Capacitor'
  s.dependency 'SSZipArchive', '2.4.3'
  s.dependency 'Alamofire'
  s.dependency 'Version'
  s.swift_version = '5.1'
end
