CONFIGURATION = "Release"
DEVICE = "iphoneos"
SIMULATOR = "iphonesimulator"

def c99ext_identifier(name)
  name.gsub(/^([0-9])/, '_\1').gsub(/[^a-zA-Z0-9_]/, '_')
end

def xcodebuild(sandbox, target, sdk='macosx')
  Pod::Executable.execute_command 'xcodebuild', %W(-project #{sandbox.project_path.basename} -scheme #{target} -configuration #{CONFIGURATION} -sdk #{sdk}), true
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context|
  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  build_dir.rmtree if build_dir.directory?
  Dir.chdir(sandbox.project_path.dirname) do
    targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
    targets.each do |target|
      target_label = target.cocoapods_target_label
      if target.platform_name == :ios
        xcodebuild(sandbox, target_label, DEVICE)
        xcodebuild(sandbox, target_label, SIMULATOR)

        spec_names = target.specs.map { |spec| spec.root.name }.uniq
        spec_names.each do |root_name|
          product_module_name = c99ext_identifier(root_name)
          executable_path = "#{build_dir}/#{product_module_name}"
          device_lib = "#{build_dir}/#{CONFIGURATION}-#{DEVICE}/#{product_module_name}.framework/#{product_module_name}"
          device_framework_lib = File.dirname(device_lib)
          device_modules_lib = "#{device_framework_lib}/Modules/#{product_module_name}.swiftmodule"
          simulator_lib = "#{build_dir}/#{CONFIGURATION}-#{SIMULATOR}/#{product_module_name}.framework/#{product_module_name}"
          simulator_framework_lib = File.dirname(simulator_lib)
          simulator_modules_lib = "#{simulator_framework_lib}/Modules/#{product_module_name}.swiftmodule"

          next unless File.file?(device_lib) && File.file?(simulator_lib)

          lipo_log = `lipo -create -output #{executable_path} #{device_lib} #{simulator_lib}`
          puts lipo_log unless File.exist?(executable_path)

          FileUtils.mv executable_path, device_lib

          module_files = Pathname.glob("#{simulator_modules_lib}/*")
          module_files.each do |module_file|
            FileUtils.mv module_file, device_modules_lib
          end

          FileUtils.mv device_framework_lib, build_dir
        end
      else
        xcodebuild(sandbox, target_label)
      end
    end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  frameworks = Pathname.glob("#{build_dir}/**/*.framework").reject { |f| f.to_s =~ /Pods*\.framework/ }

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
    end
  end
  frameworks.uniq!

  Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  frameworks.each do |framework|
    FileUtils.mkdir_p destination
    FileUtils.cp_r framework, destination, :remove_destination => true
  end
  build_dir.rmtree if build_dir.directory?
end
