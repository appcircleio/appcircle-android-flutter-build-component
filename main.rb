require 'yaml'
require 'open3'
require 'pathname'
require 'fileutils'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

ac_flutter_project_dir = get_env_variable("AC_FLUTTER_PROJECT_DIR") || abort('Missing Flutter project path.')
ac_output_type = get_env_variable("AC_OUTPUT_TYPE") || abort('Missing output type.')
ac_output_folder = get_env_variable("AC_OUTPUT_DIR") || abort('Missing output folder.')
ac_flutter_build_extra_args = get_env_variable("AC_FLUTTER_BUILD_EXTRA_ARGS") || ""
ac_flutter_build_mode = get_env_variable("AC_FLUTTER_BUILD_MODE") || "release"

def run_command(command)
    puts "@@[command] #{command}"
    unless system(command)
      exit $?.exitstatus
    end
end

build_type = (ac_output_type == "aab") ? "appbundle" : "apk"

puts "PATH=#{ENV["PATH"]}"
run_command("cd #{ac_flutter_project_dir} && flutter build #{build_type} #{ac_flutter_build_extra_args} --#{ac_flutter_build_mode}")

build_outputs_folder = "#{ac_flutter_project_dir}/build/app/outputs"
apk_filter_pattern = "#{build_outputs_folder}/apk/***/*.apk"
aab_filter_pattern = "#{build_outputs_folder}/bundle/***/*.aab"
flutter_apk_filter_pattern = "#{build_outputs_folder}/flutter-apk/**/app-*.apk"

puts "Filtering artifacts: #{apk_filter_pattern}\n, #{flutter_apk_filter_pattern}\n, #{aab_filter_pattern}\n"

apks = Dir.glob("#{apk_filter_pattern}")
apks += Dir.glob("#{flutter_apk_filter_pattern}")
aabs = Dir.glob("#{aab_filter_pattern}")

puts "Copying artifacts to output folder..."
puts "#{apks}"
puts "#{aabs}"

FileUtils.cp apks, "#{ac_output_folder}"
FileUtils.cp aabs, "#{ac_output_folder}"

apks = Dir.glob("#{ac_output_folder}/**/*.apk").join("|")
aabs = Dir.glob("#{ac_output_folder}/**/*.aab").join("|")

puts "Exporting AC_APK_PATH=#{apks}"
puts "Exporting AC_AAB_PATH=#{aabs}"

open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_APK_PATH=#{apks}"
    f.puts "AC_AAB_PATH=#{aabs}"
}

exit 0
