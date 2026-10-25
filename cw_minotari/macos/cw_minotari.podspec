Pod::Spec.new do |s|
  s.name = 'cw_minotari'
  s.version = '0.0.1'
  s.summary = 'Cake Wallet Minotari native wallet'
  s.description = 'Minotari wallet library loaded through Flutter Rust Bridge.'
  s.homepage = 'https://cakewallet.com'
  s.license = { :type => 'MIT', :file => '../../LICENSE.md' }
  s.author = { 'Cake Wallet' => 'support@cakewallet.com' }
  s.source = { :path => '.' }
  s.platform = :osx, '12.0'
  s.vendored_frameworks = 'Frameworks/rust_lib_flutter_rust_wallet.framework'
end
