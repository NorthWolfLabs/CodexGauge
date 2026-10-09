#!/usr/bin/env ruby
# Run from the repository root. Generates only the companion project.
require 'xcodeproj'
project = Xcodeproj::Project.new('Companion/TokenTachMobile.xcodeproj')
app = project.new_target(:application, 'TokenTachMobile', :ios, '17.0')
widgets = project.new_target(:app_extension, 'TokenTachWidgets', :ios, '17.0')
shared = project.main_group.new_group('Shared', 'Shared')
Dir['Companion/Shared/*.swift'].sort.each do |file|
  ref = shared.new_file(File.basename(file))
  [app, widgets].each { |target| target.source_build_phase.add_file_reference(ref) }
end
[[app, 'iOS'], [widgets, 'Widgets']].each do |target, folder|
  group = project.main_group.new_group(folder, folder)
  Dir["Companion/#{folder}/*.swift"].sort.each { |file| target.source_build_phase.add_file_reference(group.new_file(File.basename(file))) }
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '6.0', 'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
      'DEVELOPMENT_TEAM' => 'ALPX923Y54', 'CODE_SIGN_STYLE' => 'Automatic',
      'CODE_SIGN_ENTITLEMENTS' => target == app ? "iOS/#{config.name == 'Release' ? '$(COMPANION_RELEASE_ENTITLEMENTS)' : 'CompanionPush'}$(DEVICE_NAME_ENTITLEMENTS_SUFFIX).entitlements" : 'iOS/Companion.entitlements',
      'PRODUCT_BUNDLE_IDENTIFIER' => target == app ? 'com.northwolflabs.CodexGauge' : 'com.northwolflabs.CodexGauge.widgets',
      'INFOPLIST_FILE' => "#{folder}/Info.plist", 'GENERATE_INFOPLIST_FILE' => 'NO',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'SWIFT_STRICT_CONCURRENCY' => 'complete',
      'MARKETING_VERSION' => '1.2.0', 'CURRENT_PROJECT_VERSION' => '10',
      'DEVICE_NAME_ENTITLEMENTS_SUFFIX' => '',
      'COMPANION_RELEASE_ENTITLEMENTS' => 'CompanionDistribution',
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => config.name == 'Debug' ? 'DEBUG' : '',
    })
  end
end
privacy = shared.new_file('PrivacyInfo.xcprivacy')
[app, widgets].each { |target| target.resources_build_phase.add_file_reference(privacy) }
app.add_dependency(widgets)
icon = project.main_group.new_file('../TokenTach/AppIcon.icon')
app.resources_build_phase.add_file_reference(icon)
app.resources_build_phase.add_file_reference(project.main_group.new_file('iOS/Assets.xcassets'))
app.build_configurations.each { |config| config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon' }
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(widgets.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
widgets.build_configurations.each { |config| config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'; config.build_settings['SKIP_INSTALL'] = 'YES' }
tests = project.new_target(:ui_test_bundle, 'CompanionUITests', :ios, '17.0')
tests.add_dependency(app)
group = project.main_group.new_group('UITests', 'UITests')
Dir['Companion/UITests/*.swift'].sort.each { |file| tests.source_build_phase.add_file_reference(group.new_file(File.basename(file))) }
tests.build_configurations.each do |config|
  config.build_settings.merge!({ 'SWIFT_VERSION' => '6.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_TARGET_NAME' => 'TokenTachMobile', 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.northwolflabs.CodexGauge.mobile.uitests', 'DEVELOPMENT_TEAM' => 'ALPX923Y54', 'CODE_SIGN_STYLE' => 'Automatic' })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests, launch_target: true)
scheme.save_as(project.path, 'TokenTachMobile', true)
