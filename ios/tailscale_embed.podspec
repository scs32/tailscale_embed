# Fetch the prebuilt xcframework (pinned in Framework.lock) from GitHub
# Releases. This runs at podspec-eval (pod install) time — NOT prepare_command
# (skipped for development pods, which Flutter plugins always are) and NOT a
# script_phase (too late: CocoaPods needs the .xcframework present at install
# time to wire up slice selection and linking).
unless system('/bin/sh', File.join(File.dirname(__FILE__), 'download_framework.sh'))
  raise 'tailscale_embed: failed to fetch TailscaleEmbed.xcframework (see error above; ' \
        'offline fallback: build from source with go/build.sh)'
end

Pod::Spec.new do |s|
  s.name             = 'tailscale_embed'
  s.version          = '0.2.0'
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

  # Built from ../go with gomobile (go/build.sh) and distributed via GitHub
  # Releases; downloaded above so consumers don't need a Go toolchain.
  s.vendored_frameworks = 'TailscaleEmbed.xcframework'
  s.static_framework = true
end
