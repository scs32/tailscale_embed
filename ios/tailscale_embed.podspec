Pod::Spec.new do |s|
  s.name             = 'tailscale_embed'
  s.version          = '0.1.0'
  s.summary          = 'Embedded Tailscale (tsnet) node for Flutter apps'
  s.description      = <<-DESC
Embeds a Tailscale node (Go tsnet via gomobile) in the app and exposes a
local HTTP CONNECT proxy for routing tailnet traffic — no system VPN needed.
                       DESC
  s.homepage         = 'https://github.com/scs32/tailscale_embed'
  s.license          = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author           = { 'Stephen Speicher' => 'stephenspeicher@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.ios.deployment_target = '13.0'

  # Built from ../go with gomobile (go/build.sh) and checked into git so
  # consumers don't need a Go toolchain.
  s.vendored_frameworks = 'TailscaleEmbed.xcframework'
  s.static_framework = true
end
